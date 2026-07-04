#!/usr/bin/env bash
# session-mode-set.sh <active|passive|autonomous> [session_id]
#
# Set the persistent, per-session credo mode and couple it to the autonomy
# keep-alive flags:
#   - autonomous       -> credo-autonomy-on.sh  (keep-alive ON, paused opt-out lifted)
#   - active | passive -> credo-autonomy-off.sh (keep-alive OFF, paused set)
# Modes are exclusive: one state file per session, holding exactly one mode.
#
# State is written atomically (tmp + mv -f) to a file keyed by session_id under
# the session-modes dir. The session_id is resolved in this order:
#   1. the second positional argument (if given)
#   2. $CREDO_SESSION_ID   (test / manual override)
#   3. $CLAUDE_CODE_SESSION_ID (set by Claude Code for tool bash calls)
# Without a session_id the state cannot be keyed -> hard error (no write).
#
# Failure-safe for the flag coupling: the mode is still written even if a
# coupling helper is missing or fails.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mode="${1:-}"
case "$mode" in
    active|passive|autonomous) ;;
    *)
        echo "Usage: session-mode-set.sh <active|passive|autonomous> [session_id]" >&2
        exit 1
        ;;
esac

session_id="${2:-${CREDO_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"
if [ -z "$session_id" ]; then
    echo "session-mode-set: cannot determine session_id (pass it as arg 2 or set CLAUDE_CODE_SESSION_ID)" >&2
    exit 1
fi
case "$session_id" in
    *[!A-Za-z0-9._-]*)
        echo "session-mode-set: invalid session_id (unexpected characters)" >&2
        exit 1
        ;;
esac

STATE_DIR="${CREDO_SESSION_MODES_DIR:-$HOME/.claude/credo/session-modes}"
mkdir -p "$STATE_DIR" || { echo "session-mode-set: cannot create state dir $STATE_DIR" >&2; exit 1; }

state_file="$STATE_DIR/$session_id"
tmp="$(mktemp "${state_file}.XXXXXX")" || { echo "session-mode-set: mktemp failed" >&2; exit 1; }
printf '%s\n' "$mode" > "$tmp"
mv -f "$tmp" "$state_file"

# --- couple to the autonomy keep-alive flags -------------------------------
if [ "$mode" = "autonomous" ]; then
    [ -x "$SCRIPT_DIR/credo-autonomy-on.sh" ] && "$SCRIPT_DIR/credo-autonomy-on.sh" "session-mode: autonomous set for session $session_id" || true
else
    [ -x "$SCRIPT_DIR/credo-autonomy-off.sh" ] && "$SCRIPT_DIR/credo-autonomy-off.sh" || true
fi

echo "session-mode = $mode (session $session_id)"
