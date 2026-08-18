#!/usr/bin/env bash
# credo-attended-reminder.sh - credo plugin (UserPromptSubmit hook)
#
# Purpose: in the ATTENDED session modes (active | passive) keep a single standing
# reminder in the model context so the agent stops producing unproductive meta
# questions - proposing pauses / breaks / "stop for today", or asking "may I
# continue / which item next" - and instead drives its own recommendation forward.
# The rules themselves live in the session-active / session-passive skills; this
# hook only re-surfaces a one-line nudge on a low cadence.
#
# Scope guard: fires ONLY when the stored session mode for this session_id is
# "active" or "passive". autonomous, no-mode, and unknown -> exit 0, no output.
# In autonomous mode pauses / budget stops are correct, so it stays silent there.
#
# Cadence: a per-session turn counter is bumped on every call; the reminder is
# injected only when (counter % 5 == 1), i.e. on turn 1, 6, 11, ... - early, then
# every fifth prompt. Other turns: silent exit 0.
#
# Injection mechanism mirrors credo-datetime-inject.sh exactly:
# hookSpecificOutput.additionalContext with suppressOutput true (model context
# only, not the user chat), hookEventName UserPromptSubmit.
#
# Failure-safe: ANY problem -> exit 0 with no output. Never block a prompt. No
# secrets or credentials are read. set -euo pipefail is combined with an ERR trap
# that turns any unexpected failure into a clean exit 0, so strict mode never
# leaks a non-zero status back to the host.

set -euo pipefail
trap 'exit 0' ERR

# --- toggle (default on) ---
[[ "${CREDO_ATTENDED_REMINDER:-true}" == "true" ]] || exit 0

# --- config (env-overridable) ---
EVERY="${CREDO_ATTENDED_REMINDER_EVERY:-5}"   # inject on turn 1, then every EVERY turns
[[ "$EVERY" =~ ^[1-9][0-9]*$ ]] || EVERY=5

command -v jq >/dev/null 2>&1 || exit 0

# --- read hook stdin (session_id); drain it either way ---
INPUT=$(cat 2>/dev/null) || exit 0
[[ -n "$INPUT" ]] || exit 0

session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || session_id=""
[[ "$session_id" == "null" ]] && session_id=""
[[ -n "$session_id" ]] || exit 0

# Guard against path tricks in the session_id (must be a plain token).
case "$session_id" in
    *[!A-Za-z0-9._-]*) exit 0 ;;
esac

# --- resolve the stored session mode (same resolution as session-mode-set.sh) ---
STATE_DIR="${CREDO_SESSION_MODES_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-modes}"
mode_file="$STATE_DIR/$session_id"
[[ -f "$mode_file" ]] || exit 0

mode=$(tr -d '[:space:]' < "$mode_file" 2>/dev/null | tr '[:upper:]' '[:lower:]') || mode=""
case "$mode" in
    active|passive) ;;   # attended -> continue
    *) exit 0 ;;         # autonomous, no-mode, unknown -> silent
esac

# --- per-session turn counter (profile + session specific) ---
COUNTER_DIR="${CREDO_ATTENDED_REMINDER_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/attended-reminder}"
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

# Fire only on turn 1, then every EVERY turns (1, 1+EVERY, 1+2*EVERY, ...).
# (count-1) % EVERY == 0 also stays correct for EVERY=1 (fires every turn).
[[ $(((count - 1) % EVERY)) -eq 0 ]] || exit 0

line="[credo] attended: never suggest a pause/break; no 'may I continue / which item next' meta-question; drive your recommendation forward (planning -> next clarify round, task -> next GO item); use Ask only for genuine clarifications or GO."

jq -n --arg ctx "$line" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null

exit 0
