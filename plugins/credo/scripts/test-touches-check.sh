#!/bin/bash
# Tests for credo-touches-check.sh. Builds a throwaway credo project in a temp
# dir (removed on exit) and checks overlap detection, unknown items, JSON
# output, and exit codes. Usage: bash test-touches-check.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/credo-touches-check.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-touches-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
contains() { # name needle haystack
    case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing: %s\n  in:      %s\n' "$1" "$2" "$3" ;; esac
}

export CREDO_DIR="$TMP/.credo"
mkdir -p "$CREDO_DIR/items/1_todo/1_clarify" "$CREDO_DIR/items/1_todo/2_go" "$CREDO_DIR/items/2_done"

item() { # id folder frontmatter-extra
    printf -- "---\nid: %s\ntitle: Item %s\ncreated: 2026-10-07\ntype: feature\nui: false\n$3---\n\nbody\n" \
        "$1" "$1" > "$CREDO_DIR/items/$2/$1-item-$1.md"
}

item 1 1_todo/2_go 'touches: [plugins/credo/scripts/a.sh, docs/x.md]\n'
item 2 1_todo/2_go 'touches:\n  - "./plugins/credo/scripts/*.sh"\n'
item 3 1_todo/2_go 'touches:\n  - README.md\n'
item 4 1_todo/1_clarify ''
item 5 2_done 'touches: [plugins/credo/]\n'
item 6 1_todo/2_go 'touches: ["src/*.md"]\n'
item 7 1_todo/2_go 'touches: ["src/*.sh"]\n'
item 8 1_todo/2_go 'heavy: true\ntouches: docs/x.md\n'
# literal directory vs a file inside it
item 9 1_todo/2_go 'touches: [plugins/credo/skills]\n'
item 10 1_todo/2_go 'touches: [plugins/credo/skills/items/SKILL.md]\n'

out="$("$SUT" 1 3)"; rc=$?
check "disjoint literals exit" 0 "$rc"
check "disjoint literals out" "ok" "$out"

out="$("$SUT" 1 2)"; rc=$?
check "literal vs glob exit" 3 "$rc"
contains "literal vs glob out" "overlap 1 2: plugins/credo/scripts/a.sh ~ plugins/credo/scripts/*.sh" "$out"

out="$("$SUT" 2 5)"; rc=$?
check "glob vs trailing-slash dir exit" 3 "$rc"

out="$("$SUT" 6 7)"; rc=$?
check "globs with disjoint suffixes exit" 0 "$rc"

out="$("$SUT" 1 8)"; rc=$?
check "scalar touches + same file exit" 3 "$rc"
contains "scalar touches out" "docs/x.md ~ docs/x.md" "$out"

out="$("$SUT" 9 10)"; rc=$?
check "dir vs file inside exit" 3 "$rc"

out="$("$SUT" 1 3 4)"; rc=$?
check "unknown does not change exit" 0 "$rc"
contains "unknown listed" "unknown 4" "$out"

out="$("$SUT" --json 1 2 4)"; rc=$?
check "json exit" 3 "$rc"
check "json parses" "ok" "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d["unknown"]==["4"] and d["overlaps"][0]["a"]=="1" and d["overlaps"][0]["b"]=="2" else d)')"

out="$("$SUT" 1 1)"; rc=$?
check "duplicate id no self-overlap" 0 "$rc"

"$SUT" >/dev/null 2>&1; check "no args exit" 1 "$?"
"$SUT" abc >/dev/null 2>&1; check "non-numeric id exit" 1 "$?"
"$SUT" 99 >/dev/null 2>&1; check "missing item exit" 1 "$?"
"$SUT" --bogus 1 >/dev/null 2>&1; check "unknown flag exit" 1 "$?"
CREDO_DIR="$TMP/nope" "$SUT" 1 >/dev/null 2>&1; check "no project exit" 4 "$?"

printf 'test-touches-check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
