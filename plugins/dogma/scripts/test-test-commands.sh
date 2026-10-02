#!/bin/bash
# Test script for test-commands.sh (per-stage test commands in DOGMA-PERMISSIONS.md)
# Covers: no file, no section, all five stages, branch filter match/miss,
# relevant with filter warning, JSON validity, permissions-summary.sh unaffected.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC="$SCRIPT_DIR/test-commands.sh"
PS="$SCRIPT_DIR/permissions-summary.sh"

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dogma-test-commands-XXXXXX")"
cleanup() {
    rm -rf "$TEST_TMP_DIR"
}
trap cleanup EXIT

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

BASE_PERMS='<permissions>
## Git Permissions
- [x] May run `git add` autonomously
- [?] May run `git push` autonomously

## File Operations
- [ ] May delete files autonomously (rm, unlink, git clean)

## Workflow Permissions

### Testing
- [x] before commit
- [ ] before push

### Final Verification
- [x] run relevant tests
- [x] check build
- [a] run ALL tests
'

echo "Testing test-commands.sh..."
echo ""

# ============================================================================
echo "--- No file / no section ---"

NOFILE_DIR="$TEST_TMP_DIR/nofile"
mkdir -p "$NOFILE_DIR"
# Guard: the upward search must not find a real file above the temp dir.
if [ -f "$(dirname "$TEST_TMP_DIR")/DOGMA-PERMISSIONS.md" ]; then
    echo "[SKIP] a DOGMA-PERMISSIONS.md exists above the temp dir"
else
    capture "$TC" "$NOFILE_DIR"
    run_test "no file: exit 4" "4" "$RC"
    run_test "no file: no output" "" "$OUT"
    capture "$TC" get commit --dir "$NOFILE_DIR"
    run_test "no file: get exits 4" "4" "$RC"
fi

NOSEC_DIR="$TEST_TMP_DIR/nosection"
mkdir -p "$NOSEC_DIR"
printf '%s</permissions>\n' "$BASE_PERMS" > "$NOSEC_DIR/DOGMA-PERMISSIONS.md"
capture "$TC" "$NOSEC_DIR"
run_test "no section: exit 4" "4" "$RC"
run_test "no section: no output" "" "$OUT"
capture "$TC" --json "$NOSEC_DIR"
run_test "no section: json exit 4" "4" "$RC"
capture "$TC" get build --dir "$NOSEC_DIR"
run_test "no section: get exits 4" "4" "$RC"

echo ""

# ============================================================================
echo "--- All five stages ---"

FULL_DIR="$TEST_TMP_DIR/full"
mkdir -p "$FULL_DIR/sub/deeper"
cat > "$FULL_DIR/DOGMA-PERMISSIONS.md" <<EOF
# Dogma Permissions

${BASE_PERMS}
### Test Commands

