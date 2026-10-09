#!/bin/bash
# Tests for credo-self-reload.py.
#
# NOTHING real is ever typed into: tmux is a FAKE binary first on a restricted PATH
# (it records every call and serves invented pane fixtures), every target is a FAKE
# process this test starts itself (argv[0] "claude"), every config dir is a temp dir,
# ntfy is off, the plugin CLI is a fake. No real tmux pane is ever addressed.
#
# It checks:
#   - check: no session id, not in tmux, OK plan (own pane + socket, the steps), no keys
#   - owner rule: exactly one of --auto / --user-confirmed; --auto only in autonomous
#     mode; refusals start nothing and write no marker
#   - worker happy path: /reload-plugins, Enter, /reload-skills, Enter, ".", Enter -
#     each typed literally into the own pane only, each verified before Enter; the wake
#     file exists before the "." Enter; the new turn (wake file consumed) ends the
#     worker without any further "." (status woken)
#   - 60 s fallback (shortened): no new turn -> "." re-sent; the turn starting after the
#     second "." stops it; a "." left in the input only gets Enter again; bounded
#     retries -> failed: no new turn, wake file kept for the next prompt
#   - background shells / agents in the footer never block
#   - typed user text -> gives up, nothing typed; input changed before Enter -> no Enter
#   - --update runs the allowlisted plugin update first and records before -> after
#   - cancel and status are per session
#
# Usage: bash test-credo-self-reload.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/credo-self-reload.py"
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "SKIP: python3 not found"; exit 0; fi
[ -f "$HELPER" ] || { echo "FAIL: $HELPER missing"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/csrl.XXXXXX")"
PIDS=""
cleanup() {
    for p in $PIDS; do kill -TERM "$p" 2>/dev/null || true; done
    rm -rf -- "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
ok() { # name cond(0=pass)
    if [ "$2" = "0" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; fi
}

# --- pure: result_seen ---------------------------------------------------------------
"$PY" - "$HELPER" <<'PYEOF'
import importlib.util, sys
s = importlib.util.spec_from_file_location("r", sys.argv[1])
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
R = "─" * 60
box = ["● Done.", "", R, "❯ ", R, "  ? for shortcuts"]
cmd = "/reload-plugins"
assert m.result_seen("\n".join(["> " + cmd, "  ⎿  Reloaded 4 plugins"] + box), cmd)
# an older run's result above a newer echo without its result does not count
assert not m.result_seen("\n".join(["> " + cmd, "  ⎿  Reloaded 4 plugins", "> " + cmd] + box), cmd)
assert not m.result_seen("\n".join(["● nothing here"] + box), cmd)
# the command still typed in the input box is not an echo
assert not m.result_seen("\n".join(["● Done.", "", R, "❯ " + cmd, R]), cmd)
PYEOF
ok "result_seen: pure detection" "$?"

# --- fakes ---------------------------------------------------------------------------
BASE="$TMP/base"; FT="$TMP/ftmux"; FC="$TMP/fclaude"; mkdir -p "$BASE" "$FT" "$FC"
for t in python3 bash dirname cat mkdir mv cp sleep env kill rm printf tr sed grep head; do
    p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$BASE/$t"
done
# fake tmux: records argv; display-message answers for $FAKE_PANE_ID with the pid in
# $FAKE_PANE_PIDFILE; capture-pane serves the pane file named in $FAKE_STATE; send-keys -l
# renders the typed text into the input box ($FAKE_TYPE_PREFIX before it, the lines of
# $FAKE_TYPE_BELOW_FILE under it); Enter switches back to $FAKE_IDLE (after a /reload-*
# command with the echoed command and a "Reloaded" result line above it, no result line
# with FAKE_NO_RESULT=1). On the Enter of a
# "." it records whether the wake file existed, and from the $FAKE_DOT_CLEARS_AT-th "."
# on it consumes the wake file (what the UserPromptSubmit hook does when the turn
# starts). FAKE_DOT_ENTER_LOST=1: the first "." Enter is lost (the "." stays typed).
cat > "$FT/tmux" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_TMUX_LOG"
[ "$1" = "-S" ] && shift 2
R="────────────────────────────────────────────────────────────"
case "$1" in
    display-message)
        [ "$4" = "$FAKE_PANE_ID" ] || exit 1
        printf '%s\t%s\t0\t0\n' "$4" "$(cat "$FAKE_PANE_PIDFILE")" ;;
    capture-pane)
        cat "$(cat "$FAKE_STATE")" ;;
    send-keys)
        if [ "$4" = "-l" ]; then
            printf '%s\n' "● Done." "" "$R" "❯ ${FAKE_TYPE_PREFIX:-}$5" "$R" > "$FAKE_STATE.typed"
            [ -n "${FAKE_TYPE_BELOW_FILE:-}" ] && cat "$FAKE_TYPE_BELOW_FILE" >> "$FAKE_STATE.typed"
            echo "$FAKE_STATE.typed" > "$FAKE_STATE"
            printf '%s' "$5" > "$FAKE_STATE.last"
            if [ -n "${FAKE_BUSY_ON_TYPE:-}" ] && [ "$5" != "." ]; then
                # a turn starts right while the command is typed: busy, text still in the input
                printf '%s\n' "● Working." "" "✻ Brewing... (3s · ↓ 10 tokens)" "" "$R" "❯ $5" "$R" > "$FAKE_STATE.typed"
            fi
            [ -n "${FAKE_SLOW_TYPE:-}" ] && [ "$5" != "." ] && sleep "$FAKE_SLOW_TYPE"
            if [ "$5" = "." ] && [ -n "${FAKE_TURN_ON_DOT_TYPE:-}" ]; then
                # another prompt starts a turn while the "." is being typed: the hook
                # consumes the wake file, the model is busy, the "." waits in the input
                rm -f "$FAKE_WAKE_FILE"
                printf '%s\n' "● Working." "" "✻ Brewing... (3s · ↓ 10 tokens)" "" "$R" "❯ ." "$R" > "$FAKE_STATE.typed"
            fi
        elif [ "$4" = "BSpace" ]; then
            echo "$FAKE_IDLE" > "$FAKE_STATE"
        elif [ "$4" = "Enter" ]; then
            last="$(cat "$FAKE_STATE.last" 2>/dev/null)"
            if [ "$last" = "." ]; then
                n=$(( $(cat "$FAKE_STATE.dots" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_STATE.dots"
                if [ -e "$FAKE_WAKE_FILE" ]; then echo "wake-present" >> "$FAKE_TMUX_LOG.wake"; else echo "wake-missing" >> "$FAKE_TMUX_LOG.wake"; fi
                if [ "${FAKE_DOT_ENTER_LOST:-}" = 1 ] && [ "$n" = 1 ]; then exit 0; fi
                if [ -n "${FAKE_DOT_CLEARS_AT:-}" ] && [ "$n" -ge "$FAKE_DOT_CLEARS_AT" ]; then rm -f "$FAKE_WAKE_FILE"; fi
            fi
            case "$last" in
                /reload-*)
                    { printf "%s\n" "❯ $last"; [ -z "${FAKE_NO_RESULT:-}" ] && printf "%s\n" "  ⎿  Reloaded: fixture result for $last"; cat "$FAKE_IDLE"; } > "$FAKE_STATE.after"
                    echo "$FAKE_STATE.after" > "$FAKE_STATE" ;;
                *) echo "$FAKE_IDLE" > "$FAKE_STATE" ;;
            esac
        fi ;;
esac
exit 0
EOF
# fake claude CLI: plugin list / update on a state file
cat > "$FC/claude" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
with open(os.environ["FAKE_CLAUDE_LOG"], "a") as fh:
    fh.write(" ".join(a) + "\n")
state = os.environ["FAKE_PLUGIN_STATE"]
if a[:2] == ["plugin", "list"]:
    print(open(state).read())
elif a[:2] == ["plugin", "update"]:
    d = json.load(open(state))
    for p in d:
        if p["id"] == a[2]:
            p["version"] = "0.2.0"
    json.dump(d, open(state, "w"))
EOF
chmod +x "$FT/tmux" "$FC/claude"
export FAKE_TMUX_LOG="$TMP/tmux.log" FAKE_CLAUDE_LOG="$TMP/claude.log" CREDO_SELF_RELOAD_NTFY_URL=off CREDO_SKIP_ENSURE=1
export CREDO_SELF_RELOAD_POLL=0.2 CREDO_SELF_RELOAD_RECHECK=0.2 CREDO_SELF_RELOAD_KEY_PAUSE=0.1 \
    CREDO_SELF_RELOAD_CONFIRM_WAIT=1 CREDO_SELF_RELOAD_RESULT_WAIT=2 CREDO_SELF_RELOAD_STEP_TIMEOUT=10
export CREDO_GLOBAL="$TMP/global.yaml" CREDO_PROFILE="$TMP/none-profile" CREDO_PROJECT="$TMP/none-project"
export CREDO_SELF_RESTART_OWN_MARKETPLACE=mkt-a
unset CREDO_SESSION_MODES_DIR
: > "$CREDO_GLOBAL"
R="────────────────────────────────────────────────────────────"
printf '%s\n' "● Done, fixture finished." "" "✻ Worked for 1m 5s" "" "$R" "❯ " "$R" "  ? for shortcuts" > "$TMP/idle.txt"
printf '%s\n' "● Done." "" "$R" "❯ a half typed user prompt" "$R" > "$TMP/typed.txt"
printf '%s\n' "● Done." "" "$R" "❯ " "$R" "  ? for shortcuts · 2 shells" "  ◯ general-purpose  Fixture audit" "  ◯ monitor  Fixture log" > "$TMP/bg.txt"
export FAKE_STATE="$TMP/state" FAKE_PANE_ID=%5 FAKE_IDLE="$TMP/idle.txt"

SID="aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb"
CFG="$TMP/cfg"; mkdir -p "$CFG/credo/session-modes"
MODES="$CFG/credo/session-modes"; MARK="$CFG/credo/self-reload-$SID.json"; LOGF="$CFG/credo/self-reload-$SID.log"
export FAKE_WAKE_FILE="$CFG/credo/self-wake-$SID"
cat > "$TMP/fake_target.py" <<'PYEOF'
import time
for _ in range(1200):
    time.sleep(0.1)
PYEOF
start_target() { # pidfile extra-env...
    local pidfile="$1"; shift
    (exec env -u TMUX -u TMUX_PANE CLAUDE_CONFIG_DIR="$CFG" "$@" bash -c 'exec -a claude "$0" "$@"' "$PY" "$TMP/fake_target.py") &
    local p=$!
    PIDS="$PIDS $p"
    echo "$p" > "$pidfile"
    sleep 0.3
}
wait_status() { # pattern [tries]
    for _ in $(seq 1 "${2:-100}"); do grep -q "$1" "$MARK" 2>/dev/null && return 0; sleep 0.2; done
    return 1
}
H() { # run the helper against target $TGT
    env CREDO_SELF_RELOAD_SESSION_ID=$SID CREDO_SELF_RELOAD_TARGET_PID="$TGT" PATH="$FT:$FC:$BASE" "$PY" "$HELPER" "$@" 2>&1
}
reset() { # pane file
    echo "$1" > "$FAKE_STATE"; : > "$FAKE_TMUX_LOG"; rm -f "$FAKE_TMUX_LOG.wake" "$FAKE_STATE.dots" "$FAKE_STATE.last" "$MARK" "$FAKE_WAKE_FILE"
}
dots_typed() { grep -cxF -- "-S /tmp/fake-sock send-keys -t %5 -l ." "$FAKE_TMUX_LOG"; }

# --- check -------------------------------------------------------------------------
start_target "$TMP/t1.pid" TMUX=/tmp/fake-sock,1,0 TMUX_PANE=%5
TGT="$(cat "$TMP/t1.pid")"; export FAKE_PANE_PIDFILE="$TMP/t1.pid"
reset "$TMP/idle.txt"
out="$(env -u CLAUDE_CODE_SESSION_ID CREDO_SELF_RELOAD_TARGET_PID="$TGT" PATH="$FT:$BASE" "$PY" "$HELPER" check 2>&1)"; rc=$?
check "check no session id -> rc 1" "1" "$rc"
case "$out" in *"FAIL: no session id"*) ok "check no session id message" 0 ;; *) ok "check no session id message ($out)" 1 ;; esac
out="$(H check)"; rc=$?
check "check ok -> rc 0" "0" "$rc"
case "$out" in *"own pane:     %5 (tmux socket /tmp/fake-sock)"*) ok "check names own pane + socket" 0 ;; *) ok "check own pane ($out)" 1 ;; esac
case "$out" in *"/reload-plugins"*"/reload-skills"*'"."'*) ok "check lists the steps" 0 ;; *) ok "check lists the steps ($out)" 1 ;; esac
case "$out" in *"owner rule:   interactive -> ask once via the Ask tool"*) ok "check interactive owner rule" 0 ;; *) ok "check owner rule ($out)" 1 ;; esac
case "$out" in *"background:   never blocks"*) ok "check says background never blocks" 0 ;; *) ok "check background line ($out)" 1 ;; esac
check "check sends no keys" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"
start_target "$TMP/t2.pid"
out="$(TGT="$(cat "$TMP/t2.pid")" H check)"; rc=$?
check "check not in tmux -> rc 1" "1" "$rc"
case "$out" in *"FAIL: not running inside tmux"*) ok "check not-in-tmux message" 0 ;; *) ok "check not-in-tmux message ($out)" 1 ;; esac
sleep 300 & SLP=$!; PIDS="$PIDS $SLP"; echo "$SLP" > "$TMP/foreign.pid"
out="$(FAKE_PANE_PIDFILE="$TMP/foreign.pid" H run --user-confirmed --delay 0.1)"; rc=$?
check "run foreign pane -> rc 1" "1" "$rc"
check "run foreign pane sends no keys" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"

