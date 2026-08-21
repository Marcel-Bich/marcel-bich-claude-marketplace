#!/usr/bin/env bash
# credo-skill-nudge.sh - credo plugin (UserPromptSubmit + PostToolUse hook)
#
# Purpose: agents underuse the credo skills even when they would clearly help.
# The SessionStart KNOWLEDGE block lists them once; over a long session that
# ages out. This hook re-surfaces a single low-cadence nudge that asks the agent
# to SELF-ASSESS whether a credo skill fits the current work - actively use the
# fitting one on non-trivial or complex work, skip it on small/trivial changes.
# It never forces a skill; the judgment stays with the agent.
#
# Two events feed it (mirrors credo-datetime-inject.sh):
#   - UserPromptSubmit (ATTENDED): a per-session turn counter fires the nudge on
#     the OFFSET slot of each EVERY-turn window ((counter-1) % EVERY == OFFSET),
#     interleaved with credo-attended-reminder.sh (which uses offset 0).
#   - PostToolUse (AUTONOMOUS): during a long autonomous keep-alive run no user
#     prompt arrives, so the UserPromptSubmit counter stalls. To still resurface
#     the nudge there, the PostToolUse path fires on a TIME throttle (default
#     120s). It only runs when full autonomy is actually active (the
#     credo-autonomy-active flag is set and not paused) - so attended sessions use
#     ONLY the turn-count path and there is no double-injection.
#
# Scope: fires only when credo is ACTIVE for this session (a mode is set, OR the
# decision is "accepted") - mirrors credo-session-start.sh. In a normal / not-yet
# -accepted session it stays silent. It fires in ALL credo modes (active,
# passive, autonomous), because skills are underused regardless of mode.
#
# Injection mirrors credo-datetime-inject.sh: hookSpecificOutput.additionalContext
# with suppressOutput true (model context only, not the user chat); hookEventName
# mirrors the firing event.
#
# Failure-safe: ANY problem -> exit 0 with no output. Never block a prompt.

set -euo pipefail
trap 'exit 0' ERR

# --- toggle (default on) ---
[[ "${CREDO_SKILL_NUDGE:-true}" == "true" ]] || exit 0

# --- config (env-overridable) ---
EVERY="${CREDO_SKILL_NUDGE_EVERY:-5}"
[[ "$EVERY" =~ ^[1-9][0-9]*$ ]] || EVERY=5
OFFSET=$((EVERY / 2))
INTERVAL="${CREDO_SKILL_NUDGE_INTERVAL:-120}"   # seconds between PostToolUse injects
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || INTERVAL=120

command -v jq >/dev/null 2>&1 || exit 0

# --- read hook stdin (event + session_id); drain it either way ---
INPUT=$(cat 2>/dev/null) || exit 0
[[ -n "$INPUT" ]] || exit 0

event=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // "UserPromptSubmit"' 2>/dev/null) || event="UserPromptSubmit"
[[ "$event" == "null" ]] && event="UserPromptSubmit"
session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || session_id=""
[[ "$session_id" == "null" ]] && session_id=""
[[ -n "$session_id" ]] || exit 0
case "$session_id" in
    *[!A-Za-z0-9._-]*|.|*..*) exit 0 ;;
esac

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# --- gate: credo must be ACTIVE (mode set OR decision==accepted) ---
MODES_DIR="${CREDO_SESSION_MODES_DIR:-$CONFIG_DIR/credo/session-modes}"
DECISIONS_DIR="${CREDO_SESSION_DECISIONS_DIR:-$CONFIG_DIR/credo/session-decisions}"

mode=""
[[ -f "$MODES_DIR/$session_id" ]] && \
    mode=$(tr -d '[:space:]' < "$MODES_DIR/$session_id" 2>/dev/null | tr '[:upper:]' '[:lower:]')
decision=""
[[ -f "$DECISIONS_DIR/$session_id" ]] && \
    decision=$(tr -d '[:space:]' < "$DECISIONS_DIR/$session_id" 2>/dev/null | tr '[:upper:]' '[:lower:]')

active=false
case "$mode" in active|passive|autonomous) active=true ;; esac
[[ "$decision" == "accepted" ]] && active=true
[[ "$active" == true ]] || exit 0

# --- cadence: two mutually exclusive paths (mode separation avoids double-fire) ---
if [[ "$event" == "PostToolUse" ]]; then
    # AUTONOMOUS path: only while full autonomy is genuinely running (flag set,
    # not paused). Attended sessions never take this path -> no overlap with the
    # turn-count path below.
    [[ -f "$CONFIG_DIR/credo-autonomy-active" ]] || exit 0
    [[ -f "$CONFIG_DIR/credo-autonomy-paused" ]] && exit 0

    # Time throttle via per-session state (the nudge text is static, so no
    # delta-guard is needed - only the time gate).
    state_file="/tmp/claude-mb-credo-skillnudge-state_${session_id}.json"
    now_ts=$(date +%s 2>/dev/null) || exit 0

    last_ts=0
    if [[ -f "$state_file" ]]; then
        last_ts=$(jq -r '.last_ts // 0' "$state_file" 2>/dev/null) || last_ts=0
    fi
    [[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0

    [[ $((now_ts - last_ts)) -ge "$INTERVAL" ]] || exit 0

    # Persist state (only when we are about to inject); atomic best-effort.
    tmp=$(mktemp 2>/dev/null) && {
        jq -n --argjson last_ts "$now_ts" '{last_ts: $last_ts}' > "$tmp" 2>/dev/null \
            && mv -f "$tmp" "$state_file" 2>/dev/null
        rm -f "$tmp" 2>/dev/null
    }
else
    # ATTENDED path (UserPromptSubmit): per-session turn counter.
    COUNTER_DIR="${CREDO_SKILL_NUDGE_DIR:-$CONFIG_DIR/credo/skill-nudge}"
    mkdir -p "$COUNTER_DIR" 2>/dev/null || exit 0
    counter_file="$COUNTER_DIR/$session_id"

    count=0
    if [[ -f "$counter_file" ]]; then
        count=$(tr -d '[:space:]' < "$counter_file" 2>/dev/null) || count=0
    fi
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    count=$((count + 1))

    {
        tmp=$(mktemp "${counter_file}.XXXXXX" 2>/dev/null) && {
            printf '%s\n' "$count" > "$tmp" 2>/dev/null && mv -f "$tmp" "$counter_file" 2>/dev/null
            rm -f "$tmp" 2>/dev/null
        }
    } || true

    # Fire on the OFFSET slot of each EVERY-turn window (interleaved with the
    # attended reminder, which uses offset 0).
    [[ $(((count - 1) % EVERY)) -eq "$OFFSET" ]] || exit 0
fi

line="[credo] Worth a credo skill here? For anything sizable or complex, use the one that fits (diag / verify / audit / items / requirements-verbatim) instead of ad-hoc. For small stuff, do not bother - judge by effort and risk."

jq -n --arg ev "$event" --arg ctx "$line" \
    '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null

exit 0
