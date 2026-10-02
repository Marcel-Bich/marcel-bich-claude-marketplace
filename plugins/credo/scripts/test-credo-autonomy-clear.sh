#!/usr/bin/env bash
# Tests for hooks/credo-autonomy-clear.sh: which prompts pause autonomy.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/credo-autonomy-clear.sh"
SID="11111111-2222-3333-4444-555555555555"

pass=0
fail=0
TMP="$(mktemp -d)"
export CREDO_AUTONOMY_DIR="$TMP/autonomy"
export CREDO_SESSION_MODES_DIR="$TMP/modes"
export CLAUDE_CONFIG_DIR="$TMP/cfg"

arm() {
    mkdir -p "$CREDO_AUTONOMY_DIR/$SID" "$CREDO_SESSION_MODES_DIR"
    : > "$CREDO_AUTONOMY_DIR/$SID/active"
    rm -f "$CREDO_AUTONOMY_DIR/$SID/paused"
    printf 'autonomous\n' > "$CREDO_SESSION_MODES_DIR/$SID"
}

run_prompt() {
    jq -n --arg p "$1" --arg s "$SID" '{prompt: $p, session_id: $s}' | bash "$HOOK" >/dev/null 2>&1
}

expect() {
    local name="$1" want="$2" got="kept"
    [ -f "$CREDO_AUTONOMY_DIR/$SID/active" ] || got="paused"
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $name (want $want, got $got)"
    fi
}

arm; run_prompt "please also check the logs"
expect "real user message pauses" paused

arm; run_prompt "[CREDO-AUTONOMY-WAKE] standby check"
expect "wake marker keeps autonomy" kept

arm; run_prompt '<cross-session-message from="uds:/x.sock">hi</cross-session-message>'
expect "peer message keeps autonomy" kept

arm; run_prompt '[Cross-session idle notice] "disk", which you asked to be notified about, is idle now'
expect "idle notice keeps autonomy" kept

arm; run_prompt '[Cross-session delivery notice] "disk" holds your message for its user approval'
expect "delivery notice keeps autonomy" kept

arm; run_prompt "<task-notification>done</task-notification>"
expect "task notification keeps autonomy" kept

# stale wake (autonomy no longer active, e.g. switched to active/passive): dropped
out_of() { jq -n --arg p "$1" --arg s "$SID" '{prompt: $p, session_id: $s}' | bash "$HOOK" 2>/dev/null; }
arm; out="$(out_of "[CREDO-AUTONOMY-WAKE] standby check")"
if printf '%s' "$out" | grep -q '"block"'; then fail=$((fail + 1)); echo "FAIL: live wake must not be blocked"; else pass=$((pass + 1)); fi
# autonomy PAUSED by a user message (flag gone, mode still autonomous): wake kept
arm; rm -f "$CREDO_AUTONOMY_DIR/$SID/active"
out="$(out_of "[CREDO-AUTONOMY-WAKE] standby check")"
if printf '%s' "$out" | grep -q '"block"'; then fail=$((fail + 1)); echo "FAIL: wake during autonomy pause must be kept"; else pass=$((pass + 1)); fi
# no mode file at all: not provably switched -> kept
rm -f "$CREDO_SESSION_MODES_DIR/$SID"
out="$(out_of "[CREDO-AUTONOMY-WAKE] standby check")"
if printf '%s' "$out" | grep -q '"block"'; then fail=$((fail + 1)); echo "FAIL: wake without a mode file must be kept"; else pass=$((pass + 1)); fi
# switched to passive: dropped
printf 'passive\n' > "$CREDO_SESSION_MODES_DIR/$SID"
out="$(out_of "[CREDO-AUTONOMY-WAKE] standby check")"
if printf '%s' "$out" | grep -q '"decision": *"block"'; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: wake after switch to passive must be dropped"; fi
# switched to active: dropped
printf 'active\n' > "$CREDO_SESSION_MODES_DIR/$SID"
out="$(out_of "[CREDO-AUTONOMY-WAKE] standby check")"
if printf '%s' "$out" | grep -q '"decision": *"block"'; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: stale wake must be blocked (got: $out)"; fi
out="$(out_of "a normal user message")"
if printf '%s' "$out" | grep -q '"block"'; then fail=$((fail + 1)); echo "FAIL: user message must never be blocked"; else pass=$((pass + 1)); fi

# --- wake marker across pause + re-arm --------------------------------------
# A user message pauses autonomy; the agent re-arms it with credo-autonomy-on.sh.
# A ScheduleWakeup marked before the pause is still pending in the harness, so its
# still-future marker must survive both steps and keep satisfying the Stop hook.
HOOKS="$HERE/../hooks"
WAKE_FILE="$CREDO_AUTONOMY_DIR/$SID/wake-scheduled"
keepalive_rc() {
    jq -n --arg s "$SID" '{session_id: $s, stop_hook_active: false}' \
        | bash "$HOOKS/credo-autonomy-keepalive.sh" >/dev/null 2>&1
    echo $?
}
check() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $name (want $want, got $got)"
    fi
}

arm; bash "$HOOKS/credo-autonomy-wake-mark.sh" 1800 "$SID" >/dev/null
run_prompt "just some context for the run"
if [ -f "$WAKE_FILE" ]; then got=kept; else got=deleted; fi
check "pause keeps a future wake marker" kept "$got"
bash "$HOOKS/credo-autonomy-on.sh" --session "$SID" >/dev/null
if [ -f "$WAKE_FILE" ]; then got=kept; else got=deleted; fi
check "re-arm keeps a future wake marker" kept "$got"
check "keepalive after re-arm honors the earlier wake" 0 "$(keepalive_rc)"

# a marker already in the past is useless: after pause + re-arm the Stop hook blocks
arm; echo "$(( $(date +%s) - 60 ))" > "$WAKE_FILE"
run_prompt "another context note"
bash "$HOOKS/credo-autonomy-on.sh" --session "$SID" >/dev/null
check "keepalive blocks on a past wake after re-arm" 2 "$(keepalive_rc)"

# an explicit autonomy-off (also used by a switch to active/passive) clears wake state
arm; bash "$HOOKS/credo-autonomy-wake-mark.sh" 1800 "$SID" >/dev/null
bash "$HOOKS/credo-autonomy-off.sh" --mode-switch "$SID" >/dev/null 2>&1
if [ -f "$WAKE_FILE" ]; then got=kept; else got=deleted; fi
check "autonomy-off clears the wake marker" deleted "$got"

rm -rf "$TMP"
echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
