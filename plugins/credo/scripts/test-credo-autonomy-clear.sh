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

# --- self-wake file (credo_pane_wake: self-reload / self-compact typed ".") ---------
SW="$CLAUDE_CONFIG_DIR/credo/self-wake-$SID"
mkdir -p "$CLAUDE_CONFIG_DIR/credo"
has() { # name needle haystack
    case "$3" in *"$2"*) check "$1" yes yes ;; *) check "$1" yes "no ($3)" ;; esac
}
# "." with a reload wake file: consumed, autonomy kept, reload note injected
arm; echo '{"kind": "reload", "update": "updated: credo 0.1.0 -> 0.2.0"}' > "$SW"
out="$(out_of ".")"
expect "self-wake '.' keeps autonomy" kept
if [ -e "$SW" ]; then got=kept; else got=consumed; fi
check "self-wake '.' consumes the wake file" consumed "$got"
has "reload note tag" "[credo-self-reload]" "$out"
has "reload note names the fallback" "/credo:self-restart" "$out"
has "reload note carries the update summary" "updated: credo 0.1.0 -> 0.2.0" "$out"
has "reload note: the '.' is not the user" "not a user message" "$out"
# "." WITHOUT a wake file is a real user message
arm; out="$(out_of ".")"
expect "plain '.' without wake file pauses" paused
# another prompt with a wake file: consumed (the turn started), note added, still pauses
arm; echo '{"kind": "compact", "compact_done": true}' > "$SW"
out="$(out_of "a real user message")"
expect "user message with wake file still pauses" paused
if [ -e "$SW" ]; then got=kept; else got=consumed; fi
check "user message consumes the wake file" consumed "$got"
has "compact note tag" "[credo-self-compact]" "$out"
has "real message: handled as a real message" "this prompt is a real message - handle it normally" "$out"
case "$out" in *"not a user message"*) check "real message never labelled 'not a user message'" yes no ;; *) check "real message never labelled 'not a user message'" yes yes ;; esac
# the "." itself is labelled as the helper's
arm; echo '{"kind": "compact", "compact_done": true}' > "$SW"
out="$(out_of ".")"
has "'.' labelled as typed by the helper" "not a user message" "$out"
case "$out" in *"real message"*) check "'.' not called a real message" yes no ;; *) check "'.' not called a real message" yes yes ;; esac
# an expired wake file (older than 1 h) is dropped without a note
arm; echo '{"kind": "reload"}' > "$SW"; touch -d '2 hours ago' "$SW"
out="$(out_of ".")"
expect "expired wake file: '.' pauses like a user message" paused
if [ -e "$SW" ]; then got=kept; else got=consumed; fi
check "expired wake file removed" consumed "$got"
case "$out" in *"credo-self-"*) check "expired wake file: no note" yes no ;; *) check "expired wake file: no note" yes yes ;; esac
# no jq: the wake file is still consumed and the note still reaches the context
NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
for t in bash cat tr date rm grep sed dirname basename ls sort tail find printf touch head mkdir; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOJQ/$t"
done
arm; echo '{"kind": "compact", "compact_done": true}' > "$SW"
out="$(printf '{"prompt": ".", "session_id": "%s"}' "$SID" | PATH="$NOJQ" bash "$HOOK" 2>/dev/null)"
if [ -e "$SW" ]; then got=kept; else got=consumed; fi
check "no jq: wake file consumed" consumed "$got"
has "no jq: note printed" "[credo-self-compact]" "$out"
expect "no jq: the helper's '.' keeps autonomy" kept
# peer message / task notification with a wake file: consumed, note, autonomy kept
arm; echo '{"kind": "compact", "compact_done": false}' > "$SW"
out="$(out_of "<task-notification>done</task-notification>")"
expect "task notification with wake file keeps autonomy" kept
if [ -e "$SW" ]; then got=kept; else got=consumed; fi
check "task notification consumes the wake file" consumed "$got"
has "compact note without done signal asks to check" "check whether the compact" "$out"
# another session's wake file is never touched
arm; echo '{"kind": "reload"}' > "$CLAUDE_CONFIG_DIR/credo/self-wake-other-session"
out="$(out_of ".")"
if [ -e "$CLAUDE_CONFIG_DIR/credo/self-wake-other-session" ]; then got=kept; else got=consumed; fi
check "other session's wake file untouched" kept "$got"
expect "'.' without own wake file pauses" paused
# version check of the reload note from a plugin-cache layout
CACHE="$TMP/cache/plugins/cache/mkt-a/credo"
mkdir -p "$CACHE/0.1.0/.claude-plugin" "$CACHE/0.2.0"
cp -r "$HERE/../hooks" "$CACHE/0.1.0/hooks"
echo '{"version": "0.1.0"}' > "$CACHE/0.1.0/.claude-plugin/plugin.json"
arm; echo '{"kind": "reload"}' > "$SW"
out="$(jq -n --arg p "." --arg s "$SID" '{prompt: $p, session_id: $s}' | bash "$CACHE/0.1.0/hooks/credo-autonomy-clear.sh" 2>/dev/null)"
has "version mismatch reported" "loaded credo 0.1.0, newest in the plugin cache 0.2.0" "$out"
echo '{"kind": "reload"}' > "$SW"
mkdir -p "$TMP/cache2/plugins/cache/mkt-a/credo"
cp -r "$CACHE/0.1.0" "$TMP/cache2/plugins/cache/mkt-a/credo/0.3.0"
echo '{"version": "0.3.0"}' > "$TMP/cache2/plugins/cache/mkt-a/credo/0.3.0/.claude-plugin/plugin.json"
out="$(jq -n --arg p "." --arg s "$SID" '{prompt: $p, session_id: $s}' | bash "$TMP/cache2/plugins/cache/mkt-a/credo/0.3.0/hooks/credo-autonomy-clear.sh" 2>/dev/null)"
has "version match reported" "loaded credo 0.3.0 = newest in the plugin cache" "$out"

rm -rf "$TMP"
echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
