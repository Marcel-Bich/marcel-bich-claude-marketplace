#!/bin/bash
# credo-id-next - issue the next deterministic, never-reused work-item id.
#
# The counter file (.credo/id-counter) holds the last issued number. Issuance
# is atomic under flock: read n (0 if empty or missing content), n = n + 1,
# write n back atomically, print n. The counter is NEVER derived from folder
# contents, so a deleted item id is never reissued.
#
# Recovery fallback (only when the counter file is entirely MISSING): scan the
# items tree for existing ids and set n = max(existing) + 1. A present-but-empty
# file counts as 0 (next id = 1) by design.
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

# --- recovery scan: highest existing id from item files ----------------------
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

if [ ! -f "$COUNTER_FILE" ]; then
    # File missing entirely -> recovery fallback.
    base="$(recover_max_id)"
else
    base="$(tr -d '[:space:]' < "$COUNTER_FILE")"
    # Empty or non-numeric content counts as 0 (per spec).
    case "$base" in
        ''|*[!0-9]*) base=0 ;;
    esac
fi

next=$((base + 1))

# Atomic write: tmp + mv -f.
tmp="$CREDO_DIR/.id-counter.tmp.$$"
printf '%s\n' "$next" > "$tmp"
mv -f "$tmp" "$COUNTER_FILE"

flock -u 9

printf '%s\n' "$next"
