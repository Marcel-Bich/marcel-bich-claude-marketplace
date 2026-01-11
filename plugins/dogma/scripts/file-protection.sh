#!/bin/bash
# Dogma: File Protection Hook
# Blocks dangerous file deletion commands
#
# Blocked: rm, del, unlink, git clean, rmdir
# Allowed: git rm --cached, git reset (safe operations)
#
# Modes (based on CLAUDE.git.md checkboxes):
# - [x] May delete files autonomously -> allow all deletes
# - [ ] May delete (default) -> block + log to TO-DELETE.md (non-blocking)
# - [ ] May delete + [ ] Log blocked -> ask user for confirmation
#
# ENV: DOGMA_ENABLED=true (default) | false - master switch for all hooks
# ENV: DOGMA_FILE_PROTECTION=true (default) | false

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# === JSON OUTPUT FOR BLOCKING ===
# Claude Code expects JSON with permissionDecision
output_ask() {
    local reason="$1"
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"$reason"}}
EOF
    exit 0
}

output_deny() {
    local reason="$1"
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"$reason"}}
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

# === CHECK CLAUDE.git.md PERMISSIONS ===
# Find CLAUDE.git.md in current directory or parents
find_claude_git_md() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/CLAUDE/CLAUDE.git.md" ]; then
            echo "$dir/CLAUDE/CLAUDE.git.md"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

CLAUDE_GIT_MD=$(find_claude_git_md 2>/dev/null || true)
DELETE_ALLOWED="false"
LOG_MODE="true"  # Default: log to TO-DELETE.md (non-blocking)

if [ -n "$CLAUDE_GIT_MD" ] && [ -f "$CLAUDE_GIT_MD" ]; then
    # Check if delete is allowed: [x] May delete files autonomously
    if grep -qE '^\s*-\s*\[x\]\s*May delete files autonomously' "$CLAUDE_GIT_MD" 2>/dev/null; then
        DELETE_ALLOWED="true"
    fi
    # Check if ask mode explicitly requested: [ ] Log blocked deletes
    if grep -qE '^\s*-\s*\[ \]\s*Log blocked deletes' "$CLAUDE_GIT_MD" 2>/dev/null; then
        LOG_MODE="false"
    fi
fi

# If delete is allowed, exit early (no blocking)
if [ "$DELETE_ALLOWED" = "true" ]; then
    exit 0
fi

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

# If blocked, handle based on mode
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

    if [ "$LOG_MODE" = "true" ]; then
        # Log mode: Write to TO-DELETE.md and deny (non-blocking for agent)
        TO_DELETE_FILE="$PWD/TO-DELETE.md"
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

        # Create file with header if it doesn't exist
        if [ ! -f "$TO_DELETE_FILE" ]; then
            cat > "$TO_DELETE_FILE" << 'HEADER'
# Files to Delete

These files were blocked from deletion by dogma. Delete them manually if needed.
Check off items after manual deletion.

HEADER
        fi

        # Append as checklist item (so checklist-tracking picks it up)
        echo "- [ ] \`$BLOCKED ${TARGET:-unknown}\` - $REASON ($TIMESTAMP)" >> "$TO_DELETE_FILE"

        # Deny with info message
        REASON_MSG="BLOCKED by dogma: $BLOCKED ${TARGET:-command} logged to TO-DELETE.md. Agent continues without deleting."
        REASON_MSG=$(echo "$REASON_MSG" | sed 's/"/\\"/g')
        output_deny "$REASON_MSG"
    else
        # Ask mode: Prompt user for confirmation
        REASON_MSG="BLOCKED by dogma: $BLOCKED ${TARGET:-command} - $REASON. User can run manually or bypass with DOGMA_FILE_PROTECTION=false"
        REASON_MSG=$(echo "$REASON_MSG" | sed 's/"/\\"/g')
        output_ask "$REASON_MSG"
    fi
fi

exit 0
