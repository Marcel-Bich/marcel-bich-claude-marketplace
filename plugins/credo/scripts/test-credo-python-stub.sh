#!/bin/bash
# Tests for the Python 3 probe (hooks/credo-python-lib.sh), the launcher (hooks/credo-py.sh)
# and the credo hooks on a machine where python3 and python are only the Windows Store alias
# stub: fake python3/python early in PATH print the Store text and exit 49 (9009 as the shell
# sees it). Every hook must exit 0 and never show the Store text; the launcher shows ONE
# clear "credo needs python3" message per session. With a real Python 3 the launcher runs the
# script with stdin, arguments and exit code passed through. credo-ledger.py exits 0 at once on
# a non-POSIX Python or when its library cannot load.
#
# Isolation: HOME, XDG_STATE_HOME, XDG_RUNTIME_DIR and CLAUDE_CONFIG_DIR point into an own
# mktemp dir; nothing outside it is written.
# Usage: bash test-credo-python-stub.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS="$ROOT/hooks"
LAUNCHER="$HOOKS/credo-py.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-python-stub-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
contains() { # name needle haystack
    case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing: %s\n  in:      %s\n' "$1" "$2" "$3" ;; esac
}
lacks() { # name needle haystack
    case "$3" in *"$2"*) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  unexpected: %s\n  in:         %s\n' "$1" "$2" "$3" ;; *) PASS=$((PASS + 1)) ;; esac
}

REAL_PY="$(command -v python3)" || { echo "SKIP: no python3 on this machine"; exit 0; }
STORE_TEXT="Python was not found; run without arguments to install from the Microsoft Store"

# --- fixtures ---------------------------------------------------------------------------
STUB="$TMP/stub-bin"        # python3 + python = Store stub
MIXED="$TMP/mixed-bin"      # python3 = stub, python = real Python 3
WIN="$TMP/win-bin"          # stub + uname reporting Git Bash
mkdir -p "$STUB" "$MIXED" "$WIN" "$TMP/home" "$TMP/state" "$TMP/run" "$TMP/cfg/sessions"
for d in "$STUB" "$MIXED" "$WIN"; do
    for n in python3 python; do
        printf '#!/bin/sh\necho "%s"\necho "%s" >&2\nexit 49\n' "$STORE_TEXT" "$STORE_TEXT" > "$d/$n"
        chmod +x "$d/$n"
    done
done
ln -sf "$REAL_PY" "$MIXED/python"
PYL="$TMP/pylauncher-bin"   # python3 + python = stub, py -3 = real Python 3 (python.org layout)
mkdir -p "$PYL"
cp "$STUB/python3" "$STUB/python" "$PYL/"
printf '#!/bin/sh\n[ "$1" = "-3" ] || exit 9\nshift\nexec "%s" "$@"\n' "$REAL_PY" > "$PYL/py"
chmod +x "$PYL/py"
printf '#!/bin/sh\necho MINGW64_NT-10.0-19045\n' > "$WIN/uname"
chmod +x "$WIN/uname"

export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" XDG_RUNTIME_DIR="$TMP/run"
export CLAUDE_CONFIG_DIR="$TMP/cfg" CLAUDE_PLUGIN_ROOT="$ROOT"
export CREDO_GLOBAL="$TMP/cfg/credo-config" CREDO_PROFILE="" CREDO_LEDGER=0
BASE_PATH="$PATH"

