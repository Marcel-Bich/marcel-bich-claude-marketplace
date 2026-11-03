#!/usr/bin/env bash
# credo-remote-mirror.sh <ask|permission|stop> - mirror real owner blockers to a sink
# (credo item #146).
#
# Observe-only hook. It forwards ONLY the events that need the owner, one JSON event per
# sink call, to the command configured as remote.mirror_command:
#   ask         PreToolUse AskUserQuestion: the Ask-box questions and their options
#   permission  PermissionRequest: a permission dialog (tool name and a short summary)
#   stop        Stop: question codes (heading "### Q-emoji Qn) topic"), test blocks
#               marked "[blocking]" (heading "### T-emoji Tn) topic [blocking]"), lines
#               "Blocker: <text>", and the reply to a message that started with
#               "[remote chat <id>]"
# The hook prints no decision, never blocks or changes a tool call, and always exits 0.
# The sink runs in the background (fire-and-forget) with a timeout and its output
# discarded; the event arrives on its stdin. Dedup state per session (sent Ask ids, Q and
# T codes, blocker texts, remote replies); a permission prompt is sent once per window.
#
# Every string of an event is masked by credo-remote-mirror-redact.jq before it is sent
# (tokens, passwords, Authorization headers, long hashes); a failing masking sends nothing.
#
# Emoji are written as jq escapes, so this source stays ASCII.
#
# Config: remote.mirror_command (default empty = off), read via scripts/credo-config.sh
# from the builtin, global and profile layers only. CREDO_PROJECT=/dev/null skips the
# project layer, as peer.trust_guard.quiet does: a repository must not be able to point
# session events at a command of its own.
#
# Env (tests and tuning): CREDO_REMOTE_MIRROR_SYNC=1 runs the sink in the foreground,
# CREDO_REMOTE_MIRROR_TIMEOUT (seconds, default 5), CREDO_REMOTE_MIRROR_PERM_WINDOW
# (seconds, default 600), CREDO_MIRROR_DIR (state root, default
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/mirror).
set -u

MODE="${1:-}"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
SCRIPTS="$HOOK_DIR/../scripts"

# mirror_maybe_on: exit 0 only when the global or the profile config file holds a non-empty
# mirror_command value. The builtin default is empty and the project layer is never read,
# so without such a line the mirror is off and the python config read is skipped (every
# permission dialog and every turn end pays for this check, not for python).
mirror_maybe_on() {
    local f pat
    pat='mirror_command:[[:space:]]*["'\'']?[^"'\''[:space:]#}]'
    f="${CREDO_GLOBAL:-$HOME/.claude/credo/config}"
    [ -f "$f" ] && grep -Eq "$pat" "$f" 2>/dev/null && return 0
    f="${CREDO_PROFILE:-}"
    [ -z "$f" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ] && f="${CLAUDE_CONFIG_DIR%/}/credo/config"
    [ -n "$f" ] && [ -f "$f" ] && grep -Eq "$pat" "$f" 2>/dev/null && return 0
    return 1
}

# mirror_command: the configured sink command, empty when off.
mirror_command() {
    [ -f "$SCRIPTS/credo-config.sh" ] || return 1
    CREDO_PROJECT=/dev/null CREDO_SKIP_ENSURE=1 bash "$SCRIPTS/credo-config.sh" \
        get remote.mirror_command 2>/dev/null
}

# valid_sid <id>: a safe, non-empty session id (no path traversal)
valid_sid() {
    case "${1:-}" in
        ""|*[!A-Za-z0-9._-]*|.|*..*) return 1 ;;
    esac
    return 0
}

state_file() {
    printf '%s/%s/sent\n' "${CREDO_MIRROR_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/mirror}" "$SID"
}

# mirror_seen <key> <window_s>: exit 0 when the key was sent (window 0 = whole session)
mirror_seen() {
    local f now
    f="$(state_file)"
    [ -f "$f" ] || return 1
    now="$(date +%s)"
    awk -F'\t' -v k="$1" -v w="$2" -v now="$now" '
        $1 == k && (w + 0 == 0 || now - $2 < w + 0) { found = 1 }
        END { exit found ? 0 : 1 }' "$f"
}

# mirror_mark <key>: remember the key; the file keeps the last 500 lines at most
mirror_mark() {
    local f n
    f="$(state_file)"
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    printf '%s\t%s\n' "$1" "$(date +%s)" >> "$f" 2>/dev/null || return 0
    n="$(wc -l < "$f" 2>/dev/null | tr -d ' ')"
    if [ "${n:-0}" -gt 500 ]; then
        tail -n 300 "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null
    fi
    return 0
}

