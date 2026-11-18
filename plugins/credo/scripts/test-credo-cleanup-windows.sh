#!/bin/bash
# Live test of the provenance ledger, the cleanup helper and process identity on NATIVE Windows
# (#194): run it in Git Bash with a real CPython 3 (python.exe) on PATH. Anywhere else it prints
# SKIP and exits 0. Every path it touches lives in one fresh mktemp dir below the Git Bash /tmp
# (the per-user Windows temp dir); the helper's paths are pointed there through the same test
# shim test-credo-cleanup.sh uses. The Windows facts stay real: owner SID, volume type, NTFS
# creation time and file ids, junctions (mklink /J), handles, the process table.
# Usage (Git Bash): bash test-credo-cleanup-windows.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../hooks/credo-python-lib.sh
. "$ROOT/hooks/credo-python-lib.sh"
# shellcheck disable=SC2154 # CREDO_PYTHON is set by credo_find_python
if ! credo_find_python || [ "$("$CREDO_PYTHON" -c 'import os; print(os.name)' 2>/dev/null | tr -d '\r')" != "nt" ]; then
    echo "SKIP: needs Git Bash with a native Windows Python 3 (os.name nt)"
    exit 0
fi
PY="$CREDO_PYTHON"
winpath() { cygpath -w "$1"; }

TMP="$(mktemp -d /tmp/credo-cleanup-win-test.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
W="$(winpath "$TMP")"

PASS=0
FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi; }
contains() { case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing: %s\n  in:      %s\n' "$1" "$2" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  unexpected: %s\n' "$1" "$2" ;; *) PASS=$((PASS + 1)) ;; esac; }
exists() { [ -e "$1" ] || [ -L "$1" ] && echo yes || echo no; }
junction() { MSYS2_ARG_CONV_EXCL='*' cmd.exe /c mklink /J "$(winpath "$1")" "$(winpath "$2")" >/dev/null; }

SA="aaaaaaaa-0000-4000-8000-000000000001"
FH="$TMP/home"; LA="$FH/AppData/Local"; CTMP="$LA/Temp/credo-tmp"; ST="$CTMP/$SA"
PROF="$FH/.claude-x"; R="$TMP/root"
mkdir -p "$PROF/sessions" "$PROF/projects/-fix" "$LA/Temp" "$FH/AppData/Roaming" "$R" "$TMP/cfg"

# the fixture paths go into credo_cleanup_lib.OVERRIDES (never the environment); the Windows
# known folders point into the fixture, owner SID and volume checks stay real
cat > "$TMP/shim.py" <<'EOF'
import json, os, runpy, sys
cfg = json.load(open(sys.argv[1]))
script = sys.argv[2]
sys.path.insert(0, os.path.dirname(script))
import credo_cleanup_lib as L
L.OVERRIDES.update(cfg)
sys.argv = [script] + sys.argv[3:]
runpy.run_path(script, run_name="__main__")
EOF
"$PY" - "$W" <<'EOF' > "$TMP/ov.json"
import json, os, sys
t = sys.argv[1]
fh = os.path.join(t, "home"); la = os.path.join(fh, "AppData", "Local")
print(json.dumps({"home": fh, "state": os.path.join(t, "state"), "keep_root": os.path.join(t, "keep"),
    "tmp_base": os.path.join(la, "Temp", "credo-tmp"), "scratch_base": os.path.join(la, "Temp", "claude"),
    "profiles": [os.path.join(fh, ".claude-x")], "roots": [os.path.join(t, "root")],
    "home_root": "none", "sync": True, "no_maintenance": True, "explicit_idle_s": 0, "idle_minutes": 0,
    "nt_folders": {"profile": fh, "local_appdata": la, "roaming_appdata": os.path.join(fh, "AppData", "Roaming")}}))
