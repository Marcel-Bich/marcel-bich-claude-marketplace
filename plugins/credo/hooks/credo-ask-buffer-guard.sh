#!/usr/bin/env bash
# credo-ask-buffer-guard.sh - PreToolUse hook on AskUserQuestion.
#
# The Ask buffer rule: when explanation text comes before an Ask call in the same turn, the
# call right before the Ask call is one separate Bash call whose ENTIRE command is `echo ok`.
# A Bash call that only ENDS in `echo ok` (bundled with other work) does not keep the text
# visible - the TUI still hides it behind the Ask dialog. This hook denies an Ask call whose
# directly preceding tool call in the same turn is such a bundled Bash call, so the session
# makes the separate `echo ok` call and asks again.
#
# Narrow on purpose: it only looks at the preceding tool call (already in the transcript at
# this point); it does not try to detect whether text precedes the Ask call. Any problem
# reading the input or the transcript lets the call through (fail-open).
set -u

INPUT=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
tpath=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || exit 0
[[ -n "$tpath" && -f "$tpath" ]] || exit 0
own_id=$(printf '%s' "$INPUT" | jq -r '.tool_use_id // ""' 2>/dev/null) || own_id=""

# the last tool_use of the current turn before this Ask call: entries after the last prompt
# that is not a tool result, tool_use blocks in order, this Ask call itself skipped
prev=$(tail -c 2097152 -- "$tpath" 2>/dev/null | jq -R -c 'fromjson? // empty' 2>/dev/null \
    | jq -s -r --arg own "$own_id" '
        ([range(0; length) as $i | select(.[$i].type == "user"
            and (.[$i].isMeta != true)
            and ((.[$i].message.content | type) == "string"
                 or ([.[$i].message.content[]? | select(.type == "tool_result")] | length == 0)))
            | $i] | last // -1) as $p
        | [.[($p + 1):][] | select(.type == "assistant") | .message.content[]?
           | select(.type == "tool_use" and .id != $own)] | last
        | if . == null then "" elif .name == "Bash" then (.input.command // "") else "" end
    ' 2>/dev/null) || exit 0

trimmed="$(printf '%s' "$prev" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
[[ -n "$trimmed" ]] || exit 0
[[ "$trimmed" == "echo ok" ]] && exit 0
# only the bundled form is denied: a Bash call that contains `echo ok` next to other work
printf '%s' "$trimmed" | grep -Eq '(^|[;&|[:space:]])echo ok([[:space:];&|]|$)' || exit 0

reason='credo Ask buffer rule: the call right before an Ask call that follows explanation text must be ONE SEPARATE Bash call whose entire command is `echo ok` - not appended to another command (the TUI still hides the text then). Make that separate `echo ok` call now, then call the Ask tool again.'
jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse",
  permissionDecision: "deny", permissionDecisionReason: $r}}'
exit 0