# run_sink <command> <event json>: the event on stdin, output discarded, killed after the
# timeout. Never fails the caller.
run_sink() {
    local cmd="$1" json="$2" t="${CREDO_REMOTE_MIRROR_TIMEOUT:-5}" p w
    if command -v timeout >/dev/null 2>&1; then
        timeout "$t" bash -c "$cmd" <<<"$json" >/dev/null 2>&1
        return 0
    fi
    bash -c "$cmd" <<<"$json" >/dev/null 2>&1 &
    p=$!
    ( sleep "$t"; kill "$p" 2>/dev/null ) >/dev/null 2>&1 &
    w=$!
    wait "$p" 2>/dev/null
    kill "$w" 2>/dev/null
    return 0
}

# mirror_send <command> <event json>: background by default, so the hook returns at once
mirror_send() {
    if [ "${CREDO_REMOTE_MIRROR_SYNC:-}" = 1 ]; then
        run_sink "$1" "$2"
    else
        ( run_sink "$1" "$2" ) >/dev/null 2>&1 </dev/null &
    fi
    return 0
}

# dispatch <line>: one {key, window, event} candidate; a key sent already is skipped,
# a new key is marked, and an event (not null) is sent
dispatch() {
    local line="$1" key window ev
    key="$(printf '%s' "$line" | jq -r '.key // empty' 2>/dev/null)"
    [ -n "$key" ] || return 0
    window="$(printf '%s' "$line" | jq -r '.window // 0' 2>/dev/null)"
    mirror_seen "$key" "$window" && return 0
    mirror_mark "$key"
    # every string of the event is masked first (credo-remote-mirror-redact.jq); a failing
    # redaction prints nothing, so nothing is sent (fail-closed)
    ev="$(printf '%s' "$line" | jq -c -f "$HOOK_DIR/credo-remote-mirror-redact.jq" 2>/dev/null)"
    [ -n "$ev" ] && mirror_send "$CMD" "$ev"
    return 0
}

