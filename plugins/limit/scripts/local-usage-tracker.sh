#!/usr/bin/env bash
# local-usage-tracker.sh - Track API usage per device with reset-aware delta tracking
# Stores delta tokens per API call with reset_id for correct percentage calculation

set -euo pipefail

# Feature toggle - disabled by default (feature in development)
if [[ "${CLAUDE_MB_LIMIT_LOCAL:-false}" != "true" ]]; then
    exit 0
fi

# Configuration
USAGE_FILE="${HOME}/.claude/limit-local-usage.json"
STATE_FILE="${HOME}/.claude/limit-local-state.json"
DEVICE_ID="${CLAUDE_MB_LIMIT_DEVICE_LABEL:-$(hostname)}"

# Read stdin data from Claude Code (JSON with token info)
STDIN_DATA=""
if [[ ! -t 0 ]]; then
    STDIN_DATA=$(timeout 0.5 head -n 1 2>/dev/null) || STDIN_DATA=""
fi

# Exit silently if no stdin data
if [[ -z "${STDIN_DATA}" ]]; then
    exit 0
fi

# Extract current token counts from stdin JSON
current_input=$(echo "${STDIN_DATA}" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null) || current_input=0
current_output=$(echo "${STDIN_DATA}" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null) || current_output=0

# Handle null values
[[ "${current_input}" == "null" ]] && current_input=0
[[ "${current_output}" == "null" ]] && current_output=0

# Skip if no tokens recorded
if [[ "${current_input}" == "0" ]] && [[ "${current_output}" == "0" ]]; then
    exit 0
fi

# Create directory if needed
mkdir -p "$(dirname "${STATE_FILE}")" 2>/dev/null || true

# Initialize state file if it doesn't exist
if [[ ! -f "${STATE_FILE}" ]]; then
    cat > "${STATE_FILE}" << 'EOF'
{
  "last_input_tokens": 0,
  "last_output_tokens": 0,
  "last_5h_reset": "",
  "last_7d_reset": "",
  "total_tokens_ever": 0
}
EOF
fi

# Read previous state
last_input=$(jq -r '.last_input_tokens // 0' "${STATE_FILE}" 2>/dev/null) || last_input=0
last_output=$(jq -r '.last_output_tokens // 0' "${STATE_FILE}" 2>/dev/null) || last_output=0
last_5h_reset=$(jq -r '.last_5h_reset // ""' "${STATE_FILE}" 2>/dev/null) || last_5h_reset=""
last_7d_reset=$(jq -r '.last_7d_reset // ""' "${STATE_FILE}" 2>/dev/null) || last_7d_reset=""
total_tokens_ever=$(jq -r '.total_tokens_ever // 0' "${STATE_FILE}" 2>/dev/null) || total_tokens_ever=0

# Handle null/empty values
[[ "${last_input}" == "null" ]] && last_input=0
[[ "${last_output}" == "null" ]] && last_output=0
[[ "${last_5h_reset}" == "null" ]] && last_5h_reset=""
[[ "${last_7d_reset}" == "null" ]] && last_7d_reset=""
[[ "${total_tokens_ever}" == "null" ]] && total_tokens_ever=0

# Calculate delta tokens (current - last)
# If current < last, this is a new session, so use current as delta
if [[ "${current_input}" -lt "${last_input}" ]] || [[ "${current_output}" -lt "${last_output}" ]]; then
    # New session detected (counters reset)
    delta_input="${current_input}"
    delta_output="${current_output}"
else
    delta_input=$((current_input - last_input))
    delta_output=$((current_output - last_output))
fi

# Skip if no new tokens
if [[ "${delta_input}" == "0" ]] && [[ "${delta_output}" == "0" ]]; then
    exit 0
fi

# Calculate total delta for this call
delta_total=$((delta_input + delta_output))

# Update total_tokens_ever (never resets)
total_tokens_ever=$((total_tokens_ever + delta_total))

# Get current timestamp
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Try to get reset times from API cache (if available)
CACHE_FILE="/tmp/claude-mb-limit-cache.json"
current_5h_reset=""
current_7d_reset=""

if [[ -f "${CACHE_FILE}" ]]; then
    current_5h_reset=$(jq -r '.five_hour.resets_at // ""' "${CACHE_FILE}" 2>/dev/null) || current_5h_reset=""
    current_7d_reset=$(jq -r '.seven_day.resets_at // ""' "${CACHE_FILE}" 2>/dev/null) || current_7d_reset=""
    [[ "${current_5h_reset}" == "null" ]] && current_5h_reset=""
    [[ "${current_7d_reset}" == "null" ]] && current_7d_reset=""
fi

# Generate reset_ids based on reset times
# Format: "5h-YYYY-MM-DDTHH:MM" (truncated to minute)
generate_reset_id() {
    local prefix="$1"
    local reset_at="$2"
    if [[ -n "${reset_at}" ]]; then
        # Truncate to minute: "2026-01-16T05:00:00Z" -> "5h-2026-01-16T05:00"
        echo "${prefix}-${reset_at:0:16}"
    else
        # Fallback: use current hour window
        local current_hour
        current_hour=$(date -u +"%Y-%m-%dT%H:00")
        echo "${prefix}-${current_hour}"
    fi
}

reset_id_5h=$(generate_reset_id "5h" "${current_5h_reset}")
reset_id_7d=$(generate_reset_id "7d" "${current_7d_reset}")

# Detect reset: if reset time changed, log it
reset_detected=""
if [[ -n "${current_5h_reset}" ]] && [[ "${current_5h_reset}" != "${last_5h_reset}" ]] && [[ -n "${last_5h_reset}" ]]; then
    reset_detected="5h"
fi
if [[ -n "${current_7d_reset}" ]] && [[ "${current_7d_reset}" != "${last_7d_reset}" ]] && [[ -n "${last_7d_reset}" ]]; then
    reset_detected="${reset_detected}${reset_detected:+,}7d"
fi

# Append usage event as JSONL (one JSON object per line)
# Format: {"ts":"ISO8601","device":"label","in":N,"out":N,"reset_5h":"id","reset_7d":"id"}
printf '{"ts":"%s","device":"%s","in":%s,"out":%s,"reset_5h":"%s","reset_7d":"%s"}\n' \
    "${timestamp}" "${DEVICE_ID}" "${delta_input}" "${delta_output}" \
    "${reset_id_5h}" "${reset_id_7d}" >> "${USAGE_FILE}" 2>/dev/null || true

# Update state file with current values
# Use temp file for atomic update
STATE_TMP="${STATE_FILE}.tmp"
cat > "${STATE_TMP}" << EOF
{
  "last_input_tokens": ${current_input},
  "last_output_tokens": ${current_output},
  "last_5h_reset": "${current_5h_reset}",
  "last_7d_reset": "${current_7d_reset}",
  "total_tokens_ever": ${total_tokens_ever}
}
EOF
mv "${STATE_TMP}" "${STATE_FILE}" 2>/dev/null || true

exit 0
