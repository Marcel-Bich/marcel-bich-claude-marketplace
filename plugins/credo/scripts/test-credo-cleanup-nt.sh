#!/bin/bash
# nt-simulation tests for the provenance ledger, the cleanup helper and process identity on
# native Windows (#194). Runs on Linux: it flips credo_platform.IS_NT / credo_cleanup_lib.NT and
# replaces the ctypes-backed Windows facts (known folders, owner SID, volume type, reparse
# attribute, process table, creation times, image paths, command lines) with fixtures. The real
# Windows behaviour (handles, junctions, pinning, sharing violations) is checked live under Git
# Bash with a real python.exe; see the item / changelog. Every path lives in a mktemp dir.
# Usage: bash test-credo-cleanup-nt.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-cleanup-nt-test.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT

if [ "$(stat -c %W "$TMP" 2>/dev/null || echo 0)" = "0" ]; then
    echo "SKIP: no file birth time on this file system (statx btime) - the fixtures need it"
    exit 0
fi

cat > "$TMP/nt_sim.py" <<'EOF'
import contextlib
import importlib.util
import io
import json
import os
import runpy
import subprocess
import sys
import time

SD, T = sys.argv[1], sys.argv[2]
sys.path.insert(0, SD)
import credo_platform as P  # noqa: E402
import credo_cleanup_lib as L  # noqa: E402

PASS = FAIL = 0


def check(name, expected, actual):
    global PASS, FAIL
    if expected == actual:
        PASS += 1
    else:
        FAIL += 1
        print("FAIL %s\n  expected: %r\n  actual:   %r" % (name, expected, actual))


def contains(name, needle, hay):
    global PASS, FAIL
    if needle in hay:
        PASS += 1
    else:
        FAIL += 1
        print("FAIL %s\n  missing: %r\n  in:      %r" % (name, needle, hay))


def load(name, fn):
    spec = importlib.util.spec_from_file_location(name, os.path.join(SD, fn))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def posix_birth(p):
    L.NT = False
    try:
        return L.birth_time(p)
    finally:
        L.NT = True


# ---------------------------------------------------------------- the simulated Windows facts
P.IS_NT = True
L.NT = True
REPARSE = set()                     # (dev, ino) of simulated junctions / reparse points
BIRTH = {}                          # (dev, ino) -> statx birth (Linux has no st_birthtime)
L.attrs = lambda st: L.FA_REPARSE_POINT if (st.st_dev, st.st_ino) in REPARSE else 0


def reg(path):
    """Register the birth times of path and everything below it."""
    for d, dirs, files in os.walk(path):
        for n in [d] + [os.path.join(d, x) for x in dirs + files]:
            st = os.lstat(n)
            BIRTH[(st.st_dev, st.st_ino)] = posix_birth(n)


def junction(path):
    os.makedirs(path, exist_ok=True)
    st = os.lstat(path)
    REPARSE.add((st.st_dev, st.st_ino))


L.birth_of = lambda st: BIRTH.get((st.st_dev, st.st_ino))

FH = os.path.join(T, "home")
LA = os.path.join(FH, "AppData", "Local")
TEMP = os.path.join(LA, "Temp")
CTMP = os.path.join(TEMP, "credo-tmp")
SA = "aaaaaaaa-0000-4000-8000-000000000001"
SB = "bbbbbbbb-0000-4000-8000-000000000002"
ST = os.path.join(CTMP, SA)
PROF = os.path.join(FH, ".claude-x")
for d in (ST, os.path.join(PROF, "sessions"), os.path.join(PROF, "projects", "-fix"),
          os.path.join(FH, "AppData", "Roaming"), os.path.join(T, "pf"), os.path.join(T, "win"),
          os.path.join(T, "outside")):
    os.makedirs(d, exist_ok=True)
L.OVERRIDES.update({
    "home": FH, "state": os.path.join(T, "state"), "keep_root": os.path.join(T, "keep"),
    "tmp_base": CTMP, "scratch_base": os.path.join(TEMP, "claude"), "profiles": [PROF],
    "nt_folders": {"profile": FH, "local_appdata": LA,
                   "roaming_appdata": os.path.join(FH, "AppData", "Roaming"),
                   "windows": os.path.join(T, "win"), "program_files": os.path.join(T, "pf"),
                   "program_files_x86": os.path.join(T, "pf86"),
                   "program_data": os.path.join(T, "pd")},
    "nt_owner_is_me": True, "nt_volume_ok": True, "explicit_idle_s": 0, "idle_minutes": 0,
    "no_maintenance": True, "home_root": "none", "sync": True,
})
L.local_config = lambda timeout=3: {}

