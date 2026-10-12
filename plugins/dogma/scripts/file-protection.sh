#!/bin/bash
# Dogma: File Protection Hook
# Blocks dangerous file deletion commands
#
# Blocked: rm, del, unlink, git clean, rmdir (delete setting §0lgy)
# Blocked: git restore, git reset --hard, git checkout (discard), git switch --discard-changes,
#          git stash drop|clear (discard setting §b4dk, a missing line counts as [?])
# Allowed: git rm --cached, git reset (the text fallback without python3 allows every git reset;
#          with python3 reset --hard counts as a discard, see above)
#
# Which DOGMA-PERMISSIONS.md applies: see lib-permissions.sh load_permissions (the
# command's target > credo pinned project > session folder, plus inheritance).
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

# Block (ask or deny + TO-DELETE.md) per DELETE_MODE; BLOCKED/TARGET/REASON describe it.
report_delete() {
    if [ "$DELETE_MODE" = "ask" ]; then
        # Ask mode: Prompt user for confirmation
        if [ "$BLOCK_KIND" = "discard" ] && [ "$BLOCK_UNDEFINED" = "true" ]; then
            # The file has no line for the discard setting yet: the step is to add it (default [?]), not to change it
            REASON_MSG="dogma: $BLOCKED ${TARGET:-command} discards uncommitted changes and needs confirmation. ${DELETE_SRC:-${PERMS_FILE:-a DOGMA-PERMISSIONS.md}} has no line for (§b4dk) yet: add \`- [?] (§b4dk) Discard uncommitted changes\` to its <permissions> block, or run /dogma:sync or /dogma:permissions. Until then this asks; set [x] to allow it."
        else
            REASON_MSG="dogma: $BLOCKED ${TARGET:-command} requires confirmation. Change [?] to [x] in ${DELETE_SRC:-$PERMS_FILE} to allow automatically."
        fi
        REASON_MSG=$(echo "$REASON_MSG" | sed 's/"/\\"/g')
        output_ask "$REASON_MSG"
    fi
    if [ "$BLOCK_KIND" = "discard" ]; then
        # A discard is not a file to delete later: deny with the reason only, no TO-DELETE.md entry
        REASON_MSG="dogma: $BLOCKED ${TARGET:-command} discards uncommitted changes and is denied. Change [ ] to [?] or [x] in ${DELETE_SRC:-${PERMS_FILE:-a DOGMA-PERMISSIONS.md (none found)}} to allow it."
        REASON_MSG=$(echo "$REASON_MSG" | sed 's/"/\\"/g')
        output_deny "$REASON_MSG"
    fi
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
    REASON_MSG="BLOCKED by dogma: $BLOCKED ${TARGET:-command} logged to TO-DELETE.md. Change [ ] to [x] or [?] in ${DELETE_SRC:-${PERMS_FILE:-a DOGMA-PERMISSIONS.md (none found)}}."
    REASON_MSG=$(echo "$REASON_MSG" | sed 's/"/\\"/g')
    output_deny "$REASON_MSG"
}

# === SHELL-AWARE CHECK (python3) ===
# bash-guard.py finds deletes and data-destroying commands however they are written
# (wrappers, quoting, nested shells, git reset --hard, archive/sync source deletion,
# inline interpreter code ...) together with the directories they run in. Two groups are
# decided on their own: the deletes under the delete setting (§0lgy), and the git discards of
# uncommitted changes under the discard setting (§b4dk, a missing line counts as [?]). The
# stricter group decides.

# Decide one group of findings (a JSON array of deletes) under one setting. Sets GROUP_MODE,
# GROUP_SRC, GROUP_LABEL and GROUP_TARGET (the first entry of the group).
# Usage: decide_group <entries JSON> <spec> <mode when no file applies>
decide_group() {
    local entries="$1" spec="$2" missing="$3"
    GROUP_MODE="auto"; GROUP_SRC=""; GROUP_LABEL=""; GROUP_TARGET=""; GROUP_UNDEFINED=""
    [ "$entries" != "[]" ] || return 0
    mapfile -t GROUP_DIRS < <(printf '%s' "$entries" | jq -r '[.[].dirs[]] | unique | .[]')
    [ "${#GROUP_DIRS[@]}" -gt 0 ] || GROUP_DIRS=("")
    dogma_strictest_mode "$spec" "$missing" "${GROUP_DIRS[@]}"
    GROUP_MODE="$DOGMA_STRICT_MODE"
    GROUP_SRC="$DOGMA_STRICT_SRC"
    GROUP_UNDEFINED="$DOGMA_STRICT_UNDEFINED"
    GROUP_LABEL="$(printf '%s' "$entries" | jq -r '.[0].label')"
    GROUP_TARGET="$(printf '%s' "$entries" | jq -r '.[0].target')"
}

