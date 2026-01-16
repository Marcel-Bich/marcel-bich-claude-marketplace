#!/bin/bash
# debug-local-usage.sh - Debug local device tracking
# Shows state file contents and delta calculations

set -euo pipefail

# Plugin data directory (organized under marketplace name)
PLUGIN_DATA_DIR="${HOME}/.claude/marcel-bich-claude-marketplace/limit"
STATE_FILE="${PLUGIN_DATA_DIR}/state.json"
CACHE_FILE="/tmp/claude-mb-limit-cache.json"
DEVICE_ID="${CLAUDE_MB_LIMIT_DEVICE_LABEL:-$(hostname)}"

# Colors
COLOR_RESET='\033[0m'
COLOR_GRAY='\033[90m'
COLOR_GREEN='\033[32m'
COLOR_YELLOW='\033[33m'
COLOR_CYAN='\033[36m'

echo -e "${COLOR_CYAN}=== Local Device Usage Debug ===${COLOR_RESET}"
echo ""

# 1. Check environment
echo -e "${COLOR_YELLOW}1. Environment:${COLOR_RESET}"
echo "   CLAUDE_MB_LIMIT_LOCAL: ${CLAUDE_MB_LIMIT_LOCAL:-not set (default: false)}"
echo "   CLAUDE_MB_LIMIT_DEVICE_LABEL: ${CLAUDE_MB_LIMIT_DEVICE_LABEL:-not set}"
echo "   Device ID: ${DEVICE_ID}"
echo ""

# 2. Check state file
echo -e "${COLOR_YELLOW}2. State File:${COLOR_RESET}"
if [[ -f "${STATE_FILE}" ]]; then
    echo "   Path: ${STATE_FILE}"
    echo ""
    echo "   Contents:"
    jq '.' "${STATE_FILE}" 2>/dev/null | sed 's/^/   /'
    echo ""

    # Extract values - new structure
    start_5h=$(jq -r '.start_5h_pct // -1' "${STATE_FILE}" 2>/dev/null)
    start_7d=$(jq -r '.start_7d_pct // -1' "${STATE_FILE}" 2>/dev/null)
    total_input=$(jq -r '.totals.input_tokens // 0' "${STATE_FILE}" 2>/dev/null)
    total_output=$(jq -r '.totals.output_tokens // 0' "${STATE_FILE}" 2>/dev/null)
    total_cost=$(jq -r '.totals.total_cost_usd // 0' "${STATE_FILE}" 2>/dev/null)
    session_count=$(jq -r '.sessions | length // 0' "${STATE_FILE}" 2>/dev/null)

    echo "   Parsed values:"
    echo "     start_5h_pct: ${start_5h}%"
    echo "     start_7d_pct: ${start_7d}%"
    echo ""
    echo "   Totals (accumulated across all sessions):"
    echo "     input_tokens: ${total_input}"
    echo "     output_tokens: ${total_output}"
    echo "     total_tokens: $((total_input + total_output))"
    echo "     total_cost_usd: \$${total_cost}"
    echo ""
    echo "   Sessions tracked: ${session_count}"
    if [[ "$session_count" -gt 0 ]]; then
        echo "   Session IDs:"
        jq -r '.sessions | keys[]' "${STATE_FILE}" 2>/dev/null | while read -r sid; do
            local_in=$(jq -r ".sessions[\"$sid\"].last_input // 0" "${STATE_FILE}" 2>/dev/null)
            local_out=$(jq -r ".sessions[\"$sid\"].last_output // 0" "${STATE_FILE}" 2>/dev/null)
            local_cost=$(jq -r ".sessions[\"$sid\"].last_cost // 0" "${STATE_FILE}" 2>/dev/null)
            echo "     - ${sid}: in=${local_in} out=${local_out} cost=\$${local_cost}"
        done
    fi
else
    echo "   File does not exist: ${STATE_FILE}"
    echo ""
    echo -e "${COLOR_GRAY}   State file will be created when CLAUDE_MB_LIMIT_LOCAL=true${COLOR_RESET}"
fi
echo ""

# 3. Check API cache
echo -e "${COLOR_YELLOW}3. API Cache (current global values):${COLOR_RESET}"
if [[ -f "${CACHE_FILE}" ]]; then
    global_5h=$(jq -r '.five_hour.utilization // 0' "${CACHE_FILE}" 2>/dev/null | cut -d. -f1)
    global_7d=$(jq -r '.seven_day.utilization // 0' "${CACHE_FILE}" 2>/dev/null | cut -d. -f1)
    reset_5h=$(jq -r '.five_hour.resets_at // ""' "${CACHE_FILE}" 2>/dev/null)
    reset_7d=$(jq -r '.seven_day.resets_at // ""' "${CACHE_FILE}" 2>/dev/null)

    echo "   Global 5h: ${global_5h}% (resets: ${reset_5h})"
    echo "   Global 7d: ${global_7d}% (resets: ${reset_7d})"
else
    echo "   No API cache found at ${CACHE_FILE}"
    echo -e "${COLOR_GRAY}   Run Claude Code to populate cache${COLOR_RESET}"
fi
echo ""

# 4. Delta calculation
echo -e "${COLOR_YELLOW}4. Delta Calculation (local device usage):${COLOR_RESET}"
if [[ -f "${STATE_FILE}" ]] && [[ -f "${CACHE_FILE}" ]]; then
    start_5h=$(jq -r '.start_5h_pct // -1' "${STATE_FILE}" 2>/dev/null)
    start_7d=$(jq -r '.start_7d_pct // -1' "${STATE_FILE}" 2>/dev/null)
    global_5h=$(jq -r '.five_hour.utilization // 0' "${CACHE_FILE}" 2>/dev/null | cut -d. -f1)
    global_7d=$(jq -r '.seven_day.utilization // 0' "${CACHE_FILE}" 2>/dev/null | cut -d. -f1)

    if [[ "${start_5h}" != "-1" ]]; then
        local_5h=$((global_5h - start_5h))
        [[ "$local_5h" -lt 0 ]] && local_5h=0
        echo "   5h: ${global_5h}% (global) - ${start_5h}% (start) = ${local_5h}% (local)"
    else
        echo "   5h: Not initialized (start_5h_pct = -1)"
    fi

    if [[ "${start_7d}" != "-1" ]]; then
        local_7d=$((global_7d - start_7d))
        [[ "$local_7d" -lt 0 ]] && local_7d=0
        echo "   7d: ${global_7d}% (global) - ${start_7d}% (start) = ${local_7d}% (local)"
    else
        echo "   7d: Not initialized (start_7d_pct = -1)"
    fi
else
    echo "   Cannot calculate - missing state or cache file"
fi
echo ""

# 5. Commands
echo -e "${COLOR_YELLOW}5. Useful Commands:${COLOR_RESET}"
echo ""
echo "   Reset local tracking (start fresh):"
echo -e "   ${COLOR_GRAY}rm ${STATE_FILE}${COLOR_RESET}"
echo ""
echo "   Enable local tracking:"
echo -e "   ${COLOR_GRAY}export CLAUDE_MB_LIMIT_LOCAL=true${COLOR_RESET}"
echo ""
echo "   View raw state file:"
echo -e "   ${COLOR_GRAY}cat ${STATE_FILE}${COLOR_RESET}"
echo ""
