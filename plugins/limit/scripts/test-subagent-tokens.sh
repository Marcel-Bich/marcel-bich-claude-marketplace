#!/usr/bin/env bash
# test-subagent-tokens.sh - Tests for subagent token tracking system
# Tests schema version reset, file offset tracking, per-model accumulation, and backup creation
# shellcheck disable=SC2250

set -euo pipefail

# =============================================================================
# Test Setup
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
TEST_PROJECTS_DIR="${TEST_DIR}/projects"
TEST_DATA_DIR="${TEST_DIR}/data"

# Override environment for testing
export PLUGIN_DATA_DIR="${TEST_DATA_DIR}"
export HOME="${TEST_DIR}"

# Create test directories
mkdir -p "${TEST_PROJECTS_DIR}"
mkdir -p "${TEST_DATA_DIR}"

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=""

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# =============================================================================
# Test Utilities
# =============================================================================

cleanup() {
    rm -rf "${TEST_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

log_test() {
    CURRENT_TEST="$1"
    echo -e "${YELLOW}>>> Testing: ${CURRENT_TEST}${NC}"
}

pass() {
    echo -e "${GREEN}  PASS: ${CURRENT_TEST}${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    local msg="${1:-}"
    echo -e "${RED}  FAIL: ${CURRENT_TEST}${NC}"
    [[ -n "$msg" ]] && echo -e "${RED}        ${msg}${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        fail "Expected '$expected', got '$actual'. ${msg}"
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    if [[ -f "$file" ]]; then
        return 0
    else
        fail "File '$file' does not exist"
        return 1
    fi
}

assert_file_not_exists() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        return 0
    else
        fail "File '$file' should not exist"
        return 1
    fi
}

# =============================================================================
# Source the script under test
# =============================================================================

# Override CLAUDE_PROJECTS_DIR before sourcing
CLAUDE_PROJECTS_DIR="${TEST_PROJECTS_DIR}"

# Source the script (this will set up functions)
source "${SCRIPT_DIR}/subagent-tokens.sh"

# Re-set paths after sourcing
SUBAGENT_STATE_FILE="${TEST_DATA_DIR}/limit-subagent-state.json"
CLAUDE_PROJECTS_DIR="${TEST_PROJECTS_DIR}"

# =============================================================================
# Test: Schema Version Reset Mechanism
# =============================================================================

test_schema_version_reset() {
    log_test "Schema version reset creates backup and resets state"

    # Reset state
    rm -f "${SUBAGENT_STATE_FILE}" "${SUBAGENT_STATE_FILE}.bak" 2>/dev/null || true

    # Create a v1 state file (old schema)
    cat > "${SUBAGENT_STATE_FILE}" << 'EOF'
{
  "schema_version": 1,
  "total_tokens": 12345,
  "total_price": 0.123456,
  "some_old_field": "test"
}
EOF

    # Call reset_state_if_incompatible
    reset_state_if_incompatible

    # Check that backup was created
    if ! assert_file_exists "${SUBAGENT_STATE_FILE}.bak"; then return 1; fi

    # Check that old state was backed up correctly
    local backup_version
    backup_version=$(jq -r '.schema_version' "${SUBAGENT_STATE_FILE}.bak" 2>/dev/null)
    if ! assert_equals "1" "$backup_version" "Backup should contain old schema version"; then return 1; fi

    # Check that state file was deleted (will be recreated by init)
    if ! assert_file_not_exists "${SUBAGENT_STATE_FILE}"; then return 1; fi

    pass
}

