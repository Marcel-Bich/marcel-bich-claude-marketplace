#!/usr/bin/env bash
# local-usage-calculator.sh - Calculate local device usage from stored JSONL data
# Uses reset_id based filtering for correct percentage calculation

# Configuration
USAGE_FILE="${HOME}/.claude/limit-local-usage.json"
STATE_FILE="${HOME}/.claude/limit-local-state.json"
DEVICE_ID="${CLAUDE_MB_LIMIT_DEVICE_LABEL:-$(hostname)}"

# =============================================================================
# Reset ID helpers
# =============================================================================

# Get current 5h reset_id from API reset time
# Input: reset_at time from API (e.g., "2026-01-16T05:00:00Z")
# Output: "5h-2026-01-16T05:00"
get_current_5h_reset_id() {
    local reset_at="${1:-}"
    if [[ -n "${reset_at}" ]] && [[ "${reset_at}" != "null" ]]; then
        echo "5h-${reset_at:0:16}"
    else
        # Fallback: use current hour
        echo "5h-$(date -u +"%Y-%m-%dT%H:00")"
    fi
}

# Get current 7d reset_id from API reset time
get_current_7d_reset_id() {
    local reset_at="${1:-}"
    if [[ -n "${reset_at}" ]] && [[ "${reset_at}" != "null" ]]; then
        echo "7d-${reset_at:0:16}"
    else
        echo "7d-$(date -u +"%Y-%m-%dT%H:00")"
    fi
}

# =============================================================================
# Token summation functions
# =============================================================================

