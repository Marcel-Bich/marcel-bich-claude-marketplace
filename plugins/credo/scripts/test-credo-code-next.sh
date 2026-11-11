#!/bin/bash
# Tests for credo-code-next.sh (one shared, locked counter per project for the typed
# codes T, Q, V) and for the credo-counter-lib.sh refactor of credo-id-next.sh.
# Builds throwaway credo projects and profile dirs in a temp dir (removed on exit);
# nothing touches a real project or the real profile.
# Usage: bash test-credo-code-next.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/credo-code-next.sh"
ID_NEXT="$SCRIPT_DIR/credo-id-next.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-code-next-test.XXXXXX")"
cleanup() {
    case "$TMP" in
        "${TMPDIR:-/tmp}"/credo-code-next-test.??????) rm -rf -- "$TMP" ;;
        *) echo "refusing to remove unexpected temp root: '$TMP'" >&2 ;;
    esac
}
trap cleanup EXIT

# Emoji of the question and veto headings as byte escapes, so the source stays ASCII.
QMARK=$'\xe2\x9d\x93'
VETO=$'\xe2\x9c\x8b'

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
has() { # name needle haystack
    case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing: %s\n  in:      %s\n' "$1" "$2" "$3" ;; esac
}

# Isolated environment: no real profile, no session pin, no project override.
unset CREDO_DIR CREDO_PROJECT CREDO_SESSION_ID CREDO_SESSION_PROJECTS_DIR
unset CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR CLAUDE_PLUGIN_ROOT
export HOME="$TMP/home"
mkdir -p "$HOME"

# A fresh .credo directory with the process layout; prints its path.
new_credo() { # name
    local dir="$TMP/$1/.credo"
    mkdir -p "$dir/process/requirements" "$dir/process/handoffs/archive"
    printf '%s\n' "$dir"
}

# Highest HEADED codes in the floor fixture: Q 401, T 12, V 5 (Q 382 headed below it).
# Mentions without a heading (Q390, Q900, T99, V40) never count (item #181).
fixture_floor() { # credo_dir
    printf '%s\n' "### $QMARK Q382) fixture question" 'answer Q390: option two' \
        "**$QMARK: Q4, #177** and item #903 and #904 (item ids are no codes)" \
        "see the other repo's Q900 and its T99 and V40" \
        > "$1/process/requirements/req-fixture.md"
    printf '%s\n' "### $QMARK Q401) open question" "### $VETO$VETO V5) Veto possible: x $VETO$VETO" \
        "#### 🧪 T12) a test [blocking]" "**$VETO: V5** and T12" > "$1/process/handoffs/archive/handoff-fixture.md"
}

# Tokens that must NOT count as codes: glued letters, lower case, item ids, too long.
fixture_noise() { # credo_dir
    printf '%s\n' 'xQ900 and Q900x and CT50 and q902 are no codes' \
        'Q1234567890123 and T1234567890123 are too long' 'item #903 and #904 have no letter' \
        > "$1/process/requirements/req-noise.md"
}

run_sut() { # args...  -> OUT (stdout), ERR (stderr), RC
    OUT="$("$SUT" "$@" 2>"$TMP/err.txt")"
    RC=$?
    ERR="$(cat "$TMP/err.txt")"
}

# --- 1. usage errors ----------------------------------------------------------
export CREDO_DIR="$(new_credo usage)"
run_sut
check "no args: exit 2" "2" "$RC"
check "no args: nothing on stdout" "" "$OUT"
run_sut X
check "bad type: exit 2" "2" "$RC"
run_sut q
check "lower-case type is not a type: exit 2" "2" "$RC"
run_sut Q 0
check "count 0: exit 2" "2" "$RC"
run_sut Q abc
check "count not a number: exit 2" "2" "$RC"
run_sut Q 5x
check "count with a letter: exit 2" "2" "$RC"
run_sut T 1001
check "count above the cap: exit 2" "2" "$RC"
check "usage errors create no counter file" "no" "$([ -e "$CREDO_DIR/code-counters" ] && echo yes || echo no)"

# --- 2. fresh project, no logs ------------------------------------------------
export CREDO_DIR="$(new_credo fresh)"
run_sut Q
check "fresh Q: first number is 1" "1" "$OUT"
check "fresh Q: exit 0" "0" "$RC"
check "fresh Q: no warning on stderr" "" "$ERR"
run_sut T
check "fresh T: counters are per type" "1" "$OUT"
run_sut Q 3
check "count 3: three consecutive numbers, one per line" "$(printf '2\n3\n4')" "$OUT"
check "counter file: one line per type" "$(printf 'T 1\nQ 4\nV 0')" "$(cat "$CREDO_DIR/code-counters")"
check "counter file: the lock file sits beside it" "yes" "$([ -e "$CREDO_DIR/code-counters.lock" ] && echo yes || echo no)"

