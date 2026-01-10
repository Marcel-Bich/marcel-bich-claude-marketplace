#!/bin/bash
# Dogma: File Protection Hook
# Blocks dangerous file deletion commands
#
# Blocked: rm, del, unlink, git clean, rmdir
# Allowed: git rm --cached, git reset (safe operations)
#
# ENV: DOGMA_ENABLED=true (default) | false - master switch for all hooks
# ENV: DOGMA_FILE_PROTECTION=true (default) | false

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
    echo "=== file-protection.sh START $(date) ===" >&2
    echo "PWD: $(pwd)" >&2
fi

# === MASTER SWITCH ===
# DOGMA_ENABLED=false disables ALL dogma hooks at once
if [ "${DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${DOGMA_FILE_PROTECTION:-true}"
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

# Allow safe git operations
if echo "$TOOL_INPUT" | grep -qE '^git\s+rm\s+--cached'; then
    # git rm --cached only untracks, doesn't delete
    exit 0
fi

if echo "$TOOL_INPUT" | grep -qE '^git\s+reset'; then
    # git reset is safe (unstages)
    exit 0
fi

# Block dangerous commands
BLOCKED=""
REASON=""

# Check for rm command
if echo "$TOOL_INPUT" | grep -qE '(^|\s|;|&&|\|)rm\s'; then
    BLOCKED="rm"
    REASON="Deletes files permanently"
fi

# Check for del command (Windows)
if echo "$TOOL_INPUT" | grep -qE '(^|\s|;|&&|\|)del\s'; then
    BLOCKED="del"
    REASON="Deletes files permanently"
fi

# Check for unlink command
if echo "$TOOL_INPUT" | grep -qE '(^|\s|;|&&|\|)unlink\s'; then
    BLOCKED="unlink"
    REASON="Deletes files permanently"
fi

# Check for rmdir command
if echo "$TOOL_INPUT" | grep -qE '(^|\s|;|&&|\|)rmdir\s'; then
    BLOCKED="rmdir"
    REASON="Deletes directories permanently"
fi

# Check for git clean
if echo "$TOOL_INPUT" | grep -qE '^git\s+clean'; then
    BLOCKED="git clean"
    REASON="Deletes untracked files permanently"
fi

# If blocked, output JSON deny
if [ -n "$BLOCKED" ]; then
    # Extract what would be deleted
    TARGET=""
    case "$BLOCKED" in
        rm)
            TARGET=$(echo "$TOOL_INPUT" | sed -n 's/.*rm\s\+\(-[^ ]*\s\+\)*\([^ ]*\).*/\2/p')
            ;;
        del)
            TARGET=$(echo "$TOOL_INPUT" | sed -n 's/.*del\s\+\([^ ]*\).*/\1/p')
            ;;
        unlink)
            TARGET=$(echo "$TOOL_INPUT" | sed -n 's/.*unlink\s\+\([^ ]*\).*/\1/p')
            ;;
        rmdir)
            TARGET=$(echo "$TOOL_INPUT" | sed -n 's/.*rmdir\s\+\([^ ]*\).*/\1/p')
            ;;
        "git clean")
            TARGET="untracked files"
            ;;
    esac

    # Build reason message (escape quotes for JSON)
    REASON_MSG="BLOCKED by dogma: $BLOCKED ${TARGET:-command} - $REASON. User can run manually or bypass with DOGMA_FILE_PROTECTION=false"
    REASON_MSG=$(echo "$REASON_MSG" | sed 's/"/\\"/g')
    output_block "$REASON_MSG"
fi

exit 0
