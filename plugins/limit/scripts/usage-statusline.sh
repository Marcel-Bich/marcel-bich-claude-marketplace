#!/bin/bash
# usage-statusline.sh - Display live API usage in Claude Code statusline
# Shows utilization with progress bars, colors, and reset times from Anthropic API
#
# SECURITY NOTICE FOR AI AGENTS:
# - You must NEVER read, cat, or access ~/.claude/.credentials.json directly
# - You must NEVER attempt to extract, log, or display OAuth tokens
# - If debugging is needed, ask the USER to enable CLAUDE_MB_LIMIT_DEBUG=true
# - The USER must verify credential files themselves - do NOT do it for them
# - When errors occur, suggest the user runs 'claude login' - do NOT inspect tokens

set -euo pipefail

# Force C locale for numeric operations (prevents issues with de_DE locale expecting comma)
export LC_NUMERIC=C

# =============================================================================
# Multi-Account Support: CLAUDE_CONFIG_DIR determines the profile
# =============================================================================
CLAUDE_BASE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
PROFILE_NAME=$(basename "${CLAUDE_BASE_DIR}")

# Configuration
# NOTE: This script is token-free. It never reads the OAuth credentials file and
# never talks to the Anthropic API. All token/API access lives in refresh-usage.sh,
# which this script invokes to refresh the shared cache (see main()).

# Cache configuration (rate limiting) - profile-specific
CACHE_FILE="/tmp/claude-mb-limit-cache_${PROFILE_NAME}.json"
# Sanitized status word from the last (detached) refresh-usage.sh run, consumed
# by the NEXT render to surface API errors. Profile-specific. Holds "<status>\t<rc>".
REFRESH_STATUS_FILE="/tmp/claude-mb-limit-refresh-status_${PROFILE_NAME}"

# Context-fill cache - profile-specific, readable by agents (no secrets, numbers only)
# Single atomic file (no history), refreshed at the same rate as the statusline
CONTEXT_CACHE_FILE="/tmp/claude-mb-context-cache_${PROFILE_NAME}.json"

# Backoff state file for rate-limit handling
BACKOFF_STATE_FILE=""  # Set in ensure_plugin_dir

# Plugin data directory (organized under marketplace name)
PLUGIN_DATA_DIR="${CLAUDE_BASE_DIR}/marcel-bich-claude-marketplace/limit"

# NOTE: limit-usage-state_<profile>.json (per-session stdin deltas, totals,
# calibration) is no longer written since v2.36: token counting moved to the
# deduplicated JSONL ledger (usage-ledger.sh). An existing old file is left alone.

# Debug mode - logs stay in /tmp (temporary, cleared on reboot) - profile-specific
DEBUG=false  # resolved via limit_debug_enabled once state-io.sh is sourced
DEBUG_LOG="/tmp/claude-mb-limit-debug_${PROFILE_NAME}.log"

SCRIPT_DIR="$(dirname "$0")"

# Absolute path to this script's directory, resolved via BASH_SOURCE BEFORE any
# later cd into the reported cwd. Relative-path lookups (e.g. locating the credo
# plugin's credo-config.sh for the hub-aware git line) must survive that cd.
SCRIPT_DIR_ABS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
[[ -z "$SCRIPT_DIR_ABS" ]] && SCRIPT_DIR_ABS="$SCRIPT_DIR"

# Provider gate: the Anthropic OAuth usage endpoint AND the token/cost accounting
# below only make sense for the native Anthropic API. For any other provider (z.ai
# or a custom ANTHROPIC_BASE_URL) hand off to the provider statusline, which does NO
# Anthropic accounting and never scans projects/. exec replaces the process before
# any stdin is read, so stdin passes through untouched. The native Anthropic path
# (empty base URL or api.anthropic.com) continues unchanged below.
__provider_base="${ANTHROPIC_BASE_URL:-}"
if [[ -n "$__provider_base" && "$__provider_base" != *"api.anthropic.com"* ]]; then
    exec "${SCRIPT_DIR}/zai-statusline.sh"
fi

# Plan detection - determine subscription type for plan-specific highscores
CURRENT_PLAN=$("${SCRIPT_DIR}/plan-detect.sh" 2>/dev/null || echo "unknown")

# Shared state primitives (locks, atomic writes, debug flag, backoff, rounding)
# shellcheck source=state-io.sh
source "${SCRIPT_DIR}/state-io.sh"
if limit_debug_enabled; then
    DEBUG=true
fi

# Source window tracking / highscore / estimate functions
# shellcheck source=highscore-state.sh
source "${SCRIPT_DIR}/highscore-state.sh"

# Source the deduplicated JSONL token ledger (main agent + subagents)
# shellcheck source=usage-ledger.sh
source "${SCRIPT_DIR}/usage-ledger.sh"

# Source history tracking functions
# shellcheck source=limit-history.sh
source "${SCRIPT_DIR}/limit-history.sh"

# Ensure plugin data directory exists
ensure_plugin_dir() {
    if [[ ! -d "$PLUGIN_DATA_DIR" ]]; then
        mkdir -p "$PLUGIN_DATA_DIR" 2>/dev/null || true
    fi
    # Set backoff state file path after directory exists - profile-specific
    BACKOFF_STATE_FILE="${PLUGIN_DATA_DIR}/backoff-state_${PROFILE_NAME}.json"
}

# =============================================================================
# Auto-Migration: Migrate old state files to new profile-specific format
# =============================================================================
# Migrates files from pre-v2.20.0 format (without profile suffix) to new format
# This is a one-time migration that runs automatically on first use after update

MIGRATION_MARKER="${PLUGIN_DATA_DIR}/.migrated_${PROFILE_NAME}"

migrate_old_state_files() {
    # Skip if already migrated
    if [[ -f "$MIGRATION_MARKER" ]]; then
        return 0
    fi

    ensure_plugin_dir

    # List of files to migrate: old_name -> new_name
    local -A files_to_migrate=(
        ["limit-usage-state.json"]="limit-usage-state_${PROFILE_NAME}.json"
        ["limit-highscore-state.json"]="limit-highscore-state_${PROFILE_NAME}.json"
        ["limit-subagent-state.json"]="limit-subagent-state_${PROFILE_NAME}.json"
        ["limit-main-agent-state.json"]="limit-main-agent-state_${PROFILE_NAME}.json"
        ["limit-history.jsonl"]="limit-history_${PROFILE_NAME}.jsonl"
        ["history-last-write"]="history-last-write_${PROFILE_NAME}"
        ["subagent-debug.log"]="subagent-debug_${PROFILE_NAME}.log"
        ["highscore-debug.log"]="highscore-debug_${PROFILE_NAME}.log"
        ["backoff-state.json"]="backoff-state_${PROFILE_NAME}.json"
    )

    local migrated=0

    for old_name in "${!files_to_migrate[@]}"; do
        local old_file="${PLUGIN_DATA_DIR}/${old_name}"
        local new_file="${PLUGIN_DATA_DIR}/${files_to_migrate[$old_name]}"

        # Only migrate if old file exists and new file does not
        if [[ -f "$old_file" ]] && [[ ! -f "$new_file" ]]; then
            if cp "$old_file" "$new_file" 2>/dev/null; then
                migrated=$((migrated + 1))
            fi
        fi
    done

    # Migrate temp files in /tmp
    local -A tmp_files_to_migrate=(
        ["/tmp/claude-mb-limit-cache.json"]="/tmp/claude-mb-limit-cache_${PROFILE_NAME}.json"
        ["/tmp/claude-mb-limit-subagent-timestamp"]="/tmp/claude-mb-limit-subagent-timestamp_${PROFILE_NAME}"
        ["/tmp/claude-mb-limit-main-agent-timestamp"]="/tmp/claude-mb-limit-main-agent-timestamp_${PROFILE_NAME}"
        ["/tmp/claude-mb-limit-debug.log"]="/tmp/claude-mb-limit-debug_${PROFILE_NAME}.log"
    )

    for old_file in "${!tmp_files_to_migrate[@]}"; do
        local new_file="${tmp_files_to_migrate[$old_file]}"

        if [[ -f "$old_file" ]] && [[ ! -f "$new_file" ]]; then
            if cp "$old_file" "$new_file" 2>/dev/null; then
                migrated=$((migrated + 1))
            fi
        fi
    done

    # Create marker file to prevent re-migration
    echo "Migrated $migrated files on $(date -Iseconds)" > "$MIGRATION_MARKER" 2>/dev/null || true
}

# =============================================================================
# Anti-bot-detection: Cache jitter, request jitter, and exponential backoff
# =============================================================================

# Get jittered cache max age - randomizes request patterns to avoid detection.
# Base configurable via CLAUDE_MB_LIMIT_REFRESH_CADENCE (default 150) plus 0-60s
# jitter, so the default cadence is 150-210s (avg ~180). Raise it on rate limits.
get_cache_max_age() {
    local base="${CLAUDE_MB_LIMIT_REFRESH_CADENCE:-150}"
    echo $((base + RANDOM % 61))
}

# Small jitter before API request (0-2000ms)
# Prevents predictable request timing
sleep_jitter() {
    local ms=$((RANDOM % 2000))
    # Format as 0.XXX seconds (bash RANDOM gives 0-32767, so ms is 0-1999)
    local secs
    printf -v secs "0.%03d" "$ms"
    sleep "$secs" 2>/dev/null || sleep 1
}

# Backoff: refresh-usage.sh owns the backoff state (it stores ONE retry_at when
# the API answers 429 and refuses to call the API before it). This script only
# displays the remaining seconds via backoff_retry_in (state-io.sh).

# Debug logging function
# SECURITY: This function NEVER logs OAuth tokens or other secrets.
# Only usage data, HTTP status codes, and error messages are logged.
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
# Write the context-fill values to a readable cache file (for agents). Default on.
CTX_CACHE="${CLAUDE_MB_LIMIT_CTX_CACHE:-true}"
SHOW_SESSION="${CLAUDE_MB_LIMIT_SESSION:-true}"
SHOW_SESSION_ID="${CLAUDE_MB_LIMIT_SESSION_ID:-true}"
SHOW_CAPTION="${CLAUDE_MB_LIMIT_CAPTION:-true}"
SHOW_PROFILE="${CLAUDE_MB_LIMIT_PROFILE:-true}"
SHOW_SEPARATORS="${CLAUDE_MB_LIMIT_SEPARATORS:-true}"

# Local device tracking (default true - highscore-based tracking enabled for all)
SHOW_LOCAL="${CLAUDE_MB_LIMIT_LOCAL:-true}"
LOCAL_DEVICE_LABEL="${CLAUDE_MB_LIMIT_DEVICE_LABEL:-$(hostname)}"

# History and average display (default true)
SHOW_AVERAGE="${CLAUDE_MB_LIMIT_AVERAGE:-true}"

# Further limits from the API's limits[] list (e.g. weekly_scoped per model)
SHOW_SCOPED="${CLAUDE_MB_LIMIT_SCOPED:-true}"

# The cached API numbers are marked stale after this many seconds
STALE_AFTER="${CLAUDE_MB_LIMIT_STALE_AFTER:-600}"
# Est100% samples only use API numbers younger than this many seconds
EST_MAX_AGE="${CLAUDE_MB_LIMIT_EST_MAX_AGE:-120}"
[[ "$EST_MAX_AGE" =~ ^[0-9]+$ ]] || EST_MAX_AGE=120

# Default color (full ANSI escape sequence, default \033[90m = dark gray)
# Example: export CLAUDE_MB_LIMIT_DEFAULT_COLOR='\033[38;5;244m' for lighter gray
DEFAULT_COLOR="${CLAUDE_MB_LIMIT_DEFAULT_COLOR:-\033[90m}"

