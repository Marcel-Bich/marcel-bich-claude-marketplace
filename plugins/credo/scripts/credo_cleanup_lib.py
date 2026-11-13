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


def birth_time(path):
    """Birth time of path (no symlink follow) in seconds, or None when unknown."""
    fn = _statx_fn()
    if fn is None:
        return None
    buf = ctypes.create_string_buffer(256)
    rc = fn(_AT_FDCWD, os.fsencode(path), _AT_SYMLINK_NOFOLLOW, _STATX_BTIME, buf)
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
    if st is not None and stat.S_ISDIR(st.st_mode) and os.path.ismount(p):
        return "a mount point"
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


def tree_refusal(p, st, limit_s=30.0):
    """Walk the tree below directory p (no symlink follow) and return a refusal reason for a
    mount point, a linked worktree, a repository outside the temp roots or one with linked
    worktrees anywhere inside; None when the whole tree may go."""
    if not stat.S_ISDIR(st.st_mode):
        return None
    t_end = now() + limit_s
    stack = [p]
    while stack:
        if now() > t_end:
            return "tree too large to check in time (checked for %.0fs)" % limit_s
        d = stack.pop()
        g = os.path.join(d, ".git")
        if os.path.lexists(g):
            reason = _git_refusal(d, g)
            if reason:
                return reason
        try:
            it = list(os.scandir(d))
        except OSError:
            continue
        for de in it:
            try:
                cst = de.stat(follow_symlinks=False)
            except OSError:
                continue
            if stat.S_ISDIR(cst.st_mode):
                if cst.st_dev != st.st_dev or os.path.ismount(de.path):
                    return "%s is a mount point / other file system inside" % de.path
                if de.name == ".git":
                    continue
                stack.append(de.path)
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
        return False
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


def owned_entry(p, st, entries, sid):
    """(ok, entry_or_None, reason). p is a real target path, st its lstat."""
    for root in session_bound_roots(sid):
        if p != root and is_under(p, root):
            return True, None, "session-bound (%s)" % root
    e = entries.get(p)
    if e is not None:
        if e.get("dev") != st.st_dev or e.get("ino") != st.st_ino:
            return False, e, "replaced since it was recorded (dev/inode differ)"
        return True, e, "ledger entry"
    # below a ledger directory entry whose inode still matches
    best = None
    for ep, e in entries.items():
        if e.get("type") != "dir" or not is_under(p, ep) or p == ep:
            continue
        if best is None or len(ep) > len(best[0]):
            best = (ep, e)
    if best is None:
        return False, None, "not created by this session (not in its ledger)"
    ep, e = best
    try:
        est = os.lstat(ep)
    except OSError:
        return False, e, "its recorded parent %s is gone" % ep
    if est.st_dev != e.get("dev") or est.st_ino != e.get("ino") or not stat.S_ISDIR(est.st_mode):
        return False, e, "its recorded parent %s was replaced" % ep
    return True, e, "below ledger entry %s" % ep


# --------------------------------------------------------------------------- delete


def safe_rmtree(path, top_dev, errors):
    """Delete a directory tree without following symlinks and without crossing into another
    file system (a mount inside is left alone and reported)."""
    try:
        it = list(os.scandir(path))
    except OSError as exc:
        errors.append("%s: %s" % (path, exc.strerror or exc))
        return
    for de in it:
        try:
            st = de.stat(follow_symlinks=False)
        except OSError as exc:
            errors.append("%s: %s" % (de.path, exc.strerror or exc))
            continue
        if stat.S_ISDIR(st.st_mode):
            if st.st_dev != top_dev or os.path.ismount(de.path):
                errors.append("%s: other file system inside, left alone" % de.path)
                continue
            safe_rmtree(de.path, top_dev, errors)
        else:
            try:
                os.unlink(de.path)
            except OSError as exc:
                errors.append("%s: %s" % (de.path, exc.strerror or exc))
    try:
        os.rmdir(path)
    except OSError as exc:
        errors.append("%s: %s" % (path, exc.strerror or exc))


def delete_path(p, st):
    """Remove p (lstat st). Returns a list of error strings (empty = removed)."""
    errors = []
    if stat.S_ISDIR(st.st_mode):
        safe_rmtree(p, st.st_dev, errors)
    else:
        try:
            os.unlink(p)
        except OSError as exc:
            errors.append("%s: %s" % (p, exc.strerror or exc))
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