EOF
OVJ="$(winpath "$TMP/ov.json")"; SHIM="$(winpath "$TMP/shim.py")"
LEDGER="$(winpath "$SCRIPT_DIR/credo-ledger.py")"; HELPER="$(winpath "$SCRIPT_DIR/credo-cleanup.py")"
export CREDO_GLOBAL="$TMP/cfg/config" CREDO_PROFILE="" CREDO_CONFIG_STDLIB_YAML=1 CLAUDE_CODE_SESSION_ID="$SA"
unset CLAUDE_CONFIG_DIR CREDO_LEDGER PLAYWRIGHT_BROWSERS_PATH
: > "$CREDO_GLOBAL"
helper() { "$PY" -I "$SHIM" "$OVJ" "$HELPER" "$@" 2>&1 | tr -d '\r'; }
hook() { # mode tool tool-input-json
    printf '{"session_id":"%s","tool_name":"%s","tool_use_id":"tu%s","cwd":"%s","tool_input":%s}' \
        "$SA" "$2" "$N" "$(winpath "$R" | sed 's/\\/\\\\/g')" "$3" | "$PY" -I "$SHIM" "$OVJ" "$LEDGER" "$1" | tr -d '\r'
}
N=0

# --- 0. process identity: this bash is a real ancestor of every python.exe it starts -------------
WINPID="$(cat /proc/$$/winpid)"
START="$("$PY" -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import credo_platform as P; print(P.proc_start(int(sys.argv[2])))' "$(winpath "$SCRIPT_DIR")" "$WINPID" | tr -d '\r')"
check "creation time of this Git Bash (GetProcessTimes) is a FILETIME number" yes "$(case "$START" in ''|*[!0-9]*) echo no ;; *) echo yes ;; esac)"
o="$("$PY" -I -c 'import os, sys; sys.path.insert(0, sys.argv[1]); import credo_platform as P
a = P.ancestors(os.getpid()); print(int(sys.argv[2]) in a, P.proc_exe(os.getpid()).lower().endswith("python.exe"), P.proc_cmdline(os.getpid())[1:3])' \
    "$(winpath "$SCRIPT_DIR")" "$WINPID" | tr -d '\r')"
check "ancestors, image path and command line of python.exe" "True True ['-I', '-c']" "$o"
printf '{"pid":%s,"sessionId":"%s","procStart":"%s"}' "$WINPID" "$SA" "$START" > "$PROF/sessions/$WINPID.json"
o="$("$PY" -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import credo_cleanup_lib as L
L.OVERRIDES.update({"profiles": [sys.argv[2]], "home": sys.argv[3]}); print(L.sid_bound(sys.argv[4]))' \
    "$(winpath "$SCRIPT_DIR")" "$(winpath "$PROF")" "$(winpath "$FH")" "$SA" | tr -d '\r')"
