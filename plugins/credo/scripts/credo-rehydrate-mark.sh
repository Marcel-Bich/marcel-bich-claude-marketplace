#!/usr/bin/env bash
# credo-rehydrate-mark.sh <handoff_path> [session_id]
#
# Drop a one-shot "rehydrate after the next reset" breadcrumb so the credo
# SessionStart hook (credo-session-start.sh), after a compact/resume/fork, tells
# the agent to reload the state that compact-plus just secured to disk. Also
# marks the session as credo-engaged (decision=accepted) IF no decision has been
# made yet - so a session that used compact-plus WITHOUT formally opting in still
# gets the credo KNOWLEDGE re-fed after the reset. An explicit earlier decision
# (accepted OR declined) is never overridden.
#
# Called by the compact-plus skill after it writes the rolling handoff. The
# session_id is resolved like session-mode-set.sh / credo-decision-set.sh:
#   1. the second positional argument (if given)
#   2. $CREDO_SESSION_ID        (test / manual override)
#   3. $CLAUDE_CODE_SESSION_ID  (set by Claude Code for tool bash calls)
# Without a session_id nothing can be keyed -> hard error (no write).
#
# State (keyed by session_id):
#   breadcrumb : ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/rehydrate/<id>
#                holds the handoff path (one line). One-shot: the SessionStart
#                hook consumes (deletes) it after injecting the reload ACTION.
set -u

handoff_path="${1:-}"
if [ -z "$handoff_path" ]; then
    echo "credo-rehydrate-mark: missing handoff path (arg 1)" >&2
    exit 1
fi

session_id="${2:-${CREDO_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"
if [ -z "$session_id" ]; then
    echo "credo-rehydrate-mark: cannot determine session_id (pass it as arg 2 or set CLAUDE_CODE_SESSION_ID)" >&2
    exit 1
fi
case "$session_id" in
    *[!A-Za-z0-9._-]*|.|*..*)
        echo "credo-rehydrate-mark: invalid session_id (unexpected characters or path traversal)" >&2
        exit 1
        ;;
esac

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# --- breadcrumb (one-shot, consumed by credo-session-start.sh) -------------
REHYDRATE_DIR="${CREDO_REHYDRATE_DIR:-$CONFIG_DIR/credo/rehydrate}"
mkdir -p "$REHYDRATE_DIR" || { echo "credo-rehydrate-mark: cannot create $REHYDRATE_DIR" >&2; exit 1; }
bc="$REHYDRATE_DIR/$session_id"
tmp="$(mktemp "${bc}.XXXXXX")" || { echo "credo-rehydrate-mark: mktemp failed" >&2; exit 1; }
printf '%s\n' "$handoff_path" > "$tmp"
mv -f "$tmp" "$bc"

# --- engagement: accept credo if still undecided (never override) ----------
DECISIONS_DIR="${CREDO_SESSION_DECISIONS_DIR:-$CONFIG_DIR/credo/session-decisions}"
if [ ! -f "$DECISIONS_DIR/$session_id" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || SCRIPT_DIR=""
    if [ -n "$SCRIPT_DIR" ] && [ -x "$SCRIPT_DIR/credo-decision-set.sh" ]; then
        "$SCRIPT_DIR/credo-decision-set.sh" accepted "$session_id" >/dev/null 2>&1 || true
    fi
fi

echo "credo-rehydrate marked (session $session_id, handoff: $handoff_path)"
