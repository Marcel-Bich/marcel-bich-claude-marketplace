#!/usr/bin/env bash
# credo-item-move-guard.sh - credo plugin (PreToolUse hook, matcher Bash).
#
# Purpose: force credo item status changes through credo-item-move.sh. A raw
# `mv`/`git mv` (a move), `cp` (a duplicating move) or `rm`/`git rm` (deleting the
# old copy after re-writing the file elsewhere) of an item file inside the .credo/
# status tree bypasses the helper's atomicity, no-clobber, History and entry-gate
# logic, so it is blocked here. The helper itself (credo-item-move.sh) uses none of
# these as its command word and is never blocked.
#
# Detection is deliberately narrow: the command must use mv/git mv, cp, or rm/git
# rm as a command WORD (line start, or right after && / ; / |) AND reference a path
# in the credo item status tree (items/<N>_<name>). Anything else is allowed.
#
# Known false positives (accepted): a legitimate non-move touch of an item file -
# copying one out as a backup (cp) or removing a stray temp file under an item
# folder (rm) - is also blocked. These are rare; do such things outside the agent
# or ask. The gain (closing the cp-duplicate and write-then-rm move bypasses)
# outweighs it.
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
# cwd tracks the PERSISTED Bash working directory (it follows a `cd` from a prior
# call), so a relative move like "mv 0042.md ../../2_done/" issued after a separate
# "cd .credo/items/1_todo/2_go" can be caught even though its command string carries
# no item-tree path. (An in-line "cd x && mv ..." is already caught via the cmd.)
cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || cwd=""
[ "$tool_name" = "null" ] && tool_name=""
[ "$cmd" = "null" ] && cmd=""
[ "$cwd" = "null" ] && cwd=""

# Only Bash carries a shell command line.
[ "$tool_name" = "Bash" ] || exit 0
[ -n "$cmd" ] || exit 0

# --- classify ----------------------------------------------------------------
# The helper is never a raw mv (its command word is a script path, not mv), so a
# command that invokes credo-item-move.sh is explicitly not blocked.
case "$cmd" in
    *credo-item-move.sh*) exit 0 ;;
esac

# mv/git mv, cp, or rm/git rm as a COMMAND WORD: at the start, or right after a
# && / ; / | separator (optional leading "cd ... &&|;" segments are handled by the
# same separator rule). So "cd /p && mv a b" matches, while "echo mv" does not.
# The optional "git " prefix applies to mv and rm (git mv / git rm); cp has no git
# form.
is_move_cmd() {
    printf '%s' "$1" | grep -Eq \
        '(^|&&|;|\|)[[:space:]]*((git[[:space:]]+)?(mv|rm)|cp)([[:space:]]|$)' \
        2>/dev/null
}

# A path in the credo item STATUS tree: items/ followed by a numbered status
# folder (1_todo, 2_done, 3_verified, 4_archived, and their subfolders like
# 1_clarify/2_go/3_blocked). Pattern: items/<digit>_<lowercase>. Applied to the
# command string AND to cwd: if the agent is standing INSIDE the item status tree
# (cwd matches), a relative move/cp/rm operates on item files even when the command
# line shows no item-tree path. Accepted trade-off: a move of an unrelated file
# while cwd happens to be inside the item tree is also blocked - rare, and doing it
# from that directory via the agent is unusual.
touches_item_tree() {
    printf '%s' "$1" | grep -Eq 'items/[0-9]_[a-z]' 2>/dev/null
}

if is_move_cmd "$cmd" && { touches_item_tree "$cmd" || touches_item_tree "$cwd"; }; then
    reason="Item status changes must go through credo-item-move.sh <id> <target> (status/history/atomicity). A raw mv/git mv, cp, or rm/git rm of item files in the .credo/ status tree is blocked (this includes the write-elsewhere-then-rm and cp-duplicate bypasses). For 3_verified, only on the user's explicit instruction and only by the main agent: credo-item-move.sh <id> verified --user-authorized."
    jq -n --arg r "$reason" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
    exit 0
fi

exit 0
