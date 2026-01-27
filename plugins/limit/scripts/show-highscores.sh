#!/usr/bin/env bash
# show-highscores.sh - Display formatted highscore status
# Called by /limit:highscore command

set -euo pipefail

# Force C locale for numeric operations (prevents issues with de_DE locale expecting comma)
export LC_NUMERIC=C

# Multi-Account Support: CLAUDE_CONFIG_DIR determines the profile
CLAUDE_BASE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
PROFILE_NAME=$(basename "${CLAUDE_BASE_DIR}")

# Paths - profile-specific
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DATA_DIR="${PLUGIN_DATA_DIR:-${CLAUDE_BASE_DIR}/marcel-bich-claude-marketplace/limit}"
HIGHSCORE_STATE="${PLUGIN_DATA_DIR}/limit-highscore-state_${PROFILE_NAME}.json"
MAIN_AGENT_STATE="${PLUGIN_DATA_DIR}/limit-main-agent-state_${PROFILE_NAME}.json"
SUBAGENT_STATE="${PLUGIN_DATA_DIR}/limit-subagent-state_${PROFILE_NAME}.json"
API_CACHE="/tmp/claude-mb-limit-cache_${PROFILE_NAME}.json"
HISTORY_FILE="${PLUGIN_DATA_DIR}/limit-history_${PROFILE_NAME}.jsonl"

# Source history functions
# shellcheck source=limit-history.sh
source "${SCRIPT_DIR}/limit-history.sh"

# Format number as human-readable (1.5M, 500.0k, 2.0G, 1.5T)
# Uses G (Giga) instead of B (Billion) for consistency with statusline
format_number() {
    local num="${1:-0}"
    [[ "$num" == "null" || -z "$num" ]] && { echo "n/a"; return; }

    # Remove decimals for comparison
    local int_num="${num%.*}"
    [[ -z "$int_num" ]] && int_num=0

    if (( int_num >= 1000000000000000000000000 )); then
        printf "%.1fY" "$(echo "scale=1; $num / 1000000000000000000000000" | bc)"
    elif (( int_num >= 1000000000000000000000 )); then
        printf "%.1fZ" "$(echo "scale=1; $num / 1000000000000000000000" | bc)"
    elif (( int_num >= 1000000000000000000 )); then
        printf "%.1fE" "$(echo "scale=1; $num / 1000000000000000000" | bc)"
    elif (( int_num >= 1000000000000000 )); then
        printf "%.1fP" "$(echo "scale=1; $num / 1000000000000000" | bc)"
    elif (( int_num >= 1000000000000 )); then
        printf "%.1fT" "$(echo "scale=1; $num / 1000000000000" | bc)"
    elif (( int_num >= 1000000000 )); then
        printf "%.1fG" "$(echo "scale=1; $num / 1000000000" | bc)"
    elif (( int_num >= 1000000 )); then
        printf "%.1fM" "$(echo "scale=1; $num / 1000000" | bc)"
    elif (( int_num >= 1000 )); then
        printf "%.1fk" "$(echo "scale=1; $num / 1000" | bc)"
    else
        echo "$int_num"
    fi
}

# Format price with 2 decimals
format_price() {
    local price="${1:-0}"
    [[ "$price" == "null" || -z "$price" ]] && { echo "n/a"; return; }
    printf "%.2f" "$price"
}

# Format reset time as absolute datetime
format_reset_datetime() {
    local reset_at="${1:-}"
    [[ -z "$reset_at" || "$reset_at" == "null" ]] && { echo "n/a"; return; }

    if date --version >/dev/null 2>&1; then
        # GNU date
        date -d "$reset_at" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "n/a"
    else
        # BSD date
        date -j -f "%Y-%m-%dT%H:%M:%S" "${reset_at%%.*}" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "n/a"
    fi
}

# Calculate time until reset (relative)
format_time_until() {
    local reset_at="${1:-}"
    [[ -z "$reset_at" || "$reset_at" == "null" ]] && { echo "n/a"; return; }

    local now reset_epoch diff
    now=$(date +%s)

    # Parse ISO timestamp
    if date --version >/dev/null 2>&1; then
        # GNU date
        reset_epoch=$(date -d "$reset_at" +%s 2>/dev/null) || { echo "n/a"; return; }
    else
        # BSD date
        reset_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${reset_at%%.*}" +%s 2>/dev/null) || { echo "n/a"; return; }
    fi

    diff=$((reset_epoch - now))
    [[ $diff -lt 0 ]] && diff=0

    local days hours minutes
    days=$((diff / 86400))
    hours=$(( (diff % 86400) / 3600 ))
    minutes=$(( (diff % 3600) / 60 ))

    if (( days > 0 )); then
        echo "${days}d ${hours}h"
    elif (( hours > 0 )); then
        echo "${hours}h ${minutes}m"
    else
        echo "${minutes}m"
    fi
}

# Safe JSON read with default
json_get() {
    local file="$1"
    local path="$2"
    local default="${3:-0}"

    if [[ -f "$file" ]]; then
        local val
        val=$(jq -r "$path // \"$default\"" "$file" 2>/dev/null) || val="$default"
        [[ "$val" == "null" ]] && val="$default"
        echo "$val"
    else
        echo "$default"
    fi
}

