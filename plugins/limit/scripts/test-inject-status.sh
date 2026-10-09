#!/usr/bin/env bash
# test-inject-status.sh - The threshold ACTION line is delivered to the main
# session only: a hook call from inside a subagent (agent_id in the hook input)
# never gets the ACTION and does not consume the threshold.
# Uses a fake session id; only its own /tmp cache and state files are touched.
# shellcheck disable=SC2250

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SID="limit-test-inject-$$"
CACHE="/tmp/claude-mb-context-cache_${SID}.json"
STATE="/tmp/claude-mb-inject-state_${SID}.json"
AGENT_STATE="/tmp/claude-mb-inject-state_${SID}_agent_agent-1.json"
cleanup() { rm -f "$CACHE" "$STATE" "$AGENT_STATE"; }
trap cleanup EXIT
cleanup

export CLAUDE_MB_LIMIT_INJECT=true
export CLAUDE_MB_LIMIT_INJECT_THRESHOLDS="62,72,87"
export CLAUDE_MB_LIMIT_COMPACT_SKILL="acme:secure-skill"
export CLAUDE_MB_LIMIT_INJECT_INTERVAL=120

PASS=0
FAIL=0
check() {
    if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); echo "  PASS: $1"
    else FAIL=$((FAIL + 1)); echo "  FAIL: $1 (expected '$2', got '$3')"; fi
}

write_cache() { # compact_pct
    jq -n --arg u "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson p "$1" \
        '{updated_at:$u, ctx_pct:$p, compact_pct:$p, ctx_tokens:100000, ctx_window:200000,
          compact_ref_tokens:160000, five_hour_pct:10, seven_day_pct:20, session_cost:"1.00"}' > "$CACHE"
}

run_main() { # event
    jq -cn --arg s "$SID" --arg e "$1" '{session_id:$s, hook_event_name:$e}' \
        | "$SCRIPT_DIR/inject-status.sh"
}
run_sub() { # event
    jq -cn --arg s "$SID" --arg e "$1" \
        '{session_id:$s, hook_event_name:$e, agent_id:"agent-1", agent_type:"general-purpose"}' \
        | "$SCRIPT_DIR/inject-status.sh"
}
has_action() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null | grep -c '^ACTION:'; }
fired() { jq -c '.fired // []' "$STATE" 2>/dev/null || echo "[]"; }

echo ">>> subagent tool call crosses a threshold"
write_cache 65
out=$(run_sub PostToolUse)
check "subagent gets no ACTION" "0" "$(has_action "$out")"
check "threshold not consumed by the subagent" "[]" "$(fired)"

echo ">>> second subagent call (inside the routine interval)"
out=$(run_sub PostToolUse)
check "subagent still gets no ACTION" "0" "$(has_action "$out")"
check "threshold still not consumed" "[]" "$(fired)"

echo ">>> main session prompt after the subagent calls"
out=$(run_main UserPromptSubmit)
check "main session gets the ACTION" "1" "$(has_action "$out")"
check "ACTION names the skill" "1" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -c 'run acme:secure-skill now')"
check "threshold recorded after the main session saw it" "[62]" "$(fired)"

echo ">>> main session again at the same fill"
out=$(run_main PostToolUse)
check "ACTION fires only once per threshold" "0" "$(has_action "$out")"

echo ">>> next threshold crossed during a subagent call"
write_cache 75
out=$(run_sub PostToolUse)
check "subagent gets no ACTION at the next threshold" "0" "$(has_action "$out")"
check "next threshold not consumed by the subagent" "[62]" "$(fired)"
out=$(run_main PostToolUse)
check "main session gets the next ACTION" "1" "$(has_action "$out")"
check "next threshold recorded" "[62,72]" "$(fired)"

echo ">>> subagent call never writes the main state file"
write_cache 76
before=$(cksum < "$STATE")
rm -f "$AGENT_STATE"
out=$(run_sub PostToolUse)
check "subagent still gets the plain status line" "1" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""' | grep -c '^\[limit\] Context')"
check "main state file byte-identical after a subagent call" "$before" "$(cksum < "$STATE")"
check "subagent throttle lives in its own file" "1" "$([[ -f "$AGENT_STATE" ]] && echo 1 || echo 0)"
check "subagent file holds no fired list" "[]" "$(jq -c '.fired // []' "$AGENT_STATE" 2>/dev/null)"

echo ">>> agent_id null or empty counts as the main session"
write_cache 88
out=$(jq -cn --arg s "$SID" '{session_id:$s, hook_event_name:"PostToolUse", agent_id:null}' | "$SCRIPT_DIR/inject-status.sh")
check "agent_id null gets the 87 ACTION" "1" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -c '>= 87%')"
check "87 recorded" "[62,72,87]" "$(fired)"
write_cache 50
CLAUDE_MB_LIMIT_INJECT_INTERVAL=0 run_main PostToolUse > /dev/null
write_cache 65
out=$(jq -cn --arg s "$SID" '{session_id:$s, hook_event_name:"PostToolUse", agent_id:""}' | "$SCRIPT_DIR/inject-status.sh")
check "agent_id empty gets the ACTION after a reset" "1" "$(has_action "$out")"

echo ">>> reset after the fill drops below a threshold"
write_cache 50
out=$(CLAUDE_MB_LIMIT_INJECT_INTERVAL=0 run_main PostToolUse)
check "fired list reset after the drop" "[]" "$(fired)"
write_cache 63
out=$(run_main PostToolUse)
check "62 fires again after the reset" "1" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -c '>= 62%')"
check "62 recorded again" "[62]" "$(fired)"

echo ">>> reset persisted while the throttle is still running"
# fired is [62] and a line was just written, so the 120 s interval is running
write_cache 50
out=$(run_main PostToolUse)
check "no line inside the interval" "" "$out"
check "reset persisted without a line" "[]" "$(fired)"
write_cache 63
out=$(run_main PostToolUse)
check "62 fires again after the unlogged drop" "1" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""' | grep -c '>= 62%')"
check "62 recorded after the re-fire" "[62]" "$(fired)"
write_cache 50
before=$(cksum < "$STATE")
out=$(run_sub PostToolUse)
check "subagent drop does not persist the reset" "$before" "$(cksum < "$STATE")"

echo ">>> malformed input"
before=$(cksum < "$STATE")
out=$(printf 'not json {' | "$SCRIPT_DIR/inject-status.sh"); rc=$?
check "malformed input exits 0" "0" "$rc"
check "malformed input prints nothing" "" "$out"
check "malformed input leaves the state unchanged" "$before" "$(cksum < "$STATE")"
out=$(jq -cn --arg s "$SID" '{session_id:$s, agent_id:"../evil"}' | "$SCRIPT_DIR/inject-status.sh"); rc=$?
check "path-like agent_id exits 0" "0" "$rc"
check "path-like agent_id prints nothing" "" "$out"
check "path-like agent_id leaves the state unchanged" "$before" "$(cksum < "$STATE")"

echo ""
echo "passed: $PASS failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
