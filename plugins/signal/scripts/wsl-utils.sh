#!/bin/bash
# wsl-utils.sh: WSL detection and Windows compatibility functions
# Part of desktop-notifier plugin for Claude Code
#
# Provides cross-platform support for notifications and sound on WSL

# Cache WSL detection result
_WSL_DETECTED=""

# Check if running in WSL
is_wsl() {
    if [ -z "$_WSL_DETECTED" ]; then
        if grep -qi microsoft /proc/version 2>/dev/null; then
            _WSL_DETECTED="true"
        else
            _WSL_DETECTED="false"
        fi
    fi
    [ "$_WSL_DETECTED" = "true" ]
}

# Send Windows toast notification via PowerShell
# Usage: windows_notify "Title" "Message"
windows_notify() {
    local title="${1:-Notification}"
    local message="${2:-}"

    # Escape special characters for PowerShell
    title=$(echo "$title" | sed "s/'/\`'/g" | sed 's/"/\\"/g')
    message=$(echo "$message" | sed "s/'/\`'/g" | sed 's/"/\\"/g')

    # Use BurntToast if available, otherwise fall back to basic toast
    powershell.exe -NoProfile -NonInteractive -Command "
        if (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue) {
            Import-Module BurntToast
            New-BurntToastNotification -Text '$title', '$message' -UniqueIdentifier 'ClaudeCode'
        } else {
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
            [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
            \$template = @'
<toast>
    <visual>
        <binding template=\"ToastText02\">
            <text id=\"1\">$title</text>
            <text id=\"2\">$message</text>
        </binding>
    </visual>
</toast>
'@
            \$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
            \$xml.LoadXml(\$template)
            \$toast = [Windows.UI.Notifications.ToastNotification]::new(\$xml)
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Claude Code').Show(\$toast)
        }
    " 2>/dev/null &
}

# Play sound on Windows via PowerShell
# Usage: windows_sound "complete" or windows_sound "attention"
windows_sound() {
    local sound_type="${1:-complete}"

    case "$sound_type" in
        complete|done)
            # Windows default notification sound
            powershell.exe -NoProfile -NonInteractive -Command "
                [System.Media.SystemSounds]::Exclamation.Play()
            " 2>/dev/null &
            ;;
        attention|message|alert)
            # Windows asterisk/info sound
            powershell.exe -NoProfile -NonInteractive -Command "
                [System.Media.SystemSounds]::Asterisk.Play()
            " 2>/dev/null &
            ;;
        *)
            # Default beep
            powershell.exe -NoProfile -NonInteractive -Command "
                [System.Media.SystemSounds]::Beep.Play()
            " 2>/dev/null &
            ;;
    esac
}

# Play sound cross-platform
# Usage: play_sound "complete" 0.4
# Arguments: type (complete|attention), volume (0.0-1.0, only used on Linux)
play_sound() {
    local sound_type="${1:-complete}"
    local volume="${2:-0.4}"

    # Skip if volume is 0
    if [ "$(echo "$volume <= 0" | bc 2>/dev/null)" = "1" ]; then
        return 0
    fi

    if is_wsl; then
        windows_sound "$sound_type"
    elif command -v paplay &> /dev/null; then
        local sound_file
        case "$sound_type" in
            complete|done)
                sound_file="/usr/share/sounds/freedesktop/stereo/complete.oga"
                ;;
            attention|message|alert)
                sound_file="/usr/share/sounds/freedesktop/stereo/message.oga"
                ;;
            *)
                sound_file="/usr/share/sounds/freedesktop/stereo/bell.oga"
                ;;
        esac

        if [ -f "$sound_file" ]; then
            local current_vol play_vol
            current_vol=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -oP '\d+(?=%)' | head -1)
            play_vol=$(echo "${current_vol:-50} * $volume * 655.36" | bc 2>/dev/null | cut -d. -f1)
            [ -n "$play_vol" ] && paplay --volume="$play_vol" "$sound_file" 2>/dev/null &
        fi
    fi
}
