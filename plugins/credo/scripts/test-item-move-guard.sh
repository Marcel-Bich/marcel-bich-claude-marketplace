#!/bin/bash
# Tests for credo-item-move-guard.sh (PreToolUse hook, Bash): a raw mv, git mv, cp, rm or
# git rm is blocked only when an item file of the status tree (items/<N>_<name>) is a
# source or a destination. Moves of other .credo/ files (e.g. the requirements log) pass,
# also when the Bash working directory sits inside the item tree.
# The hook only reads its JSON payload and never touches the filesystem, so the fixture
# paths below need not exist.
# Usage: bash test-item-move-guard.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/credo-item-move-guard.sh"
ROOT="/work/project"
ITEMS_CWD="$ROOT/.credo/items/1_todo/2_go"

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}

verdict() { # tool command cwd -> prints "deny" or "allow"; a non-zero hook exit is printed as such
    local payload out rc
    payload="$(jq -n --arg t "$1" --arg c "$2" --arg d "$3" '{tool_name:$t, tool_input:{command:$c}, cwd:$d}')"
    out="$(printf '%s' "$payload" | bash "$SUT" 2>/dev/null)"; rc=$?
    [ "$rc" = 0 ] || { echo "exit-$rc"; return; }
    [ -n "$out" ] || { echo allow; return; }
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'
}
deny() { check "$1" deny "$(verdict Bash "$2" "$3")"; } # name command cwd
allow() { check "$1" allow "$(verdict Bash "$2" "$3")"; }

# --- allowed: moves that do not touch the item tree -------------------------------
allow "mv into .credo/process (relative, root cwd)" \
    "mv -f /tmp/log-tmp .credo/process/requirements/log.md" "$ROOT"
allow "mv into .credo/process (./ prefix)" \
    "mv -f ./tmp.x ./.credo/process/requirements/log.md" "$ROOT"
allow "temp write then mv into .credo/process (chained)" \
    "printf 'x' > /tmp/log-tmp && mv -f /tmp/log-tmp .credo/process/requirements/log.md" "$ROOT"
allow "mv into .credo/process, absolute destination, cwd inside item tree" \
    "mv -f /tmp/log-tmp $ROOT/.credo/process/requirements/log.md" "$ITEMS_CWD"
allow "mv into .credo/process, relative destination from item cwd" \
    "mv -f /tmp/log-tmp ../../../process/requirements/log.md" "$ITEMS_CWD"
allow "mv of unrelated absolute paths, cwd inside item tree" \
    "mv /tmp/a /tmp/b" "$ITEMS_CWD"
allow "cp of a log file out of .credo/process" \
    "cp .credo/process/requirements/log.md /tmp/backup.md" "$ROOT"
allow "cd elsewhere, then unrelated mv" \
    "cd /tmp && mv /tmp/a /tmp/b" "$ROOT"
allow "helper call alone (no raw move)" \
    "plugins/credo/scripts/credo-item-move.sh 94 done" "$ROOT"
allow "read of an item file (no move)" \
    "cat .credo/items/1_todo/2_go/94-x.md" "$ROOT"
allow "echo quoting a move (not a command word)" \
    "echo \"mv .credo/items/1_todo/2_go/94-x.md .credo/items/2_done/\"" "$ROOT"
check "non-Bash tool is ignored" allow "$(verdict Read "mv .credo/items/1_todo/2_go/94-x.md .credo/items/2_done/" "$ROOT")"

# --- blocked: raw moves of item files between status folders ----------------------
deny "item mv, relative, root cwd" \
    "mv .credo/items/1_todo/2_go/94-x.md .credo/items/2_done/" "$ROOT"
deny "item mv, ./ prefix" \
    "mv ./.credo/items/1_todo/2_go/94-x.md ./.credo/items/2_done/" "$ROOT"
deny "item mv, absolute paths" \
    "mv $ROOT/.credo/items/1_todo/2_go/94-x.md $ROOT/.credo/items/2_done/" "$ROOT"
deny "item mv, relative from item cwd (../../2_done/)" \
    "mv 94-x.md ../../2_done/" "$ITEMS_CWD"
deny "item mv, cd into item folder in the same command" \
    "cd .credo/items/1_todo/2_go && mv 94-x.md ../../2_done/" "$ROOT"
deny "item mv, several sources" \
    "mv .credo/items/1_todo/2_go/94-x.md .credo/items/1_todo/2_go/95-y.md .credo/items/2_done/" "$ROOT"
deny "item mv, -t target form" \
    "mv -t .credo/items/2_done/ .credo/items/1_todo/2_go/94-x.md" "$ROOT"
deny "item mv, -t relative target from item cwd" \
    "mv -t ../../2_done/ 94-x.md" "$ITEMS_CWD"
deny "item mv, --target-directory= form" \
    "mv --target-directory=.credo/items/2_done 94-x.md" "$ROOT"
deny "item git mv" \
    "git mv .credo/items/1_todo/2_go/94-x.md .credo/items/2_done/" "$ROOT"
deny "item rm" \
    "rm .credo/items/1_todo/2_go/94-x.md" "$ROOT"
deny "item cp out of the tree" \
    "cp .credo/items/1_todo/2_go/94-x.md /tmp/backup.md" "$ROOT"
deny "raw item mv chained after the helper call" \
    "plugins/credo/scripts/credo-item-move.sh 94 done && mv .credo/items/1_todo/2_go/94-x.md .credo/items/2_done/" "$ROOT"
deny "item mv in a subshell after cd into the item tree" \
    "(cd .credo/items/1_todo/2_go && mv 94-x.md ../../2_done/)" "$ROOT"
deny "item mv after popd, relative from item cwd" \
    "popd; mv 94-x.md ../../2_done/" "$ITEMS_CWD"
allow "cd to home, then absolute move, cwd inside item tree" \
    "cd ~ && mv /tmp/a /tmp/b" "$ITEMS_CWD"

# --- fail-safe: empty input is allowed silently -----------------------------------
out="$(printf '' | bash "$SUT" 2>&1)"; rc=$?
check "empty stdin: exit" 0 "$rc"
check "empty stdin: no output" "" "$out"

printf 'passed: %s, failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