# --- owner rule ---------------------------------------------------------------------
reset "$TMP/idle.txt"; rm -f "$MODES/$SID"
out="$(H run)"; rc=$?
check "run without flag -> rc 3" "3" "$rc"
case "$out" in *"exactly one of --auto or --user-confirmed"*"Nothing was started."*) ok "run without flag message" 0 ;; *) ok "run without flag message ($out)" 1 ;; esac
out="$(H run --auto --user-confirmed)"; rc=$?
check "run with both flags -> rc 3" "3" "$rc"
for m in "" active passive; do
    if [ -n "$m" ]; then echo "$m" > "$MODES/$SID"; fi
    out="$(H run --auto)"; rc=$?
    check "run --auto in mode '${m:-none}' -> rc 3" "3" "$rc"
done
rm -f "$MODES/$SID"
ok "refusals write no marker" "$([ ! -e "$MARK" ] && echo 0 || echo 1)"
check "refusals send no keys" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"

# --- worker happy path (autonomous): the first "." starts the turn -------------------
echo autonomous > "$MODES/$SID"; reset "$TMP/idle.txt"
out="$(FAKE_DOT_CLEARS_AT=1 H run --auto --delay 0.1 --nudge-wait 1)"; rc=$?
check "run --auto autonomous -> rc 0" "0" "$rc"
case "$out" in *"End your turn now."*) ok "run tells the agent to end the turn" 0 ;; *) ok "run end-turn line ($out)" 1 ;; esac
wait_status '"status": "woken"'; ok "happy: marker woken" "$?"
"$PY" - "$FAKE_TMUX_LOG" <<'PYEOF'
import sys
keys = [l for l in open(sys.argv[1]).read().splitlines() if " send-keys " in l]
want = ["-S /tmp/fake-sock send-keys -t %5 -l /reload-plugins", "-S /tmp/fake-sock send-keys -t %5 Enter",
        "-S /tmp/fake-sock send-keys -t %5 -l /reload-skills", "-S /tmp/fake-sock send-keys -t %5 Enter",
        "-S /tmp/fake-sock send-keys -t %5 -l .", "-S /tmp/fake-sock send-keys -t %5 Enter"]
