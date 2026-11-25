#!/usr/bin/env bash
# lib-notify.sh - dogma plugin: detect a REPEAT subagent notification prompt (#215).
#
# A finished subagent that left background work of its own running is woken again each
# time that work ends; every wake ends with another <task-notification> for the same
# task-id and starts a new main-agent turn. Each such turn used to carry the full
# UserPromptSubmit bundle. On a REPEAT notification the dogma UserPromptSubmit hooks
# (subagent-suggestion.sh, user-prompt-submit.sh, prompt-intervention-reminder.sh,
# checklist-tracking.sh) emit nothing. Self-contained: no dependency on credo.
#
# Slim only when ALL of this holds:
#   - the prompt consists only of harness notification blocks: <task-notification> blocks,
#     optional <system-reminder> wrappers, the fixed "[SYSTEM NOTIFICATION - NOT USER
#     INPUT]" paragraph and <total_tokens>; no other text (an owner prompt, a peer
#     <cross-session-message>, a reminder or any own text keeps the full bundle);
#   - every block reports a subagent (<summary>Agent "..."); Monitor events and background
#     shell completions keep the full bundle;
#   - every task-id in it was already notified in an EARLIER prompt of this session.
# The first notification of a task-id records it and keeps the full bundle.
#
# State: one small file per session, ${DOGMA_NOTIFY_SEEN_DIR:-<config>/dogma/notify-seen}/
# <session_id>, lines "<task-id> <prompt checksum> <epoch>". The hooks of one prompt run in
# parallel and all call dogma_notify_repeat: an entry with the SAME prompt checksum written
# in the last 60 s counts as this very prompt, so they all reach the same answer. Capped at
# 400 lines (the newest 200 are kept).
#
# Usage:
#   . lib-notify.sh
#   dogma_notify_repeat "$prompt" "$session_id" && <slim path>
# Fail open: anything unclear (no session id, unreadable state, odd format) is "not a
# repeat", so the full bundle is kept.

# dogma_notify_agent_ids PROMPT - prints the task-ids (one per line) when PROMPT consists
# only of notification blocks that all report a subagent; returns 1 otherwise.
dogma_notify_agent_ids() {
    local s="$1" rest block id ids="" line
    case "$s" in *"<task-notification>"*) ;; *) return 1 ;; esac
    while [[ "$s" == *"<task-notification>"* ]]; do
        rest="${s#*"<task-notification>"}"
        [[ "$rest" == *"</task-notification>"* ]] || return 1
        block="${rest%%"</task-notification>"*}"
        s="${s%%"<task-notification>"*}"$'\n'"${rest#*"</task-notification>"}"
        [[ "$block" == *'<summary>Agent "'* ]] || return 1
        [[ "$block" == *"<task-id>"*"</task-id>"* ]] || return 1
        id="${block#*<task-id>}"
        id="${id%%</task-id>*}"
        [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || return 1
        ids+="$id"$'\n'
    done
    while [[ "$s" == *"<total_tokens>"*"</total_tokens>"* ]]; do
        s="${s%%"<total_tokens>"*}${s#*"</total_tokens>"}"
    done
    s="${s//<system-reminder>/}"
    s="${s//<\/system-reminder>/}"
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
            "" | "[SYSTEM NOTIFICATION - NOT USER INPUT]"* \
            | "This is an automated background-task event"* \
            | "Do NOT interpret this as user acknowledgement"* \
            | "No human input has been received since"* \
            | "Read the output file to retrieve the result"*) ;;
            *) return 1 ;;
        esac
    done <<< "$s"
    printf '%s' "$ids"
}

# dogma_notify_repeat PROMPT SESSION_ID - 0 when PROMPT is a repeat subagent notification
# (slim), 1 otherwise. Records the task-ids either way.
dogma_notify_repeat() {
    local ids sid="$2" dir file sum now id all=0 e_id e_sum e_ts hit tmp
    ids="$(dogma_notify_agent_ids "$1")" || return 1
    [ -n "$ids" ] || return 1
    case "$sid" in "" | . | .. | *[!A-Za-z0-9._-]*) return 1 ;; esac
    dir="${DOGMA_NOTIFY_SEEN_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dogma/notify-seen}"
    file="$dir/$sid"
    sum="$(printf '%s' "$1" | cksum 2>/dev/null)" || return 1
    sum="${sum%% *}"
    now="$(date +%s 2>/dev/null)" || return 1
    mkdir -p "$dir" 2>/dev/null || return 1
    all=1
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        hit=0
        if [ -f "$file" ]; then
            while read -r e_id e_sum e_ts; do
                [ "$e_id" = "$id" ] || continue
                [[ "$e_ts" =~ ^[0-9]+$ ]] || continue
                if [ "$e_sum" != "$sum" ] || [ $((now - e_ts)) -gt 60 ]; then
                    hit=1
                    break
                fi
            done < "$file"
        fi
        [ "$hit" = 1 ] || all=0
        if ! grep -q "^$id $sum " "$file" 2>/dev/null; then
            printf '%s %s %s\n' "$id" "$sum" "$now" >> "$file" 2>/dev/null || return 1
        fi
    done <<< "$ids"
    if [ "$(wc -l < "$file" 2>/dev/null || echo 0)" -gt 400 ]; then
        tmp="$file.tmp.$$"
        tail -n 200 "$file" > "$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null
        rm -f "$tmp" 2>/dev/null
    fi
    [ "$all" = 1 ]
}
