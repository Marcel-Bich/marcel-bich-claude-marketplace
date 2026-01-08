#!/bin/bash
# notify-replace.sh: Send desktop notification with replacement support
# Part of desktop-notifier plugin for Claude Code
#
# Uses gdbus for notification replacement (prevents stacking)
# Falls back to notify-send if gdbus fails
# On WSL: Uses Windows toast notifications via PowerShell

# Load WSL utilities
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/wsl-utils.sh"

SESSION_ID="${1:-default}"
TITLE="${2:-Claude Code}"
BODY="${3:-}"
ICON="${4:-dialog-information}"
URGENCY="${5:-1}"

# Store notification IDs in temp files for replacement
ID_FILE="/tmp/claude-mb-notify-id-${SESSION_ID}"
PREV_ID=0
if [ -f "$ID_FILE" ]; then
    PREV_ID=$(cat "$ID_FILE" 2>/dev/null || echo "0")
fi

# Set timeout based on urgency
case "$URGENCY" in
    2|critical) TIMEOUT=0 ;;      # Persistent
    1|normal)   TIMEOUT=5000 ;;   # 5 seconds
    *)          TIMEOUT=5000 ;;
esac

# WSL: Use Windows toast notifications with replacement support
if is_wsl; then
    # SESSION_ID is used as Tag for notification replacement
    windows_notify "$TITLE" "$BODY" "$SESSION_ID" "$URGENCY"
# Linux: Try gdbus first (supports replacement)
elif command -v gdbus &> /dev/null; then
    RESULT=$(gdbus call --session \
        -d org.freedesktop.Notifications \
        -o /org/freedesktop/Notifications \
        -m org.freedesktop.Notifications.Notify \
        "Claude Code" \
        "$PREV_ID" \
        "$ICON" \
        "$TITLE" \
        "$BODY" \
        "[]" \
        "{}" \
        "$TIMEOUT" 2>/dev/null)

    # Extract new notification ID for future replacement
    NEW_ID=$(echo "$RESULT" | grep -oP '\(uint32 \K\d+')
    if [ -n "$NEW_ID" ] && [ "$NEW_ID" != "0" ]; then
        echo "$NEW_ID" > "$ID_FILE"
    fi
# Fallback to notify-send
elif command -v notify-send &> /dev/null; then
    notify-send -i "$ICON" "$TITLE" "$BODY" 2>/dev/null
fi

exit 0
