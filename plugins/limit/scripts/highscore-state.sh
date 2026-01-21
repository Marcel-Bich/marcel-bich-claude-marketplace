#!/usr/bin/env bash
# highscore-state.sh - Highscore state management for limit plugin
# Tracks highest token usage per plan (max20, max5, pro, unknown)
# 5h and 7d windows are tracked separately
# shellcheck disable=SC2250

# =============================================================================
# Theoretical Token Limits (User Calculation - 2026-01-19)
# =============================================================================
# Based on user's calculation:
# - max20 in 5h window: ~12.5M tokens (theoretical maximum)
# - 20% of 5h = 2.5M tokens
# - 1% of 5h = 125k tokens
#
# This could be extrapolated to:
# - max5: proportionally lower
# - pro: even lower
#
# WARNING: These calculations are likely INCORRECT because subagent/Task tool
# tokens were NOT included in the measurement when these numbers were derived.
# Subagents (spawned via Task tool) run in separate sessions and their tokens
# are stored in agent-*.jsonl files, not in the main session's STDIN_DATA.
# The actual limits may be significantly higher than estimated here.
#
# TODO: Re-measure limits with subagent tokens included
# =============================================================================

set -euo pipefail

# State file location
HIGHSCORE_STATE_FILE="${PLUGIN_DATA_DIR:-${HOME}/.claude/marcel-bich-claude-marketplace/limit}/limit-highscore-state.json"

# Default highscore values (conservative estimates)
# These will be exceeded and updated as usage is tracked
declare -A DEFAULT_HIGHSCORES_5H=(
    ["max20"]=1000000
    ["max5"]=500000
    ["pro"]=200000
    ["unknown"]=1000000
)

declare -A DEFAULT_HIGHSCORES_7D=(
    ["max20"]=10000000
    ["max5"]=5000000
    ["pro"]=2000000
    ["unknown"]=10000000
)

# Current schema version - bump on breaking changes to trigger reset
HIGHSCORE_SCHEMA_VERSION=1

# Debug logging
HIGHSCORE_DEBUG="${CLAUDE_MB_LIMIT_DEBUG:-0}"
HIGHSCORE_LOG_FILE="${PLUGIN_DATA_DIR:-${HOME}/.claude/marcel-bich-claude-marketplace/limit}/highscore-debug.log"

