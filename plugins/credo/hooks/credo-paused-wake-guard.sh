#!/usr/bin/env bash
# credo-paused-wake-guard.sh - PreToolUse hook on ScheduleWakeup.
#
# While this session's autonomy keep-alive is paused (credo/autonomy/<session_id>/paused,
# set when the owner writes during an autonomous run), the session must not schedule its own
# wake-ups: the owner is present and the session only reacts to messages. This hook denies a
# ScheduleWakeup call in that state. Any other state, or any problem reading the input,
# lets the call through (fail-open: it never blocks a wake-up of a running autonomous run).
set -u

INPUT=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || exit 0
[[ -n "$session_id" && "$session_id" != "null" ]] || exit 0
[[ "$session_id" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0

paused="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/autonomy/${session_id}/paused"
[[ -f "$paused" ]] || exit 0

reason="credo: autonomy keep-alive is paused for this session (the owner is present). Do not schedule wake-ups; react to owner and peer messages only. The owner re-arms autonomy when wanted."
jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse",
  permissionDecision: "deny", permissionDecisionReason: $r}}'
exit 0
