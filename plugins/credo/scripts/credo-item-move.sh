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
#   credo-item-move.sh <id> blocked [--unblock-to clarify|go]
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
#   target blocked -> refuses if the item has no blocked_by (a block needs a concrete blocker);
#                     records unblock_to: in the frontmatter (the return target the auto-unblock
#                     sweep uses) - derived from the source folder (1_clarify->clarify, 2_go->go,
#                     anything else->go), overridable with --unblock-to clarify|go.
#
# After a successful move to done OR verified, credo-unblock-sweep.sh is invoked
# (defensively, never failing the move) so items whose blockers are now delivered
# return to their unblock_to target immediately.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "credo-item-move: $*" >&2; exit 1; }

# --- args --------------------------------------------------------------------
[ "$#" -ge 2 ] || die "usage: credo-item-move.sh <id> <target> [--user-authorized] [--unblock-to clarify|go]  (target: clarify|go|blocked|done|verified|archived|hold|future)"
ID="$1"
TARGET="$2"
shift 2

# Optional flags (order-free): --user-authorized (verified target only) and
# --unblock-to <clarify|go> (blocked target only, overrides the source-folder default).
FLAG=""
UNBLOCK_TO_OVERRIDE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --user-authorized)
            FLAG="--user-authorized"
            ;;
        --unblock-to)
            shift
            UNBLOCK_TO_OVERRIDE="${1:-}"
            case "$UNBLOCK_TO_OVERRIDE" in
                clarify|go) : ;;
                *) die "--unblock-to takes 'clarify' or 'go', got '${UNBLOCK_TO_OVERRIDE:-<empty>}'" ;;
            esac
            ;;
        *)
            die "unknown option '$1' (valid: --user-authorized, --unblock-to clarify|go)"
            ;;
    esac
    shift
done

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

# --- locate the target .credo directory (shared resolver) --------------------
# Precedence (see credo-config.sh resolve-project): explicit CREDO_DIR > session
# pin (/credo:project) > cwd git-toplevel/.credo when it already exists and is not
# a hub. Mirrors credo-init.sh so every helper agrees. The old pin-blind
# $(pwd)/.credo fallback is gone: on a hub / no-project cwd this fails loud
# (exit 4) instead of moving items in the wrong project.
set +e
RESOLVED="$("$SCRIPT_DIR/credo-config.sh" resolve-project 2>/dev/null)"
RESOLVE_RC=$?
set -e
if [ "$RESOLVE_RC" -eq 4 ]; then
    TARGET_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    echo "credo-item-move: cwd '$TARGET_DIR' is a hub or has no credo project, and no explicit target was given. Set CREDO_DIR to the target repo, or pin it with /credo:project <path>, then retry." >&2
    exit 4
fi
if [ "$RESOLVE_RC" -ne 0 ] || [ -z "$RESOLVED" ]; then
    echo "credo-item-move: could not resolve a target .credo directory" >&2
    exit 1
fi
CREDO_DIR="$RESOLVED"

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
        # Record the return target the auto-unblock sweep uses. Derive it from the
        # source folder (where the GO'd item came from) unless --unblock-to overrides:
        #   1_clarify -> clarify, 2_go -> go, anything else -> go (the legacy default).
        if [ -n "$UNBLOCK_TO_OVERRIDE" ]; then
            UNBLOCK_TO="$UNBLOCK_TO_OVERRIDE"
        else
            case "$SRC_DIR" in
                */1_todo/1_clarify) UNBLOCK_TO="clarify" ;;
                */1_todo/2_go)      UNBLOCK_TO="go" ;;
                *)                  UNBLOCK_TO="go" ;;
            esac
        fi
        # Write unblock_to into the frontmatter (replace an existing line, else insert
        # before the closing '---'). Atomic via a temp file so a parse hiccup never
        # corrupts the item; a failure here only warns and does not abort the move.
        _fm_tmp="$SRC.unblockto.$$"
        if awk -v val="$UNBLOCK_TO" '
            BEGIN{infm=0; wrote=0; seen=0}
            NR==1 && /^---[[:space:]]*$/ {print; infm=1; seen=1; next}
            infm==1 && /^---[[:space:]]*$/ {
                if (wrote==0) { print "unblock_to: " val; wrote=1 }
                print; infm=0; next
            }
            infm==1 && /^[[:space:]]*unblock_to:/ {
                if (wrote==0) { print "unblock_to: " val; wrote=1 }
                next
            }
            {print}
            END{ if (seen==0) exit 1 }
        ' "$SRC" > "$_fm_tmp" 2>/dev/null; then
            mv -f "$_fm_tmp" "$SRC" 2>/dev/null || rm -f "$_fm_tmp" 2>/dev/null
        else
            rm -f "$_fm_tmp" 2>/dev/null
            echo "credo-item-move: WARNING - could not record unblock_to in $BASENAME (frontmatter unchanged)." >&2
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

# --- auto-unblock dependents (done/verified only) ----------------------------
# A delivery (a move into 2_done or 3_verified) can satisfy the last blocker of
# some item in 3_blocked. Run the unblock sweep (pass 1) so such dependents return
# to their unblock_to target immediately, not only at the next SessionStart. The
# sweep is fully defensive and idempotent; its failure must NEVER fail this move,
# so it is fire-and-forget with output discarded. It targets THIS tree via CREDO_DIR.
case "$TARGET" in
    done|verified|3_verified)
        if [ -x "$SCRIPT_DIR/credo-unblock-sweep.sh" ]; then
            CREDO_DIR="$CREDO_DIR" "$SCRIPT_DIR/credo-unblock-sweep.sh" "$CREDO_DIR" >/dev/null 2>&1 || true
        fi
        ;;
esac
