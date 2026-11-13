#!/usr/bin/env python3
"""credo-ledger.py - the hook side of the provenance ledger (#174).

Modes (hook input JSON on stdin):
  pre             PreToolUse  Bash|Write|Edit|MultiEdit|NotebookEdit
                  - denies tool calls that write the ledger / keep list (only hooks and the
                    cleanup helper write them)
                  - denies writes into a real .credo/ of a linked worktree (.credo belongs to
                    the main checkout; a worktree only has a symlink to it)
                  - sets the time mark of this call (one small file)
  post            PostToolUse (same matcher)
                  - Write/Edit: records the file (or the topmost new directory) when it did
                    not exist before the call
                  - Bash: records every entry born during the call at depth <= 2 of the temp
                    roots (/tmp, /dev/shm, the repo's .credo/sandbox-tmp, <main>-worktrees);
                    $HOME (depth 2) is scanned by a detached background job
  session-start   SessionStart: creates the session TMPDIR, exports TMPDIR and CREDO_CLEANUP
                  through $CLAUDE_ENV_FILE (when Claude Code provides it), starts the detached
                  maintenance (sweep, merged worktrees, Playwright prune once a day)
  home-scan <job> the background $HOME scan (started by post)

Evidence of an entry: "write" (Write/Edit tool), "command" (the Bash command text names the
path or its name), "window" (only born during the call). An entry born while another session
had a tool call running is marked "ambiguous" with those session ids; the helper refuses an
ambiguous window-only entry.

Never blocks: every error exits 0 without output (the deny cases are intentional). Off with
CREDO_LEDGER=0 or the local config key cleanup.enabled: false.
"""
import json
import os
import re
import shlex
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import credo_cleanup_lib as L  # noqa: E402

WRITE_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")
MARK_STALE_S = 6 * 3600
WINDOW_KEEP_S = 3600


def deny(reason):
    L.emit({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                   "permissionDecisionReason": "credo cleanup: " + reason}})


def disabled():
    if os.environ.get("CREDO_LEDGER") == "0":
        return True
    return os.path.exists(os.path.join(L.state_dir(), "disabled"))


# --------------------------------------------------------------------------- guards


def protected_forms():
    """Text forms of the hook-only paths as they may appear in a command."""
    h = L.home()
    forms = set()
    for p in (L.state_dir(), L.keep_list_path()):
        forms.add(p)
        if L.is_under(p, h):
            rest = p[len(h):]
            forms.update({"~" + rest, "$HOME" + rest, "${HOME}" + rest})
    return forms


def credo_worktree_violation(path):
    """Main-checkout path suggestion when path is under a real .credo/ of a linked worktree."""
    ab = os.path.abspath(path)
    idx = ab.find("/.credo/")
    if idx < 0:
        if ab.endswith("/.credo"):
            idx = len(ab) - len("/.credo")
        else:
            return None
    wt = ab[:idx] or "/"
    if not os.path.isfile(os.path.join(wt, ".git")):
        return None  # not a linked worktree
    link = os.path.join(wt, ".credo")
    if os.path.islink(link):
        return None  # the setup symlink into the main checkout
    main = L.main_checkout_of(wt)
    rest = ab[idx + len("/.credo"):]
    return (main + "/.credo" + rest) if main else "the main checkout's .credo/"


REDIR_RE = re.compile(r"""(?:>>?|\btee\s+(?:-a\s+)?)\s*["']?([^\s"'|;&<>()]*\.credo(?:/[^\s"'|;&<>()]*)?)""")


