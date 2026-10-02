#!/bin/bash
# Test script for worktree-files.sh (worktree files list in DOGMA-PERMISSIONS.md)
# Covers: no file -> default, no list -> default, configured kinds, bare entry = link,
# backticks, invalid entries, list end, JSON validity, bad args, and that
# permissions-summary.sh output is unaffected by the new Hydra lines.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$SCRIPT_DIR/worktree-files.sh"
PS="$SCRIPT_DIR/permissions-summary.sh"

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dogma-worktree-files-XXXXXX")"
cleanup() {
    rm -rf "$TEST_TMP_DIR"
}
trap cleanup EXIT

# hermetic: no session-folder file to inherit from, no credo pinned project
mkdir -p "$TEST_TMP_DIR/session"
export DOGMA_SESSION_DIR="$TEST_TMP_DIR/session" DOGMA_CREDO_CONFIG=none

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

capture() {
    local errfile="$TEST_TMP_DIR/stderr"
    OUT="$("$@" 2>"$errfile")" && RC=0 || RC=$?
    ERR="$(cat "$errfile")"
}

DEFAULT_OUT='link CLAUDE.md
link CLAUDE/
link GUIDES/
link DOGMA-PERMISSIONS.md
link .credo/'

BASE_PERMS='<permissions>
## Git Permissions
- [x] May run `git add` autonomously
- [?] May run `git push` autonomously

## File Operations
- [ ] May delete files autonomously (rm, unlink, git clean)

## Workflow Permissions

### Hydra

Parallel work (only if Hydra available, otherwise sequential):
- [x] use Hydra for 2+ independent tasks

Worktree cleanup at item close ([x] = remove without asking, [?] = ask each time, [ ] = never):
- [ ] clean up merged worktrees automatically
'

echo "Testing worktree-files.sh..."
echo ""

echo "--- Defaults ---"
NOFILE_DIR="$TEST_TMP_DIR/nofile"
mkdir -p "$NOFILE_DIR"
if [ -f "$(dirname "$TEST_TMP_DIR")/DOGMA-PERMISSIONS.md" ]; then
    echo "[SKIP] a DOGMA-PERMISSIONS.md exists above the temp dir"
else
    capture "$WF" "$NOFILE_DIR"
    run_test "no file: exit 0" "0" "$RC"
    run_test "no file: default list" "$DEFAULT_OUT" "$OUT"
    capture "$WF" --json "$NOFILE_DIR"
    run_test "no file: json source default, file null" "default None 5" \
        "$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["source"], d["file"], len(d["entries"]))')"
fi

NOLIST_DIR="$TEST_TMP_DIR/nolist"
mkdir -p "$NOLIST_DIR"
printf '%s</permissions>\n' "$BASE_PERMS" > "$NOLIST_DIR/DOGMA-PERMISSIONS.md"
capture "$WF" "$NOLIST_DIR"
run_test "no list: exit 0" "0" "$RC"
run_test "no list: default list" "$DEFAULT_OUT" "$OUT"

EMPTY_DIR="$TEST_TMP_DIR/empty"
mkdir -p "$EMPTY_DIR"
printf '%s\nWorktree files (excluded files only; versioned files come with git checkout):\n</permissions>\n' "$BASE_PERMS" > "$EMPTY_DIR/DOGMA-PERMISSIONS.md"
capture "$WF" "$EMPTY_DIR"
run_test "empty list: default list" "$DEFAULT_OUT" "$OUT"

