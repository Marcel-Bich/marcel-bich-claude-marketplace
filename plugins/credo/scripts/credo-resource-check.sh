#!/bin/bash
# credo-resource-check - may one more agent start without overloading the machine? (read-only)
#
# The resource gate for parallel subagents (credo orchestration skill). Below
# resources.gate_from_agents running agents it answers "ok" without looking at
# the machine; from that count on (and ALWAYS with --heavy) it reads free RAM
# (/proc/meminfo MemAvailable) and the 1-minute load per CPU (/proc/loadavg
# divided by nproc) and answers "wait:<reason>" when a threshold is crossed.
# Free disk on the target drive is checked ALWAYS, also below the gate: the
# item's disk_gb plus the reserve must fit (see --disk-gb and --path below).
# On "wait" the caller starts no new agent and re-checks when the next running
# agent finishes (completion notification, no polling loop).
#
# Usage:
#   credo-resource-check.sh --running N [--heavy] [--disk-gb G] [--path P] [--json]
#     --running N  agents currently running (required, integer >= 0)
#     --heavy      the agent to start is heavy (model/benchmark tests, large
#                  downloads): always check RAM and load, even below the gate
#     --disk-gb G  the item's disk_gb (optional, number >= 0); absent = only the
#                  reserve is checked
#     --path P     any path on the target drive (default: the current directory)
#     --json       {"status":"ok"|"wait","reason":"...","checked":true|false,...}
#   text output: "ok" or "wait:<reason>" (one line)
#
# Thresholds (credo config cascade, read via credo-config.sh get; builtin
# defaults apply when a key is absent or not a number):
#   resources.gate_from_agents   6    check only from this many running agents
#   resources.min_free_ram_gb    4    wait below this much MemAvailable (GB)
#   resources.max_load_per_cpu   1.0  wait above this 1-min load per CPU
#   resources.disk_reserve_gb    3    free disk that must stay after the item's disk_gb
#
# Fail-safe: an unreadable /proc or df value never blocks - the check answers "ok"
# and notes the reason on stderr.
#
# Env overrides (testing):
#   CREDO_PROC_MEMINFO  meminfo file (default /proc/meminfo)
#   CREDO_PROC_LOADAVG  loadavg file (default /proc/loadavg)
#   CREDO_NPROC         CPU count (default: nproc)
#   CREDO_DISK_AVAIL_KB free KB on the target drive (default: df of --path; set but
#                       empty = unreadable)
#
# Exit codes: 0 ok, 5 wait, 1 bad arguments.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNNING=""
HEAVY=0
MODE="text"
DISK_NEED=""
DISK_PATH="."
while [ $# -gt 0 ]; do
    case "$1" in
        --running)
            [ $# -ge 2 ] || { echo "credo-resource-check: --running needs a number" >&2; exit 1; }
            RUNNING="$2"
            shift
            ;;
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
        --heavy) HEAVY=1 ;;
        --json) MODE="json" ;;
        *) echo "credo-resource-check: unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done
case "$RUNNING" in
    ""|*[!0-9]*) echo "usage: credo-resource-check.sh --running N [--heavy] [--disk-gb G] [--path P] [--json]" >&2; exit 1 ;;
esac
if [ -n "$DISK_NEED" ] && ! [[ "$DISK_NEED" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "credo-resource-check: --disk-gb needs a number" >&2
    exit 1
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

GATE="$(cfg gate_from_agents 6)"
GATE="${GATE%%.*}"
MIN_RAM="$(cfg min_free_ram_gb 4)"
MAX_LOAD="$(cfg max_load_per_cpu 1.0)"
DISK_RESERVE="$(cfg disk_reserve_gb 3)"

STATUS="ok"
REASON=""
CHECKED=false
MEM_GB=""
LOAD1=""
NCPU=""
LPC=""
DISK_FREE_GB=""
reasons=()

emit() {
    if [ "$MODE" = "json" ]; then
        printf '{"status":"%s","reason":"%s","checked":%s,"running":%s,"heavy":%s,' \
            "$STATUS" "$REASON" "$CHECKED" "$RUNNING" "$([ "$HEAVY" = 1 ] && echo true || echo false)"
        printf '"gate_from_agents":%s,"min_free_ram_gb":%s,"max_load_per_cpu":%s,' \
            "$GATE" "$MIN_RAM" "$MAX_LOAD"
        printf '"mem_available_gb":%s,"load1":%s,"nproc":%s,"load_per_cpu":%s,' \
            "${MEM_GB:-null}" "${LOAD1:-null}" "${NCPU:-null}" "${LPC:-null}"
        printf '"disk_free_gb":%s,"disk_need_gb":%s,"disk_reserve_gb":%s}\n' \
            "${DISK_FREE_GB:-null}" "${DISK_NEED:-null}" "$DISK_RESERVE"
    elif [ "$STATUS" = "ok" ]; then
        echo "ok"
    else
        echo "wait:$REASON"
    fi
    [ "$STATUS" = "ok" ] && exit 0 || exit 5
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

check_ram_and_load() {
    local kb
    CHECKED=true
    MEMINFO="${CREDO_PROC_MEMINFO:-/proc/meminfo}"
    LOADAVG="${CREDO_PROC_LOADAVG:-/proc/loadavg}"

    kb="$(awk '/^MemAvailable:/ { print $2; exit }' "$MEMINFO" 2>/dev/null || true)"
    if [[ "$kb" =~ ^[0-9]+$ ]]; then
        MEM_GB="$(awk -v k="$kb" 'BEGIN { printf "%.2f", k / 1048576 }')"
    else
        echo "credo-resource-check: cannot read MemAvailable from $MEMINFO - RAM not checked" >&2
    fi

    LOAD1="$(awk '{ print $1; exit }' "$LOADAVG" 2>/dev/null || true)"
    [[ "$LOAD1" =~ ^[0-9]+([.][0-9]+)?$ ]] || LOAD1=""
    NCPU="${CREDO_NPROC:-$(nproc 2>/dev/null || true)}"
    [[ "$NCPU" =~ ^[0-9]+$ ]] && [ "$NCPU" -gt 0 ] || NCPU=""
    if [ -n "$LOAD1" ] && [ -n "$NCPU" ]; then
        LPC="$(awk -v l="$LOAD1" -v n="$NCPU" 'BEGIN { printf "%.2f", l / n }')"
    else
        echo "credo-resource-check: cannot read load average or CPU count - load not checked" >&2
    fi

    if [ -n "$MEM_GB" ] && awk -v a="$MEM_GB" -v m="$MIN_RAM" 'BEGIN { exit !(a < m) }'; then
        reasons+=("low free RAM ${MEM_GB} GB < ${MIN_RAM} GB")
    fi
    if [ -n "$LPC" ] && awk -v a="$LPC" -v m="$MAX_LOAD" 'BEGIN { exit !(a > m) }'; then
        reasons+=("high load ${LPC} per CPU > ${MAX_LOAD}")
    fi
}

GATED=0
if [ "$HEAVY" = 1 ] || [ "$RUNNING" -ge "$GATE" ]; then
    check_ram_and_load
    GATED=1
fi
check_disk

if [ "${#reasons[@]}" -gt 0 ]; then
    STATUS="wait"
    REASON="$(IFS=';'; echo "${reasons[*]}")"
    REASON="${REASON//;/; }"
elif [ "$GATED" = 1 ]; then
    REASON="resources ok"
else
    REASON="below gate ($RUNNING < $GATE running)"
fi
emit