def guard(data):
    tool = data.get("tool_name") or ""
    ti = data.get("tool_input") or {}
    cwd = data.get("cwd") or os.getcwd()
    if tool in WRITE_TOOLS:
        fp = ti.get("file_path") or ti.get("notebook_path")
        if not isinstance(fp, str) or not fp:
            return None
        ab = os.path.join(cwd, os.path.expanduser(fp))
        p = L.real_target(ab) or ab
        if L.is_under(p, L.state_dir()) or p == L.keep_list_path():
            return ("the provenance ledger and the keep list are written by credo hooks and "
                    "credo-cleanup.py only; read them with credo-cleanup.py report")
        sugg = credo_worktree_violation(ab)
        if sugg:
            return (".credo/ never holds real files in a linked worktree; write into the main "
                    "checkout instead: %s" % sugg)
        return None
    if tool == "Bash":
        cmd = ti.get("command")
        if not isinstance(cmd, str):
            return None
        hit = [f for f in protected_forms() if f in cmd]
        # cd into the state tree plus a relative path (best effort)
        if not hit and ".local/state" in cmd and re.search(r"(^|[\s/'\"])cleanup(/|[\s'\"]|$)", cmd):
            hit = [".local/state ... cleanup"]
        if not hit and ".local/share" in cmd and "keep-list" in cmd:
            hit = [".local/share ... keep-list"]
        for f in hit:
            return ("the command names the provenance ledger or the keep list (%s), which only "
                    "credo hooks and credo-cleanup.py write; use credo-cleanup.py report to read "
                    "it" % f)
        for m in REDIR_RE.finditer(cmd):
            target = os.path.join(cwd, os.path.expanduser(m.group(1)))
            sugg = credo_worktree_violation(target)
            if sugg:
                return (".credo/ never holds real files in a linked worktree; redirect into the "
                        "main checkout instead: %s" % sugg)
    return None


# --------------------------------------------------------------------------- marks


def marks_dir(sid):
    return os.path.join(L.state_dir(), "marks", sid)


def top_missing(path):
    """The topmost ancestor of path (or path) that does not exist yet, else None."""
    p = os.path.abspath(path)
    if os.path.lexists(p):
        return None
    top = p
    while True:
        parent = os.path.dirname(top)
        if parent == top or os.path.lexists(parent):
            return top
        top = parent


def pre(data):
    reason = guard(data)
    if reason:
        deny(reason)
        return
    sid = data.get("session_id") or ""
    if not L.valid_sid(sid):
        return
    tool = data.get("tool_name") or ""
    tuid = re.sub(r"[^A-Za-z0-9_-]", "", str(data.get("tool_use_id") or "")) or "call"
    info = {}
    if tool in WRITE_TOOLS:
        ti = data.get("tool_input") or {}
        fp = ti.get("file_path") or ti.get("notebook_path")
        if isinstance(fp, str) and fp:
            new = top_missing(os.path.join(data.get("cwd") or os.getcwd(), os.path.expanduser(fp)))
            if not new:
                return  # an existing file: nothing to record, no mark needed
            info["new"] = new
    elif tool == "Bash":
        st = L.session_tmp(sid)
        if os.path.isdir(L.tmp_base()) and not os.path.isdir(st):
            os.makedirs(st, mode=0o700, exist_ok=True)  # TMPDIR of this session vanished: recreate
    d = marks_dir(sid)
    L.ensure_dir(d)
    with open(os.path.join(d, "%.6f_%s" % (time.time(), tuid)), "w", encoding="utf-8") as fh:
        json.dump(info, fh)


def take_mark(sid, tuid):
    d = marks_dir(sid)
    try:
        names = os.listdir(d)
    except OSError:
        return None, None
    best = None
    for n in names:
        t0s, _, mid = n.partition("_")
        if mid == tuid:
            best = n
            break
    if best is None:
        return None, None
    path = os.path.join(d, best)
    try:
        with open(path, encoding="utf-8") as fh:
            info = json.load(fh)
    except (OSError, ValueError):
        info = {}
    try:
        os.unlink(path)
    except OSError:
        pass
    try:
        return float(best.partition("_")[0]), info
    except ValueError:
        return None, None


