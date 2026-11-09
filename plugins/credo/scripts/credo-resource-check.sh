#!/bin/bash
# credo-resource-check - may one more agent start without overloading the machine? (read-only)
#
# The resource gate for subagents (credo orchestration skill). It runs before
# EVERY agent start, in every mode, and always looks at CPU and RAM:
#   CPU busy = 1-minute load per CPU (/proc/loadavg first value divided by nproc)
#   RAM used = (MemTotal - MemAvailable) / MemTotal (/proc/meminfo)
#   host     = under WSL also the Windows host (the owner's machine; the WSL VM is only a
#              part of it): RAM (total - available) / total and the CPU load in percent,
#              read in one powershell.exe call
# CPU (WSL or host) at resources.max_busy_percent or more, or RAM (WSL or host) at
# resources.max_ram_percent or more answers "wait:<reason>".
# Free disk on the target drive is checked too: the item's disk_gb plus the
# reserve must fit (see --disk-gb and --path below).
# On "wait" the caller starts no new agent and re-checks when the next running
# agent finishes (completion notification, no polling loop).
#
# Usage:
#   credo-resource-check.sh [--disk-gb G] [--path P] [--json]
#     --disk-gb G  the item's disk_gb (optional, number >= 0); absent = only the
#                  reserve is checked
#     --path P     any path on the target drive (default: the current directory)
#     --json       {"status":"ok"|"wait","reason":"...","checked":true|false,...}
#                  checked = CPU or RAM could be read (false = both unreadable)
#   text output: "ok" or "wait:<reason>" (one line)
#
# Thresholds (credo config cascade, read via credo-config.sh get; builtin
# defaults apply when a key is absent or not a number):
#   resources.max_busy_percent   94   wait when CPU busy (WSL or Windows host) is at this percent or more
#   resources.max_ram_percent    80   wait when RAM used (WSL or Windows host) is at this percent or more
#   resources.disk_reserve_gb    3    free disk that must stay after the item's disk_gb
#
# Fail-safe: an unreadable /proc or df value never blocks - that part is not
# checked and the reason goes to stderr.
#
# Env overrides (testing):
#   CREDO_PROC_MEMINFO  meminfo file (default /proc/meminfo)
#   CREDO_PROC_LOADAVG  loadavg file (default /proc/loadavg)
#   CREDO_NPROC         CPU count (default: nproc)
#   CREDO_HOST_MEM      host as "<total bytes> <available bytes> [<cpu load %>]" instead of powershell.exe;
#                       "off" skips the host check (default: queried only under WSL)
#   CREDO_DISK_AVAIL_KB free KB on the target drive (default: df of --path; set but
#                       empty = unreadable)
#
# Exit codes: 0 ok, 5 wait, 1 bad arguments.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# decimal number without leading zeros ("05" -> 5, "1.0" -> 1); keeps JSON valid
norm() { awk -v v="$1" 'BEGIN { printf "%s", v + 0 }'; }

USAGE="usage: credo-resource-check.sh [--disk-gb G] [--path P] [--json]"
MODE="text"
DISK_NEED=""
DISK_PATH="."
while [ $# -gt 0 ]; do
    case "$1" in
        --disk-gb)
            [ $# -ge 2 ] || { echo "credo-resource-check: --disk-gb needs a number" >&2; exit 1; }
            DISK_NEED="$2"
            shift
            ;;
        --path)
            [ $# -ge 2 ] || { echo "credo-resource-check: --path needs a value" >&2; exit 1; }
            DISK_PATH="$2"
            shift
            ;;
        --json) MODE="json" ;;
        *) echo "credo-resource-check: unknown argument: $1" >&2; echo "$USAGE" >&2; exit 1 ;;
    esac
    shift
