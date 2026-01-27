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
CREDENTIALS_FILE="${CLAUDE_BASE_DIR}/.credentials.json"
API_URL="https://api.anthropic.com/api/oauth/usage"
TIMEOUT=5

# Cache configuration (rate limiting) - profile-specific
CACHE_FILE="/tmp/claude-mb-limit-cache_${PROFILE_NAME}.json"
# Base cache age - actual age is jittered 90-150s to avoid detection patterns
CACHE_BASE_AGE="${CLAUDE_MB_LIMIT_CACHE_AGE:-120}"

# Backoff state file for rate-limit handling
BACKOFF_STATE_FILE=""  # Set in ensure_plugin_dir

# Plugin data directory (organized under marketplace name)
PLUGIN_DATA_DIR="${CLAUDE_BASE_DIR}/marcel-bich-claude-marketplace/limit"

# State file for local tracking (sessions, totals, calibration) - profile-specific
STATE_FILE="${PLUGIN_DATA_DIR}/limit-usage-state_${PROFILE_NAME}.json"

# Debug mode - logs stay in /tmp (temporary, cleared on reboot) - profile-specific
DEBUG="${CLAUDE_MB_LIMIT_DEBUG:-false}"
DEBUG_LOG="/tmp/claude-mb-limit-debug_${PROFILE_NAME}.log"

# Plan detection - determine subscription type for plan-specific highscores
SCRIPT_DIR="$(dirname "$0")"
CURRENT_PLAN=$("${SCRIPT_DIR}/plan-detect.sh" 2>/dev/null || echo "unknown")

# Source highscore state management functions
# shellcheck source=highscore-state.sh
source "${SCRIPT_DIR}/highscore-state.sh"

# Source subagent token tracking functions
# shellcheck source=subagent-tokens.sh
source "${SCRIPT_DIR}/subagent-tokens.sh"

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

