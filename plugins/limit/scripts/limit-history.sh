#!/usr/bin/env bash
# limit-history.sh - History tracking and average calculation for limit plugin
# Stores JSONL entries with usage data for computing averages
# shellcheck disable=SC2250

set -euo pipefail

# =============================================================================
# Multi-Account Support: CLAUDE_CONFIG_DIR determines the profile
# =============================================================================
CLAUDE_BASE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
PROFILE_NAME=$(basename "${CLAUDE_BASE_DIR}")

# History file location - profile-specific
HISTORY_FILE="${PLUGIN_DATA_DIR:-${CLAUDE_BASE_DIR}/marcel-bich-claude-marketplace/limit}/limit-history_${PROFILE_NAME}.jsonl"

# Configuration with defaults
HISTORY_ENABLED="${CLAUDE_MB_LIMIT_HISTORY_ENABLED:-true}"
HISTORY_INTERVAL="${CLAUDE_MB_LIMIT_HISTORY_INTERVAL:-600}"  # 10 minutes in seconds
HISTORY_DAYS="${CLAUDE_MB_LIMIT_HISTORY_DAYS:-28}"           # 28 days retention

# Last write timestamp file (to check interval) - profile-specific
HISTORY_LAST_WRITE="${PLUGIN_DATA_DIR:-${CLAUDE_BASE_DIR}/marcel-bich-claude-marketplace/limit}/history-last-write_${PROFILE_NAME}"

# =============================================================================
# History write control
# =============================================================================

# Check if enough time has elapsed since last history write
# Returns: 0 if should write, 1 if too soon
should_write_history() {
    if [[ "$HISTORY_ENABLED" != "true" ]]; then
        return 1
    fi

    if [[ ! -f "$HISTORY_LAST_WRITE" ]]; then
        return 0
    fi

    local last_write now diff
    last_write=$(cat "$HISTORY_LAST_WRITE" 2>/dev/null) || last_write=0
    now=$(date +%s)
    diff=$((now - last_write))

    if [[ $diff -ge $HISTORY_INTERVAL ]]; then
        return 0
    fi

    return 1
}

# Update last write timestamp
update_last_write() {
    date +%s > "$HISTORY_LAST_WRITE" 2>/dev/null || true
}

# =============================================================================
# History cleanup
# =============================================================================

# Remove entries older than HISTORY_DAYS
# Called automatically during append_history
cleanup_history() {
    if [[ ! -f "$HISTORY_FILE" ]]; then
        return 0
    fi

    local cutoff_seconds retention_seconds
    retention_seconds=$((HISTORY_DAYS * 86400))
    cutoff_seconds=$(($(date +%s) - retention_seconds))

    # Use jq to filter entries, keeping only those newer than cutoff
    local tmp_file
    tmp_file=$(mktemp)

    jq -c --argjson cutoff "$cutoff_seconds" '
        select((.ts | fromdateiso8601) > $cutoff)
    ' "$HISTORY_FILE" > "$tmp_file" 2>/dev/null || {
        rm -f "$tmp_file"
        return 0
    }

    if [[ -s "$tmp_file" ]]; then
        mv "$tmp_file" "$HISTORY_FILE"
    else
        rm -f "$tmp_file"
        # File would be empty, remove it
        rm -f "$HISTORY_FILE"
    fi
}

# =============================================================================
# History append
# =============================================================================

# Append a history entry with current usage data
# Usage: append_history <5h_api_pct> <5h_local_tokens> <5h_highscore> \
#                       <7d_api_pct> <7d_local_tokens> <7d_highscore> \
#                       <opus_pct> <sonnet_pct> <plan> <device>
append_history() {
    if [[ "$HISTORY_ENABLED" != "true" ]]; then
        return 0
    fi

    if ! should_write_history; then
        return 0
    fi

    local api_5h="${1:-0}"
    local local_5h="${2:-0}"
    local hs_5h="${3:-0}"
    local api_7d="${4:-0}"
    local local_7d="${5:-0}"
    local hs_7d="${6:-0}"
    local opus="${7:-0}"
    local sonnet="${8:-0}"
    local plan="${9:-unknown}"
    local device="${10:-$(hostname)}"

    # Ensure directory exists
    local dir
    dir=$(dirname "$HISTORY_FILE")
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" 2>/dev/null || return 0
    fi

    # Build JSON entry
    local ts entry
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    entry=$(jq -n \
        --arg ts "$ts" \
        --argjson api5h "$api_5h" \
        --argjson local5h "$local_5h" \
        --argjson hs5h "$hs_5h" \
        --argjson api7d "$api_7d" \
        --argjson local7d "$local_7d" \
        --argjson hs7d "$hs_7d" \
        --argjson opus "$opus" \
        --argjson sonnet "$sonnet" \
        --arg plan "$plan" \
        --arg device "$device" \
        '{
            ts: $ts,
            "5h": {api: $api5h, local: $local5h, hs: $hs5h},
            "7d": {api: $api7d, local: $local7d, hs: $hs7d},
            opus: $opus,
            sonnet: $sonnet,
            plan: $plan,
            device: $device
        }' 2>/dev/null)

    if [[ -n "$entry" ]]; then
        echo "$entry" >> "$HISTORY_FILE"
        update_last_write
        # Cleanup old entries periodically (every write)
        cleanup_history
    fi
}

