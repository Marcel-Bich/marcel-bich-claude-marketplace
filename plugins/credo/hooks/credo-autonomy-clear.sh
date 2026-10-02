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
# subagent finish would end autonomy. Peer messages from other Claude sessions
# (<cross-session-message>) are exempt too: a peer is not the user, and
# credo-peer-message.sh tells the receiver how to handle them inside the run.
# Harness notices about other sessions ([Cross-session idle notice] /
# [Cross-session delivery notice], prompt prefix only) are exempt as well.
#
# PER SESSION: the autonomy state lives under
#   ${CREDO_AUTONOMY_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/autonomy}/<session_id>/
# (see credo-autonomy-lib.sh). A user message pauses autonomy ONLY for the session
# it was typed in (session_id from the hook stdin JSON, else $CREDO_SESSION_ID /
# $CLAUDE_CODE_SESSION_ID); other sessions' autonomous runs are never touched.
#
# Failure-safe: never blocks a user prompt (never exits 2; only a stale wake is dropped, above). If no valid session_id can
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

# A self-scheduled wake that fires after the session was SWITCHED to active or
# passive (by the user or the agent) is stale: drop it so it never drives work in an
# attended session. ScheduleWakeup cannot be cancelled from a hook, so this is the
# backstop. Keyed on the session MODE, not the autonomy flag: a user message only
# pauses autonomy (flag gone, mode still autonomous) and the run's wakes must survive
# that. No mode file = not provably switched = kept. Only a prompt that STARTS with
# the marker counts.
case "$prompt" in
    "[CREDO-AUTONOMY-WAKE]"*)
        if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/credo-autonomy-lib.sh" ]; then
            # shellcheck source=credo-autonomy-lib.sh
            . "$SCRIPT_DIR/credo-autonomy-lib.sh"
            if wake_sid="$(credo_autonomy_resolve_id "$stdin_session_id")"; then
                wake_modes="${CREDO_SESSION_MODES_DIR:-$CONFIG_DIR/credo/session-modes}"
                wake_mode=""
                [ -f "$wake_modes/$wake_sid" ] && \
                    wake_mode=$(tr -d '[:space:]' < "$wake_modes/$wake_sid" 2>/dev/null | tr '[:upper:]' '[:lower:]')
                case "$wake_mode" in
                    active | passive)
                        printf '{"decision": "block", "reason": "credo: stale autonomy wake-up dropped - this session was switched to %s mode"}\n' "$wake_mode"
                        exit 0
                        ;;
                esac
            fi
        fi
        ;;
esac

case "$prompt$input" in
    *"[CREDO-AUTONOMY-WAKE]"* | *"<task-notification>"* | *"[SYSTEM NOTIFICATION - NOT USER INPUT]"* | *"<cross-session-message"*)
        exit 0
        ;;
esac

# Harness notices about other sessions (idle / delivery) are automated, not the
# user; match them only as a prompt prefix so a user quoting one still pauses.
case "$prompt" in
    "[Cross-session idle notice]"* | "[Cross-session delivery notice]"*)
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

# Real user message -> pause THIS session's autonomy (fail-safe): drop its flag
# and set its hard paused opt-out. Capture whether autonomy was actually active
# so the judgment nudge below only fires when a real autonomy run was just paused.
# The wake marker is KEPT while it lies in the future: the ScheduleWakeup it
# records is still pending in the harness (it survives the pause, see the stale
# wake rule above), so after a re-arm (credo-autonomy-on.sh) the Stop hook must
# still see it. Only a past or unreadable marker is dropped here; explicit
# autonomy-off (incl. a switch to active/passive) clears wake state.
# A session that never had autonomy state (no dir) has nothing to pause - the
# Stop hook is inert without an active flag - so no dir is created for it.
had_flag=false
[ -f "$STATE_DIR/active" ] && had_flag=true
if [ -d "$STATE_DIR" ]; then
    rm -f "$STATE_DIR/active" 2>/dev/null || true
    if [ -f "$STATE_DIR/wake-scheduled" ]; then
        wake_ts="$(tr -dc '0-9' < "$STATE_DIR/wake-scheduled" 2>/dev/null || true)"
        if [ -z "$wake_ts" ] || ! [ "$wake_ts" -gt "$(date +%s)" ] 2>/dev/null; then
            rm -f "$STATE_DIR/wake-scheduled" 2>/dev/null || true
        fi
    fi
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
