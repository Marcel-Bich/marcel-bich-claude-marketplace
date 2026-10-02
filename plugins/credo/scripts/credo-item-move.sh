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
#   credo-item-move.sh <id> go [--user-authorized]
#   credo-item-move.sh <id> blocked [--unblock-to clarify|go]
#   credo-item-move.sh <id> clarify [--keep-owner]
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
#   target go      -> GO gate by clarify owner (frontmatter clarify_owner: human|agent;
#                     missing or any other value = human, fail-safe). clarify_owner: agent
#                     only counts when it is provable from the History (outside HTML
#                     comments), otherwise the item is treated as human:
#                       - the last owner line this helper wrote is "clarify_owner human ->
#                         agent" (written on a GO move; this helper is the only writer of
#                         that flip), or
#                       - no owner line yet and the item was created as an agent item: a
#                         "parent: <id>" field or a "created by agent" History line.
#                     A "clarify_owner ... -> human" line (entry into 1_clarify) as the last
#                     owner line always means human.
#                     Slicing guard: an item with "parent: <id>" (and no own flip line) is
#                     agent-owned only while the parent is GO'd: parent in 2_go, 2_done,
#                     3_verified, or 3_blocked with a GO line and unblock_to other than
#                     clarify. A parent in 1_clarify, parked, archived or missing makes the
#                     child human-owned (the user has not decided the parent yet).
#                     human-owned: refused unless the item History (outside HTML comments)
#                       has a user GO line "(GO: <user quote>)" (not "(GO: agent ...)") or
#                       --user-authorized is passed (main agent, explicit user GO only).
#                       This applies from every source folder, so a detour via hold,
#                       future or 3_blocked never turns into a GO without the user.
#                     agent-owned from 1_clarify: refused unless the History has a GO line,
#                       normally "(GO: agent per SOTA rule, <reason>)".
#                     agent-owned from elsewhere: only warns when no GO line exists.
#                     After the move a human-owned item becomes clarify_owner: agent and
#                     its History gets "-> go <date> (origin: created by user; clarify_owner
#                     human -> agent)", so the original owner stays visible.
#   target clarify -> every move into 1_clarify (Named-Decision-Test send-back, emergency
#                     brake, bug found after done) sets clarify_owner: human and logs
#                     "clarify_owner <old> -> human" in the History, because the open
#                     question is the user's. --keep-owner skips that for an agent-internal
#                     re-clarify (the unblock sweep uses it for unblock_to: clarify).
#   target blocked -> refuses if the item has no blocked_by (a block needs a concrete blocker);
#                     records unblock_to: in the frontmatter (the return target the auto-unblock
#                     sweep uses) - derived from the source folder (1_clarify->clarify, 2_go->go,
#                     anything else->go), overridable with --unblock-to clarify|go.
#
# After a successful move to done OR verified, credo-unblock-sweep.sh is invoked
# (defensively, never failing the move) so items whose blockers are now delivered
# return to their unblock_to target immediately.
#
# After a successful move to done, verified or archived, merged+clean worktrees are
# cleaned up per the DOGMA-PERMISSIONS checkbox "clean up merged worktrees
# automatically" ([x] remove, [?] or missing: list candidates and ask, [ ] nothing) via
# credo-worktree-cleanup.sh - also defensive, never failing the move.
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

# Optional flags (order-free): --user-authorized (verified and go targets: the main
# agent carries out an explicit user instruction) and
# --unblock-to <clarify|go> (blocked target only, overrides the source-folder default).
FLAG=""
UNBLOCK_TO_OVERRIDE=""
KEEP_OWNER=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --user-authorized)
            FLAG="--user-authorized"
            ;;
        --keep-owner)
            KEEP_OWNER=1
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
            die "unknown option '$1' (valid: --user-authorized, --unblock-to clarify|go, --keep-owner)"
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

if [ "$KEEP_OWNER" -eq 1 ] && [ "$TARGET" != "clarify" ]; then
    die "--keep-owner only applies to target 'clarify'"
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

