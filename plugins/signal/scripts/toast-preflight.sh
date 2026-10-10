#!/bin/bash
# toast-preflight.sh: once-a-day check that desktop toasts can show up at all
# Part of desktop-notifier plugin for Claude Code
#
# Sourced by session-start.sh (function signal_preflight); also a small CLI:
#   toast-preflight.sh decline         stop the hints for good (state file preflight-declined)
#   toast-preflight.sh reset           clear the decline, the daily stamp, the probe state and the warning stamps
#   toast-preflight.sh open-settings   open the Windows notification settings (ms-settings:notifications)
#
# Only runs when CLAUDE_MB_NOTIFY_TOAST is on. At most once per day (stamp in the state dir).
# WSL: READ-ONLY registry reads through powershell.exe (nothing is ever written or changed),
# absent value = enabled. Native Linux: only checks that gdbus or notify-send exist (never
# powershell). The result is at most one short line on stdout, which SessionStart hands to
# the agent as context. Focus Assist is deliberately not checked. There is no other fallback.
#
# WSL flow (SessionStart has a 5 s budget, a cold powershell.exe start can take longer):
#   session N    starts the registry read detached in the background (stdin /dev/null, marker
#                preflight-pending) and prints nothing; the probe writes preflight-result
#   session N+1  reports the result (one line when toasts look disabled), sets the daily stamp
#                preflight-checked and removes the result
# The daily stamp is only set after a usable result. A failed probe (no output, killed by the
# timeout) or a powershell.exe that cannot be found leaves the marker preflight-failed (the
# latter also logs/prints its one line, at most once a day): the next session retries, but at
# most once per hour.
#
# Environment:
#   CLAUDE_MB_SIGNAL_PREFLIGHT_TIMEOUT: seconds before the background registry read is killed
#   (default 20)

_SIGNAL_PREFLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SIGNAL_PREFLIGHT_SELF="$_SIGNAL_PREFLIGHT_DIR/toast-preflight.sh"
# shellcheck source=wsl-utils.sh
source "$_SIGNAL_PREFLIGHT_DIR/wsl-utils.sh"

# Read-only. Prints "T=<ToastEnabled>;G=<NOC_GLOBAL_SETTING_TOASTS_ENABLED>;A=<per-app Enabled>"
# (empty = value absent). The per-app key is the AppID signal uses, nested as Windows stores it.
_SIGNAL_PREFLIGHT_PS='
$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
$b = "HKCU:\Software\Microsoft\Windows\CurrentVersion"
$t = (Get-ItemProperty -LiteralPath "$b\PushNotifications").ToastEnabled
$g = (Get-ItemProperty -LiteralPath "$b\Notifications\Settings").NOC_GLOBAL_SETTING_TOASTS_ENABLED
$a = (Get-ItemProperty -LiteralPath "$b\Notifications\Settings\{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe").Enabled
"T=$t;G=$g;A=$a"
'

# Context line for an "off" result, empty when everything is on or the result is unusable.
# Usage: _signal_preflight_report <T=..;G=..;A=..>
_signal_preflight_report() {
    local out="$1" reasons="" t g a cmd_hint
    cmd_hint="bash \"$_SIGNAL_PREFLIGHT_SELF\""
    case "$out" in
        T=*\;G=*\;A=*) ;;
        *) return 0 ;;
    esac
    t="${out#T=}"; t="${t%%;*}"
    g="${out#*;G=}"; g="${g%%;*}"
    a="${out#*;A=}"
    [ "$t" = "0" ] && reasons="PushNotifications ToastEnabled=0"
    [ "$g" = "0" ] && reasons="${reasons:+$reasons, }NOC_GLOBAL_SETTING_TOASTS_ENABLED=0"
    [ "$a" = "0" ] && reasons="${reasons:+$reasons, }per-app switch of the toast sender Enabled=0"
    [ -n "$reasons" ] || return 0
    echo "[signal] Windows toast notifications look disabled for this user ($reasons), so signal toasts will not show. Tell the user once, briefly, and ask whether they want you to open the Windows notification settings. Run: $cmd_hint open-settings ONLY after the user said yes, never on your own (it opens ms-settings:notifications, changes nothing). Never change the setting yourself; the user switches it on manually (Settings > System > Notifications, \"Get notifications from apps and other senders\" = On; German UI: \"Benachrichtigungen von Apps und anderen Absendern abrufen\" = Ein). If the user wants no further hints, run: $cmd_hint decline"
}

