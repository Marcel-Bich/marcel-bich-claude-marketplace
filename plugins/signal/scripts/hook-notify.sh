#!/bin/bash
# hook-notify.sh: Notification handler for PreToolUse and Notification events
# Part of desktop-notifier plugin for Claude Code

# === CONFIGURATION (via environment variables) ===
# CLAUDE_MB_NOTIFY_SOUND_ATTENTION: volume 0.0-1.0 (default: 0.25), 0 to disable
# CLAUDE_MB_NOTIFY_SOUND_COMPLETE: volume 0.0-1.0 (default: 0.4), 0 to disable (used for permission_prompt)

SOUND_VOLUME_ATTENTION="${CLAUDE_MB_NOTIFY_SOUND_ATTENTION:-0.25}"
SOUND_VOLUME_COMPLETE="${CLAUDE_MB_NOTIFY_SOUND_COMPLETE:-0.4}"

# Get plugin root and hook type
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Load WSL utilities
source "$PLUGIN_ROOT/scripts/wsl-utils.sh"
source "$PLUGIN_ROOT/scripts/kitty-tab.sh"
HOOK_TYPE="${1:-notification}"
PROJECT=$(basename "$PWD" 2>/dev/null || echo "claude")
DISPLAY_NAME=$(kitty_tab_get_display_name "$PROJECT")

# Read JSON input
INPUT=""
[ ! -t 0 ] && INPUT=$(cat)

# Use PROJECT + HOOK_TYPE as replacement ID
NOTIFY_ID="project-${PROJECT}-${HOOK_TYPE}"

# Ignore first PreToolUse event after session start
# - New session: User is at terminal anyway, no notification needed
# - /resume: First event is stale from old session
if [ "$HOOK_TYPE" = "PreToolUse" ] || [ "$HOOK_TYPE" = "pretooluse" ]; then
    FIRST_EVENT_MARKER="/tmp/claude-mb-first-event-pending-${PROJECT}"
    if [ -f "$FIRST_EVENT_MARKER" ]; then
        rm -f "$FIRST_EVENT_MARKER"
        exit 0
    fi
fi

# Build notification based on hook type
case "$HOOK_TYPE" in
    stop|Stop)
        # Stop is handled by stop-notify.sh
        exit 0
        ;;
    notification|Notification)
        TITLE="Claude Code [$DISPLAY_NAME]"
        ICON="dialog-information"
        URGENCY=2
        SOUND_TYPE="attention"
        if [ -n "$INPUT" ]; then
            NOTIF_TYPE=$(echo "$INPUT" | jq -r '.notification_type // empty' 2>/dev/null)
            case "$NOTIF_TYPE" in
                permission_prompt)
                    MESSAGE="Permission required"
                    SOUND_TYPE="complete"
                    ;;
                idle_prompt)
                    MESSAGE="Waiting for your input"
                    ;;
                elicitation_dialog)
                    MESSAGE="Question waiting for answer"
                    ;;
                *)
                    if [ -n "$NOTIF_TYPE" ]; then
                        MESSAGE="Notification: $NOTIF_TYPE"
                    else
                        MESSAGE="Waiting for input"
                    fi
                    ;;
            esac
        else
            MESSAGE="Notification"
        fi
        ;;
    PreToolUse|pretooluse)
        TITLE="Tool waiting [$DISPLAY_NAME]"
        ICON="dialog-warning"
        URGENCY=2
        if [ -n "$INPUT" ]; then
            TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "Tool"' 2>/dev/null)
            case "$TOOL_NAME" in
                Bash)
                    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null | head -c 80)
                    if [ -n "$CMD" ]; then
                        MESSAGE="Bash: $CMD"
                    else
                        MESSAGE="Bash command waiting"
                    fi
                    ;;
                Write|Edit)
                    FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null | xargs basename 2>/dev/null)
                    MESSAGE="$TOOL_NAME: $FILE"
                    ;;
                Read)
                    FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null | xargs basename 2>/dev/null)
                    MESSAGE="Read: $FILE"
                    ;;
                Task)
                    DESC=$(echo "$INPUT" | jq -r '.tool_input.description // empty' 2>/dev/null | head -c 50)
                    MESSAGE="Task: $DESC"
                    ;;
                *)
                    MESSAGE="$TOOL_NAME waiting for approval"
                    ;;
            esac
        else
            MESSAGE="Tool waiting for approval"
        fi
        ;;
    *)
        TITLE="Claude Code [$PROJECT]"
        MESSAGE="Activity: $HOOK_TYPE"
        ICON="dialog-information"
        URGENCY=1
        ;;
esac

# Send notification
"$PLUGIN_ROOT/scripts/notify-replace.sh" "$NOTIFY_ID" "$TITLE" "$MESSAGE" "$ICON" "$URGENCY"

# Play sound (complete for permission_prompt, attention for others)
# SOUND_TYPE is set in notification handler, default to attention for other hooks
SOUND_TYPE="${SOUND_TYPE:-attention}"

if [ "$SOUND_TYPE" = "complete" ]; then
    SOUND_VOLUME="$SOUND_VOLUME_COMPLETE"
    SOUND_FILE="/usr/share/sounds/freedesktop/stereo/complete.oga"
else
    SOUND_VOLUME="$SOUND_VOLUME_ATTENTION"
    SOUND_FILE="/usr/share/sounds/freedesktop/stereo/message.oga"
fi

if is_wsl; then
    # WSL: Use Windows system sound with volume
    windows_sound "$SOUND_TYPE" "$SOUND_VOLUME"
elif command -v paplay &> /dev/null && [ "$(echo "$SOUND_VOLUME > 0" | bc 2>/dev/null)" = "1" ]; then
    # Linux: Original paplay code
    CURRENT_VOL=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -oP '\d+(?=%)' | head -1)
    PLAY_VOL=$(echo "${CURRENT_VOL:-50} * $SOUND_VOLUME * 655.36" | bc 2>/dev/null | cut -d. -f1)
    [ -n "$PLAY_VOL" ] && paplay --volume="$PLAY_VOL" "$SOUND_FILE" 2>/dev/null &
fi

exit 0
