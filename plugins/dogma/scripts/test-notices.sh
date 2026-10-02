#!/bin/bash
# Test script for notices-pending.sh, notice-applies-test-commands.sh and the
# SessionStart hook hooks/notices-inject.sh.
# Covers: applies / not applies, mark, seen not listed again, two repos independent,
# JSON validity, not a git repo -> 4, hook silent / valid JSON; source broadcasts
# (NOTICES.md) as local path and file:// clone, daily throttle, background fetch,
# unreachable source silent + hint once a day, seen per repo, max age, src: prefix,
# both kinds together.

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
unset CLAUDE_MB_DOGMA_SOURCE CLAUDE_MB_DOGMA_SOURCE_FETCH CLAUDE_MB_DOGMA_NOTICES_MAX_AGE_DAYS
# Isolated git config: no user/system insteadOf, sshCommand or hooks leak into the tests.
: > "$TEST_TMP_DIR/gitconfig"
export GIT_CONFIG_GLOBAL="$TEST_TMP_DIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_COUNT GIT_SSH_COMMAND

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

# Stable id (§ly5v): a reworded heading in another subsection still counts as present
REPO_ID="$TEST_TMP_DIR/repo-id"
make_repo "$REPO_ID"
printf '<permissions>\n## Workflow Permissions\n\n### Final Verification\n- [x] (§3dy3) run ALL tests\n\n#### Befehle je Stufe (§ly5v)\n- commit: `make lint`\n</permissions>\n' > "$REPO_ID/DOGMA-PERMISSIONS.md"
capture "$NP" "$REPO_ID"
run_test "reworded Test Commands heading with id: exit 4" "4" "$RC"

REPO_TPL="$TEST_TMP_DIR/repo-template-heading"
make_repo "$REPO_TPL"
printf '<permissions>\n### Test Commands (§ly5v)\n- commit: `make lint`\n</permissions>\n' > "$REPO_TPL/DOGMA-PERMISSIONS.md"
capture "$NP" "$REPO_TPL"
run_test "template heading '### Test Commands (§ly5v)': exit 4" "4" "$RC"

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
      and n[0]["kind"] == "plugin"
      and sorted(n[0]) == ["action", "id", "kind", "text"])
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
echo "--- Source broadcasts (NOTICES.md) ---"

CACHE_ROOT="$CLAUDE_CONFIG_DIR/dogma/source-cache"
days_ago() { python3 -c 'import datetime,sys; print(datetime.date.today() - datetime.timedelta(days=int(sys.argv[1])))' "$1"; }
D_RECENT="$(days_ago 3)"
D_OLD="$(days_ago 200)"
sgit() { git -C "$SRC" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@example.invalid "$@"; }
# list ids of a kv listing on one line
ids_of() { printf '%s\n' "$1" | grep '^id=' | cut -d= -f2 | tr '\n' ' ' | sed 's/ $//'; }

SRC="$TEST_TMP_DIR/dogma-source"
make_repo "$SRC"
mkdir -p "$SRC/CLAUDE"
cat > "$SRC/NOTICES.md" <<EOF_N
# Notices

Free text before the first entry is ignored.

## $D_RECENT (§n001) Stable setting ids
Action: /dogma:sync
Settings now carry ids.
Run a sync once.

## $D_RECENT (§n002) Info only
Nothing to run.

## $D_OLD (§n000) Ancient entry
Action: /dogma:sync
Too old.

## $D_RECENT No id here
Action: /dogma:sync

## (§n009) No date here
Skipped.
EOF_N
sgit add -A && sgit commit -q -m init

REPO_D="$TEST_TMP_DIR/repo-d"      # uses dogma via CLAUDE/, no DOGMA-PERMISSIONS.md
make_repo "$REPO_D"
mkdir -p "$REPO_D/CLAUDE"
REPO_E="$TEST_TMP_DIR/repo-e"      # DOGMA-PERMISSIONS.md without Test Commands: both kinds
make_repo "$REPO_E"
printf '%s' "$PERMS_NO_SECTION" > "$REPO_E/DOGMA-PERMISSIONS.md"

