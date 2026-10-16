#!/usr/bin/env bash
# credo-autonomy-permission-notify.sh - Notification hook (permission_prompt).
#
# In an unattended credo autonomous run a permission prompt blocks the whole run
# silently: nobody is at the keyboard and no push goes out. When a permission prompt
# appears in an autonomous session, this hook sends one high-priority ntfy so the
# owner is called back to the PC. It acts only when the autonomy flag of THIS session
# is set and not paused (the same state credo-autonomy-keepalive.sh reads).
#
# Registered in hooks/hooks.json for notification_type "permission_prompt". Every
# other notification_type is ignored too (defence in depth).
#
# The push goes through scripts/credo-ntfy-send.sh, which owns the topic: this hook
# never prints or logs it. The send runs in the background so the hook returns at
# once. CREDO_NTFY_SEND overrides the sender path (tests use a stub).
#
# Failure-safe: any problem -> exit 0 with no output. Never blocks a prompt.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
# shellcheck source=credo-autonomy-lib.sh
. "$SCRIPT_DIR/credo-autonomy-lib.sh" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

ntype="$(printf '%s' "$input" | jq -r '.notification_type // empty' 2>/dev/null || true)"
[ "$ntype" = "permission_prompt" ] || exit 0

# Unknown session -> not provably autonomous -> stay silent.
stdin_session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
session_id="$(credo_autonomy_resolve_id "$stdin_session_id")" || exit 0
STATE_DIR="$(credo_autonomy_dir "$session_id")"
[ -f "$STATE_DIR/active" ] || exit 0
[ -f "$STATE_DIR/paused" ] && exit 0

SEND="${CREDO_NTFY_SEND:-$SCRIPT_DIR/../scripts/credo-ntfy-send.sh}"
[ -x "$SEND" ] || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
project_dir="${cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}"
project="$(basename -- "$project_dir" 2>/dev/null || true)"

msg="$(printf '%s' "$input" | jq -r '.message // empty' 2>/dev/null || true)"
msg="$(printf '%s' "$msg" | tr -d '[:cntrl:]')"
msg="${msg:0:200}"

body="Project: ${project:-unknown}. Prompt: ${msg:-(no message)}"
body="$(printf '%s' "$body" | tr -d '[:cntrl:]')"

CREDO_NTFY_PRIORITY=high "$SEND" -t "credo: permission prompt blocks run" "$body" \
    >/dev/null 2>&1 </dev/null &

exit 0
