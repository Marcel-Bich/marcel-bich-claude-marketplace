#!/bin/bash
# Dogma: PostToolUse Write/Edit Hook
# Outputs review reminder when configured in DOGMA-PERMISSIONS.md
#
# Checks Workflow Permissions section for:
# - "Wann Review? - [x] nach Umsetzung" -> trigger reminder
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch for all hooks
# ENV: CLAUDE_MB_DOGMA_REVIEW_TRIGGER=true (default) | false

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# === DEBUG MODE ===
DEBUG="${CLAUDE_MB_DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== review-trigger.sh START $(date) ===" >&2
    echo "PWD: $(pwd)" >&2
fi

# === MASTER SWITCH ===
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${CLAUDE_MB_DOGMA_REVIEW_TRIGGER:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Read JSON input from stdin
INPUT=$(cat 2>/dev/null || true)

# Extract tool info
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only process Write and Edit results
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
    exit 0
fi

# Which DOGMA-PERMISSIONS.md applies: the edited file's own path (target) > credo
# pinned project > upward from $PWD; missing settings inherited from the session
# folder's file (see lib-permissions.sh load_permissions)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-permissions.sh
source "$SCRIPT_DIR/lib-permissions.sh"
dogma_session_from_input "$INPUT"
EDITED_FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

if ! load_permissions "$EDITED_FILE"; then
    exit 0
fi
PERMISSIONS_FILE="$PERMS_FILE"

# Check if review after implementation is configured
# Looking for: "Wann Review? - [x] nach Umsetzung" or similar pattern
# Also support English: "When Review? - [x] after implementation"
REVIEW_CONFIGURED=false
REVIEW_TRIGGER=""

# Id first (§d33m = review after implementation), text as fallback
if perm_is_checked "$(cat "$PERMISSIONS_FILE" 2>/dev/null)" d33m '(nach Umsetzung|after implementation)'; then
    REVIEW_CONFIGURED=true
    REVIEW_TRIGGER="nach Umsetzung"
fi

# Alternative: check for workflow section with review checkbox
if grep -qiE '##\s*Workflow' "$PERMISSIONS_FILE"; then
    if grep -A20 -iE '##\s*Workflow' "$PERMISSIONS_FILE" | grep -qiE '\[x\].*review'; then
        REVIEW_CONFIGURED=true
        if [ -z "$REVIEW_TRIGGER" ]; then
            REVIEW_TRIGGER="workflow settings"
        fi
    fi
fi

# Exit if review not configured
if [ "$REVIEW_CONFIGURED" != "true" ]; then
    exit 0
fi

# Output review reminder
echo ""
echo "<dogma-review-reminder>"
echo "Code changed. Review configured for: $REVIEW_TRIGGER"
echo ""
echo "Consider spawning a review agent for the changed code (quality, error paths,"
echo "types). Use whatever specialized reviewer your environment actually lists -"
echo "agent names vary per install, so verify the name first, else use general-purpose."
echo ""
echo "Based on DOGMA-PERMISSIONS.md workflow settings."
echo "</dogma-review-reminder>"

# PostToolUse hooks should not block (content already written)
# Just remind so Claude can act on it
exit 0
