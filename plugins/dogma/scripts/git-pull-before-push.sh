#!/bin/bash
# Dogma: Git Pull Before Push Hook
# Blocks git push if local branch is behind remote to prevent data loss
#
# This prevents --force or --force-with-lease pushes from overwriting
# remote commits that haven't been pulled yet.
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch for all hooks
# ENV: CLAUDE_MB_DOGMA_PULL_BEFORE_PUSH=true (default) | false
# ENV: CLAUDE_MB_DOGMA_DEBUG=true | false (default) - debug logging

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
trap 'exit 0' ERR

# Load shared permissions library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-permissions.sh"

# === JSON OUTPUT FOR BLOCKING ===
output_deny() {
    local reason="$1"
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"$reason"}}
EOF
    exit 0
}

# === MASTER SWITCH ===
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${CLAUDE_MB_DOGMA_PULL_BEFORE_PUSH:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

dogma_debug_log "=== git-pull-before-push.sh START ==="

# === HYDRA WORKTREE CHECK ===
if is_hydra_worktree; then
    dogma_debug_log "In hydra worktree - skipping pull check"
    exit 0
fi

# Read JSON input from stdin
INPUT=$(cat 2>/dev/null || true)

# Extract the command being run
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

dogma_debug_log "Tool: $TOOL_NAME, Input: $TOOL_INPUT"

# Only process Bash tool calls
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Only check git push commands
if ! echo "$TOOL_INPUT" | grep -qE '(^|&&|;|\|\||\||\$\(|\(|`)\s*git\s+push(\s|$)'; then
    exit 0
fi

dogma_debug_log "Detected git push command"

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    dogma_debug_log "Not in a git repository"
    exit 0
fi

# Get current branch
CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)
if [ -z "$CURRENT_BRANCH" ]; then
    dogma_debug_log "Could not determine current branch (detached HEAD?)"
    exit 0
fi

dogma_debug_log "Current branch: $CURRENT_BRANCH"

# Get tracking remote and branch
UPSTREAM=$(git rev-parse --abbrev-ref "$CURRENT_BRANCH@{upstream}" 2>/dev/null)
if [ -z "$UPSTREAM" ]; then
    dogma_debug_log "No upstream configured - allowing push"
    exit 0
fi

dogma_debug_log "Upstream: $UPSTREAM"

# Fetch from remote (quietly)
REMOTE=$(echo "$UPSTREAM" | cut -d'/' -f1)
dogma_debug_log "Fetching from remote: $REMOTE"
git fetch "$REMOTE" --quiet 2>/dev/null || true

# Check if local is behind remote
LOCAL_COMMIT=$(git rev-parse HEAD 2>/dev/null)
REMOTE_COMMIT=$(git rev-parse "$UPSTREAM" 2>/dev/null)
BASE_COMMIT=$(git merge-base HEAD "$UPSTREAM" 2>/dev/null)

dogma_debug_log "Local: $LOCAL_COMMIT, Remote: $REMOTE_COMMIT, Base: $BASE_COMMIT"

if [ -z "$LOCAL_COMMIT" ] || [ -z "$REMOTE_COMMIT" ] || [ -z "$BASE_COMMIT" ]; then
    dogma_debug_log "Could not determine commit status - allowing push"
    exit 0
fi

# If remote has commits that local doesn't have (local is behind)
if [ "$BASE_COMMIT" != "$REMOTE_COMMIT" ] && [ "$LOCAL_COMMIT" != "$REMOTE_COMMIT" ]; then
    # Count how many commits behind
    BEHIND_COUNT=$(git rev-list --count HEAD.."$UPSTREAM" 2>/dev/null || echo "unknown")
    dogma_debug_log "Local is $BEHIND_COUNT commits behind remote"

    output_deny "BLOCKED by dogma: Local branch is $BEHIND_COUNT commit(s) behind remote. Run 'git pull' first to avoid data loss, then push again."
fi

dogma_debug_log "=== git-pull-before-push.sh END ==="
exit 0
