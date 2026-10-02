#!/bin/bash
# Tests for credo-optimize-idle.sh. Builds a throwaway git repo in a temp dir
# (removed on exit), fakes every signal's age with touch -d and CREDO_OPTIMIZE_NOW,
# and checks that idle needs ALL four signals to be old. Usage: bash test-optimize-idle.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/credo-optimize-idle.sh"
STATE="$SCRIPT_DIR/credo-optimize-state.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-optimize-idle-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
printf '[user]\n\tname = Test\n\temail = test@example.invalid\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
# isolate the config cascade and the state store from the real user setup
export CREDO_OPTIMIZE_DIR="$TMP/store" CREDO_GLOBAL="$TMP/no-global" CREDO_PROFILE="$TMP/no-profile"
unset CREDO_OPTIMIZE_IDLE_DAYS CREDO_DIR CREDO_PROJECT

NOW="$(date +%s)"
export CREDO_OPTIMIZE_NOW="$NOW"
OLD="@$((NOW - 10 * 86400))"
FRESH="@$((NOW - 3600))"

R="$TMP/repo"
git init -q "$R"
printf 'a\n' > "$R/a.txt"
git -C "$R" add a.txt
git -C "$R" commit -q -m init

age_all_old() {
    touch -d "$OLD" "$R/.git/logs/HEAD" "$R/.git/index" "$R/a.txt"
    "$STATE" --repo "$R" seen "$((NOW - 10 * 86400))"
}
run() { "$SUT" --repo "$R" "$@"; }

age_all_old
out="$(run)"; rc=$?
check "all old -> idle exit" 0 "$rc"
check "all old -> idle=yes" "idle=yes" "$(printf '%s\n' "$out" | grep '^idle=')"
check "default threshold 7" "threshold_days=7" "$(printf '%s\n' "$out" | grep '^threshold_days=')"
check "clean tree -> dirty none" "age_dirty_s=none" "$(printf '%s\n' "$out" | grep '^age_dirty_s=')"
check "index untouched by the check" "$((NOW - 10 * 86400))" "$(stat -c %Y "$R/.git/index")"

age_all_old; "$STATE" --repo "$R" seen "$((NOW - 3600))"
run >/dev/null; check "fresh last-seen -> not idle" 1 "$?"

age_all_old; touch -d "$FRESH" "$R/.git/logs/HEAD"
run >/dev/null; check "fresh reflog -> not idle" 1 "$?"

age_all_old; touch -d "$FRESH" "$R/.git/index"
run >/dev/null; check "fresh index -> not idle" 1 "$?"

age_all_old; printf 'b\n' >> "$R/a.txt"; touch -d "$FRESH" "$R/a.txt"; touch -d "$OLD" "$R/.git/index"
run >/dev/null; check "fresh modified file -> not idle" 1 "$?"
touch -d "$OLD" "$R/a.txt"
run >/dev/null; check "old modified file -> idle" 0 "$?"
git -C "$R" checkout -q -- a.txt

age_all_old; printf 'n\n' > "$R/new.txt"; touch -d "$FRESH" "$R/new.txt"
run >/dev/null; check "fresh untracked file -> not idle" 1 "$?"
touch -d "$OLD" "$R/new.txt"
run >/dev/null; check "old untracked file -> idle" 0 "$?"
mkdir -p "$TMP/keep"; mv "$R/new.txt" "$TMP/keep/"

# a missing last-seen does not argue against idle
age_all_old; rm -f "$TMP"/store/*/last-seen
out="$(run)"; rc=$?
check "never seen + old git -> idle" 0 "$rc"
check "never seen -> age none" "age_last_seen_s=none" "$(printf '%s\n' "$out" | grep '^age_last_seen_s=')"

# thresholds: flag, env, project config
age_all_old
run --days 30 >/dev/null; check "--days 30 -> not idle" 1 "$?"
CREDO_OPTIMIZE_IDLE_DAYS=30 run >/dev/null; check "env 30 -> not idle" 1 "$?"
mkdir -p "$R/.credo"; printf 'optimize:\n  idle_days: 30\n' > "$R/.credo/config"
printf '.credo/\n' >> "$R/.git/info/exclude"
age_all_old
out="$(run)"; rc=$?
check "config 30 -> not idle" 1 "$rc"
check "config threshold read" "threshold_days=30" "$(printf '%s\n' "$out" | grep '^threshold_days=')"
run --days 5 >/dev/null; check "--days beats config" 0 "$?"

out="$(run --days 5 --json)"
check "json" "ok" "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d["idle"] is True and d["threshold_days"]==5 and d["age_dirty_s"] is None and d["age_index_s"]>=9*86400 else d)')"

mkdir -p "$TMP/plain"
"$SUT" --repo "$TMP/plain" >/dev/null 2>&1; check "not a git repo exit" 4 "$?"
"$SUT" --bogus >/dev/null 2>&1; check "bad flag exit" 2 "$?"

printf 'test-optimize-idle: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