test_schema_version_no_reset_when_matching() {
    log_test "Schema version matching does not reset state"

    # Reset state
    rm -f "${SUBAGENT_STATE_FILE}" "${SUBAGENT_STATE_FILE}.bak" 2>/dev/null || true

    # Create a v2 state file (current schema)
    cat > "${SUBAGENT_STATE_FILE}" << 'EOF'
{
  "schema_version": 2,
  "total_tokens": 99999,
  "haiku": {"input_tokens": 1000}
}
EOF

    # Call reset_state_if_incompatible
    reset_state_if_incompatible

    # Check that backup was NOT created
    if ! assert_file_not_exists "${SUBAGENT_STATE_FILE}.bak"; then return 1; fi

    # Check that state file still exists with original data
    local tokens
    tokens=$(jq -r '.total_tokens' "${SUBAGENT_STATE_FILE}" 2>/dev/null)
    if ! assert_equals "99999" "$tokens" "State should not be modified"; then return 1; fi

    pass
}

test_schema_version_backup_overwrites() {
    log_test "Schema version reset overwrites previous backup"

    # Reset state
    rm -f "${SUBAGENT_STATE_FILE}" "${SUBAGENT_STATE_FILE}.bak" 2>/dev/null || true

    # Create an existing backup
    echo '{"old_backup": true}' > "${SUBAGENT_STATE_FILE}.bak"

    # Create a v0 state file (very old)
    cat > "${SUBAGENT_STATE_FILE}" << 'EOF'
{
  "schema_version": 0,
  "new_data": "should be in backup"
}
EOF

    # Call reset_state_if_incompatible
    reset_state_if_incompatible

    # Check that backup was overwritten
    local new_data
    new_data=$(jq -r '.new_data' "${SUBAGENT_STATE_FILE}.bak" 2>/dev/null)
    if ! assert_equals "should be in backup" "$new_data" "Backup should be overwritten with new data"; then return 1; fi

    pass
}

# =============================================================================
# Test: File Offset Tracking
# =============================================================================

test_file_offset_tracking() {
    log_test "File offset tracking reads from correct position"

    # Reset state
    rm -f "${SUBAGENT_STATE_FILE}" 2>/dev/null || true
    init_subagent_state

    # Create a test JSONL file
    local test_file="${TEST_DIR}/test-agent.jsonl"
    echo '{"message":{"model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50}}}' > "${test_file}"

    # Get initial file size
    local initial_size
    initial_size=$(get_file_size "${test_file}")

    # Extract tokens (should get all)
    local result
    result=$(extract_tokens_from_file_offset "${test_file}" 0)
    local sonnet_inp
    sonnet_inp=$(echo "$result" | jq -r '.sonnet.input')
    if ! assert_equals "100" "$sonnet_inp" "Should read 100 input tokens from file"; then return 1; fi

    # Extract tokens from end offset (should get nothing new)
    result=$(extract_tokens_from_file_offset "${test_file}" "$initial_size")
    sonnet_inp=$(echo "$result" | jq -r '.sonnet.input')
    if ! assert_equals "0" "$sonnet_inp" "Should read 0 tokens when starting from end"; then return 1; fi

    # Append more data
    echo '{"message":{"model":"claude-sonnet-4","usage":{"input_tokens":200,"output_tokens":100}}}' >> "${test_file}"

    # Extract from old offset (should get new data only)
    result=$(extract_tokens_from_file_offset "${test_file}" "$initial_size")
    sonnet_inp=$(echo "$result" | jq -r '.sonnet.input')
    if ! assert_equals "200" "$sonnet_inp" "Should read 200 input tokens from appended data"; then return 1; fi

    pass
}

test_file_offset_new_offset_returned() {
    log_test "File offset extraction returns correct new offset"

    # Create a test JSONL file
    local test_file="${TEST_DIR}/test-offset.jsonl"
    echo '{"message":{"model":"claude-haiku-4","usage":{"input_tokens":50}}}' > "${test_file}"

    local file_size
    file_size=$(get_file_size "${test_file}")

    # Extract tokens
    local result
    result=$(extract_tokens_from_file_offset "${test_file}" 0)
    local new_offset
    new_offset=$(echo "$result" | jq -r '.new_offset')

    if ! assert_equals "$file_size" "$new_offset" "New offset should match file size"; then return 1; fi

    pass
}

