#!/bin/bash
# The tmux features (self-restart, self-compact, self-reload, the periodic reminder,
# owner-type, runtime pane references) refuse with one clear "needs tmux ... native Windows"
# line on native Windows instead of a traceback. A native Windows Python is simulated: the
# POSIX-only modules (fcntl, pty, termios, tty, select, pwd, grp, resource) cannot be
# imported, os.name is "nt" and sys.platform "win32". Every run uses a fresh temp config dir
# and project dir (removed on exit); nothing is sent to any pane.
#
# Usage: bash test-credo-windows-tmux-refusal.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-win-tmux-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 missing"; exit 0; }

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

cat >"$TMP/winsim.py" <<'PY'
import os, runpy, sys
# stdlib modules that pick their implementation from os.name are loaded before the switch
import argparse, datetime, glob, hashlib, importlib.util, json, re, shlex, shutil  # noqa: F401,E401
import signal, subprocess, tempfile, time, unicodedata, stat, socket, uuid  # noqa: F401,E401
for mod in ("fcntl", "pty", "termios", "tty", "select", "pwd", "grp", "resource"):
    sys.modules[mod] = None  # import raises ImportError
os.name = "nt"
sys.platform = "win32"
script = sys.argv[1]
sys.argv = sys.argv[1:]
sys.path.insert(0, os.path.dirname(os.path.abspath(script)))
runpy.run_path(script, run_name="__main__")
PY

mkdir -p "$TMP/cfg" "$TMP/proj"
git -C "$TMP/proj" init -q 2>/dev/null
win() { # script args... -> "<rc>|<first output line>|<traceback or none>"
    local out rc
    out="$(cd "$TMP/proj" && env -u TMUX -u TMUX_PANE CLAUDE_CONFIG_DIR="$TMP/cfg" \
        CLAUDE_CODE_SESSION_ID=00000000-0000-4000-8000-000000000000 \
        python3 "$TMP/winsim.py" "$HERE/$1" "${@:2}" </dev/null 2>&1)"
    rc=$?
    case "$out" in *Traceback*) tb=traceback ;; *) tb=none ;; esac
    printf '%s|%s|%s' "$rc" "${out%%$'\n'*}" "$tb"
}
MSG="needs tmux, which is not available on native Windows (Git Bash); run Claude Code inside WSL to use it"

for s in self-restart self-compact self-reload; do
    for a in check run; do
        check "$s $a" "1|FAIL: $s $MSG|none" "$(win "credo-$s.py" "$a")"
    done
done
check "self-restart pty relaunch" "2|credo-self-restart: the pty relaunch needs a POSIX terminal, which is not available on native Windows; run Claude Code inside WSL|none" \
    "$(win credo-self-restart.py relaunch-pty -- true)"
check "self-restart status still works" "none" "$(win credo-self-restart.py status | cut -d'|' -f3)"
check "reminder status" "0|the periodic reminder $MSG|none" "$(win credo-reminder.py status)"
check "reminder turn hook: silent" "0||none" "$(win credo-reminder.py turn)"
check "reminder start hook: silent" "0||none" "$(win credo-reminder.py start)"
check "owner-type show" "1|unsupported: owner-type $MSG|none" "$(win credo-owner-type.py show --session x)"
check "owner-type send json" '1|{"exit": 1, "reason": "owner-type '"$MSG"'", "status": "unsupported"}|none' \
    "$(win credo-owner-type.py send --session x --text hi --json)"
check "runtime pane status" "1|tmux pane references $MSG|none" "$(win credo_runtime.py pane status --root "$TMP/proj")"
check "runtime pane add" "1|tmux pane references $MSG|none" "$(win credo_runtime.py pane add s:0.0 --purpose p --root "$TMP/proj")"
check "runtime check unaffected" "0||none" "$(win credo_runtime.py check --root "$TMP/proj")"

# Linux: the refusal helper stays quiet
check "linux: no refusal" "None" "$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import credo_pane_guard as g; print(g.windows_tmux_refusal("x"))' "$HERE")"

echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