# --- local path ---
export CLAUDE_MB_DOGMA_SOURCE="$SRC"

capture "$NP" "$REPO_D"
run_test "path source: exit 0" "0" "$RC"
run_test "path source: ids prefixed, old/no-id/no-date skipped" "src:n001 src:n002" "$(ids_of "$OUT")"
run_test "path source: kind line" "kind=source" "$(printf '%s\n' "$OUT" | grep '^kind=' | sort -u)"
run_test "path source: action parsed" "action=/dogma:sync" "$(printf '%s\n' "$OUT" | grep '^action=' | head -1)"
run_test "path source: text = title + body + date" "text=Stable setting ids: Settings now carry ids. Run a sync once. ($D_RECENT)" "$(printf '%s\n' "$OUT" | grep '^text=' | head -1)"
run_test "path source: no clone for a local path" "no" "$([ -d "$CACHE_ROOT" ] && find "$CACHE_ROOT" -name repo -type d | grep -q . && echo yes || echo no)"

capture "$NP" "$REPO_NOFILE"
run_test "repo without dogma: no source notices (exit 4)" "4" "$RC"
capture "$NP" "$SRC"
run_test "the source repo itself: no source notices (exit 4)" "4" "$RC"

CLAUDE_MB_DOGMA_NOTICES_MAX_AGE_DAYS=0 capture "$NP" "$REPO_D"
run_test "max age 0 = no limit: old entry shown" "src:n001 src:n002 src:n000" "$(ids_of "$OUT")"
CLAUDE_MB_DOGMA_NOTICES_MAX_AGE_DAYS=2 capture "$NP" "$REPO_D"
run_test "max age 2 days: nothing (exit 4)" "4" "$RC"

capture "$NP" --json "$REPO_E"
BOTH_CHECK="$(printf '%s' "$OUT" | python3 -c '
import json, sys
n = json.load(sys.stdin)["notices"]
got = [(x["id"], x["kind"], x["action"]) for x in n]
want = [("dogma-test-commands", "plugin", "/dogma:permissions"),
        ("src:n001", "source", "/dogma:sync"), ("src:n002", "source", "")]
print("valid" if got == want and "hint" not in n else got)
' 2>&1)"
run_test "both kinds together in json" "valid" "$BOTH_CHECK"

capture "$NP" mark "src:n999" "$REPO_D"
run_test "mark unknown source id: exit 1" "1" "$RC"
capture "$NP" mark "src:../x" "$REPO_D"
run_test "mark invalid source id: exit 1" "1" "$RC"
capture "$NP" mark "src:n001" "$REPO_D"
run_test "mark src:n001: exit 0" "0" "$RC"
run_test "mark src: seen file under .src/" "1" "$(find "$CLAUDE_CONFIG_DIR/dogma/notices-seen" -path '*/.src/n001' -type f | wc -l | tr -d ' ')"
capture "$NP" "$REPO_D"
run_test "seen per repo: src:n001 gone in repo D" "src:n002" "$(ids_of "$OUT")"
capture "$NP" "$REPO_E"
run_test "seen per repo: src:n001 still pending in repo E" "dogma-test-commands src:n001 src:n002" "$(ids_of "$OUT")"
capture "$NP" mark "dogma-test-commands" "$REPO_E"
capture "$NP" "$REPO_E"
run_test "plugin id marked: source ids stay" "src:n001 src:n002" "$(ids_of "$OUT")"

capture "$NP" --hint "$REPO_D"
run_test "reachable path source: no hint" "" "$(printf '%s\n' "$OUT" | grep '^hint=' || true)"

# --- file:// URL (cached clone) ---
export CLAUDE_MB_DOGMA_SOURCE="file://$SRC"
export CLAUDE_MB_DOGMA_SOURCE_FETCH=sync
# state dir of (source, identity of the repo it is called from)
state_dir_of() { (cd "$1" && "$SCRIPT_DIR/source-cache.sh" state-dir); }
URL_CACHE="$(state_dir_of "$REPO_D")"
run_test "url source: state dir under source-cache" "yes" "$(case "$URL_CACHE" in "$CACHE_ROOT"/????????????????) echo yes ;; *) echo "$URL_CACHE" ;; esac)"