# --- 3. floor from the project's own logs -------------------------------------
export CREDO_DIR="$(new_credo floor)"
fixture_floor "$CREDO_DIR"
run_sut Q
check "floor: Q continues above the highest logged Q (401)" "402" "$OUT"
has "floor: reconcile warning names the counter and the floor" "reconciled to 402" "$ERR"
run_sut Q
check "floor: second Q is 403, no warning once the counter is ahead" "403" "$OUT"
check "floor: no warning on the second call" "" "$ERR"
run_sut T
check "floor: T continues above T12 from handoffs/archive" "13" "$OUT"
run_sut V
check "floor: V continues above V5 from a veto footer" "6" "$OUT"

# --- 3b. a foreign code mentioned in the logs does not push the counter (item #181) ---
export CREDO_DIR="$(new_credo foreign)"
printf 'T 0\nQ 5\nV 1\n' > "$CREDO_DIR/code-counters"
printf '%s\n' "see the other repo's Q398 and its V3" "**$QMARK: Q398**" > "$CREDO_DIR/process/requirements/req-foreign.md"
run_sut Q
check "foreign: a mentioned Q398 of another project does not raise Q (6)" "6" "$OUT"
check "foreign: no reconcile warning" "" "$ERR"
run_sut V
check "foreign: a mentioned V3 does not raise V (2)" "2" "$OUT"

# --- 3c. a large reconcile jump warns loudly --------------------------------------
export CREDO_DIR="$(new_credo jump)"
printf 'T 0\nQ 5\nV 0\n' > "$CREDO_DIR/code-counters"
printf '%s\n' "### $QMARK Q120) own question" > "$CREDO_DIR/process/requirements/req-jump.md"
run_sut Q
check "jump: a headed Q120 still reconciles (121)" "121" "$OUT"
has "jump: a jump over 50 warns loudly" "WARNING: that is a jump of 115 numbers" "$ERR"

# --- 4. the regex ignores glued, lower-case, item-id and over-long tokens ------
export CREDO_DIR="$(new_credo noise)"
fixture_noise "$CREDO_DIR"
run_sut Q
check "noise: Q ignores xQ900, Q900x, q902 and the 13-digit token" "1" "$OUT"
check "noise: no warning for noise" "" "$ERR"
run_sut T
check "noise: T ignores CT50 and the 13-digit token" "1" "$OUT"
run_sut V
check "noise: V gets 1" "1" "$OUT"

# --- 5. counter rules: never lowered, corrupt values, missing lines -----------
export CREDO_DIR="$(new_credo rules)"
printf 'Q 382\nT 50\n' > "$CREDO_DIR/code-counters"
run_sut Q
check "rules: a stored counter with no logs continues (382 -> 383)" "383" "$OUT"
check "rules: no warning when the counter is ahead of the logs" "" "$ERR"
check "rules: the other type's line is kept" "yes" "$(grep -qx 'T 50' "$CREDO_DIR/code-counters" && echo yes || echo no)"
run_sut Q
check "rules: deleting logs cannot lower the counter (next is 384)" "384" "$OUT"
run_sut T
check "rules: T continues from its stored 50" "51" "$OUT"
printf 'Q abc\n' > "$CREDO_DIR/code-counters"
run_sut Q
check "rules: a non-numeric counter counts as 0" "1" "$OUT"
run_sut V
check "rules: a missing type line counts as 0" "1" "$OUT"

# --- 6. parallel race: 20 concurrent calls, every number once -----------------
export CREDO_DIR="$(new_credo race)"
fixture_floor "$CREDO_DIR"
RACE="$TMP/race"
mkdir -p "$RACE"
for i in $(seq 1 20); do
    "$SUT" Q > "$RACE/q$i.out" 2> "$RACE/q$i.err" &
done
wait
check "race: 20 concurrent Q calls return 402..421, each once" "$(seq 402 421)" "$(sort -n "$RACE"/q*.out)"
check "race: the counter ends at the last issued Q" "yes" "$(grep -qx 'Q 421' "$CREDO_DIR/code-counters" && echo yes || echo no)"

export CREDO_DIR="$(new_credo race-count)"
fixture_floor "$CREDO_DIR"
for i in $(seq 1 10); do
    "$SUT" T 3 > "$RACE/t$i.out" 2> "$RACE/t$i.err" &