assert keys == want, keys
lines = open(sys.argv[1]).read().splitlines()
idx = [i for i, l in enumerate(lines) if " send-keys " in l]
caps = [i for i, l in enumerate(lines) if "capture-pane" in l]
for typed, enter in ((idx[0], idx[1]), (idx[2], idx[3]), (idx[4], idx[5])):
    assert any(typed < i < enter for i in caps), "verified before Enter"
assert sum(1 for i in caps if idx[1] < i < idx[2]) >= 2, "idle twice before /reload-skills"
PYEOF
ok "happy: exact key sequence, each verified, idle between the commands" "$?"
check "happy: every tmux call targets %5 only" "0" "$(grep -- '-t ' "$FAKE_TMUX_LOG" | grep -vc -- '-t %5')"
check "happy: wake file existed before the '.' Enter" "wake-present" "$(cat "$FAKE_TMUX_LOG.wake")"
ok "happy: wake file consumed" "$([ ! -e "$FAKE_WAKE_FILE" ] && echo 0 || echo 1)"
sleep 1.5
check "happy: no further '.' after the turn started" "1" "$(dots_typed)"
grep -q '"mode": "auto"' "$MARK"; ok "happy: marker records mode" "$?"
check "happy: both result lines seen before the next key" "2" "$(grep -c 'result line seen after /reload-' "$LOGF")"

