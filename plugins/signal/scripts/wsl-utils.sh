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
# Usage: windows_notify "Title" "Message" "Tag" "Urgency"
# - Tag: Used for notification replacement (same tag = replace old notification)
# - Urgency: 1=normal (5s), 2=critical (persistent)
# Uses scenario="incomingCall" to bypass Focus Assist and show banner
windows_notify() {
    local title="${1:-Notification}"
    local message="${2:-}"
    local tag="${3:-claude-default}"
    local urgency="${4:-1}"

    # Escape special characters for PowerShell
    title=$(echo "$title" | sed "s/'/\`'/g" | sed 's/"/\\"/g')
    message=$(echo "$message" | sed "s/'/\`'/g" | sed 's/"/\\"/g')
    # Sanitize tag for Windows (alphanumeric and dash only)
    tag=$(echo "$tag" | sed 's/[^a-zA-Z0-9-]/-/g')

    # Duration: short (5s) for normal, long (25s) for critical
    local duration="short"
    [ "$urgency" = "2" ] && duration="long"

    powershell.exe -NoProfile -NonInteractive -Command "
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        \$template = @'
<toast scenario=\"incomingCall\" duration=\"$duration\">
    <visual>
        <binding template=\"ToastText02\">
            <text id=\"1\">$title</text>
            <text id=\"2\">$message</text>
        </binding>
    </visual>
    <audio silent=\"true\"/>
</toast>
'@
        \$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        \$xml.LoadXml(\$template)
        \$toast = [Windows.UI.Notifications.ToastNotification]::new(\$xml)
        \$toast.Tag = '$tag'
        \$toast.Group = 'ClaudeCode'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show(\$toast)
    " 2>/dev/null &
}

# Play sound on Windows via PowerShell with volume control
# Usage: windows_sound "complete" 0.4
# Arguments: type (complete|attention), linux_volume (0.0-1.0)
# Volume is converted: Windows_Volume = Linux_Volume * 0.125 (so 0.4 -> 0.05)
windows_sound() {
    local sound_type="${1:-complete}"
    local linux_volume="${2:-0.4}"

    # Select sound file and volume factor based on type
    # Speech On.wav is quieter by nature, needs higher volume factor
    local sound_file
    local volume_factor="0.125"
    case "$sound_type" in
        complete|done)
            sound_file='C:\Windows\Media\Windows Notify Email.wav'
            volume_factor="0.125"  # Linux 0.4 -> Windows 0.05
            ;;
        attention|message|alert)
            sound_file='C:\Windows\Media\Speech On.wav'
            volume_factor="0.35"   # Linux 0.25 -> Windows ~0.09 (louder for quiet sound)
            ;;
        *)
            sound_file='C:\Windows\Media\Windows Notify Email.wav'
            volume_factor="0.125"
            ;;
    esac

    # Convert Linux volume to Windows volume
    local win_volume=$(echo "$linux_volume * $volume_factor" | bc -l 2>/dev/null | head -c 6)
    [ -z "$win_volume" ] && win_volume="0.05"

    powershell.exe -NoProfile -NonInteractive -Command "
        Add-Type -AssemblyName PresentationCore
        \$player = New-Object System.Windows.Media.MediaPlayer
        \$player.Volume = $win_volume
        \$player.Open([Uri]'$sound_file')
        \$player.Play()
        Start-Sleep -Milliseconds 1500
        \$player.Close()
    " 2>/dev/null &
}
