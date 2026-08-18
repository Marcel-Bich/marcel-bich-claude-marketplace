#!/usr/bin/env bash
# credo-autonomy-clear.sh - UserPromptSubmit hook.
#
# The keep-alive obligation (see credo-autonomy-keepalive.sh) may only apply in
# full-autonomy mode. On every real user message the autonomy flag is cleared:
# the user typing = autonomy PAUSED = no more keep-alive obligation. This is the
# primary, fail-safe guard against an endless keep-alive loop and is never
# removed - a user message always pauses autonomy.
#
# AUGMENT (not replace): when this pause actually ends an ACTIVE autonomy AND the
# session mode is still "autonomous", the agent is given a one-line judgment
# nudge: if the message was only context to improve the run, it MAY re-arm
# autonomy (credo-autonomy-on.sh) and continue; if it needs alignment/steering,
# stay attended. Re-arming is allowed ONLY here, because this session was already
# user-authorized for autonomy (mode==autonomous) - the agent can never cold-start
# autonomy from active/passive/normal (that stays user-only).
#
# EXCEPTION: self-scheduled ScheduleWakeup wake prompts carry the marker
# [CREDO-AUTONOMY-WAKE] and must NOT clear the flag. Background subagent
# completions (<task-notification>) and automated system events
# ([SYSTEM NOTIFICATION - NOT USER INPUT]) are also exempt, otherwise every
# subagent finish would end autonomy.
#
# Failure-safe: any error -> exit 0 (never block a prompt).
#
# NOTE: this is registered in the plugin hooks manifest (hooks/hooks.json) as a
# UserPromptSubmit hook, together with credo-autonomy-keepalive.sh on Stop. A
# real user message thus turns autonomy off at runtime.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || SCRIPT_DIR=""
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
FLAG="$CONFIG_DIR/credo-autonomy-active"
WAKE="$CONFIG_DIR/credo-wake-scheduled"

input="$(cat 2>/dev/null || true)"

prompt=""
session_id=""
if command -v jq >/dev/null 2>&1; then
    prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null || true)"
    session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
fi
[ -z "$session_id" ] && session_id="${CLAUDE_CODE_SESSION_ID:-}"

case "$prompt$input" in
    *"[CREDO-AUTONOMY-WAKE]"* | *"<task-notification>"* | *"[SYSTEM NOTIFICATION - NOT USER INPUT]"*)
        exit 0
        ;;
esac

# Real user message -> pause autonomy (fail-safe): drop flag + wake marker and
# set the hard paused opt-out. Capture whether autonomy was actually active so
# the judgment nudge below only fires when a real autonomy run was just paused.
had_flag=false
[ -f "$FLAG" ] && had_flag=true
rm -f "$FLAG" "$WAKE" 2>/dev/null || true
: > "$CONFIG_DIR/credo-autonomy-paused" 2>/dev/null || true

# If we just paused an ACTIVE autonomy and the session mode is still autonomous,
# let the agent judge intent (pure context -> re-arm; intervention -> stay).
if [ "$had_flag" = true ] && command -v jq >/dev/null 2>&1; then
    mode=""
    case "$session_id" in
        ""|*[!A-Za-z0-9._-]*) : ;;
        *)
            MODES_DIR="${CREDO_SESSION_MODES_DIR:-$CONFIG_DIR/credo/session-modes}"
            [ -f "$MODES_DIR/$session_id" ] && \
                mode=$(tr -d '[:space:]' < "$MODES_DIR/$session_id" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            ;;
    esac
    if [ "$mode" = "autonomous" ]; then
        on_script="${SCRIPT_DIR:+$SCRIPT_DIR/}credo-autonomy-on.sh"
        line="[credo] Your message paused autonomous mode (fail-safe). Judge its intent: only context/info to improve the run, no alignment needed -> re-arm autonomy (run ${on_script}) and continue unattended. Needs a decision, alignment, or steering -> stay attended and address it (/credo:session-active if you will keep collaborating). Re-arm is allowed only because this session was already authorized for autonomy; when unsure, stay attended."
        jq -n --arg ctx "$line" \
            '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null
    fi
fi
exit 0
