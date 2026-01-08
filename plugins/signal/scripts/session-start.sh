#!/bin/bash
# session-start.sh: Clean up old notification state on session start
# Part of desktop-notifier plugin for Claude Code

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/wsl-utils.sh"

PROJECT=$(basename "$PWD" 2>/dev/null || echo "claude")

# Mark session start time (used by hook-notify.sh to ignore stale events)
echo "$(date +%s)" > "/tmp/claude-mb-session-start-${PROJECT}"

if is_wsl; then
    # Windows: Clear only ClaudeCode group notifications from Action Center
    powershell.exe -NoProfile -NonInteractive -Command "
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.UI.Notifications.ToastNotificationManager]::History.RemoveGroup('ClaudeCode', '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe')
    " 2>/dev/null &
else
    # Linux: Remove old notification ID files for this project
    rm -f /tmp/claude-mb-notify-id-project-${PROJECT}-* 2>/dev/null
fi

exit 0