done
if [ -n "$DISK_NEED" ]; then
    if ! [[ "$DISK_NEED" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "credo-resource-check: --disk-gb needs a number" >&2
        exit 1
    fi
    DISK_NEED="$(norm "$DISK_NEED")"
fi

# config value, falling back to the default when absent or not a number
cfg() {
    local v
    v="$(CREDO_SKIP_ENSURE=1 "$SCRIPT_DIR/credo-config.sh" get "resources.$1" 2>/dev/null || true)"
    if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s' "$v"
    else
        printf '%s' "$2"
    fi
}

MAX_BUSY="$(norm "$(cfg max_busy_percent 94)")"
MAX_RAM="$(norm "$(cfg max_ram_percent 80)")"
DISK_RESERVE="$(norm "$(cfg disk_reserve_gb 3)")"

STATUS="ok"
REASON=""
CHECKED=false
LOAD1=""
NCPU=""
LPC=""
CPU_PCT=""
MEM_GB=""
RAM_PCT=""
HOST_RAM_PCT=""
HOST_CPU_PCT=""
DISK_FREE_GB=""
reasons=()

emit() {
    if [ "$MODE" = "json" ]; then
        printf '{"status":"%s","reason":"%s","checked":%s,"max_busy_percent":%s,' \
            "$STATUS" "$REASON" "$CHECKED" "$MAX_BUSY"
        printf '"cpu_busy_percent":%s,"load1":%s,"nproc":%s,"load_per_cpu":%s,' \
            "${CPU_PCT:-null}" "${LOAD1:-null}" "${NCPU:-null}" "${LPC:-null}"
        printf '"ram_used_percent":%s,"mem_available_gb":%s,"host_ram_used_percent":%s,"max_ram_percent":%s,"host_cpu_percent":%s,' \
            "${RAM_PCT:-null}" "${MEM_GB:-null}" "${HOST_RAM_PCT:-null}" "$MAX_RAM" "${HOST_CPU_PCT:-null}"
        printf '"disk_free_gb":%s,"disk_need_gb":%s,"disk_reserve_gb":%s}\n' \
            "${DISK_FREE_GB:-null}" "${DISK_NEED:-null}" "$DISK_RESERVE"
    elif [ "$STATUS" = "ok" ]; then
        echo "ok"
    else
        echo "wait:$REASON"
    fi
    [ "$STATUS" = "ok" ] && exit 0 || exit 5
}

# true when value $1 is at threshold $2 or more
at_or_over() { awk -v a="$1" -v m="$2" 'BEGIN { exit !(a >= m) }'; }

check_cpu() {
    local loadavg="${CREDO_PROC_LOADAVG:-/proc/loadavg}"
    LOAD1="$(awk '{ print $1; exit }' "$loadavg" 2>/dev/null || true)"
    [[ "$LOAD1" =~ ^[0-9]+([.][0-9]+)?$ ]] || LOAD1=""
    NCPU="${CREDO_NPROC:-$(nproc 2>/dev/null || true)}"
    [[ "$NCPU" =~ ^[0-9]+$ ]] && [ "$NCPU" -gt 0 ] || NCPU=""
    if [ -z "$LOAD1" ] || [ -z "$NCPU" ]; then
        echo "credo-resource-check: cannot read load average or CPU count - CPU not checked" >&2
        return 0
    fi
    CHECKED=true
    LPC="$(awk -v l="$LOAD1" -v n="$NCPU" 'BEGIN { printf "%.2f", l / n }')"
    CPU_PCT="$(awk -v l="$LOAD1" -v n="$NCPU" 'BEGIN { printf "%.1f", l * 100 / n }')"
    if at_or_over "$CPU_PCT" "$MAX_BUSY"; then
        reasons+=("CPU busy ${CPU_PCT}% >= ${MAX_BUSY}%")
    fi
}

check_ram() {
    local meminfo="${CREDO_PROC_MEMINFO:-/proc/meminfo}" total avail
    total="$(awk '/^MemTotal:/ { print $2; exit }' "$meminfo" 2>/dev/null || true)"
    avail="$(awk '/^MemAvailable:/ { print $2; exit }' "$meminfo" 2>/dev/null || true)"
    if ! [[ "$total" =~ ^[0-9]+$ ]] || ! [[ "$avail" =~ ^[0-9]+$ ]] || [ "$total" -eq 0 ]; then
        echo "credo-resource-check: cannot read MemTotal and MemAvailable from $meminfo - RAM not checked" >&2
        return 0
    fi
    CHECKED=true
    MEM_GB="$(awk -v k="$avail" 'BEGIN { printf "%.2f", k / 1048576 }')"
    RAM_PCT="$(awk -v t="$total" -v a="$avail" 'BEGIN { u = (t - a) * 100 / t; if (u < 0) u = 0; printf "%.1f", u }')"
    if at_or_over "$RAM_PCT" "$MAX_RAM"; then
        reasons+=("RAM used ${RAM_PCT}% >= ${MAX_RAM}%")
    fi
}

# the Windows host behind WSL: its RAM is the owner's RAM (the WSL VM is only a part of it)
host_mem() {
    if [ -n "${CREDO_HOST_MEM+x}" ]; then
        printf '%s' "$CREDO_HOST_MEM"
        return 0
    fi
    grep -qi microsoft /proc/version 2>/dev/null || return 0
    command -v powershell.exe >/dev/null 2>&1 || return 0
    timeout 15 powershell.exe -NoProfile -NonInteractive -Command \
        'Add-Type -AssemblyName Microsoft.VisualBasic; $c = New-Object Microsoft.VisualBasic.Devices.ComputerInfo; $l = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average; "$($c.TotalPhysicalMemory) $($c.AvailablePhysicalMemory) $l"' \
        2>/dev/null | tr -d '\r' | head -n 1
}

check_host_ram() {
    local line total avail cpu
    line="$(host_mem || true)"
    [ -n "$line" ] && [ "$line" != off ] || return 0
    read -r total avail cpu <<<"$line"
    if [[ "${cpu:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        CHECKED=true
        HOST_CPU_PCT="$(norm "$cpu")"
        if at_or_over "$HOST_CPU_PCT" "$MAX_BUSY"; then
            reasons+=("host CPU busy ${HOST_CPU_PCT}% >= ${MAX_BUSY}%")
        fi
    fi
    if ! [[ "$total" =~ ^[0-9]+$ ]] || ! [[ "$avail" =~ ^[0-9]+$ ]] || [ "$total" -eq 0 ]; then
        echo "credo-resource-check: cannot read the host RAM - host RAM not checked" >&2
        return 0
    fi
    CHECKED=true
    HOST_RAM_PCT="$(awk -v t="$total" -v a="$avail" 'BEGIN { u = (t - a) * 100 / t; if (u < 0) u = 0; printf "%.1f", u }')"
    if at_or_over "$HOST_RAM_PCT" "$MAX_RAM"; then
        reasons+=("host RAM used ${HOST_RAM_PCT}% >= ${MAX_RAM}%")
    fi
}

# free disk on the target drive: the item's disk_gb plus the reserve must fit
disk_avail_kb() {
    if [ -n "${CREDO_DISK_AVAIL_KB+x}" ]; then
        printf '%s' "$CREDO_DISK_AVAIL_KB"
    else
        df -Pk -- "$DISK_PATH" 2>/dev/null | awk 'NR == 2 { print $4 }'
    fi
}

check_disk() {
    local kb required
    kb="$(disk_avail_kb || true)"
    if ! [[ "$kb" =~ ^[0-9]+$ ]]; then
        echo "credo-resource-check: cannot read free disk on $DISK_PATH - disk not checked" >&2
        return 0
    fi
    DISK_FREE_GB="$(awk -v k="$kb" 'BEGIN { printf "%.2f", k / 1048576 }')"
    required="$(awk -v n="${DISK_NEED:-0}" -v r="$DISK_RESERVE" 'BEGIN { printf "%g", n + r }')"
    if awk -v a="$DISK_FREE_GB" -v q="$required" 'BEGIN { exit !(a < q) }'; then
        if [ -n "$DISK_NEED" ]; then
            reasons+=("low free disk ${DISK_FREE_GB} GB < ${required} GB (${DISK_NEED} needed + ${DISK_RESERVE} reserve)")
        else
            reasons+=("low free disk ${DISK_FREE_GB} GB < ${DISK_RESERVE} GB reserve")
        fi
    fi
}

check_cpu
check_ram
check_host_ram
check_disk

if [ "${#reasons[@]}" -gt 0 ]; then
    STATUS="wait"
    REASON="$(IFS=';'; echo "${reasons[*]}")"
    REASON="${REASON//;/; }"
else
    REASON="resources ok"
fi
emit
