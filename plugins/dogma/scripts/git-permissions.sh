#!/bin/bash
# Dogma: Git Permissions Hook
# Blocks git add/commit/push based on checkboxes in CLAUDE.git.md
#
# Reads <permissions> section and checks:
# - [ ] = not allowed (blocked)
# - [x] = allowed (proceed)
#
# ENV: DOGMA_GIT_PERMISSIONS=true (default) | false

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# === JSON OUTPUT FOR BLOCKING ===
# Claude Code expects JSON with permissionDecision
# Using "ask" allows user to confirm and proceed if they really want to
output_block() {
    local reason="$1"
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"$reason"}}
EOF
    exit 0
}

# === DEBUG MODE ===
DEBUG="${DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== git-permissions.sh START $(date) ===" >&2
    echo "PWD: $(pwd)" >&2
fi

# === CONFIGURATION ===
ENABLED="${DOGMA_GIT_PERMISSIONS:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Read JSON input from stdin
INPUT=$(cat 2>/dev/null || true)

# Extract the command being run
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only process Bash tool calls
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Find CLAUDE.git.md
CLAUDE_GIT=""
if [ -f "CLAUDE/CLAUDE.git.md" ]; then
    CLAUDE_GIT="CLAUDE/CLAUDE.git.md"
elif [ -f "CLAUDE.git.md" ]; then
    CLAUDE_GIT="CLAUDE.git.md"
elif [ -f ".claude/CLAUDE.git.md" ]; then
    CLAUDE_GIT=".claude/CLAUDE.git.md"
fi

# If no CLAUDE.git.md found, allow all
if [ -z "$CLAUDE_GIT" ]; then
    exit 0
fi

# Extract permissions section
PERMS_SECTION=$(sed -n '/<permissions>/,/<\/permissions>/p' "$CLAUDE_GIT" 2>/dev/null)

if [ -z "$PERMS_SECTION" ]; then
    exit 0
fi

# Function to check if permission is granted
check_permission() {
    local CMD="$1"
    local PATTERN="$2"

    # Look for the checkbox line
    # - [x] = allowed
    # - [ ] = not allowed
    if echo "$PERMS_SECTION" | grep -qE "^\s*-\s*\[x\].*$PATTERN"; then
        return 0  # Allowed
    elif echo "$PERMS_SECTION" | grep -qE "^\s*-\s*\[ \].*$PATTERN"; then
        return 1  # Not allowed
    fi
    # If pattern not found, allow by default
    return 0
}

# Check git add
if echo "$TOOL_INPUT" | grep -qE '^git\s+add(\s|$)'; then
    if ! check_permission "git add" "git add"; then
        output_block "BLOCKED by dogma: git add not permitted. Change [ ] to [x] for git add in $CLAUDE_GIT or run manually."
    fi
fi

# Check git commit
if echo "$TOOL_INPUT" | grep -qE '^git\s+commit(\s|$)'; then
    if ! check_permission "git commit" "git commit"; then
        output_block "BLOCKED by dogma: git commit not permitted. Change [ ] to [x] for git commit in $CLAUDE_GIT or ask user."
    fi
fi

# Check git push
if echo "$TOOL_INPUT" | grep -qE '^git\s+push(\s|$)'; then
    if ! check_permission "git push" "git push"; then
        output_block "BLOCKED by dogma: git push not permitted. Change [ ] to [x] for git push in $CLAUDE_GIT or push manually."
    fi
fi

exit 0
