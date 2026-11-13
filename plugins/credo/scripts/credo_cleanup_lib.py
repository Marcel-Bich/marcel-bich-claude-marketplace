"""credo_cleanup_lib.py - shared code of the provenance ledger (credo-ledger.py, the hooks)
and the cleanup helper (credo-cleanup.py).

Idea: an agent may remove, without a prompt, exactly what its own session provably created.
The proof is a per-session ledger that only hooks write: a PreToolUse hook sets a time mark,
the PostToolUse hook records every entry born after the mark in the watched roots (birth time
via statx), and Write/Edit record a file (or the topmost new directory) that did not exist
before. Each entry keeps dev+inode, so a path that was replaced later is not "ours" any more.
Subagents run under the session id of their main agent, so the main agent inherits their
entries. The helper deletes only ledger entries (or paths below a ledger directory entry) and
refuses a hard denylist whatever the ledger says.

Layout (all local, never versioned):
  state dir   $CREDO_CLEANUP_STATE, else ${XDG_STATE_HOME:-~/.local/state}/credo/cleanup
    ledger/<session_id>.jsonl   append-only records and events (removed, moved)
    marks/<session_id>/<t0>_<tool_use_id>   time marks of running tool calls
    windows.log                 closed tool-call windows of all sessions (ambiguity check)
    jobs/                       background scan jobs
    cleanup.log                 every removal, refusal and failure
    stamps/                     once-per-day / once-per-hour markers
  keep dir    $CREDO_KEEP_ROOT, else ~/.local/share/credo/keep  (keep-list.json inside)
  session tmp $CREDO_TMP_BASE, else /tmp/credo-tmp-<uid>; one dir per session id

Everything here fails soft: callers catch exceptions; a hook never blocks on an error.
"""
import ctypes
import ctypes.util
import fcntl
import glob
import json
import os
import re
import stat
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")

# --------------------------------------------------------------------------- paths


def home():
    return os.path.realpath(os.path.expanduser("~"))


def state_dir():
    d = os.environ.get("CREDO_CLEANUP_STATE")
    if not d:
        base = os.environ.get("XDG_STATE_HOME") or os.path.join(home(), ".local", "state")
        d = os.path.join(base, "credo", "cleanup")
    return os.path.realpath(os.path.expanduser(d))


def keep_root():
    d = os.environ.get("CREDO_KEEP_ROOT") or os.path.join(home(), ".local", "share", "credo", "keep")
    return os.path.realpath(os.path.expanduser(d))


def keep_list_path():
    return os.path.join(keep_root(), "keep-list.json")


def tmp_base():
    d = os.environ.get("CREDO_TMP_BASE") or "/tmp/credo-tmp-%d" % os.getuid()
    return os.path.realpath(d)


def session_tmp(sid):
    return os.path.join(tmp_base(), sid)


def valid_sid(sid):
    return bool(sid) and bool(SID_RE.match(sid))


def ledger_path(sid):
    return os.path.join(state_dir(), "ledger", sid + ".jsonl")


def log_path():
    return os.path.join(state_dir(), "cleanup.log")


def ensure_dir(path, mode=0o700):
    os.makedirs(path, mode=mode, exist_ok=True)


def now():
    return time.time()


def iso(ts=None):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(ts if ts is not None else now()))