# Sum tokens for current device with matching reset_id
# Args: $1 = reset_id (e.g., "5h-2026-01-16T05:00")
#       $2 = field to match (reset_5h or reset_7d)
sum_my_tokens_since_reset() {
    local reset_id="${1}"
    local field="${2:-reset_5h}"
    local device="${DEVICE_ID}"

    if [[ ! -f "${USAGE_FILE}" ]]; then
        echo "0"
        return
    fi

    local total
    total=$(jq -s --arg device "${device}" --arg reset_id "${reset_id}" --arg field "${field}" '
        [.[] | select(.device == $device and .[$field] == $reset_id)] |
        map(.in + .out) |
        add // 0
    ' "${USAGE_FILE}" 2>/dev/null) || total=0

    [[ "${total}" == "null" ]] && total=0
    echo "${total}"
}

# Sum ALL tokens (all devices) with matching reset_id
sum_all_tokens_since_reset() {
    local reset_id="${1}"
    local field="${2:-reset_5h}"

    if [[ ! -f "${USAGE_FILE}" ]]; then
        echo "0"
        return
    fi

    local total
    total=$(jq -s --arg reset_id "${reset_id}" --arg field "${field}" '
        [.[] | select(.[$field] == $reset_id)] |
        map(.in + .out) |
        add // 0
    ' "${USAGE_FILE}" 2>/dev/null) || total=0

    [[ "${total}" == "null" ]] && total=0
    echo "${total}"
}

# =============================================================================
# Main percentage calculation functions
# =============================================================================

# Calculate local percentage for 5h limit
# Formula: local_pct = (my_tokens / all_tracked_tokens) * global_pct
# Args: $1 = global_pct (e.g., "35" for 35%)
#       $2 = reset_id (e.g., "5h-2026-01-16T05:00")
get_local_5h_percent() {
    local global_pct="${1:-0}"
    local reset_id="${2:-}"

    # Validate inputs
    if [[ -z "${reset_id}" ]]; then
        echo "0"
        return
    fi

    local my_tokens all_tokens
    my_tokens=$(sum_my_tokens_since_reset "${reset_id}" "reset_5h")
    all_tokens=$(sum_all_tokens_since_reset "${reset_id}" "reset_5h")

    # Edge case: no tracked tokens
    if [[ "${all_tokens}" == "0" ]] || [[ -z "${all_tokens}" ]]; then
        echo "0"
        return
    fi

    # Calculate: (my / all) * global_pct
    local result
    result=$(awk "BEGIN {printf \"%.0f\", (${my_tokens} / ${all_tokens}) * ${global_pct}}")
    echo "${result}"
}

# Calculate local percentage for 7d limit
get_local_7d_percent() {
    local global_pct="${1:-0}"
    local reset_id="${2:-}"

    if [[ -z "${reset_id}" ]]; then
        echo "0"
        return
    fi

    local my_tokens all_tokens
    my_tokens=$(sum_my_tokens_since_reset "${reset_id}" "reset_7d")
    all_tokens=$(sum_all_tokens_since_reset "${reset_id}" "reset_7d")

    if [[ "${all_tokens}" == "0" ]] || [[ -z "${all_tokens}" ]]; then
        echo "0"
        return
    fi

    local result
    result=$(awk "BEGIN {printf \"%.0f\", (${my_tokens} / ${all_tokens}) * ${global_pct}}")
    echo "${result}"
}

# =============================================================================
# Convenience wrappers for statusline integration
# =============================================================================

# Get local 5h percent - wrapper that creates reset_id from reset_at
# Args: $1 = global_pct, $2 = reset_at from API
get_local_percent_5h() {
    local global_pct="${1:-0}"
    local reset_at="${2:-}"
    local reset_id
    reset_id=$(get_current_5h_reset_id "${reset_at}")
    get_local_5h_percent "${global_pct}" "${reset_id}"
}

# Get local 7d percent
get_local_percent_7d() {
    local global_pct="${1:-0}"
    local reset_at="${2:-}"
    local reset_id
    reset_id=$(get_current_7d_reset_id "${reset_at}")
    get_local_7d_percent "${global_pct}" "${reset_id}"
}

# =============================================================================
# Standalone execution (for debugging)
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Local Usage Calculator"
    echo "======================"
    echo "Device: ${DEVICE_ID}"
    echo "Usage file: ${USAGE_FILE}"
    echo "State file: ${STATE_FILE}"
    echo ""

    if [[ -f "${STATE_FILE}" ]]; then
        echo "State:"
        cat "${STATE_FILE}"
        echo ""
    fi

    if [[ -f "${USAGE_FILE}" ]]; then
        local_entries=$(wc -l < "${USAGE_FILE}")
        echo "Usage entries: ${local_entries}"
        echo ""

        # Try to get current reset_ids from cache
        CACHE_FILE="/tmp/claude-mb-limit-cache.json"
        if [[ -f "${CACHE_FILE}" ]]; then
            reset_5h=$(jq -r '.five_hour.resets_at // ""' "${CACHE_FILE}" 2>/dev/null)
            reset_7d=$(jq -r '.seven_day.resets_at // ""' "${CACHE_FILE}" 2>/dev/null)
            global_5h=$(jq -r '.five_hour.utilization // 0' "${CACHE_FILE}" 2>/dev/null | cut -d. -f1)
            global_7d=$(jq -r '.seven_day.utilization // 0' "${CACHE_FILE}" 2>/dev/null | cut -d. -f1)

            reset_id_5h=$(get_current_5h_reset_id "${reset_5h}")
            reset_id_7d=$(get_current_7d_reset_id "${reset_7d}")

            echo "Current Reset IDs:"
            echo "  5h: ${reset_id_5h}"
            echo "  7d: ${reset_id_7d}"
            echo ""

            my_5h=$(sum_my_tokens_since_reset "${reset_id_5h}" "reset_5h")
            all_5h=$(sum_all_tokens_since_reset "${reset_id_5h}" "reset_5h")
            my_7d=$(sum_my_tokens_since_reset "${reset_id_7d}" "reset_7d")
            all_7d=$(sum_all_tokens_since_reset "${reset_id_7d}" "reset_7d")

            echo "Tokens since reset:"
            echo "  5h: my=${my_5h}, all=${all_5h}"
            echo "  7d: my=${my_7d}, all=${all_7d}"
            echo ""

            echo "Percentage calculation:"
            echo "  Global 5h: ${global_5h}%"
            echo "  Local 5h:  $(get_local_5h_percent "${global_5h}" "${reset_id_5h}")%"
            echo "  Global 7d: ${global_7d}%"
            echo "  Local 7d:  $(get_local_7d_percent "${global_7d}" "${reset_id_7d}")%"
        else
            echo "No API cache found at ${CACHE_FILE}"
            echo "Run statusline first to populate cache."
        fi
    else
        echo "No usage data found at ${USAGE_FILE}"
        echo "Enable tracking with: export CLAUDE_MB_LIMIT_LOCAL=true"
    fi
fi
