#!/usr/bin/env bash
# credo-autonomy-wake-mark.sh <delaySeconds> [session_id]
#
# Record a planned ScheduleWakeup time for the Stop keep-alive hook
# (credo-autonomy-keepalive.sh). Writes the absolute Unix timestamp
# (now + delaySeconds) to THIS session's wake marker
#   ${CREDO_AUTONOMY_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/autonomy}/<session_id>/wake-scheduled
# (see credo-autonomy-lib.sh). The Stop hook then lets this session's turn stop
# because a self-wake lies in the future. ALWAYS use this together with a
# ScheduleWakeup call, with the same delaySeconds.
#
# session_id resolves from the second argument, else $CREDO_SESSION_ID, else
# $CLAUDE_CODE_SESSION_ID. Without a valid session_id -> hard error, no write.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=credo-autonomy-lib.sh
. "$SCRIPT_DIR/credo-autonomy-lib.sh"

delay="${1:-}"
case "$delay" in
    ''|*[!0-9]*)
        echo "usage: credo-autonomy-wake-mark.sh <delaySeconds (integer)> [session_id]" >&2
        exit 1
        ;;
esac

if ! session_id="$(credo_autonomy_resolve_id "${2:-}")"; then
    echo "credo-autonomy-wake-mark: cannot determine a valid session_id (pass it as arg 2 or set CLAUDE_CODE_SESSION_ID); nothing written" >&2
    exit 1
fi

STATE_DIR="$(credo_autonomy_dir "$session_id")"
mkdir -p "$STATE_DIR"
now="$(date +%s)"
target="$((now + delay))"
echo "$target" > "$STATE_DIR/wake-scheduled"
echo "wake marked for $target (now=$now, +${delay}s, session $session_id)"
