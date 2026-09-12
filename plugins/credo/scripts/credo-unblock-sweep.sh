#!/bin/bash
# credo-unblock-sweep.sh - reconcile the 3_blocked folder against reality.
#
# Note: when CREDO_TASK_BACKEND=gsd the credo item model is inactive (GSD owns task
# tracking) and this sweep is a no-op; it applies for the default credo backend.
#
# The credo item model promises that a GO'd-but-blocked item auto-returns to its
# origin folder the moment its blockers are delivered. Nothing enforced that, so
# stale items piled up in 3_blocked long after their blockers were done. This sweep
# makes the promise deterministic. It runs two passes over 1_todo/3_blocked:
#
#   Pass 1 (auto-unblock): for each blocked item, read its blocked_by ids and look
#     up each blocker's status (the FOLDER a blocker file lives in). When ALL of an
#     item's blockers are in 2_done OR 3_verified, the block is over: move the item
#     back to its return target (frontmatter unblock_to: go|clarify; default go for
#     legacy items) and append a History line. This is NOT a new GO - the GO still
#     stands, the block merely paused it. 4_archived does NOT count as delivered.
#
#   Pass 2 (surface, no move): for the items STILL in 3_blocked after pass 1, flag
#     the ones whose blockers are not heading toward done - a blocker in 1_clarify
#     (waiting on an undecided question), a blocker in 4_archived (stranded, the
#     dependency was abandoned), or a transitive dead-end (the blocker is itself
#     blocked). This is a short nudge only; it never moves anything.
#
# Invocation:
#   credo-unblock-sweep.sh                 resolve the project via credo-config.sh
#                                          resolve-project (honors CREDO_DIR, the
#                                          session pin, else cwd/.credo).
#   credo-unblock-sweep.sh <dir>           operate on an explicit items root: either
#                                          a .credo directory (items under it) or the
#                                          items directory itself.
#   As a SessionStart hook: reads the hook JSON on stdin, takes session_id from it so
#     the pin resolves, and emits the pass-2 nudge as SessionStart.additionalContext
#     (suppressOutput), mirroring credo-session-start.sh.
#
# Defensive by design: ANY problem -> exit 0 with no output. It never crashes, never
# blocks a session or a move, is idempotent (an unblocked item leaves 3_blocked, so a
# re-run does not touch it again), and never deletes anything (moves go through
# credo-item-move.sh, which only ever mv's).

# No `set -e`/`set -u`: this must never abort a session or a move on its own error.
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."

# --- backend gate: gsd owns task tracking -> stand down ----------------------
backend="$("$SCRIPT_DIR/credo-config.sh" backend 2>/dev/null || echo credo)"
[ -n "$backend" ] || backend="credo"
[ "$backend" = "gsd" ] && exit 0

# --- arg / hook detection ----------------------------------------------------
ROOT_ARG="${1:-}"
INPUT=""
HOOK_MODE=0

# Only read stdin when no explicit root arg was given AND stdin is not a terminal
# (a SessionStart hook pipes its JSON in; a manual CLI run with an arg does not).
if [ -z "$ROOT_ARG" ] && [ ! -t 0 ]; then
    if command -v timeout >/dev/null 2>&1; then
        INPUT="$(timeout 2 cat 2>/dev/null || true)"
    else
        INPUT="$(cat 2>/dev/null || true)"
    fi
fi

if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
    sid="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")"
    [ "$sid" = "null" ] && sid=""
    case "$sid" in *[!A-Za-z0-9._-]*) sid="" ;; esac
    if [ -n "$sid" ]; then
        HOOK_MODE=1
        export CREDO_SESSION_ID="$sid"
    else
        ev="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // .hookEventName // ""' 2>/dev/null || echo "")"
        [ "$ev" = "null" ] && ev=""
        [ -n "$ev" ] && HOOK_MODE=1
    fi
fi

# --- resolve the items directory ---------------------------------------------
if [ -n "$ROOT_ARG" ]; then
    if [ -d "$ROOT_ARG/items/1_todo" ]; then
        ITEMS_DIR="$ROOT_ARG/items"
    elif [ -d "$ROOT_ARG/1_todo" ]; then
        ITEMS_DIR="$ROOT_ARG"
    elif [ -d "$ROOT_ARG/items" ]; then
        ITEMS_DIR="$ROOT_ARG/items"
    else
        ITEMS_DIR="$ROOT_ARG"
    fi