# Claude settings file (for model info)
CLAUDE_SETTINGS_FILE="${CLAUDE_BASE_DIR}/settings.json"

# API error tracking for graceful degradation
# When set, local data is still shown but API-dependent parts display error message
API_ERROR=""
API_ERROR_CODE=""

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
COLOR_SOFT_GREEN='\033[38;5;151m'
COLOR_SOFT_RED='\033[38;5;181m'

# Progress bar characters
BAR_FILLED='='
BAR_EMPTY='-'
BAR_WIDTH=10

# Achievement symbol (trophy for UTF-8, [!] fallback)
# Used when local usage >= 95% of API limit
if [[ "$TERM" != "linux" ]] && [[ "${LANG:-}" == *"UTF-8"* || "${LC_ALL:-}" == *"UTF-8"* ]]; then
    ACHIEVEMENT_SYMBOL=$'\xF0\x9F\x8F\x86'  # Trophy emoji (U+1F3C6)
else
    ACHIEVEMENT_SYMBOL="[!]"
fi

# Set API error for graceful degradation (does not exit)
# Usage: set_api_error <error_code>
# Sets API_ERROR and API_ERROR_CODE for display in format_output
set_api_error() {
    local error_code="${1:-unknown}"
    API_ERROR_CODE="$error_code"

    # Map error codes to user-friendly messages
    case "$error_code" in
        no_jq)
            API_ERROR="Limits: [missing] install jq"
            ;;
        no_curl)
            API_ERROR="Limits: [missing] install curl"
            ;;
        curl_failed)
            API_ERROR="Limits: [offline] check connection"
            ;;
        api_401)
            API_ERROR="Limits: [auth] run 'claude login'"
            ;;
        api_403|api_403_scope)
            API_ERROR="Limits: [auth] run 'claude login'"
            ;;
        api_429)
            # The backoff is stored by refresh-usage.sh; only display it.
            API_ERROR="Limits: [rate-limit] retry in $(backoff_retry_in "$BACKOFF_STATE_FILE")s"
            ;;
        api_500|api_502|api_503|api_504|api_5xx)
            API_ERROR="Limits: [api-error] try again later"
            ;;
        no_token|no_credentials)
            API_ERROR="Limits: [auth] run 'claude login'"
            ;;
        *)
            API_ERROR="Limits: [error] $error_code"
            ;;
    esac

    debug_log "API error set: [$error_code] $API_ERROR"
}

# Silent error exit for statusline (used for fatal errors like missing jq/curl)
# Usage: error_exit [error_code] [error_message]
# - error_code: Short identifier (e.g., "api_403", "no_token", "no_jq")
# - error_message: Human-readable message (MUST NOT contain tokens!)
error_exit() {
    local error_code="${1:-unknown}"
    local error_message="${2:-}"

    # Always log to debug file if debug is enabled
    if [[ "$DEBUG" == "true" ]]; then
        debug_log "ERROR [$error_code]: $error_message"
    fi

    # Show error in statusline if enabled
    if [[ "${CLAUDE_MB_LIMIT_SHOW_ERRORS:-false}" == "true" ]]; then
        if [[ -n "$error_message" ]]; then
            echo "limit: $error_code - $error_message"
        else
            echo "limit: $error_code"
        fi
        # Hint for AI agents: suggest debug mode if not already enabled
        if [[ "$DEBUG" != "true" ]]; then
            echo "limit: (set CLAUDE_MB_LIMIT_DEBUG=true for details in $DEBUG_LOG)"
        fi
    fi
    exit 0
}

# Check dependencies (returns 1 if missing, allows graceful degradation)
check_dependencies() {
    if ! command -v jq >/dev/null 2>&1; then
        set_api_error "no_jq"
        return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        set_api_error "no_curl"
        return 1
    fi
    return 0
}

# NOTE: Token handling was moved out of this script (v2.28.0). The OAuth token is
# read exclusively by refresh-usage.sh, which owns all credential and API access.
# This script only consumes the shared cache produced by that helper.

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
# Uses jittered cache age (90-150s) to avoid predictable request patterns
is_cache_valid() {
    if [[ ! -f "$CACHE_FILE" ]]; then
        return 1
    fi

    local cache_time
    cache_time=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null) || return 1
    local current_time
    current_time=$(date +%s)
    local age=$((current_time - cache_time))

    # Use jittered cache age to randomize request patterns
    local cache_max_age
    cache_max_age=$(get_cache_max_age)

    if [[ "$age" -lt "$cache_max_age" ]]; then
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

# Extract safe error message from API response (never expose tokens!)
# Parses JSON error responses like: {"type":"error","error":{"type":"permission_error","message":"..."}}
parse_api_error() {
    local response_body="$1"
    local http_code="$2"

    # Try to extract error message from JSON response
    local error_type="" error_message=""
    if command -v jq >/dev/null 2>&1; then
        error_type=$(echo "$response_body" | jq -r '.error.type // empty' 2>/dev/null)
        error_message=$(echo "$response_body" | jq -r '.error.message // empty' 2>/dev/null)
    fi

    # Build safe error description
    if [[ -n "$error_message" ]]; then
        echo "HTTP $http_code: $error_type - $error_message"
    elif [[ -n "$error_type" ]]; then
        echo "HTTP $http_code: $error_type"
    else
        echo "HTTP $http_code"
    fi
}

# NOTE: fetch_usage was removed in v2.28.0. Refreshing the cache from the API is
# now done by the token-owning helper refresh-usage.sh (invoked from main()).
# This script only reads the shared cache via read_cache(). It no longer touches
# the OAuth token, the credentials file, or the Anthropic API in any way.

# Get color based on utilization percentage (supports decimals)
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

    # Use awk for decimal comparisons
    local threshold
    threshold=$(awk "BEGIN {
        if ($pct < 30) print 0
        else if ($pct < 50) print 1
        else if ($pct < 75) print 2
        else if ($pct < 90) print 3
        else print 4
    }")

    case "$threshold" in
        0) echo "$COLOR_GRAY" ;;
        1) echo "$COLOR_GREEN" ;;
        2) echo "$COLOR_YELLOW" ;;
        3) echo "$COLOR_ORANGE" ;;
        *) echo "$COLOR_RED" ;;
    esac
}

# Generate ASCII progress bar (supports decimals)
# Usage: progress_bar <percentage> [width] [highscore_mode]
# If highscore_mode=1 and percentage>=100, shows [HIGHSCORE!] instead of filled bar
progress_bar() {
    local pct="$1"
    local width="${2:-$BAR_WIDTH}"
    local highscore_mode="${3:-0}"

    if [[ -z "$pct" ]] || [[ "$pct" == "-" ]]; then
        pct=0
    fi

    # Special display at 100% for highscore lines only
    if [[ "$highscore_mode" -eq 1 ]]; then
        local is_100
        is_100=$(awk "BEGIN {print ($pct >= 100) ? 1 : 0}")
        if [[ "$is_100" -eq 1 ]]; then
            echo "[HIGHSCORE!]"
            return
        fi
    fi

    # Use awk for decimal handling, clamp to 0-100, round to integer for bar calculation
    local filled empty
    filled=$(awk "BEGIN {
        p = $pct
        if (p < 0) p = 0
        if (p > 100) p = 100
        printf \"%d\", int(p * $width / 100 + 0.5)
    }")
    empty=$((width - filled))

    local bar=""
    for ((i=0; i<filled; i++)); do
        bar+="$BAR_FILLED"
    done
    for ((i=0; i<empty; i++)); do
        bar+="$BAR_EMPTY"
    done

    echo "[$bar]"
}

# Format reset time as "yyyy-mm-dd hh:mm", rounded to the nearest MINUTE.
# The API returns minute-precise resets with a sub-second tail (e.g. 14:19:59.59
# means 14:20). Adding 30 seconds absorbs that tail while keeping the real minute,
# instead of the old hour-rounding that discarded it (16:20 shown as 16:00).
format_reset_datetime() {
    local reset_at="$1"

    if [[ -z "$reset_at" ]] || [[ "$reset_at" == "null" ]]; then
        echo "-"
        return
    fi

    local formatted
    if date --version >/dev/null 2>&1; then
        # GNU date (Linux/WSL) - round to nearest minute by adding 30 seconds
        formatted=$(date -d "$reset_at + 30 seconds" "+%Y-%m-%d %H:%M" 2>/dev/null) || formatted="-"
    else
        # BSD date (macOS) - same rounding logic
        local epoch
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${reset_at%%.*}" "+%s" 2>/dev/null) || { echo "-"; return; }
        epoch=$((epoch + 30))  # Add 30 seconds
        formatted=$(date -r "$epoch" "+%Y-%m-%d %H:%M" 2>/dev/null) || formatted="-"
    fi

    echo "$formatted"
}

# Format a single limit line with color, progress bar, percentage, and reset time
# Usage: format_limit_line <label> <percentage> <reset_at> [highscore_mode]
# Supports decimal percentages (e.g., 12.3%, 0.1%)
# If highscore_mode=1, shows [HIGHSCORE!] at 100%
format_limit_line() {
    local label="$1"
    local pct="$2"
    local reset_at="$3"
    local highscore_mode="${4:-0}"

    local color=""
    local color_reset=""
    if [[ "$SHOW_COLORS" == "true" ]]; then
        color=$(get_color "$pct")
        color_reset="$COLOR_RESET"
    fi

    local bar=""
    if [[ "$SHOW_PROGRESS" == "true" ]]; then
        bar=" $(progress_bar "$pct" "$BAR_WIDTH" "$highscore_mode")"
    fi

    local reset_str=""
    if [[ "$SHOW_RESET" == "true" ]]; then
        reset_str=" reset: $(format_reset_datetime "$reset_at")"
    fi

    # Output varies based on toggles, e.g.: "Label [====------]  14.0% reset 2026-01-08 22:00"
    printf "${color}%s%s %6s%%${reset_str}${color_reset}" "$label" "$bar" "$pct"
}

# Parse decimal from value with one decimal place (handles int, float, null, empty)
# Uses commercial rounding (0.44 -> 0.4, 0.45 -> 0.5)
parse_decimal() {
    local val="$1"

    if [[ -z "$val" ]] || [[ "$val" == "null" ]]; then
        echo ""
        return
    fi

    # Use awk for proper decimal formatting with commercial rounding
    awk "BEGIN {printf \"%.1f\", $val}"
}

