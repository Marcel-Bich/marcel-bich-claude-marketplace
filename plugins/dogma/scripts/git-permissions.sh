#!/bin/bash
# Dogma: Git Permissions Hook
# Blocks git add/commit/push based on checkboxes in permissions file
#
# Searches for permissions in (priority order):
# 1. DOGMA-PERMISSIONS.md (project root)
# 2. CLAUDE/CLAUDE.git.md (fallback)
# 3. CLAUDE.git.md (fallback)
#
# Reads <permissions> section and checks:
# - [ ] = not allowed (blocked)
# - [x] = allowed (proceed)
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch for all hooks
# ENV: CLAUDE_MB_DOGMA_GIT_PERMISSIONS=true (default) | false
# ENV: CLAUDE_MB_DOGMA_DEBUG=true | false (default) - debug logging to /tmp/dogma-debug.log

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# Load shared permissions library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-permissions.sh"

# === JSON OUTPUT FOR BLOCKING ===
# Claude Code expects JSON with permissionDecision
# Using "deny" - git permissions are binding policy
output_block() {
    local reason="$1"
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"$reason"}}
EOF
    exit 0
}

# === MASTER SWITCH ===
# CLAUDE_MB_DOGMA_ENABLED=false disables ALL dogma hooks at once
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${CLAUDE_MB_DOGMA_GIT_PERMISSIONS:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

dogma_debug_log "=== git-permissions.sh START ==="
dogma_debug_log "PWD: $(pwd)"

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

# Find permissions file
PERMS_FILE=$(find_permissions_file)
if [ -z "$PERMS_FILE" ]; then
    # No permissions file - allow all by default
    dogma_debug_log "No permissions file found - allowing all"
    exit 0
fi

# Extract permissions section
PERMS_SECTION=$(get_permissions_section "$PERMS_FILE")
dogma_debug_log "Permissions section: ${PERMS_SECTION:0:100}..."

if [ -z "$PERMS_SECTION" ]; then
    dogma_debug_log "No <permissions> section found - allowing all"
    exit 0
fi

# Check git add (also catches: && git add, ; git add, || git add)
if echo "$TOOL_INPUT" | grep -qE '(^|&&|;|\|\||\||\$\(|\(|`)\s*git\s+add(\s|$)'; then
    if ! check_permission "$PERMS_SECTION" "git add"; then
        output_block "BLOCKED by dogma: git add not permitted. Change [ ] to [x] for git add in $PERMS_FILE or run manually."
    fi
fi

# Check git commit (also catches chained commands)
if echo "$TOOL_INPUT" | grep -qE '(^|&&|;|\|\||\||\$\(|\(|`)\s*git\s+commit(\s|$)'; then
    if ! check_permission "$PERMS_SECTION" "git commit"; then
        output_block "BLOCKED by dogma: git commit not permitted. Change [ ] to [x] for git commit in $PERMS_FILE or ask user."
    fi
fi

# Check git push (also catches chained commands)
if echo "$TOOL_INPUT" | grep -qE '(^|&&|;|\|\||\||\$\(|\(|`)\s*git\s+push(\s|$)'; then
    if ! check_permission "$PERMS_SECTION" "git push"; then
        output_block "BLOCKED by dogma: git push not permitted. Change [ ] to [x] for git push in $PERMS_FILE or push manually."
    fi
fi

dogma_debug_log "=== git-permissions.sh END ==="
exit 0
