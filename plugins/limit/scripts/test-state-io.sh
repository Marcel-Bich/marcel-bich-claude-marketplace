#!/usr/bin/env bash
# test-state-io.sh - The state-io primitives under parallel writers: a
# read-modify-write held under limit_with_lock loses no update, a reader of
# limit_atomic_write never sees a partial file, and a rejected write leaves the
# target untouched. Temp dir only.
# shellcheck disable=SC2250

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export LIMIT_LOCK_WAIT=10

# shellcheck source=state-io.sh
source "$SCRIPT_DIR/state-io.sh"

PASS=0
FAIL=0
check() {
    if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); echo "  PASS: $1"
    else FAIL=$((FAIL + 1)); echo "  FAIL: $1 (expected '$2', got '$3')"; fi
}

COUNTER="$TEST_DIR/counter.json"
LOCK="$TEST_DIR/counter.json.lock"
echo '{"n":0}' > "$COUNTER"

increment_once() {
    local n
    n=$(jq -r '.n' "$COUNTER") || return 1
    jq -n --argjson n "$((n + 1))" '{n: $n}' | limit_atomic_write "$COUNTER"
}

echo ">>> 12 parallel writers, 5 locked read-modify-write cycles each"
pids=()
for _ in $(seq 1 12); do
    ( for _ in 1 2 3 4 5; do limit_with_lock "$LOCK" increment_once || exit 1; done ) &
    pids+=("$!")
done

# A reader running alongside the writers must always see complete JSON.
( bad=0; for _ in $(seq 1 300); do jq -e . "$COUNTER" >/dev/null 2>&1 || bad=$((bad + 1)); done; echo "$bad" > "$TEST_DIR/reader-bad" ) &
pids+=("$!")

for pid in "${pids[@]}"; do wait "$pid"; done

check "no lost update under the lock" "60" "$(jq -r '.n' "$COUNTER")"
check "reader never saw a partial file" "0" "$(cat "$TEST_DIR/reader-bad" 2>/dev/null)"
check "no temp file left behind" "0" "$(find "$TEST_DIR" -name 'counter.json.tmp.*' | wc -l | tr -d ' ')"

echo ">>> mkdir fallback lock (used where flock is missing)"
_limit_mkdir_acquire "$TEST_DIR/fallback.lock.d" 2; rc1=$?
_limit_mkdir_acquire "$TEST_DIR/fallback.lock.d" 2; rc2=$?
rmdir "$TEST_DIR/fallback.lock.d" 2>/dev/null
check "first acquire succeeds" "0" "$rc1"
check "second acquire is refused while the lock is held" "1" "$rc2"

echo ">>> rejected write"
before=$(cksum < "$COUNTER")
printf 'not json {' | limit_atomic_write "$COUNTER"; rc=$?
check "invalid JSON is rejected" "1" "$rc"
check "target untouched by a rejected write" "$before" "$(cksum < "$COUNTER")"

echo ""
echo "passed: $PASS failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