# --- frontmatter / History readers (used by the GO gate) ---------------------
# fm_get <file> <key>: value of <key> in the leading frontmatter block (trailing
# "# comment" and quotes stripped, lowercased), empty when absent.
fm_get() {
    awk -v key="$2" '
        NR==1 && /^---[[:space:]]*$/ {infm=1; next}
        infm==1 && /^---[[:space:]]*$/ {exit}
        infm==1 {
            line=$0
            if (match(line, "^[[:space:]]*" key ":")) {
                v=substr(line, RLENGTH+1)
                sub(/[[:space:]]+#.*$/, "", v)
                gsub(/["\047]/, "", v)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                print tolower(v); exit
            }
        }' "$1" 2>/dev/null
}
# fm_set <file> <key> <value>: replace the key line in the frontmatter, else insert it
# before the closing '---'. Atomic via a temp file; returns non-zero and leaves the
# file unchanged when the item has no frontmatter.
fm_set() {
    local f="$1" key="$2" val="$3" tmp="$1.fmset.$$"
    if awk -v key="$key" -v val="$val" '
        BEGIN{infm=0; wrote=0; seen=0}
        NR==1 && /^---[[:space:]]*$/ {print; infm=1; seen=1; next}
        infm==1 && /^---[[:space:]]*$/ {
            if (wrote==0) { print key ": " val; wrote=1 }
            print; infm=0; next
        }
        infm==1 && $0 ~ ("^[[:space:]]*" key ":") {
            if (wrote==0) { print key ": " val; wrote=1 }
            next
        }
        {print}
        END{ if (seen==0) exit 1 }
    ' "$f" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$f"
    else
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
}
# history_lines <file>: the lines of the first "## History" section, skipping HTML
# comments (the template's filled example sits in one), so a GO quoted in the
# Requirement or in a comment never counts as a GO citation.
history_lines() {
    awk '
        incom==1 { if (index($0, "-->")) incom=0; next }
        /^[[:space:]]*<!--/ { if (!index($0, "-->")) incom=1; next }
        /^##[[:space:]]+[Hh]istory/ { if (done==0) inh=1; next }
        inh==1 && /^##[[:space:]]/ { inh=0; done=1 }
        inh==1 { print }
    ' "$1" 2>/dev/null
}
# history_append <file> <line>: add <line> at the end of the History section (before
# the next heading or a trailing HTML comment), or create the section at EOF.
history_append() {
    local f="$1" line="$2" tmp="$1.hist.$$"
    if grep -Eq '^##[[:space:]]+[Hh]istory' "$f" 2>/dev/null; then
        if awk -v nl="$line" '
            function flush() { if (pend>0) for (i=1;i<=pend;i++) print buf[i]; pend=0 }
            incom==1 { print; if (index($0, "-->")) incom=0; next }
            /^##[[:space:]]+[Hh]istory/ && done==0 { print; inh=1; next }
            inh==1 && (/^##[[:space:]]/ || /^[[:space:]]*<!--/) {
                print nl; done=1; inh=0; flush()
                if (/^[[:space:]]*<!--/ && !index($0, "-->")) incom=1
                print; next
            }
            inh==1 && /^[[:space:]]*$/ { buf[++pend]=$0; next }
            inh==1 { flush(); print; next }
            /^[[:space:]]*<!--/ { print; if (!index($0, "-->")) incom=1; next }
            { print }
            END { if (inh==1 && done==0) print nl; flush() }
        ' "$f" > "$tmp" 2>/dev/null; then
            mv -f "$tmp" "$f"
        else
            rm -f "$tmp" 2>/dev/null
            return 1
        fi
    else
        printf '\n## History\n\n%s\n' "$line" >> "$f"
    fi
}

# last_owner_event <file>: target of the last owner line in the History written by
# this helper ("clarify_owner human -> agent" on GO, "clarify_owner <x> -> human" on
# entry into 1_clarify): prints agent, human, or nothing.
last_owner_event() {
    history_lines "$1" \
        | grep -Eio -- 'clarify_owner([[:space:]]+(agent|human))?[[:space:]]*->[[:space:]]*(agent|human)' \
        | tail -n1 | grep -Eio -- '(agent|human)$' | tr '[:upper:]' '[:lower:]'
}
# history_since_reset <file>: the History lines after the last "clarify_owner ... ->
# human" line (entry into 1_clarify). A GO given before the item was sent back to the
# user does not carry over: the send-back question needs a new GO.
history_since_reset() {
    history_lines "$1" | awk '
        tolower($0) ~ /clarify_owner([ \t]+(agent|human))?[ \t]*->[ \t]*human/ { n=0; next }
        { buf[++n]=$0 }
        END { for (i=1;i<=n;i++) print buf[i] }'
}
# folder_of_id <id>: status folder (relative to items/) of the item with that id, empty
# when there is no file or more than one.
folder_of_id() {
    local m n
    m="$(find "$ITEMS_DIR" -type f -name "$1-*.md" 2>/dev/null)"
    n="$(printf '%s' "$m" | grep -c . || true)"
    [ "$n" = "1" ] || return 0
    m="$(dirname "$m")"
    printf '%s' "${m#"$ITEMS_DIR"/}"
}
# parent_is_go <id>: 0 when the parent item is GO'd (2_go, 2_done, 3_verified, or
# 3_blocked with a GO line and unblock_to other than clarify), else 1.
parent_is_go() {
    local folder pf
    folder="$(folder_of_id "$1")"
    case "$folder" in
        1_todo/2_go|2_done|3_verified) return 0 ;;
        1_todo/3_blocked)
            pf="$(find "$ITEMS_DIR/1_todo/3_blocked" -type f -name "$1-*.md" 2>/dev/null | head -n1)"
            [ "$(fm_get "$pf" unblock_to)" = "clarify" ] && return 1
            history_lines "$pf" | grep -Fqi -- '(GO:' && return 0
            history_lines "$pf" | grep -Eqi -- 'clarify_owner[[:space:]]+human[[:space:]]*->[[:space:]]*agent' && return 0
            return 1
            ;;
    esac
    return 1
}
# resolve_owner <file>: sets OWNER (agent|human) and OWNER_WHY (why an agent value was
# not accepted, empty otherwise). Fail-safe: anything unprovable is human.
resolve_owner() {
    local f="$1" raw ev parent pfolder
    OWNER="human"; OWNER_WHY=""; OWNER_ORIGIN="created by user"
    raw="$(fm_get "$f" clarify_owner)"
    parent="$(fm_get "$f" parent | grep -Eo '[0-9]+' | head -n1 || true)"
    if [ -n "$parent" ] || history_lines "$f" | grep -Eqi -- 'created by agent'; then
        OWNER_ORIGIN="created by agent${parent:+, parent #$parent}"
    fi
    [ "$raw" = "agent" ] || return 0
    ev="$(last_owner_event "$f" || true)"
    case "$ev" in
        agent) OWNER="agent"; return 0 ;;
        human) OWNER_WHY="its last owner line in the History is a reset to human (entry into 1_clarify); only a GO move by this helper flips it to agent"; return 0 ;;
    esac
    if [ -n "$parent" ]; then
        if parent_is_go "$parent"; then
            OWNER="agent"
        else
            pfolder="$(folder_of_id "$parent")"
            OWNER_WHY="its parent #$parent is not GO'd (${pfolder:-not found}) - children of a parent the user has not decided are human-owned"
        fi
        return 0
    fi
    if history_lines "$f" | grep -Eqi -- 'created by agent'; then
        OWNER="agent"; return 0
    fi
    OWNER_WHY="clarify_owner: agent is not backed by a 'clarify_owner human -> agent' line from this helper, a 'parent:' field or a 'created by agent' History line (hand edit?)"
}