# Rank of a mode for the "stricter group wins" choice (deny > ask > auto)
group_rank() {
    case "$1" in
        deny) echo 2 ;;
        ask) echo 1 ;;
        *) echo 0 ;;
    esac
}

dogma_session_from_input "$INPUT"
BLOCK_KIND="delete"
BLOCK_UNDEFINED=""
if [ "$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)" = "Bash" ] && \
    FINDINGS="$(dogma_bash_findings "$INPUT")"; then
    # The analysis refused the command (or ran out of time): deny here too, so a
    # finding is never silently skipped.
    BLOCKED_REASON="$(dogma_findings_blocked "$FINDINGS")"
    if [ -n "$BLOCKED_REASON" ]; then
        output_deny "$BLOCKED_REASON"
    fi
    [ "$(printf '%s' "$FINDINGS" | jq '.deletes | length')" -gt 0 ] || exit 0
    DELETE_ENTRIES="$(printf '%s' "$FINDINGS" | jq -c '[.deletes[] | select(.discard != true)]')"
    DISCARD_ENTRIES="$(printf '%s' "$FINDINGS" | jq -c '[.deletes[] | select(.discard == true)]')"
    # Deletes that stay inside a temp root (/tmp, /var/tmp, $TMPDIR, Windows temp folders) are always
    # allowed, whatever the delete setting; anything unsure keeps the setting below (delete-guard.py).
    # Discards get no temp-root exemption: they always follow their own setting.
    EVENT_CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
    if [ "$DELETE_ENTRIES" != "[]" ] && [ "$(printf '{"deletes": %s}' "$DELETE_ENTRIES" | python3 -I "$SCRIPT_DIR/delete-guard.py" --temp-only "$EVENT_CWD" 2>/dev/null)" = "temp" ]; then
        DELETE_ENTRIES="[]"
    fi
    decide_group "$DELETE_ENTRIES" "§0lgy|delete files" deny
    DELETE_MODE="$GROUP_MODE"
    DELETE_SRC="$GROUP_SRC"
    BLOCKED="$GROUP_LABEL"
    TARGET="$GROUP_TARGET"
    decide_group "$DISCARD_ENTRIES" "§b4dk|discard uncommitted changes" deny
    if [ "$(group_rank "$GROUP_MODE")" -gt "$(group_rank "$DELETE_MODE")" ]; then
        DELETE_MODE="$GROUP_MODE"
        DELETE_SRC="$GROUP_SRC"
        BLOCKED="$GROUP_LABEL"
        TARGET="$GROUP_TARGET"
        BLOCK_KIND="discard"
        BLOCK_UNDEFINED="$GROUP_UNDEFINED"
    fi
    [ "$DELETE_MODE" = "auto" ] && exit 0
    if [ "$BLOCK_KIND" = "discard" ]; then
        REASON="Discards uncommitted changes"
    else
        REASON="Deletes files permanently"
    fi
    report_delete
fi

# === CHECK PERMISSIONS (text fallback without python3) ===
# Target of the command (`cd <dir> && rm ...`, `git -C <dir> clean`) > credo pinned
# project > $PWD; missing settings inherited from the session folder's file
TARGET_DIR=$(dogma_target_from_command "$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)") || TARGET_DIR=""
DELETE_MODE="deny"  # Default: deny (log to TO-DELETE.md)

if load_permissions "$TARGET_DIR" && [ -f "$PERMS_FILE" ]; then
    DELETE_MODE=$(get_permission_mode "$PERMS_SECTION" "§0lgy|delete files")
    DELETE_SRC=$(perm_defining_file "§0lgy|delete files")
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

    report_delete
fi

dogma_debug_log "=== file-protection.sh END ==="
exit 0
