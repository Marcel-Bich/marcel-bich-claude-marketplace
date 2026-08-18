#!/usr/bin/env bash
# credo-decision-set.sh <accepted|declined> [session_id]
#
# Record the per-session credo-workflow decision so the SessionStart hook
# (credo-session-start.sh) stops asking once the user has decided. State is one
# file per session_id under the session-decisions dir, holding exactly one word:
#   accepted -> user opted into the credo workflow for this session
#   declined -> user opted out; the hook then stays silent
#
# The session_id is resolved in the same order as session-mode-set.sh:
#   1. the second positional argument (if given)
#   2. $CREDO_SESSION_ID        (test / manual override)
#   3. $CLAUDE_CODE_SESSION_ID  (set by Claude Code for tool bash calls)
# Without a session_id the state cannot be keyed -> hard error (no write).
#
# State is written atomically (tmp + mv -f), mirroring session-mode-set.sh.
set -u

decision="${1:-}"
case "$decision" in
    accepted|declined) ;;
    *)
        echo "Usage: credo-decision-set.sh <accepted|declined> [session_id]" >&2
        exit 1
        ;;
esac

session_id="${2:-${CREDO_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"
if [ -z "$session_id" ]; then
    echo "credo-decision-set: cannot determine session_id (pass it as arg 2 or set CLAUDE_CODE_SESSION_ID)" >&2
    exit 1
fi
case "$session_id" in
    *[!A-Za-z0-9._-]*|.|*..*)
        echo "credo-decision-set: invalid session_id (unexpected characters or path traversal)" >&2
        exit 1
        ;;
esac

STATE_DIR="${CREDO_SESSION_DECISIONS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-decisions}"
mkdir -p "$STATE_DIR" || { echo "credo-decision-set: cannot create state dir $STATE_DIR" >&2; exit 1; }

state_file="$STATE_DIR/$session_id"
tmp="$(mktemp "${state_file}.XXXXXX")" || { echo "credo-decision-set: mktemp failed" >&2; exit 1; }
printf '%s\n' "$decision" > "$tmp"
mv -f "$tmp" "$state_file"

echo "credo-decision = $decision (session $session_id)"
