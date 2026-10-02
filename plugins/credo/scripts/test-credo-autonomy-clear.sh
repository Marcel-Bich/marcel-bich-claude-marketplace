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

rm -rf "$TMP"
echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
