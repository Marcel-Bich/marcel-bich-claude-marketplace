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
