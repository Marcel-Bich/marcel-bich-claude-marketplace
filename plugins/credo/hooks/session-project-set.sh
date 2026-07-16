#!/usr/bin/env bash
# session-project-set.sh <abs-path> [session_id]
#
# Pin the target repo for credo's PROJECT layer (.credo, config, items) for this
# session. This is layer 2 of `credo-config.sh resolve-project`: it lets a launch
# hub (a shell cwd you start other repos from) point credo at the repo you are
# actually working on, without changing the cwd or exporting CREDO_DIR by hand.
#
# The absolute target repo path is written atomically (tmp + mv -f) to a file
# keyed by session_id under the session-projects dir. Mirrors session-mode-set.sh.
# The session_id is resolved in this order:
#   1. the second positional argument (if given)
#   2. $CREDO_SESSION_ID       (test / manual override)
#   3. $CLAUDE_CODE_SESSION_ID (set by Claude Code for tool bash calls)
# Without a session_id the pin cannot be keyed -> hard error (no write).
#
# Fail-safe messaging: a non-existent path or a bad session_id is rejected with a
# clear message and a non-zero exit; nothing is written on error.
set -u

target="${1:-}"
if [ -z "$target" ]; then
    echo "Usage: session-project-set.sh <path> [session_id]" >&2
    exit 1
fi
if [ ! -d "$target" ]; then
    echo "session-project-set: not an existing directory: $target" >&2
    exit 1
fi
target_abs="$(cd "$target" 2>/dev/null && pwd)" || {
    echo "session-project-set: cannot resolve directory: $target" >&2
    exit 1
}

session_id="${2:-${CREDO_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"
if [ -z "$session_id" ]; then
    echo "session-project-set: cannot determine session_id (pass it as arg 2 or set CLAUDE_CODE_SESSION_ID)" >&2
    exit 1
fi
case "$session_id" in
    *[!A-Za-z0-9._-]*)
        echo "session-project-set: invalid session_id (unexpected characters)" >&2
        exit 1
        ;;
esac

STATE_DIR="${CREDO_SESSION_PROJECTS_DIR:-$HOME/.claude/credo/session-projects}"
mkdir -p "$STATE_DIR" || { echo "session-project-set: cannot create state dir $STATE_DIR" >&2; exit 1; }

state_file="$STATE_DIR/$session_id"
tmp="$(mktemp "${state_file}.XXXXXX")" || { echo "session-project-set: mktemp failed" >&2; exit 1; }
printf '%s\n' "$target_abs" > "$tmp"
mv -f "$tmp" "$state_file"

echo "credo project pinned = $target_abs (session $session_id)"