def other_windows(sid, t_now):
    """[(sid, t0, t1)] of other sessions' open marks and recently closed windows."""
    out = []
    base = os.path.join(L.state_dir(), "marks")
    try:
        others = [n for n in os.listdir(base) if n != sid]
    except OSError:
        others = []
    for o in others:
        try:
            for n in os.listdir(os.path.join(base, o)):
                try:
                    t0 = float(n.partition("_")[0])
                except ValueError:
                    continue
                if t_now - t0 < MARK_STALE_S:
                    out.append((o, t0, t_now + 1))
        except OSError:
            continue
    wl = os.path.join(L.state_dir(), "windows.log")
    try:
        with open(wl, "rb") as fh:
            fh.seek(0, 2)
            size = fh.tell()
            fh.seek(max(0, size - 65536))
            lines = fh.read().decode("utf-8", "replace").splitlines()
        if size > 65536:
            lines = lines[1:]  # the first line may be cut
    except OSError:
        lines = []
    for line in lines:
        parts = line.split()
        if len(parts) == 3 and parts[0] != sid:
            try:
                out.append((parts[0], float(parts[1]), float(parts[2])))
            except ValueError:
                continue
    return out


def close_window(sid, t0, t1):
    wl = os.path.join(L.state_dir(), "windows.log")
    try:
        with L.Locked(wl):
            if os.path.exists(wl) and os.path.getsize(wl) > 262144:
                with open(wl, encoding="utf-8") as fh:
                    keep = [ln for ln in fh.read().splitlines()
                            if len(ln.split()) == 3 and float(ln.split()[2]) > t1 - WINDOW_KEEP_S]
                with open(wl, "w", encoding="utf-8") as fh:
                    fh.write("".join(k + "\n" for k in keep))
            with open(wl, "a", encoding="utf-8") as fh:
                fh.write("%s %.6f %.6f\n" % (sid, t0, t1))
    except (OSError, ValueError):
        pass


# --------------------------------------------------------------------------- scanning


def excluded(path):
    if os.path.basename(path) == ".git" or L.in_claude_profile(path):
        return True
    for root in (L.state_dir(), L.keep_root(), L.tmp_base(), "/tmp/claude-%d" % os.getuid()):
        if L.is_under(path, root):
            return True
    return False


def scan_root(root, t0, t1, home_mode=False):
    """[(path, lstat, btime)] of entries born in [t0, t1] at depth 1..2 below root. A depth-1
    entry born in the window is reported alone (its children are covered by it)."""
    found = []
    uid = os.getuid()

    def born(path, st):
        bt = L.birth_time(path)
        return bt, (bt is not None and t0 <= bt <= t1 + 1)

    try:
        root_dev = os.lstat(root).st_dev
        top = list(os.scandir(root))
    except OSError:
        return found
    mounts = L.mount_points()
    for de in top:
        if excluded(de.path) or (home_mode and de.name.startswith(".claude")):
            continue
        try:
            st = de.stat(follow_symlinks=False)
        except OSError:
            continue
        if st.st_uid != uid or st.st_dev != root_dev or de.path in mounts:
            continue
        bt, new = born(de.path, st)
        if new:
            found.append((de.path, st, bt))
            continue
        if not de.is_dir(follow_symlinks=False) or st.st_mtime < t0:
            continue  # no new child: creating an entry updates its parent's mtime
        if home_mode and de.name.startswith("."):
            continue  # caches and tool state below dot dirs of the home are not scanned
        try:
            kids = list(os.scandir(de.path))
        except OSError:
            continue
        for k in kids:
            if excluded(k.path):
                continue
            try:
                kst = k.stat(follow_symlinks=False)
            except OSError:
                continue
            if kst.st_uid != uid or kst.st_dev != root_dev or k.path in mounts:
                continue
            kbt, knew = born(k.path, kst)
            if knew:
                found.append((k.path, kst, kbt))
    return found


def temp_scan_roots(cwd):
    env = os.environ.get("CREDO_CLEANUP_ROOTS")
    if env is not None:
        return [os.path.realpath(r) for r in env.split(":") if r]
    roots = ["/tmp", "/dev/shm"]
    top, linked = L.git_top(os.path.realpath(cwd)) if cwd else (None, False)
    if top:
        main = (L.main_checkout_of(top) if linked else top) or top
        sb = os.path.join(main, ".credo", "sandbox-tmp")
        if os.path.isdir(sb):
            roots.append(os.path.realpath(sb))
        wtr = main.rstrip("/") + "-worktrees"
        if os.path.isdir(wtr):
            roots.append(os.path.realpath(wtr))
    return roots