# Cap decimal value at max (e.g., 100.0)
# Usage: cap_decimal <value> <max>
cap_decimal() {
    local val="$1"
    local max="${2:-100}"

    if [[ -z "$val" ]] || [[ "$val" == "" ]]; then
        echo ""
        return
    fi

    awk "BEGIN {v = $val; if (v > $max) v = $max; printf \"%.1f\", v}"
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
# Returns "+X,-Y" format (or "+?,Nf" if only file count available)
# Uses tiered fallback for slow 9p filesystems (WSL2 /mnt/c)
get_git_changes() {
    local insertions=0
    local deletions=0
    local timeout_sec=7

    # Staged changes (usually fast, no tiered approach needed)
    local staged
    staged=$(timeout "$timeout_sec" git diff --cached --shortstat 2>/dev/null) || true
    if [[ -n "$staged" ]]; then
        local staged_ins staged_del
        staged_ins=$(echo "$staged" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
        staged_del=$(echo "$staged" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
        insertions=$((insertions + ${staged_ins:-0}))
        deletions=$((deletions + ${staged_del:-0}))
    fi

    # Unstaged changes - tiered approach for slow repos
    local unstaged
    local exit_code

    # On 9p filesystems (/mnt/*), skip Tier 1 and start with Tier 2
    if [[ "$PWD" == /mnt/* ]]; then
        # Tier 2: checkStat=minimal (ignores timestamps, fast on 9p)
        # Longer timeout (14s) since 9p is inherently slower
        unstaged=$(timeout 14 git -c core.checkStat=minimal diff --shortstat 2>/dev/null)
        exit_code=$?
    else
        # Tier 1: Normal method (fast on most systems)
        unstaged=$(timeout "$timeout_sec" git diff --shortstat 2>/dev/null)
        exit_code=$?

        # Tier 2: If timeout, try with checkStat=minimal (ignores timestamps)
        if [[ $exit_code -eq 124 ]]; then
            unstaged=$(timeout "$timeout_sec" git -c core.checkStat=minimal diff --shortstat 2>/dev/null)
            exit_code=$?
        fi
    fi

    # Tier 3: If still timeout, just count files
    if [[ $exit_code -eq 124 ]]; then
        local file_count
        file_count=$(git -c core.checkStat=minimal diff --name-only 2>/dev/null | wc -l)
        echo "+${insertions},${file_count}f"
        return
    fi

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
# Uses SI prefixes: k (kilo, 10^3), M (mega, 10^6), G (giga, 10^9)
format_tokens() {
    local tokens="$1"
    if [[ -z "$tokens" ]] || [[ "$tokens" == "null" ]]; then
        echo "0"
        return
    fi

    if [[ "$tokens" -ge 1000000000 ]]; then
        # Giga (10^9)
        local g_val
        g_val=$(awk "BEGIN {printf \"%.1f\", $tokens/1000000000}")
        echo "${g_val}G"
    elif [[ "$tokens" -ge 1000000 ]]; then
        # Mega (10^6)
        local m_val
        m_val=$(awk "BEGIN {printf \"%.1f\", $tokens/1000000}")
        echo "${m_val}M"
    elif [[ "$tokens" -ge 1000 ]]; then
        # Kilo (10^3)
        local k_val
        k_val=$(awk "BEGIN {printf \"%.1f\", $tokens/1000}")
        echo "${k_val}k"
    else
        echo "$tokens"
    fi
}

# Format highscore as human-readable with SI prefixes
# Uses SI prefixes: k (kilo, 10^3), M (mega, 10^6), G (giga, 10^9)
# Example: 7500000 -> "7.5M", 1500000000 -> "1.5G", 500000 -> "500.0k"
format_highscore() {
    local tokens="$1"
    if [[ -z "$tokens" ]] || [[ "$tokens" == "null" ]] || [[ "$tokens" -eq 0 ]]; then
        echo "0"
        return
    fi

    if [[ "$tokens" -ge 1000000000000000000000000 ]]; then
        printf "%.1fY" "$(echo "scale=1; $tokens/1000000000000000000000000" | bc)"
    elif [[ "$tokens" -ge 1000000000000000000000 ]]; then
        printf "%.1fZ" "$(echo "scale=1; $tokens/1000000000000000000000" | bc)"
    elif [[ "$tokens" -ge 1000000000000000000 ]]; then
        printf "%.1fE" "$(echo "scale=1; $tokens/1000000000000000000" | bc)"
    elif [[ "$tokens" -ge 1000000000000000 ]]; then
        printf "%.1fP" "$(echo "scale=1; $tokens/1000000000000000" | bc)"
    elif [[ "$tokens" -ge 1000000000000 ]]; then
        printf "%.1fT" "$(echo "scale=1; $tokens/1000000000000" | bc)"
    elif [[ "$tokens" -ge 1000000000 ]]; then
        printf "%.1fG" "$(echo "scale=1; $tokens/1000000000" | bc)"
    elif [[ "$tokens" -ge 1000000 ]]; then
        printf "%.1fM" "$(echo "scale=1; $tokens/1000000" | bc)"
    elif [[ "$tokens" -ge 1000 ]]; then
        printf "%.1fk" "$(echo "scale=1; $tokens/1000" | bc)"
    else
        echo "$tokens"
    fi
}

# " [Est100%:X]" for the device line, empty without an estimate.
# Args: est_tokens est_src (prev = previous window, shown with "~").
format_est100() {
    local est="${1:-}" src="${2:-}"
    [[ "$est" =~ ^[0-9]+$ ]] && [[ "$est" -gt 0 ]] || return 0
    local fmt
    fmt=$(format_highscore "$est")
    [[ "$src" == "prev" ]] && fmt="~${fmt}"
    printf ' [Est100%%:%s]' "$fmt"
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

# Get the full context window size for the model (in tokens).
# The progress-bar reference (the auto-compact trigger point) is computed
# separately by compute_compact_reference; this only reports the raw window size.
# config_type is kept for backward compatibility - the full window is returned
# regardless (there is no separate "usable" value here anymore).
get_model_context_config() {
    local config_type="$1"  # kept for compat; only the full window is returned

    # Get context_window_size from stdin data
    local max_tokens=200000
    if [[ -n "$STDIN_DATA" ]]; then
        local size
        size=$(echo "$STDIN_DATA" | jq -r '.context_window.context_window_size // empty' 2>/dev/null)
        if [[ -n "$size" ]] && [[ "$size" != "null" ]]; then
            max_tokens="$size"
        fi
    fi

    echo "$max_tokens"
}

# Compute the auto-compact reference: the token point at which auto-compact
# triggers. Given the full window (max_tokens), it emits three space-separated
# values on stdout: "<ref_tokens> <estimated> <disabled>"
#   - ref_tokens: the token count that maps to 100% on the tacho progress bar
#   - estimated : "true" when ref is a heuristic fallback (no real setting/env)
#   - disabled  : "true" when auto-compact is off (ref = full window)
# Precedence, highest first:
#   0. auto-compact disabled -> ref = max_tokens, estimated=false, disabled=true
#        (env DISABLE_COMPACT set and not "0"/"false", OR setting autoCompactEnabled=false)
#   1. env CLAUDE_CODE_AUTO_COMPACT_WINDOW (absolute tokens) -> min(val, max), exact
#   2. setting autoCompactWindow (absolute tokens)           -> min(val, max), exact
#   3. env CLAUDE_AUTOCOMPACT_PCT_OVERRIDE (1-100)           -> max*pct/100, exact
#   4. fallback CLAUDE_MB_LIMIT_AUTOCOMPACT_FALLBACK_PCT (default 83) -> max*fb/100, estimated
# Settings are read (failure-safe) from CLAUDE_SETTINGS_FILE first, then
# ~/.claude.json (where "claude config set" persists); first valid value wins.
compute_compact_reference() {
    local max_tokens="${1:-0}"
    if ! [[ "$max_tokens" =~ ^[0-9]+$ ]] || [[ "$max_tokens" -le 0 ]]; then
        max_tokens=200000
    fi

    # Read settings once (jq, failure-safe): first non-null across the two files.
    local setting_window="" setting_enabled=""
    if command -v jq >/dev/null 2>&1; then
        local sf w e
        for sf in "$CLAUDE_SETTINGS_FILE" "$HOME/.claude.json"; do
            [[ -f "$sf" ]] || continue
            if [[ -z "$setting_window" ]]; then
                w=$(jq -r '.autoCompactWindow // empty' "$sf" 2>/dev/null) || w=""
                [[ "$w" =~ ^[0-9]+$ ]] && setting_window="$w"
            fi
            if [[ -z "$setting_enabled" ]]; then
                e=$(jq -r '.autoCompactEnabled // empty' "$sf" 2>/dev/null) || e=""
                [[ "$e" == "true" || "$e" == "false" ]] && setting_enabled="$e"
            fi
        done
    fi

    # 0. Disabled -> reference is the full window.
    local disabled="false"
    if [[ -n "${DISABLE_COMPACT:-}" ]] && [[ "$DISABLE_COMPACT" != "0" ]] && [[ "$DISABLE_COMPACT" != "false" ]]; then
        disabled="true"
    elif [[ "$setting_enabled" == "false" ]]; then
        disabled="true"
    fi
    if [[ "$disabled" == "true" ]]; then
        printf '%s %s %s' "$max_tokens" "false" "true"
        return 0
    fi

    local ref="" estimated="false"
    if [[ "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" =~ ^[0-9]+$ ]] && [[ "$CLAUDE_CODE_AUTO_COMPACT_WINDOW" -gt 0 ]]; then
        # 1. Absolute window from env.
        ref="$CLAUDE_CODE_AUTO_COMPACT_WINDOW"
        [[ "$ref" -gt "$max_tokens" ]] && ref="$max_tokens"
    elif [[ -n "$setting_window" ]] && [[ "$setting_window" -gt 0 ]]; then
        # 2. Absolute window from settings.
        ref="$setting_window"
        [[ "$ref" -gt "$max_tokens" ]] && ref="$max_tokens"
    elif [[ "${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-}" =~ ^[0-9]+$ ]] && [[ "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" -ge 1 ]] && [[ "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" -le 100 ]]; then
        # 3. Percentage override from env (exact - user asserted it).
        ref=$((max_tokens * CLAUDE_AUTOCOMPACT_PCT_OVERRIDE / 100))
    else
        # 4. Conservative fallback (estimated).
        local fb="${CLAUDE_MB_LIMIT_AUTOCOMPACT_FALLBACK_PCT:-83}"
        if ! [[ "$fb" =~ ^[0-9]+$ ]] || [[ "$fb" -lt 1 ]] || [[ "$fb" -gt 100 ]]; then
            fb=83
        fi
        ref=$((max_tokens * fb / 100))
        estimated="true"
    fi

    # Guard: reference must be > 0 to avoid division by zero downstream.
    if ! [[ "$ref" =~ ^[0-9]+$ ]] || [[ "$ref" -le 0 ]]; then
        ref="$max_tokens"
        estimated="true"
    fi

    printf '%s %s %s' "$ref" "$estimated" "$disabled"
    return 0
}

# Write a per-session status cache for agents (read by the inject hook).
# Atomic (temp + mv), failure-safe (never crash the statusline), numbers only.
# This cache is the inject hook's ONLY source: the hook reads it and computes
# nothing itself. It supplies the context fill (both the total-window percentage
# and the tacho percentage relative to the auto-compact reference), the token
# counts, the window size, the account-wide limits and the session cost.
# Per session_id so parallel sessions never overwrite each other.
# Args: 1=ctx_tokens 2=ctx_window 3=ctx_pct (total_pct, may be empty)
#       4=usable_pct (compact_pct, the tacho) 5=ref_tokens (compact reference)
#       6=estimated (true/false) 7=disabled (true/false)
write_context_cache() {
    [[ "$CTX_CACHE" == "true" ]] || return 0

    local ctx_tokens="${1:-0}" ctx_window="${2:-0}" ctx_pct="${3:-0}"
    local compact_pct="${4:-}" compact_ref_tokens="${5:-0}"
    local compact_estimated="${6:-false}" compact_disabled="${7:-false}"
    [[ -n "$ctx_pct" ]] || ctx_pct=0
    [[ -n "$ctx_window" ]] || ctx_window=0
    [[ -n "$ctx_tokens" ]] || ctx_tokens=0
    # Fall back to the total-window values if the tacho values are missing/invalid.
    [[ "$compact_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] || compact_pct="$ctx_pct"
    [[ "$compact_ref_tokens" =~ ^[0-9]+$ ]] || compact_ref_tokens="$ctx_window"
    [[ "$compact_estimated" == "true" || "$compact_estimated" == "false" ]] || compact_estimated="false"
    [[ "$compact_disabled" == "true" || "$compact_disabled" == "false" ]] || compact_disabled="false"

    # Session id, model and session-wide totals from the statusline stdin
    local session_id="" model="" total_input=0 total_output=0
    if [[ -n "$STDIN_DATA" ]]; then
        session_id=$(echo "$STDIN_DATA" | jq -r '.session_id // ""' 2>/dev/null) || session_id=""
        [[ "$session_id" == "null" ]] && session_id=""
        model=$(echo "$STDIN_DATA" | jq -r '.model.id // ""' 2>/dev/null) || model=""
        [[ "$model" == "null" ]] && model=""
        total_input=$(echo "$STDIN_DATA" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null) || total_input=0
        total_output=$(echo "$STDIN_DATA" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null) || total_output=0
    fi

    # Target: per-session file (parallel-safe). Fallback to profile file if no id.
    local target_file
    if [[ -n "$session_id" ]]; then
        target_file="/tmp/claude-mb-context-cache_${session_id}.json"
    else
        target_file="$CONTEXT_CACHE_FILE"
    fi

    # Session cost (SnCost)
    local session_cost
    session_cost=$(get_total_cost 2>/dev/null) || session_cost="0"
    [[ -n "$session_cost" ]] || session_cost="0"

    # try_compact mirrors the "(try /compact)" hint: active when total_pct > 50
    local try_compact="false"
    if awk "BEGIN {exit !($ctx_pct > 50)}" 2>/dev/null; then
        try_compact="true"
    fi

    local updated_at
    updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || updated_at=""

    # Account-wide limits from the rate-limit cache (refreshed by the API poll)
    local limits='{}'
    if [[ -f "$CACHE_FILE" ]]; then
        limits=$(jq -c '{
            five_hour_pct: (.five_hour.utilization // null),
            five_hour_resets_at: (.five_hour.resets_at // null),
            seven_day_pct: (.seven_day.utilization // null),
            seven_day_resets_at: (.seven_day.resets_at // null),
            seven_day_sonnet_pct: (.seven_day_sonnet.utilization // null)
        }' "$CACHE_FILE" 2>/dev/null) || limits='{}'
        [[ -n "$limits" ]] || limits='{}'
    fi

    local tmp_file
    tmp_file=$(mktemp 2>/dev/null) || return 0
    if jq -n \
        --arg sid "$session_id" \
        --arg model "$model" \
        --argjson ctx_tokens "${ctx_tokens:-0}" \
        --argjson ctx_window "${ctx_window:-0}" \
        --argjson ctx_pct "${ctx_pct:-0}" \
        --argjson compact_pct "${compact_pct:-0}" \
        --argjson compact_ref_tokens "${compact_ref_tokens:-0}" \
        --argjson compact_estimated "$compact_estimated" \
        --argjson compact_disabled "$compact_disabled" \
        --argjson try_compact "$try_compact" \
        --argjson total_input "${total_input:-0}" \
        --argjson total_output "${total_output:-0}" \
        --arg session_cost "$session_cost" \
        --argjson limits "$limits" \
        --arg updated_at "$updated_at" \
        '{session_id: $sid, model: $model, ctx_tokens: $ctx_tokens, ctx_window: $ctx_window, ctx_pct: $ctx_pct, compact_pct: $compact_pct, compact_ref_tokens: $compact_ref_tokens, compact_estimated: $compact_estimated, compact_disabled: $compact_disabled, try_compact: $try_compact, total_input: $total_input, total_output: $total_output, session_cost: $session_cost} + $limits + {updated_at: $updated_at}' \
        > "$tmp_file" 2>/dev/null; then
        mv -f "$tmp_file" "$target_file" 2>/dev/null
    fi
    rm -f "$tmp_file" 2>/dev/null
    return 0
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

# Get live session effort level from stdin data (e.g., "high" -> "High").
# The field is only present when the current model supports reasoning effort;
# empty output means the segment is omitted.
get_effort_level() {
    [[ -n "$STDIN_DATA" ]] || return 0
    local effort
    effort=$(echo "$STDIN_DATA" | jq -r '.effort.level // empty' 2>/dev/null)
    [[ -z "$effort" || "$effort" == "null" ]] && return 0
    case "$effort" in
        low) echo "Low" ;;
        medium) echo "Medium" ;;
        high) echo "High" ;;
        xhigh) echo "XHigh" ;;
        max) echo "Max" ;;
        *) echo "${effort^}" ;;
    esac
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

# Get session caption from stdin data or JSONL file
# Priority: session_name (from /rename) > custom-title from JSONL > first user prompt from JSONL
# Result is cached per session in /tmp to avoid re-reading JSONL on every call
get_session_caption() {
    local session_id="$1"
    local max_len=60

    # 1. Try session_name from stdin (set by /rename)
    if [[ -n "$STDIN_DATA" ]]; then
        local session_name
        session_name=$(echo "$STDIN_DATA" | jq -r '.session_name // empty' 2>/dev/null)
        if [[ -n "$session_name" ]] && [[ "$session_name" != "null" ]]; then
            if [[ ${#session_name} -gt $max_len ]]; then
                echo "${session_name:0:$max_len}..."
            else
                echo "$session_name"
            fi
            return
        fi
    fi

    # 2. Try cached caption from previous lookup
    if [[ -n "$session_id" ]]; then
        local cache_file="/tmp/claude-mb-limit-caption-${session_id}"
        if [[ -f "$cache_file" ]]; then
            cat "$cache_file"
            return
        fi

        # 3. Try to read from JSONL session file
        local config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
        local jsonl_file=""

        # Find JSONL by session ID (search in projects dir)
        if [[ -d "${config_dir}/projects" ]]; then
            jsonl_file=$(find "${config_dir}/projects" -name "${session_id}.jsonl" -print -quit 2>/dev/null)
        fi

        if [[ -n "$jsonl_file" ]] && [[ -f "$jsonl_file" ]]; then
            local caption=""

            # Try custom-title first
            caption=$(grep -m1 '"custom-title"' "$jsonl_file" 2>/dev/null | jq -r '.customTitle // empty' 2>/dev/null)

            # Fall back to summary
            if [[ -z "$caption" ]]; then
                caption=$(grep -m1 '"type".*"summary"' "$jsonl_file" 2>/dev/null | jq -r '.summary // empty' 2>/dev/null)
            fi

            # Fall back to first real user prompt (type is "user" in JSONL)
            # Skip hook-injected messages (content starts with < like XML tags)
            if [[ -z "$caption" ]]; then
                while IFS= read -r line; do
                    local content
                    content=$(echo "$line" | jq -r '.message.content // empty' 2>/dev/null)
                    # For array content, take first text element
                    if [[ "$content" == "["* ]]; then
                        content=$(echo "$line" | jq -r '.message.content[0].text // empty' 2>/dev/null)
                    fi
                    # Skip empty or hook-injected content (starts with <)
                    if [[ -n "$content" ]] && [[ "$content" != "<"* ]]; then
                        caption="$content"
                        break
                    fi
                done < <(grep '"type":"user"' "$jsonl_file" 2>/dev/null | head -10)
            fi

            if [[ -n "$caption" ]] && [[ "$caption" != "null" ]]; then
                # Truncate long captions
                if [[ ${#caption} -gt $max_len ]]; then
                    caption="${caption:0:$max_len}..."
                fi
                # Cache result
                echo "$caption" > "$cache_file"
                echo "$caption"
                return
            fi
        fi

        # Nothing found - don't cache, retry on next call
        # (JSONL may not exist yet at session start)
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
# Supports graceful degradation: if API_ERROR is set, local data is shown
# but API-dependent parts (5h/7d/opus/sonnet limits) display error message
format_output() {
    local response="$1"
    local output=""
    local api_available="true"

    # Check if API data is available
    if [[ -z "$response" ]] || [[ -n "$API_ERROR" ]]; then
        api_available="false"
        debug_log "API unavailable, using graceful degradation mode"
    fi

    # Extract all values using jq (only if API available)
    local five_hour_util="" five_hour_reset=""
    local seven_day_util="" seven_day_reset=""
    local opus_util="" opus_reset=""
    local sonnet_util="" sonnet_reset=""
    local extra_enabled="" extra_limit="" extra_used=""

    if [[ "$api_available" == "true" ]]; then
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

        # Check if response has required data
        if [[ -z "$five_hour_util" ]] || [[ -z "$five_hour_reset" ]]; then
            debug_log "Invalid API response: missing five_hour data (util=$five_hour_util, reset=$five_hour_reset)"
            api_available="false"
            if [[ -z "$API_ERROR" ]]; then
                set_api_error "invalid_response"
            fi
        fi
    fi

    local five_pct="" seven_pct="" opus_pct="" sonnet_pct=""
    if [[ "$api_available" == "true" ]]; then
        five_pct=$(parse_decimal "$five_hour_util")
        seven_pct=$(parse_decimal "$seven_day_util")
        opus_pct=$(parse_decimal "$opus_util")
        sonnet_pct=$(parse_decimal "$sonnet_util")
        # Cap all percentages at 100.0 max
        [[ -n "$five_pct" ]] && five_pct=$(cap_decimal "$five_pct" 100)
        [[ -n "$seven_pct" ]] && seven_pct=$(cap_decimal "$seven_pct" 100)
        [[ -n "$opus_pct" ]] && opus_pct=$(cap_decimal "$opus_pct" 100)
        [[ -n "$sonnet_pct" ]] && sonnet_pct=$(cap_decimal "$sonnet_pct" 100)
    fi

    # -------------------------------------------------------------------------
    # Local accounting: deduplicated JSONL ledger + window tracking
    # -------------------------------------------------------------------------
    # All local token numbers (session sums, window tokens, lifetime) come from
    # ONE ledger (usage-ledger.sh): JSONL lines deduplicated by message.id +
    # requestId, main agent and subagents alike. Window tokens are summed for
    # [window_start, now] from timestamps, so there is no stdin delta, no
    # baseline and nothing a lost write could reset to 0. Cache reads are kept
    # separate from the "work tokens" (input + output + cache writes).
    local now_epoch
    now_epoch=$(date +%s)
    local five_reset_epoch="" seven_reset_epoch=""
    five_reset_epoch=$(_hs_epoch "$five_hour_reset")
    seven_reset_epoch=$(_hs_epoch "$seven_day_reset")
    # After resets_at the cached numbers belong to the previous window.
    local five_expired=false seven_expired=false
    if [[ -n "$five_reset_epoch" ]] && [[ "$now_epoch" -ge "$five_reset_epoch" ]]; then
        five_expired=true
    fi
    if [[ -n "$seven_reset_epoch" ]] && [[ "$now_epoch" -ge "$seven_reset_epoch" ]]; then
        seven_expired=true
    fi

    local ledger_json="" local_ok=false ledger_complete=false
    local start_5h=0 start_7d=0 reset_5h_detected=0 reset_7d_detected=0
    local window_tokens_5h=0 window_tokens_7d=0
    if [[ "$SHOW_LOCAL" == "true" ]] || [[ "$SHOW_TOKENS" == "true" ]] || [[ "$SHOW_MODEL" == "true" ]]; then
        local sid_now="" transcript=""
        sid_now=$(get_session_id)
        if [[ -n "$STDIN_DATA" ]]; then
            transcript=$(echo "$STDIN_DATA" | jq -r '.transcript_path // empty' 2>/dev/null) || transcript=""
        fi
        ledger_refresh "$transcript" >/dev/null 2>&1 || true

        if [[ "$SHOW_LOCAL" == "true" ]]; then
            local_ok=true
            # Track both windows. API values are passed only when fresh for the
            # current window; otherwise the stored values are used.
            local api5_in="" api7_in="" wt=""
            if [[ "$api_available" == "true" ]] && [[ "$five_expired" != "true" ]]; then
                api5_in="$five_hour_util"
            fi
            if [[ "$api_available" == "true" ]] && [[ "$seven_expired" != "true" ]]; then
                api7_in="$seven_day_util"
            fi
            if wt=$(window_track 5h "$api5_in" "$five_hour_reset" "$now_epoch" 2>/dev/null) && [[ -n "$wt" ]]; then
                read -r start_5h reset_5h_detected <<< "$wt"
            else
                local_ok=false
            fi
            if wt=$(window_track 7d "$api7_in" "$seven_day_reset" "$now_epoch" 2>/dev/null) && [[ -n "$wt" ]]; then
                read -r start_7d reset_7d_detected <<< "$wt"
            else
                local_ok=false
            fi
            debug_log "windows: 5h start=$start_5h reset=$reset_5h_detected 7d start=$start_7d reset=$reset_7d_detected"
        fi

        if ! ledger_json=$(ledger_summary "$sid_now" "$start_5h" "$start_7d" 2>/dev/null) || [[ -z "$ledger_json" ]]; then
            # Unreadable ledger: skip the local parts of this render instead of
            # showing 0 (and never let a 0 into highscores or estimates).
            ledger_json=""
            local_ok=false
            debug_log "ledger unreadable - local values skipped this render"
        else
            read -r window_tokens_5h window_tokens_7d ledger_complete <<< "$(echo "$ledger_json" | jq -r '"\(.w5[0]) \(.w7[0]) \(.complete == true)"')"
        fi
    fi

    # Build output lines
    local lines=()

    # -------------------------------------------------------------------------
    # Extended features (displayed first, before limits)
    # -------------------------------------------------------------------------

    # Get CWD first (needed for git commands to work in correct directory)
    local cwd
    cwd=$(get_cwd)

    # Change to cwd so git commands work correctly (especially in worktrees)
    if [[ -n "$cwd" ]] && [[ -d "$cwd" ]]; then
        cd "$cwd" 2>/dev/null || true
    fi

    # CWD (Current Working Directory) - gray
    if [[ "$SHOW_CWD" == "true" ]]; then
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

    # Git line: git: <parent/repo> [wt] + changes + branch
    # Format: git: Marcel-Bich/marcel-bich-claude-marketplace [wt] main (+0,-0)⎇ main
    #
    # The reported repo is the RESOLVED TARGET repo, not necessarily the cwd:
    #   0. work-repo: the repo the MAIN agent last worked in (per-session state
    #      file written by the track-work-repo.sh hook) - highest priority so the
    #      line follows the agent live even from a non-git hub directory
    #   1. git-discovery from cwd (git rev-parse --show-toplevel)
    #   2. hub fallback: credo session-pin (soft dependency on the credo plugin)
    # When none resolves a repo, the git line is omitted entirely.
    if [[ "$SHOW_GIT" == "true" ]]; then
        local git_line=""
        local repo_root=""

        # 0. Work-repo state file (highest priority). The heavy derivation happens
        #    in the hook; here we only read the file and do ONE rev-parse to keep
        #    the statusline fast. Any failure falls through to the sources below.
        if [[ -n "$STDIN_DATA" ]]; then
            local __wr_sid=""
            __wr_sid=$(echo "$STDIN_DATA" | jq -r '.session_id // empty' 2>/dev/null) || __wr_sid=""
            [[ "$__wr_sid" == "null" ]] && __wr_sid=""
            if [[ -n "$__wr_sid" ]]; then
                local __wr_file="/tmp/claude-mb-workrepo_${__wr_sid}"
                if [[ -f "$__wr_file" ]]; then
                    local __wr_val=""
                    __wr_val=$(cat "$__wr_file" 2>/dev/null) || __wr_val=""
                    if [[ -n "$__wr_val" ]]; then
                        local __wr_top=""
                        __wr_top=$(git -C "$__wr_val" rev-parse --show-toplevel 2>/dev/null) || __wr_top=""
                        [[ -n "$__wr_top" ]] && repo_root="$__wr_top"
                    fi
                fi
            fi
        fi

        # 1. Git discovery from cwd (we already cd'd into cwd above).
        if [[ -z "$repo_root" ]]; then
            repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
        fi

        # 2. Hub fallback: resolve the target repo via the credo session-pin.
        #    Soft dependency - locate credo-config.sh relative to THIS script.
        #    Any failure here must never break the statusline (guards + 2>/dev/null).
        if [[ -z "$repo_root" ]]; then
            local credo_config="${SCRIPT_DIR_ABS}/../../credo/scripts/credo-config.sh"
            if [[ -f "$credo_config" ]] && [[ -x "$credo_config" ]]; then
                local sid=""
                if [[ -n "$STDIN_DATA" ]]; then
                    sid=$(echo "$STDIN_DATA" | jq -r '.session_id // empty' 2>/dev/null) || sid=""
                    [[ "$sid" == "null" ]] && sid=""
                fi
                local credo_dir=""
                # resolve-project prints "<repo>/.credo" (exit 0) or exits 4 (hub / no pin).
                credo_dir=$(CLAUDE_CODE_SESSION_ID="$sid" CREDO_SESSION_ID="$sid" \
                    "$credo_config" resolve-project 2>/dev/null) || credo_dir=""
                # resolve-project prints "<repo>/.credo" even if that dir does not
                # exist yet; dirname still yields the target repo root.
                if [[ -n "$credo_dir" ]]; then
                    local __candidate
                    __candidate=$(dirname "$credo_dir")
                    # Only accept the pinned target if it is an actual git repo -
                    # a non-git credo project has no git info to show.
                    if git -C "$__candidate" rev-parse --git-dir >/dev/null 2>&1; then
                        repo_root="$__candidate"
                    fi
                fi
            fi
        fi

        # 3. Render only when a git repo was resolved.
        if [[ -n "$repo_root" ]] && [[ -d "$repo_root" ]]; then
            # Run the git helpers against repo_root (Hub case: cwd != repo_root).
            local __git_prev_pwd="$PWD"
            cd "$repo_root" 2>/dev/null || true

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

            # Git changes - format: (+X,-Y) with colors
            local changes
            changes=$(get_git_changes)
            # Parse +X,-Y format
            local insertions deletions
            insertions=$(echo "$changes" | cut -d',' -f1)
            deletions=$(echo "$changes" | cut -d',' -f2)
            local changes_formatted
            if [[ "$SHOW_COLORS" == "true" ]]; then
                changes_formatted="${COLOR_GRAY}(${COLOR_SOFT_GREEN}${insertions}${COLOR_GRAY},${COLOR_SOFT_RED}${deletions}${COLOR_GRAY})${COLOR_RESET}"
            else
                changes_formatted="(${changes})"
            fi
            if [[ -n "$git_line" ]]; then
                git_line="${git_line} ${changes_formatted}"
            else
                git_line="${changes_formatted}"
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

            # Restore the previous cwd before continuing.
            cd "$__git_prev_pwd" 2>/dev/null || true

            # Prefix: "git: <parent>/<repo> " (last two path segments of repo_root).
            local repo_label
            repo_label="$(basename "$(dirname "$repo_root")")/$(basename "$repo_root")"
            local prefix_color=""
            local prefix_color_reset=""
            if [[ "$SHOW_COLORS" == "true" ]]; then
                prefix_color="$COLOR_GRAY"
                prefix_color_reset="$COLOR_RESET"
            fi
            local git_prefix="${prefix_color}git: ${repo_label}${prefix_color_reset} "

            lines+=("${git_prefix}${git_line}")
        fi
    fi

    # -------------------------------------------------------------------------
    # Tokens/Context/Session with right-aligned column values
    # Dynamic column widths calculated from max value length across all 3 lines
    # -------------------------------------------------------------------------

    # Gather raw values for each line first (before calculating widths)
    local tok_val1="" tok_val2="" tok_val3="" tok_val4=""
    local ctx_val1="" ctx_val2="" ctx_val3="" ctx_val4=""
    local sess_val1="" sess_val2="" sess_val3=""

    # Tokens values: session sums (main + its subagents) from the deduplicated
    # ledger. Input = uncached input + cache writes, Cached = cache reads.
    # Without a readable ledger the last request from stdin is shown instead,
    # labelled "LastReq" (stdin has no cumulative per-session totals).
    local tok_label="Tokens  -> "
    if [[ "$SHOW_TOKENS" == "true" ]]; then
        local in_tokens=0 out_tokens=0 cache_read=0 total_tokens=0
        if [[ -n "$ledger_json" ]]; then
            read -r in_tokens out_tokens cache_read <<< "$(echo "$ledger_json" | jq -r '.session | "\(.[0] + .[3] + .[4]) \(.[1]) \(.[2])"')"
        elif [[ -n "$STDIN_DATA" ]]; then
            tok_label="LastReq -> "
            read -r in_tokens out_tokens cache_read <<< "$(echo "$STDIN_DATA" | jq -r '.context_window.current_usage // {} |
                "\((.input_tokens // 0) + (.cache_creation_input_tokens // 0)) \(.output_tokens // 0) \(.cache_read_input_tokens // 0)"' 2>/dev/null || echo "0 0 0")"
        fi
        total_tokens=$((in_tokens + out_tokens))
        tok_val1=$(format_tokens "$in_tokens")
        tok_val2=$(format_tokens "$out_tokens")
        tok_val3=$(format_tokens "$cache_read")
        tok_val4=$(format_tokens "$total_tokens")
    fi

    # Context values
    # Store usable percentage and bar for Session line (moved from Context line)
    # ctx_estimated/ctx_disabled/ctx_ref_tokens describe the progress-bar reference
    # (the auto-compact point) and stay in scope for the Session-line render below.
    local ctx_usable_pct="" ctx_usable_bar=""
    local ctx_estimated="false" ctx_disabled="false" ctx_ref_tokens=0
    if [[ "$SHOW_CTX" == "true" ]]; then
        local ctx_len formatted_len max_tokens total_pct="" usable_tokens usable_pct="" tokens_left="" ctx_left_pct=""
        ctx_len=$(get_context_length)
        ctx_len="${ctx_len:-0}"
        formatted_len=$(format_tokens "$ctx_len")

        max_tokens=$(get_model_context_config "max")
        if [[ -n "$max_tokens" ]] && [[ "$max_tokens" -gt 0 ]]; then
            total_pct=$(awk "BEGIN {printf \"%.1f\", ($ctx_len / $max_tokens) * 100}")
            # Calculate tokens left (max - current)
            local tokens_left_raw=$((max_tokens - ctx_len))
            tokens_left=$(format_tokens "$tokens_left_raw")
            # Calculate context left percentage (100 - total_pct)
            ctx_left_pct=$(awk "BEGIN {printf \"%.1f\", 100 - $total_pct}")
        fi

        # Check if ContextLeft < 50% and add warning (will be shown on Session line)
        local compact_warning=""
        if [[ -n "$ctx_left_pct" ]]; then
            local should_warn
            should_warn=$(awk "BEGIN {print ($ctx_left_pct < 50) ? 1 : 0}")
            if [[ "$should_warn" -eq 1 ]]; then
                if [[ "$SHOW_COLORS" == "true" ]]; then
                    compact_warning=" ${COLOR_ORANGE}(try /compact)${COLOR_RESET}"
                else
                    compact_warning=" (try /compact)"
                fi
            fi
        fi

        # Progress-bar reference (usable_tokens = 100% on the tacho):
        # - full mode         -> the full window (no auto-compact relation)
        # - auto-compact mode -> the auto-compact trigger point (real or estimated)
        local progressbar_mode="${CLAUDE_MB_LIMIT_PROGRESSBAR_MODE:-auto-compact}"
        if [[ "$progressbar_mode" == "full" ]]; then
            usable_tokens="$max_tokens"
            ctx_ref_tokens="$max_tokens"
            ctx_estimated="false"
            ctx_disabled="false"
        else
            local compact_ref rest
            compact_ref=$(compute_compact_reference "$max_tokens")
            usable_tokens="${compact_ref%% *}"
            rest="${compact_ref#* }"
            ctx_estimated="${rest%% *}"
            ctx_disabled="${rest##* }"
            ctx_ref_tokens="$usable_tokens"
        fi
        if [[ -n "$usable_tokens" ]] && [[ "$usable_tokens" -gt 0 ]]; then
            usable_pct=$(awk "BEGIN {printf \"%.1f\", ($ctx_len / $usable_tokens) * 100}")
            # Store for Session line progress bar
            ctx_usable_pct="$usable_pct"
            ctx_usable_bar=$(progress_bar "$usable_pct")
        fi

        ctx_val1="${formatted_len}"
        ctx_val2="${tokens_left}"
        ctx_val3="${total_pct}%"
        ctx_val4="${ctx_left_pct}%"

        # Write context-fill to a readable cache file for agents (failure-safe)
        write_context_cache "$ctx_len" "$max_tokens" "$total_pct" \
            "$usable_pct" "$ctx_ref_tokens" "$ctx_estimated" "$ctx_disabled"
    fi

    # Session values
    local sess_cost=""
    if [[ "$SHOW_SESSION" == "true" ]]; then
        local session_secs api_secs
        session_secs=$(get_session_time "session")
        api_secs=$(get_session_time "block")

        sess_val1=$(format_duration "$session_secs")
        sess_val2=$(format_duration "$api_secs")
        sess_cost=$(get_total_cost)
        sess_val3="\$${sess_cost}"
    fi

    # Calculate max width per column across all 3 lines
    # Column 1: tok_val1 vs ctx_val1 vs sess_val1
    local col1_width=${#tok_val1}
    [[ ${#ctx_val1} -gt $col1_width ]] && col1_width=${#ctx_val1}
    [[ ${#sess_val1} -gt $col1_width ]] && col1_width=${#sess_val1}

    # Column 2: tok_val2 vs ctx_val2 vs sess_val2
    local col2_width=${#tok_val2}
    [[ ${#ctx_val2} -gt $col2_width ]] && col2_width=${#ctx_val2}
    [[ ${#sess_val2} -gt $col2_width ]] && col2_width=${#sess_val2}

    # Column 3: tok_val3 vs ctx_val3 vs sess_val3
    local col3_width=${#tok_val3}
    [[ ${#ctx_val3} -gt $col3_width ]] && col3_width=${#ctx_val3}
    [[ ${#sess_val3} -gt $col3_width ]] && col3_width=${#sess_val3}

    # Column 4: tok_val4 vs ctx_val4 vs session progress bar percentage
    # Session col4 = progress bar (12 chars) + space (1 char) + percentage
    # For alignment, Tokens/Context col4 labels need extra padding to match progress bar width
    local col4_width=${#tok_val4}
    [[ ${#ctx_val4} -gt $col4_width ]] && col4_width=${#ctx_val4}
    # Include session's percentage (ctx_usable_pct + "%" suffix) in width calculation
    local sess_pct_len=0
    if [[ -n "$ctx_usable_pct" ]]; then
        sess_pct_len=$((${#ctx_usable_pct} + 1))  # +1 for % suffix
        # +1 more for the "~" prefix shown when the reference is estimated
        [[ "$ctx_estimated" == "true" ]] && sess_pct_len=$((sess_pct_len + 1))
    fi
    [[ $sess_pct_len -gt $col4_width ]] && col4_width=$sess_pct_len

    # Progress bar is 12 chars + 1 space = 13 chars before percentage
    # Labels "User Tokens: " and "ContextLeft: " are 13 chars each
    # To align the VALUES (not total width), we need extra padding for Tokens/Context
    # Extra padding needed = progress_bar_width (13) - label_width (13) = 0 chars
    local progress_bar_prefix_width=13  # [==========] + space
    local label_prefix_width=13         # "User Tokens: " or "ContextLeft: "
    local extra_padding=$((progress_bar_prefix_width - label_prefix_width))
    local col4_padded_width=$((col4_width + extra_padding))

    # Now output the lines with dynamically calculated right-aligned values
    local gray_color="" gray_color_reset=""
    if [[ "$SHOW_COLORS" == "true" ]]; then
        gray_color="$COLOR_GRAY"
        gray_color_reset="$COLOR_RESET"
    fi

    # Tokens line: Input: %Ns    Output: %Ns    Cached: %Ns    User Tokens: %Ns
    # 4 spaces between columns for readability
    # col4 uses padded width so value aligns with Session's progress bar percentage
    if [[ "$SHOW_TOKENS" == "true" ]]; then
        local tok_line
        printf -v tok_line "${tok_label}Input: %${col1_width}s    Output: %${col2_width}s    Cached: %${col3_width}s    User Tokens: %${col4_padded_width}s" \
            "$tok_val1" "$tok_val2" "$tok_val3" "$tok_val4"
        lines+=("${gray_color}${tok_line}${gray_color_reset}")
    fi

    # Context line: UsedT: %Ns    TkLeft: %Ns    CtxMax: %Ns    ContextLeft: %Ns
    # 4 spaces between columns for readability
    # col4 uses padded width so value aligns with Session's progress bar percentage
    if [[ "$SHOW_CTX" == "true" ]]; then
        local ctx_line
        printf -v ctx_line "Context -> UsedT: %${col1_width}s    TkLeft: %${col2_width}s    CtxMax: %${col3_width}s    ContextLeft: %${col4_padded_width}s" \
            "$ctx_val1" "$ctx_val2" "$ctx_val3" "$ctx_val4"
        lines+=("${gray_color}${ctx_line}${gray_color_reset}")
    fi

    # Session line - includes model, style, hostname, total tokens and cost
    if [[ "$SHOW_SESSION" == "true" ]]; then
        # Get model info for session line
        local current_model_sess
        current_model_sess=$(get_current_model)
        local style_sess
        style_sess=$(get_thinking_style)
        local effort_sess
        effort_sess=$(get_effort_level)

        local model_name_color_sess="" model_color_reset_sess=""
        if [[ "$SHOW_COLORS" == "true" ]] && [[ -n "$current_model_sess" ]]; then
            model_color_reset_sess="$COLOR_RESET"
            case "${current_model_sess,,}" in
                haiku*) model_name_color_sess="$COLOR_SILVER" ;;
                sonnet*) model_name_color_sess="$COLOR_SALMON" ;;
                opus*) model_name_color_sess="$COLOR_GOLD" ;;
                *) model_name_color_sess="$COLOR_GRAY" ;;
            esac
        fi

        # Build session line with progress bar at end (showing usable context percentage)
        local sess_progress_bar="" sess_progress_color="" sess_progress_color_reset=""
        if [[ -n "$ctx_usable_pct" ]] && [[ "$SHOW_PROGRESS" == "true" ]]; then
            # Format progress bar percentage right-aligned using col4_width.
            # The "~" (estimated reference) is part of the value so it sits
            # directly on the number; right-align pads with leading spaces only.
            local sess_pct_formatted sess_pct_value="${ctx_usable_pct}%"
            [[ "$ctx_estimated" == "true" ]] && sess_pct_value="~${ctx_usable_pct}%"
            printf -v sess_pct_formatted "%${col4_width}s" "$sess_pct_value"
            sess_progress_bar="    ${ctx_usable_bar} ${sess_pct_formatted}"
            if [[ "$SHOW_COLORS" == "true" ]]; then
                local usable_pct_int="${ctx_usable_pct%%.*}"
                sess_progress_color=$(get_color "$usable_pct_int")
                sess_progress_color_reset="$COLOR_RESET"
            fi
        fi

        # Session line: Sessn: %Ns    APIuse: %Ns    SnCost: %Ns    [progress bar] (compact_warning)
        # 4 spaces between columns for readability
        local sess_line
        printf -v sess_line "Session -> Sessn: %${col1_width}s    APIuse: %${col2_width}s    SnCost: %${col3_width}s" \
            "$sess_val1" "$sess_val2" "$sess_val3"
        lines+=("${gray_color}${sess_line}${gray_color_reset}${sess_progress_color}${sess_progress_bar}${sess_progress_color_reset}${compact_warning}")

        # Model info line with lifetime totals
        # Format: {Model} | {Effort} | {style} | LifetimeTotal: {tokens} ${cost} | Device: {device}
        # {Effort} is omitted when stdin has no effort.level (model without reasoning effort)
        if [[ "$SHOW_MODEL" == "true" ]] && [[ -n "$current_model_sess" ]]; then
            # Lifetime work tokens + cost from the ledger (main + subagents,
            # deduplicated, priced per concrete model id; unknown models are
            # not priced and flagged "+n/a").
            local formatted_tokens_lifetime="" total_cost_lifetime="0.00"
            if [[ -n "$ledger_json" ]]; then
                local lt_tokens lt_cost lt_unpriced
                read -r lt_tokens lt_cost lt_unpriced <<< "$(echo "$ledger_json" | jq -r '.lifetime | "\(.tokens) \(.cost) \(.unpriced)"')"
                if [[ "${lt_tokens:-0}" -gt 0 ]]; then
                    formatted_tokens_lifetime=$(format_tokens "$lt_tokens")
                    total_cost_lifetime=$(awk -v c="${lt_cost:-0}" 'BEGIN {printf "%.2f", c}')
                    [[ "${lt_unpriced:-0}" -gt 0 ]] && total_cost_lifetime="${total_cost_lifetime}+n/a"
                fi
            fi

            local model_line=""
            model_line="${model_name_color_sess}${current_model_sess}${model_color_reset_sess}"
            model_line="${model_line}${gray_color}"
            if [[ -n "$effort_sess" ]]; then
                model_line="${model_line} | ${effort_sess}"
            fi
            model_line="${model_line} | ${style_sess}"
            if [[ -n "$formatted_tokens_lifetime" ]]; then
                model_line="${model_line} | LifetimeTotal: ${formatted_tokens_lifetime} \$${total_cost_lifetime}"
            fi
            model_line="${model_line} | Device: ${LOCAL_DEVICE_LABEL}${gray_color_reset}"
            lines+=("$model_line")
        fi
    fi

    # -------------------------------------------------------------------------
    # Original limit features (with empty line separator)
    # -------------------------------------------------------------------------

    # Add visual separator before limits (black dash, invisible on dark terminals)
    if [[ "$SHOW_SEPARATORS" == "true" ]]; then
        lines+=("${COLOR_BLACK}-${COLOR_RESET}")
    fi

    # Highscore-based local tracking (per plan, 5h and 7d separately):
    # - window tokens: deduplicated work tokens of the current window (ledger)
    # - highscore: the highest window token count ever seen (only rises)
    # - local_pct = window_tokens * 100 / highscore
    # - Est100%: median of tokens / (api% / 100) over samples with api >= 20 %
    #   in the current window (falls back to the previous window's median).
    #   The tokens are THIS device's transcripts only (other devices write their
    #   own ~/.claude and cannot be read), while API% is account-wide, so the
    #   value is shown on the device line and is a lower bound when other
    #   devices are active. Samples are only taken with a complete ledger
    #   (backfill finished, nothing pending) and a fresh API value - otherwise
    #   the ratio comes out too low (missing tokens) or too high (old API%).
    #   "Fresh" = cache younger than EST_MAX_AGE (default 120 s), tighter than
    #   the [stale] marker.
    local local_5h_pct="" local_7d_pct=""
    local highscore_5h=0 highscore_7d=0
    local est_5h="" est_7d="" est_5h_src="" est_7d_src=""

    # Cache age, needed for the sampling decision and the [stale] marker.
    local cache_age=0
    if [[ "$api_available" == "true" ]] && [[ -f "$CACHE_FILE" ]]; then
        local cache_mtime
        cache_mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo "$now_epoch")
        cache_age=$((now_epoch - cache_mtime))
    fi

    if [[ "$SHOW_LOCAL" == "true" ]] && [[ "$local_ok" == "true" ]]; then
        local hs_json="" api5_rec="" api7_rec="" est_sampling=true
        [[ "$ledger_complete" == "true" ]] || est_sampling=false
        [[ "$cache_age" -gt "$EST_MAX_AGE" || "$cache_age" -gt "$STALE_AFTER" ]] && est_sampling=false
        [[ "$est_sampling" == "true" && "$api_available" == "true" && "$five_expired" != "true" ]] && api5_rec="$five_hour_util"
        [[ "$est_sampling" == "true" && "$api_available" == "true" && "$seven_expired" != "true" ]] && api7_rec="$seven_day_util"
        debug_log "est sampling=$est_sampling (ledger complete=$ledger_complete, cache age=${cache_age}s)"

        if [[ "$start_5h" -ge 0 ]] && hs_json=$(highscore_record "$CURRENT_PLAN" 5h "$start_5h" "$window_tokens_5h" "$api5_rec" "$now_epoch" 2>/dev/null) && [[ -n "$hs_json" ]]; then
            read -r highscore_5h est_5h est_5h_src <<< "$(echo "$hs_json" | jq -r '"\(.hs) \(.est // "-") \(.src)"')"
            if [[ "$highscore_5h" -gt 0 ]]; then
                local_5h_pct=$(awk "BEGIN {pct = ($window_tokens_5h * 100) / $highscore_5h; if (pct > 100) pct = 100; printf \"%.1f\", pct}")
            fi
        fi
        if [[ "$start_7d" -ge 0 ]] && hs_json=$(highscore_record "$CURRENT_PLAN" 7d "$start_7d" "$window_tokens_7d" "$api7_rec" "$now_epoch" 2>/dev/null) && [[ -n "$hs_json" ]]; then
            read -r highscore_7d est_7d est_7d_src <<< "$(echo "$hs_json" | jq -r '"\(.hs) \(.est // "-") \(.src)"')"
            if [[ "$highscore_7d" -gt 0 ]]; then
                local_7d_pct=$(awk "BEGIN {pct = ($window_tokens_7d * 100) / $highscore_7d; if (pct > 100) pct = 100; printf \"%.1f\", pct}")
            fi
        fi
        debug_log "local: plan=$CURRENT_PLAN w5=$window_tokens_5h hs5=$highscore_5h est5=$est_5h w7=$window_tokens_7d hs7=$highscore_7d est7=$est_7d"

        # History entry (10-min interval) for the averages, only with API values
        # that belong to the current window.
        if [[ "$api_available" == "true" ]] && [[ "$five_expired" != "true" ]]; then
            append_history \
                "${five_pct:-0}" "$window_tokens_5h" "$highscore_5h" \
                "${seven_pct:-0}" "$window_tokens_7d" "$highscore_7d" \
                "${opus_pct:-0}" "${sonnet_pct:-0}" \
                "$CURRENT_PLAN" "$LOCAL_DEVICE_LABEL" \
                "$five_hour_reset" "$seven_day_reset" || true
        fi
    fi

    # After resets_at the cached utilization belongs to the old window: show 0 %.
    local five_reset_note="" seven_reset_note=""
    if [[ "$five_expired" == "true" ]] && [[ -n "$five_pct" ]]; then
        five_pct="0.0"
        five_reset_note=" (reset)"
    fi
    if [[ "$seven_expired" == "true" ]] && [[ -n "$seven_pct" ]]; then
        seven_pct="0.0"
        seven_reset_note=" (reset)"
    fi

    # Cache age marker when the API numbers are old.
    local stale_note=""
    if [[ "$api_available" == "true" ]] && [[ "$cache_age" -gt "$STALE_AFTER" ]]; then
        stale_note=" [stale $(format_duration "$cache_age")]"
    fi

    # API error handling: show error message instead of API-dependent limits
    if [[ "$api_available" != "true" ]] && [[ -n "$API_ERROR" ]]; then
        # Display error message for API-dependent parts
        local error_color="" error_color_reset=""
        if [[ "$SHOW_COLORS" == "true" ]]; then
            error_color="$COLOR_ORANGE"
            error_color_reset="$COLOR_RESET"
        fi
        lines+=("${error_color}${API_ERROR}${error_color_reset}")

        # Still show local highscore lines if available (without reset time)
        if [[ "$SHOW_LOCAL" == "true" ]] && [[ "$SHOW_5H" == "true" ]] && [[ -n "${local_5h_pct}" ]]; then
            local local_5h_color="" local_5h_color_reset=""
            if [[ "$SHOW_COLORS" == "true" ]]; then
                local_5h_color=$(get_color "${local_5h_pct}")
                local_5h_color_reset="${COLOR_RESET}"
            fi
            local window_5h_formatted hs_5h_formatted
            window_5h_formatted=$(format_highscore "$window_tokens_5h")
            hs_5h_formatted=$(format_highscore "$highscore_5h")
            # Show without reset time since we don't have fresh API data
            lines+=("$(format_limit_line "5h all" "${local_5h_pct}" "" 1) ${local_5h_color}[Highest:${window_5h_formatted}/${hs_5h_formatted}]$(format_est100 "$est_5h" "$est_5h_src") (${LOCAL_DEVICE_LABEL})${local_5h_color_reset}")
        fi

        # Still show the local 7d/weekly highscore line too (also API-independent, without reset)
        if [[ "$SHOW_LOCAL" == "true" ]] && [[ "$SHOW_7D" == "true" ]] && [[ -n "${local_7d_pct}" ]]; then
            local local_7d_color="" local_7d_color_reset=""
            if [[ "$SHOW_COLORS" == "true" ]]; then
                local_7d_color=$(get_color "${local_7d_pct}")
                local_7d_color_reset="${COLOR_RESET}"
            fi
            local window_7d_formatted hs_7d_formatted
            window_7d_formatted=$(format_highscore "$window_tokens_7d")
            hs_7d_formatted=$(format_highscore "$highscore_7d")
            # Show without reset time since we don't have fresh API data
            lines+=("$(format_limit_line "7d all" "${local_7d_pct}" "" 1) ${local_7d_color}[Highest:${window_7d_formatted}/${hs_7d_formatted}]$(format_est100 "$est_7d" "$est_7d_src") (${LOCAL_DEVICE_LABEL})${local_7d_color_reset}")
        fi
    else
        # Normal mode: API available, show all limits

        # Averages from the history (one jq pass):
        #   5h: [AvgPeak:X%] average peak of completed 5h windows (7 days)
        #       [Avg:Y%/h]   average consumption per hour (24 h, idle included)
        #   7d: [AvgPeak:X%] (28 days) [Avg:Y%/d] (7 days); Opus/Sonnet: AvgPeak
        local avg_5h_peak="-" avg_5h_rate="-" avg_7d_peak="-" avg_7d_rate="-"
        local avg_opus="-" avg_sonnet="-"
        if [[ "$SHOW_AVERAGE" == "true" ]]; then
            read -r avg_5h_peak avg_5h_rate avg_7d_peak avg_7d_rate avg_opus avg_sonnet <<< "$(history_averages "$now_epoch" 2>/dev/null || echo "- - - - - -")"
        fi

        # Check for achievement: trophy appears when global API usage >= 95%
        # AND local device usage >= 95% of its own highscore
        local achievement_5h="" achievement_7d=""
        if [[ -n "$local_5h_pct" ]] && [[ -n "$five_pct" ]]; then
            local is_achievement_5h
            is_achievement_5h=$(awk "BEGIN {print ($five_pct >= 95 && $local_5h_pct >= 95) ? 1 : 0}")
            if [[ "$is_achievement_5h" -eq 1 ]]; then
                achievement_5h=" $ACHIEVEMENT_SYMBOL"
            fi
        fi
        if [[ -n "$local_7d_pct" ]] && [[ -n "$seven_pct" ]]; then
            local is_achievement_7d
            is_achievement_7d=$(awk "BEGIN {print ($seven_pct >= 95 && $local_7d_pct >= 95) ? 1 : 0}")
            if [[ "$is_achievement_7d" -eq 1 ]]; then
                achievement_7d=" $ACHIEVEMENT_SYMBOL"
            fi
        fi

        # 5-hour limit (if enabled) - all models
        if [[ "$SHOW_5H" == "true" ]]; then
            local global_5h_line global_5h_color="" global_5h_color_reset=""
            if [[ "$SHOW_COLORS" == "true" ]]; then
                global_5h_color=$(get_color "$five_pct")
                global_5h_color_reset="${COLOR_RESET}"
            fi
            global_5h_line="$(format_limit_line "5h all" "$five_pct" "$five_hour_reset")${five_reset_note}${stale_note}"
            if [[ "$SHOW_AVERAGE" == "true" ]]; then
                [[ "$avg_5h_peak" != "-" ]] && global_5h_line="${global_5h_line} ${global_5h_color}[AvgPeak:${avg_5h_peak}%]${global_5h_color_reset}"
                [[ "$avg_5h_rate" != "-" ]] && global_5h_line="${global_5h_line} ${global_5h_color}[Avg:${avg_5h_rate}%/h]${global_5h_color_reset}"
            fi
            lines+=("$global_5h_line")
            # Local 5h directly below global 5h - shows highscore-based percentage
            if [[ "$SHOW_LOCAL" == "true" ]] && [[ -n "${local_5h_pct}" ]]; then
                local local_5h_color="" local_5h_color_reset=""
                if [[ "$SHOW_COLORS" == "true" ]]; then
                    local_5h_color=$(get_color "${local_5h_pct}")
                    local_5h_color_reset="${COLOR_RESET}"
                fi
                local window_5h_formatted hs_5h_formatted
                window_5h_formatted=$(format_highscore "$window_tokens_5h")
                hs_5h_formatted=$(format_highscore "$highscore_5h")
                lines+=("$(format_limit_line "5h all" "${local_5h_pct}" "$five_hour_reset" 1) ${local_5h_color}[Highest:${window_5h_formatted}/${hs_5h_formatted}]$(format_est100 "$est_5h" "$est_5h_src") (${LOCAL_DEVICE_LABEL})${achievement_5h}${local_5h_color_reset}")
            fi
        fi

        # 7-day limit (if enabled and available) - all models
        if [[ "$SHOW_7D" == "true" ]] && [[ -n "$seven_pct" ]]; then
            local global_7d_line global_7d_color="" global_7d_color_reset=""
            if [[ "$SHOW_COLORS" == "true" ]]; then
                global_7d_color=$(get_color "$seven_pct")
                global_7d_color_reset="${COLOR_RESET}"
            fi
            global_7d_line="$(format_limit_line "7d all" "$seven_pct" "$seven_day_reset")${seven_reset_note}"
            if [[ "$SHOW_AVERAGE" == "true" ]]; then
                [[ "$avg_7d_peak" != "-" ]] && global_7d_line="${global_7d_line} ${global_7d_color}[AvgPeak:${avg_7d_peak}%]${global_7d_color_reset}"
                [[ "$avg_7d_rate" != "-" ]] && global_7d_line="${global_7d_line} ${global_7d_color}[Avg:${avg_7d_rate}%/d]${global_7d_color_reset}"
            fi
            lines+=("$global_7d_line")
            # Local 7d directly below global 7d - shows highscore-based percentage
            if [[ "$SHOW_LOCAL" == "true" ]] && [[ -n "${local_7d_pct}" ]]; then
                local local_7d_color="" local_7d_color_reset=""
                if [[ "$SHOW_COLORS" == "true" ]]; then
                    local_7d_color=$(get_color "${local_7d_pct}")
                    local_7d_color_reset="${COLOR_RESET}"
                fi
                local window_7d_formatted hs_7d_formatted
                window_7d_formatted=$(format_highscore "$window_tokens_7d")
                hs_7d_formatted=$(format_highscore "$highscore_7d")
                lines+=("$(format_limit_line "7d all" "${local_7d_pct}" "$seven_day_reset" 1) ${local_7d_color}[Highest:${window_7d_formatted}/${hs_7d_formatted}]$(format_est100 "$est_7d" "$est_7d_src") (${LOCAL_DEVICE_LABEL})${achievement_7d}${local_7d_color_reset}")
            fi
        fi

        # 7-day Opus limit (if enabled and has data)
        if [[ "$SHOW_OPUS" == "true" ]] && [[ -n "$opus_pct" ]]; then
            local opus_line opus_color="" opus_color_reset=""
            if [[ "$SHOW_COLORS" == "true" ]]; then
                opus_color=$(get_color "$opus_pct")
                opus_color_reset="${COLOR_RESET}"
            fi
            opus_line="$(format_limit_line "7d Opus" "$opus_pct" "$opus_reset")"
            if [[ "$SHOW_AVERAGE" == "true" ]] && [[ "$avg_opus" != "-" ]]; then
                opus_line="${opus_line} ${opus_color}[AvgPeak:${avg_opus}%]${opus_color_reset}"
            fi
            lines+=("$opus_line")
        fi

        # 7-day Sonnet limit (if enabled and has utilization >= 0.1%)
        # Hide when usage is 0 or rounds to 0.0% (check both numeric and string)
        if [[ "$SHOW_SONNET" == "true" ]] && [[ -n "$sonnet_pct" ]]; then
            # Use awk for proper decimal comparison - show only if >= 0.1%
            local sonnet_above_threshold
            sonnet_above_threshold=$(awk "BEGIN {print ($sonnet_pct >= 0.1) ? 1 : 0}")
            if [[ "$sonnet_above_threshold" -eq 1 ]]; then
                local sonnet_line sonnet_color="" sonnet_color_reset=""
                if [[ "$SHOW_COLORS" == "true" ]]; then
                    sonnet_color=$(get_color "$sonnet_pct")
                    sonnet_color_reset="${COLOR_RESET}"
                fi
                sonnet_line="$(format_limit_line "7d Sonnet" "$sonnet_pct" "$sonnet_reset")"
                if [[ "$SHOW_AVERAGE" == "true" ]] && [[ "$avg_sonnet" != "-" ]]; then
                    sonnet_line="${sonnet_line} ${sonnet_color}[AvgPeak:${avg_sonnet}%]${sonnet_color_reset}"
                fi
                lines+=("$sonnet_line")
            fi
        fi

        # Further limits from limits[] (e.g. weekly_scoped per model). The
        # session and weekly_all entries are the 5h/7d lines above; scoped
        # entries already shown as Opus/Sonnet lines are skipped.
        if [[ "$SHOW_SCOPED" == "true" ]]; then
            local sc_label sc_pct sc_reset
            while IFS=$'\t' read -r sc_label sc_pct sc_reset; do
                [[ -n "$sc_label" ]] || continue
                [[ "$sc_label" == "7d Opus" && -n "$opus_pct" ]] && continue
                [[ "$sc_label" == "7d Sonnet" && -n "$sonnet_pct" ]] && continue
                sc_pct=$(cap_decimal "$(parse_decimal "$sc_pct")" 100)
                [[ -n "$sc_pct" ]] || continue
                local sc_epoch
                sc_epoch=$(_hs_epoch "$sc_reset")
                if [[ -n "$sc_epoch" ]] && [[ "$now_epoch" -ge "$sc_epoch" ]]; then
                    lines+=("$(format_limit_line "$sc_label" "0.0" "$sc_reset") (reset)")
                else
                    lines+=("$(format_limit_line "$sc_label" "$sc_pct" "$sc_reset")")
                fi
            done < <(echo "$response" | jq -r '
                .limits[]? | select(.kind != "session" and .kind != "weekly_all")
                | [ ((if .group == "session" then "5h" elif .group == "weekly" then "7d" else (.group // "") end)
                     + " " + ((.scope.model.display_name // .scope.surface // .kind // "limit") | tostring)),
                    ((.percent // 0) | tostring), (.resets_at // "") ] | @tsv' 2>/dev/null)
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
    fi

    # Session ID and/or Profile (if enabled) - always gray, same line with 4 spaces between
    if [[ "$SHOW_SESSION_ID" == "true" ]] || [[ "$SHOW_PROFILE" == "true" ]]; then
        local info_parts=()
        local info_color=""
        local info_color_reset=""

        if [[ "$SHOW_COLORS" == "true" ]]; then
            info_color="$COLOR_GRAY"
            info_color_reset="$COLOR_RESET"
        fi

        if [[ "$SHOW_SESSION_ID" == "true" ]]; then
            local session_id
            session_id=$(get_session_id)
            if [[ -n "$session_id" ]]; then
                info_parts+=("Session ID: ${session_id}")
            fi
        fi

        if [[ "$SHOW_PROFILE" == "true" ]]; then
            info_parts+=("Profile: ${PROFILE_NAME}")
        fi

        if [[ ${#info_parts[@]} -gt 0 ]]; then
            if [[ "$SHOW_SEPARATORS" == "true" ]]; then
                lines+=("${COLOR_BLACK}-${COLOR_RESET}")
            fi
            # Join parts with 4 spaces
            local info_line=""
            local first_part=true
            for part in "${info_parts[@]}"; do
                if [[ "$first_part" == "true" ]]; then
                    info_line="$part"
                    first_part=false
                else
                    info_line="${info_line}    ${part}"
                fi
            done
            lines+=("${info_color}${info_line}${info_color_reset}")
        fi
    fi

    # Session caption (below session ID line)
    if [[ "$SHOW_CAPTION" == "true" ]]; then
        local caption_color=""
        local caption_color_reset=""
        if [[ "$SHOW_COLORS" == "true" ]]; then
            caption_color="$COLOR_GRAY"
            caption_color_reset="$COLOR_RESET"
        fi

        local sid
        sid=$(get_session_id)
        local caption
        caption=$(get_session_caption "$sid")

        if [[ -n "$caption" ]]; then
            lines+=("${caption_color}Caption: ${caption}${caption_color_reset}")
        else
            lines+=("${caption_color}Caption: loading...${caption_color_reset}")
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
    # Ensure plugin directory exists and migrate old state files if needed
    ensure_plugin_dir
    migrate_old_state_files

    # Read stdin data from Claude Code first (contains model info)
    read_stdin_data

    local response=""

    # Check dependencies - if missing, skip the refresh but continue with local data.
    if check_dependencies; then
        # Refresh the shared cache via the isolated, token-owning helper. This
        # script never reads the OAuth token nor calls the Anthropic API itself.
        # The helper emits a single sanitized status word; we map it to the
        # existing API_ERROR codes so format_output renders the same messages.
        #
        # The render must stay fast: with statusLine.refreshInterval this script
        # runs every few seconds (also while the main loop is idle waiting on a
        # subagent), and Claude Code cancels an in-flight statusline script when
        # the next tick fires. So the render NEVER blocks on the API:
        #   - cold start (no cache yet): one synchronous fetch so the first render
        #     has data.
        #   - warm: kick refresh-usage.sh off DETACHED (survives cancellation) and
        #     render from the current cache; the helper's status word is captured
        #     to REFRESH_STATUS_FILE and surfaced on the NEXT render (~1 tick later).
        # Either way the helper's own throttle (floor + jittered cadence + flock)
        # governs the real API cadence unchanged - invoking it more often does NOT
        # cause extra API calls.
        local refresh_status="" refresh_rc=0
        if [[ ! -f "$CACHE_FILE" ]]; then
            # Cold start: synchronous fetch so we have something to show now.
            refresh_status="$("${SCRIPT_DIR}/refresh-usage.sh" 2>/dev/null)" || refresh_rc=$?
        else
            # Warm: consume the previous detached run's status (if any),
            if [[ -f "$REFRESH_STATUS_FILE" ]]; then
                local _rline _rrc
                _rline="$(cat "$REFRESH_STATUS_FILE" 2>/dev/null || true)"
                refresh_status="${_rline%%$'\t'*}"
                _rrc="${_rline#*$'\t'}"
                [[ "$_rrc" =~ ^[0-9]+$ ]] && refresh_rc="$_rrc"
            fi
            # and kick off a fresh refresh DETACHED for the next render.
            if command -v setsid >/dev/null 2>&1; then
                setsid bash -c '
                    s="$("$1/refresh-usage.sh" 2>/dev/null)"; rc=$?
                    printf "%s\t%s\n" "$s" "$rc" > "$2.tmp.$$" 2>/dev/null && mv -f "$2.tmp.$$" "$2" 2>/dev/null
                ' _ "$SCRIPT_DIR" "$REFRESH_STATUS_FILE" >/dev/null 2>&1 < /dev/null &
            else
                # No setsid (e.g. stock macOS): background a subshell that still
                # captures the status the same way, so warm-path error surfacing
                # keeps working. It stays in this process group (a killpg-style
                # cancellation could interrupt it, but tmp+mv+flock make that a
                # clean skipped tick, never corruption).
                ( r="$("${SCRIPT_DIR}/refresh-usage.sh" 2>/dev/null)"; rc=$?
                  printf '%s\t%s\n' "$r" "$rc" > "${REFRESH_STATUS_FILE}.tmp.$$" 2>/dev/null \
                    && mv -f "${REFRESH_STATUS_FILE}.tmp.$$" "$REFRESH_STATUS_FILE" 2>/dev/null ) < /dev/null &
            fi
            disown 2>/dev/null || true
        fi
        debug_log "refresh-usage.sh status='${refresh_status}' rc=${refresh_rc}"

        case "$refresh_status" in
            fresh|refreshed|skipped-locked)
                : # cache is usable, no error to surface
                ;;
            no-credentials)
                set_api_error "no_credentials"
                ;;
            no-token)
                set_api_error "no_token"
                ;;
            no-curl)
                set_api_error "no_curl"
                ;;
            curl-failed)
                set_api_error "curl_failed"
                ;;
            rate-limited)
                # refresh-usage.sh stored ONE retry time when the 429 arrived;
                # show the remaining seconds of exactly that backoff (stable
                # across renders, and the helper honours it).
                set_api_error "api_429"
                ;;
            http-error | http-error\ *)
                # refresh-usage.sh appends only curl's numeric transport status
                # code (validated 3-digit), never the response body. Map auth
                # failures to the auth hint, everything else to the generic error.
                local http_code="${refresh_status#http-error}"
                http_code="${http_code# }"
                case "$http_code" in
                    401) set_api_error "api_401" ;;
                    403) set_api_error "api_403" ;;
                    *)   set_api_error "api_5xx" ;;
                esac
                ;;
            *)
                # Unknown/empty status: only treat as an error if the helper
                # actually failed (rc != 0).
                if [[ "$refresh_rc" -ne 0 ]]; then
                    set_api_error "api_error"
                fi
                ;;
        esac

        # Load the (possibly just refreshed) cache. Only read it if present.
        if [[ -f "$CACHE_FILE" ]]; then
            response="$(read_cache)"
        fi
    fi

    # Debug logging
    debug_log "=== Statusline execution ==="
    debug_log "Stdin data: $STDIN_DATA"
    debug_log "API response: $response"

    format_output "$response"
}

main