done
wait
check "race: 10 concurrent T calls of count 3 return 13..42, each once" "$(seq 13 42)" "$(sort -n "$RACE"/t*.out)"
check "race: the counter ends at T 42" "yes" "$(grep -qx 'T 42' "$CREDO_DIR/code-counters" && echo yes || echo no)"
check "race: no temp files left behind" "0" "$(find "$CREDO_DIR" -name '*.tmp.*' | wc -l | tr -d ' ')"

# --- 7. target resolution (same resolver as credo-id-next) --------------------
unset CREDO_DIR
CWDPROJ="$TMP/cwd-project"
mkdir -p "$CWDPROJ"
fixture_floor "$(new_credo cwd-project)" >/dev/null
(cd "$CWDPROJ" && "$SUT" Q > "$TMP/cwd.out" 2> "$TMP/cwd.err")
check "cwd: a cwd project with .credo is used (floor applies, 402)" "402" "$(cat "$TMP/cwd.out")"

PINNED="$TMP/pinned-project"
mkdir -p "$PINNED"
fixture_floor "$(new_credo pinned-project)" >/dev/null
mkdir -p "$TMP/pin-profile/credo/session-projects"
printf '%s\n' "$PINNED" > "$TMP/pin-profile/credo/session-projects/sid-fixture"
CLAUDE_CONFIG_DIR="$TMP/pin-profile" CREDO_SESSION_ID=sid-fixture "$SUT" T > "$TMP/pin.out" 2> "$TMP/pin.err"
check "pin: a session pin wins over the cwd (T continues above 12)" "13" "$(cat "$TMP/pin.out")"
check "pin: the counter is in the pinned project" "yes" "$([ -e "$PINNED/.credo/code-counters" ] && echo yes || echo no)"

HUB="$TMP/hub-project"
mkdir -p "$HUB"
new_credo hub-project >/dev/null
printf 'hub: true\n' > "$HUB/.credo/config"
fixture_floor "$HUB/.credo"
printf 'open Q500\n' > "$HUB/.credo/process/requirements/req-hub.md"
(cd "$HUB" && CLAUDE_CONFIG_DIR="$TMP/hub-profile" "$SUT" Q > "$TMP/hub.out" 2> "$TMP/hub.err")
check "hub: a hub cwd falls back to the profile counter (no project floor, 1)" "1" "$(cat "$TMP/hub.out")"
has "hub: the fallback names the profile counter" "profile counter" "$(cat "$TMP/hub.err")"
check "hub: the profile counter file is created" "yes" "$([ -e "$TMP/hub-profile/credo/code-counters" ] && echo yes || echo no)"
check "hub: the project's own counter file is not touched" "no" "$([ -e "$HUB/.credo/code-counters" ] && echo yes || echo no)"

BARE="$TMP/bare"
mkdir -p "$BARE"
(cd "$BARE" && CLAUDE_CONFIG_DIR="$TMP/bare-profile" "$SUT" V > "$TMP/bare1.out" 2>/dev/null)
(cd "$BARE" && CLAUDE_CONFIG_DIR="$TMP/bare-profile" "$SUT" V > "$TMP/bare2.out" 2>/dev/null)
check "no project: fallback counter continues (1 then 2)" "$(printf '1\n2')" "$(cat "$TMP/bare1.out" "$TMP/bare2.out")"

(cd "$BARE" && env -u CLAUDE_CONFIG_DIR "$SUT" T > "$TMP/default.out" 2>/dev/null)
check "no project, no CLAUDE_CONFIG_DIR: default profile is ~/.claude (HOME set to temp)" "1" "$(cat "$TMP/default.out")"
check "no project, no CLAUDE_CONFIG_DIR: counter under the default profile" "yes" "$([ -e "$HOME/.claude/credo/code-counters" ] && echo yes || echo no)"

# --- 8. credo-id-next still works through the shared library ------------------
export CREDO_DIR="$(new_credo idnext)"
mkdir -p "$CREDO_DIR/items/1_todo/1_clarify"
printf -- '---\nid: 10\n---\n' > "$CREDO_DIR/items/1_todo/1_clarify/10-fixture-item.md"
ID_OUT="$("$ID_NEXT" 2>"$TMP/id1.err")"
check "credo-id-next: first id continues above the items floor (11)" "11" "$ID_OUT"
has "credo-id-next: reconcile warning kept" "reconciled to 11" "$(cat "$TMP/id1.err")"
ID_OUT="$("$ID_NEXT" 2>"$TMP/id2.err")"
check "credo-id-next: next id is 12" "12" "$ID_OUT"
check "credo-id-next: no warning once the counter is ahead" "" "$(cat "$TMP/id2.err")"
check "credo-id-next: counter file holds the last id" "12" "$(cat "$CREDO_DIR/id-counter")"

echo "test-credo-code-next: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
