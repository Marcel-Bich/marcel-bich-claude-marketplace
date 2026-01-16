#!/usr/bin/env bash
# local-usage-tracker.sh - Track API usage per device for local usage analysis
# Stores usage events in JSONL format with device identifier

set -euo pipefail

# Feature toggle - disabled by default (feature in development)
if [[ "${CLAUDE_MB_LIMIT_LOCAL:-false}" != "true" ]]; then
    exit 0
fi

# Configuration
USAGE_FILE="${HOME}/.claude/limit-local-usage.json"
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

# Extract token counts from stdin JSON
# Uses context_window totals for session-wide metrics
input_tokens=$(echo "${STDIN_DATA}" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null) || input_tokens=0
output_tokens=$(echo "${STDIN_DATA}" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null) || output_tokens=0

# Handle null values
[[ "${input_tokens}" == "null" ]] && input_tokens=0
[[ "${output_tokens}" == "null" ]] && output_tokens=0

# Skip if no tokens recorded
if [[ "${input_tokens}" == "0" ]] && [[ "${output_tokens}" == "0" ]]; then
    exit 0
fi

# Get current timestamp in ISO8601 format
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Create usage directory if needed
mkdir -p "$(dirname "${USAGE_FILE}")" 2>/dev/null || true

# Append usage event as JSONL (one JSON object per line)
# Format: {"timestamp":"ISO8601","device":"label","input_tokens":N,"output_tokens":N}
printf '{"timestamp":"%s","device":"%s","input_tokens":%s,"output_tokens":%s}\n' \
    "${timestamp}" "${DEVICE_ID}" "${input_tokens}" "${output_tokens}" >> "${USAGE_FILE}" 2>/dev/null || true

exit 0
