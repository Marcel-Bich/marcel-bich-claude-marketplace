#!/usr/bin/env bash
# highscore-state.sh - Highscore state management for limit plugin
# Tracks highest token usage per plan (max20, max5, pro, unknown)
# 5h and 7d windows are tracked separately
# shellcheck disable=SC2250

set -euo pipefail

# State file location
HIGHSCORE_STATE_FILE="${HOME}/.claude/limit-highscore-state.json"

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

# =============================================================================
# State file operations
# =============================================================================

# Initialize state file with defaults if it doesn't exist
# Usage: init_state
init_state() {
    if [[ -f "${HIGHSCORE_STATE_FILE}" ]]; then
        return 0
    fi

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
  "last_5h_reset": null,
  "last_7d_reset": null
}
EOF
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

    # If reset time changed, window has reset
    if [[ "${new_reset_time}" != "${last_reset}" ]]; then
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
