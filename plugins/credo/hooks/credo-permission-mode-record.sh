#!/usr/bin/env bash
# credo-permission-mode-record.sh - credo plugin (SessionStart + UserPromptSubmit hook)
#
# Records the LIVE permission mode of a session so /credo:self-restart can restore it.
# A mode changed during the session (Shift+Tab, /permissions) is not in the process
# argv, and bypassPermissions is not restored by `claude --resume`, so the helper
# needs this record to bring the session back in the mode the user already had.
#
# Record: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-mode/<session_id>
#         one line, the hook input's "permission_mode" (e.g. default, acceptEdits,
#         plan, bypassPermissions). Written atomically and only when it changed.
# Pruning: on SessionStart only, records not rewritten for 30 days are removed.
#
# Cheap by design (runs on every prompt): one jq call, one small file compare.
# Failure-safe: no output, always exit 0; a problem just leaves no record (the helper
# then uses the original argv as-is and never invents a mode).

trap 'exit 0' ERR
command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$INPUT" ] || exit 0
sid="" mode="" event=""
{
    IFS= read -r sid
    IFS= read -r mode
    IFS= read -r event
} < <(printf '%s' "$INPUT" | jq -r '(.session_id // "" | tostring), (.permission_mode // "" | tostring), (.hook_event_name // "" | tostring)' 2>/dev/null)
case "$sid" in
    ""|.|..|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
case "$mode" in
    ""|*[!A-Za-z]*) exit 0 ;;
esac

state="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
state="${state%/}/credo/session-mode"
rec="$state/$sid"
if [ -f "$rec" ] && [ "$(cat "$rec" 2>/dev/null)" = "$mode" ]; then
    exit 0
fi
mkdir -p "$state" 2>/dev/null || exit 0
printf '%s\n' "$mode" > "$rec.tmp.$$" 2>/dev/null && mv -f "$rec.tmp.$$" "$rec" 2>/dev/null
if [ "$event" = "SessionStart" ]; then
    find "$state" -maxdepth 1 -type f -mtime +30 -delete 2>/dev/null
fi
exit 0
