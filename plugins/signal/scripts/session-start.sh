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

# --- Kitty tab: clean up stale prefix and start exit monitor ---

source "$SCRIPT_DIR/kitty-tab.sh"

# Find our kitty window PID (unique per tab)
WINDOW_PID=$(_find_kitty_window_pid)

if [ -n "$WINDOW_PID" ]; then
    # Kill old exit monitor for THIS tab
    EXIT_MONITOR_FILE="/tmp/claude-mb-kitty-exit-monitor-${WINDOW_PID}"
    if [ -f "$EXIT_MONITOR_FILE" ]; then
        OLD_MONITOR=$(cat "$EXIT_MONITOR_FILE" 2>/dev/null)
        if [ -n "$OLD_MONITOR" ] && kill -0 "$OLD_MONITOR" 2>/dev/null; then
            kill "$OLD_MONITOR" 2>/dev/null
        fi
    fi

    # Immediate cleanup of any stale prefix
    kitty_tab_cleanup_stale "$WINDOW_PID"

    # Initialize display name for notifications before first prompt
    kitty_tab_init_display_name

    # Find Claude's actual PID (not an ephemeral hook shell)
    CLAUDE_PID=$(_find_claude_pid)
    if [ -z "$CLAUDE_PID" ]; then
        CLAUDE_PID=$PPID
    fi

    # Background monitor: clean up when Claude exits
    (
        while kill -0 "$CLAUDE_PID" 2>/dev/null; do
            sleep 3
        done
        sleep 1
        kitty_tab_cleanup_stale "$WINDOW_PID"
        rm -f "$EXIT_MONITOR_FILE"
    ) &
    echo $! > "$EXIT_MONITOR_FILE"
fi

exit 0
