#!/usr/bin/env bash
# session-mode-inject.sh - credo plugin (UserPromptSubmit hook)
#
# Purpose: give every prompt a persistent, per-session view of its credo session
# mode (active | passive | autonomous). The mode survives compact, new sessions
# and subagents because it is stored on disk keyed by session_id, and this hook
# re-injects it on every prompt. It also surfaces the session_id itself, which
# the model otherwise cannot know (needed so the set command / skills can key
# their own per-session state).
#
# Pattern mirrors the limit plugin inject-status.sh: read session_id from the
# hook stdin JSON with jq, look up per-session state, emit a short line via
# hookSpecificOutput.additionalContext (suppressOutput so the user chat is not
# flooded).
#
# Per-session state: one file per session_id under the session-modes dir. The
# file content is the mode string. No file for this session -> inject nothing.
#
# Failure-safe: ANY problem -> exit 0 with no output. Never block a prompt.

# --- toggle (default on) ---
[[ "${CREDO_SESSION_MODE_INJECT:-true}" == "true" ]] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

# --- read hook stdin ---
INPUT=$(cat 2>/dev/null) || exit 0
[[ -n "$INPUT" ]] || exit 0

session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || session_id=""
[[ "$session_id" == "null" ]] && session_id=""
[[ -n "$session_id" ]] || exit 0

# Guard against path tricks in the session_id (must be a plain token).
case "$session_id" in
    *[!A-Za-z0-9._-]*) exit 0 ;;
esac

# --- locate the per-session state file ---
STATE_DIR="${CREDO_SESSION_MODES_DIR:-$HOME/.claude/credo/session-modes}"
state_file="$STATE_DIR/$session_id"
[[ -f "$state_file" ]] || exit 0

mode=$(tr -d '[:space:]' < "$state_file" 2>/dev/null | tr '[:upper:]' '[:lower:]') || mode=""

case "$mode" in
    active)
        rules="active collaboration: log progress via the limit thresholds and compact-plus, pick up open GO items alongside, clarify during subagent waits, no keep-alive. Load skill session-active."
        ;;
    passive)
        rules="passive: handle most work alongside, actively push every item to a 100 percent GO, less is more (only ambiguous items via the Ask tool), no keep-alive. Load skill session-passive."
        ;;
    autonomous)
        rules="autonomous: work approved GO items only, hook-enforced keep-alive (a Stop hook blocks a stop with no scheduled wake; schedule your own ScheduleWakeup plus wake marker), budget caps enforced, ntfy per task and question, secure progress via compact-plus. Load skill session-autonomous."
        ;;
    *)
        # Unknown value -> do not invent a rule set, stay silent.
        exit 0
        ;;
esac

status="[credo-mode] ${mode} (session ${session_id}) - ${rules}"

jq -n --arg ctx "$status" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null

exit 0