SA="aaaaaaaa-0000-4000-8000-000000000001"
SB="bbbbbbbb-0000-4000-8000-000000000002"
start_input() { printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$1" "$TMP"; }
pre_input() { printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"%s"}' "$1" "$TMP"; }

run() { # path-prefix stdin cmd... -> sets OUT, ERR, RC
    local p="$1" in="$2"
    shift 2
    OUT="$(printf '%s' "$in" | PATH="$p:$BASE_PATH" "$@" 2>"$TMP/err")"
    RC=$?
    ERR="$(cat "$TMP/err")"
}

# --- 1. probe ---------------------------------------------------------------------------
probe() { # path-prefix -> "<rc> <CREDO_PYTHON>"
    PATH="$1:$BASE_PATH" bash -c '. "$1"; credo_find_python; echo "$? $CREDO_PYTHON"' _ "$HOOKS/credo-python-lib.sh" 2>&1
}
check "probe: stub only = no python" "1 " "$(probe "$STUB")"
check "probe: stub python3, real python = python" "0 python" "$(probe "$MIXED")"
REAL_EXE="$("$REAL_PY" -c 'import sys; print(sys.executable)')"
check "probe: py -3 launcher = its interpreter" "0 $REAL_EXE" "$(probe "$PYL")"
check "probe: real python3 first" "0 python3" "$(probe "$TMP/empty-dir")"
check "probe: ready caches the failed probe" "1 1" "$(PATH="$STUB:$BASE_PATH" bash -c '. "$1"; credo_python_ready; a=$?; PATH=/nonexistent; credo_python_ready; echo "$a $?"' _ "$HOOKS/credo-python-lib.sh")"
check "stub detection: WindowsApps path" "0" "$(mkdir -p "$TMP/Microsoft/WindowsApps" && cp "$STUB/python3" "$TMP/Microsoft/WindowsApps/python3" && PATH="$TMP/Microsoft/WindowsApps:$BASE_PATH" bash -c '. "$1"; credo_python_is_stub; echo $?' _ "$HOOKS/credo-python-lib.sh")"
contains "install hint: Git Bash = winget + aliases" "winget install Python.Python.3.12" "$(PATH="$WIN:$BASE_PATH" bash -c '. "$1"; credo_python_install_hint' _ "$HOOKS/credo-python-lib.sh")"
contains "install hint: Git Bash names the App Execution Aliases" "App Execution Aliases" "$(PATH="$WIN:$BASE_PATH" bash -c '. "$1"; credo_python_install_hint' _ "$HOOKS/credo-python-lib.sh")"

# --- 2. launcher without a working Python ---------------------------------------------------
FIX="$TMP/fixture.py"
printf 'import sys\ndata = sys.stdin.read()\nprint("ran", sys.argv[1:], data)\nsys.exit(3)\n' > "$FIX"

run "$STUB" "$(start_input "$SA")" "$LAUNCHER" "$FIX" session-start
check "launcher stub: exit 0" "0" "$RC"
check "launcher stub: no stderr" "" "$ERR"
lacks "launcher stub: no Store text" "Python was not found" "$OUT"
lacks "launcher stub: script not run" "ran" "$OUT"
contains "launcher stub: clear message" '"systemMessage":"credo needs python3' "$OUT"
contains "launcher stub: SessionStart context for the agent" '"hookEventName":"SessionStart","additionalContext":"[credo] python3 is a requirement' "$OUT"
check "launcher stub: output is valid JSON" "ok" "$(printf '%s' "$OUT" | jq -e '.systemMessage' >/dev/null 2>&1 && echo ok)"

run "$STUB" "$(pre_input "$SA")" "$LAUNCHER" "$FIX" pre
check "launcher stub: same session again = silent" "0|" "$RC|$OUT"

run "$STUB" "$(pre_input "$SB")" "$LAUNCHER" "$FIX" pre
check "launcher stub: other session exit 0" "0" "$RC"
contains "launcher stub: other session gets the message once" '"systemMessage":"credo needs python3' "$OUT"
lacks "launcher stub: PreToolUse has no SessionStart context" "additionalContext" "$OUT"
check "launcher stub: PreToolUse output is valid JSON" "ok" "$(printf '%s' "$OUT" | jq -e '.systemMessage' >/dev/null 2>&1 && echo ok)"

run "$WIN" "$(start_input "cccccccc-0000-4000-8000-000000000003")" "$LAUNCHER" "$FIX" session-start
contains "launcher on Git Bash: winget hint" "winget install Python.Python.3.12" "$OUT"
check "launcher on Git Bash: valid JSON" "ok" "$(printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 && echo ok)"

run "$STUB" "" "$LAUNCHER" "$TMP/missing.py" pre
check "launcher: missing script = exit 0, silent" "0|" "$RC|$OUT"

# --- 3. launcher with a working Python ----------------------------------------------------
run "$TMP/empty-dir" "hello" "$LAUNCHER" "$FIX" a b
check "launcher real: exit code passes through" "3" "$RC"
check "launcher real: args and stdin pass through" "ran ['a', 'b'] hello" "$OUT"
run "$MIXED" "x" "$LAUNCHER" "$FIX" m
check "launcher mixed: python fallback runs the script" "3|ran ['m'] x" "$RC|$OUT"

run "$PYL" "y" "$LAUNCHER" "$FIX" p
check "launcher py -3: runs the script" "3|ran ['p'] y" "$RC|$OUT"

# --- 4. the real ledger through the launcher -------------------------------------------------
LEDGER="$ROOT/scripts/credo-ledger.py"
for mode in pre post session-start; do
    run "$STUB" "$(pre_input "dddddddd-0000-4000-8000-00000000000$((${#mode} % 10))")" "$LAUNCHER" "$LEDGER" "$mode"
    check "ledger $mode via launcher, stub: exit 0" "0" "$RC"
    lacks "ledger $mode via launcher, stub: no Store text" "Python was not found" "$OUT$ERR"
done
run "$TMP/empty-dir" "$(pre_input "$SA")" "$LAUNCHER" "$LEDGER" pre
check "ledger pre via launcher, real python (CREDO_LEDGER=0): exit 0, silent" "0||" "$RC|$OUT|$ERR"

# Windows-flavoured Python with unreadable input: exits 0, silent
OUT="$(printf 'not json' | "$REAL_PY" -c 'import os, runpy, sys; os.name = "nt"; sys.argv = [sys.argv[1], "pre"]; runpy.run_path(sys.argv[0], run_name="__main__")' "$LEDGER" 2>&1)"
check "ledger: os.name nt, bad input: exits 0, silent" "0|" "$?|$OUT"
# library that cannot load: exits 0
mkdir -p "$TMP/lonely"
cp "$LEDGER" "$TMP/lonely/credo-ledger.py"
OUT="$(printf '{}' | CREDO_LEDGER=1 "$REAL_PY" "$TMP/lonely/credo-ledger.py" pre 2>&1)"
check "ledger: missing library exits 0, silent" "0|" "$?|$OUT"

# --- 4b. modules that a native Windows Python must import without crashing ------------------
NOPOSIX='import sys; sys.modules["fcntl"] = None; sys.modules["pwd"] = None; sys.path.insert(0, sys.argv[1])'
OUT="$("$REAL_PY" -I -c "$NOPOSIX"'
import credo_cleanup_lib as L
p = sys.argv[2] + "/lockfile"
with L.Locked(p):
    pass
print("ok", bool(L.home()))' "$SCRIPT_DIR" "$TMP" 2>&1)"
check "cleanup lib: imports and locks without fcntl/pwd" "ok True" "$OUT"
OUT="$("$REAL_PY" -I -c "$NOPOSIX"'
import importlib.util
spec = importlib.util.spec_from_file_location("sr", sys.argv[1] + "/credo-self-restart.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print("ok", m.credo_lock.fcntl is None)' "$SCRIPT_DIR" 2>&1)"
check "self-restart: imports without fcntl" "ok True" "$OUT"
for mod in credo-peer-lan credo-win-bridge; do
    OUT="$("$REAL_PY" -I -c "$NOPOSIX"'
import importlib.util
spec = importlib.util.spec_from_file_location("m", sys.argv[1] + "/" + sys.argv[2] + ".py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print("ok")' "$SCRIPT_DIR" "$mod" 2>&1 | tail -n 1)"
    check "$mod: imports without fcntl/pwd" "ok" "$OUT"
done
# credo_lock on Windows: msvcrt.locking of byte 0, a busy lock is reported (fake msvcrt here)
OUT="$("$REAL_PY" -I -c 'import sys, types
sys.modules["fcntl"] = None
calls = []
held = {"busy": False}
fake = types.ModuleType("msvcrt")
fake.LK_NBLCK, fake.LK_UNLCK = 2, 0
def locking(fd, mode, n):
    calls.append((mode, n))
    if mode == fake.LK_NBLCK and held["busy"]:
        raise OSError(36, "busy")
fake.locking = locking
sys.modules["msvcrt"] = fake
sys.path.insert(0, sys.argv[1])
import credo_lock
with credo_lock.Locked(sys.argv[2] + "/w.lock"):
    pass
held["busy"] = True
with open(sys.argv[2] + "/w.lock", "a") as fh:
    nb = credo_lock.lock(fh, blocking=False)
print(credo_lock.AVAILABLE, calls[:2], nb)' "$SCRIPT_DIR" "$TMP" 2>&1)"
check "credo_lock: msvcrt fallback locks and unlocks byte 0, busy = False" "True [(2, 1), (0, 1)] False" "$OUT"
# cleanup helper and ledger: no POSIX-only early exit any more (#194); their Windows behaviour
# is covered by test-credo-cleanup-nt.sh (simulated) and the live Git Bash check
check "cleanup/ledger: no POSIX-only exit left" "0" \
    "$(grep -c -E 'not supported on native Windows|if os.name != "posix"' "$SCRIPT_DIR/credo-cleanup.py" "$SCRIPT_DIR/credo-ledger.py" | awk -F: '{s += $2} END {print s}')"

# peer-lan relay is POSIX only: a native Windows Python 3 must not start or offer it
NT="$TMP/nt-bin"
mkdir -p "$NT"
printf '#!/bin/sh\nif [ "$1" = "-I" ] && [ "$2" = "-c" ]; then echo "credo-python 3 nt"; exit 0; fi\ntouch "%s/nt-ran"\nexit 0\n' "$TMP" > "$NT/python3"
chmod +x "$NT/python3"
run "$NT" "$(start_input "$SA")" "$HOOKS/credo-peer-lan-autostart.sh"
check "peer-lan-autostart, nt python: exit 0, silent" "0|" "$RC|$OUT"
check "peer-lan-autostart, nt python: relay script not run" "no" "$([ -e "$TMP/nt-ran" ] && echo yes || echo no)"
check "probe: nt python counts as present" "0 python3 nt" "$(PATH="$NT:$BASE_PATH" bash -c '. "$1"; credo_find_python; echo "$? $CREDO_PYTHON $CREDO_PYTHON_OS"' _ "$HOOKS/credo-python-lib.sh")"

# --- 5. every credo hook that uses Python, with only the stub ------------------------------
hook_ok() { # name stdin hook [args]
    local name="$1" in="$2"
    shift 2
    run "$STUB" "$in" "$@"
    check "$name: exit 0" "0" "$RC"
    lacks "$name: no Store text" "Python was not found" "$OUT$ERR"
}
hook_ok "session-registry" "$(start_input "$SA")" "$HOOKS/credo-session-registry.sh"
hook_ok "peer-bridge" "$(start_input "$SA")" "$HOOKS/credo-peer-bridge.sh"
hook_ok "peer-split-hint" "$(start_input "$SA")" "$HOOKS/credo-peer-split-hint.sh"
hook_ok "win-bridge-autostart" "$(start_input "$SA")" env WSL_DISTRO_NAME=fixture "$HOOKS/credo-win-bridge-autostart.sh"
hook_ok "peer-lan-autostart" "$(start_input "$SA")" "$HOOKS/credo-peer-lan-autostart.sh"
hook_ok "reminder start" "$(start_input "$SA")" "$HOOKS/credo-reminder.sh" start
hook_ok "reminder turn" '{"session_id":"x","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$HOOKS/credo-reminder.sh" turn
hook_ok "session-start" "$(start_input "$SA")" "$HOOKS/credo-session-start.sh"
hook_ok "peer-message (trust marker)" '{"session_id":"x","hook_event_name":"UserPromptSubmit","prompt":"<cross-session-message from=\"uds:/tmp/x.sock\">credo-trust hi</cross-session-message>"}' "$HOOKS/credo-peer-message.sh"
hook_ok "peer-message (trust grant)" '{"session_id":"x","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"credo-peer-lan.py trust add box-1"}}' "$HOOKS/credo-peer-message.sh"
hook_ok "remote-mirror stop" '{"session_id":"x","hook_event_name":"Stop","last_assistant_message":"done"}' "$HOOKS/credo-remote-mirror.sh" stop

# win-bridge-autostart must not start anything without a working Python
check "win-bridge-autostart: no daemon state without python" "no" "$([ -e "$TMP/state/credo/win-bridge/bridge.pid" ] && echo yes || echo no)"

# --- 5b. credo_platform: bash path and pid liveness ---------------------------------------------
OUT="$("$REAL_PY" -I -c 'import os, sys, subprocess
sys.path.insert(0, sys.argv[1])
import credo_platform as cp
os.environ.pop("CREDO_BASH", None)
a = cp.bash_exe()
os.environ["CREDO_BASH"] = sys.argv[2]
b = cp.bash_exe()
os.environ["CREDO_BASH"] = sys.argv[2] + "-missing"
c = cp.bash_exe()
p = subprocess.Popen(["true"]); p.wait()
print(a, b == sys.argv[2], c, cp.pid_alive(os.getpid()), cp.pid_alive(p.pid), cp.pid_alive("x"), cp.pid_alive(0))' "$SCRIPT_DIR" "$(command -v bash)" 2>&1)"
check "credo_platform: bash path and liveness" "bash True bash True False False False" "$OUT"
check "lib: CREDO_BASH only on MSYS" "unset" "$(bash -c '. "$1"; echo "${CREDO_BASH:-unset}"' _ "$HOOKS/credo-python-lib.sh")"

# --- 6. counter lock without flock (Git Bash, macOS): mkdir lock, no duplicate numbers -------
NOFLOCK="$TMP/noflock-bin"
mkdir -p "$NOFLOCK"
for tool in bash mkdir rmdir stat date sleep tr cat mv dirname basename printf; do
    p="$(command -v "$tool")" && [ "${p#/}" != "$p" ] && ln -sf "$p" "$NOFLOCK/$tool"
done
CNT="$TMP/counter"
PATH="$NOFLOCK" "$NOFLOCK/bash" -c '
. "$1"
command -v flock >/dev/null 2>&1 && { echo "flock still visible"; exit 1; }
for i in $(printf "%s\n" 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16); do
    (
        credo_counter_lock "$2.lock" || exit 1
        n=$(( $(credo_counter_read "$2") + 1 ))
        printf "%s\n" "$n" | credo_counter_write "$2"
        printf "%s\n" "$n" >> "$2.drawn"
        credo_counter_unlock
    ) &
done
wait' _ "$SCRIPT_DIR/credo-counter-lib.sh" "$CNT"
check "counter without flock: 16 parallel draws end at 16" "16" "$(tr -d '[:space:]' < "$CNT" 2>/dev/null)"
check "counter without flock: no number drawn twice" "16" "$(sort -u "$CNT.drawn" 2>/dev/null | wc -l | tr -d ' ')"
check "counter without flock: lock dir released" "no" "$([ -d "$CNT.lock.d" ] && echo yes || echo no)"

echo "credo python stub: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