# ask_lines: the Ask-box event, plus a mark for every Q code in the question text
ask_lines() {
    printf '%s' "$INPUT" | jq -c --argjson base "$BASE" '
        def origin: if (.agent_id // "") == "" then {subagent: false}
                    else {subagent: true, agent_type: (.agent_type // "")} end;
        (.tool_input.questions // []) as $qs
        | ([$qs[] | (.question // "")] | join("\n")) as $all
        | (if (.tool_use_id // "") == "" then ($qs | tojson | .[0:300] | @base64)
           else .tool_use_id end) as $id
        | {key: ("ask:" + $id), window: 0,
           event: ($base + origin + {type: "ask", tool_use_id: (.tool_use_id // null),
               questions: [$qs[] | {question: (.question // ""), header: (.header // ""),
                   multiSelect: (.multiSelect // false),
                   options: [(.options // [])[] | {label: (.label // ""),
                                                   description: (.description // "")}]}]})},
          ([$all | match("\u2753 (Q[0-9]+)\\)"; "g") | .captures[0].string] | unique[]
           | {key: ., window: 0, event: null})
    ' 2>/dev/null
}

# permission_lines: one permission dialog; a file body or a command beyond 500 bytes is
# cut, and file content never leaves the hook (only the path)
permission_lines() {
    printf '%s' "$INPUT" | jq -c --argjson base "$BASE" --argjson w "$PERM_WINDOW" '
        def origin: if (.agent_id // "") == "" then {subagent: false}
                    else {subagent: true, agent_type: (.agent_type // "")} end;
        (.tool_name // "") as $tn
        | (.tool_input // {}) as $ti
        | (if $tn == "Bash" then ($ti.command // "")
           elif ($tn | test("^(Edit|MultiEdit|Write|NotebookEdit)$")) then
               ($ti.file_path // $ti.notebook_path // "")
           elif $tn == "WebFetch" then ($ti.url // "")
           else "" end | .[0:500]) as $sum
        | {key: ("perm:" + ([$tn, $sum, (.agent_id // "")] | join("|") | @base64)),
           window: $w,
           event: ($base + origin + {type: "permission", tool_name: $tn, summary: $sum})}
    ' 2>/dev/null
}

# transcript_summary <path>: the final assistant text, and the chat id of the last owner
# prompt when that prompt started with "[remote chat <id>]" and was answered after it.
# Only the tail of the transcript is read (long sessions stay cheap).
transcript_summary() {
    tail -c 4194304 -- "$1" 2>/dev/null | jq -R -s -c '
        def text_of: if type == "string" then .
                     elif type == "array" then [.[] | select(.type? == "text") | .text] | join("\n")
                     else "" end;
        def has_text: (.message.content | type) == "array"
                      and ([.message.content[] | select(.type == "text")] | length) > 0;
        def owner_prompt: .type == "user"
                          and ((.message.content | type) == "string"
                               or ((.message.content | type) == "array"
                                   and ([.message.content[] | select(.type == "tool_result")] | length == 0)));
        [split("\n")[] | fromjson?] as $e
        | ([range(0; $e | length) | select($e[.] | owner_prompt)] | last) as $p
        | ([range(0; $e | length) | select($e[.].type == "assistant" and ($e[.] | has_text))] | last) as $a
        | (if $a == null then "" else ($e[$a].message.content | text_of) end) as $text
        | (if $p == null then "" else ($e[$p].message.content | text_of) end)
        # a pasted prompt (credo-owner-type send) arrives wrapped as <pasted_content id="..">
        | sub("^\\s*<pasted_content[^>]*>\\s*"; "") as $ptext
        | (if ($ptext | test("^\\[remote chat [A-Za-z0-9._-]{1,64}\\]"))
              and $p != null and $a != null and $a > $p
           then ($ptext | capture("^\\[remote chat (?<id>[A-Za-z0-9._-]{1,64})\\]") | .id)
           else "" end) as $chat
        | {text: $text, chat: $chat,
           prompt_key: (if $p == null then "" else ($e[$p].uuid // ("line" + ($p | tostring))) end)}
    ' 2>/dev/null
}

# stop_lines <text> <chat> <prompt key>: candidates from the final reply text
stop_lines() {
    printf '%s' "$1" | jq -R -s -c --argjson base "$BASE" --arg chat "$2" --arg pkey "$3" '
        def clean: sub("[ \t\r]+$"; "");
        def noneish: ascii_downcase as $d
                     | ["", "none", "no", "keine", "nein", "-", "n/a"] | map(. == $d) | any;
        . as $text
        | split("\n") as $ls
        | ([ $ls[] | select(test("^#{2,4} \u2753 Q[0-9]+\\)"))
              | capture("^#{2,4} \u2753 (?<code>Q[0-9]+)\\)[ \t]*(?<topic>.*)$")
              | {key: .code, window: 0,
                 event: ($base + {type: "question_codes", code: .code,
                                  heading: (.topic | clean | .[0:300])})} ]
          + [ $ls[] | select(test("^#{2,4} \ud83e\uddea T[0-9]+\\)"))
              | capture("^#{2,4} \ud83e\uddea (?<code>T[0-9]+)\\)[ \t]*(?<topic>.*)$")
              | select(.topic | test("\\[blocking\\]"))
              | {key: .code, window: 0,
                 event: ($base + {type: "test_blocking", code: .code,
                                  heading: (.topic | clean | .[0:300])})} ]
          + [ $ls[] | select(test("^(> )?(\\*\\*)?Blocker(\\*\\*)?:"))
              | capture("^(> )?(\\*\\*)?Blocker(\\*\\*)?:(\\*\\*)?[ \t]*(?<text>.*)$")
              | .text | clean | select(noneish | not)
              | {key: ("blocker:" + (. | @base64)), window: 0,
                 event: ($base + {type: "blocker", text: (. | .[0:1000])})} ]
          + (if $chat == "" or ($text | length) == 0 then []
             else [{key: ("reply:" + $chat + ":" + $pkey), window: 0,
                    event: ($base + {type: "remote_reply", chat_id: $chat,
                                     text: ($text | .[0:8000])})}]
             end)
        )[]
    ' 2>/dev/null
}

# stop_events: the final reply text from last_assistant_message (else from the transcript)
stop_events() {
    local text="" tpath tsum chat="" pkey=""
    text="$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)"
    tpath="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
    if [ -n "$tpath" ] && [ -f "$tpath" ]; then
        tsum="$(transcript_summary "$tpath")"
        if [ -n "$tsum" ]; then
            [ -n "$text" ] || text="$(printf '%s' "$tsum" | jq -r '.text // empty' 2>/dev/null)"
            chat="$(printf '%s' "$tsum" | jq -r '.chat // empty' 2>/dev/null)"
            pkey="$(printf '%s' "$tsum" | jq -r '.prompt_key // empty' 2>/dev/null)"
        fi
    fi
    [ -n "$text" ] || return 0
    stop_lines "$text" "$chat" "$pkey"
}

main() {
    case "$MODE" in
        ask|permission|stop) ;;
        *) return 0 ;;
    esac
    INPUT="$(cat 2>/dev/null || true)"
    [ -n "$INPUT" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    mirror_maybe_on || return 0
    CMD="$(mirror_command)" || return 0
    [ -n "${CMD//[[:space:]]/}" ] || return 0
    SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)" || return 0
    valid_sid "$SID" || return 0
    local cwd_in
    cwd_in="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
    BASE="$(jq -n -c --arg s "$SID" --arg c "$cwd_in" \
        --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{session_id: $s, cwd: $c, ts: $t}')"
    PERM_WINDOW="${CREDO_REMOTE_MIRROR_PERM_WINDOW:-600}"
    case "$PERM_WINDOW" in
        ""|*[!0-9]*) PERM_WINDOW=600 ;;
    esac
    case "$MODE" in
        ask) ask_lines ;;
        permission) permission_lines ;;
        stop) stop_events ;;
    esac | while IFS= read -r line; do dispatch "$line"; done
    return 0
}

main
exit 0
