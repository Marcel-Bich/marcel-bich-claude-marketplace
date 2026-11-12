#!/usr/bin/env bash
# credo-ask-buffer-guard.sh - PreToolUse hook on AskUserQuestion (credo items #180, #182).
#
# With the current models, text that follows a tool call in the same turn reaches the owner
# only as a one-line summary ("progress update"); the original text is not stored anywhere.
# An explanation before an Ask call is therefore visible only as the FIRST text of a turn.
# Owner decision Q398: an Ask call may follow only these tool calls in its turn:
#   - a Bash call that ENDS with credo-code-next.sh T|Q|V [count] (the code for the question;
#     a setup prefix such as `C=$(ls ...);` is fine, more work after it is not), and
#   - one separate Bash call whose entire command is `echo ok` (kept in case the summary
#     behaviour goes away again).
# Any other earlier tool call in the turn (a Read, a check, an Agent, a bundled `... ; echo ok`,
# an earlier Ask) denies the Ask call: the session then ends the turn with the explanation and
# the question as text, and the owner answers "Qn: ..." in chat.
#
# The turn starts at the last prompt that is not a tool result or a skill body. Any problem
# reading the input or the transcript lets the call through (fail-open).
set -u

INPUT=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
tpath=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || exit 0
[[ -n "$tpath" && -f "$tpath" ]] || exit 0
own_id=$(printf '%s' "$INPUT" | jq -r '.tool_use_id // ""' 2>/dev/null) || own_id=""

# the first tool call of the turn that is not allowed before an Ask call, as "name: command"
bad=$(tail -c 2097152 -- "$tpath" 2>/dev/null | jq -R -c 'fromjson? // empty' 2>/dev/null \
    | jq -s -r --arg own "$own_id" '
        def norm: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
        def allowed: .name == "Bash"
            and ((.input.command // "" | norm) == "echo ok"
                 or ((.input.command // "") | test("credo-code-next\\.sh\\s+[TQV](\\s+[0-9]+)?\\s*$")));
        ([range(0; length) as $i | select(.[$i].type == "user"
            and (.[$i].isMeta != true)
            and ((.[$i].message.content | type) == "string"
                 or ([.[$i].message.content[]? | select(.type == "tool_result")] | length == 0)))
            | $i] | last // -1) as $p
        | [.[($p + 1):][] | select(.type == "assistant") | .message.content[]?
           | select(.type == "tool_use" and .id != $own) | select(allowed | not)] | first
        | if . == null then ""
          else .name + ": " + ((.input.command // .input.file_path // .input.description // "") | tostring | .[0:120])
          end
    ' 2>/dev/null) || exit 0

[[ -n "$bad" ]] || exit 0

reason="credo Ask rule (owner decision Q398): text after a tool call in the same turn reaches the owner only as a one-line summary, so an Ask call may only follow credo-code-next.sh and one separate \`echo ok\` in its turn. This turn already ran: ${bad}. Do NOT call the Ask tool now: end the turn with the explanation and the question as text (heading \"### ❓ Qn) <topic>\", code from credo-code-next.sh Q) - the owner answers \"Qn: ...\" in chat."
jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse",
  permissionDecision: "deny", permissionDecisionReason: $r}}'
exit 0