# process table: this process -> bash (50) -> claude (10); pid 1 is younger than 10
ME = os.getpid()
TABLE = {ME: (50, "python.exe"), 50: (10, "bash.exe"), 10: (1, "claude.exe"), 1: (0, "x.exe")}
STARTS = {ME: "300", 50: "200", 10: "100", 1: "500"}
EXES = {10: "C:\\Users\\u\\.local\\bin\\claude.exe"}
CMDS = {}
P.proc_table = lambda: dict(TABLE)
P.proc_start = lambda pid: STARTS.get(int(pid), "") if str(pid).lstrip("-").isdigit() else ""
P.proc_exe = lambda pid: EXES.get(pid, "")
P.proc_cmdline = lambda pid: list(CMDS.get(pid, []))
P.pid_alive = lambda pid: bool(STARTS.get(int(pid))) if str(pid).isdigit() else False

# ---------------------------------------------------------------- 1. platform: parent chain
check("ancestors stop at a parent younger than the child", [ME, 50, 10], P.ancestors(ME))
check("proc_ppid: unknown parent start ends the chain", 0, P.proc_ppid(1))
check("proc_alive with the same start", True, P.proc_alive(10, "100"))
check("proc_alive with another start (pid reused)", False, P.proc_alive(10, "999"))
check("filetime_to_epoch", 0.0, P.filetime_to_epoch(116444736000000000))

# ---------------------------------------------------------------- 2. path rules
check("temp dir inside the home counts as temp", True, L.in_temp_root(os.path.join(TEMP, "x")))
check("the temp root itself is no temp entry", False, L.in_temp_root(TEMP))
contains("temp root itself is denied", "per-user AppData or temp root", L.hard_refusal(TEMP) or "")
contains("Program Files tree is denied", "system path", L.hard_refusal(os.path.join(T, "pf", "x")) or "")
contains("drive root level is denied", "root-level", L.hard_refusal("/x") or "")
L.OVERRIDES["nt_volume_ok"] = False
contains("non-local / non-NTFS volume is report-only", "NTFS/ReFS", L.hard_refusal(os.path.join(ST, "x")) or "")
L.OVERRIDES["nt_volume_ok"] = True
check("tmp base below LocalAppData is private", True, L.private_dir(CTMP))
check("a dir outside LocalAppData is not private (0700 stand-in)", False, L.private_dir(os.path.join(T, "outside")))
L.OVERRIDES["nt_owner_is_me"] = False
check("a dir owned by somebody else is not private", False, L.private_dir(CTMP))
L.OVERRIDES["nt_owner_is_me"] = True
check("held_open has no Windows equivalent", "unsupported", L.held_open(ST))
junction(os.path.join(T, "j1"))
check("a junction is link-like", True, L.link_like(os.path.join(T, "j1")))
check("a junction records as reparse", "reparse", L.kind_of(os.lstat(os.path.join(T, "j1"))))

# ---------------------------------------------------------------- 3. session binding (pid reuse)
desc = os.path.join(PROF, "sessions", "10.json")
json.dump({"pid": 10, "sessionId": SA, "procStart": "100"}, open(desc, "w"))
check("bound: descriptor pid is an ancestor with the same start", (True, None), L.sid_bound(SA))
json.dump({"pid": 10, "sessionId": SA, "procStart": "999"}, open(desc, "w"))
check("not bound: descriptor start differs (pid reused)", False, L.sid_bound(SA)[0])
json.dump({"pid": 10, "sessionId": SA, "procStart": "100"}, open(desc, "w"))

# ---------------------------------------------------------------- 4. the helper on Windows
os.environ["CLAUDE_CODE_SESSION_ID"] = SA
CL = load("credo_cleanup_nt", "credo-cleanup.py")


def helper(*argv):
    buf = io.StringIO()
    sys.argv = ["credo-cleanup.py"] + list(argv)
    with contextlib.redirect_stdout(buf):
        CL.main()
    return buf.getvalue()


