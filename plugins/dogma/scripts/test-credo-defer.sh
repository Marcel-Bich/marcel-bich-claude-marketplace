#!/bin/bash
# Test script for lib-credo.sh (credo detection) and the dogma workflow injects that
# step back while credo is active: subagent-suggestion.sh, user-prompt-submit.sh
# (planning + versioning lines), prompt-intervention-reminder.sh (create-plan hint)
# and checklist-tracking.sh (ask before ticking). Each inject is checked with and
# without credo; the safety reminders must stay in both cases.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dogma-credo-defer-XXXXXX")"
# every rm below works inside this fresh temp dir only
case "$TEST_TMP_DIR" in
    */dogma-credo-defer-??????) ;;
    *) echo "unexpected temp dir: $TEST_TMP_DIR" >&2; exit 1 ;;
esac
cleanup() {
    rm -rf "$TEST_TMP_DIR"
}
trap cleanup EXIT

# hermetic: own config dir, no credo env overrides, no session-folder file, no credo pin
unset CREDO_SESSION_MODES_DIR CREDO_SESSION_DECISIONS_DIR CREDO_DIR_DECISIONS_DIR CLAUDE_MB_DOGMA_CREDO_DEFER
export CLAUDE_CONFIG_DIR="$TEST_TMP_DIR/config"
export DOGMA_SESSION_DIR="$TEST_TMP_DIR/session" DOGMA_CREDO_CONFIG=none
mkdir -p "$CLAUDE_CONFIG_DIR" "$DOGMA_SESSION_DIR"

PROJECT="$TEST_TMP_DIR/project"
mkdir -p "$PROJECT/CLAUDE"
echo "# Subagents" > "$PROJECT/CLAUDE/CLAUDE.subagents.md"
echo "# Planning" > "$PROJECT/CLAUDE/CLAUDE.planning.md"
echo "# Versioning" > "$PROJECT/CLAUDE/CLAUDE.versioning.md"
echo "# Language" > "$PROJECT/CLAUDE/CLAUDE.language.md"
echo "# Intervention" > "$PROJECT/CLAUDE/CLAUDE.prompt-intervention.md"
printf '# Git\n<ai_traces>\n</ai_traces>\nNEVER delete local files\n' > "$PROJECT/CLAUDE/CLAUDE.git.md"
printf '# Todo\n- [ ] first task\n' > "$PROJECT/TODO.md"

SID="sess-1"
INPUT="{\"session_id\":\"$SID\",\"prompt\":\"hi\"}"
MODES="$CLAUDE_CONFIG_DIR/credo/session-modes"
DECISIONS="$CLAUDE_CONFIG_DIR/credo/session-decisions"
DIRS="$CLAUDE_CONFIG_DIR/credo/dir-decisions"
DIR_HASH="$(cd "$PROJECT" && printf '%s' "$PWD" | sha256sum | cut -d' ' -f1)"

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

reset_state() {
    rm -rf "$CLAUDE_CONFIG_DIR/credo" "$CLAUDE_CONFIG_DIR/settings.json" "$PROJECT/.claude"
    mkdir -p "$MODES" "$DECISIONS" "$DIRS"
}

# detect [input] -> "active:<mode>" or "inactive"
detect() {
    (
        cd "$PROJECT"
        # shellcheck source=lib-credo.sh
        source "$SCRIPT_DIR/lib-credo.sh"
        if dogma_credo_active "${1-$INPUT}"; then
            echo "active:$DOGMA_CREDO_MODE"
        else
            echo "inactive"
        fi
    )
}

is() { [ "$1" = "$2" ] && echo true || echo false; }
has() { case "$1" in *"$2"*) echo true ;; *) echo false ;; esac; }
lacks() { case "$1" in *"$2"*) echo false ;; *) echo true ;; esac; }
run_hook() { (cd "$PROJECT" && printf '%s' "$INPUT" | bash "$SCRIPT_DIR/$1"); }

# === Detection ===
reset_state
run_test "no credo state -> inactive" "$(is "$(detect)" inactive)"

echo active > "$MODES/$SID"
run_test "session mode active -> active" "$(is "$(detect)" active:active)"
echo passive > "$MODES/$SID"
run_test "session mode passive -> active" "$(is "$(detect)" active:passive)"
echo " Autonomous " > "$MODES/$SID"
run_test "session mode autonomous (case, spaces) -> active, mode reported" "$(is "$(detect)" active:autonomous)"
echo bogus > "$MODES/$SID"
run_test "unknown session mode -> inactive" "$(is "$(detect)" inactive)"
run_test "other session's mode does not count" \
    "$(echo active > "$MODES/$SID"; is "$(detect '{"session_id":"sess-2"}')" inactive)"
run_test "path tricks in session id are ignored" \
    "$(is "$(detect '{"session_id":"../sess-1"}')" inactive)"

reset_state
echo accepted > "$DECISIONS/$SID"
run_test "session decision accepted -> active" "$(is "$(detect)" active:)"
echo declined > "$DECISIONS/$SID"
run_test "session decision declined -> inactive" "$(is "$(detect)" inactive)"

