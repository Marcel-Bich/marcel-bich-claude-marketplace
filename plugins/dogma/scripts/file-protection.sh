#!/bin/bash
# Dogma: File Protection Hook
# Blocks dangerous file deletion commands
#
# Blocked: rm, del, unlink, git clean, rmdir
# Allowed: git rm --cached, git reset (safe operations)
#
# Searches for permissions in (priority order):
# 1. DOGMA-PERMISSIONS.md (project root)
# 2. CLAUDE/CLAUDE.git.md (fallback)
# 3. CLAUDE.git.md (fallback)
#
# Modes (based on checkboxes):
# - [x] May delete files autonomously -> auto: allow all deletes
# - [?] May delete files autonomously -> ask: prompt user for confirmation
# - [ ] May delete files autonomously -> deny: log to TO-DELETE.md
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch for all hooks
# ENV: CLAUDE_MB_DOGMA_FILE_PROTECTION=true (default) | false
# ENV: CLAUDE_MB_DOGMA_DEBUG=true | false (default) - debug logging to /tmp/dogma-debug.log

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# Load shared permissions library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-permissions.sh"

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

# === MASTER SWITCH ===
# CLAUDE_MB_DOGMA_ENABLED=false disables ALL dogma hooks at once
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${CLAUDE_MB_DOGMA_FILE_PROTECTION:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

dogma_debug_log "=== file-protection.sh START ==="
dogma_debug_log "PWD: $(pwd)"

# === HYDRA WORKTREE CHECK ===
# Agents in worktrees can work freely (isolated from main repo)
if is_hydra_worktree; then
    dogma_debug_log "In hydra worktree - permissive mode"
    exit 0
fi

# Read JSON input from stdin
INPUT=$(cat 2>/dev/null || true)

# === CHECK PERMISSIONS ===
PERMS_FILE=$(find_permissions_file)
DELETE_MODE="deny"  # Default: deny (log to TO-DELETE.md)

if [ -n "$PERMS_FILE" ] && [ -f "$PERMS_FILE" ]; then
    PERMS_SECTION=$(get_permissions_section "$PERMS_FILE")
    DELETE_MODE=$(get_permission_mode "$PERMS_SECTION" "delete files")
    dogma_debug_log "Delete mode: $DELETE_MODE"
fi

# If delete is allowed (auto), exit early (no blocking)
if [ "$DELETE_MODE" = "auto" ]; then
    dogma_debug_log "Delete permitted (auto) - exiting"
    exit 0
fi

# Extract the command being run
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only process Bash tool calls
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

dogma_debug_log "Tool: $TOOL_NAME, Input: $TOOL_INPUT"

# Allow safe git operations
if echo "$TOOL_INPUT" | grep -qE '(^|\s|;|&&|\||\|\||\$\(|\(|`)git\s+rm\s+--cached'; then
    # git rm --cached only untracks, doesn't delete
    exit 0
fi

if echo "$TOOL_INPUT" | grep -qE '(^|\s|;|&&|\||\|\||\$\(|\(|`)git\s+reset'; then
    # git reset is safe (unstages)
    exit 0
fi

# Block dangerous commands
BLOCKED=""
REASON=""

# Check for rm command
if echo "$TOOL_INPUT" | grep -qE '(^|\s|;|&&|\||\|\||\$\(|\(|`)rm\s'; then
    BLOCKED="rm"
    REASON="Deletes files permanently"
fi

# Check for del command (Windows)
if echo "$TOOL_INPUT" | grep -qE '(^|\s|;|&&|\||\|\||\$\(|\(|`)del\s'; then
    BLOCKED="del"
    REASON="Deletes files permanently"
fi

# Check for unlink command
if echo "$TOOL_INPUT" | grep -qE '(^|\s|;|&&|\||\|\||\$\(|\(|`)unlink\s'; then
    BLOCKED="unlink"
    REASON="Deletes files permanently"
fi

# Check for rmdir command
if echo "$TOOL_INPUT" | grep -qE '(^|\s|;|&&|\||\|\||\$\(|\(|`)rmdir\s'; then
    BLOCKED="rmdir"
    REASON="Deletes directories permanently"
fi

# Check for git clean
if echo "$TOOL_INPUT" | grep -qE '(^|\s|;|&&|\||\|\||\$\(|\(|`)git\s+clean'; then
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

    if [ "$DELETE_MODE" = "ask" ]; then
        # Ask mode: Prompt user for confirmation
        REASON_MSG="dogma: $BLOCKED ${TARGET:-command} requires confirmation. Change [?] to [x] in $PERMS_FILE to allow automatically."
        REASON_MSG=$(echo "$REASON_MSG" | sed 's/"/\\"/g')
        output_ask "$REASON_MSG"
    else
        # Deny mode: Write to TO-DELETE.md and deny
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
        REASON_MSG="BLOCKED by dogma: $BLOCKED ${TARGET:-command} logged to TO-DELETE.md. Change [ ] to [x] or [?] in $PERMS_FILE."
        REASON_MSG=$(echo "$REASON_MSG" | sed 's/"/\\"/g')
        output_deny "$REASON_MSG"
    fi
fi

dogma_debug_log "=== file-protection.sh END ==="
exit 0