capture "$NP" "$REPO_D"
run_test "url source: exit 0 after first clone" "0" "$RC"
run_test "url source: ids (seen state shared with the path source)" "src:n002" "$(ids_of "$OUT")"
run_test "url source: shallow clone in the cache" "yes" "$([ -f "$URL_CACHE/repo/NOTICES.md" ] && [ -f "$URL_CACHE/repo/.git/shallow" ] && echo yes || echo no)"
run_test "url source: status ok" "ok" "$(cat "$URL_CACHE/status" 2>/dev/null)"

printf '\n## %s (§n003) Brand new\nAction: /dogma:sync\nNew entry.\n' "$D_RECENT" >> "$SRC/NOTICES.md"
sgit commit -q -am n003
capture "$NP" "$REPO_D"
run_test "daily throttle: new entry not fetched within 24h" "src:n002" "$(ids_of "$OUT")"
echo $(( $(date +%s) - 90000 )) > "$URL_CACHE/last-check"
capture "$NP" "$REPO_D"
run_test "after 24h (faked timestamp): fetched, new entry shown" "src:n002 src:n003" "$(ids_of "$OUT")"
CHECKED="$(cat "$URL_CACHE/last-check")"
run_test "after fetch: last-check is fresh" "yes" "$([ $(( $(date +%s) - CHECKED )) -lt 60 ] && echo yes || echo no)"

# background mode (default): returns at once, fetch happens detached
printf '\n## %s (§n004) Background\nNew.\n' "$D_RECENT" >> "$SRC/NOTICES.md"
sgit commit -q -am n004
echo $(( $(date +%s) - 90000 )) > "$URL_CACHE/last-check"
unset CLAUDE_MB_DOGMA_SOURCE_FETCH
capture "$NP" "$REPO_D"
run_test "background fetch: current cache used meanwhile" "src:n002 src:n003" "$(ids_of "$OUT")"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -q n004 "$URL_CACHE/repo/NOTICES.md" 2>/dev/null && [ ! -d "$URL_CACHE/lock" ] && break
    sleep 0.5
done
capture "$NP" "$REPO_D"
run_test "background fetch: new entry after it finished" "src:n002 src:n003 src:n004" "$(ids_of "$OUT")"
CLAUDE_MB_DOGMA_SOURCE_FETCH=off capture "$NP" mark "src:n004" "$REPO_D"
run_test "mark src:n004 (url source): exit 0" "0" "$RC"

capture run_hook "$REPO_D"
HOOK_SRC_CHECK="$(printf '%s' "$OUT" | python3 -c '
import json, sys
c = json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]
ok = ("src:n002" in c and "src:n003" in c and "dogma source" in c and "src:n004" not in c
      and "information only" in c and "Got it" in c and "not reachable" not in c)
print("valid" if ok else c)
' 2>&1)"
run_test "hook: source notices in the context" "valid" "$HOOK_SRC_CHECK"

# --- identity routing: url.insteadOf of the CURRENT repo reaches the cache fetch ---
ALIAS_URL="https://dogma-alias.invalid/owner/dogma-source.git"
export CLAUDE_MB_DOGMA_SOURCE="$ALIAS_URL"
export CLAUDE_MB_DOGMA_SOURCE_FETCH=sync
REPO_G="$TEST_TMP_DIR/repo-g"      # carries the rewrite alias -> file:// source
make_repo "$REPO_G"
mkdir -p "$REPO_G/CLAUDE"
git -C "$REPO_G" config "url.file://$SRC.insteadOf" "$ALIAS_URL"

