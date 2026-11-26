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
# Only a code in its own heading counts - the form in which a project issues its codes:
# a markdown heading (## to ####), its emoji (one or two), a space, then X<n> followed by
# " <middle dot>" (block format) or ")" (older form), with X = T, Q or V, e.g.
# "### <question emoji> Q382 <dot> topic" or "### <veto emoji x2> V5) Veto possible".
# A mere mention ("answer Q390:", "see the other repo's Q398", a footer "**<emoji>: Q4**")
# never counts, so a code of another project or session quoted in the logs cannot push
# this project's counter. When the floor is above the counter, the counter is reconciled
# up with a warning on stderr; a jump of more than 50 gets a louder warning.
#
# Target resolution: credo-config.sh resolve-project, the resolver credo-id-next
# uses (explicit CREDO_DIR, then session pin, then the cwd project). A hub or a cwd
# without a credo project falls back to a counter in the active profile's credo
# dir, ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/code-counters. That fallback has no
# project floor: there are no project logs to scan.
#
# stdout carries ONLY the numbers, one per line; warnings and errors go to stderr.
#
# Reconcile (item #217): a code an agent writes by hand into a chat reply, without
# drawing it here, is in no project log, so the floor cannot see it and the counter
# would hand it out again. The Stop hook credo-code-reconcile.sh pipes the agent's own
# reply text into "reconcile". It finds the code headings by the floor's heading rule
# (lines inside a fenced code block never count) and, under the same lock, raises each
# type's stored counter to at least the highest code found; it never lowers one. Its stdout:
#   target <dir>                     the resolved .credo (or profile credo) directory
#   code <X> <n><TAB><topic>         every code heading found, in reply order
#   raised <X> <old> <new> <n>...    a type whose counter was below a written code: the
#                                    old and the new counter, then the codes above old
# Without a code heading in the text it prints nothing and touches nothing.
#
# Usage:
#   credo-code-next.sh T|Q|V [count]      issue count numbers of that type (1-1000, default 1)
#   credo-code-next.sh reconcile < text   raise the counters to the codes in a reply text
#   CREDO_DIR=/path credo-code-next.sh Q  use an explicit .credo directory
#
# Exit 0 on success, 2 on a usage error, 1 on a hard error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=credo-counter-lib.sh
. "$SCRIPT_DIR/credo-counter-lib.sh"

TYPE="${1:-}"
COUNT="${2:-1}"
MODE="next"

usage_error() {
    echo "credo-code-next: $1" >&2
    echo "usage: credo-code-next.sh T|Q|V [count] | reconcile < text" >&2
    exit 2
}

DOT=$'\xc2\xb7' # U+00B7 middle dot of the block-format heading "### <emoji> Q12 <dot> topic"
# The heading rule of a code (floor and reconcile): "## " to "#### ", one or two emoji
# (no space, letter or digit), a space, X<n>, then " <dot>" (block format) or ")" (older form).
heading_re() { # allowed type letters, e.g. Q or TQV
    printf '^#{2,4} [^ [:alnum:]]{1,16} [%s][0-9]{1,12}(\\)| +%s)' "$1" "$DOT"
}

case "$TYPE" in
    T|Q|V) ;;
    reconcile)
        MODE="reconcile"
        [ "$#" -le 1 ] || usage_error "reconcile takes no further argument (the text comes on stdin)"
        ;;
    *) usage_error "type must be T, Q or V (got '$TYPE')" ;;
esac
if [ "$MODE" = "next" ] && { ! [[ "$COUNT" =~ ^[1-9][0-9]{0,3}$ ]] || [ "$COUNT" -gt 1000 ]; }; then
    usage_error "count must be a whole number from 1 to 1000 (got '$COUNT')"
fi

# Reconcile: the code headings of the reply text on stdin, outside fenced code blocks,
# as "X n<TAB>topic" lines. Read before the target is resolved: no heading, no work.
HEADINGS=""
if [ "$MODE" = "reconcile" ]; then
    HEADINGS="$(
        awk '/^[ \t]*(```|~~~)/ { fence = !fence; next } !fence' \
            | grep -E "$(heading_re TQV)" \
            | sed -E "s/^#{2,4} [^ ]+ ([TQV])([0-9]+)(\\)| +${DOT}) *(.*)\$/\\1 \\2\t\\4/"
    )" || true
    [ -n "$HEADINGS" ] || exit 0
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
        } | xargs -0 -r grep -ohE "$(heading_re "$type")" 2>/dev/null \
            | sed -E "s/.* ${type}([0-9]+)(\\)| +${DOT})\$/\\1/" | sort -n | tail -n 1
    )" || true
    printf '%d' "$((10#${found:-0}))"
}

# --- atomic issuance under flock ---------------------------------------------
credo_counter_lock "$LOCK_FILE"

declare -A COUNTER=()
for t in T Q V; do
    COUNTER[$t]="$(stored_counter "$t")"
done

if [ "$MODE" = "reconcile" ]; then
    # Raise each type to the highest code written in the reply, never lower it. The
    # floor is not applied here: the next draw applies it anyway.
    printf 'target %s\n' "$TARGET_DIR"
    raised=""
    for t in T Q V; do
        top=0
        above=""
        while IFS=' ' read -r ht hn; do
            [ "$ht" = "$t" ] || continue
            hn="$((10#${hn%%$'\t'*}))"
            [ "$hn" -gt "$top" ] && top="$hn"
            if [ "$hn" -gt "${COUNTER[$t]}" ]; then
                case " $above " in *" $hn "*) ;; *) above="${above:+$above }$hn" ;; esac
            fi
        done <<< "$HEADINGS"
        if [ "$top" -gt "${COUNTER[$t]}" ]; then
            raised="${raised}raised $t ${COUNTER[$t]} $top $above"$'\n'
            COUNTER[$t]="$top"
        fi
    done
    if [ -n "$raised" ]; then
        printf 'T %s\nQ %s\nV %s\n' "${COUNTER[T]}" "${COUNTER[Q]}" "${COUNTER[V]}" | credo_counter_write "$COUNTER_FILE"
    fi
    credo_counter_unlock
    while IFS= read -r line; do
        [ -n "$line" ] && printf 'code %s\n' "$line"
    done <<< "$HEADINGS"
    printf '%s' "$raised"
    exit 0
fi

counter="${COUNTER[$TYPE]}"
floor="$(floor_of "$TYPE")"
base="$counter"
if [ "$floor" -gt "$base" ]; then
    printf 'credo-code-next: counter (%s) for %s was behind existing codes (max %s); reconciled to %s.\n' \
        "$counter" "$TYPE" "$floor" "$((floor + 1))" >&2
    if [ $((floor - counter)) -gt 50 ]; then
        printf 'credo-code-next: WARNING: that is a jump of %s numbers - check the %s headings in .credo/process (requirements, handoffs) for a code that is not this project'"'"'s own.\n' \
            "$((floor - counter))" "$TYPE" >&2
    fi
    base="$floor"
fi

COUNTER[$TYPE]=$((base + COUNT))
printf 'T %s\nQ %s\nV %s\n' "${COUNTER[T]}" "${COUNTER[Q]}" "${COUNTER[V]}" | credo_counter_write "$COUNTER_FILE"

credo_counter_unlock

for ((i = 1; i <= COUNT; i++)); do
    printf '%s\n' "$((base + i))"
done
