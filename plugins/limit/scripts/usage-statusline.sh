#!/bin/bash
# usage-statusline.sh - Display live API usage in Claude Code statusline
# Shows utilization with progress bars, colors, and reset times from Anthropic API

set -euo pipefail

# Configuration
CREDENTIALS_FILE="${HOME}/.claude/.credentials.json"
API_URL="https://api.anthropic.com/api/oauth/usage"
TIMEOUT=5

# Cache configuration (rate limiting)
CACHE_FILE="/tmp/claude-mb-limit-cache.json"
CACHE_MAX_AGE="${CLAUDE_MB_LIMIT_CACHE_AGE:-120}"  # 2 minutes default

# Debug mode - logs to /tmp/claude-mb-limit-debug.log
DEBUG="${CLAUDE_MB_LIMIT_DEBUG:-false}"
DEBUG_LOG="/tmp/claude-mb-limit-debug.log"

# Debug logging function
debug_log() {
    if [[ "$DEBUG" == "true" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$DEBUG_LOG"
    fi
}

# Feature toggles (all default to true)
SHOW_MODEL="${CLAUDE_MB_LIMIT_MODEL:-true}"
SHOW_5H="${CLAUDE_MB_LIMIT_5H:-true}"
SHOW_7D="${CLAUDE_MB_LIMIT_7D:-true}"
SHOW_OPUS="${CLAUDE_MB_LIMIT_OPUS:-true}"
SHOW_SONNET="${CLAUDE_MB_LIMIT_SONNET:-true}"
SHOW_EXTRA="${CLAUDE_MB_LIMIT_EXTRA:-true}"
SHOW_COLORS="${CLAUDE_MB_LIMIT_COLORS:-true}"
SHOW_PROGRESS="${CLAUDE_MB_LIMIT_PROGRESS:-true}"
SHOW_RESET="${CLAUDE_MB_LIMIT_RESET:-true}"

# Extended features (all default to true)
SHOW_CWD="${CLAUDE_MB_LIMIT_CWD:-true}"
SHOW_GIT="${CLAUDE_MB_LIMIT_GIT:-true}"
SHOW_TOKENS="${CLAUDE_MB_LIMIT_TOKENS:-true}"
SHOW_CTX="${CLAUDE_MB_LIMIT_CTX:-true}"
SHOW_SESSION="${CLAUDE_MB_LIMIT_SESSION:-true}"
SHOW_SESSION_ID="${CLAUDE_MB_LIMIT_SESSION_ID:-true}"
SHOW_SEPARATORS="${CLAUDE_MB_LIMIT_SEPARATORS:-true}"

# Local device tracking (default false - feature in development)
SHOW_LOCAL="${CLAUDE_MB_LIMIT_LOCAL:-false}"
LOCAL_DEVICE_LABEL="${CLAUDE_MB_LIMIT_DEVICE_LABEL:-$(hostname)}"

# Default color (full ANSI escape sequence, default \033[90m = dark gray)
# Example: export CLAUDE_MB_LIMIT_DEFAULT_COLOR='\033[38;5;244m' for lighter gray
DEFAULT_COLOR="${CLAUDE_MB_LIMIT_DEFAULT_COLOR:-\033[90m}"

# Claude settings file (for model info)
CLAUDE_SETTINGS_FILE="${HOME}/.claude/settings.json"

# ANSI color codes
COLOR_RESET='\033[0m'
COLOR_GRAY="$DEFAULT_COLOR"
COLOR_GREEN='\033[32m'
COLOR_YELLOW='\033[33m'
COLOR_ORANGE='\033[38;5;208m'
COLOR_RED='\033[31m'
COLOR_CYAN='\033[36m'
COLOR_MAGENTA='\033[35m'
COLOR_BLUE='\033[34m'
COLOR_BRIGHT_BLUE='\033[94m'
COLOR_BRIGHT_CYAN='\033[96m'
COLOR_BLACK='\033[30m'
COLOR_WHITE='\033[97m'
COLOR_SILVER='\033[38;5;250m'
COLOR_GOLD='\033[38;5;220m'
COLOR_SALMON='\033[38;5;210m'

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

# Read stdin data from Claude Code (JSON with model info, etc.)
# Called once at startup, cached in STDIN_DATA
STDIN_DATA=""
read_stdin_data() {
    if [[ -t 0 ]]; then
        # No stdin (running manually in terminal)
        STDIN_DATA=""
        debug_log "No stdin (TTY mode)"
    else
        # Read first line from stdin with timeout (Claude Code sends single-line JSON)
        # Timeout prevents hanging if stdin has no data
        STDIN_DATA=$(timeout 0.5 head -n 1 2>/dev/null) || STDIN_DATA=""
        debug_log "Stdin read: ${STDIN_DATA:0:200}..."
    fi
}

# Get current model name only (e.g., "Opus", "Sonnet", "Haiku")
get_current_model() {
    local display_name=""

    # Primary: Get model from stdin data (sent by Claude Code)
    if [[ -n "$STDIN_DATA" ]]; then
        display_name=$(echo "$STDIN_DATA" | jq -r '.model.display_name // empty' 2>/dev/null)
    fi

    # Return model name with version (e.g., "Opus 4.5" from "Claude Opus 4.5")
    if [[ -n "$display_name" ]] && [[ "$display_name" != "null" ]]; then
        # Remove "Claude " prefix, keep version
        display_name="${display_name#Claude }"
        echo "$display_name"
        return
    fi

    # Fallback: Get model from settings.json
    local model=""
    if [[ -f "$CLAUDE_SETTINGS_FILE" ]]; then
        model=$(jq -r '.model // empty' "$CLAUDE_SETTINGS_FILE" 2>/dev/null)
    fi

    if [[ -z "$model" ]] || [[ "$model" == "null" ]]; then
        echo ""
        return
    fi

    # Capitalize first letter (opus -> Opus, sonnet -> Sonnet)
    echo "${model^}"
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

# Format reset time as "yyyy-mm-dd hh:mm", rounded to nearest hour
# API sometimes returns :59:59, sometimes :00:00 - we round to the hour
format_reset_datetime() {
    local reset_at="$1"

    if [[ -z "$reset_at" ]] || [[ "$reset_at" == "null" ]]; then
        echo "-"
        return
    fi

    local formatted
    if date --version >/dev/null 2>&1; then
        # GNU date (Linux/WSL) - round to nearest hour by adding 30 minutes then truncating
        # This handles :59:59 -> next hour, :00:00 -> same hour
        formatted=$(date -d "$reset_at + 30 minutes" "+%Y-%m-%d %H:00" 2>/dev/null) || formatted="-"
    else
        # BSD date (macOS) - same rounding logic
        local epoch
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${reset_at%%.*}" "+%s" 2>/dev/null) || { echo "-"; return; }
        epoch=$((epoch + 1800))  # Add 30 minutes
        formatted=$(date -r "$epoch" "+%Y-%m-%d %H:00" 2>/dev/null) || formatted="-"
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

# =============================================================================
# Extended features
# =============================================================================

# Get current working directory from stdin data
get_cwd() {
    if [[ -n "$STDIN_DATA" ]]; then
        local cwd
        cwd=$(echo "$STDIN_DATA" | jq -r '.cwd // empty' 2>/dev/null)
        if [[ -n "$cwd" ]] && [[ "$cwd" != "null" ]]; then
            echo "$cwd"
            return
        fi
    fi
    # Fallback to pwd
    pwd 2>/dev/null || echo ""
}

# Get git worktree name
# Returns "main" for standard repos, worktree name for worktrees
get_git_worktree() {
    local git_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 1

    # Standard repo: ends with /.git or is just .git
    if [[ "$git_dir" == ".git" ]] || [[ "$git_dir" == *"/.git" ]]; then
        echo "main"
        return
    fi

    # Worktree: path like /path/to/.git/worktrees/worktree-name
    if [[ "$git_dir" == *"/worktrees/"* ]]; then
        # Extract worktree name from path
        local worktree_name
        worktree_name=$(basename "$git_dir")
        echo "$worktree_name"
        return
    fi

    # Unknown structure, return main
    echo "main"
}

# Get git changes (insertions and deletions)
# Returns "+X,-Y" format
get_git_changes() {
    local insertions=0
    local deletions=0

    # Staged changes
    local staged
    staged=$(git diff --cached --shortstat 2>/dev/null) || true
    if [[ -n "$staged" ]]; then
        local staged_ins staged_del
        staged_ins=$(echo "$staged" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
        staged_del=$(echo "$staged" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
        insertions=$((insertions + ${staged_ins:-0}))
        deletions=$((deletions + ${staged_del:-0}))
    fi

    # Unstaged changes
    local unstaged
    unstaged=$(git diff --shortstat 2>/dev/null) || true
    if [[ -n "$unstaged" ]]; then
        local unstaged_ins unstaged_del
        unstaged_ins=$(echo "$unstaged" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
        unstaged_del=$(echo "$unstaged" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
        insertions=$((insertions + ${unstaged_ins:-0}))
        deletions=$((deletions + ${unstaged_del:-0}))
    fi

    echo "+${insertions},-${deletions}"
}

# Get current git branch
get_git_branch() {
    git branch --show-current 2>/dev/null || echo ""
}

# Format tokens as human-readable (e.g., 1500000 -> 1.5M, 18600 -> 18.6k)
format_tokens() {
    local tokens="$1"
    if [[ -z "$tokens" ]] || [[ "$tokens" == "null" ]]; then
        echo "0"
        return
    fi

    if [[ "$tokens" -ge 1000000 ]]; then
        # Millions
        local m_val
        m_val=$(awk "BEGIN {printf \"%.1f\", $tokens/1000000}")
        echo "${m_val}M"
    elif [[ "$tokens" -ge 1000 ]]; then
        # Thousands
        local k_val
        k_val=$(awk "BEGIN {printf \"%.1f\", $tokens/1000}")
        echo "${k_val}k"
    else
        echo "$tokens"
    fi
}

# Calculate token cost based on model (input price per million tokens)
calculate_token_cost() {
    local tokens="$1"
    local model="$2"
    local price_per_million=3  # Default: Sonnet

    case "${model,,}" in
        *opus*) price_per_million=15 ;;
        *sonnet*) price_per_million=3 ;;
        *haiku*) price_per_million=0.25 ;;
    esac

    awk "BEGIN {printf \"%.2f\", ($tokens / 1000000) * $price_per_million}"
}

# Get and update totals using per-session delta tracking
# Each session is tracked by its session_id, allowing parallel sessions to accumulate correctly
# Also tracks cost using Claude's total_cost_usd (which is correctly calculated)
get_total_tokens_ever() {
    local state_file="${HOME}/.claude/limit-local-state.json"

    # Get current session data from stdin
    local session_id="" current_input=0 current_output=0 current_cost="0.00"
    if [[ -n "$STDIN_DATA" ]]; then
        session_id=$(echo "$STDIN_DATA" | jq -r '.session_id // ""' 2>/dev/null) || session_id=""
        current_input=$(echo "$STDIN_DATA" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null) || current_input=0
        current_output=$(echo "$STDIN_DATA" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null) || current_output=0
        current_cost=$(echo "$STDIN_DATA" | jq -r '.cost.total_cost_usd // 0' 2>/dev/null) || current_cost="0"
        [[ "$session_id" == "null" ]] && session_id=""
        [[ "$current_input" == "null" ]] && current_input=0
        [[ "$current_output" == "null" ]] && current_output=0
        [[ "$current_cost" == "null" ]] && current_cost="0"
    fi

    debug_log "get_total_tokens_ever: session_id=$session_id current_in=$current_input current_out=$current_output current_cost=$current_cost"

    # If no session_id, fall back to simple mode
    if [[ -z "$session_id" ]]; then
        debug_log "No session_id available, skipping total tracking"
        echo "0"
        return
    fi

    # Read current state file
    local state="{}"
    local state_file_exists="false"
    if [[ -f "$state_file" ]]; then
        state=$(cat "$state_file" 2>/dev/null) || state="{}"
        state_file_exists="true"
        debug_log "State file exists, content length: ${#state}"
    else
        debug_log "State file does not exist, will create new"
    fi

    # Check if this session already exists in state
    local session_exists="false"
    if [[ "$state_file_exists" == "true" ]]; then
        local existing_session
        existing_session=$(echo "$state" | jq -r ".sessions[\"$session_id\"] // \"null\"" 2>/dev/null)
        if [[ "$existing_session" != "null" ]] && [[ -n "$existing_session" ]]; then
            session_exists="true"
        fi
    fi
    debug_log "Session $session_id exists in state: $session_exists"

    # Get previous values for this session
    local last_input=0 last_output=0 last_cost="0"
    last_input=$(echo "$state" | jq -r ".sessions[\"$session_id\"].last_input // 0" 2>/dev/null) || last_input=0
    last_output=$(echo "$state" | jq -r ".sessions[\"$session_id\"].last_output // 0" 2>/dev/null) || last_output=0
    last_cost=$(echo "$state" | jq -r ".sessions[\"$session_id\"].last_cost // 0" 2>/dev/null) || last_cost="0"
    [[ "$last_input" == "null" ]] && last_input=0
    [[ "$last_output" == "null" ]] && last_output=0
    [[ "$last_cost" == "null" ]] && last_cost="0"

    debug_log "Previous values for session: last_in=$last_input last_out=$last_output last_cost=$last_cost"

    # Calculate deltas for this session
    local delta_input=0 delta_output=0 delta_cost="0"
    local reset_detected="false"
    if [[ "$current_input" -lt "$last_input" ]] || [[ "$current_output" -lt "$last_output" ]]; then
        # Session reset detected - use current values as delta
        delta_input="$current_input"
        delta_output="$current_output"
        delta_cost="$current_cost"
        reset_detected="true"
        debug_log "Session reset detected (current < last), using current as delta"
    else
        delta_input=$((current_input - last_input))
        delta_output=$((current_output - last_output))
        delta_cost=$(awk "BEGIN {printf \"%.4f\", $current_cost - $last_cost}")
    fi

    debug_log "Deltas: in=$delta_input out=$delta_output cost=$delta_cost reset=$reset_detected"

    # Get current totals
    local total_input=0 total_output=0 total_cost="0"
    total_input=$(echo "$state" | jq -r '.totals.input_tokens // 0' 2>/dev/null) || total_input=0
    total_output=$(echo "$state" | jq -r '.totals.output_tokens // 0' 2>/dev/null) || total_output=0
    total_cost=$(echo "$state" | jq -r '.totals.total_cost_usd // 0' 2>/dev/null) || total_cost="0"
    [[ "$total_input" == "null" ]] && total_input=0
    [[ "$total_output" == "null" ]] && total_output=0
    [[ "$total_cost" == "null" ]] && total_cost="0"

    debug_log "Current totals from state: in=$total_input out=$total_output cost=$total_cost"

    # Update totals with deltas
    local new_total_input=$((total_input + delta_input))
    local new_total_output=$((total_output + delta_output))
    local new_total_cost
    new_total_cost=$(awk "BEGIN {printf \"%.4f\", $total_cost + $delta_cost}")

    debug_log "New totals: in=$new_total_input out=$new_total_output cost=$new_total_cost"

    # Only update if there was a change
    local delta_total=$((delta_input + delta_output))
    if [[ "$delta_total" -gt 0 ]] || [[ ! -f "$state_file" ]]; then
        mkdir -p "$(dirname "$state_file")" 2>/dev/null || true

        # Preserve start_pct values for local tracking feature
        local start_5h=-1 start_7d=-1 last_5h="" last_7d=""
        start_5h=$(echo "$state" | jq -r '.start_5h_pct // -1' 2>/dev/null) || start_5h=-1
        start_7d=$(echo "$state" | jq -r '.start_7d_pct // -1' 2>/dev/null) || start_7d=-1
        last_5h=$(echo "$state" | jq -r '.last_5h_reset // ""' 2>/dev/null) || last_5h=""
        last_7d=$(echo "$state" | jq -r '.last_7d_reset // ""' 2>/dev/null) || last_7d=""
        [[ "$start_5h" == "null" ]] && start_5h=-1
        [[ "$start_7d" == "null" ]] && start_7d=-1
        [[ "$last_5h" == "null" ]] && last_5h=""
        [[ "$last_7d" == "null" ]] && last_7d=""

        # Build sessions object - preserve existing sessions, update current
        local sessions_json
        sessions_json=$(echo "$state" | jq -r '.sessions // {}' 2>/dev/null) || sessions_json="{}"
        sessions_json=$(echo "$sessions_json" | jq --arg sid "$session_id" \
            --argjson inp "$current_input" \
            --argjson out "$current_output" \
            --arg cost "$current_cost" \
            '.[$sid] = {"last_input": $inp, "last_output": $out, "last_cost": ($cost | tonumber)}' 2>/dev/null) || sessions_json="{}"

        debug_log "Writing state file with sessions: $(echo "$sessions_json" | jq -c '.')"

        # Write updated state
        cat > "$state_file" << EOF
{
  "start_5h_pct": ${start_5h},
  "start_7d_pct": ${start_7d},
  "last_5h_reset": "${last_5h}",
  "last_7d_reset": "${last_7d}",
  "sessions": ${sessions_json},
  "totals": {
    "input_tokens": ${new_total_input},
    "output_tokens": ${new_total_output},
    "total_cost_usd": ${new_total_cost}
  }
}
EOF
        debug_log "State file written successfully"
    else
        debug_log "No change detected (delta_total=$delta_total), skipping write"
    fi

    # Return total tokens (input + output)
    echo "$((new_total_input + new_total_output))"
}

# Get total accumulated cost from state file
get_total_cost_ever() {
    local state_file="${HOME}/.claude/limit-local-state.json"
    if [[ -f "$state_file" ]]; then
        local cost
        cost=$(jq -r '.totals.total_cost_usd // 0' "$state_file" 2>/dev/null) || cost="0"
        [[ "$cost" == "null" ]] && cost="0"
        awk "BEGIN {printf \"%.2f\", $cost}"
    else
        echo "0.00"
    fi
}

# Get context length from stdin data
# Current context = cache_read + cache_creation + input tokens
get_context_length() {
    if [[ -n "$STDIN_DATA" ]]; then
        local cache_read cache_create input_tok
        cache_read=$(echo "$STDIN_DATA" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0' 2>/dev/null)
        cache_create=$(echo "$STDIN_DATA" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0' 2>/dev/null)
        input_tok=$(echo "$STDIN_DATA" | jq -r '.context_window.current_usage.input_tokens // 0' 2>/dev/null)

        # Handle null values
        [[ "$cache_read" == "null" ]] && cache_read=0
        [[ "$cache_create" == "null" ]] && cache_create=0
        [[ "$input_tok" == "null" ]] && input_tok=0

        local total=$((cache_read + cache_create + input_tok))
        echo "$total"
        return
    fi
    echo "0"
}

# Get max context for model (usable = 80% before auto-compact)
get_model_context_config() {
    local config_type="$1"  # "max" or "usable"

    # Get context_window_size from stdin data
    local max_tokens=200000
    if [[ -n "$STDIN_DATA" ]]; then
        local size
        size=$(echo "$STDIN_DATA" | jq -r '.context_window.context_window_size // empty' 2>/dev/null)
        if [[ -n "$size" ]] && [[ "$size" != "null" ]]; then
            max_tokens="$size"
        fi
    fi

    # Usable = 80% of max (before auto-compact)
    local usable_tokens=$((max_tokens * 80 / 100))

    if [[ "$config_type" == "usable" ]]; then
        echo "$usable_tokens"
    else
        echo "$max_tokens"
    fi
}

# Get model ID from stdin data
get_model_id() {
    if [[ -n "$STDIN_DATA" ]]; then
        local model_id
        model_id=$(echo "$STDIN_DATA" | jq -r '.model.id // empty' 2>/dev/null)
        if [[ -n "$model_id" ]] && [[ "$model_id" != "null" ]]; then
            echo "$model_id"
            return
        fi
    fi
    echo ""
}

# Get output style from stdin data (e.g., "default", "concise")
get_thinking_style() {
    if [[ -n "$STDIN_DATA" ]]; then
        local style
        style=$(echo "$STDIN_DATA" | jq -r '.output_style.name // empty' 2>/dev/null)
        if [[ -n "$style" ]] && [[ "$style" != "null" ]]; then
            echo "$style"
            return
        fi
    fi
    echo "default"
}

# Get total cost from stdin data (USD)
get_total_cost() {
    if [[ -n "$STDIN_DATA" ]]; then
        local cost
        cost=$(echo "$STDIN_DATA" | jq -r '.cost.total_cost_usd // empty' 2>/dev/null)
        if [[ -n "$cost" ]] && [[ "$cost" != "null" ]]; then
            # Format to 2 decimal places
            awk "BEGIN {printf \"%.2f\", ${cost:-0}}"
            return
        fi
    fi
    echo "0.00"
}

# Get session ID from stdin data
get_session_id() {
    if [[ -n "$STDIN_DATA" ]]; then
        local session_id
        session_id=$(echo "$STDIN_DATA" | jq -r '.session_id // empty' 2>/dev/null)
        if [[ -n "$session_id" ]] && [[ "$session_id" != "null" ]]; then
            echo "$session_id"
            return
        fi
    fi
    echo ""
}

# Get token metrics from stdin data
# Uses context_window totals for session-wide metrics, current_usage for cache
get_token_metrics() {
    local metric="$1"  # input, output, cache_read
    if [[ -n "$STDIN_DATA" ]]; then
        local value
        case "$metric" in
            input)
                # Session total input tokens
                value=$(echo "$STDIN_DATA" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null)
                ;;
            output)
                # Session total output tokens
                value=$(echo "$STDIN_DATA" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null)
                ;;
            cache_read)
                # Current context cache (for context calculation)
                value=$(echo "$STDIN_DATA" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0' 2>/dev/null)
                ;;
            *)
                value="0"
                ;;
        esac
        if [[ -n "$value" ]] && [[ "$value" != "null" ]]; then
            echo "$value"
            return
        fi
    fi
    echo "0"
}

# Get session timing info from stdin data
# Uses cost.total_duration_ms and cost.total_api_duration_ms
get_session_time() {
    local time_type="$1"  # session or api
    if [[ -n "$STDIN_DATA" ]]; then
        local value_ms
        case "$time_type" in
            session)
                value_ms=$(echo "$STDIN_DATA" | jq -r '.cost.total_duration_ms // empty' 2>/dev/null)
                ;;
            block)
                # Use API duration as "block" time
                value_ms=$(echo "$STDIN_DATA" | jq -r '.cost.total_api_duration_ms // empty' 2>/dev/null)
                ;;
        esac
        if [[ -n "$value_ms" ]] && [[ "$value_ms" != "null" ]]; then
            # Convert ms to seconds
            local seconds=$((value_ms / 1000))
            echo "$seconds"
            return
        fi
    fi
    echo ""
}

# Format seconds as human-readable duration (e.g., 2d5h, 2h15m, 45m, 30s)
format_duration() {
    local seconds="$1"
    if [[ -z "$seconds" ]] || [[ "$seconds" == "null" ]]; then
        echo "-"
        return
    fi

    local days=$((seconds / 86400))
    local hours=$(((seconds % 86400) / 3600))
    local minutes=$(((seconds % 3600) / 60))

    if [[ "$days" -gt 0 ]]; then
        echo "${days}d${hours}h"
    elif [[ "$hours" -gt 0 ]]; then
        echo "${hours}h${minutes}m"
    elif [[ "$minutes" -gt 0 ]]; then
        echo "${minutes}m"
    else
        echo "${seconds}s"
    fi
}

# =============================================================================
# Output formatting
# =============================================================================

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

    # -------------------------------------------------------------------------
    # Extended features (displayed first, before limits)
    # -------------------------------------------------------------------------

    # CWD (Current Working Directory) - gray
    if [[ "$SHOW_CWD" == "true" ]]; then
        local cwd
        cwd=$(get_cwd)
        if [[ -n "$cwd" ]]; then
            local cwd_color=""
            local cwd_color_reset=""
            if [[ "$SHOW_COLORS" == "true" ]]; then
                cwd_color="$COLOR_GRAY"
                cwd_color_reset="$COLOR_RESET"
            fi
            lines+=("${cwd_color}cwd: ${cwd}${cwd_color_reset}")
        fi
    fi

    # Git line: worktree + changes + branch
    # Format: [wt] main (+0,-0)⎇ main
    if [[ "$SHOW_GIT" == "true" ]]; then
        local git_line=""

        # Check if in git repo
        if git rev-parse --git-dir >/dev/null 2>&1; then
            # Git worktree (dark blue) - symbol: [wt]
            local worktree
            worktree=$(get_git_worktree 2>/dev/null) || true
            if [[ -n "$worktree" ]]; then
                local wt_color=""
                local wt_color_reset=""
                if [[ "$SHOW_COLORS" == "true" ]]; then
                    wt_color="$COLOR_BRIGHT_BLUE"
                    wt_color_reset="$COLOR_RESET"
                fi
                git_line="${wt_color}[wt] ${worktree}${wt_color_reset}"
            fi

            # Git changes (cyan) - format: (+X,-Y)
            local changes
            changes=$(get_git_changes)
            local chg_color=""
            local chg_color_reset=""
            if [[ "$SHOW_COLORS" == "true" ]]; then
                chg_color="$COLOR_CYAN"
                chg_color_reset="$COLOR_RESET"
            fi
            if [[ -n "$git_line" ]]; then
                git_line="${git_line} ${chg_color}(${changes})${chg_color_reset}"
            else
                git_line="${chg_color}(${changes})${chg_color_reset}"
            fi

            # Git branch (bright cyan/light blue) - symbol: ⎇
            local branch
            branch=$(get_git_branch)
            if [[ -n "$branch" ]]; then
                local br_color=""
                local br_color_reset=""
                if [[ "$SHOW_COLORS" == "true" ]]; then
                    br_color="$COLOR_BRIGHT_CYAN"
                    br_color_reset="$COLOR_RESET"
                fi
                git_line="${git_line}${br_color}⎇ ${branch}${br_color_reset}"
            fi

            # Add git line
            if [[ -n "$git_line" ]]; then
                lines+=("$git_line")
            fi
        fi
    fi

    # -------------------------------------------------------------------------
    # Tokens/Context/Session with dynamic column alignment
    # -------------------------------------------------------------------------

    # First, gather all values to calculate dynamic column widths
    local tok_col1_str="" tok_col2_str="" tok_col3_str="" tok_col4_str=""
    local ctx_col1_str="" ctx_col2_str="" ctx_col3_str=""
    local sess_col1_str="" sess_col2_str=""

    # Tokens values
    if [[ "$SHOW_TOKENS" == "true" ]]; then
        local in_tokens out_tokens cache_read total_tokens
        in_tokens=$(get_token_metrics "input")
        out_tokens=$(get_token_metrics "output")
        cache_read=$(get_token_metrics "cache_read")
        total_tokens=$((in_tokens + out_tokens))

        tok_col1_str="In: $(format_tokens "$in_tokens")"
        tok_col2_str="Out: $(format_tokens "$out_tokens")"
        tok_col3_str="Cached: $(format_tokens "$cache_read")"
        tok_col4_str="Total: $(format_tokens "$total_tokens")"
    fi

    # Context values
    local ctx_usable_color="" ctx_usable_color_reset=""
    if [[ "$SHOW_CTX" == "true" ]]; then
        local ctx_len formatted_len max_tokens total_pct="" usable_tokens usable_pct="" usable_pct_int
        ctx_len=$(get_context_length)
        ctx_len="${ctx_len:-0}"
        formatted_len=$(format_tokens "$ctx_len")

        max_tokens=$(get_model_context_config "max")
        if [[ -n "$max_tokens" ]] && [[ "$max_tokens" -gt 0 ]]; then
            total_pct=$(awk "BEGIN {printf \"%.1f\", ($ctx_len / $max_tokens) * 100}")
        fi

        usable_tokens=$(get_model_context_config "usable")
        if [[ -n "$usable_tokens" ]] && [[ "$usable_tokens" -gt 0 ]]; then
            usable_pct=$(awk "BEGIN {printf \"%.1f\", ($ctx_len / $usable_tokens) * 100}")
            usable_pct_int="${usable_pct%%.*}"
            if [[ "$SHOW_COLORS" == "true" ]]; then
                ctx_usable_color=$(get_color "$usable_pct_int")
                ctx_usable_color_reset="$COLOR_RESET"
            fi
        fi

        ctx_col1_str="Ctx: ${formatted_len}"
        ctx_col2_str="Ctx: ${total_pct}%"
        ctx_col3_str="Ctx(usable): ${usable_pct}%"
    fi

    # Session values
    if [[ "$SHOW_SESSION" == "true" ]]; then
        local session_secs api_secs
        session_secs=$(get_session_time "session")
        api_secs=$(get_session_time "block")

        sess_col1_str="Total: $(format_duration "$session_secs")"
        sess_col2_str="API: $(format_duration "$api_secs")"
    fi

    # Calculate dynamic column widths (max of each column + 2 for spacing)
    local col1_width=0 col2_width=0
    local len

    # Col1: tok_col1, ctx_col1, sess_col1
    for str in "$tok_col1_str" "$ctx_col1_str" "$sess_col1_str"; do
        len=${#str}
        [[ $len -gt $col1_width ]] && col1_width=$len
    done
    col1_width=$((col1_width + 2))

    # Col2: tok_col2, ctx_col2, sess_col2
    for str in "$tok_col2_str" "$ctx_col2_str" "$sess_col2_str"; do
        len=${#str}
        [[ $len -gt $col2_width ]] && col2_width=$len
    done
    col2_width=$((col2_width + 2))

    # Now output the lines with dynamic widths
    local gray_color="" gray_color_reset=""
    if [[ "$SHOW_COLORS" == "true" ]]; then
        gray_color="$COLOR_GRAY"
        gray_color_reset="$COLOR_RESET"
    fi

    # Tokens line
    if [[ "$SHOW_TOKENS" == "true" ]]; then
        local tok_c1 tok_c2
        printf -v tok_c1 "%-${col1_width}s" "$tok_col1_str"
        printf -v tok_c2 "%-${col2_width}s" "$tok_col2_str"
        lines+=("${gray_color}Tokens  -> ${tok_c1}${tok_c2}${tok_col3_str}  ${tok_col4_str}${gray_color_reset}")
    fi

    # Context line
    if [[ "$SHOW_CTX" == "true" ]]; then
        local ctx_c1 ctx_c2
        printf -v ctx_c1 "%-${col1_width}s" "$ctx_col1_str"
        printf -v ctx_c2 "%-${col2_width}s" "$ctx_col2_str"
        lines+=("${gray_color}Context -> ${ctx_c1}${ctx_c2}${gray_color_reset}${ctx_usable_color}${ctx_col3_str}${ctx_usable_color_reset}")
    fi

    # Session line
    if [[ "$SHOW_SESSION" == "true" ]]; then
        local sess_c1
        printf -v sess_c1 "%-${col1_width}s" "$sess_col1_str"
        lines+=("${gray_color}Session -> ${sess_c1}${sess_col2_str}${gray_color_reset}")
    fi

    # -------------------------------------------------------------------------
    # Original limit features (with empty line separator)
    # -------------------------------------------------------------------------

    # Add visual separator before limits (black dash, invisible on dark terminals)
    if [[ "$SHOW_SEPARATORS" == "true" ]]; then
        lines+=("${COLOR_BLACK}-${COLOR_RESET}")
    fi

    # Local tracking: Delta-based calculation (current_pct - start_pct)
    local local_5h_pct="" local_7d_pct=""
    if [[ "$SHOW_LOCAL" == "true" ]]; then
        local state_file="${HOME}/.claude/limit-local-state.json"

        # Read current state
        local start_5h=-1 start_7d=-1 last_5h_reset="" last_7d_reset=""
        if [[ -f "$state_file" ]]; then
            start_5h=$(jq -r '.start_5h_pct // -1' "$state_file" 2>/dev/null) || start_5h=-1
            start_7d=$(jq -r '.start_7d_pct // -1' "$state_file" 2>/dev/null) || start_7d=-1
            last_5h_reset=$(jq -r '.last_5h_reset // ""' "$state_file" 2>/dev/null) || last_5h_reset=""
            last_7d_reset=$(jq -r '.last_7d_reset // ""' "$state_file" 2>/dev/null) || last_7d_reset=""
            [[ "$start_5h" == "null" ]] && start_5h=-1
            [[ "$start_7d" == "null" ]] && start_7d=-1
            [[ "$last_5h_reset" == "null" ]] && last_5h_reset=""
            [[ "$last_7d_reset" == "null" ]] && last_7d_reset=""
        fi

        # Initialize or reset start values
        local needs_update=false

        # First run: initialize start values
        if [[ "$start_5h" == "-1" ]]; then
            start_5h="$five_pct"
            needs_update=true
        fi
        if [[ "$start_7d" == "-1" ]]; then
            start_7d="${seven_pct:-0}"
            needs_update=true
        fi

        # Reset detection: if current % dropped below start % (usage was reset by API)
        # This is more reliable than comparing timestamps which vary between :59:59 and :00:00
        if [[ "$five_pct" -lt "$start_5h" ]]; then
            start_5h="$five_pct"
            needs_update=true
        fi
        if [[ -n "$seven_pct" ]] && [[ "$seven_pct" -lt "$start_7d" ]]; then
            start_7d="$seven_pct"
            needs_update=true
        fi

        # Update state file if needed - PRESERVE sessions and totals!
        if [[ "$needs_update" == "true" ]]; then
            mkdir -p "$(dirname "$state_file")" 2>/dev/null || true

            # Read existing sessions and totals to preserve them
            local existing_sessions="{}" existing_totals='{"input_tokens":0,"output_tokens":0,"total_cost_usd":0}'
            if [[ -f "$state_file" ]]; then
                existing_sessions=$(jq -r '.sessions // {}' "$state_file" 2>/dev/null) || existing_sessions="{}"
                existing_totals=$(jq -c '.totals // {"input_tokens":0,"output_tokens":0,"total_cost_usd":0}' "$state_file" 2>/dev/null) || existing_totals='{"input_tokens":0,"output_tokens":0,"total_cost_usd":0}'
                [[ "$existing_sessions" == "null" ]] && existing_sessions="{}"
                [[ "$existing_totals" == "null" ]] && existing_totals='{"input_tokens":0,"output_tokens":0,"total_cost_usd":0}'
            fi

            cat > "$state_file" << EOF
{
  "start_5h_pct": ${start_5h},
  "start_7d_pct": ${start_7d},
  "last_5h_reset": "${five_hour_reset:-}",
  "last_7d_reset": "${seven_day_reset:-}",
  "sessions": ${existing_sessions},
  "totals": ${existing_totals}
}
EOF
        fi

        # Calculate delta: local = current - start
        local_5h_pct=$((five_pct - start_5h))
        [[ "$local_5h_pct" -lt 0 ]] && local_5h_pct=0

        if [[ -n "$seven_pct" ]]; then
            local_7d_pct=$((seven_pct - start_7d))
            [[ "$local_7d_pct" -lt 0 ]] && local_7d_pct=0
        fi
    fi

    # 5-hour limit (if enabled) - all models
    if [[ "$SHOW_5H" == "true" ]]; then
        lines+=("$(format_limit_line "5h all" "$five_pct" "$five_hour_reset")")
        # Local 5h directly below global 5h
        if [[ "$SHOW_LOCAL" == "true" ]] && [[ -n "${local_5h_pct}" ]]; then
            local local_5h_color="" local_5h_reset=""
            if [[ "$SHOW_COLORS" == "true" ]]; then
                local_5h_color=$(get_color "${local_5h_pct}")
                local_5h_reset="${COLOR_RESET}"
            fi
            lines+=("$(format_limit_line "5h all" "${local_5h_pct}" "$five_hour_reset") ${local_5h_color}(${LOCAL_DEVICE_LABEL})${local_5h_reset}")
        fi
    fi

    # 7-day limit (if enabled and available) - all models
    if [[ "$SHOW_7D" == "true" ]] && [[ -n "$seven_pct" ]]; then
        lines+=("$(format_limit_line "7d all" "$seven_pct" "$seven_day_reset")")
        # Local 7d directly below global 7d
        if [[ "$SHOW_LOCAL" == "true" ]] && [[ -n "${local_7d_pct}" ]]; then
            local local_7d_color="" local_7d_reset=""
            if [[ "$SHOW_COLORS" == "true" ]]; then
                local_7d_color=$(get_color "${local_7d_pct}")
                local_7d_reset="${COLOR_RESET}"
            fi
            lines+=("$(format_limit_line "7d all" "${local_7d_pct}" "$seven_day_reset") ${local_7d_color}(${LOCAL_DEVICE_LABEL})${local_7d_reset}")
        fi
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
    # Note: extra_limit and extra_used are dollar amounts and may contain decimals
    # Extra usage: check if used_credits > 0 (handles "0", "0.0", "0.00" etc.)
    local extra_used_int="${extra_used%%.*}"
    if [[ "$SHOW_EXTRA" == "true" ]] && [[ "$extra_enabled" == "true" ]] && [[ -n "$extra_used" ]] && [[ "$extra_used" != "null" ]] && [[ -n "$extra_used_int" ]] && [[ "$extra_used_int" != "0" ]]; then
        local extra_pct=0
        # Convert limit to integer for arithmetic (remove decimal part)
        local extra_limit_int="${extra_limit%%.*}"
        if [[ -n "$extra_limit_int" ]] && [[ "$extra_limit_int" =~ ^[0-9]+$ ]] && [[ "$extra_limit_int" -gt 0 ]]; then
            extra_pct=$((extra_used_int * 100 / extra_limit_int))
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

    # Current model with Style and Cost (if enabled)
    if [[ "$SHOW_MODEL" == "true" ]]; then
        local current_model
        current_model=$(get_current_model)
        if [[ -n "$current_model" ]]; then
            local model_name_color=""
            local model_color=""
            local model_color_reset=""
            local cost_value_color=""
            if [[ "$SHOW_COLORS" == "true" ]]; then
                model_color="$COLOR_GRAY"
                model_color_reset="$COLOR_RESET"
                cost_value_color="$COLOR_WHITE"
                # Model name color based on model type
                case "${current_model,,}" in
                    haiku*) model_name_color="$COLOR_SILVER" ;;
                    sonnet*) model_name_color="$COLOR_SALMON" ;;
                    opus*) model_name_color="$COLOR_GOLD" ;;
                    *) model_name_color="$COLOR_GRAY" ;;
                esac
            fi

            # Add Style
            local style
            style=$(get_thinking_style)

            # Add Cost (dollar sign gray, value white)
            local cost
            cost=$(get_total_cost)

            local model_line="${model_name_color}${current_model}${model_color_reset}${model_color} | Style: ${style} | Cost: \$${model_color_reset}${cost_value_color}${cost}${model_color_reset}"

            # Add local token stats if enabled (gray) - shows lifetime total tokens and cost
            if [[ "$SHOW_LOCAL" == "true" ]]; then
                local total_tokens_ever
                total_tokens_ever=$(get_total_tokens_ever)
                if [[ "$total_tokens_ever" -gt 0 ]]; then
                    local formatted_tokens total_cost_ever
                    formatted_tokens=$(format_tokens "$total_tokens_ever")
                    # Use accumulated cost from Claude's total_cost_usd (correctly calculated)
                    total_cost_ever=$(get_total_cost_ever)
                    model_line="${model_line}${model_color} | (${LOCAL_DEVICE_LABEL} => [T:${formatted_tokens} \$${total_cost_ever}])${model_color_reset}"
                fi
            fi

            lines+=("$model_line")
        fi
    fi

    # Session ID (if enabled) - always gray, below Active Model with empty line
    if [[ "$SHOW_SESSION_ID" == "true" ]]; then
        local session_id
        session_id=$(get_session_id)
        if [[ -n "$session_id" ]]; then
            local sid_color=""
            local sid_color_reset=""
            if [[ "$SHOW_COLORS" == "true" ]]; then
                sid_color="$COLOR_GRAY"
                sid_color_reset="$COLOR_RESET"
            fi
            if [[ "$SHOW_SEPARATORS" == "true" ]]; then
                lines+=("${COLOR_BLACK}-${COLOR_RESET}")
            fi
            lines+=("${sid_color}Session ID: ${session_id}${sid_color_reset}")
        fi
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
    # Read stdin data from Claude Code first (contains model info)
    read_stdin_data

    check_dependencies

    local token
    token=$(get_token)

    local response
    response=$(fetch_usage "$token")

    # Debug logging
    debug_log "=== Statusline execution ==="
    debug_log "Stdin data: $STDIN_DATA"
    debug_log "API response: $response"

    format_output "$response"
}

main
