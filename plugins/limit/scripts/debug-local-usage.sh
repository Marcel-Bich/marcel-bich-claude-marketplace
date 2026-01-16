#!/bin/bash
# debug-local-usage.sh - Debug local device tracking
# Shows usage data, tests calculator, simulates output

set -euo pipefail

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
USAGE_FILE="${HOME}/.claude/limit-local-usage.json"
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
echo "   CLAUDE_MB_LIMIT_LOCAL: ${CLAUDE_MB_LIMIT_LOCAL:-not set (default: true)}"
echo "   CLAUDE_MB_LIMIT_DEVICE_LABEL: ${CLAUDE_MB_LIMIT_DEVICE_LABEL:-not set}"
echo "   Device ID: ${DEVICE_ID}"
echo ""

# 2. Check usage file
echo -e "${COLOR_YELLOW}2. Usage File:${COLOR_RESET}"
if [[ -f "${USAGE_FILE}" ]]; then
    local_entries=$(wc -l < "${USAGE_FILE}")
    file_size=$(du -h "${USAGE_FILE}" | cut -f1)
    echo "   Path: ${USAGE_FILE}"
    echo "   Size: ${file_size}"
    echo "   Entries: ${local_entries}"
    echo ""
    echo "   Last 5 entries:"
    tail -5 "${USAGE_FILE}" | while read -r line; do
        echo "     ${line}"
    done
else
    echo "   File does not exist: ${USAGE_FILE}"
    echo ""
    echo -e "${COLOR_GRAY}   To create test data, run:${COLOR_RESET}"
    echo "   echo '{\"context_window\":{\"total_input_tokens\":1000,\"total_output_tokens\":500}}' | bash ${SCRIPT_DIR}/local-usage-tracker.sh"
fi
echo ""

# 3. Test calculator
echo -e "${COLOR_YELLOW}3. Calculator Test:${COLOR_RESET}"
if [[ -f "${SCRIPT_DIR}/local-usage-calculator.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/local-usage-calculator.sh" 2>/dev/null || true

    if type get_local_5h_percent &>/dev/null; then
        # Simulate with 50% global usage
        test_5h=$(get_local_5h_percent 50 2>/dev/null) || test_5h="error"
        test_7d=$(get_local_7d_percent 50 2>/dev/null) || test_7d="error"

        echo "   With 50% global usage:"
        echo "     Local 5h percent: ${test_5h}%"
        echo "     Local 7d percent: ${test_7d}%"
    else
        echo "   Calculator functions not loaded"
    fi
else
    echo "   Calculator script not found"
fi
echo ""

# 4. Simulate output
echo -e "${COLOR_YELLOW}4. Simulated Output (how it would look):${COLOR_RESET}"
echo ""

# Get color based on percentage
get_color() {
    local pct="$1"
    if [[ "$pct" -lt 30 ]]; then echo "$COLOR_GRAY"
    elif [[ "$pct" -lt 50 ]]; then echo "$COLOR_GREEN"
    elif [[ "$pct" -lt 75 ]]; then echo "$COLOR_YELLOW"
    else echo '\033[38;5;208m'; fi
}

# Progress bar
progress_bar() {
    local pct="$1"
    [[ "$pct" -lt 0 ]] && pct=0
    [[ "$pct" -gt 100 ]] && pct=100
    local filled=$((pct * 10 / 100))
    local empty=$((10 - filled))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="="; done
    for ((i=0; i<empty; i++)); do bar+="-"; done
    echo "[$bar]"
}

# Simulate global 42% and local 15%
global_pct=42
local_pct=15

global_color=$(get_color "$global_pct")
local_color=$(get_color "$local_pct")
global_bar=$(progress_bar "$global_pct")
local_bar=$(progress_bar "$local_pct")

echo -e "   ${global_color}5h all ${global_bar} ${global_pct}%  reset: 2026-01-16 05:00${COLOR_RESET}"
echo -e "   ${local_color}5h all ${local_bar} ${local_pct}%  reset: 2026-01-16 05:00 (${DEVICE_ID})${COLOR_RESET}"
echo ""

# 5. Manual test command
echo -e "${COLOR_YELLOW}5. Manual Test Commands:${COLOR_RESET}"
echo ""
echo "   Add test usage entry:"
echo -e "   ${COLOR_GRAY}echo '{\"context_window\":{\"total_input_tokens\":5000,\"total_output_tokens\":2000}}' | bash ${SCRIPT_DIR}/local-usage-tracker.sh${COLOR_RESET}"
echo ""
echo "   View all entries:"
echo -e "   ${COLOR_GRAY}cat ${USAGE_FILE}${COLOR_RESET}"
echo ""
echo "   Clear usage data:"
echo -e "   ${COLOR_GRAY}rm ${USAGE_FILE}${COLOR_RESET}"
echo ""