# =============================================================================
# Test: Per-Model Token Accumulation
# =============================================================================

test_per_model_accumulation() {
    log_test "Per-model token accumulation categorizes correctly"

    # Reset state
    rm -f "${SUBAGENT_STATE_FILE}" 2>/dev/null || true

    # Create content with multiple models
    local content
    content=$(cat << 'EOF'
{"message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":100,"output_tokens":50}}}
{"message":{"model":"claude-sonnet-4-5-20251001","usage":{"input_tokens":200,"output_tokens":100}}}
{"message":{"model":"claude-opus-4-5-20251101","usage":{"input_tokens":300,"output_tokens":150}}}
{"message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":400,"output_tokens":200}}}
EOF
)

    # Extract per-model tokens
    local result
    result=$(extract_tokens_per_model "$content")

    # Check haiku (should be 100+400=500 input, 50+200=250 output)
    local haiku_inp haiku_out
    haiku_inp=$(echo "$result" | jq -r '.haiku.input')
    haiku_out=$(echo "$result" | jq -r '.haiku.output')
    if ! assert_equals "500" "$haiku_inp" "Haiku input should be 500"; then return 1; fi
    if ! assert_equals "250" "$haiku_out" "Haiku output should be 250"; then return 1; fi

    # Check sonnet
    local sonnet_inp
    sonnet_inp=$(echo "$result" | jq -r '.sonnet.input')
    if ! assert_equals "200" "$sonnet_inp" "Sonnet input should be 200"; then return 1; fi

    # Check opus
    local opus_inp
    opus_inp=$(echo "$result" | jq -r '.opus.input')
    if ! assert_equals "300" "$opus_inp" "Opus input should be 300"; then return 1; fi

    pass
}

test_model_category_classification() {
    log_test "Model category classification works correctly"

    local category

    category=$(get_model_category "claude-haiku-4-5-20251001")
    if ! assert_equals "haiku" "$category" "Should classify haiku model"; then return 1; fi

    category=$(get_model_category "claude-sonnet-4-5-20251001")
    if ! assert_equals "sonnet" "$category" "Should classify sonnet model"; then return 1; fi

    category=$(get_model_category "claude-opus-4-5-20251101")
    if ! assert_equals "opus" "$category" "Should classify opus model"; then return 1; fi

    category=$(get_model_category "unknown-model-xyz")
    if ! assert_equals "opus" "$category" "Should default to opus for unknown models"; then return 1; fi

    pass
}

# =============================================================================
# Test: Cost Calculation
# =============================================================================

test_cost_calculation() {
    log_test "Cost calculation uses correct per-model pricing"

    # Test haiku pricing (1.00 input, 5.00 output per MTok)
    local haiku_cost
    haiku_cost=$(calculate_model_cost "haiku" 1000000 1000000 0 0)
    # Expected: (1M / 1M) * 1.00 + (1M / 1M) * 5.00 = 1 + 5 = 6.00
    if ! assert_equals "6.000000" "$haiku_cost" "Haiku cost should be 6.00 for 1M in + 1M out"; then return 1; fi

    # Test sonnet pricing (3.00 input, 15.00 output per MTok)
    local sonnet_cost
    sonnet_cost=$(calculate_model_cost "sonnet" 1000000 1000000 0 0)
    # Expected: 3 + 15 = 18.00
    if ! assert_equals "18.000000" "$sonnet_cost" "Sonnet cost should be 18.00 for 1M in + 1M out"; then return 1; fi

    # Test opus pricing (5.00 input, 25.00 output per MTok)
    local opus_cost
    opus_cost=$(calculate_model_cost "opus" 1000000 1000000 0 0)
    # Expected: 5 + 25 = 30.00
    if ! assert_equals "30.000000" "$opus_cost" "Opus cost should be 30.00 for 1M in + 1M out"; then return 1; fi

    pass
}

