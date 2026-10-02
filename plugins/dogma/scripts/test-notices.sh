#!/bin/bash
# Test script for notices-pending.sh, notice-applies-test-commands.sh and the
# SessionStart hook hooks/notices-inject.sh.
# Covers: applies / not applies, mark, seen not listed again, two repos independent,
# JSON validity, not a git repo -> 4, hook silent / valid JSON.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NP="$SCRIPT_DIR/notices-pending.sh"
HOOK="$SCRIPT_DIR/../hooks/notices-inject.sh"
ID="dogma-test-commands"

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dogma-test-notices-XXXXXX")"
cleanup() {
    rm -rf "$TEST_TMP_DIR"
}
trap cleanup EXIT

# Isolated profile: seen state never touches the real config dir.
export CLAUDE_CONFIG_DIR="$TEST_TMP_DIR/config"
unset CLAUDE_PLUGIN_ROOT CLAUDE_MB_DOGMA_ENABLED CLAUDE_MB_DOGMA_NOTICES

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

# Runs a command, captures stdout, stderr and exit code into OUT, ERR, RC.
capture() {
    local errfile="$TEST_TMP_DIR/stderr"
    OUT="$("$@" 2>"$errfile")" && RC=0 || RC=$?
    ERR="$(cat "$errfile")"
}

make_repo() {
    mkdir -p "$1"
    git -C "$1" init -q
}

PERMS_NO_SECTION='# Dogma Permissions

<permissions>
## Workflow Permissions

### Testing
- [x] before commit
</permissions>
'

PERMS_WITH_SECTION='# Dogma Permissions

<permissions>
## Workflow Permissions

### Test Commands
- commit: `npm run lint`
</permissions>
'

echo "Testing notices-pending.sh..."
echo ""

# Guard: the upward search must not find a real file above the temp dir.
if [ -f "$(dirname "$TEST_TMP_DIR")/DOGMA-PERMISSIONS.md" ]; then
    echo "[SKIP] a DOGMA-PERMISSIONS.md exists above the temp dir"
    exit 0
fi

# ============================================================================
echo "--- Applies / not applies ---"

REPO_A="$TEST_TMP_DIR/repo-a"
make_repo "$REPO_A"
printf '%s' "$PERMS_NO_SECTION" > "$REPO_A/DOGMA-PERMISSIONS.md"
mkdir -p "$REPO_A/sub/deeper"

capture "$NP" "$REPO_A"
run_test "no Test Commands section: exit 0" "0" "$RC"
run_test "kv: id line" "id=$ID" "$(printf '%s\n' "$OUT" | grep '^id=')"
run_test "kv: action line" "action=/dogma:permissions" "$(printf '%s\n' "$OUT" | grep '^action=')"
capture "$NP" "$REPO_A/sub/deeper"
run_test "subdir of repo: exit 0" "0" "$RC"

REPO_SEC="$TEST_TMP_DIR/repo-section"
make_repo "$REPO_SEC"
printf '%s' "$PERMS_WITH_SECTION" > "$REPO_SEC/DOGMA-PERMISSIONS.md"
capture "$NP" "$REPO_SEC"
run_test "with Test Commands section: exit 4" "4" "$RC"
run_test "with Test Commands section: no output" "" "$OUT"

REPO_NOFILE="$TEST_TMP_DIR/repo-nofile"
make_repo "$REPO_NOFILE"
capture "$NP" "$REPO_NOFILE"
run_test "no DOGMA-PERMISSIONS.md: exit 4" "4" "$RC"

NOGIT="$TEST_TMP_DIR/nogit"
mkdir -p "$NOGIT"
printf '%s' "$PERMS_NO_SECTION" > "$NOGIT/DOGMA-PERMISSIONS.md"
capture "$NP" "$NOGIT"
run_test "not a git repo: exit 4" "4" "$RC"
run_test "not a git repo: no output" "" "$OUT"
capture "$NP" mark "$ID" "$NOGIT"
run_test "mark in not a git repo: exit 4" "4" "$RC"

capture "$NP" "$TEST_TMP_DIR/does-not-exist"
run_test "missing dir: exit 4" "4" "$RC"

echo ""

# ============================================================================
echo "--- JSON ---"

