#!/usr/bin/env bash
# credo-item-move-guard.sh - credo plugin (PreToolUse hook, matcher Bash).
#
# Purpose: force credo item status changes through credo-item-move.sh. A raw
# `mv` or `git mv` of an item file inside the .credo/ status tree bypasses the
# helper's atomicity, no-clobber, History and entry-gate logic, so it is blocked
# here. The helper itself (credo-item-move.sh) is NOT a raw mv and is never blocked.
#
# Detection is deliberately narrow: the command must use mv (or git mv) as a
# command WORD (line start, or right after && / ; / |) AND reference a path in the
# credo item status tree (items/<N>_<name>). Anything else is allowed.
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
[ "$tool_name" = "null" ] && tool_name=""
[ "$cmd" = "null" ] && cmd=""

# Only Bash carries a shell command line.
[ "$tool_name" = "Bash" ] || exit 0
[ -n "$cmd" ] || exit 0

# --- classify ----------------------------------------------------------------
# The helper is never a raw mv (its command word is a script path, not mv), so a
# command that invokes credo-item-move.sh is explicitly not blocked.
case "$cmd" in
    *credo-item-move.sh*) exit 0 ;;
esac

# mv (or git mv) as a COMMAND WORD: at the start, or right after a && / ; / |
# separator, with optional leading "cd ... &&|;" segments handled by the same
# separator rule. So "cd /p && mv a b" matches, while "echo mv" does not.
is_mv_cmd() {
    printf '%s' "$1" | grep -Eq \
        '(^|&&|;|\|)[[:space:]]*(git[[:space:]]+)?mv([[:space:]]|$)' \
        2>/dev/null
}

# A path in the credo item STATUS tree: items/ followed by a numbered status
# folder (1_todo, 2_done, 3_verified, 4_archived, and their subfolders like
# 1_clarify/2_go/3_blocked). Pattern: items/<digit>_<lowercase>.
touches_item_tree() {
    printf '%s' "$1" | grep -Eq 'items/[0-9]_[a-z]' 2>/dev/null
}

if is_mv_cmd "$cmd" && touches_item_tree "$cmd"; then
    reason="Item moves must go through credo-item-move.sh <id> <target> (status/history/atomicity). A raw mv/git mv of item files in the .credo/ status tree is blocked. For 3_verified, only on the user's explicit instruction and only by the main agent: credo-item-move.sh <id> verified --user-authorized."
    jq -n --arg r "$reason" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
    exit 0
fi

exit 0
