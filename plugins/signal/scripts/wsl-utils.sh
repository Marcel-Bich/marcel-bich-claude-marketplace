#!/bin/bash
# wsl-utils.sh: WSL detection, powershell.exe resolution and Windows compatibility functions
# Part of desktop-notifier plugin for Claude Code
#
# Provides cross-platform support for notifications and sound on WSL.
#
# Environment:
#   CLAUDE_MB_NOTIFY_TOAST: "true" (default) or "false"/"off"/"no"/"0"/"disabled" to skip every toast and
#                           desktop-notification attempt (and the preflight). Sounds are unaffected.
#   CLAUDE_MB_SIGNAL_STATE_DIR: state dir (default: ${XDG_STATE_HOME:-$HOME/.local/state}/claude-mb-signal)
#   CLAUDE_MB_SIGNAL_PS_TIMEOUT: seconds before a powershell.exe run is killed (default 20)
#   CLAUDE_MB_SIGNAL_PROC_MOUNTS / CLAUDE_MB_SIGNAL_PROC_VERSION: test seams for /proc/mounts and /proc/version

# Cache WSL detection result
_WSL_DETECTED=""

# Check if running in WSL
is_wsl() {
    if [ -z "$_WSL_DETECTED" ]; then
        if grep -qi microsoft "${CLAUDE_MB_SIGNAL_PROC_VERSION:-/proc/version}" 2>/dev/null; then
            _WSL_DETECTED="true"
        else
            _WSL_DETECTED="false"
        fi
    fi
    [ "$_WSL_DETECTED" = "true" ]
}

# --- state dir, log, rate-limited warnings -------------------------------------------

# Print the state dir (created 0700) or return 1 when it is not usable; callers then simply
# run without state. Hardening, so that nothing is ever written through a planted symlink:
#  - the path must be absolute, without "." / ".." / "//" parts and not a top-level directory
#  - anchor: $HOME when the dir lies below it, else the dir's parent (an explicit choice)
#  - the physical path of the dir must be exactly "<physical path of the anchor>/<relative
#    part>", so no symlink may sit anywhere below the anchor
#  - every level below the anchor must be a real directory owned by the user; a parent must not
#    be world-writable (unless it has the sticky bit) and not group-writable unless that group
#    is one of the user's own groups (default Ubuntu umask 002 makes ~/.local group-writable
#    for the user's private group); the dir itself is tightened to 0700
# Only POSIX-ish tools are used (GNU or BSD stat, cd -P, id), so it also works on macOS.