os.makedirs(os.path.join(ST, "run1"))
open(os.path.join(ST, "run1", "f"), "w").write("x")
time.sleep(0.05)
reg(CTMP)
o = helper("own-rm", os.path.join(ST, "run1"))
contains("own-rm in TMPDIR: report only on Windows", "refused %s: report only: Windows has no equally strong check" % os.path.join(ST, "run1"), o)
check("own-rm in TMPDIR: kept", True, os.path.exists(os.path.join(ST, "run1", "f")))
o = helper("own-rm", "--dry-run", os.path.join(ST, "run1"))
contains("dry run also refuses", "refused", o)
os.makedirs(os.path.join(ST, "tree", "sub"))
junction(os.path.join(ST, "tree", "junc"))
reg(os.path.join(ST, "tree"))
o = helper("own-rm", os.path.join(ST, "tree"))
contains("a junction inside the tree: report only", "junction, symlink or other reparse point", o)
o = helper("own-rm", os.path.join(ST, "tree", "junc"))
contains("the junction itself is never deleted", "never followed or deleted on Windows", o)
os.makedirs(os.path.join(ST, "lnk"))
os.symlink(os.path.join(T, "outside"), os.path.join(ST, "lnk", "l"))
reg(os.path.join(ST, "lnk"))
o = helper("own-rm", os.path.join(ST, "lnk"))
contains("a symlink inside the tree: report only on Windows", "junction, symlink or other reparse point", o)
check("symlink target untouched", True, os.path.isdir(os.path.join(T, "outside")))
o = helper("purge", "--now")
contains("purge lists TMPDIR children", "listed %s: session TMPDIR" % os.path.join(ST, "run1"), o)
os.makedirs(os.path.join(ST, "export1"))
open(os.path.join(ST, "export1", "m.bin"), "w").write("m")
reg(os.path.join(ST, "export1"))
o = helper("keep", os.path.join(ST, "export1"), "e1", "--reason", "owner: keep", "--project", "acme")
contains("keep moves on Windows", "kept %s -> " % os.path.join(ST, "export1"), o)
check("kept content there", True, os.path.exists(os.path.join(T, "keep", "acme", "e1", "m.bin")))
DEAD = os.path.join(CTMP, "11111111-2222-4333-8444-555555555555")
os.makedirs(os.path.join(DEAD, "x"))
open(os.path.join(DEAD, "x", "f"), "w").write("y")
old = time.time() - 3600
os.utime(DEAD, (old, old))
reg(DEAD)
o = helper("sweep")
contains("sweep of a dead session: report only on Windows", "kept %s: Windows has no equally strong check" % os.path.join(DEAD, "x"), o)
check("sweep deletes nothing on Windows", True, os.path.exists(os.path.join(DEAD, "x", "f")))

# worktrees: always a dry run on Windows, through bash
calls = []


class R:
    returncode, stdout, stderr = 0, "auto\n", ""


def fake_run(argv, **kw):
    calls.append(argv)
    return R()


CL.subprocess.run = fake_run
os.environ["CREDO_BASH"] = "/bin/sh"
with contextlib.redirect_stdout(io.StringIO()):
    CL.worktrees(type("A", (), {"dir": T})())
CL.subprocess.run = subprocess.run
check("worktrees: scripts run through bash on Windows", "/bin/sh", calls[-1][0])
check("worktrees: always a dry run on Windows (even with [x])", True, "--dry-run" in calls[-1])

# playwright: in-use revisions from image paths and command lines
cache = os.path.join(LA, "ms-playwright")
os.makedirs(cache)
TABLE.update({500: (1, "chrome.exe"), 501: (1, "svchost.exe"), 502: (1, "node.exe")})
EXES.update({500: os.path.join(cache, "chromium-1300", "chrome-win", "chrome.exe")})
CMDS.update({502: ["node", os.path.join(cache, "firefox-1500", "x")]})
check("in-use revisions from image path and command line", {"chromium-1300", "firefox-1500"},
      CL.revisions_in_use(cache))
TABLE[503] = (1, "chrome.exe")
try:
    CL.revisions_in_use(cache)
    check("an unreadable browser process makes it unclear", "Unclear", "no exception")
except CL.Unclear as exc:
    contains("an unreadable browser process makes it unclear", "cannot be inspected", str(exc))
del TABLE[503]

# ---------------------------------------------------------------- 5. the ledger on Windows
LG = load("credo_ledger_nt", "credo-ledger.py")
RT = os.path.join(T, "root")
os.makedirs(os.path.join(RT, "olddir"))
junction(os.path.join(RT, "oldj"))
reg(RT)
L.OVERRIDES["roots"] = [RT]
time.sleep(1.2)
LG.pre({"session_id": SA, "tool_name": "Bash", "tool_use_id": "tu1", "cwd": RT,
        "tool_input": {"command": "mkdir x"}})
time.sleep(0.05)
os.makedirs(os.path.join(RT, "olddir", "kid"))
os.makedirs(os.path.join(RT, "oldj", "kid"))
os.makedirs(os.path.join(RT, "fresh"))
for p_ in ("olddir", "oldj"):
    os.utime(os.path.join(RT, p_))  # creating a child updates the parent's mtime
