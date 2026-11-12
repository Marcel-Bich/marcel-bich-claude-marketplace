#!/usr/bin/env bash
# Tests for hooks/credo-ask-buffer-guard.sh (credo items #180, #182, owner decision Q398): an
# Ask call may only follow credo-code-next.sh and one separate `echo ok` in its turn; any other
# earlier tool call of the turn (also a bundled `...; echo ok`) denies it.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/credo-ask-buffer-guard.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-ask-guard.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
TR="$TMP/t.jsonl"
prompt() { jq -cn --arg t "$1" '{type: "user", message: {role: "user", content: $t}}' >> "$TR"; }
text() { jq -cn --arg t "$1" '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: $t}]}}' >> "$TR"; }
bash_call() { jq -cn --arg c "$1" '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "toolu_b", name: "Bash", input: {command: $c}}]}}' >> "$TR"
    jq -cn '{type: "user", message: {role: "user", content: [{type: "tool_result", tool_use_id: "toolu_b", content: "ok"}]}}' >> "$TR"; }
read_call() { jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "toolu_r", name: "Read", input: {file_path: "/x"}}]}}' >> "$TR"
    jq -cn '{type: "user", message: {role: "user", content: [{type: "tool_result", tool_use_id: "toolu_r", content: "x"}]}}' >> "$TR"; }
ask_written() { jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "toolu_ask", name: "AskUserQuestion", input: {}}]}}' >> "$TR"; }
decision() { # the hook's decision for an Ask call: deny or allow
    local out
    out="$(jq -n --arg tr "$TR" '{session_id: "s1", hook_event_name: "PreToolUse", tool_name: "AskUserQuestion", tool_use_id: "toolu_ask", transcript_path: $tr, tool_input: {}}' | bash "$HOOK")"
    if [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" = deny ]; then echo deny; else echo allow; fi
}
reset() { : > "$TR"; prompt "hello"; text "Here is the background."; }

reset; bash_call "echo ok"
check "a separate echo ok before the Ask passes" allow "$(decision)"
reset; bash_call "  echo ok  "
check "a separate echo ok with spaces passes" allow "$(decision)"
reset; bash_call 'C=$(ls -d x/*/ | tail -1); ${C}scripts/credo-code-next.sh Q'; bash_call "echo ok"
check "code reservation, then echo ok, then Ask passes" allow "$(decision)"
reset
check "no tool call in the turn passes" allow "$(decision)"
reset; bash_call "credo-code-next.sh Q; tspace remote ask x | grep ok; echo ok"
check "echo ok bundled with other work is denied" deny "$(decision)"
reset; bash_call "echo ok && ls"
check "echo ok followed by more work is denied" deny "$(decision)"
reset; read_call; bash_call "echo ok"
check "a Read earlier in the turn denies the Ask (text after it is only a summary)" deny "$(decision)"
reset; bash_call "git status"
check "any other Bash call earlier in the turn denies the Ask" deny "$(decision)"
reset; read_call; prompt "new owner prompt"; text "More text."
check "a tool call of an earlier turn does not count" allow "$(decision)"
reset; ask_written
check "the Ask call itself already in the transcript is skipped" allow "$(decision)"
reset; read_call; ask_written
check "a Read plus the Ask itself in the transcript still denies" deny "$(decision)"
out="$(printf 'not json' | bash "$HOOK")"
check "bad input fails open" "" "$out"

echo "ask buffer guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