# Print "<uid> <octal mode with special bits> <gid>" of a path: GNU stat first, BSD stat second.
_signal_stat_umg() {
    local out
    if out="$(stat -c '%u %a %g' -- "$1" 2>/dev/null)" && [ -n "$out" ]; then
        printf '%s\n' "$out"
        return 0
    fi
    out="$(stat -f '%u %Mp%Lp %g' -- "$1" 2>/dev/null)" && [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

# Print the numeric group ids of the current user (separate function: a test seam).
_signal_user_groups() {
    id -G 2>/dev/null
}

# True when the numeric gid is one of the user's groups.
_signal_in_my_groups() {
    local g
    for g in $(_signal_user_groups); do
        [ "$g" = "$1" ] && return 0
    done
    return 1
}

# Print the physical path (no symlink left) of an existing directory, rc 1 otherwise.
_signal_physdir() {
    ( CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P )
}

signal_state_dir() {
    local d="${CLAUDE_MB_SIGNAL_STATE_DIR:-}" home anchor p ra rd uid owner mode gid m dmode=""
    if [ -z "$d" ]; then
        if [ -n "${XDG_STATE_HOME:-}" ]; then d="$XDG_STATE_HOME/claude-mb-signal"
        elif [ -n "${HOME:-}" ]; then d="$HOME/.local/state/claude-mb-signal"
        else return 1
        fi
    fi
    case "$d" in /*) ;; *) return 1 ;; esac
    case "$d" in *//*|*/./*|*/.|*/../*|*/..) return 1 ;; esac
    d="${d%/}"
    anchor="${d%/*}"
    [ -n "$anchor" ] || return 1
    home="${HOME:-}"
    home="${home%/}"
    if [ -n "$home" ]; then
        case "$d" in "$home"/*) anchor="$home" ;; esac
    fi
    [ -L "$d" ] && return 1
    if [ ! -d "$d" ]; then
        (umask 077; mkdir -p -- "$d") 2>/dev/null || return 1
    fi
    [ -d "$d" ] || return 1
    ra="$(_signal_physdir "$anchor")" || return 1
    rd="$(_signal_physdir "$d")" || return 1
    [ "$rd" = "${ra%/}/${d#"$anchor"/}" ] || return 1
    uid="$(id -u)"
    p="$d"
    while [ "$p" != "$anchor" ] && [ -n "$p" ]; do
        [ -L "$p" ] && return 1
        [ -d "$p" ] || return 1
        read -r owner mode gid < <(_signal_stat_umg "$p") || return 1
        case "$mode" in ''|*[!0-7]*) return 1 ;; esac
        [ "$owner" = "$uid" ] || return 1
        if [ "$p" = "$d" ]; then
            dmode="$(( 8#$mode & 8#7777 ))"
        else
            m=$(( 8#$mode ))
            # world-writable parent: only with the sticky bit
            [ $(( m & 8#002 )) -eq 0 ] || [ $(( m & 8#1000 )) -ne 0 ] || return 1
            # group-writable parent: only when the group is one of the user's own
            [ $(( m & 8#020 )) -eq 0 ] || _signal_in_my_groups "$gid" || return 1
        fi
        p="${p%/*}"
    done
    [ "$dmode" -eq $(( 8#700 )) ] || chmod 700 -- "$d" 2>/dev/null || return 1
    printf '%s\n' "$d"
}

# True when the path is not a symlink (a missing path is fine). Checked before every write
# into the state dir: a planted symlink is never written through.
_signal_nolink() {
    [ ! -L "$1" ]
}

# Create the file or refresh its mtime, never through a symlink.
# Usage: signal_touch <file>
signal_touch() {
    _signal_nolink "$1" && touch -- "$1" 2>/dev/null
}

# Replace <dest> with stdin, atomically (private mktemp file next to it, then rename). Refuses
# when <dest> is a symlink or a directory (mv would move the file into it).
# Usage: <producer> | _signal_atomic_write <dest>
_signal_atomic_write() {
    local dest="$1" tmp
    _signal_nolink "$dest" || return 1
    [ ! -d "$dest" ] || return 1
    tmp="$(mktemp "$dest.XXXXXX" 2>/dev/null)" || return 1
    if cat > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$dest" 2>/dev/null; then
        return 0
    fi
    rm -f -- "$tmp" 2>/dev/null
    return 1
}

# Append one line to the state log (flattened and capped); keeps the log small.
signal_log() {
    local d line size
    d="$(signal_state_dir)" || return 0
    _signal_nolink "$d/signal.log" || return 0
    line="$(printf '%s' "$*" | tr '\r\n' '  ' | cut -c1-400)"
    printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null)" "$line" >> "$d/signal.log" 2>/dev/null
    size="$(wc -c < "$d/signal.log" 2>/dev/null | tr -d ' ')"
    if [ "${size:-0}" -gt 65536 ]; then
        tail -n 200 -- "$d/signal.log" 2>/dev/null | _signal_atomic_write "$d/signal.log"
    fi
    return 0
}

# True when the marker file (a regular file, not a symlink) is younger than the given number
# of minutes (default: a day).
# Usage: signal_stamp_fresh <file> [minutes]
signal_stamp_fresh() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ -z "$(find "$1" -mmin +"${2:-1440}" 2>/dev/null)" ]
}

# Warn on stderr and in the log, at most once per day per key (marker in the state dir). Without
# a usable state dir (HOME unset, symlinked parent, ...) the marker is a private per-user file
# in ${TMPDIR:-/tmp} instead; a symlinked marker or one that cannot be written means silence,
# never a warning on every call.
# Usage: signal_warn_once <key> <message>
signal_warn_once() {
    local key="${1//[^A-Za-z0-9._-]/_}" msg="$2" d m
    if d="$(signal_state_dir)"; then
        signal_stamp_fresh "$d/warned-$key" && return 0
        signal_touch "$d/warned-$key"
    else
        m="${TMPDIR:-/tmp}/claude-mb-signal-warned-$(id -u 2>/dev/null)-$key"
        [ ! -L "$m" ] || return 0
        signal_stamp_fresh "$m" && return 0
        if [ -e "$m" ]; then
            touch -- "$m" 2>/dev/null || return 0
        else
            ( umask 077; set -C; : > "$m" ) 2>/dev/null || return 0
        fi
    fi
    printf 'signal: %s\n' "$msg" >&2
    signal_log "$msg"
    return 0
}

# --- toast switch ---------------------------------------------------------------------

# True unless CLAUDE_MB_NOTIFY_TOAST is false/off/no/0/disabled (any case, surrounding
# whitespace ignored).
signal_toast_enabled() {
    local v="${CLAUDE_MB_NOTIFY_TOAST:-true}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
    case "$v" in
        0|false|off|no|disabled) return 1 ;;
    esac
    return 0
}

# --- powershell.exe resolution --------------------------------------------------------

# True when the path is an absolute, executable file named powershell.exe.
_signal_valid_ps() {
    case "$1" in /*) ;; *) return 1 ;; esac
    [ "${1##*/}" = "powershell.exe" ] && [ -f "$1" ] && [ -x "$1" ]
}

