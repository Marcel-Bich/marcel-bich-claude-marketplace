#!/usr/bin/env bash
# credo-code-reconcile.sh stop|prompt - keeps the typed-code counter ahead of the codes an
# agent shows in chat (item #217).
#
# stop (Stop hook): the agent's own text of the reply that just ended - every assistant text
# block after the last owner prompt in the transcript, plus last_assistant_message - goes to
# "credo-code-next.sh reconcile". That finds the code headings (### <emoji> Q12 <dot> topic,
# also T and V, also the older "Q12)" form; same heading rule as the counter's floor, lines in
# a fenced code block never count) and, under the counter's lock, raises each type to at least
# the highest code found. Owner prompts, tool results and quoted text (blockquotes start with
# ">", not "#") are never scanned. A code above the old counter was issued by hand: the hook
# then shows a short note (systemMessage) and queues the same note for the agent, which gets
# it as context with the next prompt (a Stop hook cannot add context without blocking).
# Best effort: a small per-session map code -> topic notes once when the same code shows up
# again with a different topic.
#
# prompt (UserPromptSubmit hook): hands a queued note to the agent as additionalContext.
#
# State per session in ${CREDO_CODE_TOPICS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/code-topics}:
#   <session_id>        lines "<target dir><TAB><code><TAB><topic key><TAB><topic>"
#   <session_id>.note   the queued note for the next prompt
#
# Fail open everywhere: any missing tool or error exits 0 without output; never blocks.
set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
CODE_NEXT="${CREDO_CODE_NEXT:-$HOOK_DIR/../scripts/credo-code-next.sh}"
MODE="${1:-}"
command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null || true)"

# jq costs about 20 ms per call: the session id is cut out with grep, the Stop fields come
# from one jq call.
SID="$(printf '%s' "$INPUT" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 \
    | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/')"
case "$SID" in ""|.|..|*[!A-Za-z0-9._-]*) exit 0 ;; esac
STATE_DIR="${CREDO_CODE_TOPICS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/code-topics}"
TOPICS="$STATE_DIR/$SID"
NOTE="$STATE_DIR/$SID.note"

if [ "$MODE" = "prompt" ]; then
    [ -s "$NOTE" ] || exit 0
    text="$(cat -- "$NOTE" 2>/dev/null)"
    rm -f -- "$NOTE" 2>/dev/null
    [ -n "$text" ] || exit 0
    jq -n -c --arg c "[credo] $text" \
        '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}' 2>/dev/null
    exit 0
fi
[ "$MODE" = "stop" ] || exit 0

DOT=$'\xc2\xb7'
# A cheap pre-check on raw text: anything that could be a code heading at all.
PRE_RE="[TQV][0-9]{1,12}( +${DOT}|\\))"

# reply_lines <transcript>: the assistant lines of the reply, oldest first. The transcript is
# read backwards (tac) only up to the last owner prompt - a user line that is no tool result
# and no meta line - so a long session costs no more than its last turn (capped at 20000
# lines). Only lines that could hold a code heading are kept.
reply_lines() {
    command -v tac >/dev/null 2>&1 || return 0
    tac -- "$1" 2>/dev/null | awk '
        /"type":"user"/ && !/"tool_result"/ && !/"isMeta":true/ { exit }
        /"type":"assistant"/ { keep[n++] = $0 }
        NR >= 20000 { exit }
        END { for (i = n - 1; i >= 0; i--) print keep[i] }
    ' | LC_ALL=C grep -E "$PRE_RE"
}
# TEXT_PROG: the text blocks of one assistant transcript entry.
TEXT_PROG='select(.type == "assistant") | .message.content
    | if type == "array" then .[] | select(.type? == "text") | .text
      elif type == "string" then . else empty end'

text=""
tpath=""
cwd_in=""
fields="$(printf '%s' "$INPUT" | jq -r '@sh "text=\((.last_assistant_message | strings) // "") tpath=\((.transcript_path | strings) // "") cwd_in=\((.cwd | strings) // "")"' 2>/dev/null)" || exit 0
case "$fields" in "text="*) eval "$fields" 2>/dev/null || exit 0 ;; *) exit 0 ;; esac
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
    # a line being written may be cut: jq stops there, the text before it stays
    turn="$(reply_lines "$tpath" | jq -r "$TEXT_PROG" 2>/dev/null)"
    [ -n "$turn" ] && text="$turn"$'\n'"$text"
fi
printf '%s' "$text" | LC_ALL=C grep -qE "$PRE_RE" 2>/dev/null || exit 0

[ -n "$cwd_in" ] && [ -d "$cwd_in" ] && { cd -- "$cwd_in" 2>/dev/null || true; }
out="$(printf '%s\n' "$text" | CREDO_SESSION_ID="$SID" "${BASH:-bash}" "$CODE_NEXT" reconcile 2>/dev/null)" || exit 0
[ -n "$out" ] || exit 0

target="$(printf '%s\n' "$out" | sed -n 's/^target //p' | head -n 1)"
notes=""

# Hand-issued codes: the counter was below them.
hand=""
while IFS=' ' read -r _ type _old _new codes; do
    for n in $codes; do hand="${hand:+$hand, }$type$n"; done
done < <(printf '%s\n' "$out" | grep '^raised ')
if [ -n "$hand" ]; then
    case "$hand" in
        *,*) notes="codes $hand were written without credo-code-next.sh - counter reconciled; always call it before writing a code." ;;
        *) notes="code $hand was written without credo-code-next.sh - counter reconciled; always call it before writing a code." ;;
    esac
fi

# topic_key <topic>: the comparable core of a topic - bracketed tags and the veto marks
# dropped, lower case, letters and digits only.
topic_key() {
    printf '%s' "$1" | sed -E 's/\[[^]]*\]//g' | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -cd 'a-z0-9'
}

# Reused codes (best effort): the same code of this project with a different topic in this
# session. One topic is a prefix of the other -> the same topic (a shortened or extended title).
reused=""
if mkdir -p -- "$STATE_DIR" 2>/dev/null; then
    while IFS=$'\t' read -r head topic; do
        code="${head#code }"
        code="${code/ /}"
        key="$(topic_key "$topic")"
        [ -n "$key" ] || continue
        prev="$(awk -F '\t' -v d="$target" -v c="$code" '$1 == d && $2 == c { k = $3 } END { print k }' "$TOPICS" 2>/dev/null)"
        if [ -z "$prev" ]; then
            printf '%s\t%s\t%s\t%s\n' "$target" "$code" "$key" "$topic" >> "$TOPICS" 2>/dev/null
        elif [ "$prev" != "!" ] && [ "${key#"$prev"}" = "$key" ] && [ "${prev#"$key"}" = "$prev" ]; then
            reused="${reused:+$reused, }$code"
            # "!" marks the code as reported, so the note comes once per code and session
            printf '%s\t%s\t!\t%s\n' "$target" "$code" "$topic" >> "$TOPICS" 2>/dev/null
        fi
    done < <(printf '%s\n' "$out" | grep '^code ')
fi
if [ -n "$reused" ]; then
    notes="${notes:+$notes }code $reused was shown earlier in this session with a different topic - a code is never reused; draw a new one with credo-code-next.sh."
fi

[ -n "$notes" ] || exit 0
printf '%s\n' "$notes" >> "$NOTE" 2>/dev/null
jq -n -c --arg m "credo: $notes" '{systemMessage: $m}' 2>/dev/null
exit 0
