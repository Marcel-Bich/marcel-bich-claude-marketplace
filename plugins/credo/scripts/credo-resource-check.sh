#!/bin/bash
# credo-resource-check - may one more agent start without overloading the machine? (read-only)
#
# The resource gate for parallel subagents (credo orchestration skill). Below
# resources.gate_from_agents running agents it answers "ok" without looking at
# the machine; from that count on (and ALWAYS with --heavy) it reads free RAM
# (/proc/meminfo MemAvailable) and the 1-minute load per CPU (/proc/loadavg
# divided by nproc) and answers "wait:<reason>" when a threshold is crossed.
# On "wait" the caller starts no new agent and re-checks when the next running
# agent finishes (completion notification, no polling loop).
#
# Usage:
#   credo-resource-check.sh --running N [--heavy] [--json]
#     --running N  agents currently running (required, integer >= 0)
#     --heavy      the agent to start is heavy (model/benchmark tests, large
#                  downloads): always check, even below the gate
#     --json       {"status":"ok"|"wait","reason":"...","checked":true|false,...}
#   text output: "ok" or "wait:<reason>" (one line)
#
# Thresholds (credo config cascade, read via credo-config.sh get; builtin
# defaults apply when a key is absent or not a number):
#   resources.gate_from_agents   6    check only from this many running agents
#   resources.min_free_ram_gb    4    wait below this much MemAvailable (GB)
#   resources.max_load_per_cpu   1.0  wait above this 1-min load per CPU
#
# Fail-safe: an unreadable /proc value never blocks - the check answers "ok"
# and notes the reason on stderr.
#
# Env overrides (testing):
#   CREDO_PROC_MEMINFO  meminfo file (default /proc/meminfo)
#   CREDO_PROC_LOADAVG  loadavg file (default /proc/loadavg)
#   CREDO_NPROC         CPU count (default: nproc)
#
# Exit codes: 0 ok, 5 wait, 1 bad arguments.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNNING=""
HEAVY=0
MODE="text"
while [ $# -gt 0 ]; do
    case "$1" in
        --running)
            [ $# -ge 2 ] || { echo "credo-resource-check: --running needs a number" >&2; exit 1; }
            RUNNING="$2"
            shift
            ;;
        --heavy) HEAVY=1 ;;
        --json) MODE="json" ;;
        *) echo "credo-resource-check: unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done
case "$RUNNING" in
    ""|*[!0-9]*) echo "usage: credo-resource-check.sh --running N [--heavy] [--json]" >&2; exit 1 ;;
esac

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

STATUS="ok"
REASON=""
CHECKED=false
MEM_GB=""
LOAD1=""
NCPU=""
LPC=""

emit() {
    if [ "$MODE" = "json" ]; then
        printf '{"status":"%s","reason":"%s","checked":%s,"running":%s,"heavy":%s,' \
            "$STATUS" "$REASON" "$CHECKED" "$RUNNING" "$([ "$HEAVY" = 1 ] && echo true || echo false)"
        printf '"gate_from_agents":%s,"min_free_ram_gb":%s,"max_load_per_cpu":%s,' \
            "$GATE" "$MIN_RAM" "$MAX_LOAD"
        printf '"mem_available_gb":%s,"load1":%s,"nproc":%s,"load_per_cpu":%s}\n' \
            "${MEM_GB:-null}" "${LOAD1:-null}" "${NCPU:-null}" "${LPC:-null}"
    elif [ "$STATUS" = "ok" ]; then
        echo "ok"
    else
        echo "wait:$REASON"
    fi
    [ "$STATUS" = "ok" ] && exit 0 || exit 5
}

if [ "$HEAVY" != 1 ] && [ "$RUNNING" -lt "$GATE" ]; then
    REASON="below gate ($RUNNING < $GATE running)"
    emit
fi

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

reasons=()
if [ -n "$MEM_GB" ] && awk -v a="$MEM_GB" -v m="$MIN_RAM" 'BEGIN { exit !(a < m) }'; then
    reasons+=("low free RAM ${MEM_GB} GB < ${MIN_RAM} GB")
fi
if [ -n "$LPC" ] && awk -v a="$LPC" -v m="$MAX_LOAD" 'BEGIN { exit !(a > m) }'; then
    reasons+=("high load ${LPC} per CPU > ${MAX_LOAD}")
fi

if [ "${#reasons[@]}" -gt 0 ]; then
    STATUS="wait"
    REASON="$(IFS=';'; echo "${reasons[*]}")"
    REASON="${REASON//;/; }"
else
    REASON="resources ok"
fi
emit
