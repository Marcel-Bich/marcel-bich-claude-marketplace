#!/bin/bash
# test-local-tracking.sh - Test local tracking logic in isolation
# Tests get_total_tokens_ever function directly without API calls

set -euo pipefail

# Plugin data directory (organized under marketplace name)
PLUGIN_DATA_DIR="${HOME}/.claude/marcel-bich-claude-marketplace/limit"
STATE_FILE="${PLUGIN_DATA_DIR}/limit-usage-state.json"

# Ensure directory exists
mkdir -p "$PLUGIN_DATA_DIR" 2>/dev/null || true

# Colors
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
RESET='\033[0m'

echo -e "${CYAN}=== Local Tracking Unit Test ===${RESET}"
echo ""

# Clean start
echo -e "${YELLOW}1. Cleaning up old state file...${RESET}"
rm -f "$STATE_FILE"
echo "   Removed $STATE_FILE"
echo ""

# Source the functions we need (extract just the function)
# We'll inline test the logic directly

# Debug function
debug_log() {
    echo "[DEBUG] $*" >> /tmp/test-local-debug.log
}

# The actual function we're testing (copied from usage-statusline.sh for isolation)
test_get_total_tokens_ever() {
    local STDIN_DATA="$1"
    local state_file="${HOME}/.claude/marcel-bich-claude-marketplace/limit/limit-usage-state.json"

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

    # If no session_id, fall back to simple mode
    if [[ -z "$session_id" ]]; then
        debug_log "No session_id available, skipping total tracking"
        echo "0"
        return
    fi

    # Read current state file
    local state="{}"
    if [[ -f "$state_file" ]]; then
        state=$(cat "$state_file" 2>/dev/null) || state="{}"
    fi

    # Get previous values for this session
    local last_input=0 last_output=0 last_cost="0"
    last_input=$(echo "$state" | jq -r ".sessions[\"$session_id\"].last_input // 0" 2>/dev/null) || last_input=0
    last_output=$(echo "$state" | jq -r ".sessions[\"$session_id\"].last_output // 0" 2>/dev/null) || last_output=0
    last_cost=$(echo "$state" | jq -r ".sessions[\"$session_id\"].last_cost // 0" 2>/dev/null) || last_cost="0"
    [[ "$last_input" == "null" ]] && last_input=0
    [[ "$last_output" == "null" ]] && last_output=0
    [[ "$last_cost" == "null" ]] && last_cost="0"

    # Calculate deltas for this session
    local delta_input=0 delta_output=0 delta_cost="0"
    if [[ "$current_input" -lt "$last_input" ]] || [[ "$current_output" -lt "$last_output" ]]; then
        # Session reset detected - use current values as delta
        delta_input="$current_input"
        delta_output="$current_output"
        delta_cost="$current_cost"
    else
        delta_input=$((current_input - last_input))
        delta_output=$((current_output - last_output))
        delta_cost=$(awk "BEGIN {printf \"%.4f\", $current_cost - $last_cost}")
    fi

    # Get current totals
    local total_input=0 total_output=0 total_cost="0"
    total_input=$(echo "$state" | jq -r '.totals.input_tokens // 0' 2>/dev/null) || total_input=0
    total_output=$(echo "$state" | jq -r '.totals.output_tokens // 0' 2>/dev/null) || total_output=0
    total_cost=$(echo "$state" | jq -r '.totals.total_cost_usd // 0' 2>/dev/null) || total_cost="0"
    [[ "$total_input" == "null" ]] && total_input=0
    [[ "$total_output" == "null" ]] && total_output=0
    [[ "$total_cost" == "null" ]] && total_cost="0"

    # Update totals with deltas
    local new_total_input=$((total_input + delta_input))
    local new_total_output=$((total_output + delta_output))
    local new_total_cost
    new_total_cost=$(awk "BEGIN {printf \"%.4f\", $total_cost + $delta_cost}")

    # Always update on first run or when there's a change
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
        debug_log "Updated state: session=$session_id delta_in=$delta_input delta_out=$delta_output delta_cost=$delta_cost"
    fi

    # Return total tokens (input + output)
    echo "$((new_total_input + new_total_output))"
}

