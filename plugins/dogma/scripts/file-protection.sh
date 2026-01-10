#!/bin/bash
# Dogma: File Protection Hook
# Blocks dangerous file deletion commands
#
# Blocked: rm, del, unlink, git clean, rmdir
# Allowed: git rm --cached, git reset (safe operations)
#
# ENV: DOGMA_FILE_PROTECTION=true (default) | false

set -e

# === CONFIGURATION ===
ENABLED="${DOGMA_FILE_PROTECTION:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Read JSON input from stdin
INPUT=$(cat)

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

# If blocked, output error
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

    echo ""
    echo "BLOCKED by dogma: file protection"
    echo ""
    echo "Command: $BLOCKED"
    echo "Reason: $REASON"
    if [ -n "$TARGET" ]; then
        echo "Target: $TARGET"
    fi
    echo ""
    echo "Claude should NEVER delete local files without explicit user confirmation."
    echo ""
    echo "What you can do instead:"
    echo "- Ask the user to confirm deletion"
    echo "- Tell the user how to delete it themselves: $TOOL_INPUT"
    echo "- Use 'git rm --cached <file>' to untrack without deleting"
    echo ""
    exit 1
fi

exit 0
