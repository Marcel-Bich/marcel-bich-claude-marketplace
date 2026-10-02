#!/bin/bash
# Tests for credo-optimize-state.sh. Builds throwaway git repos and a state store in
# a temp dir (removed on exit). Usage: bash test-optimize-state.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/credo-optimize-state.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-optimize-state-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
printf '[user]\n\tname = Test\n\temail = test@example.invalid\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
export CREDO_OPTIMIZE_DIR="$TMP/store"

R="$TMP/repo"
git init -q "$R"
git -C "$R" commit -q --allow-empty -m init
mkdir -p "$R/sub"

check "optin empty" "" "$("$SUT" --repo "$R" optin)"
"$SUT" --repo "$R" optin yes >/dev/null; check "optin set exit" 0 "$?"
check "optin yes" "yes" "$("$SUT" --repo "$R" optin)"
check "optin from subdir" "yes" "$(cd "$R/sub" && "$SUT" optin)"
"$SUT" --repo "$R" optin maybe >/dev/null 2>&1; check "optin bad value" 1 "$?"

"$SUT" --repo "$R" seen 1000; check "seen explicit" "1000" "$("$SUT" --repo "$R" get-seen)"
CREDO_OPTIMIZE_NOW=2000 "$SUT" --repo "$R" seen; check "seen now override" "2000" "$("$SUT" --repo "$R" get-seen)"
"$SUT" --repo "$R" seen abc >/dev/null 2>&1; check "seen bad epoch" 1 "$?"

"$SUT" --repo "$R" pending 3000; check "pending set" "3000" "$("$SUT" --repo "$R" get-pending)"
"$SUT" --repo "$R" offered 4000
check "offered sets last-offer" "4000" "$("$SUT" --repo "$R" get-offer)"
check "offered clears pending" "" "$("$SUT" --repo "$R" get-pending)"

"$SUT" --repo "$R" never-add "hotspot:a/b.sh"
"$SUT" --repo "$R" never-add "test-convention"
"$SUT" --repo "$R" never-add "hotspot:a/b.sh"
check "never-list dedup" $'hotspot:a/b.sh\ntest-convention' "$("$SUT" --repo "$R" never-list)"
"$SUT" --repo "$R" never-has "test-convention"; check "never-has yes" 0 "$?"
"$SUT" --repo "$R" never-has "nope"; check "never-has no" 1 "$?"
"$SUT" --repo "$R" never-has "hotspot:a/b"; check "never-has exact match only" 1 "$?"

out="$("$SUT" --repo "$R" get --json)"
check "json" "ok" "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d["optin"]=="yes" and d["last_seen"]==2000 and d["last_offer"]==4000 and d["pending"] is None and d["never"]==["hotspot:a/b.sh","test-convention"] else d)')"
check "get text optin" "optin=yes" "$("$SUT" --repo "$R" get | grep '^optin=')"
check "get text never_count" "never_count=2" "$("$SUT" --repo "$R" get | grep '^never_count=')"

# a linked worktree shares the state of the main checkout
git -C "$R" worktree add -q "$TMP/wt" -b wt-branch
check "worktree shares state" "yes" "$("$SUT" --repo "$TMP/wt" optin)"

# a second repo is independent
R2="$TMP/repo2"
git init -q "$R2"
check "other repo independent" "" "$("$SUT" --repo "$R2" optin)"

# per profile: another CLAUDE_CONFIG_DIR is another store
check "profile store separate" "" "$(unset CREDO_OPTIMIZE_DIR; CLAUDE_CONFIG_DIR="$TMP/profile" "$SUT" --repo "$R" optin)"
(unset CREDO_OPTIMIZE_DIR; CLAUDE_CONFIG_DIR="$TMP/profile" "$SUT" --repo "$R" optin no >/dev/null)
check "profile store path" "1" "$(find "$TMP/profile/credo/optimize" -name optin | wc -l | tr -d ' ')"

mkdir -p "$TMP/plain"
"$SUT" --repo "$TMP/plain" optin >/dev/null 2>&1; check "not a git repo exit" 4 "$?"
"$SUT" >/dev/null 2>&1; check "no args exit" 1 "$?"
"$SUT" --repo "$R" bogus >/dev/null 2>&1; check "unknown command exit" 1 "$?"

printf 'test-optimize-state: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
