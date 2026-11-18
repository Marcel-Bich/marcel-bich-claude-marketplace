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

# A reader running alongside the writers must always see complete JSON. A file
# that cannot be opened at that instant is no partial read: native Windows can
# refuse an open for a moment while a rename replaces the file.
( bad=0; for _ in $(seq 1 300); do
      c=$(cat "$COUNTER" 2>/dev/null) || continue
      jq -e . <<< "$c" >/dev/null 2>&1 || bad=$((bad + 1))
  done; echo "$bad" > "$TEST_DIR/reader-bad" ) &
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
# The holder releases the lock between our failed mkdir and the stat: the lock
# must be retried, not taken for a stale one that cannot be removed (that gave
# up at once and lost updates on native Windows, where this window is wide).
check "a lock released between mkdir and stat is retried" "0" "$(
    mkdir_calls=0
    mkdir() { mkdir_calls=$((mkdir_calls + 1)); [[ "$mkdir_calls" -gt 1 ]] && command mkdir "$@"; }
    _limit_mkdir_acquire "$TEST_DIR/vanish.lock.d" 2; echo $?
)"
rmdir "$TEST_DIR/vanish.lock.d" 2>/dev/null
check "mkdir that keeps failing still gives up" "1" "$(
    mkdir() { return 1; }
    _limit_mkdir_acquire "$TEST_DIR/never.lock.d" 3; echo $?
)"

echo ">>> rejected write"
before=$(cksum < "$COUNTER")
printf 'not json {' | limit_atomic_write "$COUNTER"; rc=$?
check "invalid JSON is rejected" "1" "$rc"
check "target untouched by a rejected write" "$before" "$(cksum < "$COUNTER")"

echo ""
echo "passed: $PASS failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
