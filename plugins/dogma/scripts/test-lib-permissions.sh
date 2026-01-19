#!/bin/bash
# Test script for lib-permissions.sh checkbox states
# Tests all 6 states: [ ], [x], [?], [1], [a], [0]
# Plus edge cases: pattern not found, empty section

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the library
source "$SCRIPT_DIR/lib-permissions.sh"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Temp directory for test files
TEST_TMP_DIR="/tmp/dogma-test-$$"
mkdir -p "$TEST_TMP_DIR"

# Cleanup on exit
cleanup() {
    rm -rf "$TEST_TMP_DIR"
}
trap cleanup EXIT

# Test helper function
run_test() {
    local description="$1"
    local expected="$2"
    local actual="$3"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "[FAIL] $description"
        echo "       Expected: '$expected'"
        echo "       Actual:   '$actual'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Test helper for exit codes
run_exit_test() {
    local description="$1"
    local expected_exit="$2"
    local perms_section="$3"
    local pattern="$4"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    # Use || true to prevent set -e from exiting on non-zero return
    check_permission "$perms_section" "$pattern" && actual_exit=0 || actual_exit=$?

    if [ "$expected_exit" = "$actual_exit" ]; then
        echo "[PASS] $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "[FAIL] $description"
        echo "       Expected exit: $expected_exit"
        echo "       Actual exit:   $actual_exit"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

echo "Testing lib-permissions.sh checkbox states..."
echo ""

# ============================================================================
# Test 1: Basic checkbox states with get_permission_mode()
# ============================================================================
echo "--- Basic Checkbox States ---"

# State [ ] -> deny
PERMS_DENY="- [ ] May run \`git push\` autonomously"
result=$(get_permission_mode "$PERMS_DENY" "git push")
run_test "State [ ] returns 'deny'" "deny" "$result"

# State [x] -> auto
PERMS_AUTO="- [x] May run \`git commit\` autonomously"
result=$(get_permission_mode "$PERMS_AUTO" "git commit")
run_test "State [x] returns 'auto'" "auto" "$result"

# State [?] -> ask
PERMS_ASK="- [?] May run \`git push\` autonomously"
result=$(get_permission_mode "$PERMS_ASK" "git push")
run_test "State [?] returns 'ask'" "ask" "$result"

# State [1] -> one
PERMS_ONE="- [1] May run \`npm install\` autonomously"
result=$(get_permission_mode "$PERMS_ONE" "npm install")
run_test "State [1] returns 'one'" "one" "$result"

# State [a] -> all
PERMS_ALL="- [a] May run \`git add\` autonomously"
result=$(get_permission_mode "$PERMS_ALL" "git add")
run_test "State [a] returns 'all'" "all" "$result"

# State [0] -> deny
PERMS_ZERO="- [0] May delete files autonomously"
result=$(get_permission_mode "$PERMS_ZERO" "delete files")
run_test "State [0] returns 'deny'" "deny" "$result"

echo ""

# ============================================================================
# Test 2: Edge cases
# ============================================================================
echo "--- Edge Cases ---"

# Pattern not found -> auto (default)
PERMS_MISSING="- [x] May run \`git commit\` autonomously"
result=$(get_permission_mode "$PERMS_MISSING" "npm publish")
run_test "Pattern not found returns 'auto' (default)" "auto" "$result"

# Empty section -> auto (default)
result=$(get_permission_mode "" "git push")
run_test "Empty section returns 'auto' (default)" "auto" "$result"

# Only whitespace section -> auto (default)
PERMS_WHITESPACE="   "
result=$(get_permission_mode "$PERMS_WHITESPACE" "git push")
run_test "Whitespace-only section returns 'auto' (default)" "auto" "$result"

echo ""

# ============================================================================
# Test 3: Realistic patterns (with backticks, indentation)
# ============================================================================
echo "--- Realistic Patterns ---"

# Indented checkbox
PERMS_INDENTED="    - [x] May run \`git add\` autonomously"
result=$(get_permission_mode "$PERMS_INDENTED" "git add")
run_test "Indented checkbox [x] returns 'auto'" "auto" "$result"

# Multi-line permissions
PERMS_MULTI="- [x] May run \`git add\` autonomously
- [ ] May run \`git push\` autonomously
- [?] May run \`npm publish\` autonomously"

result=$(get_permission_mode "$PERMS_MULTI" "git add")
run_test "Multi-line: git add [x] returns 'auto'" "auto" "$result"

result=$(get_permission_mode "$PERMS_MULTI" "git push")
run_test "Multi-line: git push [ ] returns 'deny'" "deny" "$result"

result=$(get_permission_mode "$PERMS_MULTI" "npm publish")
run_test "Multi-line: npm publish [?] returns 'ask'" "ask" "$result"

# Pattern with special characters (backticks in pattern)
PERMS_BACKTICKS="- [1] May run \`rm -rf\` autonomously"
result=$(get_permission_mode "$PERMS_BACKTICKS" "rm -rf")
run_test "Pattern with special chars returns 'one'" "one" "$result"

echo ""

# ============================================================================
# Test 4: Legacy check_permission() function (exit codes)
# ============================================================================
echo "--- Legacy check_permission() Exit Codes ---"

# [x] -> exit 0 (allowed)
run_exit_test "check_permission [x] exits 0 (allowed)" 0 "$PERMS_AUTO" "git commit"

# [ ] -> exit 1 (blocked)
run_exit_test "check_permission [ ] exits 1 (blocked)" 1 "$PERMS_DENY" "git push"

# [?] -> exit 0 (legacy: allowed)
run_exit_test "check_permission [?] exits 0 (legacy allowed)" 0 "$PERMS_ASK" "git push"

# Pattern not found -> exit 0 (allow by default)
run_exit_test "check_permission pattern not found exits 0 (allow)" 0 "$PERMS_AUTO" "npm publish"

# Empty section -> exit 0 (allow by default)
run_exit_test "check_permission empty section exits 0 (allow)" 0 "" "git push"

echo ""

# ============================================================================
# Results
# ============================================================================
echo "============================================"
echo "Results: $TESTS_PASSED/$TESTS_TOTAL tests passed"

if [ "$TESTS_FAILED" -gt 0 ]; then
    echo "FAILED: $TESTS_FAILED test(s) failed"
    exit 1
else
    echo "SUCCESS: All tests passed"
    exit 0
fi