# Test 1: Session A first update
echo -e "${YELLOW}2. Test: Session A first update...${RESET}"
MOCK_A1='{"session_id":"session-aaa-111","context_window":{"total_input_tokens":5000,"total_output_tokens":1000},"cost":{"total_cost_usd":0.05}}'
result=$(test_get_total_tokens_ever "$MOCK_A1")
echo "   Result: $result tokens"
echo "   State:"
jq '.' "$STATE_FILE" 2>/dev/null | sed 's/^/   /'
echo ""

# Test 2: Session B (parallel)
echo -e "${YELLOW}3. Test: Session B (parallel session)...${RESET}"
MOCK_B1='{"session_id":"session-bbb-222","context_window":{"total_input_tokens":3000,"total_output_tokens":500},"cost":{"total_cost_usd":0.03}}'
result=$(test_get_total_tokens_ever "$MOCK_B1")
echo "   Result: $result tokens"
echo "   State:"
jq '.' "$STATE_FILE" 2>/dev/null | sed 's/^/   /'
echo ""

# Test 3: Session A second update
echo -e "${YELLOW}4. Test: Session A second update (more tokens)...${RESET}"
MOCK_A2='{"session_id":"session-aaa-111","context_window":{"total_input_tokens":10000,"total_output_tokens":2500},"cost":{"total_cost_usd":0.12}}'
result=$(test_get_total_tokens_ever "$MOCK_A2")
echo "   Result: $result tokens"
echo "   State:"
jq '.' "$STATE_FILE" 2>/dev/null | sed 's/^/   /'
echo ""

# Verify
echo -e "${YELLOW}5. Verification...${RESET}"
total_input=$(jq -r '.totals.input_tokens' "$STATE_FILE")
total_output=$(jq -r '.totals.output_tokens' "$STATE_FILE")
total_cost=$(jq -r '.totals.total_cost_usd' "$STATE_FILE")
session_count=$(jq -r '.sessions | length' "$STATE_FILE")

# Expected:
# A1: +5000 in, +1000 out, +0.05 cost
# B1: +3000 in, +500 out, +0.03 cost
# A2: +5000 in (10000-5000), +1500 out (2500-1000), +0.07 cost (0.12-0.05)
# Total: 13000 in, 3000 out, 0.15 cost

expected_input=13000
expected_output=3000
expected_cost="0.15"

echo "   Sessions tracked: $session_count (expected: 2)"
echo "   Total input:  $total_input (expected: $expected_input)"
echo "   Total output: $total_output (expected: $expected_output)"
echo "   Total cost:   \$$total_cost (expected: \$$expected_cost)"
echo ""

# Validate
errors=0
if [[ "$total_input" != "$expected_input" ]]; then
    echo -e "   ${RED}FAIL: Input mismatch${RESET}"
    errors=$((errors + 1))
else
    echo -e "   ${GREEN}PASS: Input correct${RESET}"
fi

if [[ "$total_output" != "$expected_output" ]]; then
    echo -e "   ${RED}FAIL: Output mismatch${RESET}"
    errors=$((errors + 1))
else
    echo -e "   ${GREEN}PASS: Output correct${RESET}"
fi

# Cost comparison with tolerance
cost_check=$(awk "BEGIN {diff = $total_cost - $expected_cost; print (diff < 0.01 && diff > -0.01) ? 1 : 0}")
if [[ "$cost_check" != "1" ]]; then
    echo -e "   ${RED}FAIL: Cost mismatch${RESET}"
    errors=$((errors + 1))
else
    echo -e "   ${GREEN}PASS: Cost correct${RESET}"
fi

if [[ "$session_count" != "2" ]]; then
    echo -e "   ${RED}FAIL: Session count mismatch${RESET}"
    errors=$((errors + 1))
else
    echo -e "   ${GREEN}PASS: Session count correct${RESET}"
fi

echo ""
if [[ "$errors" -eq 0 ]]; then
    echo -e "${GREEN}=== ALL TESTS PASSED ===${RESET}"
    exit 0
else
    echo -e "${RED}=== $errors TEST(S) FAILED ===${RESET}"
    exit 1
fi
