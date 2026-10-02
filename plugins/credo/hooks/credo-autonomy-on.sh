#!/usr/bin/env bash
# credo-autonomy-on.sh [--session <session_id>] [reason...]
#
# Activate the full-autonomy keep-alive mode FOR ONE SESSION: sets this
# session's autonomy "active" flag and lifts its paused opt-out. Call this
# ONLY when full autonomy plus AFK has been explicitly granted (the session-mode
# set script calls it when switching to the autonomous mode). Never call it on
# your own.
#
# State is per session (see credo-autonomy-lib.sh):
#   ${CREDO_AUTONOMY_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/autonomy}/<session_id>/
# so autonomy in one session never affects another. The session_id resolves
# from --session <id> (or --session=<id>), else $CREDO_SESSION_ID, else
# $CLAUDE_CODE_SESSION_ID. Without a valid session_id -> hard error, no write.
# Optional remaining arguments: a short reason / repo hint recorded in the flag.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=credo-autonomy-lib.sh
. "$SCRIPT_DIR/credo-autonomy-lib.sh"

arg_session_id=""
reason_parts=()
while [ $# -gt 0 ]; do
    case "$1" in
        --session) arg_session_id="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --session=*) arg_session_id="${1#--session=}"; shift ;;
        *) reason_parts+=("$1"); shift ;;
    esac
done

if ! session_id="$(credo_autonomy_resolve_id "$arg_session_id")"; then
    echo "credo-autonomy-on: cannot determine a valid session_id (pass --session <id> or set CLAUDE_CODE_SESSION_ID); nothing written" >&2
    exit 1
fi

STATE_DIR="$(credo_autonomy_dir "$session_id")"
FLAG="$STATE_DIR/active"
mkdir -p "$STATE_DIR"
rm -f "$STATE_DIR/paused" 2>/dev/null || true
reason="${reason_parts[*]:-}"
ts="$(date '+%Y-%m-%d %H:%M:%S %z')"
{
    echo "activated_at: $ts"
    echo "session_id: $session_id"
    if [ -n "$reason" ]; then echo "reason: $reason"; fi
} > "$FLAG"
echo "credo-autonomy ON for session $session_id ($ts)${reason:+ - $reason}"
