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
# PER SESSION: the autonomy state lives under
#   ${CREDO_AUTONOMY_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/autonomy}/<session_id>/
# (see credo-autonomy-lib.sh). A user message pauses autonomy ONLY for the session
# it was typed in (session_id from the hook stdin JSON, else $CREDO_SESSION_ID /
# $CLAUDE_CODE_SESSION_ID); other sessions' autonomous runs are never touched.
#
# Failure-safe: never blocks a prompt (never exits 2). If no valid session_id can
# be resolved the state cannot be keyed: a note goes to stderr and the hook exits
# 1 (a non-blocking hook error) WITHOUT writing anything.
#
# DOES NOT touch the durable suspend-on-idle directive (managed by
# credo-suspend-directive.sh under credo/suspend-directives/<session_id>). Pausing
# autonomy on a user message affects ONLY this session's autonomy state below
# (active / paused / wake-scheduled), never the directive. The directive persists
# until an EXPLICIT revocation - user presence is NOT a revocation (see the session-autonomous skill's presence carve-out). Do not
# add any directive-clearing here.
#
# NOTE: this is registered in the plugin hooks manifest (hooks/hooks.json) as a
# UserPromptSubmit hook, together with credo-autonomy-keepalive.sh on Stop. A
# real user message thus turns autonomy off at runtime.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || SCRIPT_DIR=""
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

input="$(cat 2>/dev/null || true)"

prompt=""
stdin_session_id=""
if command -v jq >/dev/null 2>&1; then
    prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null || true)"
    stdin_session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
fi

case "$prompt$input" in
    *"[CREDO-AUTONOMY-WAKE]"* | *"<task-notification>"* | *"[SYSTEM NOTIFICATION - NOT USER INPUT]"*)
        exit 0
        ;;
esac

if [ -z "$SCRIPT_DIR" ] || [ ! -f "$SCRIPT_DIR/credo-autonomy-lib.sh" ]; then
    echo "credo-autonomy-clear: credo-autonomy-lib.sh not found; autonomy state untouched" >&2
    exit 1
fi
# shellcheck source=credo-autonomy-lib.sh
. "$SCRIPT_DIR/credo-autonomy-lib.sh"

if ! session_id="$(credo_autonomy_resolve_id "$stdin_session_id")"; then
    echo "credo-autonomy-clear: cannot determine a valid session_id; autonomy state untouched" >&2
    exit 1
fi
STATE_DIR="$(credo_autonomy_dir "$session_id")"

# Real user message -> pause THIS session's autonomy (fail-safe): drop its flag +
# wake marker and set its hard paused opt-out. Capture whether autonomy was
# actually active so the judgment nudge below only fires when a real autonomy
# run was just paused.
# A session that never had autonomy state (no dir) has nothing to pause - the
# Stop hook is inert without an active flag - so no dir is created for it.
had_flag=false
[ -f "$STATE_DIR/active" ] && had_flag=true
if [ -d "$STATE_DIR" ]; then
    rm -f "$STATE_DIR/active" "$STATE_DIR/wake-scheduled" 2>/dev/null || true
    : > "$STATE_DIR/paused" 2>/dev/null || true
fi

# If we just paused an ACTIVE autonomy and the session mode is still autonomous,
# let the agent judge intent (pure context -> re-arm; intervention -> stay).
if [ "$had_flag" = true ] && command -v jq >/dev/null 2>&1; then
    mode=""
    MODES_DIR="${CREDO_SESSION_MODES_DIR:-$CONFIG_DIR/credo/session-modes}"
    [ -f "$MODES_DIR/$session_id" ] && \
        mode=$(tr -d '[:space:]' < "$MODES_DIR/$session_id" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [ "$mode" = "autonomous" ]; then
        on_script="${SCRIPT_DIR:+$SCRIPT_DIR/}credo-autonomy-on.sh --session $session_id"
        line="[credo] Your message paused autonomous mode (fail-safe). Judge its intent: only context/info to improve the run, no alignment needed -> re-arm autonomy (run ${on_script}) and continue unattended. Needs a decision, alignment, or steering -> stay attended and address it (/credo:session-active if you will keep collaborating). Re-arm is allowed only because this session was already authorized for autonomy; when unsure, stay attended."
        jq -n --arg ctx "$line" \
            '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null
    fi
fi
exit 0
