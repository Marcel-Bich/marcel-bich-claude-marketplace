#!/bin/bash
# notify-replace.sh: Send desktop notification with replacement support
# Part of desktop-notifier plugin for Claude Code
#
# Uses gdbus for notification replacement (prevents stacking)
# Falls back to notify-send if gdbus fails
# On WSL: Uses Windows toast notifications via PowerShell (resolved by wsl-utils.sh)
#
# CLAUDE_MB_NOTIFY_TOAST=false skips every attempt. Exit code: 0 delivered/started or switched
# off, 1 when no notification channel worked (one warning per day on stderr, plus the state log).
#
# Why 1 and never 2: this script is not a hook itself, hook-notify.sh and stop-notify.sh call it
# and always end with "exit 0", so its code never reaches Claude Code. Should it ever be wired
# up directly as a hook command: Claude Code treats exit 2 as a blocking error and any other
# non-zero code as a non-blocking error (stderr shown, the action goes on), so 1 stays harmless.
# Keep it that way: never exit 2 from here.

# Load WSL utilities
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/wsl-utils.sh"

SESSION_ID="${1:-default}"
TITLE="${2:-Claude Code}"
BODY="${3:-}"
ICON="${4:-dialog-information}"
URGENCY="${5:-1}"

# Toast switch off: no toast, no desktop notification, no state touched
signal_toast_enabled || exit 0

RC=1

# Store notification IDs in temp files for replacement
ID_FILE="/tmp/claude-mb-notify-id-${SESSION_ID}"

# Serialize read-close-notify-write per key. Without the lock, hooks that fire
# at the same moment (parallel tool calls) all read the same old ID and each
# leaves its own notification behind. The lock is released when the script exits.
if command -v flock &> /dev/null; then
    exec 9>"${ID_FILE}.lock"
    flock -w 5 9 || true
fi

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
    # (windows_notify returns 1 after its own once-per-day warning when powershell.exe is missing)
    windows_notify "$TITLE" "$BODY" "$SESSION_ID" "$URGENCY"
    [ $? -eq 0 ] && RC=0
else
    # Linux: Try gdbus first (supports replacement), fall back to notify-send
    GDBUS_OK=false
    if command -v gdbus &> /dev/null; then
        # Close previous notification to prevent tray stacking (GNOME)
        if [ "$PREV_ID" != "0" ]; then
            gdbus call --session \
                -d org.freedesktop.Notifications \
                -o /org/freedesktop/Notifications \
                -m org.freedesktop.Notifications.CloseNotification \
                "$PREV_ID" >/dev/null 2>&1 || true
        fi

        # GNOME Shell (46 and older) turns every "\n" in the body into a space, even
        # when the notification is expanded; a carriage return survives and renders
        # as a line break. Other servers keep "\n", so convert only for gnome-shell.
        SERVER_NAME=$(gdbus call --session \
            -d org.freedesktop.Notifications \
            -o /org/freedesktop/Notifications \
            -m org.freedesktop.Notifications.GetServerInformation 2>/dev/null)
        case "$SERVER_NAME" in
            *"'gnome-shell'"*) BODY="${BODY//$'\n'/$'\r'}" ;;
        esac

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
        GDBUS_RC=$?

        # gdbus rc 0 means the server accepted the notification: delivered, even when the
        # reply cannot be parsed (a fallback to notify-send would show a duplicate). The new ID
        # is only stored for future replacement when it can be parsed.
        if [ "$GDBUS_RC" -eq 0 ]; then
            GDBUS_OK=true
            RC=0
            NEW_ID=$(echo "$RESULT" | grep -oP '\(uint32 \K\d+')
            if [ -n "$NEW_ID" ] && [ "$NEW_ID" != "0" ]; then
                echo "$NEW_ID" > "$ID_FILE"
            fi
        fi
    fi
    # Fallback to notify-send (gdbus missing or its Notify call failed)
    if [ "$GDBUS_OK" != "true" ] && command -v notify-send &> /dev/null; then
        notify-send -i "$ICON" "$TITLE" "$BODY" 2>/dev/null && RC=0
    fi
    if [ "$RC" -ne 0 ]; then
        signal_warn_once no-channel "no notification channel worked (gdbus Notify failed or missing, notify-send failed or missing); desktop notifications are skipped"
    fi
fi

exit "$RC"
