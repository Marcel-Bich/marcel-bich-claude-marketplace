#!/usr/bin/env bash
# credo-datetime-inject.sh - credo plugin (UserPromptSubmit + PostToolUse hook)
#
# Purpose: inject the current local date and time into the model context so the
# agent stays date/time-aware AND the mode-awareness rules have a live clock
# signal. Two events feed it:
#   - UserPromptSubmit: inject on EVERY prompt (fresh, cheap, user turns are rare).
#   - PostToolUse: inject during long autonomous runs where no user prompt arrives
#     for many minutes, so the clock does not freeze at the last prompt's value.
#     Throttled (default 120s) and delta-guarded (only when the rendered line
#     actually changed) so it does not accumulate a line per tool call. Because
#     PostToolUse only fires on real tool activity, idle waits inject nothing.
#
# Output: hookSpecificOutput.additionalContext with suppressOutput true (model
# context only, not the user chat). One short line, for example:
#   [credo-time] 2026-07-22 14:33 (Tue), TZ CEST
#
# Per-session throttle/delta state (PostToolUse only): a small json under /tmp
# keyed by session_id. UserPromptSubmit never touches it (always injects).
#
# No dependency on the limit plugin or any other plugin. jq is optional on the
# UserPromptSubmit path (hand-built JSON is safe: the content is a controlled date
# format stripped of quotes/backslashes/control chars). The PostToolUse path needs
# jq for the state file; without jq it simply injects unthrottled like before.
#
# Failure-safe: ANY problem -> exit 0 with no output. Never block a prompt.

# --- toggle (default on) ---
[[ "${CREDO_DATETIME_INJECT:-true}" == "true" ]] || exit 0

# --- config (env-overridable) ---
INTERVAL="${CREDO_DATETIME_INJECT_INTERVAL:-120}"   # seconds between PostToolUse injects

# --- read hook stdin (event + session_id); drain it either way so the producer
#     never blocks on a full pipe ---
INPUT=$(cat 2>/dev/null) || INPUT=""

event="UserPromptSubmit"
session_id=""
if command -v jq >/dev/null 2>&1 && [[ -n "$INPUT" ]]; then
    event=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // "UserPromptSubmit"' 2>/dev/null) || event="UserPromptSubmit"
    session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || session_id=""
    [[ "$event" == "null" ]] && event="UserPromptSubmit"
    [[ "$session_id" == "null" ]] && session_id=""
fi

# --- build the local date/time line ---
now_line=$(date '+%Y-%m-%d %H:%M (%a), TZ %Z' 2>/dev/null) || exit 0
[[ -n "$now_line" ]] || exit 0
line="[credo-time] ${now_line}"

# Defensive: keep the manual-JSON path safe even if the locale injected an odd
# character - strip backslashes, double quotes, and any control characters.
line=${line//\\/}
line=${line//\"/}
line=$(printf '%s' "$line" | tr -d '[:cntrl:]' 2>/dev/null) || exit 0
[[ -n "$line" ]] || exit 0

# --- PostToolUse: throttle + delta-guard via per-session state ---
if [[ "$event" == "PostToolUse" ]]; then
    # Without jq or a usable session_id we cannot keep state safely -> stay silent
    # on the tool-call path rather than inject on every single tool call.
    command -v jq >/dev/null 2>&1 || exit 0
    [[ -n "$session_id" ]] || exit 0
    # Guard against path tricks in the session_id (must be a plain token).
    case "$session_id" in
        *[!A-Za-z0-9._-]*) exit 0 ;;
    esac

    state_file="/tmp/claude-mb-credo-time-state_${session_id}.json"
    now_ts=$(date +%s 2>/dev/null) || exit 0

    last_ts=0; last_line=""
    if [[ -f "$state_file" ]]; then
        last_ts=$(jq -r '.last_ts // 0' "$state_file" 2>/dev/null) || last_ts=0
        last_line=$(jq -r '.last_line // ""' "$state_file" 2>/dev/null) || last_line=""
        [[ "$last_line" == "null" ]] && last_line=""
    fi
    [[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0

    # Throttle: not enough time since the last inject -> skip.
    [[ $((now_ts - last_ts)) -ge "$INTERVAL" ]] || exit 0
    # Delta-guard: the rendered (minute-granular) line has not changed -> skip.
    [[ "$line" != "$last_line" ]] || exit 0

    # Persist state (only when we are about to inject).
    tmp=$(mktemp 2>/dev/null) && {
        jq -n --argjson last_ts "$now_ts" --arg last_line "$line" \
            '{last_ts: $last_ts, last_line: $last_line}' > "$tmp" 2>/dev/null \
            && mv -f "$tmp" "$state_file" 2>/dev/null
        rm -f "$tmp" 2>/dev/null
    }
fi

# --- emit JSON (suppressOutput so the user chat is not flooded); hookEventName
#     mirrors the firing event so the host attributes the context correctly ---
if command -v jq >/dev/null 2>&1; then
    jq -n --arg ev "$event" --arg ctx "$line" \
        '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null
else
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"},"suppressOutput":true}\n' "$event" "$line"
fi

exit 0