highscore_log() {
    if [[ "$HIGHSCORE_DEBUG" == "1" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$HIGHSCORE_LOG_FILE"
    fi
}

# Reset state if schema version mismatch (no migration, clean reset)
reset_highscore_if_incompatible() {
    if [[ ! -f "${HIGHSCORE_STATE_FILE}" ]]; then
        return 0
    fi

    local file_version
    file_version=$(jq -r '.schema_version // 0' "${HIGHSCORE_STATE_FILE}" 2>/dev/null) || file_version=0

    if [[ "$file_version" != "$HIGHSCORE_SCHEMA_VERSION" ]]; then
        highscore_log "Schema mismatch: file=$file_version current=$HIGHSCORE_SCHEMA_VERSION - resetting state"
        # Backup old state (single backup, overwrites previous)
        cp "${HIGHSCORE_STATE_FILE}" "${HIGHSCORE_STATE_FILE}.bak" 2>/dev/null || true
        rm -f "${HIGHSCORE_STATE_FILE}"
        highscore_log "Old state backed up to ${HIGHSCORE_STATE_FILE}.bak"
    fi
}

# =============================================================================
# State file operations
# =============================================================================

# Initialize state file with defaults if it doesn't exist
# Usage: init_state
init_state() {
    # Check for schema mismatch first (reset if needed)
    reset_highscore_if_incompatible

    if [[ -f "${HIGHSCORE_STATE_FILE}" ]]; then
        highscore_log "init_state: state file exists"
        return 0
    fi

    highscore_log "init_state: creating new state file"

    # Detect current plan
    local current_plan="unknown"
    local script_dir
    script_dir="$(dirname "$0")"
    if [[ -x "${script_dir}/plan-detect.sh" ]]; then
        current_plan=$("${script_dir}/plan-detect.sh" 2>/dev/null || echo "unknown")
    fi

    # Create state file with default values
    cat > "${HIGHSCORE_STATE_FILE}" << EOF
{
  "schema_version": ${HIGHSCORE_SCHEMA_VERSION},
  "plan": "${current_plan}",
  "highscores": {
    "max20": {"5h": ${DEFAULT_HIGHSCORES_5H[max20]}, "7d": ${DEFAULT_HIGHSCORES_7D[max20]}},
    "max5": {"5h": ${DEFAULT_HIGHSCORES_5H[max5]}, "7d": ${DEFAULT_HIGHSCORES_7D[max5]}},
    "pro": {"5h": ${DEFAULT_HIGHSCORES_5H[pro]}, "7d": ${DEFAULT_HIGHSCORES_7D[pro]}},
    "unknown": {"5h": ${DEFAULT_HIGHSCORES_5H[unknown]}, "7d": ${DEFAULT_HIGHSCORES_7D[unknown]}}
  },
  "limits_at": {
    "max20": {"5h": null, "7d": null},
    "max5": {"5h": null, "7d": null},
    "pro": {"5h": null, "7d": null},
    "unknown": {"5h": null, "7d": null}
  },
  "window_tokens_5h": 0,
  "window_tokens_7d": 0,
  "subagent_window_5h": 0,
  "subagent_window_7d": 0,
  "subagent_baseline_5h": 0,
  "subagent_baseline_7d": 0,
  "last_5h_reset": null,
  "last_7d_reset": null
}
EOF
    highscore_log "init_state: state file created"
    return 0
}

# Get highscore for a specific plan and window
# Usage: get_highscore <plan> <window>
# Example: get_highscore max20 5h
get_highscore() {
    local plan="${1:-unknown}"
    local window="${2:-5h}"

    init_state

    local highscore
    highscore=$(jq -r ".highscores[\"${plan}\"][\"${window}\"] // 0" "${HIGHSCORE_STATE_FILE}" 2>/dev/null)

    # If plan not found, fall back to unknown
    if [[ "${highscore}" == "null" ]] || [[ -z "${highscore}" ]]; then
        highscore=$(jq -r ".highscores[\"unknown\"][\"${window}\"] // 0" "${HIGHSCORE_STATE_FILE}" 2>/dev/null)
    fi

    # If still null, return default
    if [[ "${highscore}" == "null" ]] || [[ -z "${highscore}" ]]; then
        if [[ "${window}" == "5h" ]]; then
            highscore="${DEFAULT_HIGHSCORES_5H[unknown]}"
        else
            highscore="${DEFAULT_HIGHSCORES_7D[unknown]}"
        fi
    fi

    echo "${highscore}"
}

# Update highscore - only if new value is higher
# Usage: update_highscore <plan> <window> <tokens>
# Returns: 0 if updated, 1 if not updated (current value higher)
update_highscore() {
    local plan="${1:-unknown}"
    local window="${2:-5h}"
    local tokens="${3:-0}"

    init_state

    local current_highscore
    current_highscore=$(get_highscore "${plan}" "${window}")

    # Only update if tokens > current highscore
    if [[ "${tokens}" -gt "${current_highscore}" ]]; then
        # Update the highscore in state file
        local tmp_file
        tmp_file=$(mktemp)
        jq ".highscores[\"${plan}\"][\"${window}\"] = ${tokens}" "${HIGHSCORE_STATE_FILE}" > "${tmp_file}" && \
            mv "${tmp_file}" "${HIGHSCORE_STATE_FILE}"
        return 0
    fi

    return 1
}

# Get current window tokens
# Usage: get_window_tokens <window>
get_window_tokens() {
    local window="${1:-5h}"

    init_state

    local tokens
    if [[ "${window}" == "5h" ]]; then
        tokens=$(jq -r '.window_tokens_5h // 0' "${HIGHSCORE_STATE_FILE}" 2>/dev/null)
    else
        tokens=$(jq -r '.window_tokens_7d // 0' "${HIGHSCORE_STATE_FILE}" 2>/dev/null)
    fi

    [[ "${tokens}" == "null" ]] && tokens=0
    echo "${tokens}"
}

# Set window tokens
# Usage: set_window_tokens <window> <tokens>
set_window_tokens() {
    local window="${1:-5h}"
    local tokens="${2:-0}"

    init_state

    local tmp_file
    tmp_file=$(mktemp)

    if [[ "${window}" == "5h" ]]; then
        jq ".window_tokens_5h = ${tokens}" "${HIGHSCORE_STATE_FILE}" > "${tmp_file}" && \
            mv "${tmp_file}" "${HIGHSCORE_STATE_FILE}"
    else
        jq ".window_tokens_7d = ${tokens}" "${HIGHSCORE_STATE_FILE}" > "${tmp_file}" && \
            mv "${tmp_file}" "${HIGHSCORE_STATE_FILE}"
    fi
}

# =============================================================================
# Subagent window token tracking (persistent across restarts)
# =============================================================================

# Get subagent window tokens
# Usage: get_subagent_window_tokens <window>
get_subagent_window_tokens() {
    local window="${1:-5h}"

    init_state

    local tokens
    if [[ "${window}" == "5h" ]]; then
        tokens=$(jq -r '.subagent_window_5h // 0' "${HIGHSCORE_STATE_FILE}" 2>/dev/null)
    else
        tokens=$(jq -r '.subagent_window_7d // 0' "${HIGHSCORE_STATE_FILE}" 2>/dev/null)
    fi

    [[ "${tokens}" == "null" ]] && tokens=0
    echo "${tokens}"
}

# Set subagent window tokens
# Usage: set_subagent_window_tokens <window> <tokens>
set_subagent_window_tokens() {
    local window="${1:-5h}"
    local tokens="${2:-0}"

    init_state

    local tmp_file
    tmp_file=$(mktemp)

    if [[ "${window}" == "5h" ]]; then
        jq ".subagent_window_5h = ${tokens}" "${HIGHSCORE_STATE_FILE}" > "${tmp_file}" && \
            mv "${tmp_file}" "${HIGHSCORE_STATE_FILE}"
    else
        jq ".subagent_window_7d = ${tokens}" "${HIGHSCORE_STATE_FILE}" > "${tmp_file}" && \
            mv "${tmp_file}" "${HIGHSCORE_STATE_FILE}"
    fi
}

# Get subagent baseline (saved at last window reset)
# Usage: get_subagent_baseline <window>
get_subagent_baseline() {
    local window="${1:-5h}"

    init_state

    local baseline
    if [[ "${window}" == "5h" ]]; then
        baseline=$(jq -r '.subagent_baseline_5h // 0' "${HIGHSCORE_STATE_FILE}" 2>/dev/null)
    else
        baseline=$(jq -r '.subagent_baseline_7d // 0' "${HIGHSCORE_STATE_FILE}" 2>/dev/null)
    fi

    [[ "${baseline}" == "null" ]] && baseline=0
    echo "${baseline}"
}

# Set subagent baseline (called at window reset)
# Usage: set_subagent_baseline <window> <tokens>
set_subagent_baseline() {
    local window="${1:-5h}"
    local tokens="${2:-0}"

    init_state

    local tmp_file
    tmp_file=$(mktemp)

    if [[ "${window}" == "5h" ]]; then
        jq ".subagent_baseline_5h = ${tokens}" "${HIGHSCORE_STATE_FILE}" > "${tmp_file}" && \
            mv "${tmp_file}" "${HIGHSCORE_STATE_FILE}"
    else
        jq ".subagent_baseline_7d = ${tokens}" "${HIGHSCORE_STATE_FILE}" > "${tmp_file}" && \
            mv "${tmp_file}" "${HIGHSCORE_STATE_FILE}"
    fi
}

# Reset subagent tracking for a window (called when window resets)
# Sets baseline to current total and window to 0
# Usage: reset_subagent_window <window> <current_subagent_total>
reset_subagent_window() {
    local window="${1:-5h}"
    local current_total="${2:-0}"

    init_state

    local tmp_file
    tmp_file=$(mktemp)

    if [[ "${window}" == "5h" ]]; then
        jq ".subagent_baseline_5h = ${current_total} | .subagent_window_5h = 0" "${HIGHSCORE_STATE_FILE}" > "${tmp_file}" && \
            mv "${tmp_file}" "${HIGHSCORE_STATE_FILE}"
    else
        jq ".subagent_baseline_7d = ${current_total} | .subagent_window_7d = 0" "${HIGHSCORE_STATE_FILE}" > "${tmp_file}" && \
            mv "${tmp_file}" "${HIGHSCORE_STATE_FILE}"
    fi
}

# Normalize reset time to hour (round to nearest hour)
# API sometimes returns :59:59, sometimes :00:00 for same reset
# This function extracts YYYY-MM-DD HH for comparison
# Usage: normalize_reset_hour <reset_time>
normalize_reset_hour() {
    local reset_time="${1:-}"

    if [[ -z "${reset_time}" ]] || [[ "${reset_time}" == "null" ]]; then
        echo ""
        return
    fi

    # Extract date and hour from ISO timestamp (e.g., 2026-01-19T12:00:00.123+00:00 -> 2026-01-19T12)
    # Handle both :59:59 and :00:00 by rounding: add 30 minutes then truncate to hour
    local epoch_seconds
    if date --version >/dev/null 2>&1; then
        # GNU date (Linux)
        epoch_seconds=$(date -d "${reset_time} + 30 minutes" "+%s" 2>/dev/null) || { echo "${reset_time:0:13}"; return; }
        date -d "@${epoch_seconds}" "+%Y-%m-%dT%H" 2>/dev/null || echo "${reset_time:0:13}"
    else
        # BSD date (macOS)
        local clean_time="${reset_time%%.*}"
        clean_time="${clean_time%%+*}"
        epoch_seconds=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${clean_time}" "+%s" 2>/dev/null) || { echo "${reset_time:0:13}"; return; }
        epoch_seconds=$((epoch_seconds + 1800))
        date -r "${epoch_seconds}" "+%Y-%m-%dT%H" 2>/dev/null || echo "${reset_time:0:13}"
    fi
}

# Check if window has reset and reset tokens if needed
# Usage: check_reset <window> <new_reset_time>
# Returns: 0 if reset detected (tokens reset to 0), 1 if no reset
check_reset() {
    local window="${1:-5h}"
    local new_reset_time="${2:-}"

    init_state

    if [[ -z "${new_reset_time}" ]] || [[ "${new_reset_time}" == "null" ]]; then
        return 1
    fi

    local last_reset_key
    if [[ "${window}" == "5h" ]]; then
        last_reset_key="last_5h_reset"
    else
        last_reset_key="last_7d_reset"
    fi

    local last_reset
    last_reset=$(jq -r ".${last_reset_key} // \"\"" "${HIGHSCORE_STATE_FILE}" 2>/dev/null)

    # Normalize both times to hour for comparison
    # This prevents false resets when API returns :59:59 vs :00:00
    local new_hour last_hour
    new_hour=$(normalize_reset_hour "${new_reset_time}")
    last_hour=$(normalize_reset_hour "${last_reset}")

    # If normalized hour changed, window has actually reset
    if [[ "${new_hour}" != "${last_hour}" ]]; then
        local tmp_file
        tmp_file=$(mktemp)

        # Update last reset time and reset window tokens to 0
        if [[ "${window}" == "5h" ]]; then
            jq ".last_5h_reset = \"${new_reset_time}\" | .window_tokens_5h = 0" "${HIGHSCORE_STATE_FILE}" > "${tmp_file}" && \
                mv "${tmp_file}" "${HIGHSCORE_STATE_FILE}"
        else
            jq ".last_7d_reset = \"${new_reset_time}\" | .window_tokens_7d = 0" "${HIGHSCORE_STATE_FILE}" > "${tmp_file}" && \
                mv "${tmp_file}" "${HIGHSCORE_STATE_FILE}"
        fi
        return 0
    fi

    return 1
}

# Update the current plan in state
# Usage: set_current_plan <plan>
set_current_plan() {
    local plan="${1:-unknown}"

    init_state

    local tmp_file
    tmp_file=$(mktemp)
    jq ".plan = \"${plan}\"" "${HIGHSCORE_STATE_FILE}" > "${tmp_file}" && \
        mv "${tmp_file}" "${HIGHSCORE_STATE_FILE}"
}

# Get current plan from state
# Usage: get_current_plan
get_current_plan() {
    init_state

    local plan
    plan=$(jq -r '.plan // "unknown"' "${HIGHSCORE_STATE_FILE}" 2>/dev/null)
    [[ "${plan}" == "null" ]] && plan="unknown"
    echo "${plan}"
}

# Update limit_at value (when user hits 100% on API)
# Usage: set_limit_at <plan> <window> <tokens>
set_limit_at() {
    local plan="${1:-unknown}"
    local window="${2:-5h}"
    local tokens="${3:-0}"

    init_state

    local tmp_file
    tmp_file=$(mktemp)
    jq ".limits_at[\"${plan}\"][\"${window}\"] = ${tokens}" "${HIGHSCORE_STATE_FILE}" > "${tmp_file}" && \
        mv "${tmp_file}" "${HIGHSCORE_STATE_FILE}"
}

# Get limit_at value
# Usage: get_limit_at <plan> <window>
get_limit_at() {
    local plan="${1:-unknown}"
    local window="${2:-5h}"

    init_state

    local limit
    limit=$(jq -r ".limits_at[\"${plan}\"][\"${window}\"] // null" "${HIGHSCORE_STATE_FILE}" 2>/dev/null)
    echo "${limit}"
}

# =============================================================================
# CLI interface for testing
# =============================================================================

# If script is called directly (not sourced), provide CLI interface
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        init)
            init_state
            echo "State file initialized: ${HIGHSCORE_STATE_FILE}"
            ;;
        get-highscore)
            get_highscore "${2:-unknown}" "${3:-5h}"
            ;;
        update-highscore)
            if update_highscore "${2:-unknown}" "${3:-5h}" "${4:-0}"; then
                echo "Highscore updated"
            else
                echo "No update (current value higher)"
            fi
            ;;
        get-window-tokens)
            get_window_tokens "${2:-5h}"
            ;;
        set-window-tokens)
            set_window_tokens "${2:-5h}" "${3:-0}"
            echo "Window tokens set"
            ;;
        check-reset)
            if check_reset "${2:-5h}" "${3:-}"; then
                echo "Reset detected, window tokens reset to 0"
            else
                echo "No reset"
            fi
            ;;
        get-plan)
            get_current_plan
            ;;
        set-plan)
            set_current_plan "${2:-unknown}"
            echo "Plan set to ${2:-unknown}"
            ;;
        show)
            jq . < "${HIGHSCORE_STATE_FILE}" 2>/dev/null
            ;;
        *)
            echo "Usage: $0 <command> [args]"
            echo ""
            echo "Commands:"
            echo "  init                          Initialize state file"
            echo "  get-highscore <plan> <window> Get highscore (e.g., max20 5h)"
            echo "  update-highscore <plan> <window> <tokens>"
            echo "  get-window-tokens <window>    Get current window tokens"
            echo "  set-window-tokens <window> <tokens>"
            echo "  check-reset <window> <reset_time>"
            echo "  get-plan                      Get current plan"
            echo "  set-plan <plan>               Set current plan"
            echo "  show                          Show full state"
            ;;
    esac
fi
