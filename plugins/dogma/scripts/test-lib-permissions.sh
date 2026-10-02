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

# hermetic: no session-folder file to inherit from, no credo pinned project
mkdir -p "$TEST_TMP_DIR/session"
export DOGMA_SESSION_DIR="$TEST_TMP_DIR/session" DOGMA_CREDO_CONFIG=none

# Test helper function
run_test() {
    local description="$1"
    local expected="$2"
    local actual="$3"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo P >> "$TEST_TMP_DIR/subshell-results"
    else
        echo "[FAIL] $description"
        echo "       Expected: '$expected'"
        echo "       Actual:   '$actual'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo F >> "$TEST_TMP_DIR/subshell-results"
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
        echo P >> "$TEST_TMP_DIR/subshell-results"
    else
        echo "[FAIL] $description"
        echo "       Expected exit: $expected_exit"
        echo "       Actual exit:   $actual_exit"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo F >> "$TEST_TMP_DIR/subshell-results"
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
# Test 5: Section-specific permissions (3rd parameter)
# ============================================================================
echo "--- Section-Specific Permissions ---"

# Create test permissions file with sections
PERMS_FILE_SECTIONS="$TEST_TMP_DIR/permissions-sections.md"
cat > "$PERMS_FILE_SECTIONS" << 'EOF'
# Permissions

<permissions>
## Development Phase
- [x] run tests
- [x] check lint
- [ ] deploy to production

## Final Verification
- [a] run tests
- [a] check lint
- [?] deploy to production

## Cleanup
- [1] delete temp files
</permissions>
EOF

# Test 5.1: Section "Development Phase" with [x] run tests -> "auto"
result=$(get_permission_mode "run tests" "$PERMS_FILE_SECTIONS" "Development Phase")
run_test "Section 'Development Phase': run tests [x] returns 'auto'" "auto" "$result"

# Test 5.2: Section "Final Verification" with [a] run tests -> "all"
result=$(get_permission_mode "run tests" "$PERMS_FILE_SECTIONS" "Final Verification")
run_test "Section 'Final Verification': run tests [a] returns 'all'" "all" "$result"

# Test 5.3: Same pattern, different sections -> different results
result_dev=$(get_permission_mode "check lint" "$PERMS_FILE_SECTIONS" "Development Phase")
result_final=$(get_permission_mode "check lint" "$PERMS_FILE_SECTIONS" "Final Verification")
run_test "Same pattern 'check lint' in 'Development Phase' returns 'auto'" "auto" "$result_dev"
run_test "Same pattern 'check lint' in 'Final Verification' returns 'all'" "all" "$result_final"

# Verify they are actually different
if [ "$result_dev" != "$result_final" ]; then
    echo "[PASS] Different sections return different results for same pattern"
    TESTS_PASSED=$((TESTS_PASSED + 1)); echo P >> "$TEST_TMP_DIR/subshell-results"
else
    echo "[FAIL] Different sections should return different results"
    echo "       Development Phase: '$result_dev'"
    echo "       Final Verification: '$result_final'"
    TESTS_FAILED=$((TESTS_FAILED + 1)); echo F >> "$TEST_TMP_DIR/subshell-results"
fi
TESTS_TOTAL=$((TESTS_TOTAL + 1))

# Test 5.4: Non-existent section -> default "auto"
result=$(get_permission_mode "run tests" "$PERMS_FILE_SECTIONS" "Non Existent Section")
run_test "Non-existent section returns 'auto' (default)" "auto" "$result"

# Test 5.5: Without section parameter -> backwards compatible (searches entire block)
# When no section given, "run tests" appears multiple times, should find first match [x]
result=$(get_permission_mode "run tests" "$PERMS_FILE_SECTIONS")
run_test "Without section parameter: backwards compatible (finds first match)" "auto" "$result"

# Test 5.6: Pattern only in specific section, searched in wrong section -> default
result=$(get_permission_mode "delete temp files" "$PERMS_FILE_SECTIONS" "Development Phase")
run_test "Pattern not in searched section returns 'auto' (default)" "auto" "$result"

# Test 5.7: Pattern only in specific section, searched correctly -> correct result
result=$(get_permission_mode "delete temp files" "$PERMS_FILE_SECTIONS" "Cleanup")
run_test "Pattern in correct section 'Cleanup' returns 'one'" "one" "$result"

# Test 5.8: deploy to production - different states in different sections
result_dev=$(get_permission_mode "deploy to production" "$PERMS_FILE_SECTIONS" "Development Phase")
result_final=$(get_permission_mode "deploy to production" "$PERMS_FILE_SECTIONS" "Final Verification")
run_test "deploy to production in 'Development Phase' returns 'deny'" "deny" "$result_dev"
run_test "deploy to production in 'Final Verification' returns 'ask'" "ask" "$result_final"

echo ""

# ============================================================================
# Test 6: Subsection support with ### (nested under ## sections)
# ============================================================================
echo "--- Subsection Support (### Subsections) ---"

# Create test permissions file with ### subsections
PERMS_FILE_SUBSECTIONS="$TEST_TMP_DIR/permissions-subsections.md"
cat > "$PERMS_FILE_SUBSECTIONS" << 'EOF'
# Permissions

<permissions>
## Workflow Permissions

### Testing
- [x] run relevant tests
- [x] silent-failure check

### Review
- [x] review changed code
- [ ] review architecture

### Final Verification
- [a] run ALL tests
- [x] check build
</permissions>
EOF

# Test 6.1: ### Section "Testing" with "run relevant tests" -> "auto"
result=$(get_permission_mode "run relevant tests" "$PERMS_FILE_SUBSECTIONS" "Testing")
run_test "Subsection 'Testing': run relevant tests [x] returns 'auto'" "auto" "$result"

# Test 6.2: ### Section "Final Verification" with "run ALL tests" -> "all"
result=$(get_permission_mode "run ALL tests" "$PERMS_FILE_SUBSECTIONS" "Final Verification")
run_test "Subsection 'Final Verification': run ALL tests [a] returns 'all'" "all" "$result"

# Test 6.3: ### Section "Review" with "review architecture" -> "deny"
result=$(get_permission_mode "review architecture" "$PERMS_FILE_SUBSECTIONS" "Review")
run_test "Subsection 'Review': review architecture [ ] returns 'deny'" "deny" "$result"

# Test 6.4: ## Section "Workflow Permissions" should find items in all ### subsections
result=$(get_permission_mode "run relevant tests" "$PERMS_FILE_SUBSECTIONS" "Workflow Permissions")
run_test "Parent section 'Workflow Permissions' finds 'run relevant tests' in subsection" "auto" "$result"

result=$(get_permission_mode "run ALL tests" "$PERMS_FILE_SUBSECTIONS" "Workflow Permissions")
run_test "Parent section 'Workflow Permissions' finds 'run ALL tests' in subsection" "all" "$result"

result=$(get_permission_mode "review architecture" "$PERMS_FILE_SUBSECTIONS" "Workflow Permissions")
run_test "Parent section 'Workflow Permissions' finds 'review architecture' in subsection" "deny" "$result"

# Test 6.5: Non-existent ### subsection -> "auto" (default)
result=$(get_permission_mode "run relevant tests" "$PERMS_FILE_SUBSECTIONS" "Non Existent Subsection")
run_test "Non-existent subsection returns 'auto' (default)" "auto" "$result"

echo ""

# ============================================================================
# Test 7: Stable setting ids "(§xxxx)" - id first, text as fallback
# ============================================================================
echo "--- Stable setting ids ---"

PERMS_FILE_IDS="$TEST_TMP_DIR/ids.md"
cat > "$PERMS_FILE_IDS" <<'EOF'
<permissions>
## Git Permissions
- [x] (§6gpt) Darf Dateien stagen
- [ ] (§bww9) Darf zum Remote pushen
- [x] May run `git push` autonomously (stale duplicate text, the id line wins)

## File Operations
- [?] (§0lgy) Löschen erlaubt

## Workflow Permissions

### Review
- [a] (§3dy3) alles laufen lassen

### Final Verification
- [x] run relevant tests
</permissions>
EOF
PERMS_IDS_SECTION=$(get_permissions_section "$PERMS_FILE_IDS")

# 7.1 id match with reworded text (legacy content mode)
result=$(get_permission_mode "$PERMS_IDS_SECTION" "§6gpt|git add")
run_test "id: reworded 'git add' line found by §6gpt -> auto" "auto" "$result"
result=$(get_permission_mode "$PERMS_IDS_SECTION" "§bww9|git push")
run_test "id: id line wins over a text match elsewhere -> deny" "deny" "$result"
result=$(get_permission_mode "$PERMS_IDS_SECTION" "§0lgy|delete files")
run_test "id: reworded delete line -> ask" "ask" "$result"

# 7.2 id in a different subsection (file mode with section filter)
result=$(get_permission_mode "§3dy3|run ALL tests" "$PERMS_FILE_IDS" "Final Verification")
run_test "id: found in another subsection although section is given -> all" "all" "$result"

# 7.3 id missing in file -> text fallback / default
result=$(get_permission_mode "§0c7y|run relevant tests" "$PERMS_FILE_IDS" "Final Verification")
run_test "id: no line with §0c7y -> text fallback 'run relevant tests' -> auto" "auto" "$result"
result=$(get_permission_mode "$PERMS_IDS_SECTION" "§zzzz")
run_test "id only, not found -> auto (default)" "auto" "$result"

# 7.4 check_permission with ids
run_exit_test "check_permission: §bww9 [ ] -> exit 1" "1" "$PERMS_IDS_SECTION" "§bww9|git push"
run_exit_test "check_permission: §0lgy [?] -> exit 0" "0" "$PERMS_IDS_SECTION" "§0lgy|delete files"

# 7.5 old file without ids: spec falls back to the old text match
PERMS_OLD="- [ ] May run \`git push\` autonomously
- [?] May delete files autonomously (rm, unlink, git clean)"
result=$(get_permission_mode "$PERMS_OLD" "§bww9|git push")
run_test "old file without ids: §bww9|git push -> deny via text" "deny" "$result"
result=$(get_permission_mode "$PERMS_OLD" "§0lgy|delete files")
run_test "old file without ids: §0lgy|delete files -> ask via text" "ask" "$result"
run_exit_test "old file without ids: check_permission §bww9|git push -> exit 1" "1" "$PERMS_OLD" "§bww9|git push"

# 7.6 helpers for [x]-only switches and parsed headings
PERMS_SWITCH="### Delegation
- [ ] (§o85w) Aufgaben-Tool zählt
- [x] Skill tool usage counts as delegation
#### Befehle je Stufe (§ly5v)"
perm_is_checked "$PERMS_SWITCH" o85w 'Task tool.*counts as delegation' && r=on || r=off
run_test "perm_is_checked: id line [ ] -> off" "off" "$r"
perm_is_checked "$PERMS_SWITCH" i397 'Skill tool.*counts as delegation' && r=on || r=off
run_test "perm_is_checked: no id line -> text fallback [x] -> on" "on" "$r"
perm_has_heading "$PERMS_SWITCH" ly5v 'Test Commands' && r=yes || r=no
run_test "perm_has_heading: reworded heading found by id" "yes" "$r"
perm_has_heading "### Test Commands" ly5v 'Test Commands' && r=yes || r=no
run_test "perm_has_heading: old heading without id -> text fallback" "yes" "$r"
perm_has_heading "### Something" ly5v 'Test Commands' && r=yes || r=no
run_test "perm_has_heading: neither id nor text -> no" "no" "$r"

# 7.7 locale independence (C locale, "§" is two bytes there)
result=$(LC_ALL=C get_permission_mode "$PERMS_IDS_SECTION" "§bww9|git push")
run_test "id match works under LC_ALL=C" "deny" "$result"

# ============================================================================
# Test 8: Which file applies (target > pinned project > session folder) and
#         inheritance from the session folder's file (§r3nx)
# ============================================================================
echo "--- File resolution and inheritance ---"

INH="$TEST_TMP_DIR/inh"
WS="$INH/workspace"
PROJ="$INH/projects"
mkdir -p "$WS" "$PROJ/app/sub" "$PROJ/noinherit" "$PROJ/nocheckbox" "$PROJ/oldfile" "$PROJ/nofile" "$INH/elsewhere"

# session folder file: everything restrictive + test commands + worktree list
cat > "$WS/DOGMA-PERMISSIONS.md" <<'EOF'
<permissions>
## Git Permissions
- [x] (§6gpt) May run `git add` autonomously
- [?] (§2w1t) May run `git commit` autonomously
- [ ] (§bww9) May run `git push` autonomously

## File Operations
- [ ] (§0lgy) May delete files autonomously (rm, unlink, git clean)

## Workflow Permissions

### Hydra
- [x] (§xw1i) use Hydra for 2+ independent tasks

Worktree files (§47p9) (excluded files only):
- link: WS-ONLY.md

### Test Commands (§ly5v)
- commit: `ws-lint`
- build: `ws-build`
- all [main]: `ws-all`
</permissions>
EOF

# project file: defines only git push (allowed) and the commit stage; inherit [x]
cat > "$PROJ/app/DOGMA-PERMISSIONS.md" <<'EOF'
<permissions>
## Inheritance
- [x] (§r3nx) inherit permissions

## Git Permissions
- [x] (§bww9) May run `git push` autonomously

## Workflow Permissions

### Test Commands (§ly5v)
- commit: `app-lint`
</permissions>
EOF

# same, inheritance switched off
sed 's/- \[x\] (§r3nx)/- [ ] (§r3nx)/' "$PROJ/app/DOGMA-PERMISSIONS.md" > "$PROJ/noinherit/DOGMA-PERMISSIONS.md"
# same, no inheritance checkbox at all (= on)
grep -v 'r3nx\|## Inheritance' "$PROJ/app/DOGMA-PERMISSIONS.md" > "$PROJ/nocheckbox/DOGMA-PERMISSIONS.md"
# old file without ids
cat > "$PROJ/oldfile/DOGMA-PERMISSIONS.md" <<'EOF'
<permissions>
## Git Permissions
- [x] May run `git push` autonomously
- [ ] May run `git commit` autonomously
</permissions>
EOF

# 8.1 target detection from Bash commands
(
    cd "$WS"
    r=$(dogma_target_from_command "git -C $PROJ/app commit -m x") || r=none
    run_test "target: git -C <abs dir>" "$PROJ/app" "$r"
    r=$(dogma_target_from_command "git -C ../projects/app push") || r=none
    run_test "target: git -C <relative dir>" "$WS/../projects/app" "$r"
    r=$(dogma_target_from_command "cd $PROJ/app && git push") || r=none
    run_test "target: cd <dir> &&" "$PROJ/app" "$r"
    r=$(dogma_target_from_command "cd \"$PROJ/app\"; git commit -m x") || r=none
    run_test "target: cd \"<dir>\";" "$PROJ/app" "$r"
    r=$(dogma_target_from_command "(cd $PROJ/app && git push)") || r=none
    run_test "target: ( cd <dir> && ... )" "$PROJ/app" "$r"
    r=$(dogma_target_from_command "cd $PROJ && git -C app push") || r=none
    run_test "target: git -C relative to the cd dir" "$PROJ/app" "$r"
    r=$(dogma_target_from_command "git push") || r=none
    run_test "target: plain command -> none" "none" "$r"
    r=$(dogma_target_from_command "git -C $PROJ/does-not-exist push") || r=none
    run_test "target: missing dir -> none" "none" "$r"
    r=$(HOME="$INH" dogma_target_from_command "git -C ~/projects/app push") || r=none
    run_test "target: ~ expanded" "$INH/projects/app" "$r"
)

# 8.2 resolution order
(
    export DOGMA_SESSION_DIR="$WS"
    cd "$WS"
    r=$(find_permissions_file) || r=none
    run_test "resolve: no target -> session folder file" "$WS/DOGMA-PERMISSIONS.md" "$r"
    r=$(find_permissions_file "$PROJ/app/sub") || r=none
    run_test "resolve: target dir -> upward from target" "$PROJ/app/DOGMA-PERMISSIONS.md" "$r"
    r=$(find_permissions_file "$PROJ/app/sub/new-file.txt") || r=none
    run_test "resolve: target file path (not yet existing)" "$PROJ/app/DOGMA-PERMISSIONS.md" "$r"
    r=$(find_permissions_file "$PROJ/nofile") || r=none
    run_test "resolve: target without own file -> session folder file" "$WS/DOGMA-PERMISSIONS.md" "$r"
)

# 8.3 per-id inheritance via load_permissions
(
    export DOGMA_SESSION_DIR="$WS"
    cd "$WS"
    load_permissions "$PROJ/app"
    run_test "inherit: PERMS_FILE is the project file" "$PROJ/app/DOGMA-PERMISSIONS.md" "$PERMS_FILE"
    run_test "inherit: DOGMA_INHERIT_FILE is the session file" "$WS/DOGMA-PERMISSIONS.md" "$DOGMA_INHERIT_FILE"
    run_test "inherit: own id wins (push [x] over session [ ])" "auto" "$(get_permission_mode "$PERMS_SECTION" "§bww9|git push")"
    run_test "inherit: missing id from session (commit [?])" "ask" "$(get_permission_mode "$PERMS_SECTION" "§2w1t|git commit")"
    run_test "inherit: missing id from session (delete [ ])" "deny" "$(get_permission_mode "$PERMS_SECTION" "§0lgy|delete files")"
    run_test "inherit: missing everywhere -> auto" "auto" "$(get_permission_mode "$PERMS_SECTION" "§zzzz|no such setting")"
    check_permission "$PERMS_SECTION" "§0lgy|delete files" && r=allowed || r=blocked
    run_test "inherit: check_permission uses the inherited deny" "blocked" "$r"
    perm_is_checked "$(cat "$PERMS_FILE")" xw1i 'use Hydra' && r=on || r=off
    run_test "inherit: perm_is_checked from session" "on" "$r"
    run_test "inherit: perm_defining_file (inherited)" "$WS/DOGMA-PERMISSIONS.md" "$(perm_defining_file "§2w1t|git commit")"
    run_test "inherit: perm_defining_file (own)" "$PROJ/app/DOGMA-PERMISSIONS.md" "$(perm_defining_file "§bww9|git push")"
    run_test "inherit: file mode get_permission_mode" "ask" "$(get_permission_mode "§2w1t|git commit" "$PERMS_FILE")"

    load_permissions "$PROJ/noinherit"
    run_test "inherit [ ]: no inherit file" "" "$DOGMA_INHERIT_FILE"
    run_test "inherit [ ]: missing id -> auto (only own file counts)" "auto" "$(get_permission_mode "$PERMS_SECTION" "§2w1t|git commit")"

    load_permissions "$PROJ/nocheckbox"
    run_test "inherit missing checkbox = on" "ask" "$(get_permission_mode "$PERMS_SECTION" "§2w1t|git commit")"

    load_permissions "$PROJ/oldfile"
    run_test "old file: text line wins over inherited id ([x] push)" "auto" "$(get_permission_mode "$PERMS_SECTION" "§bww9|git push")"
    run_test "old file: text line [ ] commit stays deny" "deny" "$(get_permission_mode "$PERMS_SECTION" "§2w1t|git commit")"
    run_test "old file: missing setting inherited (delete [ ])" "deny" "$(get_permission_mode "$PERMS_SECTION" "§0lgy|delete files")"

    load_permissions
    run_test "session itself: no inheritance" "" "$DOGMA_INHERIT_FILE"
)

# 8.4 git-permissions.sh hook end to end (session folder = workspace)
hook() { # command -> hook stdout
    local json
    json=$(jq -cn --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}')
    (cd "$WS" && DOGMA_SESSION_DIR="$WS" bash "$SCRIPT_DIR/git-permissions.sh" <<<"$json")
}
decision() { # hook output -> deny|ask|allow
    case "$1" in
        *'"deny"'*) echo deny ;;
        *'"ask"'*) echo ask ;;
        *) echo allow ;;
    esac
}
run_test "hook: git push in session folder -> deny" "deny" "$(decision "$(hook "git push")")"
run_test "hook: git -C app push -> allowed by app's file" "allow" "$(decision "$(hook "git -C $PROJ/app push")")"
run_test "hook: cd app && git push -> allowed" "allow" "$(decision "$(hook "cd $PROJ/app && git push")")"
run_test "hook: git -C app commit -> inherited ask" "ask" "$(decision "$(hook "git -C $PROJ/app commit -m x")")"
out=$(hook "git -C $PROJ/app commit -m x")
case "$out" in *"$WS/DOGMA-PERMISSIONS.md"*) r=yes ;; *) r=no ;; esac
run_test "hook: message names the file that defines the setting" "yes" "$r"
run_test "hook: noinherit project -> commit allowed" "allow" "$(decision "$(hook "git -C $PROJ/noinherit commit -m x")")"