# Print the first usable Windows PowerShell below a Windows drive mount of /proc/mounts.
# A drive mount is 9p/drvfs with path=<Letter>: in the options or a "<Letter>:" device; the
# WSL "drivers" mount has neither and is skipped. No drive letter or mount point is assumed.
_signal_ps_from_mounts() {
    local dev mnt fst opts _rest cand
    local mounts="${CLAUDE_MB_SIGNAL_PROC_MOUNTS:-/proc/mounts}"
    local rel="Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    # checked up front: a failing "done < file" redirection prints its error before 2>/dev/null
    [ -r "$mounts" ] || return 1
    while read -r dev mnt fst opts _rest; do
        case "$fst" in 9p|drvfs) ;; *) continue ;; esac
        case "$opts" in
            *path=[A-Za-z]:*) ;;
            *) case "$dev" in [A-Za-z]:*) ;; *) continue ;; esac ;;
        esac
        # /proc/mounts escapes space, tab and backslash in the mount point
        mnt="${mnt//\\040/ }"
        mnt="${mnt//\\011/$'\t'}"
        mnt="${mnt//\\134/\\}"
        cand="${mnt%/}/$rel"
        if _signal_valid_ps "$cand"; then
            printf '%s\n' "$cand"
            return 0
        fi
    done < "$mounts"
    return 1
}

# Print the path of powershell.exe: PATH first, then the cached path (re-validated), then
# a scan of the Windows drive mounts; a found path is cached in the state dir.
# Returns 1 (prints nothing, no warning) when it cannot be found.
resolve_powershell() {
    local p d cached
    d="$(signal_state_dir)" || d=""
    p="$(command -v powershell.exe 2>/dev/null)"
    if [ -z "$p" ] || ! _signal_valid_ps "$p"; then
        p=""
        if [ -n "$d" ] && [ -f "$d/powershell-path" ]; then
            cached="$(head -n1 -- "$d/powershell-path" 2>/dev/null)"
            _signal_valid_ps "$cached" && p="$cached"
        fi
        [ -n "$p" ] || p="$(_signal_ps_from_mounts)"
    fi
    [ -n "$p" ] || return 1
    if [ -n "$d" ] && [ "$(head -n1 -- "$d/powershell-path" 2>/dev/null)" != "$p" ]; then
        printf '%s\n' "$p" | _signal_atomic_write "$d/powershell-path"
    fi
    printf '%s\n' "$p"
}