# --- no "Reloaded" result line: waits RESULT_WAIT, then continues on the idle guard ---
rm -f "$LOGF"; reset "$TMP/idle.txt"
out="$(FAKE_NO_RESULT=1 FAKE_DOT_CLEARS_AT=1 H run --auto --delay 0.1 --nudge-wait 1)"
wait_status '"status": "woken"'; ok "no result line: still woken" "$?"
check "no result line: timeout logged for both" "2" "$(grep -c 'no result line after /reload-' "$LOGF")"

# --- fallback: no turn after the first "." -> re-sent; second one works ---------------
rm -f "$MODES/$SID"; reset "$TMP/idle.txt"
out="$(FAKE_DOT_CLEARS_AT=2 H run --user-confirmed --delay 0.1 --nudge-wait 0.8)"
wait_status '"status": "woken"'; ok "fallback: marker woken" "$?"
check "fallback: two '.' typed" "2" "$(dots_typed)"
grep -q '"nudges": 1' "$MARK"; ok "fallback: marker counts one re-send" "$?"
grep -q "no new turn within" "$LOGF"; ok "fallback: re-send logged" "$?"

# --- fallback: the "." stayed in the input (Enter lost) -> only Enter again ------------
reset "$TMP/idle.txt"
out="$(FAKE_DOT_ENTER_LOST=1 FAKE_DOT_CLEARS_AT=2 H run --user-confirmed --delay 0.1 --nudge-wait 0.8)"
wait_status '"status": "woken"'; ok "lost Enter: marker woken" "$?"
check "lost Enter: '.' typed only once" "1" "$(dots_typed)"
check "lost Enter: two Enters for the '.'" "2" "$(wc -l < "$FAKE_TMUX_LOG.wake" | tr -d ' ')"

