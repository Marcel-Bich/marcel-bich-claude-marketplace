#!/bin/bash
# Tests for credo-go-stall.sh: the read-only listing of GO items without progress (the file
# mtime and the date of the last History line are both older than the threshold), the
# threshold from the argument, items.go_stall_hours or the fallback 24, and one line per
# stalled item in id order. Builds a throwaway credo project in a temp dir (removed on
# exit). The clock is pinned with CREDO_GO_STALL_NOW and every config layer points at a
# fixture file, so the run does not depend on the machine's clock or its own config.
# Usage: bash test-credo-go-stall.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/credo-go-stall.sh"
CFG="$SCRIPT_DIR/credo-config.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-go-stall-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
has_line() { # name output exact-line
    if printf '%s\n' "$2" | grep -Fxq -- "$3"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing line: %s\n  in:           %s\n' "$1" "$3" "$2"; fi
}
lacks() { # name needle haystack
    case "$3" in *"$2"*) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  unexpected: %s\n' "$1" "$2" ;; *) PASS=$((PASS + 1)) ;; esac
}
ids() { # output -> the ids of the listed items, one "#<id> " each
    printf '%s\n' "$1" | awk 'NF { printf "%s ", $1 }'
}

# Pinned clock: 2021-06-01 12:00 local time. The fixture dates are invented, not work dates.
NOW="$(date -d '2021-06-01 12:00' +%s)"
export CREDO_GO_STALL_NOW="$NOW"
export CREDO_GLOBAL="$TMP/global-config"     # absent unless a test writes it
export CREDO_PROFILE="$TMP/profile-config"   # absent
export CREDO_PROJECT="$TMP/project-config"   # absent
export CREDO_SKIP_ENSURE=1

export CREDO_DIR="$TMP/.credo"
I="$CREDO_DIR/items"
GO="$I/1_todo/2_go"
mkdir -p "$GO" "$I/1_todo/1_clarify" "$I/2_done"

stamp() { # file hours-ago: set the mtime to NOW minus that many hours
    touch -d "@$((NOW - $2 * 3600))" "$1"
}
mk() { # file hours-ago history-body (printf %b): an item with a Requirement and a History
    printf -- '---\nid: %s\ntitle: Fixture\n---\n\n## Requirement (verbatim)\n\n> fixture\n\n## History\n\n%b' \
        "$(basename "$1" | cut -d- -f1)" "$3" > "$1"
    stamp "$1" "$2"
}

# 1. stalled: last History line 2021-05-25 (180 h), file untouched for 240 h -> age 180 h
mk "$GO/1-go-stalled.md" 240 '- created (clarify) 2021-01-02\n- -> go 2021-05-25 (GO: "fixture", test)\n'
# 2. not stalled: the file was touched an hour ago
mk "$GO/2-go-touched.md" 1 '- -> go 2021-05-01 (GO: "fixture", test)\n'
# 3. not stalled: a History line was logged on 2021-06-01 (12 h), although the file is old
mk "$GO/3-go-logged.md" 240 '- -> go 2021-06-01 (GO: "fixture", test)\n'
# 4. stalled without a date on the last History line: judged by the mtime (240 h)
mk "$GO/4-go-undated.md" 240 '- waiting for review\n'
# 5. stalled: the commented-out line is skipped, the last real line is the dated one (180 h)
mk "$GO/5-go-comment.md" 240 '- -> go 2021-05-25 (GO: "fixture", test)\n<!--\n- -> go 2021-06-01 commented example\n-->\n'
# 6. stalled without any History section (240 h)
printf -- '---\nid: 6\ntitle: Fixture\n---\n\n## Requirement (verbatim)\n\n> fixture\n' > "$GO/6-go-no-history.md"
stamp "$GO/6-go-no-history.md" 240
# 10. stalled (240 h); sorted after 6, not after 1
mk "$GO/10-go-old.md" 240 '- created (clarify) 2021-01-02\n'
# ignored: not an item name in 2_go, and old items in the other folders
printf 'notes\n' > "$GO/notes.md"
stamp "$GO/notes.md" 240
mk "$I/2_done/20-done-old.md" 240 '- created (clarify) 2021-01-02\n'
mk "$I/1_todo/1_clarify/21-clarify-old.md" 240 '- created (clarify) 2021-01-02\n'

# --- default threshold (no argument, no config): 24 hours -------------------------
out="$("$SUT")"; rc=$?
check "default: exit" 0 "$rc"
check "default: stalled ids in id order" "#1 #4 #5 #6 #10 " "$(ids "$out")"
has_line "default: line for 1 has age and last History line" "$out" \
    '#1 age 180h last: - -> go 2021-05-25 (GO: "fixture", test)'
has_line "default: undated last line is marked" "$out" '#4 age 240h last: - waiting for review (no date)'
has_line "default: no History section" "$out" '#6 age 240h last: (no History line)'
has_line "default: commented line is skipped" "$out" \
    '#5 age 180h last: - -> go 2021-05-25 (GO: "fixture", test)'
lacks "default: the commented example is never printed" "commented" "$out"
check "default: one line per stalled item" "5" "$(printf '%s\n' "$out" | grep -c .)"

# --- the argument sets the threshold (strictly older than N hours) -----------------
out="$("$SUT" 200)"
check "arg 200: stalled ids" "#4 #6 #10 " "$(ids "$out")"
out="$("$SUT" 180)"
check "arg 180: 180 h is not older than 180 h" "#4 #6 #10 " "$(ids "$out")"
out="$("$SUT" 179)"
check "arg 179: 180 h is older than 179 h" "#1 #4 #5 #6 #10 " "$(ids "$out")"

# --- items.go_stall_hours from the config cascade -----------------------------------
printf 'items:\n  go_stall_hours: 200\n' > "$TMP/global-config"
out="$("$SUT")"
check "config 200: stalled ids" "#4 #6 #10 " "$(ids "$out")"
out="$("$SUT" 24)"
check "config 200 with arg 24: the argument wins" "#1 #4 #5 #6 #10 " "$(ids "$out")"
printf 'items:\n  go_stall_hours: soon\n' > "$TMP/global-config"
out="$("$SUT")"; rc=$?
check "config not a number: exit" 0 "$rc"
check "config not a number: falls back to 24" "#1 #4 #5 #6 #10 " "$(ids "$out")"
check "builtin default is 24" "24" "$(CREDO_GLOBAL="$TMP/absent-config" "$CFG" get items.go_stall_hours 2>/dev/null)"

# --- bad arguments -----------------------------------------------------------------
for bad in abc 0 -5 1.5; do
    "$SUT" "$bad" >/dev/null 2>&1; rc=$?
    check "bad argument '$bad': exit" 1 "$rc"
done
"$SUT" 24 48 >/dev/null 2>&1; rc=$?
check "two arguments: exit" 1 "$rc"

# --- read-only: no item file changes content or mtime -------------------------------
snap() { find "$I" -type f -printf '%p %T@ %s\n' | sort; }
before="$(snap)"
"$SUT" >/dev/null
check "read-only: items unchanged" "$before" "$(snap)"

# --- no credo project, and no 2_go folder -------------------------------------------
CREDO_DIR="$TMP/bare/.credo" "$SUT" >/dev/null 2>&1; rc=$?
check "no items directory: exit" 4 "$rc"
mkdir -p "$TMP/nogo/.credo/items/1_todo"
out="$(CREDO_DIR="$TMP/nogo/.credo" "$SUT")"; rc=$?
check "no 2_go folder: exit" 0 "$rc"
check "no 2_go folder: no output" "" "$out"

printf 'passed: %s, failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