# Calculate model total from state
calc_model_total() {
    local file="$1"
    local model="$2"

    if [[ ! -f "$file" ]]; then
        echo "0"
        return
    fi

    jq -r "(.${model}.input_tokens // 0) + (.${model}.output_tokens // 0) + (.${model}.cache_read_tokens // 0) + (.${model}.cache_creation_tokens // 0)" "$file" 2>/dev/null || echo "0"
}

# Detect current plan
detect_plan() {
    # First try highscore state
    if [[ -f "$HIGHSCORE_STATE" ]]; then
        local plan
        plan=$(jq -r '.plan // ""' "$HIGHSCORE_STATE" 2>/dev/null)
        if [[ -n "$plan" && "$plan" != "null" && "$plan" != "unknown" ]]; then
            echo "$plan"
            return
        fi
    fi

    # Try plan-detect.sh if available
    if [[ -x "${SCRIPT_DIR}/plan-detect.sh" ]]; then
        local detected
        detected=$("${SCRIPT_DIR}/plan-detect.sh" 2>/dev/null) || detected=""
        if [[ -n "$detected" && "$detected" != "unknown" ]]; then
            echo "$detected"
            return
        fi
    fi

    echo "unknown"
}

# Main output
main() {
    local hostname_val
    hostname_val=$(hostname 2>/dev/null || echo "unknown")

    local current_plan
    current_plan=$(detect_plan)

    echo "## Highscore Status"
    echo ""
    echo "**Plan:** $current_plan | **Device:** $hostname_val"
    echo ""
    echo "---"
    echo ""

    # Combined Total
    echo "### Combined Total (Main + Subagents)"
    echo ""

    local main_tokens main_price sub_tokens sub_price
    main_tokens=$(json_get "$MAIN_AGENT_STATE" ".total_tokens" "0")
    main_price=$(json_get "$MAIN_AGENT_STATE" ".total_price" "0")
    sub_tokens=$(json_get "$SUBAGENT_STATE" ".total_tokens" "0")
    sub_price=$(json_get "$SUBAGENT_STATE" ".total_price" "0")

    local combined_tokens combined_price
    combined_tokens=$((main_tokens + sub_tokens))
    combined_price=$(echo "$main_price + $sub_price" | bc)

    echo "**$(format_number "$combined_tokens") Tokens** | \$$(format_price "$combined_price")"
    echo ""
    echo "---"
    echo ""

    # Current Window
    echo "### Current Window (Main + Subagents)"
    echo ""

    local window_5h window_7d sub_window_5h sub_window_7d
    window_5h=$(json_get "$HIGHSCORE_STATE" ".window_tokens_5h" "0")
    window_7d=$(json_get "$HIGHSCORE_STATE" ".window_tokens_7d" "0")
    sub_window_5h=$(json_get "$HIGHSCORE_STATE" ".subagent_window_5h" "0")
    sub_window_7d=$(json_get "$HIGHSCORE_STATE" ".subagent_window_7d" "0")

    local total_5h total_7d
    total_5h=$((window_5h + sub_window_5h))
    total_7d=$((window_7d + sub_window_7d))

    if [[ -f "$HIGHSCORE_STATE" ]]; then
        echo "- **5h:** $(format_number "$total_5h") Tokens"
        echo "- **7d:** $(format_number "$total_7d") Tokens"
    else
        echo "- **5h:** n/a"
        echo "- **7d:** n/a"
    fi
    echo ""
    echo "---"
    echo ""

    # Current Usage (from API)
    echo "### Current Usage (from API)"
    echo ""

    if [[ -f "$API_CACHE" ]]; then
        local five_util five_reset seven_util seven_reset
        five_util=$(json_get "$API_CACHE" ".five_hour.utilization" "n/a")
        five_reset=$(json_get "$API_CACHE" ".five_hour.resets_at" "")
        seven_util=$(json_get "$API_CACHE" ".seven_day.utilization" "n/a")
        seven_reset=$(json_get "$API_CACHE" ".seven_day.resets_at" "")

        echo "- **5h:** ${five_util}% (resets in $(format_time_until "$five_reset") - $(format_reset_datetime "$five_reset"))"
        echo "- **7d:** ${seven_util}% (resets in $(format_time_until "$seven_reset") - $(format_reset_datetime "$seven_reset"))"
    else
        echo "> API cache not available. Run a Claude session to populate usage data."
    fi
    echo ""
    echo "---"
    echo ""

    # Highscores
    echo "### Local Highscores"
    echo ""

    if [[ -f "$HIGHSCORE_STATE" ]]; then
        local hs_5h hs_7d
        hs_5h=$(json_get "$HIGHSCORE_STATE" ".highscores[\"$current_plan\"][\"5h\"]" "0")
        hs_7d=$(json_get "$HIGHSCORE_STATE" ".highscores[\"$current_plan\"][\"7d\"]" "0")

        echo "**Highscores ($current_plan)**"
        echo "- 5h: $(format_number "$hs_5h")"
        echo "- 7d: $(format_number "$hs_7d")"
        echo ""

        echo "**Other Plans:**"
        for other_plan in max20 max5 pro unknown; do
            if [[ "$other_plan" != "$current_plan" ]]; then
                local other_5h other_7d
                other_5h=$(json_get "$HIGHSCORE_STATE" ".highscores[\"$other_plan\"][\"5h\"]" "0")
                other_7d=$(json_get "$HIGHSCORE_STATE" ".highscores[\"$other_plan\"][\"7d\"]" "0")
                echo "- $other_plan: 5h=$(format_number "$other_5h"), 7d=$(format_number "$other_7d")"
            fi
        done
    else
        echo "> No local highscore data yet."
        echo "> Local tracking is enabled by default (v1.9.0+)."
        echo "> All data stays on your device - nothing is sent anywhere."
    fi
    echo ""
    echo "---"
    echo ""

    # Lifetime Breakdown
    echo "### Lifetime Breakdown"
    echo ""

    echo "**Main Agent:**"
    if [[ -f "$MAIN_AGENT_STATE" ]]; then
        echo "- Tokens: $(format_number "$main_tokens")"
        echo "- Cost: \$$(format_price "$main_price")"
        echo "- Haiku: $(format_number "$(calc_model_total "$MAIN_AGENT_STATE" "haiku")")"
        echo "- Sonnet: $(format_number "$(calc_model_total "$MAIN_AGENT_STATE" "sonnet")")"
        echo "- Opus: $(format_number "$(calc_model_total "$MAIN_AGENT_STATE" "opus")")"
    else
        echo "- n/a"
    fi
    echo ""

    echo "**Subagents:**"
    if [[ -f "$SUBAGENT_STATE" ]] && (( sub_tokens > 0 )); then
        echo "- Tokens: $(format_number "$sub_tokens")"
        echo "- Cost: \$$(format_price "$sub_price")"
        echo "- Haiku: $(format_number "$(calc_model_total "$SUBAGENT_STATE" "haiku")")"
        echo "- Sonnet: $(format_number "$(calc_model_total "$SUBAGENT_STATE" "sonnet")")"
        echo "- Opus: $(format_number "$(calc_model_total "$SUBAGENT_STATE" "opus")")"
    else
        echo "- No subagent usage recorded yet"
    fi
    echo ""
    echo "---"
    echo ""

    # History & Averages
    echo "### History & Averages"
    echo ""

    if [[ -f "$HISTORY_FILE" ]]; then
        local total_entries entries_24h entries_7d
        total_entries=$(get_history_count)
        entries_24h=$(get_history_count 24)
        entries_7d=$(get_history_count 168)

        echo "**History Data:**"
        echo "- Total entries: $total_entries"
        echo "- Last 24h: $entries_24h entries"
        echo "- Last 7d: $entries_7d entries"
        echo ""

        # Get averages
        local avg_5h_local avg_5h_api avg_7d_local avg_7d_api
        local device_label
        device_label=$(hostname 2>/dev/null || echo "unknown")

        avg_5h_local=$(get_local_average '."5h".api' 24 "$device_label")
        avg_5h_api=$(get_average '."5h".api' 24)
        avg_7d_local=$(get_local_average '."7d".api' 168 "$device_label")
        avg_7d_api=$(get_average '."7d".api' 168)

        echo "**Averages (24h/7d):**"
        echo "- 5h window: Local ${avg_5h_local:-n/a}% / API ${avg_5h_api:-n/a}%"
        echo "- 7d window: Local ${avg_7d_local:-n/a}% / API ${avg_7d_api:-n/a}%"
        echo ""

        # Model averages
        local avg_opus avg_sonnet
        avg_opus=$(get_average '.opus' 168)
        avg_sonnet=$(get_average '.sonnet' 168)

        if [[ -n "$avg_opus" ]] || [[ -n "$avg_sonnet" ]]; then
            echo "**Model Averages (7d):**"
            [[ -n "$avg_opus" ]] && echo "- Opus: ${avg_opus}%"
            [[ -n "$avg_sonnet" ]] && echo "- Sonnet: ${avg_sonnet}%"
            echo ""
        fi
    else
        echo "> No history data yet. History is recorded every 10 minutes"
        echo "> during active usage and retained for 28 days."
        echo ""
    fi

    echo "---"
    echo ""

    # Achievement explanation
    echo "### Achievement Symbol"
    echo ""
    echo "The achievement symbol (trophy or [!]) appears when the global API"
    echo "usage is >= 95% AND your local device usage is >= 95% of its own"
    echo "highscore. This means the real limit is nearly exhausted and you"
    echo "have almost maxed out your device's recorded capacity."
    echo ""
    echo "---"
    echo ""

    # Explanation
    echo "> **How does Local Highscore Tracking work?**"
    echo ">"
    echo "> Highscores can only increase, never decrease. The more you work,"
    echo "> the higher your record gets."
    echo ">"
    echo "> Highscores are stored per plan so that a plan change"
    echo "> (e.g., from Max20 to Pro) doesn't mix up the records."
    echo ">"
    echo "> All data is stored locally in ~/.claude/ - nothing leaves your device."
}

main "$@"