# --- fallback bounded: never a new turn -> failed, wake file kept -------------------
reset "$TMP/idle.txt"
out="$(H run --user-confirmed --delay 0.1 --nudge-wait 0.5 --max-nudges 2)"
wait_status '"status": "failed: no new turn'; ok "bounded: marker failed: no new turn" "$?"
check "bounded: 1 + 2 '.' typed" "3" "$(dots_typed)"
ok "bounded: wake file kept for the next prompt" "$([ -e "$FAKE_WAKE_FILE" ] && echo 0 || echo 1)"

# --- background work in the footer never blocks ---------------------------------------
reset "$TMP/bg.txt"
export FAKE_TYPE_BELOW_FILE="$TMP/bgfoot.txt"
printf '%s\n' "  ? for shortcuts · 2 shells" "  ◯ general-purpose  Fixture audit" > "$FAKE_TYPE_BELOW_FILE"
out="$(FAKE_IDLE="$TMP/bg.txt" FAKE_DOT_CLEARS_AT=1 H run --user-confirmed --delay 0.1 --nudge-wait 1)"; rc=$?
check "background: run -> rc 0" "0" "$rc"
wait_status '"status": "woken"'; ok "background: marker woken" "$?"
grep -q "background work running" "$LOGF"; ok "background: never logged as blocking" "$([ $? -eq 0 ] && echo 1 || echo 0)"
unset FAKE_TYPE_BELOW_FILE

# --- typed user text -> gives up, nothing typed --------------------------------------
reset "$TMP/typed.txt"
out="$(H run --user-confirmed --delay 0.1 --timeout 1.5)"
wait_status '"status": "failed: not idle'; ok "typed: marker failed: not idle" "$?"
check "typed: no keys sent" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"
ok "typed: no wake file" "$([ ! -e "$FAKE_WAKE_FILE" ] && echo 0 || echo 1)"