# 8.5 credo pinned project (fake pin in a temp CLAUDE_CONFIG_DIR)
CREDO_CFG="$SCRIPT_DIR/../../credo/scripts/credo-config.sh"
if [ -f "$CREDO_CFG" ]; then
    mkdir -p "$INH/cfg/credo/session-projects"
    printf '%s\n' "$PROJ/app" > "$INH/cfg/credo/session-projects/test-sid"
    (
        unset CREDO_DIR
        export DOGMA_SESSION_DIR="$WS" DOGMA_CREDO_CONFIG="$CREDO_CFG" CLAUDE_CONFIG_DIR="$INH/cfg"
        export CREDO_SESSION_ID=test-sid
        cd "$WS"
        r=$(find_permissions_file) || r=none
        run_test "pinned: no target -> pinned project file" "$PROJ/app/DOGMA-PERMISSIONS.md" "$r"
        r=$(find_permissions_file "$PROJ/noinherit") || r=none
        run_test "pinned: a target still wins over the pin" "$PROJ/noinherit/DOGMA-PERMISSIONS.md" "$r"
        run_test "pinned: hook git push -> allowed by the pinned file" "allow" "$(decision "$(hook "git push")")"
        run_test "pinned: hook git commit -> inherited ask" "ask" "$(decision "$(hook "git commit -m x")")"
        r=$(DOGMA_CREDO_CONFIG=none find_permissions_file) || r=none
        run_test "pinned: credo absent -> session folder" "$WS/DOGMA-PERMISSIONS.md" "$r"
        r=$(DOGMA_SESSION_DIR="$PROJ/app/sub" find_permissions_file) || r=none
        run_test "pinned: session inside the pinned project -> upward from session" "$PROJ/app/DOGMA-PERMISSIONS.md" "$r"
    )