# Background probe (called detached): run the registry read, store a usable result for the
# next session, otherwise log and leave the short-lived failure marker. Always clears the
# pending marker at the end.
# Usage: _signal_preflight_probe <powershell-path> <state-dir>
_signal_preflight_probe() {
    local ps="$1" d="$2" out rc line
    out="$(_signal_ps_run "$ps" "${CLAUDE_MB_SIGNAL_PREFLIGHT_TIMEOUT:-20}" "$_SIGNAL_PREFLIGHT_PS" 2>/dev/null)"
    rc=$?
    line="$(printf '%s' "$out" | tr -d '\r' | tail -n1)"
    case "$line" in
        T=*\;G=*\;A=*)
            if printf '%s\n' "$line" | _signal_atomic_write "$d/preflight-result"; then
                rm -f -- "$d/preflight-failed"
            else
                signal_log "preflight: could not store the registry result"
                signal_touch "$d/preflight-failed"
            fi
            ;;
        *)
            signal_log "preflight: registry read gave no usable result (exit $rc)"
            signal_touch "$d/preflight-failed"
            ;;
    esac
    rm -f -- "$d/preflight-pending"
}

_signal_preflight_wsl() {
    local d="$1" res stamp ps line ttl
    res="$d/preflight-result"
    stamp="$d/preflight-checked"

    # A finished probe: report it once, now the day counts as checked
    if [ -f "$res" ] && [ ! -L "$res" ]; then
        line="$(head -n1 -- "$res" 2>/dev/null)"
        rm -f -- "$res"
        signal_touch "$stamp"
        _signal_preflight_report "$line"
        return 0
    fi

    signal_stamp_fresh "$stamp" && return 0
    # A failed probe is retried at most once per hour; a running one is not started twice
    signal_stamp_fresh "$d/preflight-failed" 60 && return 0
    ttl=$(( ${CLAUDE_MB_SIGNAL_PREFLIGHT_TIMEOUT:-20} / 60 + 2 ))
    signal_stamp_fresh "$d/preflight-pending" "$ttl" && return 0

    if ! ps="$(resolve_powershell)"; then
        # Not a usable result: no daily stamp. The failure marker throttles the next try to once
        # per hour (powershell.exe may show up later), the line itself goes out once a day.
        signal_touch "$d/preflight-failed"
        signal_stamp_fresh "$d/warned-preflight-ps-missing" && return 0
        signal_touch "$d/warned-preflight-ps-missing"
        echo "[signal] powershell.exe could not be found from this WSL session (not on PATH, not below any Windows drive mount), so Windows toasts and sounds are skipped. Tell the user once, briefly; do not search for it or install anything. If the user wants no further hints, run: bash \"$_SIGNAL_PREFLIGHT_SELF\" decline"
        return 0
    fi

    # Detached: the hook must not wait for a cold powershell.exe start
    signal_touch "$d/preflight-pending"
    ( _signal_preflight_probe "$ps" "$d" ) </dev/null >/dev/null 2>&1 &
}

_signal_preflight_linux() {
    local d="$1" stamp
    stamp="$d/preflight-checked"
    signal_stamp_fresh "$stamp" && return 0
    signal_touch "$stamp"
    command -v gdbus >/dev/null 2>&1 && return 0
    command -v notify-send >/dev/null 2>&1 && return 0
    echo "[signal] Neither gdbus nor notify-send is available, so signal desktop notifications will not show. Tell the user once, briefly; do not install anything. If the user wants no further hints, run: bash \"$_SIGNAL_PREFLIGHT_SELF\" decline"
}

# Entry point for SessionStart. Silent unless there is something to say; never blocks.
signal_preflight() {
    local d
    signal_toast_enabled || return 0
    d="$(signal_state_dir)" || return 0
    [ -e "$d/preflight-declined" ] && return 0
    if is_wsl; then
        _signal_preflight_wsl "$d"
    else
        _signal_preflight_linux "$d"
    fi
    return 0
}

_signal_preflight_main() {
    local d ps
    case "${1:-}" in
        decline)
            d="$(signal_state_dir)" || { echo "state dir not usable" >&2; return 1; }
            signal_touch "$d/preflight-declined" && echo "signal: toast hints turned off (reset with: bash \"$_SIGNAL_PREFLIGHT_SELF\" reset)"
            ;;
        reset)
            d="$(signal_state_dir)" || { echo "state dir not usable" >&2; return 1; }
            rm -f -- "$d/preflight-declined" "$d/preflight-checked" "$d/preflight-result" \
                "$d/preflight-failed" "$d/preflight-pending" "$d"/warned-* "$d"/ps-failed-*
            echo "signal: toast hints and warnings reset"
            ;;
        open-settings)
            is_wsl || { echo "open-settings is only for WSL" >&2; return 1; }
            ps="$(resolve_powershell)" || { echo "powershell.exe not found" >&2; return 1; }
            _signal_ps_run "$ps" 10 "Start-Process 'ms-settings:notifications'" >/dev/null 2>&1
            ;;
        *)
            echo "usage: toast-preflight.sh decline|reset|open-settings" >&2
            return 2
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    _signal_preflight_main "$@"
fi
