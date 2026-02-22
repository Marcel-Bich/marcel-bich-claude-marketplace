#!/bin/bash
# session-start.sh: Clean up old notification state on session start
# Part of desktop-notifier plugin for Claude Code

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/wsl-utils.sh"

PROJECT=$(basename "$PWD" 2>/dev/null || echo "claude")

# Mark that first PreToolUse event should be ignored
# (Either stale from /resume, or user is at terminal anyway for new session)
touch "/tmp/claude-mb-first-event-pending-${PROJECT}"

if is_wsl; then
    # Windows: Clear only ClaudeCode group notifications from Action Center
    powershell.exe -NoProfile -NonInteractive -Command "
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.UI.Notifications.ToastNotificationManager]::History.RemoveGroup('ClaudeCode', '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe')
    " 2>/dev/null &
else
    # Linux: Close all tracked notifications and clean up ID files
    if command -v gdbus &> /dev/null; then
        for id_file in /tmp/claude-mb-notify-id-project-${PROJECT}-*; do
            [ -f "$id_file" ] || continue
            NOTIF_ID=$(cat "$id_file" 2>/dev/null)
            if [ -n "$NOTIF_ID" ] && [ "$NOTIF_ID" != "0" ]; then
                gdbus call --session \
                    -d org.freedesktop.Notifications \
                    -o /org/freedesktop/Notifications \
                    -m org.freedesktop.Notifications.CloseNotification \
                    "$NOTIF_ID" 2>/dev/null || true
            fi
        done
    fi
    rm -f /tmp/claude-mb-notify-id-project-${PROJECT}-* 2>/dev/null
fi

# Kitty tab indicator: mark tab as working
source "$SCRIPT_DIR/kitty-tab.sh"
kitty_tab_save_and_mark "$PROJECT"

exit 0