reg(RT)
LG.post({"session_id": SA, "tool_name": "Bash", "tool_use_id": "tu1", "cwd": RT,
         "tool_input": {"command": "mkdir x"}})
led = open(L.ledger_path(SA)).read()
contains("new dir at depth 1 recorded", '"%s"' % os.path.join(RT, "fresh"), led)
contains("new kid of a plain dir recorded", '"%s"' % os.path.join(RT, "olddir", "kid"), led)
check("a junction is never entered by the scan", False, os.path.join(RT, "oldj", "kid") in led)
rec = [json.loads(x) for x in led.splitlines() if os.path.join(RT, "fresh") in x][0]
check("records carry a real file id (lstat, not DirEntry)", True, rec["ino"] != 0 and rec["dev"] != 0)
check("Git Bash drive token", "C:/Users/x", LG.win_token("/c/Users/x"))
check("Git Bash /tmp token", TEMP + "/a", LG.win_token("/tmp/a"))
check("msys form of a Windows path", "/c/Users/x/y", LG.msys_form("C:\\Users\\x\\y"))
WT = os.path.join(T, "wt")
os.makedirs(os.path.join(WT, ".credo"))
open(os.path.join(WT, ".git"), "w").write("gitdir: %s\n" % os.path.join(T, "main", ".git", "worktrees", "wt"))
check("real .credo in a worktree is a violation", True,
      LG.credo_worktree_violation(os.path.join(WT, ".credo", "items", "a.md")) is not None)
os.rmdir(os.path.join(WT, ".credo"))
junction(os.path.join(WT, ".credo"))
check("a .credo junction counts as the setup link", None,
      LG.credo_worktree_violation(os.path.join(WT, ".credo", "items", "a.md")))
envf = os.path.join(T, "envfile")
open(envf, "w").close()
os.environ["CLAUDE_ENV_FILE"] = envf
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    LG.session_start({"session_id": SA, "cwd": RT})
contains("session-start exports TMPDIR", "export TMPDIR='%s'" % ST, open(envf).read())
contains("session-start tells the Windows rule", "On native Windows own-rm, purge and sweep only report", buf.getvalue())

# ---------------------------------------------------------------- 6. process identity users
os.environ["CLAUDE_CONFIG_DIR"] = PROF
os.environ["HOME"] = FH
REG = load("credo_session_registry_nt", "credo_session_registry.py")
check("registry: process chain from the Windows parent chain", [ME, 50, 10], REG.process_chain())
found = REG.find_agent(PROF, SA, REG.process_chain())
check("registry: session process found with the descriptor's procStart", (10, "100"), found[:2] if found else None)
check("registry: recorded", True, REG.record_session(PROF, SA, REG.process_chain()))
entry = json.load(open(REG.entry_path(PROF, SA)))
check("registry: no tmux pane on Windows", None, entry.get("tmux"))
check("registry: live while the start time matches", "live", REG.verify(PROF, SA, entry)[0])
STARTS[10] = "101"
check("registry: stale after pid reuse (start differs)", "stale", REG.verify(PROF, SA, entry)[0])
del STARTS[10]
check("registry: stale when the process is gone", "process 10 is gone", REG.verify(PROF, SA, entry)[1])
STARTS[10] = "100"
PC = load("credo_peer_check_nt", "credo-peer-check.py")
check("peer-check: alive with the descriptor's procStart", True, PC.pid_alive(10, "100"))
check("peer-check: pid reuse is dead", False, PC.pid_alive(10, "999"))
check("peer-check: children from the process table", [ME], PC.proc_children().get(50))
CMDS[600] = ["C:\\tools\\codex.exe", "exec"]
CMDS[601] = ["C:\\tools\\codex.exe", "app-server"]
check("peer-check: codex.exe recognised", True, PC.is_codex_proc(600))
check("peer-check: codex app-server ignored", False, PC.is_codex_proc(601))
check("peer-check: start epoch from FILETIME", P.filetime_to_epoch("100"), PC.proc_started_at(10))
import credo_session_name as SN  # noqa: E402
check("session name: ancestors from the Windows chain", [ME, 50, 10], SN.ancestors(ME))
check("session name: no environment of other processes", None, SN._environ_value(10, "TMUX"))
EXES[50] = "C:\\Program Files\\kitty\\kitty.exe"
check("session name: kitty by image name", True, SN._is_kitty(50))
check("session name: no daemon link", None, SN._daemon_client(10))

print("passed: %d, failed: %d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
EOF

python3 -I "$TMP/nt_sim.py" "$SCRIPT_DIR" "$TMP"
