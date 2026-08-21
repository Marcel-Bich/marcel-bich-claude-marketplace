#!/usr/bin/env bash
# credo-plugin-freshness-inject.sh - credo plugin (UserPromptSubmit + PostToolUse hook)
#
# Purpose: keep a standing reminder in the model context that a plugin's own
# script must NOT be run from bash via a version-pinned cache path copied out of
# a command or skill body. Command/skill bodies are rendered once with
# ${CLAUDE_PLUGIN_ROOT} already expanded by the harness to a VERSION-PINNED cache
# path (e.g. .../<plugin>/0.37.1/scripts/foo.sh). An agent that copies that path
# keeps calling a STALE version for the rest of the session, and
# ${CLAUDE_PLUGIN_ROOT} is not set in the agent's bash shell so it cannot be
# resolved there. The only reliable way to stay on latest is to glob the plugin
# cache under the active profile and pick the highest version with sort -V. This
# hook re-surfaces that guidance on a low cadence.
#
# Two events feed it (mirrors credo-datetime-inject.sh):
#   - UserPromptSubmit (ATTENDED): a per-session turn counter fires the reminder
#     on turn 1 and then every EVERY turns (counter % EVERY == 1).
#   - PostToolUse (AUTONOMOUS): during a long autonomous keep-alive run no user
#     prompt arrives, so the UserPromptSubmit counter stalls. To still resurface
#     the reminder there, the PostToolUse path fires on a TIME throttle (default
#     120s). It only runs when full autonomy is actually active (the
#     credo-autonomy-active flag is set and not paused) - so attended sessions use
#     ONLY the turn-count path and there is no double-injection.
#
# Scope: fires only when credo is ACTIVE for this session (a mode is set, OR the
# decision is "accepted") - mirrors credo-skill-nudge.sh. In a normal / not-yet
# -accepted session it stays silent. It fires in ALL credo modes (active,
# passive, autonomous), because agents run plugin scripts regardless of mode.
#
# Injection mechanism mirrors credo-datetime-inject.sh: hookSpecificOutput
# .additionalContext with suppressOutput true (model context only, not user chat),
# hookEventName mirrors the firing event.
#
# Failure-safe: ANY problem -> exit 0 with no output. Never block a prompt. No
# secrets or credentials are read.

set -euo pipefail
trap 'exit 0' ERR

# --- toggle (default on) ---
[[ "${CREDO_PLUGIN_FRESHNESS_INJECT:-true}" == "true" ]] || exit 0

# --- config (env-overridable) ---
EVERY="${CREDO_PLUGIN_FRESHNESS_EVERY:-10}"   # inject on turn 1, then every EVERY turns
[[ "$EVERY" =~ ^[1-9][0-9]*$ ]] || EVERY=10
INTERVAL="${CREDO_PLUGIN_FRESHNESS_INTERVAL:-120}"   # seconds between PostToolUse injects
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

    # Time throttle via per-session state (the reminder text is static, so no
    # delta-guard is needed - only the time gate).
    state_file="/tmp/claude-mb-credo-freshness-state_${session_id}.json"
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
    COUNTER_DIR="${CREDO_PLUGIN_FRESHNESS_DIR:-$CONFIG_DIR/credo/plugin-freshness}"
    mkdir -p "$COUNTER_DIR" 2>/dev/null || exit 0
    counter_file="$COUNTER_DIR/$session_id"

    count=0
    if [[ -f "$counter_file" ]]; then
        count=$(tr -d '[:space:]' < "$counter_file" 2>/dev/null) || count=0
    fi
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    count=$((count + 1))

    # Persist the bumped counter atomically (best-effort; never abort on failure).
    {
        tmp=$(mktemp "${counter_file}.XXXXXX" 2>/dev/null) && {
            printf '%s\n' "$count" > "$tmp" 2>/dev/null && mv -f "$tmp" "$counter_file" 2>/dev/null
            rm -f "$tmp" 2>/dev/null
        }
    } || true

    # Fire on the FIRST turn, then every EVERY turns (1, 1+EVERY, 1+2*EVERY, ...).
    # Stacking with other turn-1 reminders is deliberately accepted.
    [[ $((count % EVERY)) -eq 1 ]] || exit 0
fi

# The reminder text. A quoted heredoc delimiter keeps ${CLAUDE_CONFIG_DIR} and
# $HOME LITERAL - they must reach the agent as guidance, NOT be expanded here.
read -r -d '' line <<'FRESHNESS' || true
[credo-plugin-freshness] When you run a plugin's own script from bash, do NOT reuse a version-pinned cache path taken from a command or skill body - it may be a stale version (the path was rendered once and can point at an old cached version). Resolve the NEWEST installed version yourself by globbing the plugin cache under the ACTIVE profile and taking the highest version, e.g.:
  ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/<marketplace>/<plugin>/*/ | sort -V | tail -1
Two things you MUST get right or you will hit the WRONG target: (1) use the ACTIVE profile dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" - never a hardcoded ~/.claude - or you read a different profile's cache; (2) if the same plugin name exists under more than one marketplace, pin the correct marketplace in the glob, otherwise sort -V mixes versions across marketplaces and may pick the wrong one.
FRESHNESS

jq -n --arg ev "$event" --arg ctx "$line" \
    '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null

exit 0
