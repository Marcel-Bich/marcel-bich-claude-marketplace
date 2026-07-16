#!/bin/bash
# credo-item-move - move a work item between status folders atomically.
#
# Note: when CREDO_TASK_BACKEND=gsd the credo item model is inactive (GSD owns task
# tracking) and this helper is not used; it applies for the default credo backend.
#
# The folder an item file lives in is the ONLY source of truth for its status.
# Changing status means physically moving the file. This helper does that safely:
# it locates the item by id, refuses to clobber, moves atomically with mv -f, and
# NEVER deletes anything. It also refuses the user-only 3_verified target.
#
# Usage:
#   credo-item-move.sh <id> <target>
#   CREDO_DIR=/path credo-item-move.sh <id> <target>
#
# <id>     integer id of the item (matches <id>-<slug>.md and frontmatter id:).
# <target> one of:
#   clarify   -> items/1_todo/1_clarify
#   go        -> items/1_todo/2_go
#   done      -> items/2_done
#   archived  -> items/4_archived
#   hold      -> items/parked/hold
#   future    -> items/parked/future
#
# NOT a valid target: verified (items/3_verified is USER-ONLY; an agent never
# places an item there). Move it there yourself with mv if you are the user.
#
# On success prints "moved #<id>: <old> -> <new>" and exits 0.
# On any error exits 1 and changes nothing.

set -euo pipefail

die() { echo "credo-item-move: $*" >&2; exit 1; }

# --- args --------------------------------------------------------------------
[ "$#" -eq 2 ] || die "usage: credo-item-move.sh <id> <target>  (target: clarify|go|done|archived|hold|future)"
ID="$1"
TARGET="$2"

case "$ID" in
    ''|*[!0-9]*) die "id must be a positive integer, got '$ID'" ;;
esac
ID="$((10#$ID))"   # normalize leading zeros

# --- map target to a relative folder -----------------------------------------
case "$TARGET" in
    clarify)  REL="items/1_todo/1_clarify" ;;
    go)       REL="items/1_todo/2_go" ;;
    done)     REL="items/2_done" ;;
    archived) REL="items/4_archived" ;;
    hold)     REL="items/parked/hold" ;;
    future)   REL="items/parked/future" ;;
    verified|3_verified)
        die "3_verified is USER-ONLY - an agent never moves items there. If you are the user, mv the file yourself." ;;
    *)
        die "unknown target '$TARGET' (use: clarify|go|done|archived|hold|future)" ;;
esac

# --- locate the target .credo directory --------------------------------------
if [ -n "${CREDO_DIR:-}" ]; then
    CREDO_DIR="$CREDO_DIR"
elif REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    CREDO_DIR="$REPO_ROOT/.credo"
else
    CREDO_DIR="$(pwd)/.credo"
fi

ITEMS_DIR="$CREDO_DIR/items"
[ -d "$ITEMS_DIR" ] || die "no items directory at $ITEMS_DIR (run credo-init first)"

DEST_DIR="$CREDO_DIR/$REL"

# --- find the item file (exactly one match by id) ----------------------------
matches=()
while IFS= read -r f; do
    [ -n "$f" ] && matches+=("$f")
done < <(find "$ITEMS_DIR" -type f -name "${ID}-*.md" 2>/dev/null)

case "${#matches[@]}" in
    0) die "no item file found for id #$ID (looked for ${ID}-*.md under $ITEMS_DIR)" ;;
    1) : ;;
    *) die "ambiguous: ${#matches[@]} files match id #$ID - resolve by hand: ${matches[*]}" ;;
esac

SRC="${matches[0]}"
BASENAME="$(basename "$SRC")"
DEST="$DEST_DIR/$BASENAME"

# --- guards: no-op and no-clobber --------------------------------------------
SRC_DIR="$(cd "$(dirname "$SRC")" && pwd)"
if [ "$SRC_DIR" = "$(cd "$DEST_DIR" 2>/dev/null && pwd || echo "$DEST_DIR")" ]; then
    die "item #$ID is already in $REL - nothing to do"
fi
if [ -e "$DEST" ]; then
    die "refusing to clobber existing file at $DEST"
fi

# --- atomic move (never delete) ----------------------------------------------
mkdir -p "$DEST_DIR"

# Case-only rename guard: on case-insensitive filesystems (NTFS, default APFS) a source
# and destination that differ ONLY in letter case name the SAME file. A direct mv can
# then be a no-op or silently drop the file, and an "overwrite" cleanup could rm the
# case-twin of a file we just wrote. If src and dest are the same path case-insensitively,
# move via a temp name in two steps and NEVER rm the twin.
src_lc="$(printf '%s' "$SRC" | tr '[:upper:]' '[:lower:]')"
dest_lc="$(printf '%s' "$DEST" | tr '[:upper:]' '[:lower:]')"
if [ "$src_lc" = "$dest_lc" ]; then
    tmp="$DEST_DIR/.move.tmp.$$-$BASENAME"
    mv -f "$SRC" "$tmp"
    mv -f "$tmp" "$DEST"
else
    mv -f "$SRC" "$DEST"
fi

echo "moved #$ID: ${SRC#"$CREDO_DIR"/} -> ${DEST#"$CREDO_DIR"/}"
echo "credo-item-move: remember to update the item's History section with this transition."