else
    rp="$("$SCRIPT_DIR/credo-config.sh" resolve-project 2>/dev/null)"
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$rp" ]; then
        exit 0
    fi
    ITEMS_DIR="$rp/items"
fi

# Normalize to absolute paths; CREDO_DIR is the parent of the items dir and is what
# credo-item-move.sh needs to target the right tree.
ITEMS_DIR="$(cd "$ITEMS_DIR" 2>/dev/null && pwd || printf '%s' "$ITEMS_DIR")"
[ -d "$ITEMS_DIR" ] || exit 0
CREDO_DIR="$(dirname "$ITEMS_DIR")"

BLOCKED_DIR="$ITEMS_DIR/1_todo/3_blocked"

# --- helpers -----------------------------------------------------------------

# Extract the YAML frontmatter block (between the first two `---` lines) of a file.
get_fm() {
    awk 'NR==1 && /^---[[:space:]]*$/ {f=1; next}
         f && /^---[[:space:]]*$/ {exit}
         f {print}' "$1" 2>/dev/null
}

# Classify a file path by its status folder.
classify_path() {
    case "$1" in
        */1_todo/1_clarify/*) echo clarify ;;
        */1_todo/2_go/*)      echo go ;;
        */1_todo/3_blocked/*) echo blocked ;;
        */2_done/*)           echo done ;;
        */3_verified/*)       echo verified ;;
        */4_archived/*)       echo archived ;;
        */parked/hold/*)      echo hold ;;
        */parked/future/*)    echo future ;;
        *)                    echo unknown ;;
    esac
}

# Status of an item by id: find <id>-*.md in the tree, map its folder. "missing" if none.
status_of() {
    local id="$1" f
    f="$(find "$ITEMS_DIR" -type f -name "${id}-*.md" 2>/dev/null | head -n1)"
    if [ -z "$f" ]; then
        echo missing
        return
    fi
    classify_path "$f"
}

# Parse blocked_by ids (inline flow list `[6, 30]` or block list `- 6`) from a file's
# frontmatter. Prints them space-separated.
blocked_by_ids() {
    get_fm "$1" | awk '
        BEGIN{inbb=0}
        {
            if ($0 ~ /^[[:space:]]*blocked_by:/) {
                v=$0; sub(/^[[:space:]]*blocked_by:[[:space:]]*/,"",v); sub(/#.*/,"",v)
                if (v ~ /\[/)       { gsub(/[^0-9]/," ",v); print v; inbb=0 }
                else if (v ~ /[0-9]/){ gsub(/[^0-9]/," ",v); print v; inbb=0 }
                else                { inbb=1 }
                next
            }
            if (inbb==1) {
                if ($0 ~ /^[[:space:]]*-[[:space:]]*[0-9]+/) { v=$0; gsub(/[^0-9]/," ",v); printf "%s ", v }
                else if ($0 ~ /^[^[:space:]#]/)             { inbb=0 }
            }
        }
    ' 2>/dev/null | tr '\n' ' ' | tr -s ' '
}

# Read the unblock_to return target from a file's frontmatter (go|clarify|empty).
unblock_to_of() {
    local v
    v="$(get_fm "$1" | sed -n 's/^[[:space:]]*unblock_to:[[:space:]]*//p' | head -n1)"
    v="${v%%#*}"
    v="$(printf '%s' "$v" | tr -d "\"' \t\r")"
    printf '%s' "$v"
}

# The item's own id: leading digits of the filename, frontmatter id as fallback.
own_id_of() {
    local base n
    base="$(basename "$1")"
    n="${base%%-*}"
    case "$n" in
        ''|*[!0-9]*)
            n="$(get_fm "$1" | sed -n 's/^[[:space:]]*id:[[:space:]]*//p' | head -n1 | tr -cd '0-9')"
            ;;
    esac
    printf '%s' "$n"
}

# Append a History line, inside the ## History section when present, else at EOF.
append_history() {
    local f="$1" line="$2" tmp
    tmp="$f.hist.$$"
    if grep -Eq '^##[[:space:]]+[Hh]istory' "$f" 2>/dev/null; then
        if awk -v nl="$line" '
            /^##[[:space:]]+[Hh]istory/ { print; inh=1; next }
            inh==1 && /^##[[:space:]]/ && done==0 { print nl; done=1; inh=0 }
            { print }
            END { if (inh==1 && done==0) print nl }
        ' "$f" > "$tmp" 2>/dev/null; then
            mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
        else
            rm -f "$tmp" 2>/dev/null
        fi
    else
        printf '\n## History\n\n%s\n' "$line" >> "$f" 2>/dev/null
    fi
}

