#!/usr/bin/env bash
# credo-skill-nudge.sh - credo plugin (UserPromptSubmit hook)
#
# Purpose: agents underuse the credo skills even when they would clearly help.
# The SessionStart KNOWLEDGE block lists them once; over a long session that
# ages out. This hook re-surfaces a single low-cadence nudge that asks the agent
# to SELF-ASSESS whether a credo skill fits the current work - actively use the
# fitting one on non-trivial or complex work, skip it on small/trivial changes.
# It never forces a skill; the judgment stays with the agent.
#
# Scope: fires only when credo is ACTIVE for this session (a mode is set, OR the
# decision is "accepted") - mirrors credo-session-start.sh. In a normal / not-yet
# -accepted session it stays silent. It fires in ALL credo modes (active,
# passive, autonomous), because skills are underused regardless of mode.
#
# Cadence: a per-session turn counter is bumped every call; the nudge fires when
# (counter-1) % EVERY == OFFSET, with OFFSET = EVERY/2. This OFFSETS it from
# credo-attended-reminder.sh (which fires at offset 0, turns 1/6/11...), so the
# two reminders never stack in the same turn - for EVERY=5 this fires on turns
# 3/8/13, interleaving with the attended reminder.
#
# Injection mirrors credo-datetime-inject.sh: hookSpecificOutput.additionalContext
# with suppressOutput true (model context only, not the user chat).
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

line="[credo] Worth a credo skill here? For anything sizable or complex, use the one that fits (diag / verify / audit / items / requirements-verbatim) instead of ad-hoc. For small stuff, do not bother - judge by effort and risk."

jq -n --arg ctx "$line" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null

exit 0
