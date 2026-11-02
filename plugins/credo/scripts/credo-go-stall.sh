#!/bin/bash
# credo-go-stall - list GO items without progress for longer than N hours (read-only).
#
# A GO item in items/1_todo/2_go is stalled when BOTH its file mtime and the date of its last
# History line are older than the threshold: nothing was edited and nothing was logged for
# that long. The age printed is the shorter of the two, the time since the last sign of
# progress. A last History line without a date is judged by the mtime alone and marked
# "(no date)". A listed item still has to be classified (credo items skill, "GO stall
# classification"): buildable, Named-Decision, human-only verify only, or blocked.
#
# Usage:
#   credo-go-stall.sh [hours]
#     hours  whole hours, at least 1. Default: items.go_stall_hours from credo-config
#            (builtin 24; a value that is not a whole number falls back to 24).
#
# Output: one line per stalled item, in id order:
#   #<id> age <N>h last: <last History line>
# Nothing is printed when no GO item is stalled.
#
# The project is CREDO_DIR when set, otherwise credo-config.sh resolve-project. Exit codes:
# 0 listed (also when none is stalled), 1 bad argument, 4 no credo project resolved.
# The helper never writes. CREDO_GO_STALL_NOW (epoch seconds) pins the clock for tests only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "credo-go-stall: $*" >&2; exit 1; }

[ "$#" -le 1 ] || die "usage: credo-go-stall.sh [hours]"
if [ "$#" -eq 1 ]; then
    case "$1" in
        ''|*[!0-9]*|0) die "hours must be a whole number of at least 1, got '$1'" ;;
    esac
    HOURS="$1"
else
    HOURS="$(CREDO_SKIP_ENSURE=1 "$SCRIPT_DIR/credo-config.sh" get items.go_stall_hours 2>/dev/null)" || HOURS=""
    case "$HOURS" in
        ''|*[!0-9]*|0) HOURS=24 ;;
    esac
fi

if [ -n "${CREDO_DIR:-}" ]; then
    DIR="$CREDO_DIR"
else
    DIR="$("$SCRIPT_DIR/credo-config.sh" resolve-project 2>/dev/null)" || {
        echo "credo-go-stall: no credo project resolved (set CREDO_DIR)" >&2
        exit 4
    }
fi
[ -d "$DIR/items" ] || { echo "credo-go-stall: no items directory under $DIR" >&2; exit 4; }
GO="$DIR/items/1_todo/2_go"
[ -d "$GO" ] || exit 0

NOW="${CREDO_GO_STALL_NOW:-$(date +%s)}"
LIMIT=$((HOURS * 3600))

# mtime_of <file>: epoch seconds of the last modification (GNU stat, BSD stat as fallback)
mtime_of() {
    stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1"
}

# last_history <file>: the last non-blank line of the first History section, HTML comments
# skipped (the template's example sits in one)
last_history() {
    awk '
        incom==1 { if (index($0, "-->")) incom=0; next }
        /^[[:space:]]*<!--/ { if (!index($0, "-->")) incom=1; next }
        /^##[[:space:]]+[Hh]istory/ { if (done==0) inh=1; next }
        inh==1 && /^##[[:space:]]/ { inh=0; done=1 }
        inh==1 && NF { last=$0 }
        END { if (last != "") print last }
    ' "$1" 2>/dev/null || true
}

# history_date_of <line>: local midnight of the first YYYY-MM-DD in the line, empty if none
history_date_of() {
    local d
    d="$(printf '%s\n' "$1" | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n1 || true)"
    [ -n "$d" ] || return 0
    date -d "$d" +%s 2>/dev/null || true
}

rows=""
for f in "$GO"/[0-9]*-*.md; do
    [ -f "$f" ] || continue
    base="$(basename -- "$f")"
    id="${base%%-*}"
    case "$id" in ''|*[!0-9]*) continue ;; esac
    id="$((10#$id))"

    mt="$(mtime_of "$f" || echo "$NOW")"
    file_age=$((NOW - mt))
    line="$(last_history "$f")"
    hdate="$(history_date_of "$line")"
    hist_age="$file_age"
    shown="$line"
    if [ -z "$line" ]; then
        shown="(no History line)"
    elif [ -n "$hdate" ]; then
        hist_age=$((NOW - hdate))
    else
        shown="$line (no date)"
    fi
    [ "$file_age" -gt "$LIMIT" ] && [ "$hist_age" -gt "$LIMIT" ] || continue

    age="$file_age"
    if [ "$hist_age" -lt "$age" ]; then age="$hist_age"; fi
    if [ "${#shown}" -gt 200 ]; then shown="${shown:0:197}..."; fi
    rows="${rows}${id}"$'\t'"#$id age $((age / 3600))h last: $shown"$'\n'
done

printf '%s' "$rows" | sort -n -k1,1 | cut -f2-