check "session id bound through the Windows process chain + procStart" "(True, None)" "$o"
o="$(CLAUDE_CONFIG_DIR="$(winpath "$PROF")" "$PY" -I -c 'import sys, importlib.util, os, json
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location("reg", os.path.join(sys.argv[1], "credo_session_registry.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
prof = sys.argv[2]
print(m.record_session(prof, sys.argv[3], m.process_chain()), m.verify(prof, sys.argv[3], json.load(open(m.entry_path(prof, sys.argv[3]))))[0])' \
    "$(winpath "$SCRIPT_DIR")" "$(winpath "$PROF")" "$SA" | tr -d '\r')"
check "session registry records and verifies on Windows" "True live" "$o"
o="$("$PY" -I -c 'import sys, importlib.util, os
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location("pc", os.path.join(sys.argv[1], "credo-peer-check.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.pid_alive(int(sys.argv[2]), sys.argv[3]), m.pid_alive(int(sys.argv[2]), "1"))' "$(winpath "$SCRIPT_DIR")" "$WINPID" "$START" | tr -d '\r')"
check "peer-check liveness with the descriptor's procStart" "True False" "$o"

# the real hook path: hooks/credo-py.sh -> python.exe -> credo-ledger.py (no shim). A non-UUID
# session id writes nothing; the hook must load on Windows and stay silent with exit 0
o="$(printf '{"session_id":"not-a-uuid","tool_name":"Write","tool_use_id":"t0","tool_input":{"file_path":"%s"}}' \
    "$(winpath "$R/x.txt" | sed 's/\\/\\\\/g')" | bash "$ROOT/hooks/credo-py.sh" "$SCRIPT_DIR/credo-ledger.py" pre 2>&1)"
check "ledger hook through the launcher: exit 0, silent" "0|" "$?|$o"

# --- 1. session start: private base, TMPDIR export (forward slashes) ------------------------------
ENVF="$TMP/envfile"; : > "$ENVF"
o="$(printf '{"session_id":"%s","cwd":"%s"}' "$SA" "$(winpath "$R" | sed 's/\\/\\\\/g')" | CLAUDE_ENV_FILE="$(winpath "$ENVF")" "$PY" -I "$SHIM" "$OVJ" "$LEDGER" session-start | tr -d '\r')"
contains "TMPDIR exported with forward slashes" "export TMPDIR='$(winpath "$ST" | tr '\\' '/')'" "$(cat "$ENVF")"
check "session tmp exists" yes "$(exists "$ST")"
contains "hint names the Windows rule" "On native Windows own-rm, purge and sweep only report" "$o"

# --- 2. the ledger records with NTFS facts, never through a junction -----------------------------
mkdir -p "$R/olddir" "$TMP/victim"; echo keep > "$TMP/victim/keep.txt"
junction "$R/oldj" "$TMP/victim"
sleep 1.2
N=1; hook pre Bash '{"command":"mkdir stuff"}' >/dev/null
mkdir "$R/fresh" "$R/olddir/kid" "$TMP/victim/kid"
hook post Bash '{"command":"mkdir stuff"}' >/dev/null
L="$(cat "$TMP/state/ledger/$SA.jsonl" 2>/dev/null)"
contains "new dir recorded" 'fresh"' "$L"
contains "new kid of a plain dir recorded" 'kid"' "$(grep olddir <<<"$L")"
lacks "nothing recorded through the junction" "oldj\\\\kid" "$L"
lacks "records carry a real file id" '"ino": 0' "$L"
o="$(hook pre Write "{\"file_path\":\"$(winpath "$TMP/state/ledger/$SA.jsonl" | sed 's/\\/\\\\/g')\"}")"
contains "Write to the ledger denied" '"permissionDecision": "deny"' "$o"
MIXED="$(cygpath -m "$TMP")"   # C:/Users/... -> the Git Bash drive form /c/Users/...
DRIVE="$(printf '%s' "${MIXED:0:1}" | tr 'A-Z' 'a-z')"
o="$(hook pre Bash "{\"command\":\"echo x >> /$DRIVE${MIXED:2}/state/ledger/$SA.jsonl\"}")"
contains "Git Bash form of the ledger path denied" '"permissionDecision": "deny"' "$o"

# --- 3. own-rm, keep, purge, sweep on Windows -----------------------------------------------------
mkdir "$ST/run1"; echo x > "$ST/run1/f"
o="$(helper own-rm "$(winpath "$ST/run1")")"
contains "own-rm in TMPDIR is report only on Windows" "report only: Windows has no equally strong check" "$o"
check "own-rm kept it" yes "$(exists "$ST/run1/f")"
mkdir "$ST/tree"; junction "$ST/tree/junc" "$TMP/victim"
o="$(helper own-rm "$(winpath "$ST/tree")")"
contains "junction inside the tree: refused" "junction, symlink or other reparse point" "$o"
o="$(helper own-rm "$(winpath "$ST/tree/junc")")"
contains "the junction itself: refused" "never followed or deleted" "$o"
check "junction target untouched" yes "$(exists "$TMP/victim/keep.txt")"
o="$(helper own-rm "$(winpath "$FH")")"
contains "the (fixture) home refused" "refused $(winpath "$FH"):" "$o"
o="$(helper purge --now)"
contains "purge lists the TMPDIR children" "session TMPDIR" "$o"
mkdir "$ST/export1"; echo m > "$ST/export1/m.bin"
o="$(helper keep "$(winpath "$ST/export1")" e1 --reason "owner: keep" --project acme)"
contains "keep moves on Windows" "kept " "$o"
check "kept content there" yes "$(exists "$TMP/keep/acme/e1/m.bin")"
DEAD="$CTMP/11111111-2222-4333-8444-555555555555"
mkdir -p "$DEAD/x"; echo y > "$DEAD/x/f"; touch -d '1 hour ago' "$DEAD"
o="$(helper sweep)"
contains "sweep of a dead session reports on Windows" "Windows has no equally strong check" "$o"
check "sweep deleted nothing" yes "$(exists "$DEAD/x/f")"
o="$(helper report)"
contains "report lists the ledger" "fresh" "$o"

# --- 4. playwright-prune deletes with handles; a junction inside stays, its target untouched ------
PC="$TMP/pw"; S="$TMP/search"
mkdir -p "$PC/chromium-1100/x" "$PC/chromium-1200" "$PC/chromium-999" "$PC/mcp-chrome-abc" "$PC/.links" "$S/proj/node_modules/playwright-core"
echo b > "$PC/chromium-1100/x/bin"; echo ro > "$PC/chromium-1100/ro"; chmod 444 "$PC/chromium-1100/ro"
junction "$PC/chromium-999/junc" "$TMP/victim"
echo '{"browsers":[{"name":"chromium","revision":"1200"}]}' > "$S/proj/node_modules/playwright-core/browsers.json"
touch -d '1 day ago' "$PC"/chromium-* "$PC/mcp-chrome-abc"
o="$(helper playwright-prune --cache "$(winpath "$PC")" --search "$(winpath "$S")")"
check "unreferenced revision removed (read-only file inside too)" no "$(exists "$PC/chromium-1100")"
check "referenced revision kept" yes "$(exists "$PC/chromium-1200")"
check "mcp-chrome untouched" yes "$(exists "$PC/mcp-chrome-abc")"
check "revision with a junction inside kept" yes "$(exists "$PC/chromium-999/junc")"
check "junction target untouched by the prune" yes "$(exists "$TMP/victim/keep.txt")"
contains "the junction is reported" "reparse point" "$o"

# --- 5. the delete primitive: pinned parents, identity, sharing violation -------------------------
o="$("$PY" -I - "$(winpath "$SCRIPT_DIR")" "$W" <<'EOF' 2>&1 | tr -d '\r'
import os, sys
sys.path.insert(0, sys.argv[1]); import credo_cleanup_lib as L
t = sys.argv[2]
d = os.path.join(t, "pin", "inner"); os.makedirs(d)
pins = L._nt_pin_dirs(d)
try:
    os.rename(os.path.join(t, "pin"), os.path.join(t, "pin2")); r = "renamed"
except OSError:
    r = "refused"
for fd in pins:
    os.close(fd)
f = os.path.join(t, "swap.txt"); open(f, "w").write("1"); st = os.lstat(f); os.unlink(f); open(f, "w").write("2")
sw = L.delete_path(f, st, False)
g = os.path.join(t, "open.txt"); open(g, "w").write("o"); sg = os.lstat(g); fh = open(g)
busy = L.delete_path(g, sg, False); fh.close()
print(r, "replaced" in sw[0], os.path.exists(f), bool(busy), os.path.exists(g), L.delete_path(g, sg, False), os.path.exists(g))
EOF
)"
check "pinned parent cannot be renamed; swapped file refused; open file kept; closed file removed" \
    "refused True True True True [] False" "$o"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
