#!/bin/bash
# usage-statusline.sh - Display live API usage in Claude Code statusline
# Shows utilization with progress bars, colors, and reset times from Anthropic API

set -euo pipefail

# Configuration
CREDENTIALS_FILE="${HOME}/.claude/.credentials.json"
API_URL="https://api.anthropic.com/api/oauth/usage"
TIMEOUT=5

# Cache configuration (rate limiting)
CACHE_FILE="/tmp/claude-limit-cache.json"
CACHE_MAX_AGE="${CLAUDE_MB_LIMIT_CACHE_AGE:-120}"  # 2 minutes default

# Debug mode - shows raw API response
DEBUG="${CLAUDE_MB_LIMIT_DEBUG:-false}"

# Feature toggles (all default to true)
SHOW_5H="${CLAUDE_MB_LIMIT_5H:-true}"
SHOW_7D="${CLAUDE_MB_LIMIT_7D:-true}"
SHOW_OPUS="${CLAUDE_MB_LIMIT_OPUS:-true}"
SHOW_SONNET="${CLAUDE_MB_LIMIT_SONNET:-true}"
SHOW_EXTRA="${CLAUDE_MB_LIMIT_EXTRA:-true}"
SHOW_COLORS="${CLAUDE_MB_LIMIT_COLORS:-true}"
SHOW_PROGRESS="${CLAUDE_MB_LIMIT_PROGRESS:-true}"
SHOW_RESET="${CLAUDE_MB_LIMIT_RESET:-true}"

# ANSI color codes
COLOR_RESET='\033[0m'
COLOR_GRAY='\033[90m'
COLOR_GREEN='\033[32m'
COLOR_YELLOW='\033[33m'
COLOR_ORANGE='\033[38;5;208m'
COLOR_RED='\033[31m'

# Progress bar characters
BAR_FILLED='='
BAR_EMPTY='-'
BAR_WIDTH=10

# Silent error exit for statusline
error_exit() {
    if [[ "${CLAUDE_MB_LIMIT_SHOW_ERRORS:-false}" == "true" ]]; then
        echo "limit: error"
    fi
    exit 0
}

# Check dependencies
check_dependencies() {
    command -v jq >/dev/null 2>&1 || error_exit
    command -v curl >/dev/null 2>&1 || error_exit
}

# Read OAuth token from credentials file
get_token() {
    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        error_exit
    fi

    local token
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null)

    if [[ -z "$token" ]]; then
        error_exit
    fi

    echo "$token"
}

# Check if cache is valid (not expired)
is_cache_valid() {
    if [[ ! -f "$CACHE_FILE" ]]; then
        return 1
    fi

    local cache_time
    cache_time=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null) || return 1
    local current_time
    current_time=$(date +%s)
    local age=$((current_time - cache_time))

    if [[ "$age" -lt "$CACHE_MAX_AGE" ]]; then
        return 0
    fi
    return 1
}

# Read cached response
read_cache() {
    cat "$CACHE_FILE" 2>/dev/null
}

# Write response to cache
write_cache() {
    local response="$1"
    echo "$response" > "$CACHE_FILE" 2>/dev/null || true
}