Per-stage commands, all optional (missing line = Claude decides as before).
Optional branch filter in brackets: the stage only applies when its branch is listed
(commit: the branch committed on; push: the push target; build/all: the branch the work
is integrated into - local merge, push, or PR/MR into it). No filter = every branch.
- commit: \`npm run lint\` - fast static checks before every commit
- push [main, develop, stage]: \`npx vitest related --run\`
- relevant: \`npx vitest related --run\`
- build: \`npm run build\`
- all [main, stage]: \`npm test\`
</permissions>

- commit: \`outside permissions block\`
EOF

capture "$TC" "$FULL_DIR"
run_test "full: exit 0" "0" "$RC"
EXPECTED_KV="file=$FULL_DIR/DOGMA-PERMISSIONS.md
commit=npm run lint
push=npx vitest related --run
push_branches=main,develop,stage
relevant=npx vitest related --run
build=npm run build
all=npm test
all_branches=main,stage"
run_test "full: kv output" "$EXPECTED_KV" "$OUT"

capture "$TC" "$FULL_DIR/sub/deeper"
run_test "full: upward search from subdir finds the file" "$EXPECTED_KV" "$OUT"

for stage in commit push relevant build all; do
    capture "$TC" get "$stage" --dir "$FULL_DIR"
    run_test "get $stage without branch: exit 0" "0" "$RC"
done
capture "$TC" get commit --dir "$FULL_DIR"
run_test "get commit prints the first backtick span only" "npm run lint" "$OUT"
capture "$TC" get all --dir "$FULL_DIR"
run_test "get all without branch prints command" "npm test" "$OUT"

echo ""

# ============================================================================
echo "--- Branch filter ---"

capture "$TC" get all main --dir "$FULL_DIR"
run_test "filter match: all main -> command" "npm test" "$OUT"
run_test "filter match: exit 0" "0" "$RC"
capture "$TC" get all feature/x --dir "$FULL_DIR"
run_test "filter miss: all feature/x -> exit 4" "4" "$RC"
run_test "filter miss: no output" "" "$OUT"
capture "$TC" get push develop --dir "$FULL_DIR"
run_test "filter match: push develop" "npx vitest related --run" "$OUT"
capture "$TC" get commit feature/x --dir "$FULL_DIR"
run_test "no filter: commit applies on any branch" "npm run lint" "$OUT"
capture "$TC" get all mai --dir "$FULL_DIR"
run_test "filter is exact match (no prefix match)" "4" "$RC"

echo ""

# ============================================================================
echo "--- relevant with filter, partial section, unknown stage ---"

REL_DIR="$TEST_TMP_DIR/relevant"
mkdir -p "$REL_DIR"
cat > "$REL_DIR/DOGMA-PERMISSIONS.md" <<EOF
${BASE_PERMS}
### Test Commands
- relevant [main]: \`pytest -q\`
- lint: \`ruff check .\`
- build:
### Something Else
- all: \`should not count\`
</permissions>
EOF

capture "$TC" "$REL_DIR"
run_test "relevant with filter: exit 0" "0" "$RC"
run_test "relevant with filter: filter dropped, other stages absent" "file=$REL_DIR/DOGMA-PERMISSIONS.md
relevant=pytest -q" "$OUT"
case "$ERR" in
    *"relevant takes no branch filter"*) w=yes ;;
    *) w=no ;;
esac
run_test "relevant with filter: warning on stderr" "yes" "$w"
case "$ERR" in
    *"unknown stage: lint"*) w=yes ;;
    *) w=no ;;
esac
run_test "unknown stage line: warning on stderr" "yes" "$w"
capture "$TC" get relevant feature/x --dir "$REL_DIR"
run_test "relevant ignores branch: get on other branch still prints" "pytest -q" "$OUT"
capture "$TC" get all --dir "$REL_DIR"
run_test "line after next ### heading does not count" "4" "$RC"
capture "$TC" get build --dir "$REL_DIR"
run_test "stage line without command is undefined" "4" "$RC"

echo ""

# ============================================================================
echo "--- JSON ---"

capture "$TC" --json "$FULL_DIR"
run_test "json: exit 0" "0" "$RC"
JSON_CHECK="$(printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
s = d["stages"]
ok = (list(s) == ["commit", "push", "relevant", "build", "all"]
      and s["commit"] == {"command": "npm run lint", "branches": None}
      and s["push"]["branches"] == ["main", "develop", "stage"]
      and s["all"] == {"command": "npm test", "branches": ["main", "stage"]}
      and d["file"].endswith("DOGMA-PERMISSIONS.md"))
print("valid" if ok else "mismatch: " + json.dumps(d))
' 2>&1)"
run_test "json: valid and complete" "valid" "$JSON_CHECK"

capture "$TC" --json "$REL_DIR"
JSON_CHECK="$(printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("valid" if d["stages"] == {"relevant": {"command": "pytest -q", "branches": None}} else "mismatch")
' 2>&1)"
run_test "json: relevant branches null" "valid" "$JSON_CHECK"

echo ""

# ============================================================================
echo "--- Bad arguments ---"

capture "$TC" get nope --dir "$FULL_DIR"
run_test "unknown stage: exit 1" "1" "$RC"
capture "$TC" get
run_test "get without stage: exit 1" "1" "$RC"
capture "$TC" --bogus
run_test "unknown flag: exit 1" "1" "$RC"
capture "$TC" "$TEST_TMP_DIR/does-not-exist"
run_test "missing dir: exit 1" "1" "$RC"
capture "$TC" get all main extra --dir "$FULL_DIR"
run_test "get with extra positional: exit 1" "1" "$RC"

echo ""

# ============================================================================
echo "--- permissions-summary.sh unaffected ---"

capture "$PS" "$NOSEC_DIR"
SUMMARY_WITHOUT="$(printf '%s' "$OUT" | sed 's#^file=.*#file=X#')"
capture "$PS" "$FULL_DIR"
SUMMARY_WITH="$(printf '%s' "$OUT" | sed 's#^file=.*#file=X#')"
run_test "permissions-summary: same output with and without the section" "$SUMMARY_WITHOUT" "$SUMMARY_WITH"
run_test "permissions-summary: expected entries" "file=X
ask=git push
deny=delete files" "$SUMMARY_WITH"
capture "$PS" --json "$FULL_DIR"
JSON_CHECK="$(printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("valid" if d["ask"] == ["git push"] and d["deny"] == ["delete files"] else "mismatch")
' 2>&1)"
run_test "permissions-summary --json: unaffected" "valid" "$JSON_CHECK"

# The workflow checkbox lookups next to the new section stay unaffected too.
# shellcheck source=lib-permissions.sh
source "$SCRIPT_DIR/lib-permissions.sh"
result=$(get_permission_mode "run ALL tests" "$FULL_DIR/DOGMA-PERMISSIONS.md" "Final Verification")
run_test "get_permission_mode: Final Verification 'run ALL tests' still 'all'" "all" "$result"
result=$(get_permission_mode "before push" "$FULL_DIR/DOGMA-PERMISSIONS.md" "Testing")
run_test "get_permission_mode: Testing 'before push' still 'deny'" "deny" "$result"

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