def command_tokens(cmd):
    try:
        toks = shlex.split(cmd, comments=False, posix=True)
    except ValueError:
        toks = cmd.split()
    out = []
    for t in toks:
        t = t.lstrip("<>&|;(0123456789") if re.match(r"^[0-9]*[<>]", t) else t
        t = t.rstrip(";&|)")
        if t:
            out.append(t)
    return out


def evidence_for(path, cmd, cwd=""):
    """"command" only when a whole shell token of the command is the full path (absolute, or
    relative to the call's cwd); a name that merely appears inside the text is no evidence."""
    if not cmd:
        return "window"
    for t in command_tokens(cmd):
        if "$" in t or "`" in t:
            continue
        cand = os.path.expanduser(t)
        if not os.path.isabs(cand):
            if not cwd:
                continue
            cand = os.path.join(cwd, cand)
        if os.path.normpath(cand).rstrip("/") == path.rstrip("/"):
            return "command"
    return "window"


def ambiguous_for(btime, windows):
    if btime is None:
        return []
    return sorted({s for s, a, b in windows if a <= btime <= b})


def build_records(found, sid, tool, cmd, kind, agent_id, windows, cwd=""):
    recs = []
    for path, st, bt in found:
        ev = evidence_for(path, cmd, cwd)
        amb = ambiguous_for(bt, windows) if ev == "window" else []
        recs.append(L.make_record(path, st, tool, ev, kind, agent_id, amb, bt))
    return recs


def post(data):
    sid = data.get("session_id") or ""
    if not L.valid_sid(sid):
        return
    tool = data.get("tool_name") or ""
    tuid = re.sub(r"[^A-Za-z0-9_-]", "", str(data.get("tool_use_id") or "")) or "call"
    t0, info = take_mark(sid, tuid)
    if t0 is None:
        return
    t1 = time.time()
    agent_id = data.get("agent_id")
    cwd = data.get("cwd") or os.getcwd()
    close_window(sid, t0, t1)
    if tool in WRITE_TOOLS:
        new = (info or {}).get("new")
        if new and os.path.lexists(new):
            p = L.real_target(new) or new
            if L.in_claude_profile(p) or L.is_under(p, L.state_dir()):
                return  # ~/.claude*/** is never recorded (and never deleted by the helper)
            st = os.lstat(p)
            L.append_ledger(sid, [L.make_record(p, st, tool, "write", "write", agent_id, None,
                                                L.birth_time(p))])
        return
    if tool != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    windows = other_windows(sid, t1)
    recs = []
    for root in temp_scan_roots(cwd):
        recs += build_records(scan_root(root, t0, t1), sid, tool, cmd, "temp", agent_id, windows, cwd)
    L.append_ledger(sid, recs)
    home_root = os.environ.get("CREDO_CLEANUP_HOME_ROOT", L.home())
    if home_root == "none" or not home_root:
        return
    job = {"sid": sid, "t0": t0, "t1": t1, "cmd": cmd[:20000], "agent_id": agent_id, "cwd": cwd,
           "root": home_root, "windows": windows}
    if os.environ.get("CREDO_CLEANUP_SYNC") == "1":
        home_scan_job(job)
        return
    jd = os.path.join(L.state_dir(), "jobs")
    L.ensure_dir(jd)
    jp = os.path.join(jd, "%s_%s.json" % (sid, tuid))
    with open(jp, "w", encoding="utf-8") as fh:
        json.dump(job, fh)
    L.detach([sys.executable, "-I", os.path.abspath(__file__), "home-scan", jp])