# Fetch usage data from API (with caching)
fetch_usage() {
    local token="$1"

    # Check cache first
    if is_cache_valid; then
        local cached
        cached=$(read_cache)
        if [[ -n "$cached" ]]; then
            if [[ "$DEBUG" == "true" ]]; then
                echo "DEBUG: Using cached response (age < ${CACHE_MAX_AGE}s)" >&2
            fi
            echo "$cached"
            return
        fi
    fi

    # Fetch fresh data from API
    local response
    response=$(curl -s -f --max-time "$TIMEOUT" \
        -X GET "$API_URL" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code-limit-plugin/1.0.0" \
        2>/dev/null) || error_exit

    # Cache the response
    write_cache "$response"

    if [[ "$DEBUG" == "true" ]]; then
        echo "DEBUG: Fresh API response fetched" >&2
    fi

    echo "$response"
}

# Get color based on utilization percentage
# <30% gray, <50% green, <75% yellow, <90% orange, >=90% red
get_color() {
    local pct="$1"

    # Return empty if colors disabled
    if [[ "$SHOW_COLORS" != "true" ]]; then
        echo ""
        return
    fi

    if [[ -z "$pct" ]] || [[ "$pct" == "-" ]]; then
        echo "$COLOR_GRAY"
        return
    fi

    if [[ "$pct" -lt 30 ]]; then
        echo "$COLOR_GRAY"
    elif [[ "$pct" -lt 50 ]]; then
        echo "$COLOR_GREEN"
    elif [[ "$pct" -lt 75 ]]; then
        echo "$COLOR_YELLOW"
    elif [[ "$pct" -lt 90 ]]; then
        echo "$COLOR_ORANGE"
    else
        echo "$COLOR_RED"
    fi
}

# Generate ASCII progress bar
# Usage: progress_bar <percentage> <width>
progress_bar() {
    local pct="$1"
    local width="${2:-$BAR_WIDTH}"

    if [[ -z "$pct" ]] || [[ "$pct" == "-" ]]; then
        pct=0
    fi

    # Clamp percentage to 0-100
    if [[ "$pct" -lt 0 ]]; then
        pct=0
    elif [[ "$pct" -gt 100 ]]; then
        pct=100
    fi

    local filled=$((pct * width / 100))
    local empty=$((width - filled))

    local bar=""
    for ((i=0; i<filled; i++)); do
        bar+="$BAR_FILLED"
    done
    for ((i=0; i<empty; i++)); do
        bar+="$BAR_EMPTY"
    done

    echo "[$bar]"
}

# Format reset time as "yyyy-mm-dd hh:mm"
format_reset_datetime() {
    local reset_at="$1"

    if [[ -z "$reset_at" ]] || [[ "$reset_at" == "null" ]]; then
        echo "-"
        return
    fi

    local formatted
    if date --version >/dev/null 2>&1; then
        # GNU date (Linux/WSL)
        formatted=$(date -d "$reset_at" "+%Y-%m-%d %H:%M" 2>/dev/null) || formatted="-"
    else
        # BSD date (macOS)
        formatted=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${reset_at%%.*}" "+%Y-%m-%d %H:%M" 2>/dev/null) || formatted="-"
    fi

    echo "$formatted"
}

# Format a single limit line with color, progress bar, percentage, and reset time
# Usage: format_limit_line <label> <percentage> <reset_at>
format_limit_line() {
    local label="$1"
    local pct="$2"
    local reset_at="$3"

    local color=""
    local color_reset=""
    if [[ "$SHOW_COLORS" == "true" ]]; then
        color=$(get_color "$pct")
        color_reset="$COLOR_RESET"
    fi

    local bar=""
    if [[ "$SHOW_PROGRESS" == "true" ]]; then
        bar=" $(progress_bar "$pct")"
    fi

    local reset_str=""
    if [[ "$SHOW_RESET" == "true" ]]; then
        reset_str=" reset: $(format_reset_datetime "$reset_at")"
    fi

    # Output varies based on toggles, e.g.: "Label [====------] 14% reset 2026-01-08 22:00"
    printf "${color}%s%s %3s%%${reset_str}${color_reset}" "$label" "$bar" "$pct"
}

# Parse integer from value (handles int, float, null, empty)
parse_int() {
    local val="$1"

    if [[ -z "$val" ]] || [[ "$val" == "null" ]]; then
        echo ""
        return
    fi

    # Try printf for floats, fallback to raw value
    local result
    result=$(printf "%.0f" "$val" 2>/dev/null || echo "$val")
    result="${result%%.*}"

    echo "$result"
}

# Main output formatting
format_output() {
    local response="$1"
    local output=""

    # Extract all values using jq
    local five_hour_util five_hour_reset
    local seven_day_util seven_day_reset
    local opus_util opus_reset
    local sonnet_util sonnet_reset
    local extra_enabled extra_limit extra_used

    five_hour_util=$(echo "$response" | jq -r '.five_hour.utilization // empty' 2>/dev/null)
    five_hour_reset=$(echo "$response" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)
    seven_day_util=$(echo "$response" | jq -r '.seven_day.utilization // empty' 2>/dev/null)
    seven_day_reset=$(echo "$response" | jq -r '.seven_day.resets_at // empty' 2>/dev/null)
    opus_util=$(echo "$response" | jq -r '.seven_day_opus.utilization // empty' 2>/dev/null)
    opus_reset=$(echo "$response" | jq -r '.seven_day_opus.resets_at // empty' 2>/dev/null)
    sonnet_util=$(echo "$response" | jq -r '.seven_day_sonnet.utilization // empty' 2>/dev/null)
    sonnet_reset=$(echo "$response" | jq -r '.seven_day_sonnet.resets_at // empty' 2>/dev/null)
    extra_enabled=$(echo "$response" | jq -r '.extra_usage.is_enabled // empty' 2>/dev/null)
    extra_limit=$(echo "$response" | jq -r '.extra_usage.monthly_limit // empty' 2>/dev/null)
    extra_used=$(echo "$response" | jq -r '.extra_usage.used_credits // empty' 2>/dev/null)

    # Required: 5-hour limit
    if [[ -z "$five_hour_util" ]] || [[ -z "$five_hour_reset" ]]; then
        error_exit
    fi

    local five_pct seven_pct opus_pct sonnet_pct
    five_pct=$(parse_int "$five_hour_util")
    seven_pct=$(parse_int "$seven_day_util")
    opus_pct=$(parse_int "$opus_util")
    sonnet_pct=$(parse_int "$sonnet_util")

    # Build output lines
    local lines=()

    # 5-hour limit (if enabled) - all models
    if [[ "$SHOW_5H" == "true" ]]; then
        lines+=("$(format_limit_line "5h all" "$five_pct" "$five_hour_reset")")
    fi

    # 7-day limit (if enabled and available) - all models
    if [[ "$SHOW_7D" == "true" ]] && [[ -n "$seven_pct" ]]; then
        lines+=("$(format_limit_line "7d all" "$seven_pct" "$seven_day_reset")")
    fi

    # 7-day Opus limit (if enabled and has data)
    if [[ "$SHOW_OPUS" == "true" ]] && [[ -n "$opus_pct" ]]; then
        lines+=("$(format_limit_line "7d Opus" "$opus_pct" "$opus_reset")")
    fi

    # 7-day Sonnet limit (if enabled and has utilization > 0 or reset time)
    if [[ "$SHOW_SONNET" == "true" ]] && [[ -n "$sonnet_pct" ]] && { [[ "$sonnet_pct" -gt 0 ]] || [[ -n "$sonnet_reset" && "$sonnet_reset" != "null" ]]; }; then
        lines+=("$(format_limit_line "7d Sonnet" "$sonnet_pct" "$sonnet_reset")")
    fi

    # Extra usage (if enabled AND used_credits > 0)
    if [[ "$SHOW_EXTRA" == "true" ]] && [[ "$extra_enabled" == "true" ]] && [[ -n "$extra_used" ]] && [[ "$extra_used" != "0" ]] && [[ "$extra_used" != "null" ]]; then
        local extra_pct=0
        if [[ -n "$extra_limit" ]] && [[ "$extra_limit" -gt 0 ]]; then
            extra_pct=$((extra_used * 100 / extra_limit))
        fi
        local extra_color=""
        local extra_color_reset=""
        if [[ "$SHOW_COLORS" == "true" ]]; then
            extra_color=$(get_color "$extra_pct")
            extra_color_reset="$COLOR_RESET"
        fi
        local extra_bar=""
        if [[ "$SHOW_PROGRESS" == "true" ]]; then
            extra_bar=" $(progress_bar "$extra_pct")"
        fi
        printf -v extra_line "${extra_color}Extra%s \$%s/\$%s${extra_color_reset}" "$extra_bar" "$extra_used" "$extra_limit"
        lines+=("$extra_line")
    fi

    # Join lines with newline separator (multiline output)
    local first=true
    for line in "${lines[@]}"; do
        if [[ "$first" == "true" ]]; then
            output="$line"
            first=false
        else
            output="$output"$'\n'"$line"
        fi
    done

    echo -e "$output"
}

# Main execution
main() {
    check_dependencies

    local token
    token=$(get_token)

    local response
    response=$(fetch_usage "$token")

    # Debug mode - show raw response structure
    if [[ "$DEBUG" == "true" ]]; then
        echo "DEBUG: Raw API response:"
        echo "$response" | jq '.' 2>/dev/null || echo "$response"
        echo "---"
    fi

    format_output "$response"
}

main