# =============================================================================
# Test: State File Initialization
# =============================================================================

test_init_creates_valid_state() {
    log_test "init_subagent_state creates valid v2 schema"

    # Reset state
    rm -f "${SUBAGENT_STATE_FILE}" 2>/dev/null || true

    # Initialize
    init_subagent_state

    # Check file exists
    if ! assert_file_exists "${SUBAGENT_STATE_FILE}"; then return 1; fi

    # Check schema version
    local version
    version=$(jq -r '.schema_version' "${SUBAGENT_STATE_FILE}" 2>/dev/null)
    if ! assert_equals "2" "$version" "Schema version should be 2"; then return 1; fi

    # Check all models exist
    local haiku_exists sonnet_exists opus_exists
    haiku_exists=$(jq -r '.haiku | type' "${SUBAGENT_STATE_FILE}" 2>/dev/null)
    sonnet_exists=$(jq -r '.sonnet | type' "${SUBAGENT_STATE_FILE}" 2>/dev/null)
    opus_exists=$(jq -r '.opus | type' "${SUBAGENT_STATE_FILE}" 2>/dev/null)

    if ! assert_equals "object" "$haiku_exists" "Haiku object should exist"; then return 1; fi
    if ! assert_equals "object" "$sonnet_exists" "Sonnet object should exist"; then return 1; fi
    if ! assert_equals "object" "$opus_exists" "Opus object should exist"; then return 1; fi

    pass
}

test_reset_subagent_state() {
    log_test "reset_subagent_state clears and reinitializes"

    # Initialize with some data
    init_subagent_state

    # Modify state
    local tmp_file
    tmp_file=$(mktemp)
    jq '.total_tokens = 99999' "${SUBAGENT_STATE_FILE}" > "${tmp_file}" && mv "${tmp_file}" "${SUBAGENT_STATE_FILE}"

    # Reset
    reset_subagent_state

    # Check total_tokens is 0
    local tokens
    tokens=$(jq -r '.total_tokens' "${SUBAGENT_STATE_FILE}" 2>/dev/null)
    if ! assert_equals "0" "$tokens" "Total tokens should be 0 after reset"; then return 1; fi

    pass
}

# =============================================================================
# Test: Empty Content Handling
# =============================================================================

test_empty_content_handling() {
    log_test "Empty content returns zero tokens"

    local result
    result=$(extract_tokens_per_model "")

    local haiku_inp
    haiku_inp=$(echo "$result" | jq -r '.haiku.input')
    if ! assert_equals "0" "$haiku_inp" "Empty content should return 0 tokens"; then return 1; fi

    pass
}

test_missing_file_handling() {
    log_test "Missing file returns zero tokens"

    local result
    result=$(extract_tokens_from_file_offset "/nonexistent/file.jsonl" 0)

    local total
    total=$(echo "$result" | jq -r '.haiku.input + .sonnet.input + .opus.input')
    if ! assert_equals "0" "$total" "Missing file should return 0 tokens"; then return 1; fi

    pass
}

# =============================================================================
# Run All Tests
# =============================================================================

echo "========================================"
echo "Subagent Token Tracking Test Suite"
echo "========================================"
echo ""

# Schema version tests
test_schema_version_reset
test_schema_version_no_reset_when_matching
test_schema_version_backup_overwrites

# File offset tests
test_file_offset_tracking
test_file_offset_new_offset_returned

# Per-model tests
test_per_model_accumulation
test_model_category_classification

# Cost calculation tests
test_cost_calculation

# State file tests
test_init_creates_valid_state
test_reset_subagent_state

# Edge case tests
test_empty_content_handling
test_missing_file_handling

echo ""
echo "========================================"
echo "Test Results"
echo "========================================"
echo -e "${GREEN}Passed: ${TESTS_PASSED}${NC}"
echo -e "${RED}Failed: ${TESTS_FAILED}${NC}"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
