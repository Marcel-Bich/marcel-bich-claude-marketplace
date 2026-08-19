#!/usr/bin/env bash
# role-inject.sh - credo plugin (UserPromptSubmit hook)
#
# Purpose: give every prompt a persistent, per-session view of its credo session
# ROLE (task | plan). A role is a GUIDING default, orthogonal to the session mode:
# it can coexist with active | passive | autonomous. The role survives compact, new
# sessions and subagents because it is stored on disk keyed by session_id, and this
# hook re-injects it on every prompt.
#
# Pattern mirrors session-mode-inject.sh: read session_id from the hook stdin JSON
# with jq, look up per-session state, emit a short line via
# hookSpecificOutput.additionalContext (suppressOutput so the user chat is not
# flooded).
#
# Per-session state: one file per session_id under the session-roles dir. The file
# content is the role string. No file for this session -> inject NOTHING (silent).
# Default = no role = the agent does everything, so there is no bootstrap hint.
#
# Failure-safe: ANY problem -> exit 0 with no output. Never block a prompt.

# --- toggle (default on) ---
[[ "${CREDO_SESSION_ROLE_INJECT:-true}" == "true" ]] || exit 0

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
STATE_DIR="${CREDO_SESSION_ROLES_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-roles}"
state_file="$STATE_DIR/$session_id"

# No role set -> stay silent. The default (no role) is normal: the agent does
# everything, exactly as today.
[[ -f "$state_file" ]] || exit 0

role=$(tr -d '[:space:]' < "$state_file" 2>/dev/null | tr '[:upper:]' '[:lower:]') || role=""

case "$role" in
    task)
        rules="default owner of implementing GO items (items in 2_go/), INCLUDING commits and push where dogma permissions allow (single index owner)."
        ;;
    plan)
        rules="default owner of clarifying items in 1_clarify/, WITHOUT commits or push (the task/build role owns commits and push)."
        ;;
    *)
        # Unknown value -> do not invent a rule set, stay silent.
        exit 0
        ;;
esac

status="[credo-role] ${role} (session ${session_id}) - ${rules} Guiding default only; explicit user instruction overrides. Clear with /credo:role-clear."

jq -n --arg ctx "$status" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null

exit 0
