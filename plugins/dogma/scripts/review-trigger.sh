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

# Find DOGMA-PERMISSIONS.md by walking up directory tree
find_permissions_file() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/DOGMA-PERMISSIONS.md" ]; then
            echo "$dir/DOGMA-PERMISSIONS.md"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

PERMISSIONS_FILE=$(find_permissions_file)
if [ -z "$PERMISSIONS_FILE" ] || [ ! -f "$PERMISSIONS_FILE" ]; then
    exit 0
fi

# Check if review after implementation is configured
# Looking for: "Wann Review? - [x] nach Umsetzung" or similar pattern
# Also support English: "When Review? - [x] after implementation"
REVIEW_CONFIGURED=false
REVIEW_TRIGGER=""

if grep -qiE '\[x\]\s*(nach Umsetzung|after implementation)' "$PERMISSIONS_FILE"; then
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
echo "Consider spawning:"
echo "- code-reviewer for quality check"
echo "- silent-failure-hunter for error paths"
echo "- type-design-analyzer for TypeScript"
echo ""
echo "Based on DOGMA-PERMISSIONS.md workflow settings."
echo "</dogma-review-reminder>"

# PostToolUse hooks should not block (content already written)
# Just remind so Claude can act on it
exit 0