# --- Pass 1: auto-unblock ----------------------------------------------------
moved_lines=()
remaining=()

if [ -d "$BLOCKED_DIR" ]; then
    while IFS= read -r bf; do
        [ -n "$bf" ] || continue
        ids="$(blocked_by_ids "$bf")"
        # An item with no parseable blocked_by cannot be evaluated - leave it, skip it.
        [ -n "$(printf '%s' "$ids" | tr -d ' ')" ] || continue

        all_done=1
        for id in $ids; do
            st="$(status_of "$id")"
            case "$st" in
                done|verified) : ;;
                *) all_done=0 ;;
            esac
        done

        if [ "$all_done" -eq 1 ]; then
            target="$(unblock_to_of "$bf")"
            case "$target" in go|clarify) : ;; *) target=go ;; esac
            oid="$(own_id_of "$bf")"
            case "$oid" in ''|*[!0-9]*) remaining+=("$bf"); continue ;; esac

            reason_ids=""
            for id in $ids; do reason_ids="$reason_ids #$id"; done
            reason_ids="${reason_ids# }"

            if CREDO_DIR="$CREDO_DIR" "$SCRIPT_DIR/credo-item-move.sh" "$oid" "$target" >/dev/null 2>&1; then
                nf="$(find "$ITEMS_DIR" -type f -name "${oid}-*.md" 2>/dev/null | head -n1)"
                [ -n "$nf" ] && append_history "$nf" "- -> $target $(date +%F) (auto-unblock: $reason_ids done)"
                moved_lines+=("unblocked #$oid -> $target (blockers $reason_ids done)")
            else
                # Move refused (clobber / ambiguous / guard) - leave it, surface in pass 2.
                remaining+=("$bf")
            fi
        else
            remaining+=("$bf")
        fi
    done < <(find "$BLOCKED_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null)
fi

# --- Pass 2: surface stranded blocked items ----------------------------------
surface_lines=()
if [ "${#remaining[@]}" -gt 0 ]; then
    for bf in "${remaining[@]}"; do
        oid="$(own_id_of "$bf")"
        ids="$(blocked_by_ids "$bf")"
        for id in $ids; do
            st="$(status_of "$id")"
            case "$st" in
                clarify)  surface_lines+=("#$oid blocked by #$id (blocker in clarify)") ;;
                archived) surface_lines+=("#$oid blocked by #$id (stranded: blocker archived)") ;;
                blocked)  surface_lines+=("#$oid blocked by #$id (transitive: blocker itself blocked)") ;;
                *) : ;;   # go/hold/future/done/verified/missing -> normal wait, not surfaced
            esac
        done
    done
fi

# --- output ------------------------------------------------------------------
CAP=15

if [ "$HOOK_MODE" -eq 1 ]; then
    # SessionStart: only the nudge, as additionalContext JSON. Moves already happened
    # on disk and are intentionally NOT printed (they would corrupt the JSON stdout).
    if [ "${#surface_lines[@]}" -gt 0 ] && command -v jq >/dev/null 2>&1; then
        ctx="[credo] Unblock sweep: blocked items whose blocker is not heading toward done (no auto-move - resolve the blocker or re-decide):"
        n=0
        for l in "${surface_lines[@]}"; do
            ctx="$ctx"$'\n'"- $l"
            n=$((n + 1)); [ "$n" -ge "$CAP" ] && break
        done
        jq -n --arg ctx "$ctx" \
            '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null
    fi
else
    # CLI: print what moved, then the nudge list. Silent no-op when nothing happened.
    if [ "${#moved_lines[@]}" -gt 0 ]; then
        for l in "${moved_lines[@]}"; do echo "$l"; done
    fi
    if [ "${#surface_lines[@]}" -gt 0 ]; then
        echo "stranded blocked items (no auto-move):"
        n=0
        for l in "${surface_lines[@]}"; do
            echo "- $l"
            n=$((n + 1)); [ "$n" -ge "$CAP" ] && break
        done
    fi
fi

exit 0
