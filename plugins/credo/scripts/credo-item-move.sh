#!/bin/bash
# credo-item-move - move a work item between status folders atomically.
#
# Note: when CREDO_TASK_BACKEND=gsd the credo item model is inactive (GSD owns task
# tracking) and this helper is not used; it applies for the default credo backend.
#
# The folder an item file lives in is the ONLY source of truth for its status.
# Changing status means physically moving the file. This helper does that safely:
# it locates the item by id, refuses to clobber, moves atomically with mv -f, and
# NEVER deletes anything. The user-only 3_verified target needs an explicit opt-in.
#
# Usage:
#   credo-item-move.sh <id> <target>
#   credo-item-move.sh <id> verified --user-authorized
#   CREDO_DIR=/path credo-item-move.sh <id> <target>
#   CREDO_VERIFIED_USER_AUTHORIZED=1 credo-item-move.sh <id> verified
#
# <id>     integer id of the item (matches <id>-<slug>.md and frontmatter id:).
# <target> one of:
#   clarify   -> items/1_todo/1_clarify
#   go        -> items/1_todo/2_go
#   blocked   -> items/1_todo/3_blocked
#   done      -> items/2_done
#   verified  -> items/3_verified  (human-authorized; needs --user-authorized opt-in)
#   archived  -> items/4_archived
#   hold      -> items/parked/hold
#   future    -> items/parked/future
#
# Entry-gate helpers (warn / refuse, not a full gate):
#   target go      -> warns if the item History has no GO-citation line (G1 not provable).
#   target blocked -> refuses if the item has no blocked_by (a block needs a concrete blocker).
#
# 3_verified is human-authorized: an agent NEVER moves an item there on its own
# initiative. Only the MAIN agent (direct user contact), and only on the user's
# explicit instruction, may run this with the opt-in - either the third argument
# --user-authorized or the env CREDO_VERIFIED_USER_AUTHORIZED=1. Subagents never do
# this; they report back and the main agent performs the move. Without the opt-in
# the verified target is refused.
#
# On success prints "moved #<id>: <old> -> <new>" and exits 0.
# On any error exits 1 and changes nothing.

set -euo pipefail

die() { echo "credo-item-move: $*" >&2; exit 1; }

# --- args --------------------------------------------------------------------
{ [ "$#" -ge 2 ] && [ "$#" -le 3 ]; } || die "usage: credo-item-move.sh <id> <target> [--user-authorized]  (target: clarify|go|blocked|done|verified|archived|hold|future; --user-authorized only for verified)"
ID="$1"
TARGET="$2"
FLAG="${3:-}"

if [ -n "$FLAG" ] && [ "$FLAG" != "--user-authorized" ]; then
    die "unknown option '$FLAG' (only --user-authorized is valid as third argument, and only for the verified target)"
fi

# 3_verified is human-authorized. Only an explicit opt-in unlocks it: the third
# argument --user-authorized OR the env CREDO_VERIFIED_USER_AUTHORIZED=1.
USER_AUTHORIZED=0
if [ "$FLAG" = "--user-authorized" ] || [ "${CREDO_VERIFIED_USER_AUTHORIZED:-}" = "1" ]; then
    USER_AUTHORIZED=1
fi

case "$ID" in
    ''|*[!0-9]*) die "id must be a positive integer, got '$ID'" ;;
esac
ID="$((10#$ID))"   # normalize leading zeros

# --- map target to a relative folder -----------------------------------------
case "$TARGET" in
    clarify)  REL="items/1_todo/1_clarify" ;;
    go)       REL="items/1_todo/2_go" ;;
    blocked)  REL="items/1_todo/3_blocked" ;;
    done)     REL="items/2_done" ;;
    verified|3_verified)
        if [ "$USER_AUTHORIZED" -eq 1 ]; then
            REL="items/3_verified"
        else
            die "3_verified is human-authorized. An agent never moves here on its own initiative. Only the MAIN agent, and only on the user's explicit instruction, may run: credo-item-move.sh <id> verified --user-authorized"
        fi
        ;;
    archived) REL="items/4_archived" ;;
    hold)     REL="items/parked/hold" ;;
    future)   REL="items/parked/future" ;;
    *)
        die "unknown target '$TARGET' (use: clarify|go|blocked|done|verified|archived|hold|future)" ;;
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

# --- entry-gate helpers (G1 / block-guard) -----------------------------------
# Lightweight, machine-checkable guards - NOT the full 2_go entry gate (that lives
# in the credo migrate skill and any GO sweep). They catch the two checkable cases.
case "$TARGET" in
    go)
        # G1: a move into 2_go should be backed by a provable, item-scoped GO, cited in
        # the item History, e.g.  -> go 2026-08-04 (GO: Marcel, <context>)
        # Missing it does not block the move (History may be written with the move), but
        # warn loudly because G1 (a provable GO) is then not verifiable here.
        if ! grep -Fiq -- '(GO:' "$SRC"; then
            echo "credo-item-move: WARNING - no GO-citation found in $BASENAME (looked for '(GO:')." >&2
            echo "credo-item-move: G1 (a provable, item-scoped GO) is NOT verifiable. Add a History line like" >&2
            echo "credo-item-move:   -> go <date> (GO: <who>, <context>)   with this move." >&2
        fi
        ;;
    blocked)
        # Block-guard: an item in 3_blocked MUST name a concrete blocker via blocked_by.
        # "too big / too hard / uncertain" is not a block. Refuse a blocked move with no
        # blocked_by so buildable work cannot be parked as "blocked" to dodge building it.
        if ! grep -Eiq -- '^[[:space:]]*blocked_by:.*[0-9]' "$SRC"; then
            die "target 'blocked' requires a blocked_by referencing an unfinished item (e.g. 'blocked_by: [123]'); '$BASENAME' has none. 'Too big/hard/uncertain' is not a block - build it in 2_go."
        fi
        ;;
esac

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