def log(msg):
    try:
        ensure_dir(state_dir())
        with open(log_path(), "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (iso(), msg.replace("\n", " ")))
    except OSError:
        pass


# --------------------------------------------------------------------------- statx

_STATX_BTIME = 0x800
_AT_FDCWD = -100
_AT_SYMLINK_NOFOLLOW = 0x100
_libc = None
_statx_ok = None


def _statx_fn():
    global _libc, _statx_ok
    if _statx_ok is None:
        _statx_ok = False
        if os.environ.get("CREDO_CLEANUP_NO_BTIME") == "1":
            return None
        try:
            _libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
            _libc.statx  # noqa: B018 - attribute lookup raises when glibc has no statx
            _statx_ok = True
        except (OSError, AttributeError):
            _statx_ok = False
    return _libc.statx if _statx_ok else None


def birth_time(path, dir_fd=None):
    """Birth time of path (relative to dir_fd when given; no symlink follow) in seconds, or None
    when unknown."""
    fn = _statx_fn()
    if fn is None:
        return None
    buf = ctypes.create_string_buffer(256)
    rc = fn(_AT_FDCWD if dir_fd is None else dir_fd, os.fsencode(path), _AT_SYMLINK_NOFOLLOW,
            _STATX_BTIME, buf)
    if rc != 0:
        return None
    mask = int.from_bytes(buf.raw[0:4], "little")
    if not mask & _STATX_BTIME:
        return None
    sec = int.from_bytes(buf.raw[80:88], "little", signed=True)
    nsec = int.from_bytes(buf.raw[88:92], "little")
    if sec <= 0:
        return None
    return sec + nsec / 1e9


def kind_of(st):
    if stat.S_ISLNK(st.st_mode):
        return "link"
    if stat.S_ISDIR(st.st_mode):
        return "dir"
    if stat.S_ISREG(st.st_mode):
        return "file"
    return "other"


# --------------------------------------------------------------------------- ledger


class Locked:
    """Exclusive flock on <file>.lock for the duration of a with block."""

    def __init__(self, path):
        self.path = path + ".lock"
        self.fh = None

    def __enter__(self):
        ensure_dir(os.path.dirname(self.path))
        self.fh = open(self.path, "a")
        fcntl.flock(self.fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        try:
            fcntl.flock(self.fh, fcntl.LOCK_UN)
        finally:
            self.fh.close()


def append_ledger(sid, records):
    if not records:
        return
    path = ledger_path(sid)
    ensure_dir(os.path.dirname(path))
    with Locked(path):
        with open(path, "a", encoding="utf-8") as fh:
            for r in records:
                fh.write(json.dumps(r, sort_keys=True) + "\n")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def load_ledger(sid):
    """Replay the ledger: {path: entry} of the entries that are still owned (not removed)."""
    entries = {}
    path = ledger_path(sid)
    try:
        fh = open(path, encoding="utf-8")
    except OSError:
        return entries
    with fh:
        for line in fh:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            ev = r.get("event", "record")
            p = r.get("path")
            if not isinstance(p, str):
                continue
            if ev == "record":
                old = entries.get(p)
                # keep the first record of a path while its inode is unchanged (evidence may grow)
                if old and old.get("ino") == r.get("ino") and old.get("dev") == r.get("dev"):
                    if old.get("evidence") == "window" and r.get("evidence") != "window":
                        old["evidence"] = r.get("evidence")
                    continue
                entries[p] = r
            elif ev == "removed":
                entries.pop(p, None)
            elif ev == "moved":
                old = entries.pop(p, None)
                to = r.get("to")
                if old is not None and isinstance(to, str):
                    new = dict(old)
                    new.update({"path": to, "dev": r.get("dev"), "ino": r.get("ino"), "kept": True})
                    entries[to] = new
    return entries


def make_record(path, st, tool, evidence, kind, agent_id=None, ambiguous=None, btime=None):
    r = {
        "event": "record",
        "path": path,
        "dev": st.st_dev,
        "ino": st.st_ino,
        "type": kind_of(st),
        "btime": round(btime, 3) if btime else None,
        "ctime": round(st.st_ctime, 3),
        "tool": tool,
        "evidence": evidence,
        "root_kind": kind,
        "ts": iso(),
    }
    if r["type"] == "file":
        r["size"] = st.st_size
    if agent_id:
        r["agent_id"] = agent_id
    if ambiguous:
        r["ambiguous"] = sorted(ambiguous)
    return r


# --------------------------------------------------------------------------- sessions


def profile_dirs():
    dirs = set()
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    if cfg:
        dirs.add(os.path.realpath(os.path.expanduser(cfg)))
    for d in glob.glob(os.path.join(home(), ".claude*")):
        if os.path.isdir(d):
            dirs.add(os.path.realpath(d))
    extra = os.environ.get("CREDO_CLEANUP_PROFILES")
    if extra is not None:  # tests: only these
        dirs = {os.path.realpath(p) for p in extra.split(":") if p}
    return sorted(dirs)


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except (ValueError, TypeError, OSError):
        return False


def running_sessions():
    """Session ids with a live process descriptor (<profile>/sessions/<pid>.json)."""
    live = set()
    for prof in profile_dirs():
        for f in glob.glob(os.path.join(prof, "sessions", "*.json")):
            try:
                with open(f, encoding="utf-8") as fh:
                    d = json.load(fh)
            except (OSError, ValueError):
                continue
            sid = d.get("sessionId")
            pid = d.get("pid") or os.path.basename(f)[:-5]
            if sid and pid_alive(pid):
                live.add(sid)
    return live


# --------------------------------------------------------------------------- config


def local_config():
    """The cleanup block of the LOCAL config only (global + profile layer, never the project
    layer, which may be versioned). {} when unreadable."""
    script = os.path.join(HERE, "credo-config.sh")
    env = dict(os.environ)
    env["CREDO_PROJECT"] = os.path.join(state_dir(), "no-project-layer")
    env["CREDO_SKIP_ENSURE"] = "1"
    env.setdefault("CLAUDE_PLUGIN_ROOT", os.path.dirname(HERE))
    try:
        out = subprocess.run(["bash", script, "get", "cleanup"], env=env, capture_output=True,
                             text=True, timeout=20)
        if out.returncode == 0:
            val = json.loads(out.stdout or "{}")
            return val if isinstance(val, dict) else {}
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return {}


# --------------------------------------------------------------------------- path rules


def is_under(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def real_target(path):
    """Absolute path with the parent resolved and the last component kept (never follows a
    symlink at the target itself)."""
    ab = os.path.abspath(os.path.expanduser(path))
    parent, name = os.path.split(ab)
    if name in ("", ".", ".."):
        return None
    return os.path.join(os.path.realpath(parent), name)


def git_top(path):
    """(top, is_linked_worktree) of the nearest git work tree containing path, or (None, False)."""
    d = path if os.path.isdir(path) and not os.path.islink(path) else os.path.dirname(path)
    while True:
        g = os.path.join(d, ".git")
        if os.path.lexists(g):
            return d, os.path.isfile(g)
        nd = os.path.dirname(d)
        if nd == d:
            return None, False
        d = nd


def main_checkout_of(worktree):
    """Main checkout of a linked worktree (its .git is a file), else None."""
    try:
        with open(os.path.join(worktree, ".git"), encoding="utf-8") as fh:
            line = fh.readline().strip()
    except OSError:
        return None
    if not line.startswith("gitdir:"):
        return None
    gd = line[7:].strip()
    if not os.path.isabs(gd):
        gd = os.path.join(worktree, gd)
    gd = os.path.realpath(gd)
    # <common>/worktrees/<id>
    common = os.path.dirname(os.path.dirname(gd))
    if os.path.basename(common) == ".git":
        return os.path.dirname(common)
    return None


def claude_profile_roots():
    """Every Claude profile dir: ~/.claude* (also when it is a symlink, both forms) and
    $CLAUDE_CONFIG_DIR. Nothing below them is ever recorded or deleted by the cleanup."""
    roots = set()
    for base in {home(), os.path.expanduser("~")}:
        for prof in glob.glob(os.path.join(base, ".claude*")):
            roots.add(prof)
            roots.add(os.path.realpath(prof))
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    if cfg:
        roots.add(os.path.abspath(os.path.expanduser(cfg)))
        roots.add(os.path.realpath(os.path.expanduser(cfg)))
    return roots


def in_claude_profile(p):
    h = home()
    if is_under(p, h) and p != h and os.path.relpath(p, h).split("/")[0].startswith(".claude"):
        return True
    return any(is_under(p, r) for r in claude_profile_roots())


_MOUNTS = None


def mount_points():
    """All mount points from /proc/self/mountinfo (same-device bind mounts included)."""
    global _MOUNTS
    if _MOUNTS is None:
        mounts = set()
        try:
            src = os.environ.get("CREDO_CLEANUP_MOUNTINFO") or "/proc/self/mountinfo"  # tests: a fixture
            with open(src, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    parts = line.split()
                    if len(parts) > 4:
                        mp = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), parts[4])
                        mounts.add(mp)
        except OSError:
            pass
        _MOUNTS = mounts
    return _MOUNTS


def mount_at_or_below(p):
    """A mount point at p or anywhere below it, else None."""
    for m in mount_points():
        if m != "/" and is_under(m, p):
            return m
    if os.path.isdir(p) and not os.path.islink(p) and os.path.ismount(p):
        return p
    return None


SYSTEM_DENY = ["/", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64", "/mnt", "/media",
               "/opt", "/proc", "/root", "/run", "/sbin", "/srv", "/sys", "/usr", "/var", "/tmp",
               "/var/tmp", "/dev/shm", "/snap"]


def hard_refusal(p, cfg_keep_paths=()):
    """Reason string when p is on the hard denylist (whatever the ledger says), else None."""
    h = home()
    if p in SYSTEM_DENY:
        return "system or root-level path"
    if is_under(h, p):
        return "the home directory or one of its parents"
    if in_claude_profile(p):
        return "Claude profile data (~/.claude*/** and $CLAUDE_CONFIG_DIR, never deleted by the helper)"
    if is_under(p, state_dir()) or is_under(state_dir(), p):
        return "the provenance ledger itself"
    if p == keep_root() or p == keep_list_path() or is_under(keep_root(), p):
        return "the keep store or its parents"
    for top in ("/mnt", "/media"):
        if is_under(p, top) and p.count("/") <= 4:
            return "mounted storage (depth <= 4)"
    try:
        st = os.lstat(p)
    except OSError:
        st = None
    if st is not None and stat.S_ISDIR(st.st_mode):
        m = mount_at_or_below(p)
        if m:
            return "a mount point at or below it (%s)" % m
    for k in cfg_keep_paths or ():
        if not isinstance(k, str) or not k.strip():
            continue
        kp = os.path.realpath(os.path.expanduser(k.strip()))
        if is_under(p, kp) or is_under(kp, p):
            return "on the owner's keep list (cleanup.keep_paths in the local config)"
    return None


def temp_roots():
    roots = ["/tmp", "/var/tmp", "/dev/shm", tmp_base()]
    roots += [os.path.realpath(r) for r in (os.environ.get("CREDO_CLEANUP_TEMP_ROOTS") or "").split(":") if r]
    return roots


def in_temp_root(p):
    return any(p != r and is_under(p, r) for r in temp_roots())


def _git_refusal(d, git_entry):
    """Reason when the repository marker git_entry (d/.git) forbids deleting d."""
    if not os.path.isdir(git_entry) or os.path.islink(git_entry):
        return "%s is a linked git worktree (use credo-worktree-cleanup.sh, never a plain delete)" % d
    if not in_temp_root(d):
        return "%s is a repository outside the temp roots (a likely result, never a plain delete)" % d
    wts = os.path.join(git_entry, "worktrees")
    if os.path.isdir(wts) and os.listdir(wts):
        return "%s is a repository with linked worktrees" % d
    return None


class TreeInfo:
    def __init__(self):
        self.newest = 0.0      # newest mtime/ctime of any inode
        self.special = None    # first socket / fifo / device found
        self.count = 0


SLACK = 2.0  # seconds of clock/rounding slack between a parent's and a child's birth


def foreign_inode(st, bt, since):
    """Reason when an inode cannot be this session's work: no birth time, born before the
    provenance start (pre-existing data moved in on the same file system), or a modification
    time older than its own birth (moved across file systems, extracted, copied with preserved
    times). None when it may be own."""
    if bt is None:
        return "birth time unknown"
    if since is None:
        return "no recorded provenance start"
    if bt < since - SLACK:
        return "older than the session's entry (pre-existing data moved in)"
    if st.st_mtime < bt - SLACK and not stat.S_ISLNK(st.st_mode):
        return "modification time older than its birth (moved across file systems or extracted)"
    return None


def inspect_tree(p, st, since, limit_s=30.0):
    """Walk p (no symlink follow) and return (reason, TreeInfo). reason is set when p or anything
    below it is foreign (see foreign_inode), a mount point, a linked worktree, a repository outside
    the temp roots or with linked worktrees, or when the walk did not finish in time (an
    incomplete walk proves nothing: refuse)."""
    info = TreeInfo()
    t_end = now() + limit_s
    m = mount_at_or_below(p) if stat.S_ISDIR(st.st_mode) else None
    if m:
        return "a mount point at or below it (%s)" % m, info
    stack = [(p, st)]
    while stack:
        if now() > t_end:
            return "tree too large to check in %.0fs (refused, nothing deleted)" % limit_s, info
        path, pst = stack.pop()
        info.count += 1
        info.newest = max(info.newest, pst.st_mtime, pst.st_ctime)
        if not (stat.S_ISDIR(pst.st_mode) or stat.S_ISREG(pst.st_mode) or stat.S_ISLNK(pst.st_mode)):
            info.special = info.special or path
        why = foreign_inode(pst, birth_time(path), since)
        if why:
            return "%s: %s" % (path, why), info
        if not stat.S_ISDIR(pst.st_mode):
            continue
        if pst.st_dev != st.st_dev:
            return "%s is another file system" % path, info
        g = os.path.join(path, ".git")
        if os.path.lexists(g):
            reason = _git_refusal(path, g)
            if reason:
                return reason, info
        try:
            it = list(os.scandir(path))
        except OSError as exc:
            return "%s cannot be read (%s)" % (path, exc.strerror or exc), info
        for de in it:
            try:
                cst = de.stat(follow_symlinks=False)
            except OSError as exc:
                return "%s cannot be read (%s)" % (de.path, exc.strerror or exc), info
            stack.append((de.path, cst))
    return None, info


def inspect_tree_structure(p, st, limit_s=30.0):
    """inspect_tree without the provenance (birth) checks: mounts, worktrees, repositories."""
    info = TreeInfo()
    if not stat.S_ISDIR(st.st_mode):
        return None, info
    m = mount_at_or_below(p)
    if m:
        return "a mount point at or below it (%s)" % m, info
    t_end = now() + limit_s
    stack = [p]
    while stack:
        if now() > t_end:
            return "tree too large to check in %.0fs (refused, nothing deleted)" % limit_s, info
        d = stack.pop()
        g = os.path.join(d, ".git")
        if os.path.lexists(g):
            reason = _git_refusal(d, g)
            if reason:
                return reason, info
        try:
            it = list(os.scandir(d))
        except OSError as exc:
            return "%s cannot be read (%s)" % (d, exc.strerror or exc), info
        for de in it:
            try:
                cst = de.stat(follow_symlinks=False)
            except OSError:
                return "%s cannot be read" % de.path, info
            info.newest = max(info.newest, cst.st_mtime, cst.st_ctime)
            if stat.S_ISDIR(cst.st_mode):
                if cst.st_dev != st.st_dev:
                    return "%s is another file system" % de.path, info
                if de.name != ".git":
                    stack.append(de.path)
            elif not (stat.S_ISREG(cst.st_mode) or stat.S_ISLNK(cst.st_mode)):
                info.special = info.special or de.path
    return None, info


def held_open(p, limit_s=5.0):
    """A pid whose cwd or an open file lies at or below p (from /proc; only readable processes),
    'unknown' when the scan did not finish, else None."""
    t_end = now() + limit_s
    try:
        pids = [n for n in os.listdir("/proc") if n.isdigit()]
    except OSError:
        return None
    me = str(os.getpid())
    for pid in pids:
        if pid == me:
            continue
        if now() > t_end:
            return "unknown"
        base = "/proc/" + pid
        links = [base + "/cwd"]
        try:
            links += [base + "/fd/" + f for f in os.listdir(base + "/fd")]
        except OSError:
            pass
        for ln in links:
            try:
                target = os.readlink(ln)
            except OSError:
                continue
            if target.endswith(" (deleted)"):
                target = target[:-10]
            if is_under(target, p):
                return pid
    return None


def git_tracked(p):
    """True when p (or anything below it) is tracked by git. False outside a work tree."""
    top, _ = git_top(p)
    if not top or p == top:
        return False
    rel = os.path.relpath(p, top)
    try:
        out = subprocess.run(["git", "-C", top, "ls-files", "-z", "--", rel], capture_output=True,
                             timeout=20)
    except (OSError, subprocess.SubprocessError):
        return True  # unsure: treat as tracked (refuse)
    if out.returncode != 0:
        # only "not a git repository" proves nothing is tracked; any other error refuses
        return b"not a git repository" not in out.stderr.lower()
    return bool(out.stdout.strip(b"\0"))


def session_bound_roots(sid):
    """Directories bound to the session by their name: the session TMPDIR and the Claude Code
    scratchpad of this session id. Their children are owned; the roots themselves are not deleted
    by own-rm."""
    roots = [session_tmp(sid)]
    pattern = "/tmp/claude-%d/*/%s/scratchpad" % (os.getuid(), sid)
    extra = os.environ.get("CREDO_CLEANUP_SCRATCH_GLOB")
    if extra:
        pattern = extra.replace("{sid}", sid)
    roots += [os.path.realpath(p) for p in glob.glob(pattern)]
    return roots


def same_birth(e, path):
    """False when the entry recorded a birth time and the path now has a different one (inode
    reuse: the path was deleted and something new got the same inode number)."""
    rec = e.get("btime")
    if rec is None:
        return True
    cur = birth_time(path)
    return cur is not None and abs(cur - rec) < 0.01


def owned_entry(p, st, entries, sid):
    """(ok, entry_or_None, reason, since). p is a real target path, st its lstat. since is the
    birth time every inode below the target must have at least (provenance start), or None
    when unknown (then no directory content can be proven own)."""
    for root in session_bound_roots(sid):
        if p != root and is_under(p, root):
            return True, None, "session-bound (%s)" % root, birth_time(root)
    e = entries.get(p)
    if e is not None:
        if e.get("dev") != st.st_dev or e.get("ino") != st.st_ino or not same_birth(e, p):
            return False, e, "replaced since it was recorded (dev/inode/birth differ)", None
        return True, e, "ledger entry", e.get("btime")
    # below a ledger directory entry whose inode still matches
    best = None
    for ep, e in entries.items():
        if e.get("type") != "dir" or not is_under(p, ep) or p == ep:
            continue
        if best is None or len(ep) > len(best[0]):
            best = (ep, e)
    if best is None:
        return False, None, "not created by this session (not in its ledger)", None
    ep, e = best
    try:
        est = os.lstat(ep)
    except OSError:
        return False, e, "its recorded parent %s is gone" % ep, None
    if (est.st_dev != e.get("dev") or est.st_ino != e.get("ino") or not stat.S_ISDIR(est.st_mode)
            or not same_birth(e, ep)):
        return False, e, "its recorded parent %s was replaced" % ep, None
    return True, e, "below ledger entry %s" % ep, e.get("btime")


# --------------------------------------------------------------------------- delete


_DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)


def open_dir_nofollow(path):
    """fd of directory path, opened component by component without following any symlink."""
    fd = os.open("/", _DIR_FLAGS)
    try:
        for comp in [c for c in path.split("/") if c]:
            nfd = os.open(comp, _DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = nfd
    except OSError:
        os.close(fd)
        raise
    return fd


def _rm_contents(fd, path, top_dev, since, errors):
    """Delete everything inside the open directory fd (path is only for messages and the mount
    check). Every inode is checked again right before its removal; a foreign one stays."""
    try:
        names = [de.name for de in os.scandir(fd)]
    except OSError as exc:
        errors.append("%s: %s" % (path, exc.strerror or exc))
        return
    for name in names:
        cpath = os.path.join(path, name)
        try:
            st = os.stat(name, dir_fd=fd, follow_symlinks=False)
        except OSError as exc:
            errors.append("%s: %s" % (cpath, exc.strerror or exc))
            continue
        if since is not False:
            why = foreign_inode(st, birth_time(name, dir_fd=fd), since)
            if why:
                errors.append("%s: %s, left alone" % (cpath, why))
                continue
        if stat.S_ISDIR(st.st_mode):
            if st.st_dev != top_dev or cpath in mount_points():
                errors.append("%s: other file system inside, left alone" % cpath)
                continue
            try:
                cfd = os.open(name, _DIR_FLAGS, dir_fd=fd)
            except OSError as exc:
                errors.append("%s: %s" % (cpath, exc.strerror or exc))
                continue
            try:
                cst = os.fstat(cfd)
                if (cst.st_dev, cst.st_ino) != (st.st_dev, st.st_ino):
                    errors.append("%s: changed during the delete, left alone" % cpath)
                    continue
                _rm_contents(cfd, cpath, top_dev, since, errors)
            finally:
                os.close(cfd)
            try:
                os.rmdir(name, dir_fd=fd)
            except OSError as exc:
                errors.append("%s: %s" % (cpath, exc.strerror or exc))
        else:
            try:
                os.unlink(name, dir_fd=fd)
            except OSError as exc:
                errors.append("%s: %s" % (cpath, exc.strerror or exc))


def delete_path(p, st, since=False):
    """Remove p, which must still be the inode st (dev+ino) that was checked. Works on file
    descriptors opened without following symlinks, so a path component swapped for a symlink
    after the check fails instead of redirecting the delete. since: the provenance start that
    every inode is checked against again right before its removal (False = no birth check,
    for owner-approved keep entries). Returns error strings (empty = removed)."""
    errors = []
    parent, name = os.path.split(p)
    try:
        pfd = open_dir_nofollow(parent)
    except OSError as exc:
        return ["%s: parent cannot be opened without following links (%s)" % (p, exc.strerror or exc)]
    try:
        try:
            cur = os.stat(name, dir_fd=pfd, follow_symlinks=False)
        except OSError as exc:
            return ["%s: %s" % (p, exc.strerror or exc)]
        if (cur.st_dev, cur.st_ino) != (st.st_dev, st.st_ino):
            return ["%s: replaced since the check, left alone" % p]
        if stat.S_ISDIR(cur.st_mode):
            try:
                fd = os.open(name, _DIR_FLAGS, dir_fd=pfd)
            except OSError as exc:
                return ["%s: %s" % (p, exc.strerror or exc)]
            try:
                fst = os.fstat(fd)
                if (fst.st_dev, fst.st_ino) != (st.st_dev, st.st_ino):
                    return ["%s: replaced since the check, left alone" % p]
                _rm_contents(fd, p, st.st_dev, since, errors)
            finally:
                os.close(fd)
            if not errors:
                try:
                    os.rmdir(name, dir_fd=pfd)
                except OSError as exc:
                    errors.append("%s: %s" % (p, exc.strerror or exc))
        else:
            try:
                os.unlink(name, dir_fd=pfd)
            except OSError as exc:
                errors.append("%s: %s" % (p, exc.strerror or exc))
    finally:
        os.close(pfd)
    return errors


def dir_size(path, limit_s=10.0):
    """Bytes below path (no symlink follow, same device), best effort within limit_s."""
    total = 0
    t_end = now() + limit_s
    stack = [path]
    try:
        top_dev = os.lstat(path).st_dev
    except OSError:
        return None
    while stack:
        if now() > t_end:
            return None
        d = stack.pop()
        try:
            for de in os.scandir(d):
                try:
                    st = de.stat(follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISDIR(st.st_mode):
                    if st.st_dev == top_dev:
                        stack.append(de.path)
                else:
                    total += st.st_blocks * 512
        except OSError:
            continue
    return total


def detach(argv, logfile=None):
    """Start argv detached (own session, no stdin, output to logfile or /dev/null)."""
    out = open(logfile, "a") if logfile else subprocess.DEVNULL
    try:
        subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=out, stderr=out,
                         start_new_session=True, close_fds=True)
    finally:
        if logfile:
            out.close()


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