# Print a PowerShell script as base64 of its UTF-16LE bytes, the form -EncodedCommand takes.
# The script then travels as one single-line argument: no quoting, no newlines in argv, no
# interpretation by the Windows command-line parser. Invalid UTF-8 is dropped (iconv -c).
# Returns 1 (prints nothing) when iconv or base64 is missing.
_signal_ps_encode() {
    local enc
    enc="$(printf '%s' "$1" | iconv -c -f UTF-8 -t UTF-16LE 2>/dev/null | base64 2>/dev/null | tr -d '\n')"
    [ -n "$enc" ] || return 1
    printf '%s' "$enc"
}

# Run powershell.exe in the foreground: script via -EncodedCommand, stdin from /dev/null,
# killed after the timeout (exit 124); stdout and stderr are left to the caller. Exit 125 when
# the script cannot be encoded.
# Usage: _signal_ps_run <powershell-path> <timeout-seconds> <script>
_signal_ps_run() {
    local enc
    # no progress records (CLIXML on stderr) from cmdlets in a non-interactive run
    if ! enc="$(_signal_ps_encode "\$ProgressPreference = 'SilentlyContinue'"$'\n'"$3")"; then
        echo "cannot encode the PowerShell script (iconv or base64 missing)" >&2
        return 125
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout "$2" "$1" -NoProfile -NonInteractive -EncodedCommand "$enc" </dev/null
    else
        "$1" -NoProfile -NonInteractive -EncodedCommand "$enc" </dev/null
    fi
}

# Run powershell.exe in the background (killed after the timeout), evaluate its exit code.
# The subshell is detached from the hook: stdin /dev/null, stdout and stderr discarded.
# A failure goes to the log and to the per-kind "ps-failed-<what>" marker (read by the next
# notification of that kind to emit one rate-limited warning); a success clears only its own
# kind's marker, so a working sound run does not hide a failing toast.
# Usage: signal_ps_bg <what> <powershell-path> <script>
signal_ps_bg() {
    local what="$1" ps="$2" cmd="$3" t="${CLAUDE_MB_SIGNAL_PS_TIMEOUT:-20}"
    (
        local err rc d kind="${what//[^A-Za-z0-9._-]/_}"
        err="$(_signal_ps_run "$ps" "$t" "$cmd" 2>&1 >/dev/null)"
        rc=$?
        d="$(signal_state_dir)" || d=""
        if [ "$rc" -ne 0 ]; then
            signal_log "powershell.exe $what failed: exit $rc: $err"
            [ -n "$d" ] && printf '%s failed (exit %s), see signal.log in the state dir\n' "$what" "$rc" | _signal_atomic_write "$d/ps-failed-$kind"
        elif [ -n "$d" ]; then
            rm -f -- "$d/ps-failed-$kind" 2>/dev/null
        fi
    ) </dev/null >/dev/null 2>&1 &
}

# Emit the rate-limited warning for a failed earlier powershell.exe run of the given kind
# (the <what> of signal_ps_bg), if any.
# Usage: _signal_warn_last_ps_failure <what>
_signal_warn_last_ps_failure() {
    local d kind="${1//[^A-Za-z0-9._-]/_}"
    d="$(signal_state_dir)" || return 0
    [ -s "$d/ps-failed-$kind" ] || return 0
    signal_warn_once "ps-failed-$kind" "powershell.exe $(head -n1 -- "$d/ps-failed-$kind" 2>/dev/null)"
}

# Resolve powershell.exe or warn once (per day) that it is missing. Prints the path.
_signal_need_ps() {
    local p
    if ! p="$(resolve_powershell)"; then
        signal_warn_once ps-missing "powershell.exe not found (checked PATH and the Windows drive mounts); Windows toasts and sounds are skipped"
        return 1
    fi
    printf '%s\n' "$p"
}