# =============================================================================
# Average calculation
# =============================================================================

# Get average value from history for a specific field
# Usage: get_average <jq_field> [hours]
# Examples:
#   get_average '."5h".api' 24      -> Average 5h API % over last 24h
#   get_average '."7d".local' 168   -> Average 7d local tokens over last 7 days
#   get_average '.opus' 24          -> Average Opus % over last 24h
get_average() {
    local field="$1"
    local hours="${2:-24}"

    if [[ ! -f "$HISTORY_FILE" ]]; then
        echo ""
        return
    fi

    local cutoff_seconds
    cutoff_seconds=$(($(date +%s) - hours * 3600))

    local result
    result=$(jq -rs --argjson cutoff "$cutoff_seconds" --arg field "$field" '
        [.[] | select((.ts | fromdateiso8601) > $cutoff) | '"$field"'] |
        if length > 0 then (add / length | . * 10 | floor / 10) else null end
    ' "$HISTORY_FILE" 2>/dev/null)

    if [[ "$result" == "null" ]] || [[ -z "$result" ]]; then
        echo ""
    else
        # Ensure one decimal place (e.g., 22 -> 22.0, 22.5 -> 22.5)
        LC_NUMERIC=C printf "%.1f" "$result"
    fi
}

# Get average for local device only (filters by hostname)
# Usage: get_local_average <jq_field> [hours]
get_local_average() {
    local field="$1"
    local hours="${2:-24}"
    local device="${3:-$(hostname)}"

    if [[ ! -f "$HISTORY_FILE" ]]; then
        echo ""
        return
    fi

    local cutoff_seconds
    cutoff_seconds=$(($(date +%s) - hours * 3600))

    local result
    result=$(jq -rs --argjson cutoff "$cutoff_seconds" --arg device "$device" '
        [.[] | select((.ts | fromdateiso8601) > $cutoff) | select(.device == $device) | '"$field"'] |
        if length > 0 then (add / length | . * 10 | floor / 10) else null end
    ' "$HISTORY_FILE" 2>/dev/null)

    if [[ "$result" == "null" ]] || [[ -z "$result" ]]; then
        echo ""
    else
        # Ensure one decimal place (e.g., 22 -> 22.0, 22.5 -> 22.5)
        LC_NUMERIC=C printf "%.1f" "$result"
    fi
}

# Get history entry count (for diagnostics)
# Usage: get_history_count [hours]
get_history_count() {
    local hours="${1:-}"

    if [[ ! -f "$HISTORY_FILE" ]]; then
        echo "0"
        return
    fi

    if [[ -z "$hours" ]]; then
        # Total count
        wc -l < "$HISTORY_FILE" | tr -d ' '
    else
        local cutoff_seconds
        cutoff_seconds=$(($(date +%s) - hours * 3600))

        jq -rs --argjson cutoff "$cutoff_seconds" '
            [.[] | select((.ts | fromdateiso8601) > $cutoff)] | length
        ' "$HISTORY_FILE" 2>/dev/null || echo "0"
    fi
}

# =============================================================================
# CLI interface for testing
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        should-write)
            if should_write_history; then
                echo "yes"
            else
                echo "no"
            fi
            ;;
        append)
            # append <5h_api> <5h_local> <5h_hs> <7d_api> <7d_local> <7d_hs> <opus> <sonnet> <plan> <device>
            append_history "${2:-0}" "${3:-0}" "${4:-0}" "${5:-0}" "${6:-0}" "${7:-0}" "${8:-0}" "${9:-0}" "${10:-unknown}" "${11:-$(hostname)}"
            echo "Entry appended (if interval passed)"
            ;;
        cleanup)
            cleanup_history
            echo "Cleanup complete"
            ;;
        get-average)
            # get-average <field> [hours]
            get_average "${2:-.\"5h\".api}" "${3:-24}"
            ;;
        get-local-average)
            # get-local-average <field> [hours] [device]
            get_local_average "${2:-.\"5h\".api}" "${3:-24}" "${4:-$(hostname)}"
            ;;
        count)
            # count [hours]
            get_history_count "${2:-}"
            ;;
        show)
            if [[ -f "$HISTORY_FILE" ]]; then
                jq -s '.' "$HISTORY_FILE" 2>/dev/null || cat "$HISTORY_FILE"
            else
                echo "No history file"
            fi
            ;;
        *)
            echo "Usage: $0 <command> [args]"
            echo ""
            echo "Commands:"
            echo "  should-write                  Check if history write is due"
            echo "  append <5h_api> <5h_local> <5h_hs> <7d_api> <7d_local> <7d_hs> <opus> <sonnet> <plan> <device>"
            echo "  cleanup                       Remove entries older than ${HISTORY_DAYS} days"
            echo "  get-average <field> [hours]   Get average for field over hours"
            echo "  get-local-average <field> [hours] [device]"
            echo "  count [hours]                 Get entry count (total or in hours)"
            echo "  show                          Show all history entries"
            ;;
    esac
fi