reset_state
printf 'accepted\n# %s\n' "$PROJECT" > "$DIRS/$DIR_HASH"
run_test "dir opt-in without credo enabled in settings -> inactive (fail open)" "$(is "$(detect)" inactive)"
echo '{"enabledPlugins":{"credo@some-market":true}}' > "$CLAUDE_CONFIG_DIR/settings.json"
run_test "dir opt-in + credo enabled in user settings -> active" "$(is "$(detect)" active:)"
run_test "dir opt-in also works without a session id" "$(is "$(detect '{}')" active:)"
echo '{"enabledPlugins":{"credo@some-market":false}}' > "$CLAUDE_CONFIG_DIR/settings.json"
run_test "dir opt-in + credo disabled in user settings -> inactive" "$(is "$(detect)" inactive)"
mkdir -p "$PROJECT/.claude"
echo '{"enabledPlugins":{"credo@some-market":true}}' > "$PROJECT/.claude/settings.local.json"
run_test "project settings.local enabling credo wins over user settings" "$(is "$(detect)" active:)"
printf 'declined\n' > "$DIRS/$DIR_HASH"
run_test "dir declined -> inactive" "$(is "$(detect)" inactive)"

reset_state
echo active > "$MODES/$SID"
run_test "CLAUDE_MB_DOGMA_CREDO_DEFER=false -> never active" \
    "$(CLAUDE_MB_DOGMA_CREDO_DEFER=false; export CLAUDE_MB_DOGMA_CREDO_DEFER; is "$(detect)" inactive)"

# === subagent-suggestion.sh (#68, #69, #70) ===
reset_state
OUT="$(run_hook subagent-suggestion.sh)"
run_test "without credo: full mandatory flow" "$(has "$OUT" 'MANDATORY ORCHESTRATION FLOW')"
run_test "without credo: handoff chain present" "$(has "$OUT" 'HANDOFF CHAIN')"
run_test "without credo: STEP 5 run ALL tests present" "$(has "$OUT" 'Run ALL tests')"
run_test "without credo: no credo pointer" "$(lacks "$OUT" 'credo is active')"

echo active > "$MODES/$SID"
OUT="$(run_hook subagent-suggestion.sh)"
run_test "with credo: block still printed" "$(has "$OUT" '<dogma-orchestration>')"
run_test "with credo: points at credo orchestration" "$(has "$OUT" 'orchestration skill; work is tracked')"
run_test "with credo: no MANDATORY flow" "$(lacks "$OUT" 'MANDATORY')"
run_test "with credo: no handoff chain" "$(lacks "$OUT" 'HANDOFF CHAIN')"
run_test "with credo: no run ALL tests" "$(lacks "$OUT" 'Run ALL tests')"
run_test "with credo: no checklist-manager step" "$(lacks "$OUT" 'checklist-manager')"
run_test "with credo: safety hooks named as active" "$(has "$OUT" 'delete guard')"

# === user-prompt-submit.sh (#71, #72) ===
reset_state
OUT="$(run_hook user-prompt-submit.sh)"
run_test "without credo: planning suggests /create-plan" "$(has "$OUT" 'suggest /create-plan')"
run_test "without credo: versioning says bump version on changes" "$(has "$OUT" 'Bump version on changes')"

echo passive > "$MODES/$SID"
OUT="$(run_hook user-prompt-submit.sh)"
run_test "with credo: planning points at credo items" "$(has "$OUT" 'credo item + clarify')"
run_test "with credo: no /create-plan suggestion" "$(lacks "$OUT" 'suggest /create-plan')"
run_test "with credo: no bump per change" "$(lacks "$OUT" 'Bump version on changes')"
run_test "with credo: versioning points at the release flow" "$(has "$OUT" 'no version bump per change')"
run_test "with credo: output convention kept" "$(has "$OUT" '<dogma-output-convention>')"
run_test "with credo: AI traces reminder kept" "$(has "$OUT" 'AI Traces:')"
run_test "with credo: language reminder kept" "$(has "$OUT" 'Language:')"
run_test "with credo: file protection reminder kept" "$(has "$OUT" 'File Protection:')"

# === prompt-intervention-reminder.sh (#72) ===
reset_state
OUT="$(run_hook prompt-intervention-reminder.sh)"
run_test "without credo: suggests /create-plan" "$(has "$OUT" 'suggest /create-plan')"

echo active > "$MODES/$SID"
OUT="$(run_hook prompt-intervention-reminder.sh)"
run_test "with credo: complex work = credo item" "$(has "$OUT" 'a credo item + clarify')"
run_test "with credo: no /create-plan suggestion" "$(lacks "$OUT" 'suggest /create-plan')"
run_test "with credo: other skill hints kept" "$(has "$OUT" 'eisenhower-matrix')"

echo autonomous > "$MODES/$SID"
OUT="$(run_hook prompt-intervention-reminder.sh)"
run_test "credo autonomous: reminder silent" "$(is "$OUT" '')"

# === checklist-tracking.sh (#73) ===
reset_state
OUT="$(run_hook checklist-tracking.sh)"
run_test "without credo: lists the open checklist" "$(has "$OUT" 'TODO.md (1 open)')"
run_test "without credo: asks before ticking" "$(has "$OUT" 'Mark as done? [Y/n]')"

echo active > "$MODES/$SID"
OUT="$(run_hook checklist-tracking.sh)"
run_test "with credo: still lists the open checklist" "$(has "$OUT" 'TODO.md (1 open)')"
run_test "with credo: dd / done gate counts as confirmation" "$(has "$OUT" "explicit 'dd'")"
run_test "with credo: no Y/n question" "$(lacks "$OUT" '[Y/n]')"
run_test "with credo attended: asks when neither dd nor gate" "$(has "$OUT" 'ask the user before')"

echo autonomous > "$MODES/$SID"
OUT="$(run_hook checklist-tracking.sh)"
run_test "credo autonomous: never ask, note instead" "$(has "$OUT" 'never ask; note the candidate')"
run_test "credo autonomous: no attended ask line" "$(lacks "$OUT" 'ask the user before')"

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_TOTAL total"

[ "$TESTS_FAILED" -eq 0 ]