else
    echo "[SKIP] pinned project tests (credo not next to dogma)"
fi

# 8.6 readers: test-commands.sh per stage, worktree-files.sh, permissions-summary.sh
(
    export DOGMA_SESSION_DIR="$WS"
    cd "$WS"
    r=$(bash "$SCRIPT_DIR/test-commands.sh" get commit --dir "$PROJ/app") || r=none
    run_test "test-commands: own stage wins" "app-lint" "$r"
    r=$(bash "$SCRIPT_DIR/test-commands.sh" get build --dir "$PROJ/app") || r=none
    run_test "test-commands: missing stage inherited" "ws-build" "$r"
    r=$(bash "$SCRIPT_DIR/test-commands.sh" get all feature --dir "$PROJ/app") || r=none
    run_test "test-commands: inherited branch filter applies" "none" "$r"
    r=$(bash "$SCRIPT_DIR/test-commands.sh" --json "$PROJ/app" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["stages"]["build"].get("source",""), d["stages"]["commit"].get("source","own"))')
    run_test "test-commands: json source only on inherited stages" "$WS/DOGMA-PERMISSIONS.md own" "$r"
    r=$(bash "$SCRIPT_DIR/test-commands.sh" get build --dir "$PROJ/noinherit") || r=none
    run_test "test-commands: inherit [ ] -> stage missing" "none" "$r"
    r=$(bash "$SCRIPT_DIR/worktree-files.sh" "$PROJ/app")
    run_test "worktree-files: list missing -> inherited list" "link WS-ONLY.md" "$r"
    r=$(bash "$SCRIPT_DIR/worktree-files.sh" "$PROJ/noinherit" | head -n1)
    run_test "worktree-files: inherit [ ] -> default list" "link CLAUDE.md" "$r"
    r=$(bash "$SCRIPT_DIR/permissions-summary.sh" "$PROJ/app" | tr '\n' ' ')
    run_test "summary: effective merged view" "file=$PROJ/app/DOGMA-PERMISSIONS.md ask=git commit deny=delete files " "$r"
    r=$(bash "$SCRIPT_DIR/permissions-summary.sh" --json "$PROJ/app" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sorted(d["source"].items()))')
    run_test "summary: json source key for inherited entries" "[('delete files', '$WS/DOGMA-PERMISSIONS.md'), ('git commit', '$WS/DOGMA-PERMISSIONS.md')]" "$r"
    r=$(bash "$SCRIPT_DIR/permissions-summary.sh" "$PROJ/noinherit" | tr '\n' ' ')
    run_test "summary: inherit [ ] -> own file only, switch not listed" "file=$PROJ/noinherit/DOGMA-PERMISSIONS.md " "$r"
)

echo ""

# ============================================================================
# Results
# ============================================================================
# counted from the results file: tests inside ( ... ) subshells count too
TESTS_PASSED=$(grep -c '^P$' "$TEST_TMP_DIR/subshell-results" || true)
TESTS_FAILED=$(grep -c '^F$' "$TEST_TMP_DIR/subshell-results" || true)
TESTS_TOTAL=$((TESTS_PASSED + TESTS_FAILED))
echo "============================================"
echo "Results: $TESTS_PASSED/$TESTS_TOTAL tests passed"

if [ "$TESTS_FAILED" -gt 0 ]; then
    echo "FAILED: $TESTS_FAILED test(s) failed"
    exit 1
else
    echo "SUCCESS: All tests passed"
    exit 0
fi