# --- input changed between typing and Enter -> NO Enter --------------------------------
reset "$TMP/idle.txt"
out="$(FAKE_TYPE_PREFIX="user words " H run --user-confirmed --delay 0.1)"
wait_status '"status": "failed: typed text not confirmed'; ok "mismatch: marker failed" "$?"
check "mismatch: no Enter sent" "0" "$(grep -c 'send-keys -t %5 Enter' "$FAKE_TMUX_LOG")"
ok "mismatch: no wake file" "$([ ! -e "$FAKE_WAKE_FILE" ] && echo 0 || echo 1)"

# --- --update: allowlisted plugin update first, before -> after recorded ---------------
reset "$TMP/idle.txt"; : > "$FAKE_CLAUDE_LOG"
export FAKE_PLUGIN_STATE="$TMP/plugins.json"
echo '[{"id": "credo@mkt-a", "version": "0.1.0"}, {"id": "other@mkt-b", "version": "1.0.0"}]' > "$FAKE_PLUGIN_STATE"
out="$(H check --update)"
case "$out" in *"update:       mkt-a"*) ok "update: check shows the allowlist" 0 ;; *) ok "update: check allowlist ($out)" 1 ;; esac
out="$(FAKE_DOT_CLEARS_AT=99 H run --user-confirmed --update --delay 0.1 --nudge-wait 5)"
for _ in $(seq 1 50); do [ -e "$FAKE_WAKE_FILE" ] && break; sleep 0.2; done
grep -q "updated: credo 0.1.0 -> 0.2.0" "$FAKE_WAKE_FILE"; ok "update: wake file records before -> after" "$?"
grep -q '"kind": "reload"' "$FAKE_WAKE_FILE"; ok "update: wake file kind reload" "$?"
grep -qx "plugin update credo@mkt-a -y" "$FAKE_CLAUDE_LOG"; ok "update: allowlisted plugin updated" "$?"
grep -q "other@mkt-b" "$FAKE_CLAUDE_LOG"; ok "update: other marketplace untouched" "$([ $? -eq 0 ] && echo 1 || echo 0)"
"$PY" - "$FAKE_TMUX_LOG" "$FAKE_CLAUDE_LOG" <<'PYEOF'
import os, sys
assert os.path.getsize(sys.argv[2]) > 0
PYEOF
rm -f "$FAKE_WAKE_FILE"
wait_status '"status": "woken"'; ok "update: woken once the wake file is consumed" "$?"
grep -q '"update": "updated: credo 0.1.0 -> 0.2.0"' "$MARK"; ok "update: marker records the summary" "$?"

# --- cancel and status per session -----------------------------------------------------
reset "$TMP/typed.txt"
out="$(H run --user-confirmed --delay 0.1 --timeout 60)"
sleep 0.8
out="$(H run --user-confirmed --delay 0.1)"; rc=$?
check "second run while pending -> rc 1" "1" "$rc"
out="$(H status)"
case "$out" in "state: pending; pane: %5"*) ok "status shows pending" 0 ;; *) ok "status shows pending ($out)" 1 ;; esac
SID2="cccccccc-4444-5555-6666-dddddddddddd"
out="$(env CREDO_SELF_RELOAD_SESSION_ID=$SID2 CREDO_SELF_RELOAD_TARGET_PID="$TGT" PATH="$FT:$BASE" "$PY" "$HELPER" cancel 2>&1)"; rc=$?
check "cancel from another session -> rc 1" "1" "$rc"
grep -q '"status": "pending"' "$MARK"; ok "cancel from another session: still pending" "$?"
out="$(H cancel)"; rc=$?
check "cancel -> rc 0" "0" "$rc"
case "$out" in *"terminated"*) ok "cancel terminates the worker" 0 ;; *) ok "cancel message ($out)" 1 ;; esac
check "cancel: no keys sent" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"
out="$(H cancel)"; rc=$?
check "cancel with nothing pending -> rc 1" "1" "$rc"

# --- cancel while waiting for the new turn removes the wake file ---------------------
reset "$TMP/idle.txt"
out="$(FAKE_DOT_CLEARS_AT=99 H run --user-confirmed --delay 0.1 --nudge-wait 30)"
for _ in $(seq 1 75); do [ -e "$FAKE_WAKE_FILE" ] && grep -q '"status": "waking"' "$MARK" && break; sleep 0.2; done
out="$(H cancel)"; rc=$?
check "cancel while waking -> rc 0" "0" "$rc"
ok "cancel removes the wake file" "$([ ! -e "$FAKE_WAKE_FILE" ] && echo 0 || echo 1)"