# Send Windows toast notification via PowerShell
# Usage: windows_notify "Title" "Message" "Tag" "Urgency"
# - Tag: Used for notification replacement (same tag = replace old notification)
# - Urgency: 1=normal (5s), 2=critical (persistent)
# Uses scenario="incomingCall" to bypass Focus Assist and show banner
# Returns 0 when the toast run was started (its exit code is evaluated in the background),
# 1 when powershell.exe cannot be found (one warning per day), 3 when the toast switch is off.
windows_notify() {
    local title="${1:-Notification}"
    local message="${2:-}"
    local tag="${3:-claude-default}"
    local urgency="${4:-1}"
    local ps ps_cmd

    signal_toast_enabled || return 3
    ps="$(_signal_need_ps)" || return 1
    _signal_warn_last_ps_failure toast

    # Multi-line bodies (git line / message / tmux+kitty line): ToastText02 shows
    # the body as one wrapping text field, so join non-empty lines with " | "
    # instead of passing raw newlines (and blank lines) into the toast XML.
    # Control characters other than tab and newline are dropped (invalid in XML 1.0, the toast
    # would not load); that includes the carriage return.
    message=$(printf '%s\n' "$message" | tr -d '\000-\010\013-\037' | awk 'NF { printf "%s%s", (n++ ? " | " : ""), $0 }')
    # The title is one line as well: a newline in it could put the here-string terminator
    # ('@ at a line start) into the script.
    title=$(printf '%s' "$title" | tr '\r\n' '  ' | tr -d '\000-\010\013-\037')
    # Length caps BEFORE the escaping (cutting an escaped text could leave half an entity): the
    # script travels as one base64 argument of UTF-16, and Windows limits a command line to
    # about 32k characters. Worst case after escaping (every character a '&' = 5 characters):
    # (200 + 1000) * 5 characters = about 16k base64 characters plus the template, far below it.
    title="${title:0:200}"
    message="${message:0:1000}"

    # Escape XML special characters (paths/commands may contain & < >). Nothing else needs
    # escaping: the text sits in a single-quoted here-string and the script is passed through
    # -EncodedCommand, so neither PowerShell nor the Windows command-line parser sees it.
    title=$(printf '%s' "$title" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    message=$(printf '%s' "$message" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

    # Tag (session id, not trusted): only [A-Za-z0-9-] reaches the script (any other character,
    # a newline included, becomes a dash); Windows limits a tag to 64 characters
    tag=$(printf '%s' "$tag" | tr -c 'A-Za-z0-9-' '-')
    tag="${tag:0:64}"

    # Duration: short (5s) for normal, long (25s) for critical
    local duration="short"
    [ "$urgency" = "2" ] && duration="long"

    ps_cmd="
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
    "
    signal_ps_bg toast "$ps" "$ps_cmd"
    return 0
}

# Play sound on Windows via PowerShell with volume control
# Usage: windows_sound "complete" 0.4
# Arguments: type (complete|attention), linux_volume (0.0-1.0)
# Volume is converted: Windows_Volume = Linux_Volume * 0.125 (so 0.4 -> 0.05)
# Independent of the toast switch. Returns 1 when powershell.exe cannot be found.
windows_sound() {
    local sound_type="${1:-complete}"
    local linux_volume="${2:-0.4}"
    local ps

    ps="$(_signal_need_ps)" || return 1
    _signal_warn_last_ps_failure sound

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
    local win_volume
    win_volume=$(echo "$linux_volume * $volume_factor" | bc -l 2>/dev/null | head -c 6)
    [ -z "$win_volume" ] && win_volume="0.05"

    signal_ps_bg sound "$ps" "
        Add-Type -AssemblyName PresentationCore
        \$player = New-Object System.Windows.Media.MediaPlayer
        \$player.Volume = $win_volume
        \$player.Open([Uri]'$sound_file')
        \$player.Play()
        Start-Sleep -Milliseconds 1500
        \$player.Close()
    "
    return 0
}
