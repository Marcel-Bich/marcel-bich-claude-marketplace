#!/usr/bin/env bash
# Tests for hooks/credo-paused-wake-guard.sh: ScheduleWakeup is denied only while this
# session's autonomy keep-alive is paused; anything else passes silently.
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/credo-paused-wake-guard.sh"
T=$(mktemp -d)
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (want '$2', got '$3')"; fi; }
run() { printf '%s' "$1" | CLAUDE_CONFIG_DIR="$T" bash "$HOOK" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }

mkdir -p "$T/credo/autonomy/s1" "$T/credo/autonomy/s2"
check "not paused: silent" "" "$(run '{"session_id":"s1","tool_name":"ScheduleWakeup"}')"
touch "$T/credo/autonomy/s1/paused"
check "paused: deny" "deny" "$(run '{"session_id":"s1","tool_name":"ScheduleWakeup"}')"
check "other session not paused: silent" "" "$(run '{"session_id":"s2","tool_name":"ScheduleWakeup"}')"
check "no session id: silent" "" "$(run '{"tool_name":"ScheduleWakeup"}')"
check "unsafe session id: silent" "" "$(run '{"session_id":"../s1","tool_name":"ScheduleWakeup"}')"
check "garbage input: silent" "" "$(run 'not json')"

echo "temp dir (remove by this literal path): $T"
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