# --- a turn starts while the "." is typed: woken, the own "." taken back, no Enter -----
reset "$TMP/idle.txt"
out="$(FAKE_TURN_ON_DOT_TYPE=1 H run --user-confirmed --delay 0.1 --nudge-wait 1)"
wait_status '"status": "woken"'; ok "typing window: woken" "$?"
grep -qxF -- "-S /tmp/fake-sock send-keys -t %5 BSpace" "$FAKE_TMUX_LOG"; ok "typing window: own '.' taken back" "$?"
check "typing window: no Enter after the '.'" "0" "$(sed -n '/send-keys -t %5 -l \.$/,$p' "$FAKE_TMUX_LOG" | grep -c 'send-keys -t %5 Enter')"

# --- abort between typing and Enter: the own text is taken back -----------------------
BS15="-S /tmp/fake-sock send-keys -t %5$(printf ' BSpace%.0s' $(seq 1 15))"
reset "$TMP/idle.txt"
out="$(FAKE_BUSY_ON_TYPE=1 H run --user-confirmed --delay 0.1)"
wait_status '"status": "failed: typed text not confirmed'; ok "busy while typing: failed, no Enter" "$?"
check "busy while typing: no Enter" "0" "$(grep -c 'send-keys -t %5 Enter' "$FAKE_TMUX_LOG")"
grep -qxF -- "$BS15" "$FAKE_TMUX_LOG"; ok "busy while typing: /reload-plugins taken back (15 BSpace)" "$?"
# user text mixed in: never touched
reset "$TMP/idle.txt"
out="$(FAKE_TYPE_PREFIX="user words " H run --user-confirmed --delay 0.1)"
wait_status '"status": "failed: typed text not confirmed'; ok "mixed input: failed" "$?"
check "mixed input: nothing taken back" "0" "$(grep -c 'BSpace' "$FAKE_TMUX_LOG")"
# cancel (SIGTERM) while typing
reset "$TMP/idle.txt"
out="$(FAKE_SLOW_TYPE=2 H run --user-confirmed --delay 0.1)"
for _ in $(seq 1 75); do grep -q -- '-l /reload-plugins' "$FAKE_TMUX_LOG" && break; sleep 0.2; done
sleep 0.3
out="$(H cancel)"; rc=$?
check "cancel while typing -> rc 0" "0" "$rc"
for _ in $(seq 1 30); do grep -q 'BSpace' "$FAKE_TMUX_LOG" && break; sleep 0.2; done
grep -qxF -- "$BS15" "$FAKE_TMUX_LOG"; ok "cancel while typing: own text taken back" "$?"
check "cancel while typing: no Enter" "0" "$(grep -c 'send-keys -t %5 Enter' "$FAKE_TMUX_LOG")"

# --- self-reload and self-compact never run at the same time --------------------------
CMARK="$CFG/credo/self-compact-$SID.json"
"$PY" -c 'import time; time.sleep(30)' _worker /fixture/credo-self-compact.py &
CW=$!; PIDS="$PIDS $CW"; sleep 0.2
printf '{"status": "sent", "session_id": "%s", "worker_pid": %s}' "$SID" "$CW" > "$CMARK"
reset "$TMP/idle.txt"
out="$(H run --user-confirmed --delay 0.1)"; rc=$?
check "pending self-compact -> self-reload refused" "1" "$rc"
case "$out" in *"self-compact"*"pending"*) ok "refusal names the self-compact" 0 ;; *) ok "refusal names the self-compact ($out)" 1 ;; esac
check "refused: no keys" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"
printf '{"status": "woken", "session_id": "%s", "worker_pid": %s}' "$SID" "$CW" > "$CMARK"
out="$(FAKE_DOT_CLEARS_AT=1 H run --user-confirmed --delay 0.1 --nudge-wait 1)"; rc=$?
check "finished self-compact -> self-reload runs" "0" "$rc"
wait_status '"status": "woken"'; ok "finished self-compact: reload woken" "$?"
kill "$CW" 2>/dev/null

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