def home_scan_job(job):
    root = os.path.realpath(job["root"])
    found = scan_root(root, job["t0"], job["t1"], home_mode=True)
    # temp roots inside the home are scanned already
    found = [f for f in found if not any(L.is_under(f[0], r) for r in temp_scan_roots(""))]
    recs = build_records(found, job["sid"], "Bash", job.get("cmd") or "", "home",
                         job.get("agent_id"), [tuple(w) for w in job.get("windows") or []],
                         job.get("cwd") or "")
    L.append_ledger(job["sid"], recs)


def home_scan(jp):
    try:
        with open(jp, encoding="utf-8") as fh:
            job = json.load(fh)
    finally:
        try:
            os.unlink(jp)
        except OSError:
            pass
    home_scan_job(job)


# --------------------------------------------------------------------------- session start


def session_start(data):
    sid = data.get("session_id") or ""
    if not L.valid_sid(sid):
        return
    cfg = L.local_config() if os.environ.get("CREDO_CLEANUP_NO_CONFIG") != "1" else {}
    flag = os.path.join(L.state_dir(), "disabled")
    L.ensure_dir(L.state_dir())
    if cfg.get("enabled") is False:
        open(flag, "a").close()
        return
    if os.path.exists(flag):
        os.unlink(flag)
    base = os.path.abspath(os.environ.get("CREDO_TMP_BASE") or "/tmp/credo-tmp-%d" % os.getuid())
    if not os.path.lexists(base):
        os.makedirs(base, mode=0o700, exist_ok=True)
        os.chmod(base, 0o700)
    st = os.lstat(base)
    if os.path.islink(base) or st.st_uid != os.getuid() or (st.st_mode & 0o077):
        L.log("session-start: %s is not a private dir of this user, no session TMPDIR" % base)
        return
    stmp = L.session_tmp(sid)
    os.makedirs(stmp, mode=0o700, exist_ok=True)
    helper = os.path.join(HERE, "credo-cleanup.py")
    envf = os.environ.get("CLAUDE_ENV_FILE")
    lines = ["export CREDO_CLEANUP=%s" % shell_quote(helper)]
    if cfg.get("session_tmpdir") is not False:
        lines.append("export TMPDIR=%s" % shell_quote(stmp))
    wrote = False
    if envf:
        try:
            try:
                with open(envf, encoding="utf-8") as fh:
                    have = fh.read()
            except OSError:
                have = ""
            add = [ln for ln in lines if ln not in have]
            if add:
                with open(envf, "a", encoding="utf-8") as fh:
                    fh.write("".join(ln + "\n" for ln in add))
            wrote = True
        except OSError as exc:
            L.log("session-start: cannot write CLAUDE_ENV_FILE: %s" % exc)
    if os.environ.get("CREDO_CLEANUP_NO_MAINTENANCE") != "1":
        L.detach([sys.executable, "-I", helper, "maintenance", "--cwd", data.get("cwd") or os.getcwd()],
                 os.path.join(L.state_dir(), "maintenance.log"))
    if wrote or envf is None:
        sys.stdout.write(
            "[credo-cleanup] Own temp dir of this session: %s%s. Delete what this session or its "
            "subagents created, without a prompt, only through: python3 %s own-rm <path>... "
            "(ledger-verified; write the helper path literally, never rm -rf outside the cwd); see what "
            "is yours: python3 %s report\n" % (stmp, " (exported as $TMPDIR)" if wrote else "", helper, helper))


def shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "home-scan" and len(sys.argv) > 2:
        try:
            home_scan(sys.argv[2])
        except Exception as exc:  # noqa: BLE001 - background job: log, never raise
            L.log("home-scan failed: %r" % exc)
        return
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        return
    if not isinstance(data, dict):
        return
    try:
        if mode == "session-start":
            session_start(data)
            return
        if disabled():
            return
        if mode == "pre":
            pre(data)
        elif mode == "post":
            post(data)
    except Exception as exc:  # noqa: BLE001 - a hook never blocks on its own error
        L.log("%s failed: %r" % (mode, exc))


if __name__ == "__main__":
    main()
    sys.exit(0)
