#!/usr/bin/env bash
# credo-plugin-freshness-inject.sh - credo plugin (UserPromptSubmit hook)
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
# Scope: fires only when credo is ACTIVE for this session (a mode is set, OR the
# decision is "accepted") - mirrors credo-skill-nudge.sh. In a normal / not-yet
# -accepted session it stays silent. It fires in ALL credo modes (active,
# passive, autonomous), because agents run plugin scripts regardless of mode.
#
# Cadence: a per-session turn counter is bumped every call; the reminder fires
# when (counter % EVERY == 1), i.e. on the FIRST turn and then every EVERY turns
# - turns 1, 11, 21, ... for the default EVERY=10 (env-overridable via
# CREDO_PLUGIN_FRESHNESS_EVERY, validated as a positive integer, else 10). Turn 1
# is wanted: the reminder is present early, right at session start. Stacking with
# other turn-1 reminders (e.g. credo-attended-reminder.sh, which also fires on
# turn 1) is deliberately accepted - it is not a problem for these context-only
# nudges.
#
# Injection mechanism mirrors credo-datetime-inject.sh: hookSpecificOutput
# .additionalContext with suppressOutput true (model context only, not user chat),
# hookEventName UserPromptSubmit.
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

command -v jq >/dev/null 2>&1 || exit 0

# --- read hook stdin (session_id); drain it either way ---
INPUT=$(cat 2>/dev/null) || exit 0
[[ -n "$INPUT" ]] || exit 0

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

# --- per-session turn counter (profile + session specific) ---
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
# Stacking with other turn-1 reminders is deliberately accepted (see header).
[[ $((count % EVERY)) -eq 1 ]] || exit 0

# The reminder text. A quoted heredoc delimiter keeps ${CLAUDE_CONFIG_DIR} and
# $HOME LITERAL - they must reach the agent as guidance, NOT be expanded here.
read -r -d '' line <<'FRESHNESS' || true
[credo-plugin-freshness] When you run a plugin's own script from bash, do NOT reuse a version-pinned cache path taken from a command or skill body - it may be a stale version (the path was rendered once and can point at an old cached version). Resolve the NEWEST installed version yourself by globbing the plugin cache under the ACTIVE profile and taking the highest version, e.g.:
  ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/<marketplace>/<plugin>/*/ | sort -V | tail -1
Two things you MUST get right or you will hit the WRONG target: (1) use the ACTIVE profile dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" - never a hardcoded ~/.claude - or you read a different profile's cache; (2) if the same plugin name exists under more than one marketplace, pin the correct marketplace in the glob, otherwise sort -V mixes versions across marketplaces and may pick the wrong one.
FRESHNESS

jq -n --arg ctx "$line" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null

exit 0
