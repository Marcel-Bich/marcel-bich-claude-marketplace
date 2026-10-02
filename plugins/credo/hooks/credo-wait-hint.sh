#!/usr/bin/env bash
# credo-wait-hint.sh - PreToolUse Bash hint against self-matching wait loops.
#
# `until ! pgrep -f "X"; do sleep 5; done` never ends: pgrep -f matches the
# waiting shell's own command line, which contains X. Two background waits hung
# that way. This hook only adds a hint when a Bash command loops on pgrep -f; it
# never blocks. The rule itself lives in the orchestration skill.
#
# Disable with CREDO_WAIT_HINT=0. Always exits 0.

case "${CREDO_WAIT_HINT:-1}" in
    0|false|no|off) exit 0 ;;
esac
command -v jq >/dev/null 2>&1 || exit 0

cmd="$(jq -r '.tool_input.command // empty' 2>/dev/null || true)"
case "$cmd" in
    *pgrep*-f*) ;;
    *) exit 0 ;;
esac
printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_])(until|while)[[:space:]]' || exit 0

jq -n --arg c "[credo-wait] This loop waits on pgrep -f, which also matches the waiting shell's own command line, so it may never end. Wait on a result file or one specific PID with a time limit instead, or rely on the harness completion notification (orchestration skill, Monitoring)." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c},suppressOutput:true}' 2>/dev/null
exit 0