# --- entry-gate helpers (G1 / block-guard) -----------------------------------
# Lightweight, machine-checkable guards - NOT the full 2_go entry gate (that lives
# in the credo migrate skill and any GO sweep). They catch the two checkable cases.
OWNER_FLIP=0
case "$TARGET" in
    go)
        # GO gate by clarify owner. clarify_owner: agent marks an item an agent created
        # (slice, follow-up, build question, audit finding); anything else - missing,
        # human, or an unknown value - is treated as human-owned (fail-safe).
        resolve_owner "$SRC"
        GO_LINES="$(history_since_reset "$SRC" | grep -Fi -- '(GO:' || true)"
        USER_GO_LINES="$(printf '%s\n' "$GO_LINES" | grep -Fi -- '(GO:' | grep -Eiv -- '\(GO:[[:space:]]*agent' || true)"
        if [ "$OWNER" = "human" ]; then
            if [ -z "$USER_GO_LINES" ] && [ "$FLAG" != "--user-authorized" ]; then
                [ -z "$OWNER_WHY" ] || die "item #$ID is treated as human-owned: $OWNER_WHY. Only the USER gives its GO: add a History line with the user's own words, e.g. '- -> go <date> (GO: \"<user quote>\", <context>)', or, as the main agent on the user's explicit GO, run: credo-item-move.sh $ID go --user-authorized."
                die "item #$ID is human-owned (clarify_owner: human or missing) - only the USER gives its GO. Add a History line with the user's own words, e.g. '- -> go <date> (GO: \"<user quote>\", <context>)', or, as the main agent on the user's explicit GO, run: credo-item-move.sh $ID go --user-authorized. An agent decision '(GO: agent ...)' does not count for a human-owned item."
            fi
            OWNER_FLIP=1
        else
            case "$SRC_DIR" in
                */1_todo/1_clarify)
                    if [ -z "$GO_LINES" ] && [ "$FLAG" != "--user-authorized" ]; then
                        die "item #$ID is agent-owned but its History has no GO line. Log the decision first, e.g. '- -> go <date> (GO: agent per SOTA rule, <reason>)', and name it in the next report so the user can veto."
                    fi
                    ;;
            esac
        fi
        # G1: a move into 2_go should be backed by a provable, item-scoped GO, cited in
        # the item History, e.g.  -> go <date> (GO: "<user quote>", <context>)
        # Past the owner gate above, a missing citation (user-authorized move, or an
        # agent-owned item returning from hold/blocked) only warns, because G1 (a
        # provable GO) is then not verifiable here.
        if [ -z "$GO_LINES" ]; then
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

