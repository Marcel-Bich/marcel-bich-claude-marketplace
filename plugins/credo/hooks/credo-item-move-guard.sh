#!/usr/bin/env bash
# credo-item-move-guard.sh - credo plugin (PreToolUse hook, matcher Bash).
#
# Purpose: force credo item status changes through credo-item-move.sh. A raw
# `mv`/`git mv` (a move), `cp` (a duplicating move) or `rm`/`git rm` (deleting the
# old copy after re-writing the file elsewhere) of an item file inside the .credo/
# status tree bypasses the helper's atomicity, no-clobber, History and entry-gate
# logic, so it is blocked here. The helper itself (credo-item-move.sh) is a script
# call, not a raw move, and is never blocked, also not when chained with one.
#
# Detection, per command segment (the command is split at && ; | & ( ) { } and
# newlines):
#   - a segment whose command WORD is mv/git mv, cp or rm/git rm is a raw move;
#   - cd/pushd segments set the working directory for the moves after them, starting
#     from the persisted Bash cwd of the hook input; popd makes it unknown;
#   - a raw move is blocked when its text holds an item status path
#     (items/<digit>_<lowercase>), or when one of its operands, resolved lexically
#     against the working directory, lands on one. Absolute operands are used as they
#     are, so a move of a non-item file stays allowed even when the shell stands
#     inside the item tree;
#   - while the working directory is unknown (cd to a home or variable path, popd),
#     the hook cwd serves as the guess for the operands, and the whole command must
#     not touch the item tree either.
# Anything else is allowed.
#
# Known false positives (accepted): a legitimate non-move touch of an item file -
# copying one out as a backup (cp) or removing a stray temp file under an item
# folder (rm) - is blocked, and so is a move after a cd into the item tree that
# targets an unrelated file. These are rare; do such things outside the agent or
# ask. The gain (closing the cp-duplicate, write-then-rm and chained-after-helper
# bypasses) outweighs it.
#
# Scope: ALL session modes (no autonomy gate). This is a structural guard, not a
# budget/pacing guard.
#
# I/O follows the documented PreToolUse contract (hooks.md):
#   deny -> stdout JSON hookSpecificOutput{hookEventName:PreToolUse,
#           permissionDecision:"deny", permissionDecisionReason:<why>}, exit 0.
#   otherwise -> exit 0 with no output (normal permission flow).
#
# Failure-safe: ANY unexpected problem -> allow the tool (exit 0, no output). A
# guard must never break tool calls because of its own error.
#
# Security: reads only the hook stdin (tool name + command string). Never reads a
# credential/token and never prints one. No `set -x`.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

# --- read hook stdin ---------------------------------------------------------
INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

tool_name=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || tool_name=""
cmd=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null) || cmd=""
# cwd is the PERSISTED Bash working directory (it follows a `cd` from a prior call),
# the start for resolving relative move operands ("mv 0042.md ../../2_done/" issued
# after a separate "cd .credo/items/1_todo/2_go" resolves into the item tree).
cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || cwd=""
[ "$tool_name" = "null" ] && tool_name=""
[ "$cmd" = "null" ] && cmd=""
[ "$cwd" = "null" ] && cwd=""

# Only Bash carries a shell command line.
[ "$tool_name" = "Bash" ] || exit 0
[ -n "$cmd" ] || exit 0

# --- classify ----------------------------------------------------------------
# mv/git mv, cp, or rm/git rm as a COMMAND WORD (start of a segment). "echo mv" does
# not match. The optional "git " prefix applies to mv and rm; cp has no git form.
MOVE_RE='^[[:space:]]*((git[[:space:]]+)?(mv|rm)|cp)([[:space:]]|$)'
CD_RE='^[[:space:]]*(cd|pushd)([[:space:]]|$)'
POPD_RE='^[[:space:]]*popd([[:space:]]|$)'

# A path in the credo item STATUS tree: items/ followed by a numbered status folder
# (1_todo, 2_done, 3_verified, 4_archived, and their subfolders like 1_clarify/2_go).
touches_item_tree() {
    case "$1" in
        *items/[0-9]_[a-z]*) return 0 ;;
    esac
    return 1
}

