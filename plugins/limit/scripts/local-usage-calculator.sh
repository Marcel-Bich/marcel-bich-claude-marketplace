#!/usr/bin/env bash
# local-usage-calculator.sh - Calculate local device usage from stored JSONL data
# Provides functions to get 5h/7d token sums and percentage of global limit

# Configuration
USAGE_FILE="${HOME}/.claude/limit-local-usage.json"
DEVICE_ID="${CLAUDE_MB_LIMIT_DEVICE_LABEL:-$(hostname)}"

# Get timestamp N hours ago in ISO8601 format
get_timestamp_hours_ago() {
    local hours="${1:-5}"
    if date --version >/dev/null 2>&1; then
        # GNU date (Linux/WSL)
        date -u -d "${hours} hours ago" +"%Y-%m-%dT%H:%M:%SZ"
    else
        # BSD date (macOS)
        date -u -v-"${hours}"H +"%Y-%m-%dT%H:%M:%SZ"
    fi
}

# Get timestamp N days ago in ISO8601 format
get_timestamp_days_ago() {
    local days="${1:-7}"
    if date --version >/dev/null 2>&1; then
        # GNU date (Linux/WSL)
        date -u -d "${days} days ago" +"%Y-%m-%dT%H:%M:%SZ"
    else
        # BSD date (macOS)
        date -u -v-"${days}"d +"%Y-%m-%dT%H:%M:%SZ"
    fi
}

# Sum tokens for current device within time range
# Args: $1 = cutoff timestamp (ISO8601)
# Returns: total tokens (input + output)
sum_tokens_since() {
    local cutoff="${1}"
    local device="${DEVICE_ID}"

    if [[ ! -f "${USAGE_FILE}" ]]; then
        echo "0"
        return
    fi

    # Filter by device and timestamp, sum tokens
    # jq processes JSONL (one object per line) with -s (slurp) flag
    local total
    total=$(jq -s --arg device "${device}" --arg cutoff "${cutoff}" '
        [.[] | select(.device == $device and .timestamp >= $cutoff)] |
        map(.input_tokens + .output_tokens) |
        add // 0
    ' "${USAGE_FILE}" 2>/dev/null) || total=0

    echo "${total}"
}

# Sum ALL tokens (all devices) within time range
# Used for calculating percentage
sum_all_tokens_since() {
    local cutoff="${1}"

    if [[ ! -f "${USAGE_FILE}" ]]; then
        echo "0"
        return
    fi

    local total
    total=$(jq -s --arg cutoff "${cutoff}" '
        [.[] | select(.timestamp >= $cutoff)] |
        map(.input_tokens + .output_tokens) |
        add // 0
    ' "${USAGE_FILE}" 2>/dev/null) || total=0

    echo "${total}"
}

# Get local 5-hour token sum for current device
get_local_usage_5h() {
    local cutoff
    cutoff=$(get_timestamp_hours_ago 5)
    sum_tokens_since "${cutoff}"
}

# Get local 7-day token sum for current device
get_local_usage_7d() {
    local cutoff
    cutoff=$(get_timestamp_days_ago 7)
    sum_tokens_since "${cutoff}"
}

# Calculate local percentage of global limit
# Args: $1 = global_percent (e.g., "14" for 14%)
# Returns: local percentage (e.g., "8" for 8% of the limit used by this device)
#
# Formula: local_pct = (local_tokens / all_tracked_tokens) * global_pct
# If all_tracked_tokens is 0, returns 0
get_local_5h_percent() {
    local global_pct="${1:-0}"
    local cutoff
    cutoff=$(get_timestamp_hours_ago 5)

    local local_tokens all_tokens
    local_tokens=$(sum_tokens_since "${cutoff}")
    all_tokens=$(sum_all_tokens_since "${cutoff}")

    if [[ "${all_tokens}" == "0" ]] || [[ -z "${all_tokens}" ]]; then
        echo "0"
        return
    fi

    # Calculate: (local / all) * global_pct
    local result
    result=$(awk "BEGIN {printf \"%.0f\", (${local_tokens} / ${all_tokens}) * ${global_pct}}")
    echo "${result}"
}

# Calculate local 7-day percentage
get_local_7d_percent() {
    local global_pct="${1:-0}"
    local cutoff
    cutoff=$(get_timestamp_days_ago 7)

    local local_tokens all_tokens
    local_tokens=$(sum_tokens_since "${cutoff}")
    all_tokens=$(sum_all_tokens_since "${cutoff}")

    if [[ "${all_tokens}" == "0" ]] || [[ -z "${all_tokens}" ]]; then
        echo "0"
        return
    fi

    local result
    result=$(awk "BEGIN {printf \"%.0f\", (${local_tokens} / ${all_tokens}) * ${global_pct}}")
    echo "${result}"
}

# If run directly (not sourced), show usage info
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Local Usage Calculator"
    echo "======================"
    echo "Device: ${DEVICE_ID}"
    echo "Usage file: ${USAGE_FILE}"
    echo ""
    if [[ -f "${USAGE_FILE}" ]]; then
        echo "5h tokens: $(get_local_usage_5h)"
        echo "7d tokens: $(get_local_usage_7d)"
        echo ""
        echo "Example percentage calculation:"
        echo "  If global 5h is 14%: local 5h = $(get_local_5h_percent 14)%"
        echo "  If global 7d is 8%:  local 7d = $(get_local_7d_percent 8)%"
    else
        echo "No usage data found at ${USAGE_FILE}"
        echo "Enable tracking with: export CLAUDE_MB_LIMIT_LOCAL=true"
    fi
fi