# --- owner flip on entry into 2_go -------------------------------------------
# Once an item is GO'd, any question that still comes up about it is very likely one
# no human was in the loop for, so it becomes agent-owned. The original owner stays
# visible in the History. A failure here only warns (the move itself is done).
if [ "$OWNER_FLIP" -eq 1 ]; then
    if fm_set "$DEST" clarify_owner agent \
        && history_append "$DEST" "- -> go $(date +%F) (origin: $OWNER_ORIGIN; clarify_owner human -> agent)"; then
        echo "credo-item-move: clarify_owner human -> agent (origin kept in History)."
    else
        echo "credo-item-move: WARNING - could not record clarify_owner: agent in $BASENAME; set it by hand." >&2
    fi
fi
# --- owner reset on entry into 1_clarify -------------------------------------
# A move into 1_clarify (Named-Decision-Test send-back, emergency brake, bug after done)
# means an open question the user decides, so the item becomes human-owned again and the
# reset is logged. --keep-owner skips it for an agent-internal re-clarify.
if [ "$TARGET" = "clarify" ]; then
    if [ "$KEEP_OWNER" -eq 1 ]; then
        echo "credo-item-move: clarify_owner kept (--keep-owner)."
    else
        PREV_OWNER="$(fm_get "$DEST" clarify_owner)"
        [ "$PREV_OWNER" = "agent" ] || PREV_OWNER="human"
        if fm_set "$DEST" clarify_owner human \
            && history_append "$DEST" "- -> clarify $(date +%F) (clarify_owner $PREV_OWNER -> human, set on entry into 1_clarify)"; then
            echo "credo-item-move: clarify_owner $PREV_OWNER -> human (entry into 1_clarify; use --keep-owner for an agent-internal re-clarify)."
        else
            echo "credo-item-move: WARNING - could not record clarify_owner: human in $BASENAME; set it by hand." >&2
        fi
    fi
fi
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

# --- worktree cleanup at item close (done/verified/archived) -------------------
# Closing an item is the moment its parallel-track worktree is finished. The dogma
# checkbox "clean up merged worktrees automatically" (### Hydra in DOGMA-PERMISSIONS.md,
# read without dogma via credo-dogma-mode.sh) decides:
#   [x]          -> remove merged+clean worktrees now (credo-worktree-cleanup.sh)
#   [?]/missing  -> list the candidates and tell the agent to ask the user first
#   [ ]          -> nothing
# Every run covers all worktrees of the repository (the first one sweeps the backlog).
# Like the unblock sweep, this never fails the move.
case "$TARGET" in
    done|verified|3_verified|archived)
        WT_REPO="$(git -C "$(dirname "$CREDO_DIR")" rev-parse --show-toplevel 2>/dev/null || true)"
        if [ -n "$WT_REPO" ] && [ -x "$SCRIPT_DIR/credo-worktree-cleanup.sh" ] \
            && [ "$(git -C "$WT_REPO" worktree list 2>/dev/null | wc -l)" -gt 1 ]; then
            WT_MODE="$("$SCRIPT_DIR/credo-dogma-mode.sh" --id 36ch Hydra 'clean up merged worktrees automatically' "$WT_REPO" 2>/dev/null || echo missing)"
            case "$WT_MODE" in
                auto)
                    "$SCRIPT_DIR/credo-worktree-cleanup.sh" "$WT_REPO" 2>&1 \
                        | grep -v '^base=' | sed 's/^/credo-item-move: worktree cleanup: /' || true
                    ;;
                deny) : ;;
                *)
                    WT_CANDIDATES="$("$SCRIPT_DIR/credo-worktree-cleanup.sh" --dry-run "$WT_REPO" 2>/dev/null | grep '^candidate ' || true)"
                    if [ -n "$WT_CANDIDATES" ]; then
                        printf '%s\n' "$WT_CANDIDATES" | sed 's/^/credo-item-move: worktree cleanup: /'
                        echo "credo-item-move: worktree cleanup is set to ask (DOGMA-PERMISSIONS [?] or no checkbox): ask the user, then run: \"$SCRIPT_DIR/credo-worktree-cleanup.sh\" \"$WT_REPO\""
                    fi
                    ;;
            esac
        fi
        ;;
esac