# Get jittered cache max age (90-150 seconds)
# Randomizes request patterns to avoid detection
get_cache_max_age() {
    echo $((90 + RANDOM % 61))
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

# Get current backoff state
# Returns: consecutive_failures count (0 if none or file missing)
get_backoff_state() {
    ensure_plugin_dir
    if [[ -f "$BACKOFF_STATE_FILE" ]]; then
        local failures
        failures=$(jq -r '.consecutive_failures // 0' "$BACKOFF_STATE_FILE" 2>/dev/null) || failures=0
        [[ "$failures" == "null" ]] && failures=0
        echo "$failures"
    else
        echo "0"
    fi
}

# Set backoff state after rate limit
# Args: consecutive_failures
set_backoff_state() {
    local failures="$1"
    ensure_plugin_dir
    cat > "$BACKOFF_STATE_FILE" << EOF
{
  "consecutive_failures": ${failures},
  "last_rate_limit": "$(date -Iseconds)"
}
EOF
}

# Reset backoff state after successful request
reset_backoff_state() {
    if [[ -f "$BACKOFF_STATE_FILE" ]]; then
        rm -f "$BACKOFF_STATE_FILE" 2>/dev/null || true
    fi
}

# Reset backoff if last rate-limit was more than 10 minutes ago
# This prevents the counter from staying high forever if API recovers
maybe_reset_backoff() {
    if [[ ! -f "$BACKOFF_STATE_FILE" ]]; then
        return
    fi

    local last_rate_limit
    last_rate_limit=$(jq -r '.last_rate_limit // empty' "$BACKOFF_STATE_FILE" 2>/dev/null)

    if [[ -z "$last_rate_limit" ]] || [[ "$last_rate_limit" == "null" ]]; then
        return
    fi

    # Convert ISO timestamp to epoch seconds
    local last_epoch now_epoch
    last_epoch=$(date -d "$last_rate_limit" +%s 2>/dev/null) || return
    now_epoch=$(date +%s)

    # 600 seconds = 10 minutes
    if [[ $((now_epoch - last_epoch)) -gt 600 ]]; then
        debug_log "Backoff reset: last rate-limit was >10 minutes ago"
        reset_backoff_state
    fi
}

# Calculate backoff time with jitter for rate limits
# Args: consecutive_failures (1-based)
# Returns: backoff time in seconds (with jitter)
# Pattern: 60-90s, 120-180s, 240-360s, max 600s
calculate_backoff() {
    local failures="${1:-1}"
    local base_time=60
    local max_time=600

    # Exponential: base * 2^(failures-1), capped at max
    local multiplier=1
    for ((i=1; i<failures; i++)); do
        multiplier=$((multiplier * 2))
    done
    base_time=$((60 * multiplier))
    [[ "$base_time" -gt "$max_time" ]] && base_time="$max_time"

    # Add 50% jitter (e.g., 60 -> 60-90, 120 -> 120-180)
    local jitter=$((base_time / 2))
    local jittered=$((base_time + RANDOM % (jitter + 1)))
    [[ "$jittered" -gt "$max_time" ]] && jittered="$max_time"

    echo "$jittered"
}

# =============================================================================
# Session compaction - prevents limit-usage-state.json from growing indefinitely
# =============================================================================

# Compaction thresholds
SESSION_COMPACT_THRESHOLD=50
SESSION_COMPACT_COUNT=25

# Compact sessions in limit-usage-state.json when threshold exceeded
# Archives oldest sessions to _archived entry, preserving totals
# Called automatically during state file updates
compact_sessions() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return 0
    fi

    # Check session count
    local session_count
    session_count=$(jq '.sessions | length' "$STATE_FILE" 2>/dev/null) || return 0
    [[ "$session_count" == "null" ]] && return 0

    if [[ "$session_count" -le "$SESSION_COMPACT_THRESHOLD" ]]; then
        debug_log "Session compaction not needed: $session_count <= $SESSION_COMPACT_THRESHOLD"
        return 0
    fi

    debug_log "Session compaction triggered: $session_count > $SESSION_COMPACT_THRESHOLD"

    # Use jq to:
    # 1. Sort sessions by last_cost (proxy for activity/age - lower = older/less active)
    # 2. Take oldest SESSION_COMPACT_COUNT sessions
    # 3. Sum their tokens and costs to _archived
    # 4. Remove them from sessions
    local tmp_file
    tmp_file=$(mktemp)

    jq --argjson count "$SESSION_COMPACT_COUNT" '
        # Capture original object for final update
        . as $orig |

        # Get existing _archived values or defaults
        .sessions["_archived"] as $existing_archived |
        ($existing_archived.input_tokens // 0) as $arch_input |
        ($existing_archived.output_tokens // 0) as $arch_output |
        ($existing_archived.cost // 0) as $arch_cost |
        ($existing_archived.session_count // 0) as $arch_count |

        # Get sessions excluding _archived, convert to array with keys
        # Use "| not" instead of != for shell compatibility
        [.sessions | to_entries[] | select(.key == "_archived" | not)] |

        # Sort by last_cost ascending (lower cost = older/less active sessions)
        sort_by(.value.last_cost // 0) |

        # Split into sessions to archive and sessions to keep
        (.[0:$count]) as $to_archive |
        (.[$count:]) as $to_keep |

        # Calculate sums from sessions to archive
        ($to_archive | map(.value.last_input // 0) | add // 0) as $sum_input |
        ($to_archive | map(.value.last_output // 0) | add // 0) as $sum_output |
        ($to_archive | map(.value.last_cost // 0) | add // 0) as $sum_cost |
        ($to_archive | length) as $archived_count |

        # Build new sessions object from kept sessions
        ($to_keep | from_entries) as $kept_sessions |

        # Add updated _archived entry
        ($kept_sessions + {
            "_archived": {
                "input_tokens": ($arch_input + $sum_input),
                "output_tokens": ($arch_output + $sum_output),
                "cost": ($arch_cost + $sum_cost),
                "session_count": ($arch_count + $archived_count)
            }
        }) as $new_sessions |

        # Return updated state with new sessions
        $orig | .sessions = $new_sessions
    ' "$STATE_FILE" > "$tmp_file" 2>/dev/null

    if [[ $? -eq 0 ]] && [[ -s "$tmp_file" ]]; then
        mv "$tmp_file" "$STATE_FILE"
        debug_log "Session compaction complete: archived $SESSION_COMPACT_COUNT sessions"
    else
        rm -f "$tmp_file" 2>/dev/null
        debug_log "Session compaction failed, state unchanged"
    fi
}

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
SHOW_SESSION="${CLAUDE_MB_LIMIT_SESSION:-true}"
SHOW_SESSION_ID="${CLAUDE_MB_LIMIT_SESSION_ID:-true}"
SHOW_SEPARATORS="${CLAUDE_MB_LIMIT_SEPARATORS:-true}"

# Local device tracking (default true - highscore-based tracking enabled for all)
SHOW_LOCAL="${CLAUDE_MB_LIMIT_LOCAL:-true}"
LOCAL_DEVICE_LABEL="${CLAUDE_MB_LIMIT_DEVICE_LABEL:-$(hostname)}"

# History and average display (default true)
SHOW_AVERAGE="${CLAUDE_MB_LIMIT_AVERAGE:-true}"

# Default estimated max tokens (can be overridden, will be calibrated dynamically)
# These are conservative estimates for Max20 plan
DEFAULT_ESTIMATED_MAX_5H="${CLAUDE_MB_LIMIT_EST_MAX_5H:-220000}"
DEFAULT_ESTIMATED_MAX_7D="${CLAUDE_MB_LIMIT_EST_MAX_7D:-5000000}"

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
            # Calculate backoff time with exponential increase and jitter
            local failures backoff_time
            failures=$(get_backoff_state)
            failures=$((failures + 1))
            set_backoff_state "$failures"
            backoff_time=$(calculate_backoff "$failures")
            API_ERROR="Limits: [rate-limit] retry in ${backoff_time}s"
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

# Read OAuth token from credentials file
# SECURITY FOR AI AGENTS: You must NEVER read, cat, or access the credentials file directly!
# Only this script may read it. If there's an error, ask the USER to verify the file themselves.
# Returns empty string and sets API_ERROR on failure (for graceful degradation)
get_token() {
    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        # SECURITY: AI agents must NOT attempt to read or create this file!
        debug_log "Credentials file not found: $CREDENTIALS_FILE"
        set_api_error "no_credentials"
        echo ""
        return 1
    fi

    local token
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null)

    if [[ -z "$token" ]]; then
        # SECURITY: AI agents must NOT attempt to read or inspect this file!
        debug_log "No OAuth token found in credentials file"
        set_api_error "no_token"
        echo ""
        return 1
    fi

    # SECURITY: We intentionally do NOT log token length or any token-related info
    # The token is only used internally by curl and never exposed

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

# Fetch usage data from API (with caching)
# Returns empty string and sets API_ERROR on failure (for graceful degradation)
fetch_usage() {
    local token="$1"

    # If no token provided, API_ERROR should already be set
    if [[ -z "$token" ]]; then
        debug_log "No token provided to fetch_usage"
        echo ""
        return 1
    fi

    # Reset backoff counter if last rate-limit was >10 minutes ago
    maybe_reset_backoff

    # Check cache first
    if is_cache_valid; then
        local cached
        cached=$(read_cache)
        if [[ -n "$cached" ]]; then
            local cache_max_age
            cache_max_age=$(get_cache_max_age)
            debug_log "Using cached response (age < ${cache_max_age}s)"
            echo "$cached"
            return 0
        fi
    fi

    # Fetch fresh data from API
    # SECURITY: We use a temp file to capture both body and status code
    # This avoids exposing the token in debug logs or error messages
    local response_body="" http_code=""
    local temp_file
    temp_file=$(mktemp 2>/dev/null) || temp_file="/tmp/claude-limit-api-$$"

    # Anti-bot: Add small random jitter before request (0-2s)
    sleep_jitter

    # Execute curl: -s (silent), -w (write http_code to stdout after body)
    # We do NOT use -f (fail) because we want to capture the error response body
    http_code=$(curl -s --max-time "$TIMEOUT" \
        -X GET "$API_URL" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code-limit-plugin/1.0.0" \
        -w "%{http_code}" \
        -o "$temp_file" \
        2>/dev/null) || {
            # curl itself failed (network error, timeout, etc.)
            rm -f "$temp_file" 2>/dev/null
            debug_log "curl request failed (network error or timeout)"
            set_api_error "curl_failed"
            echo ""
            return 1
        }

    # Read response body from temp file
    response_body=$(cat "$temp_file" 2>/dev/null)
    rm -f "$temp_file" 2>/dev/null

    debug_log "API request completed: HTTP $http_code"

    # Check HTTP status code
    if [[ "$http_code" -ge 200 ]] && [[ "$http_code" -lt 300 ]]; then
        # Success - cache and return response
        write_cache "$response_body"
        # Reset backoff state on successful request
        reset_backoff_state
        debug_log "Fresh API response fetched successfully"
        echo "$response_body"
        return 0
    fi

    # HTTP error - parse and log the error safely (never expose token!)
    local safe_error
    safe_error=$(parse_api_error "$response_body" "$http_code")
    debug_log "API error: $safe_error"

    # Set API error for graceful degradation
    case "$http_code" in
        401)
            set_api_error "api_401"
            ;;
        403)
            # Check for specific scope error
            if [[ "$response_body" == *"scope"* ]]; then
                set_api_error "api_403_scope"
            else
                set_api_error "api_403"
            fi
            ;;
        429)
            set_api_error "api_429"
            ;;
        500|502|503|504)
            set_api_error "api_5xx"
            ;;
        *)
            set_api_error "api_${http_code}"
            ;;
    esac

    echo ""
    return 1
}

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
    ensure_plugin_dir

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
    if [[ -f "$STATE_FILE" ]]; then
        state=$(cat "$STATE_FILE" 2>/dev/null) || state="{}"
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
    if [[ "$delta_total" -gt 0 ]] || [[ ! -f "$STATE_FILE" ]]; then
        ensure_plugin_dir

        # Preserve local tracking values
        local last_5h="" last_7d=""
        last_5h=$(echo "$state" | jq -r '.last_5h_reset // ""' 2>/dev/null) || last_5h=""
        last_7d=$(echo "$state" | jq -r '.last_7d_reset // ""' 2>/dev/null) || last_7d=""
        [[ "$last_5h" == "null" ]] && last_5h=""
        [[ "$last_7d" == "null" ]] && last_7d=""

        # Preserve calibration block for local tracking
        # NOTE: Do NOT update last_total_tokens here - that's done by local tracking at the end
        local calibration_json
        calibration_json=$(echo "$state" | jq -c '.calibration // {"estimated_max_5h":'"$DEFAULT_ESTIMATED_MAX_5H"',"estimated_max_7d":'"$DEFAULT_ESTIMATED_MAX_7D"',"last_total_tokens":0,"last_api_5h":0,"last_api_7d":0,"window_tokens_5h":0,"window_tokens_7d":0}' 2>/dev/null)
        [[ -z "$calibration_json" || "$calibration_json" == "null" ]] && calibration_json='{"estimated_max_5h":'"$DEFAULT_ESTIMATED_MAX_5H"',"estimated_max_7d":'"$DEFAULT_ESTIMATED_MAX_7D"',"last_total_tokens":0,"last_api_5h":0,"last_api_7d":0,"window_tokens_5h":0,"window_tokens_7d":0}'

        # Build sessions object - preserve existing sessions, update current
        local sessions_json
        sessions_json=$(echo "$state" | jq -r '.sessions // {}' 2>/dev/null) || sessions_json="{}"
        sessions_json=$(echo "$sessions_json" | jq --arg sid "$session_id" \
            --argjson inp "$current_input" \
            --argjson out "$current_output" \
            --arg cost "$current_cost" \
            '.[$sid] = {"last_input": $inp, "last_output": $out, "last_cost": ($cost | tonumber)}' 2>/dev/null) || sessions_json="{}"

        debug_log "Writing state file with sessions: $(echo "$sessions_json" | jq -c '.')"

        # Write updated state (preserving calibration block)
        cat > "$STATE_FILE" << EOF
{
  "current_plan": "${CURRENT_PLAN}",
  "last_5h_reset": "${last_5h}",
  "last_7d_reset": "${last_7d}",
  "sessions": ${sessions_json},
  "totals": {
    "input_tokens": ${new_total_input},
    "output_tokens": ${new_total_output},
    "total_cost_usd": ${new_total_cost}
  },
  "calibration": ${calibration_json}
}
EOF
        debug_log "State file written successfully"

        # Run compaction if needed (non-blocking, runs only when threshold exceeded)
        compact_sessions
    else
        debug_log "No change detected (delta_total=$delta_total), skipping write"
    fi

    # Return total tokens (input + output)
    echo "$((new_total_input + new_total_output))"
}

# Get total accumulated cost from state file
get_total_cost_ever() {
    if [[ -f "$STATE_FILE" ]]; then
        local cost
        cost=$(jq -r '.totals.total_cost_usd // 0' "$STATE_FILE" 2>/dev/null) || cost="0"
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

# Get max context for model (usable = auto-compact threshold or full)
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

    # Progressbar mode: "auto-compact" (default) or "full"
    # - auto-compact: 100% = when auto-compact triggers
    # - full: 100% = full context window (for users with auto-compact disabled)
    local progressbar_mode="${CLAUDE_MB_LIMIT_PROGRESSBAR_MODE:-auto-compact}"

    local usable_tokens
    if [[ "$progressbar_mode" == "full" ]]; then
        # Full mode: progressbar shows full context usage
        usable_tokens="$max_tokens"
    else
        # Auto-compact mode: progressbar shows distance to auto-compact trigger
        # Get threshold from env (default: 85% based on observed Claude Code behavior)
        local auto_compact_pct="${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-85}"

        # Validate: must be number between 1-100
        if ! [[ "$auto_compact_pct" =~ ^[0-9]+$ ]] || [[ "$auto_compact_pct" -lt 1 ]]; then
            auto_compact_pct=85
        elif [[ "$auto_compact_pct" -gt 100 ]]; then
            auto_compact_pct=100
        fi

        # Usable = threshold% of max (point where auto-compact triggers)
        usable_tokens=$((max_tokens * auto_compact_pct / 100))
    fi

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

            # Add git line
            if [[ -n "$git_line" ]]; then
                lines+=("$git_line")
            fi
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

    # Tokens values
    if [[ "$SHOW_TOKENS" == "true" ]]; then
        local in_tokens out_tokens cache_read total_tokens
        in_tokens=$(get_token_metrics "input")
        out_tokens=$(get_token_metrics "output")
        cache_read=$(get_token_metrics "cache_read")
        total_tokens=$((in_tokens + out_tokens))

        tok_val1=$(format_tokens "$in_tokens")
        tok_val2=$(format_tokens "$out_tokens")
        tok_val3=$(format_tokens "$cache_read")
        tok_val4=$(format_tokens "$total_tokens")
    fi

    # Context values
    # Store usable percentage and bar for Session line (moved from Context line)
    local ctx_usable_pct="" ctx_usable_bar=""
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

        usable_tokens=$(get_model_context_config "usable")
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
        printf -v tok_line "Tokens  -> Input: %${col1_width}s    Output: %${col2_width}s    Cached: %${col3_width}s    User Tokens: %${col4_padded_width}s" \
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
            # Format progress bar percentage right-aligned using col4_width
            local sess_pct_formatted
            printf -v sess_pct_formatted "%${col4_width}s" "${ctx_usable_pct}%"
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
        # Format: {Model} | Style: {style} | LifetimeTotal: {tokens} ${cost} | Device: {device}
        if [[ "$SHOW_MODEL" == "true" ]] && [[ -n "$current_model_sess" ]]; then
            # Get lifetime tokens from JSONL files (main + subagent)
            local main_tokens_lifetime subagent_tokens_lifetime total_tokens_lifetime
            main_tokens_lifetime=$(get_main_agent_tokens 2>/dev/null) || main_tokens_lifetime=0
            [[ "$main_tokens_lifetime" == "null" ]] && main_tokens_lifetime=0
            subagent_tokens_lifetime=$(get_subagent_tokens 2>/dev/null) || subagent_tokens_lifetime=0
            [[ "$subagent_tokens_lifetime" == "null" ]] && subagent_tokens_lifetime=0
            total_tokens_lifetime=$((main_tokens_lifetime + subagent_tokens_lifetime))

            local formatted_tokens_lifetime=""
            local total_cost_lifetime="0.00"
            if [[ "$total_tokens_lifetime" -gt 0 ]]; then
                formatted_tokens_lifetime=$(format_tokens "$total_tokens_lifetime")
                # Get cost from JSONL-based calculation (main + subagent)
                local main_cost_lifetime subagent_cost_lifetime
                main_cost_lifetime=$(get_main_agent_cost 2>/dev/null) || main_cost_lifetime=0
                [[ "$main_cost_lifetime" == "null" ]] && main_cost_lifetime=0
                subagent_cost_lifetime=$(get_subagent_cost 2>/dev/null) || subagent_cost_lifetime=0
                [[ "$subagent_cost_lifetime" == "null" ]] && subagent_cost_lifetime=0
                total_cost_lifetime=$(awk -v m="$main_cost_lifetime" -v s="$subagent_cost_lifetime" 'BEGIN {printf "%.2f", m + s}')
            fi

            local model_line=""
            model_line="${model_name_color_sess}${current_model_sess}${model_color_reset_sess}"
            model_line="${model_line}${gray_color} | Style: ${style_sess}"
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

    # IMPORTANT: Call get_total_tokens_ever FIRST to update state file totals
    # This ensures window tokens can be calculated from session totals
    local _total_tokens_sync=""
    if [[ "$SHOW_LOCAL" == "true" ]]; then
        _total_tokens_sync=$(get_total_tokens_ever)
        debug_log "Synced totals before highscore tracking: $_total_tokens_sync"
    fi

    # Highscore-based local tracking:
    # - Tracks highest token usage per plan (max20, max5, pro, unknown)
    # - 5h and 7d are SEPARATE highscores
    # - Highscores can only INCREASE, never decrease
    # - Converges to true limit over time
    # - local_pct = window_tokens * 100 / highscore
    # - LimitAt: When highscore is broken at >95% API utilization, we've found the real limit!
    local local_5h_pct="" local_7d_pct=""
    local highscore_5h=0 highscore_7d=0
    local window_tokens_5h=0 window_tokens_7d=0
    local limit_at_5h="" limit_at_7d=""

    if [[ "$SHOW_LOCAL" == "true" ]]; then
        # Initialize highscore state if needed
        init_state

        # Update current plan in highscore state
        set_current_plan "$CURRENT_PLAN"

        # Get current total tokens from session tracking
        local current_total_tokens=0
        if [[ -f "$STATE_FILE" ]]; then
            local in_tok out_tok
            in_tok=$(jq -r '.totals.input_tokens // 0' "$STATE_FILE" 2>/dev/null) || in_tok=0
            out_tok=$(jq -r '.totals.output_tokens // 0' "$STATE_FILE" 2>/dev/null) || out_tok=0
            [[ "$in_tok" == "null" ]] && in_tok=0
            [[ "$out_tok" == "null" ]] && out_tok=0
            current_total_tokens=$((in_tok + out_tok))
        fi

        # Reset detection: check if API reset times have changed
        # If reset time changed, window tokens are reset to 0
        # Also save subagent token baseline at reset time
        # Note: Skip reset detection when API is unavailable (no reset times)
        local reset_5h_detected=false reset_7d_detected=false
        if [[ "$api_available" == "true" ]]; then
            if check_reset "5h" "$five_hour_reset"; then
                reset_5h_detected=true
            fi
            if [[ -n "$seven_day_reset" ]]; then
                if check_reset "7d" "$seven_day_reset"; then
                    reset_7d_detected=true
                fi
            fi
        fi

        # Get subagent tokens (incremental scan with caching)
        local subagent_tokens_total=0
        subagent_tokens_total=$(get_subagent_tokens 2>/dev/null) || subagent_tokens_total=0
        [[ "$subagent_tokens_total" == "null" ]] && subagent_tokens_total=0
        debug_log "Subagent tokens total: $subagent_tokens_total"

        # Get subagent baseline from state (saved at last reset)
        local subagent_baseline_5h=0 subagent_baseline_7d=0
        if [[ -f "$STATE_FILE" ]]; then
            subagent_baseline_5h=$(jq -r '.calibration.subagent_baseline_5h // 0' "$STATE_FILE" 2>/dev/null) || subagent_baseline_5h=0
            subagent_baseline_7d=$(jq -r '.calibration.subagent_baseline_7d // 0' "$STATE_FILE" 2>/dev/null) || subagent_baseline_7d=0
            [[ "$subagent_baseline_5h" == "null" ]] && subagent_baseline_5h=0
            [[ "$subagent_baseline_7d" == "null" ]] && subagent_baseline_7d=0
        fi

        # Initialize baseline to current total on first run (prevents historical tokens in window)
        # This ensures that only tokens since plugin install count toward the window
        if [[ "$subagent_baseline_5h" -eq 0 ]] && [[ "$subagent_tokens_total" -gt 0 ]]; then
            subagent_baseline_5h="$subagent_tokens_total"
            debug_log "Initialized 5h subagent baseline to current total: $subagent_baseline_5h"
        fi
        if [[ "$subagent_baseline_7d" -eq 0 ]] && [[ "$subagent_tokens_total" -gt 0 ]]; then
            subagent_baseline_7d="$subagent_tokens_total"
            debug_log "Initialized 7d subagent baseline to current total: $subagent_baseline_7d"
        fi

        # On reset, update baseline to current subagent total
        if [[ "$reset_5h_detected" == "true" ]]; then
            subagent_baseline_5h="$subagent_tokens_total"
            debug_log "5h reset: new subagent baseline = $subagent_baseline_5h"
        fi
        if [[ "$reset_7d_detected" == "true" ]]; then
            subagent_baseline_7d="$subagent_tokens_total"
            debug_log "7d reset: new subagent baseline = $subagent_baseline_7d"
        fi

        # Calculate subagent window tokens (tokens since last reset)
        local subagent_window_5h=$((subagent_tokens_total - subagent_baseline_5h))
        local subagent_window_7d=$((subagent_tokens_total - subagent_baseline_7d))
        [[ "$subagent_window_5h" -lt 0 ]] && subagent_window_5h=0
        [[ "$subagent_window_7d" -lt 0 ]] && subagent_window_7d=0
        debug_log "Subagent window tokens: 5h=$subagent_window_5h 7d=$subagent_window_7d"

        # Get current window tokens from highscore state
        window_tokens_5h=$(get_window_tokens "5h")
        window_tokens_7d=$(get_window_tokens "7d")

        # Calculate token delta since last update (main agent only)
        local last_total_tokens=0
        if [[ -f "$STATE_FILE" ]]; then
            last_total_tokens=$(jq -r '.calibration.last_total_tokens // 0' "$STATE_FILE" 2>/dev/null) || last_total_tokens=0
            [[ "$last_total_tokens" == "null" ]] && last_total_tokens=0
        fi
        local token_delta=$((current_total_tokens - last_total_tokens))
        [[ "$token_delta" -lt 0 ]] && token_delta=0

        # Accumulate main agent tokens to window counters
        window_tokens_5h=$((window_tokens_5h + token_delta))
        window_tokens_7d=$((window_tokens_7d + token_delta))

        # Update window tokens in highscore state (main agent only, before adding subagent)
        set_window_tokens "5h" "$window_tokens_5h"
        set_window_tokens "7d" "$window_tokens_7d"

        # Add subagent window tokens to display totals
        # These are already relative to the baseline at reset time
        window_tokens_5h=$((window_tokens_5h + subagent_window_5h))
        window_tokens_7d=$((window_tokens_7d + subagent_window_7d))
        debug_log "Window tokens with subagents: 5h=$window_tokens_5h 7d=$window_tokens_7d"


        # Get highscores for current plan
        highscore_5h=$(get_highscore "$CURRENT_PLAN" "5h")
        highscore_7d=$(get_highscore "$CURRENT_PLAN" "7d")

        # Update highscores if window_tokens exceed current highscore
        # Highscores can only increase, never decrease
        if update_highscore "$CURRENT_PLAN" "5h" "$window_tokens_5h"; then
            highscore_5h="$window_tokens_5h"
            debug_log "New 5h highscore for $CURRENT_PLAN: $highscore_5h"

            # LimitAt Easter-Egg: If new highscore AND API utilization >= 95%,
            # we've found the real user limit!
            # Use awk for float comparison since bash arithmetic doesn't support floats
            local five_pct_in_range
            five_pct_in_range=$(awk "BEGIN {print ($five_pct >= 95 && $five_pct <= 100) ? 1 : 0}")
            if [[ "$five_pct_in_range" -eq 1 ]]; then
                set_limit_at "$CURRENT_PLAN" "5h" "$window_tokens_5h"
                debug_log "LimitAt 5h discovered for $CURRENT_PLAN: $window_tokens_5h at ${five_pct}% API"
            fi
        fi
        if update_highscore "$CURRENT_PLAN" "7d" "$window_tokens_7d"; then
            highscore_7d="$window_tokens_7d"
            debug_log "New 7d highscore for $CURRENT_PLAN: $highscore_7d"

            # LimitAt Easter-Egg: If new highscore AND API utilization >= 95%,
            # we've found the real user limit!
            # Use awk for float comparison since bash arithmetic doesn't support floats
            if [[ -n "$seven_pct" ]]; then
                local seven_pct_in_range
                seven_pct_in_range=$(awk "BEGIN {print ($seven_pct >= 95 && $seven_pct <= 100) ? 1 : 0}")
                if [[ "$seven_pct_in_range" -eq 1 ]]; then
                    set_limit_at "$CURRENT_PLAN" "7d" "$window_tokens_7d"
                    debug_log "LimitAt 7d discovered for $CURRENT_PLAN: $window_tokens_7d at ${seven_pct}% API"
                fi
            fi
        fi

        # Calculate local percentage: window_tokens * 100 / highscore
        # Uses decimal with one digit precision and commercial rounding
        if [[ "$highscore_5h" -gt 0 ]]; then
            local_5h_pct=$(awk "BEGIN {pct = ($window_tokens_5h * 100) / $highscore_5h; if (pct > 100) pct = 100; printf \"%.1f\", pct}")
            debug_log "5h: window=$window_tokens_5h highscore=$highscore_5h pct=$local_5h_pct"
        else
            local_5h_pct="0.0"
        fi

        if [[ -n "$seven_pct" ]] && [[ "$highscore_7d" -gt 0 ]]; then
            local_7d_pct=$(awk "BEGIN {pct = ($window_tokens_7d * 100) / $highscore_7d; if (pct > 100) pct = 100; printf \"%.1f\", pct}")
            debug_log "7d: window=$window_tokens_7d highscore=$highscore_7d pct=$local_7d_pct"
        fi

        # Retrieve LimitAt values (Easter-Egg: discovered when hitting >95% API)
        limit_at_5h=$(get_limit_at "$CURRENT_PLAN" "5h")
        limit_at_7d=$(get_limit_at "$CURRENT_PLAN" "7d")
        debug_log "LimitAt: 5h=$limit_at_5h 7d=$limit_at_7d"

        # Update legacy state file with last_total_tokens for delta calculation
        ensure_plugin_dir
        local existing_sessions="{}" existing_totals='{"input_tokens":0,"output_tokens":0,"total_cost_usd":0}'
        local existing_5h_reset="" existing_7d_reset=""
        if [[ -f "$STATE_FILE" ]]; then
            existing_sessions=$(jq -r '.sessions // {}' "$STATE_FILE" 2>/dev/null) || existing_sessions="{}"
            existing_totals=$(jq -c '.totals // {"input_tokens":0,"output_tokens":0,"total_cost_usd":0}' "$STATE_FILE" 2>/dev/null) || existing_totals='{"input_tokens":0,"output_tokens":0,"total_cost_usd":0}'
            existing_5h_reset=$(jq -r '.last_5h_reset // ""' "$STATE_FILE" 2>/dev/null) || existing_5h_reset=""
            existing_7d_reset=$(jq -r '.last_7d_reset // ""' "$STATE_FILE" 2>/dev/null) || existing_7d_reset=""
            [[ "$existing_sessions" == "null" ]] && existing_sessions="{}"
            [[ "$existing_totals" == "null" ]] && existing_totals='{"input_tokens":0,"output_tokens":0,"total_cost_usd":0}'
            [[ "$existing_5h_reset" == "null" ]] && existing_5h_reset=""
            [[ "$existing_7d_reset" == "null" ]] && existing_7d_reset=""
        fi

        # Use API reset times if available, otherwise preserve existing values
        local state_5h_reset="${five_hour_reset:-$existing_5h_reset}"
        local state_7d_reset="${seven_day_reset:-$existing_7d_reset}"

        # Write minimal state for session tracking (highscores are in separate file)
        cat > "$STATE_FILE" << EOF
{
  "current_plan": "${CURRENT_PLAN}",
  "last_5h_reset": "${state_5h_reset}",
  "last_7d_reset": "${state_7d_reset}",
  "sessions": ${existing_sessions},
  "totals": ${existing_totals},
  "calibration": {
    "last_total_tokens": ${current_total_tokens},
    "subagent_baseline_5h": ${subagent_baseline_5h},
    "subagent_baseline_7d": ${subagent_baseline_7d}
  }
}
EOF
        debug_log "Highscore tracking: plan=$CURRENT_PLAN window_5h=$window_tokens_5h window_7d=$window_tokens_7d hs_5h=$highscore_5h hs_7d=$highscore_7d local_5h_pct=$local_5h_pct local_7d_pct=$local_7d_pct"

        # Append history entry (respects 10-min interval and retention cleanup)
        if [[ "$api_available" == "true" ]]; then
            append_history \
                "${five_pct:-0}" "$window_tokens_5h" "$highscore_5h" \
                "${seven_pct:-0}" "$window_tokens_7d" "$highscore_7d" \
                "${opus_pct:-0}" "${sonnet_pct:-0}" \
                "$CURRENT_PLAN" "$LOCAL_DEVICE_LABEL"
        fi
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
            lines+=("$(format_limit_line "5h all" "${local_5h_pct}" "" 1) ${local_5h_color}[Highest:${window_5h_formatted}/${hs_5h_formatted}] (${LOCAL_DEVICE_LABEL})${local_5h_color_reset}")
        fi
    else
        # Normal mode: API available, show all limits

        # Calculate averages from history (for [Average:X%/Y%] display)
        local avg_5h_local="" avg_5h_api="" avg_7d_local="" avg_7d_api=""
        local avg_opus="" avg_sonnet=""
        if [[ "$SHOW_AVERAGE" == "true" ]]; then
            # Local averages (this device only, over 24h for 5h window, 168h for 7d)
            avg_5h_local=$(get_local_average '."5h".api' 24 "$LOCAL_DEVICE_LABEL")
            avg_7d_local=$(get_local_average '."7d".api' 168 "$LOCAL_DEVICE_LABEL")
            # API averages (all devices, same time windows)
            avg_5h_api=$(get_average '."5h".api' 24)
            avg_7d_api=$(get_average '."7d".api' 168)
            # Model averages (API only, no local tracking)
            avg_opus=$(get_average '.opus' 168)
            avg_sonnet=$(get_average '.sonnet' 168)
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
            # Global 5h line - append [LimitAt:X.XM] Easter-Egg if discovered
            local global_5h_line global_5h_color="" global_5h_color_reset=""
            if [[ "$SHOW_COLORS" == "true" ]]; then
                global_5h_color=$(get_color "$five_pct")
                global_5h_color_reset="${COLOR_RESET}"
            fi
            global_5h_line="$(format_limit_line "5h all" "$five_pct" "$five_hour_reset")"
            if [[ "$SHOW_LOCAL" == "true" ]] && [[ -n "$limit_at_5h" ]] && [[ "$limit_at_5h" != "null" ]]; then
                local limit_at_5h_fmt window_5h_limit_fmt
                limit_at_5h_fmt=$(format_highscore "$limit_at_5h")
                window_5h_limit_fmt=$(format_highscore "$window_tokens_5h")
                global_5h_line="${global_5h_line} ${global_5h_color}[LimitAt:${window_5h_limit_fmt}/${limit_at_5h_fmt}]${global_5h_color_reset}"
            fi
            # Append [Average:LOCAL%/API%] if available
            if [[ "$SHOW_AVERAGE" == "true" ]] && [[ -n "$avg_5h_local" || -n "$avg_5h_api" ]]; then
                local avg_5h_display="${avg_5h_local:-n/a}%/${avg_5h_api:-n/a}%"
                global_5h_line="${global_5h_line} ${global_5h_color}[Average:${avg_5h_display}]${global_5h_color_reset}"
            fi
            lines+=("$global_5h_line")
            # Local 5h directly below global 5h - shows highscore-based percentage
            if [[ "$SHOW_LOCAL" == "true" ]] && [[ -n "${local_5h_pct}" ]]; then
                local local_5h_color="" local_5h_color_reset=""
                if [[ "$SHOW_COLORS" == "true" ]]; then
                    local_5h_color=$(get_color "${local_5h_pct}")
                    local_5h_color_reset="${COLOR_RESET}"
                fi
                # Format current window tokens and highscore (e.g., 150.0k/1.5M)
                local window_5h_formatted hs_5h_formatted
                window_5h_formatted=$(format_highscore "$window_tokens_5h")
                hs_5h_formatted=$(format_highscore "$highscore_5h")
                lines+=("$(format_limit_line "5h all" "${local_5h_pct}" "$five_hour_reset" 1) ${local_5h_color}[Highest:${window_5h_formatted}/${hs_5h_formatted}] (${LOCAL_DEVICE_LABEL})${achievement_5h}${local_5h_color_reset}")
            fi
        fi

        # 7-day limit (if enabled and available) - all models
        if [[ "$SHOW_7D" == "true" ]] && [[ -n "$seven_pct" ]]; then
            # Global 7d line - append [LimitAt:X.XM] Easter-Egg if discovered
            local global_7d_line global_7d_color="" global_7d_color_reset=""
            if [[ "$SHOW_COLORS" == "true" ]]; then
                global_7d_color=$(get_color "$seven_pct")
                global_7d_color_reset="${COLOR_RESET}"
            fi
            global_7d_line="$(format_limit_line "7d all" "$seven_pct" "$seven_day_reset")"
            if [[ "$SHOW_LOCAL" == "true" ]] && [[ -n "$limit_at_7d" ]] && [[ "$limit_at_7d" != "null" ]]; then
                local limit_at_7d_fmt window_7d_limit_fmt
                limit_at_7d_fmt=$(format_highscore "$limit_at_7d")
                window_7d_limit_fmt=$(format_highscore "$window_tokens_7d")
                global_7d_line="${global_7d_line} ${global_7d_color}[LimitAt:${window_7d_limit_fmt}/${limit_at_7d_fmt}]${global_7d_color_reset}"
            fi
            # Append [Average:LOCAL%/API%] if available
            if [[ "$SHOW_AVERAGE" == "true" ]] && [[ -n "$avg_7d_local" || -n "$avg_7d_api" ]]; then
                local avg_7d_display="${avg_7d_local:-n/a}%/${avg_7d_api:-n/a}%"
                global_7d_line="${global_7d_line} ${global_7d_color}[Average:${avg_7d_display}]${global_7d_color_reset}"
            fi
            lines+=("$global_7d_line")
            # Local 7d directly below global 7d - shows highscore-based percentage
            if [[ "$SHOW_LOCAL" == "true" ]] && [[ -n "${local_7d_pct}" ]]; then
                local local_7d_color="" local_7d_color_reset=""
                if [[ "$SHOW_COLORS" == "true" ]]; then
                    local_7d_color=$(get_color "${local_7d_pct}")
                    local_7d_color_reset="${COLOR_RESET}"
                fi
                # Format current window tokens and highscore (e.g., 150.0k/1.5M)
                local window_7d_formatted hs_7d_formatted
                window_7d_formatted=$(format_highscore "$window_tokens_7d")
                hs_7d_formatted=$(format_highscore "$highscore_7d")
                lines+=("$(format_limit_line "7d all" "${local_7d_pct}" "$seven_day_reset" 1) ${local_7d_color}[Highest:${window_7d_formatted}/${hs_7d_formatted}] (${LOCAL_DEVICE_LABEL})${achievement_7d}${local_7d_color_reset}")
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
            # Append [Average:X%] for Opus (API only, no local tracking)
            if [[ "$SHOW_AVERAGE" == "true" ]] && [[ -n "$avg_opus" ]]; then
                opus_line="${opus_line} ${opus_color}[Average:${avg_opus}%]${opus_color_reset}"
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
                # Append [Average:X%] for Sonnet (API only, no local tracking)
                if [[ "$SHOW_AVERAGE" == "true" ]] && [[ -n "$avg_sonnet" ]]; then
                    sonnet_line="${sonnet_line} ${sonnet_color}[Average:${avg_sonnet}%]${sonnet_color_reset}"
                fi
                lines+=("$sonnet_line")
            fi
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
    # Ensure plugin directory exists and migrate old state files if needed
    ensure_plugin_dir
    migrate_old_state_files

    # Read stdin data from Claude Code first (contains model info)
    read_stdin_data

    local token="" response=""

    # Check dependencies - if missing, skip API calls but continue with local data
    if check_dependencies; then
        token=$(get_token)
        response=$(fetch_usage "$token")
    fi

    # Debug logging
    debug_log "=== Statusline execution ==="
    debug_log "Stdin data: $STDIN_DATA"
    debug_log "API response: $response"

    format_output "$response"
}

main
