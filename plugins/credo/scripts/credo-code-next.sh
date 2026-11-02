#!/bin/bash
# credo-code-next - issue the next typed-code number (T, Q or V), never reused.
#
# Typed codes are the numbers the owner answers: tests (T), questions (Q) and
# vetos (V). Every session of one project draws them from ONE locked counter file
# in the project's .credo directory, so two sessions can never issue the same code
# (the "Q382 twice" failure: two questions, one answer). Numbers are per type and
# monotone: none is handed out twice, and nothing resets them.
#
# Counter file <CREDO_DIR>/code-counters: one line per type, "T <n>", "Q <n>",
# "V <n>"; a missing type counts as 0. Each value is the last number given out for
# that type, like id-counter in credo-id-next. Issuance runs under an exclusive
# flock on <CREDO_DIR>/code-counters.lock (credo-counter-lib.sh): read the counters,
# base = max(counter of the type, floor of the type), write base + count back
# atomically, print base+1 .. base+count.
#
# Floor, the safety net against a counter that is behind the project's own text
# (the role the items scan has in credo-id-next). The floor is the highest code of
# the type in these files:
#   <CREDO_DIR>/process/requirements/*.md   (direct files)
#   <CREDO_DIR>/process/handoffs/**/*.md    (recursive, includes handoffs/archive/)
# A code is an ERE match of \bX[0-9]{1,12}\b with X = T, Q or V, case-sensitive.
# Both sides need a word boundary: "### <question emoji> Q382)", "Q390:" and
# "**<question emoji>: Q4, #177**" match; "xQ900", "Q900x", "CT50", "q902", a 13-digit number and item ids such as
# "#903" (no letter) do not. A quarter label such as "Q1" also matches: that only
# raises the floor and skips a number, it never repeats one. When the floor is above
# the counter, the counter is reconciled up and a warning goes to stderr.
#
# Target resolution: credo-config.sh resolve-project, the resolver credo-id-next
# uses (explicit CREDO_DIR, then session pin, then the cwd project). A hub or a cwd
# without a credo project falls back to a counter in the active profile's credo
# dir, ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/code-counters. That fallback has no
# project floor: there are no project logs to scan.
#
# stdout carries ONLY the numbers, one per line; warnings and errors go to stderr.
#
# Usage:
#   credo-code-next.sh T|Q|V [count]      issue count numbers of that type (1-1000, default 1)
#   CREDO_DIR=/path credo-code-next.sh Q  use an explicit .credo directory
#
# Exit 0 on success, 2 on a usage error, 1 on a hard error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=credo-counter-lib.sh
. "$SCRIPT_DIR/credo-counter-lib.sh"

TYPE="${1:-}"
COUNT="${2:-1}"

usage_error() {
    echo "credo-code-next: $1" >&2
    echo "usage: credo-code-next.sh T|Q|V [count]" >&2
    exit 2
}

case "$TYPE" in
    T|Q|V) ;;
    *) usage_error "type must be T, Q or V (got '$TYPE')" ;;
esac
if ! [[ "$COUNT" =~ ^[1-9][0-9]{0,3}$ ]] || [ "$COUNT" -gt 1000 ]; then
    usage_error "count must be a whole number from 1 to 1000 (got '$COUNT')"
fi

# --- locate the target (shared resolver) -------------------------------------
set +e
RESOLVED="$("$SCRIPT_DIR/credo-config.sh" resolve-project 2>/dev/null)"
RESOLVE_RC=$?
set -e

REQ_DIR=""
HANDOFF_DIR=""
if [ "$RESOLVE_RC" -eq 0 ] && [ -n "$RESOLVED" ]; then
    TARGET_DIR="$RESOLVED"
    REQ_DIR="$TARGET_DIR/process/requirements"
    HANDOFF_DIR="$TARGET_DIR/process/handoffs"
elif [ "$RESOLVE_RC" -eq 4 ]; then
    PROFILE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    TARGET_DIR="${PROFILE_DIR%/}/credo"
    echo "credo-code-next: no project target (hub or no credo project), using the profile counter in $TARGET_DIR" >&2
else
    echo "credo-code-next: could not resolve a target .credo directory" >&2
    exit 1
fi

COUNTER_FILE="$TARGET_DIR/code-counters"
LOCK_FILE="$TARGET_DIR/code-counters.lock"
mkdir -p "$TARGET_DIR"

# Stored counter of one type as a plain decimal (0 when the file or the line is
# missing or not a number).
stored_counter() {
    local type="$1" value=""
    if [ -f "$COUNTER_FILE" ]; then
        value="$(awk -v t="$type" '$1 == t { print $2; exit }' "$COUNTER_FILE")"
    fi
    case "$value" in
        ''|*[!0-9]*) printf '0' ;;
        *) printf '%d' "$((10#$value))" ;;
    esac
}

# Highest code of one type in the project's text logs (0 when there is none).
floor_of() {
    local type="$1" found=""
    found="$(
        {
            if [ -d "$REQ_DIR" ]; then
                find "$REQ_DIR" -maxdepth 1 -type f -name '*.md' -print0
            fi
            if [ -d "$HANDOFF_DIR" ]; then
                find "$HANDOFF_DIR" -type f -name '*.md' -print0
            fi
        } | xargs -0 -r grep -ohE "\\b${type}[0-9]{1,12}\\b" 2>/dev/null \
            | sed "s/^${type}//" | sort -n | tail -n 1
    )" || true
    printf '%d' "$((10#${found:-0}))"
}

# --- atomic issuance under flock ---------------------------------------------
credo_counter_lock "$LOCK_FILE"

declare -A COUNTER=()
for t in T Q V; do
    COUNTER[$t]="$(stored_counter "$t")"
done

counter="${COUNTER[$TYPE]}"
floor="$(floor_of "$TYPE")"
base="$counter"
if [ "$floor" -gt "$base" ]; then
    printf 'credo-code-next: counter (%s) for %s was behind existing codes (max %s); reconciled to %s.\n' \
        "$counter" "$TYPE" "$floor" "$((floor + 1))" >&2
    base="$floor"
fi

COUNTER[$TYPE]=$((base + COUNT))
printf 'T %s\nQ %s\nV %s\n' "${COUNTER[T]}" "${COUNTER[Q]}" "${COUNTER[V]}" | credo_counter_write "$COUNTER_FILE"

credo_counter_unlock

for ((i = 1; i <= COUNT; i++)); do
    printf '%s\n' "$((base + i))"
done
