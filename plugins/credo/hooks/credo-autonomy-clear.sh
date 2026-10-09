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
# A bare "." prompt is exempt only when it consumes this session's self-wake file
# (written by scripts/credo_pane_wake.py for /credo:self-reload and
# /credo:self-compact, which typed that "." to start a turn); any prompt consumes
# the file and gets the wake note, but only that "." skips the pause.
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

# --- self-wake (scripts/credo_pane_wake.py: /credo:self-reload, /credo:self-compact) --
# After a reload or a finished compact the detached worker types "." into this
# session's own pane to start a turn, and leaves the wake file
# <configdir>/credo/self-wake-<session_id> (JSON, "kind" reload|compact). The FIRST
# prompt of this session - whatever it is - consumes it. That cancels the worker's
# 60 s "." fallback (it watches the file) and gives the agent a short note. Only a
# bare "." that consumed the file is the worker's own prompt, so it never pauses
# autonomy and is labelled as such; any other prompt is a real message and the note
# says so. A wake file older than 1 h is stale and dropped without a note. Works
# without jq too (plain-text note). Cost is one test -f per prompt.
SELF_WAKE_NOTE=""
sw_json_str() { # key file -> string value (jq, else a plain grep/sed fallback)
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$1" 'if has($k) and .[$k] != null then .[$k] | tostring else empty end' "$2" 2>/dev/null
    else
        grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" 2>/dev/null | head -1 \
            | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/'
        grep -o "\"$1\"[[:space:]]*:[[:space:]]*\(true\|false\)" "$2" 2>/dev/null | head -1 \
            | sed 's/.*:[[:space:]]*//'
    fi
}
self_wake_note() { # kind update compact_done is_dot
    local root ver_dir credo_dir loaded="" newest="" check head
    if [ "$1" = "compact" ]; then
        if [ "$4" = "yes" ]; then
            head="[credo-self-compact] This turn was started by /credo:self-compact (it typed \".\" - not a user message)"
        else
            head="[credo-self-compact] A /credo:self-compact just finished; this prompt is a real message - handle it normally, then"
        fi
        if [ "$3" = "false" ]; then
            check="no compact-done signal arrived in time, so check whether the compact actually happened (is the earlier conversation summarized?), then reload the handoff secured by compact-plus and continue where you left off."
        else
            check="the compact finished. Reload the handoff secured by compact-plus and continue where you left off."
        fi
        if [ "$4" = "yes" ]; then
            printf '%s' "$head. Next: $check"
        else
            printf '%s' "$head $check"
        fi
        return 0
    fi
    root="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)" || root=""
    if [ -n "$root" ]; then
        loaded="$(sw_json_str version "$root/.claude-plugin/plugin.json")" || loaded=""
        credo_dir="$(dirname "$root")"
        ver_dir="$(dirname "$(dirname "$credo_dir")")"
        if [ "$(basename "$credo_dir")" = "credo" ] && [ "$(basename "$ver_dir")" = "cache" ]; then
            newest="$(ls -1 "$credo_dir" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | tail -1)" || newest=""
        fi
    fi
    if [ -n "$loaded" ] && [ -n "$newest" ] && [ "$loaded" = "$newest" ]; then
        check="loaded credo $loaded = newest in the plugin cache, so the plugin reload looks sufficient"
    elif [ -n "$loaded" ] && [ -n "$newest" ]; then
        check="loaded credo $loaded, newest in the plugin cache $newest, so the reload did NOT load the new version"
    else
        check="loaded credo ${loaded:-unknown}, newest in the plugin cache unknown (not running from the plugin cache)"
    fi
    if [ "$4" = "yes" ]; then
        head="[credo-self-reload] This turn was started by /credo:self-reload after it typed /reload-plugins and /reload-skills (it typed \".\" - not a user message).${2:+ Plugin update: $2.} Check now whether the reload was enough"
    else
        head="[credo-self-reload] A /credo:self-reload just finished (it typed /reload-plugins and /reload-skills).${2:+ Plugin update: $2.} This prompt is a real message - handle it normally, then check whether the reload was enough"
    fi
    printf '%s' "$head ($check); also confirm the command, skill or hook you expected from the update is listed. Enough -> continue where you left off. Not enough -> fall back to the full restart /credo:self-restart --update (cc-up) under its owner rule (autonomous: run --announce 300 --no-background-work --update; interactive: ask once via the Ask tool, then run --user-confirmed --no-background-work --update)."
}
emit_self_wake() {
    [ -n "$SELF_WAKE_NOTE" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg ctx "$SELF_WAKE_NOTE" \
            '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null
    else
        printf '%s\n' "$SELF_WAKE_NOTE"  # plain stdout of a UserPromptSubmit hook reaches the context
    fi
}
sw_sid="$stdin_session_id"
if [ -z "$sw_sid" ] && ! command -v jq >/dev/null 2>&1; then
    sw_sid="$(printf '%s' "$input" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
        | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/')"
fi
[ -n "$sw_sid" ] || sw_sid="${CLAUDE_CODE_SESSION_ID:-}"
case "$sw_sid" in ""|.|..|*[!A-Za-z0-9._-]*) sw_sid="" ;; esac
if [ -n "$sw_sid" ] && [ -f "$CONFIG_DIR/credo/self-wake-$sw_sid" ]; then
    sw_file="$CONFIG_DIR/credo/self-wake-$sw_sid"
    sw_stale="$(find "$sw_file" -mmin +60 2>/dev/null)"
    if [ -n "$sw_stale" ]; then
        rm -f "$sw_file" 2>/dev/null || true
    else
        sw_kind="$(sw_json_str kind "$sw_file")"; [ -n "$sw_kind" ] || sw_kind="reload"
        sw_update="$(sw_json_str update "$sw_file")"
        sw_done="$(sw_json_str compact_done "$sw_file")"
        rm -f "$sw_file" 2>/dev/null || true
        sw_dot=no
        if command -v jq >/dev/null 2>&1; then
            [ "$(printf '%s' "$prompt" | tr -d '[:space:]')" = "." ] && sw_dot=yes
        elif printf '%s' "$input" | grep -qE '"prompt"[[:space:]]*:[[:space:]]*"[[:space:]]*\.[[:space:]]*"'; then
            sw_dot=yes
        fi
        SELF_WAKE_NOTE="$(self_wake_note "$sw_kind" "$sw_update" "$sw_done" "$sw_dot")"
        if [ "$sw_dot" = yes ]; then
            emit_self_wake
            exit 0
        fi
    fi
fi

case "$prompt$input" in
    *"[CREDO-AUTONOMY-WAKE]"* | *"<task-notification>"* | *"[SYSTEM NOTIFICATION - NOT USER INPUT]"* | *"<cross-session-message"*)
        emit_self_wake
        exit 0
        ;;
esac

# Harness notices about other sessions (idle / delivery) are automated, not the
# user; match them only as a prompt prefix so a user quoting one still pauses.
case "$prompt" in
    "[Cross-session idle notice]"* | "[Cross-session delivery notice]"*)
        emit_self_wake
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
        [ -n "$SELF_WAKE_NOTE" ] && line="$line
$SELF_WAKE_NOTE"
        SELF_WAKE_NOTE="$line"
    fi
fi
emit_self_wake
exit 0