capture "$NP" --json "$REPO_A"
run_test "json: exit 0" "0" "$RC"
JSON_CHECK="$(printf '%s' "$OUT" | REPO="$REPO_A" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
n = d["notices"]
ok = (os.path.realpath(d["repo"]) == os.path.realpath(os.environ["REPO"])
      and len(n) == 1 and n[0]["id"] == "dogma-test-commands"
      and n[0]["action"] == "/dogma:permissions" and n[0]["text"]
      and sorted(n[0]) == ["action", "id", "text"])
print("valid" if ok else "mismatch")
' 2>&1)"
run_test "json: structure" "valid" "$JSON_CHECK"

echo ""

# ============================================================================
echo "--- Mark ---"

capture "$NP" mark
run_test "mark without id: exit 1" "1" "$RC"
capture "$NP" mark "../evil" "$REPO_A"
run_test "mark with invalid id: exit 1" "1" "$RC"
capture "$NP" mark "no-such-notice" "$REPO_A"
run_test "mark unknown id: exit 1" "1" "$RC"

capture "$NP" mark "$ID" "$REPO_A/sub"
run_test "mark from a subdir: exit 0" "0" "$RC"
SEEN_FILES="$(find "$CLAUDE_CONFIG_DIR/dogma/notices-seen" -type f | wc -l | tr -d ' ')"
run_test "mark: one seen file" "1" "$SEEN_FILES"
KEY_DIR="$(basename "$(dirname "$(find "$CLAUDE_CONFIG_DIR/dogma/notices-seen" -type f)")")"
run_test "mark: key is 16 hex chars" "yes" "$(printf '%s' "$KEY_DIR" | grep -qE '^[0-9a-f]{16}$' && echo yes)"

capture "$NP" "$REPO_A"
run_test "seen: not listed again" "4" "$RC"
capture "$NP" --json "$REPO_A"
run_test "seen: json not listed again" "4" "$RC"

echo ""

# ============================================================================
echo "--- Two repos independent ---"

REPO_B="$TEST_TMP_DIR/repo-b"
make_repo "$REPO_B"
printf '%s' "$PERMS_NO_SECTION" > "$REPO_B/DOGMA-PERMISSIONS.md"
capture "$NP" "$REPO_B"
run_test "repo B still pending after marking repo A" "0" "$RC"
capture "$NP" mark "$ID" "$REPO_B"
run_test "mark repo B: exit 0" "0" "$RC"
capture "$NP" "$REPO_B"
run_test "repo B seen afterwards" "4" "$RC"
SEEN_DIRS="$(find "$CLAUDE_CONFIG_DIR/dogma/notices-seen" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
run_test "two repos: two key dirs" "2" "$SEEN_DIRS"

# A different profile has its own seen state.
CLAUDE_CONFIG_DIR="$TEST_TMP_DIR/other-profile" capture "$NP" "$REPO_A"
run_test "other profile: repo A pending again" "0" "$RC"

echo ""

# ============================================================================
echo "--- SessionStart hook ---"

# runs the hook with a SessionStart payload whose cwd is $1
run_hook() {
    printf '{"hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$1" | "$HOOK"
}

capture run_hook "$REPO_A"
run_test "hook: nothing pending -> exit 0" "0" "$RC"
run_test "hook: nothing pending -> no output" "" "$OUT"

REPO_C="$TEST_TMP_DIR/repo-c"
make_repo "$REPO_C"
printf '%s' "$PERMS_NO_SECTION" > "$REPO_C/DOGMA-PERMISSIONS.md"
capture run_hook "$REPO_C"
run_test "hook: pending -> exit 0" "0" "$RC"
HOOK_CHECK="$(printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)["hookSpecificOutput"]
c = d["additionalContext"]
ok = (d["hookEventName"] == "SessionStart" and "dogma-test-commands" in c
      and "AskUserQuestion" in c and "notices-pending.sh" in c and " mark " in c
      and "autonomous" in c)
print("valid" if ok else "mismatch")
' 2>&1)"
run_test "hook: pending -> valid JSON with the notice" "valid" "$HOOK_CHECK"

CLAUDE_MB_DOGMA_NOTICES=false capture run_hook "$REPO_C"
run_test "hook: CLAUDE_MB_DOGMA_NOTICES=false -> no output" "" "$OUT"
CLAUDE_MB_DOGMA_ENABLED=false capture run_hook "$REPO_C"
run_test "hook: CLAUDE_MB_DOGMA_ENABLED=false -> no output" "" "$OUT"

capture run_hook "$NOGIT"
run_test "hook: not a git repo -> exit 0" "0" "$RC"
run_test "hook: not a git repo -> no output" "" "$OUT"

echo ""

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
