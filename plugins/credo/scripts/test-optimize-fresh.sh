#!/bin/bash
# Tests for credo-optimize-fresh.sh. Builds a bare remote plus clones in a temp dir
# (removed on exit) and checks branch/behind detection, suggestions, JSON and exit
# codes. Usage: bash test-optimize-fresh.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/credo-optimize-fresh.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-optimize-fresh-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | paste -sd'|' -; }

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
printf '[user]\n\tname = Test\n\temail = test@example.invalid\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

git init -q --bare "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/seed" 2>/dev/null
git -C "$TMP/seed" commit -q --allow-empty -m init
git -C "$TMP/seed" push -q origin main 2>/dev/null
git clone -q "$TMP/remote.git" "$TMP/work"
A="$TMP/work"

out="$("$SUT" --repo "$A")"; rc=$?
check "up to date exit" 0 "$rc"
check "up to date fresh" "yes" "$(field "$out" fresh)"
check "default detected" "main" "$(field "$out" default)"
check "remote detected" "origin" "$(field "$out" remote)"
check "fetch ok" "ok" "$(field "$out" fetch)"
check "no suggestions" "" "$(field "$out" suggest)"

git -C "$TMP/seed" commit -q --allow-empty -m second
git -C "$TMP/seed" push -q origin main 2>/dev/null

out="$("$SUT" --repo "$A" --no-fetch)"; rc=$?
check "no-fetch does not see new commit" 0 "$rc"
check "no-fetch flag" "skipped" "$(field "$out" fetch)"

out="$("$SUT" --repo "$A")"; rc=$?
check "behind exit" 1 "$rc"
check "behind count" "1" "$(field "$out" behind)"
check "behind suggest pull" "git pull --ff-only" "$(field "$out" suggest)"
check "fetch never moved the branch" "1" "$(git -C "$A" rev-list --count main)"

git -C "$A" pull -q --ff-only
git -C "$A" switch -q -c feature/x
out="$("$SUT" --repo "$A")"; rc=$?
check "feature branch exit" 1 "$rc"
check "feature branch on_default" "no" "$(field "$out" on_default)"
check "feature branch suggest switch" "git switch main" "$(field "$out" suggest)"

git -C "$TMP/seed" commit -q --allow-empty -m third
git -C "$TMP/seed" push -q origin main 2>/dev/null
out="$("$SUT" --repo "$A" --json)"; rc=$?
check "json exit" 1 "$rc"
check "json" "ok" "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d["fresh"]=="no" and d["behind"]==1 and d["branch"]=="feature/x" and d["suggest"]==["git switch main","git pull --ff-only"] else d)')"
check "never switched by the check" "feature/x" "$(git -C "$A" branch --show-current)"

printf 'x\n' > "$A/dirty.txt"
check "dirty counted" "1" "$(field "$("$SUT" --repo "$A" --no-fetch)" dirty)"

# local repo without remote: branch check only
L="$TMP/local"
git init -q "$L"
git -C "$L" commit -q --allow-empty -m init
out="$("$SUT" --repo "$L")"; rc=$?
check "no remote exit" 0 "$rc"
check "no remote fetch" "no-remote" "$(field "$out" fetch)"

# no recognisable default branch
U="$TMP/unknown"
git init -q -b trunk "$U"
git -C "$U" commit -q --allow-empty -m init
"$SUT" --repo "$U" >/dev/null; check "unknown default exit" 3 "$?"

# unreachable remote: the fetch failure is reported and freshness stays unknown
git -C "$L" remote add origin "$TMP/missing.git"
out="$("$SUT" --repo "$L")"; rc=$?
check "fetch failed reported" "failed" "$(field "$out" fetch)"
check "fetch failed -> freshness unknown" 3 "$rc"
check "fetch failed fresh value" "unknown" "$(field "$out" fresh)"

mkdir -p "$TMP/plain"
"$SUT" --repo "$TMP/plain" >/dev/null 2>&1; check "not a git repo exit" 4 "$?"
"$SUT" --bogus >/dev/null 2>&1; check "bad flag exit" 2 "$?"

printf 'test-optimize-fresh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
