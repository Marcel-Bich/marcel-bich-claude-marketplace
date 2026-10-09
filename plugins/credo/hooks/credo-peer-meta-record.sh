#!/usr/bin/env bash
# credo-peer-meta-record.sh - credo plugin (SessionStart + UserPromptSubmit hook)
#
# Records a few facts about THIS session per session_id, so an orchestrating peer
# can see them in credo-peer-check.py (and, over the LAN relay, on other machines):
#   model   the hook input's "model" (SessionStart only), else the last valid
#           assistant model in the transcript tail (a line cut by the tail read is
#           skipped); an unknown value keeps the previous one
#   effort  the hook input's effort.level (low | medium | high | xhigh | max, part of
#           the common hook input); an input without it keeps the previous value
#   credo   the credo directory decision of the session cwd (accepted -> on,
#           declined -> off, none -> not recorded)
# Mode and role are not recorded here: they already live in session-modes/ and
# session-roles/ (session-mode-set.sh, role-set.sh).
#
# Record: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-meta/<session_id>.json
#         (CREDO_SESSION_META_DIR overrides the dir), written atomically and only
#         when it changed. Pruning: on SessionStart, records older than 30 days go.
# Every value is validated against the same whitelist as credo_peer_meta.py, so the
# file never holds free text. INFORMATIONAL ONLY: nothing reads it for trust,
# approval or permissions. Main thread only (a subagent call carries agent_id).
#
# Disable with CREDO_PEER_META_RECORD=0. Failure-safe: no output, always exit 0.

trap 'exit 0' ERR
case "${CREDO_PEER_META_RECORD:-1}" in
    0|false|no|off) exit 0 ;;
esac
command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$INPUT" ] || exit 0
sid="" agent="" event="" model="" effort="" tpath="" cwd=""
{
    IFS= read -r sid
    IFS= read -r agent
    IFS= read -r event
    IFS= read -r model
    IFS= read -r effort
    IFS= read -r tpath
    IFS= read -r cwd
} < <(printf '%s' "$INPUT" | jq -r '
    def s: if type == "string" then gsub("[\n\r]"; "") else "" end;
    (.session_id | s), (.agent_id | s), (.hook_event_name | s), (.model | s),
    ((.effort | if type == "object" then .level else . end) | s),
    (.transcript_path | s), (.cwd | s)' 2>/dev/null)
case "$sid" in
    ""|.|..|*..*|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
[ ${#sid} -le 128 ] || exit 0
[ -z "$agent" ] || exit 0

valid_model() {
    [ ${#1} -le 72 ] && printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}(\[[0-9]{1,4}[km]\])?$'
}

dir="${CREDO_SESSION_META_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
[ -n "${CREDO_SESSION_META_DIR:-}" ] || dir="${dir%/}/credo/session-meta"
rec="$dir/$sid.json"
old=""
[ -f "$rec" ] && [ ! -L "$rec" ] && old="$(head -c 4096 "$rec" 2>/dev/null)"

valid_model "$model" || model=""
if [ -z "$model" ] && [ -n "$tpath" ] && [ -f "$tpath" ]; then
    while IFS= read -r m; do
        valid_model "$m" && model="$m"
    done < <(tail -c 262144 "$tpath" 2>/dev/null | grep -F '"type":"assistant"' \
        | jq -rR 'fromjson? | select(type == "object" and .type == "assistant") | .message.model // empty | strings' 2>/dev/null)
fi
if [ -z "$model" ] && [ -n "$old" ]; then
    m="$(printf '%s' "$old" | jq -r '.model // empty | strings' 2>/dev/null)"
    valid_model "$m" && model="$m"
fi

case "$effort" in
    low|medium|high|xhigh|max) ;;
    *)
        effort=""
        # an input without a valid effort field keeps the last known value
        if [ -n "$old" ]; then
            e="$(printf '%s' "$old" | jq -r '.effort // empty | strings' 2>/dev/null)"
            case "$e" in low|medium|high|xhigh|max) effort="$e" ;; esac
        fi
        ;;
esac

credo=""
dec_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" 2>/dev/null && pwd)/credo-dir-decision.sh"
if [ -f "$dec_script" ]; then
    [ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"
    case "$(cd "$cwd" 2>/dev/null && bash "$dec_script" get 2>/dev/null)" in
        accepted) credo="on" ;;
        declined) credo="off" ;;
    esac
fi

new="$(jq -cn --arg m "$model" --arg e "$effort" --arg c "$credo" \
    '{model: $m, effort: $e, credo: $c} | with_entries(select(.value != ""))' 2>/dev/null)" || exit 0
[ -n "$new" ] || exit 0
if [ -n "$old" ] && [ "$(printf '%s' "$old" | jq -cS . 2>/dev/null)" = "$(printf '%s' "$new" | jq -cS . 2>/dev/null)" ]; then
    exit 0
fi
mkdir -p "$dir" 2>/dev/null || exit 0
if ! { printf '%s\n' "$new" > "$rec.tmp.$$" && mv -f "$rec.tmp.$$" "$rec"; } 2>/dev/null; then
    rm -f "$rec.tmp.$$" 2>/dev/null
fi
if [ "$event" = "SessionStart" ]; then
    find "$dir" -maxdepth 1 -type f -name '*.json' -mtime +30 -delete 2>/dev/null
fi
exit 0