# Lexical clean-up of base + path: "." and ".." are resolved, no filesystem access,
# symlinks are not followed (a symlinked .credo keeps its .credo/items/... spelling).
# Result in RESOLVED.
resolve_path() { # base path
    local part path="$2"
    local -a parts=() stack=()
    case "$path" in
        /*) ;;
        *) path="$1/$path" ;;
    esac
    IFS=/ read -r -a parts <<< "$path" || true
    for part in "${parts[@]+"${parts[@]}"}"; do
        case "$part" in
            ""|.) ;;
            ..) if [ "${#stack[@]}" -gt 0 ]; then unset 'stack[${#stack[@]}-1]'; fi ;;
            *) stack+=("$part") ;;
        esac
    done
    RESOLVED=""
    if [ "${#stack[@]}" -gt 0 ]; then
        for part in "${stack[@]}"; do RESOLVED+="/$part"; done
    fi
    RESOLVED="${RESOLVED:-/}"
}

# True when an operand of the raw move (segment $1), resolved against $2, is an item
# path. Options are skipped; "--opt=value" and "-tVALUE" operands count by their value.
operand_in_items() { # segment base
    local args w
    local -a words=()
    args="$(printf '%s' "$1" | sed -E 's/^[[:space:]]*((git[[:space:]]+)?(mv|rm)|cp)([[:space:]]|$)//')"
    read -r -a words <<< "$args" || true
    for w in "${words[@]+"${words[@]}"}"; do
        w="${w//\"/}"
        w="${w//\'/}"
        case "$w" in
            --*=*) w="${w#*=}" ;;
            -t?*) w="${w#-t}" ;;
            -*) continue ;;
        esac
        [ -n "$w" ] || continue
        resolve_path "$2" "$w"
        if touches_item_tree "$RESOLVED"; then return 0; fi
    done
    return 1
}

# cd/pushd segment: BASE becomes the directory it leads to, or "" when that cannot be
# known (home, variable or no target).
step_cd() { # segment
    local args w target=""
    local -a words=()
    args="$(printf '%s' "$1" | sed -E 's/^[[:space:]]*(cd|pushd)//')"
    read -r -a words <<< "$args" || true
    for w in "${words[@]+"${words[@]}"}"; do
        w="${w//\"/}"
        w="${w//\'/}"
        case "$w" in -*) continue ;; esac
        target="$w"
        break
    done
    case "$target" in
        ""|"~"*|"\$"*) set_unknown; return 0 ;;
    esac
    if [ -z "$BASE" ] && [ "${target#/}" = "$target" ]; then set_unknown; return 0; fi
    resolve_path "$BASE" "$target"
    BASE="$RESOLVED"
}

# The working directory cannot be followed: fall back to the hook cwd as a guess and
# let the whole command decide as well (see the main loop).
set_unknown() {
    UNKNOWN=yes
    BASE="$cwd"
}

# Segments: the command split at && ; | & ( ) { } and newlines. A failing sed falls
# back to the whole command as one segment.
segments="$(printf '%s\n' "$cmd" | sed -e 's/&&/\n/g' -e 's/[;|&(){}]/\n/g')" || segments="$cmd"

BASE="$cwd"
UNKNOWN=no
hit=no
while IFS= read -r seg; do
    if [[ $seg =~ $CD_RE ]]; then step_cd "$seg"; continue; fi
    if [[ $seg =~ $POPD_RE ]]; then set_unknown; continue; fi
    [[ $seg =~ $MOVE_RE ]] || continue
    if touches_item_tree "$seg"; then hit=yes; break; fi
    if [ -n "$BASE" ]; then
        if operand_in_items "$seg" "$BASE"; then hit=yes; break; fi
    fi
    if [ "$UNKNOWN" = yes ] && touches_item_tree "$cmd"; then hit=yes; break; fi
done <<< "$segments"

if [ "$hit" = yes ]; then
    reason="Item status changes must go through credo-item-move.sh <id> <target> (status/history/atomicity). A raw mv/git mv, cp, or rm/git rm of item files in the .credo/ status tree is blocked (this includes the write-elsewhere-then-rm and cp-duplicate bypasses). For 3_verified, only on the user's explicit instruction and only by the main agent: credo-item-move.sh <id> verified --user-authorized."
    jq -n --arg r "$reason" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
fi

exit 0