capture "$NP" "$REPO_D"
run_test "identity: alias without rewrite fails (exit 4)" "4" "$RC"
run_test "identity: status fail without rewrite" "fail" "$(cat "$(state_dir_of "$REPO_D")/status" 2>/dev/null)"
capture "$NP" "$REPO_G"
run_test "identity: rewrite of the current repo used, fetch ok" "src:n001 src:n002 src:n003 src:n004" "$(ids_of "$OUT")"
run_test "identity: own state dir per identity" "yes" "$([ "$(state_dir_of "$REPO_D")" != "$(state_dir_of "$REPO_G")" ] && echo yes || echo no)"
run_test "identity: status ok with rewrite" "ok" "$(cat "$(state_dir_of "$REPO_G")/status" 2>/dev/null)"
capture "$NP" --hint "$REPO_G"
run_test "identity: no hint for the working identity" "" "$(printf '%s\n' "$OUT" | grep '^hint=' || true)"
capture "$NP" --hint "$REPO_D"
run_test "identity: hint for the failing identity" "yes" "$(printf '%s\n' "$OUT" | grep -q '^hint=.*not reachable' && echo yes || echo no)"
run_test "identity: rewrite value not in the cache clone config" "no" "$(grep -q dogma-alias "$(state_dir_of "$REPO_G")/repo/.git/config" && grep -q "insteadOf" "$(state_dir_of "$REPO_G")/repo/.git/config" && echo yes || echo no)"

# --- unreachable source: silent, hint at most once a day ---
export CLAUDE_MB_DOGMA_SOURCE="file://$TEST_TMP_DIR/no-such-source"
export CLAUDE_MB_DOGMA_SOURCE_FETCH=sync
REPO_F="$TEST_TMP_DIR/repo-f"
make_repo "$REPO_F"
mkdir -p "$REPO_F/CLAUDE"
BAD_CACHE="$(state_dir_of "$REPO_F")"

capture "$NP" "$REPO_F"
run_test "unreachable: silent without --hint (exit 4)" "4" "$RC"
run_test "unreachable: no output, no stderr" "|" "$OUT|$ERR"
run_test "unreachable: status fail" "fail" "$(cat "$BAD_CACHE/status" 2>/dev/null)"
capture "$NP" --json --hint "$REPO_F"
HINT_CHECK="$(printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("valid" if d["notices"] == [] and "not reachable" in d["hint"] and "SSH host alias" in d["hint"] else d)
' 2>&1)"
run_test "unreachable: --hint gives the hint once" "valid" "$HINT_CHECK"
capture "$NP" --json --hint "$REPO_F"
run_test "unreachable: hint not again the same day (exit 4)" "4" "$RC"
capture run_hook "$REPO_F"
run_test "hook: no second hint the same day" "" "$OUT"
echo $(( $(date +%s) - 90000 )) > "$BAD_CACHE/hint-shown"
capture run_hook "$REPO_F"
HOOK_HINT_CHECK="$(printf '%s' "$OUT" | python3 -c '
import json, sys
c = json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]
print("valid" if "not reachable" in c and "Update notice" not in c else c)
' 2>&1)"
run_test "hook: hint again on the next day" "valid" "$HOOK_HINT_CHECK"

# userinfo is never echoed
export CLAUDE_MB_DOGMA_SOURCE="file://someuser@localhost$TEST_TMP_DIR/no-such-source-2"
capture "$NP" --hint "$REPO_F"
run_test "hint: userinfo of the URL not echoed" "no" "$(printf '%s' "$OUT" | grep -q someuser && echo yes || echo no)"

export CLAUDE_MB_DOGMA_SOURCE="$TEST_TMP_DIR/missing-path"
capture "$NP" --hint "$REPO_F"
run_test "missing local path: hint says it does not exist" "yes" "$(printf '%s' "$OUT" | grep -q '^hint=.*does not exist' && echo yes || echo no)"
capture "$NP" "$REPO_F"
run_test "missing local path: silent without --hint" "4" "$RC"

export CLAUDE_MB_DOGMA_SOURCE="relative/path"
capture "$NP" "$REPO_F"
run_test "invalid source: silent (exit 4)" "4" "$RC"

unset CLAUDE_MB_DOGMA_SOURCE CLAUDE_MB_DOGMA_SOURCE_FETCH
capture "$NP" "$REPO_D"
run_test "no source configured: no source notices (exit 4)" "4" "$RC"

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