echo ""
echo "--- Configured list ---"
CONF_DIR="$TEST_TMP_DIR/conf"
mkdir -p "$CONF_DIR/sub/deeper"
printf '%s\nWorktree files (excluded files only; versioned files come with git checkout):\n- link: CLAUDE.md\n- `GUIDES/`\n- copy: .env.local  <!-- per worktree -->\n- link: ./.credo/\n- link: /etc/passwd\n- link: ../outside\n- move: x\n- link: CLAUDE.md\n- [x] some checkbox ends the list\n- link: after-checkbox\n\n### TDD\n- link: other-section\n</permissions>\n' "$BASE_PERMS" > "$CONF_DIR/DOGMA-PERMISSIONS.md"
capture "$WF" "$CONF_DIR/sub/deeper"
run_test "configured: exit 0" "0" "$RC"
run_test "configured: entries (upward search)" "link CLAUDE.md
link GUIDES/
copy .env.local
link .credo/" "$OUT"
case "$ERR" in *"outside the repo: /etc/passwd"*) R1=yes ;; *) R1=no ;; esac
run_test "configured: absolute path warned" "yes" "$R1"
case "$ERR" in *"outside the repo: ../outside"*) R1=yes ;; *) R1=no ;; esac
run_test "configured: .. path warned" "yes" "$R1"
case "$ERR" in *"unknown kind: move"*) R1=yes ;; *) R1=no ;; esac
run_test "configured: unknown kind warned" "yes" "$R1"
case "$ERR" in *"duplicate path CLAUDE.md"*) R1=yes ;; *) R1=no ;; esac
run_test "configured: duplicate warned" "yes" "$R1"

capture "$WF" --json "$CONF_DIR"
run_test "configured json" "configured copy .env.local" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); e=d["entries"][2]; print(d["source"], e["kind"], e["path"])')"

echo ""
echo "--- Stable id (§47p9) ---"
ID_DIR="$TEST_TMP_DIR/ids"
mkdir -p "$ID_DIR"
# Reworded label in another subsection; a plain "Worktree files" list in ### Hydra must lose.
printf '%s\nWorktree files (excluded files only):\n- link: from-text-label\n\n### Arbeitsbäume\nDateien für neue Worktrees (§47p9):\n- link: CLAUDE.md\n- copy: .env.local\n</permissions>\n' "$BASE_PERMS" > "$ID_DIR/DOGMA-PERMISSIONS.md"
capture "$WF" "$ID_DIR"
run_test "id: reworded label in another subsection wins" "link CLAUDE.md
copy .env.local" "$OUT"

TPL_DIR="$TEST_TMP_DIR/template-label"
mkdir -p "$TPL_DIR"
printf '<permissions>\n### Hydra\n- [x] (§xw1i) use Hydra for 2+ independent tasks\n\nWorktree files (§47p9) (excluded files only; versioned files come with git checkout):\n- link: GUIDES/\n</permissions>\n' > "$TPL_DIR/DOGMA-PERMISSIONS.md"
capture "$WF" "$TPL_DIR"
run_test "id: template label" "link GUIDES/" "$OUT"

OLDF_DIR="$TEST_TMP_DIR/old-no-id"
mkdir -p "$OLDF_DIR"
printf '%s\nWorktree files (excluded files only; versioned files come with git checkout):\n- link: CLAUDE.md\n</permissions>\n' "$BASE_PERMS" > "$OLDF_DIR/DOGMA-PERMISSIONS.md"
capture "$WF" "$OLDF_DIR"
run_test "old file without ids: text fallback in ### Hydra" "link CLAUDE.md" "$OUT"

echo ""
echo "--- Arguments ---"
capture "$WF" --bogus
run_test "unknown flag: exit 1" "1" "$RC"
capture "$WF" "$TEST_TMP_DIR/does-not-exist"
run_test "missing dir: exit 1" "1" "$RC"
capture "$WF" "$CONF_DIR" extra
run_test "extra arg: exit 1" "1" "$RC"

echo ""
echo "--- permissions-summary.sh unaffected ---"
capture "$PS" "$CONF_DIR"
run_test "summary unchanged by Hydra lines" "file=$CONF_DIR/DOGMA-PERMISSIONS.md
ask=git push
deny=delete files" "$OUT"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_TOTAL passed, $TESTS_FAILED failed"
[ "$TESTS_FAILED" -eq 0 ]
