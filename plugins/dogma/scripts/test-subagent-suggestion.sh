#!/bin/bash
# Test script for subagent-suggestion.sh (the per-prompt dogma-orchestration inject)
# Covers: the inject is printed, the hydra worktree rule is present exactly once, and it
# names the hydra flow, the single-track case and the two forbidden worktree paths.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUGGESTION="$SCRIPT_DIR/subagent-suggestion.sh"

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dogma-subagent-suggestion-XXXXXX")"
cleanup() {
    rm -rf "$TEST_TMP_DIR"
}
trap cleanup EXIT

# hermetic: no session-folder file to inherit from, no credo pinned project
mkdir -p "$TEST_TMP_DIR/session" "$TEST_TMP_DIR/project/CLAUDE"
export DOGMA_SESSION_DIR="$TEST_TMP_DIR/session" DOGMA_CREDO_CONFIG=none
echo "# Subagents" > "$TEST_TMP_DIR/project/CLAUDE/CLAUDE.subagents.md"

run_test() {
    local description="$1"
    local passed="$2"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ "$passed" = "true" ]; then
        echo "[PASS] $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "[FAIL] $description"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

OUTPUT="$(cd "$TEST_TMP_DIR/project" && bash "$SUGGESTION" </dev/null)"

has() {
    case "$OUTPUT" in
        *"$1"*) echo "true" ;;
        *) echo "false" ;;
    esac
}

run_test "inject is printed inside dogma-orchestration" \
    "$(has '<dogma-orchestration>')"

run_test "hydra worktree rule is conditional on hydra being installed" \
    "$(has 'while hydra is installed, EVERY worktree')"

run_test "rule covers a single isolated track, not only 2+ parallel tasks" \
    "$(has 'also for a single isolated track')"

run_test "rule forbids Agent isolation worktree" \
    "$(has 'Agent isolation:"worktree"')"

run_test "rule forbids a bare git worktree add outside the hydra folder" \
    "$(has 'bare git worktree add outside')"

COUNT="$(printf '%s\n' "$OUTPUT" | grep -c 'single isolated track' || true)"
run_test "hydra worktree rule is printed exactly once" \
    "$([ "$COUNT" = "1" ] && echo true || echo false)"

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_TOTAL total"

[ "$TESTS_FAILED" -eq 0 ]
