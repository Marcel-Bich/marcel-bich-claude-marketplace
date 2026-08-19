#!/usr/bin/env bash
# role-set.sh <task|plan|clear> [session_id]
#
# Set the persistent, per-session credo ROLE. A role is a GUIDING default that is
# orthogonal to the session mode (active | passive | autonomous): a role can
# coexist with any mode. Default = NO role (the agent does everything, as today).
#   - task  -> default owner of implementing GO items, INCLUDING commits and push
#              where dogma permissions allow (the single index owner).
#   - plan  -> default owner of clarifying 1_clarify items, WITHOUT commits or push
#              (the task/build role owns commits and push).
# Roles are exclusive: one state file per session, holding exactly one role.
#
# State is written atomically (tmp + mv -f) to a file keyed by session_id under
# the session-roles dir. The session_id is resolved in this order:
#   1. the second positional argument (if given)
#   2. $CREDO_SESSION_ID   (test / manual override)
#   3. $CLAUDE_CODE_SESSION_ID (set by Claude Code for tool bash calls)
# Without a session_id the state cannot be keyed -> hard error (no write).
#
# A role is a guiding default only; explicit user instruction always overrides it.
# The role is re-injected on every prompt by role-inject.sh, so it survives
# context compaction, new sessions and subagents (stored on disk, not in context).
set -u

role="${1:-}"
case "$role" in
    task|plan|clear) ;;
    *)
        echo "Usage: role-set.sh <task|plan|clear> [session_id]" >&2
        exit 1
        ;;
esac

session_id="${2:-${CREDO_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"
if [ -z "$session_id" ]; then
    echo "role-set: cannot determine session_id (pass it as arg 2 or set CLAUDE_CODE_SESSION_ID)" >&2
    exit 1
fi
case "$session_id" in
    *[!A-Za-z0-9._-]*|.|*..*)
        echo "role-set: invalid session_id (unexpected characters or path traversal)" >&2
        exit 1
        ;;
esac

STATE_DIR="${CREDO_SESSION_ROLES_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-roles}"
mkdir -p "$STATE_DIR" || { echo "role-set: cannot create state dir $STATE_DIR" >&2; exit 1; }

state_file="$STATE_DIR/$session_id"

# clear: remove this session's role file, then done (return to no-role/does-everything).
if [ "$role" = "clear" ]; then
    rm -f "$state_file"
    echo "session-role cleared (session $session_id)"
    exit 0
fi

tmp="$(mktemp "${state_file}.XXXXXX")" || { echo "role-set: mktemp failed" >&2; exit 1; }
printf '%s\n' "$role" > "$tmp"
mv -f "$tmp" "$state_file"

echo "session-role = $role (session $session_id)"
