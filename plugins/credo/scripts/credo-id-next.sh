#!/bin/bash
# credo-id-next - issue the next deterministic, never-reused work-item id.
#
# The counter file (.credo/id-counter) is the monotone issuing point: it holds
# the last number given out. Issuance is atomic under flock: read the counter
# (0 if empty, missing, or non-numeric), scan the items tree for the highest
# existing id, take base = max(counter, scan), write base + 1 back atomically,
# print it.
#
# The counter, not the folder, decides the number: deleting the highest item
# does NOT lower the next id, so a deleted id is never reissued. The folder scan
# is a SAFETY FLOOR, not the source of the id - it only guards against a counter
# that was rolled back or is stale relative to the items on disk (merge, clone,
# backup restore, NAS sync). Whenever the scan finds ids above the counter, the
# counter is reconciled up to them and a drift warning is printed to stderr so
# the reconciliation is visible rather than silent.
#
# stdout carries ONLY the issued id (callers parse stdout); warnings go to stderr.
#
# Usage:
#   credo-id-next.sh                 use the current git repo (or cwd)
#   CREDO_DIR=/path credo-id-next.sh use an explicit .credo directory
#
# Prints the issued id to stdout. Exit 0 on success, 1 on hard error.

set -euo pipefail

# --- locate the target .credo directory -------------------------------------
if [ -n "${CREDO_DIR:-}" ]; then
    CREDO_DIR="$CREDO_DIR"
elif REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    CREDO_DIR="$REPO_ROOT/.credo"
else
    CREDO_DIR="$(pwd)/.credo"
fi

COUNTER_FILE="$CREDO_DIR/id-counter"
LOCK_FILE="$CREDO_DIR/id-counter.lock"
ITEMS_DIR="$CREDO_DIR/items"

mkdir -p "$CREDO_DIR"

# --- scan floor: highest existing id from item files -------------------------
# Looks at filenames like 124-slug.md and any "id: 124" frontmatter line.
recover_max_id() {
    local max=0 id
    if [ -d "$ITEMS_DIR" ]; then
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            if [ "$id" -gt "$max" ] 2>/dev/null; then
                max="$id"
            fi
        done < <(
            {
                # ids from filenames: leading digits before a dash
                find "$ITEMS_DIR" -type f -name '*.md' 2>/dev/null \
                    | sed -n 's#.*/\([0-9][0-9]*\)-.*#\1#p'
                # ids from frontmatter "id: N"
                grep -rhoE '^id:[[:space:]]*[0-9]+' "$ITEMS_DIR" 2>/dev/null \
                    | grep -oE '[0-9]+'
            } | sed 's/^0*\([0-9]\)/\1/'
        )
    fi
    printf '%s' "$max"
}

# --- atomic issuance under flock --------------------------------------------
exec 9>"$LOCK_FILE"
flock 9

# Read the counter (missing, empty, or non-numeric all count as 0).
counter=0
if [ -f "$COUNTER_FILE" ]; then
    counter="$(tr -d '[:space:]' < "$COUNTER_FILE")"
    case "$counter" in
        ''|*[!0-9]*) counter=0 ;;
    esac
fi

# Always scan the items tree so a stale/rolled-back counter cannot reissue an id.
scan="$(recover_max_id)"

# base = max(counter, scan). The counter still governs monotonicity (never-reuse);
# the scan only lifts a counter that fell behind the items on disk.
base="$counter"
if [ "$scan" -gt "$base" ]; then
    base="$scan"
    printf 'credo-id-next: counter (%s) was behind existing ids (max %s); reconciled to %s.\n' \
        "$counter" "$scan" "$((base + 1))" >&2
fi

next=$((base + 1))

# Atomic write: tmp + mv -f.
tmp="$CREDO_DIR/.id-counter.tmp.$$"
printf '%s\n' "$next" > "$tmp"
mv -f "$tmp" "$COUNTER_FILE"

flock -u 9

printf '%s\n' "$next"
