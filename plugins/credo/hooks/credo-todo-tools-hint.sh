#!/usr/bin/env bash
# credo-todo-tools-hint.sh - credo plugin (SessionStart hook)
#
# When the Claude Code task-list tools (TaskCreate / TaskGet / TaskUpdate / TaskList)
# are not opted in for this profile (CLAUDE_CODE_ENABLE_TODO_TOOLS != 1, see
# scripts/credo-todo-tools.sh), inject a short instruction to offer the opt-in ONCE
# via the AskUserQuestion tool. It never changes settings itself.
#
# Throttle: at most once per CREDO_TODO_TOOLS_HINT_DAYS (default 7) per profile; a
# "never ask again" answer (credo-todo-tools.sh decline) silences it for good.
#
# Silent (and nothing recorded) when: the opt-in is on, it was declined, the last
# hint is too recent, the start is not human-present (only startup|clear), credo is
# not active here (no session mode and no accepted decision), credo is declined for
# this directory, the session runs autonomously, the toggle is off, or the credo
# optimisation hook (credo-optimize-hook.sh) asks its own opt-in or returner question
# at this same start. That last gate keeps it to at most one credo opt-in question per
# start; the throttle slot is NOT consumed then, so the hint comes on a later start.
# SessionStart hooks run in parallel, so the gate re-evaluates the optimize hook's
# conditions read-only instead of relying on order: idle check FIRST, then the pending
# marker (the optimize hook writes pending before it updates last-seen, so one of the
# two always sees a returner offer).
# Toggle: CREDO_TODO_TOOLS_HINT (default true).
#
# Autonomous mode at a fresh start: the session-mode file is usually NOT written yet
# when this hook runs (the mode is set later, e.g. by /credo:session-autonomous or a
# resumed run), so the mode gate below cannot catch every unattended start. That is
# why the injected text itself opens with the rule "in autonomous / unattended mode do
# NOT ask" - the model applies it once the mode is known.
#
# Failure-safe: ANY problem -> exit 0 with no output.

trap 'exit 0' ERR
[[ "${CREDO_TODO_TOOLS_HINT:-true}" == "true" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || INPUT=""
[[ -n "$INPUT" ]] || exit 0
event=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null) || exit 0
[[ "$event" == "SessionStart" ]] || exit 0
source=$(printf '%s' "$INPUT" | jq -r '.source // ""' 2>/dev/null) || exit 0
case "$source" in startup|clear) ;; *) exit 0 ;; esac
session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || session_id=""
case "$session_id" in null|*[!A-Za-z0-9._-]*) session_id="" ;; esac

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
SCRIPTS="$(cd "$HOOK_DIR/../scripts" 2>/dev/null && pwd)" || exit 0
TOOL="$SCRIPTS/credo-todo-tools.sh"
[[ -x "$TOOL" ]] || exit 0

"$TOOL" hint-due >/dev/null 2>&1 || exit 0

dir_decision="$("$SCRIPTS/credo-dir-decision.sh" get 2>/dev/null | tr -d '[:space:]')" || dir_decision=""
[[ "$dir_decision" == "declined" ]] && exit 0

mode=""
decision=""
if [[ -n "$session_id" ]]; then
    MODES_DIR="${CREDO_SESSION_MODES_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-modes}"
    DECISIONS_DIR="${CREDO_SESSION_DECISIONS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-decisions}"
    [[ -f "$MODES_DIR/$session_id" ]] && mode=$(tr -d '[:space:]' < "$MODES_DIR/$session_id" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    [[ -f "$DECISIONS_DIR/$session_id" ]] && decision=$(tr -d '[:space:]' < "$DECISIONS_DIR/$session_id" 2>/dev/null | tr '[:upper:]' '[:lower:]')
fi
active=false
case "$mode" in active|passive|autonomous) active=true ;; esac
[[ "$decision" == "accepted" || "$dir_decision" == "accepted" ]] && active=true
[[ "$active" == true ]] || exit 0

[[ "$mode" == "autonomous" ]] && exit 0
# shellcheck source=credo-autonomy-lib.sh
if . "$HOOK_DIR/credo-autonomy-lib.sh" 2>/dev/null; then
    credo_autonomy_running "$session_id" && exit 0
fi

# Mirrors credo-optimize-hook.sh SessionStart: exit 0 when it asks a question now.
# Called only after the gates above (credo active, not autonomous, startup|clear).
optimize_will_ask() {
    [[ "${CREDO_OPTIMIZE_HOOK:-true}" == "true" ]] || return 1
    git rev-parse --git-dir >/dev/null 2>&1 || return 1
    local state="$SCRIPTS/credo-optimize-state.sh" backend optin pending
    [[ -x "$state" ]] || return 1
    backend="$("$SCRIPTS/credo-config.sh" backend 2>/dev/null || echo credo)"
    [[ "$backend" == "gsd" ]] && return 1
    optin="$("$state" optin 2>/dev/null | tr -d '[:space:]')" || optin=""
    [[ -z "$optin" ]] && return 0
    [[ "$optin" == "yes" ]] || return 1
    "$SCRIPTS/credo-optimize-idle.sh" >/dev/null 2>&1 && return 0
    pending="$("$state" get-pending 2>/dev/null | tr -d '[:space:]')" || pending=""
    [[ -n "$pending" ]]
}
optimize_will_ask && exit 0

OUT="[credo-todo-tools] FIRST: if this session runs in credo autonomous mode or any other unattended run, do NOT ask this question at all (not now, not later in the run) - at most note it once in the end-of-run report; the session mode is often not set yet when this hint is injected, so check it before asking.
The Claude Code task-list tools (TaskCreate/TaskGet/TaskUpdate/TaskList) are not opted in for this profile (CLAUDE_CODE_ENABLE_TODO_TOOLS is not 1). On newer models Claude Code only offers them with that opt-in; credo uses the list as its ephemeral coordination layer ([GO]/[HOLD]/[REMINDER] entries, §cct_N refs, orchestration), and subagents only get the tools when the parent session has them. When you ask, also mention: Ctrl+T shows or hides the task list; the list and a mod band (such as the credo band) cannot be visible at the same time, so many keep the list hidden and press Ctrl+T for a quick look. Ask once via the AskUserQuestion tool, at a natural point that does not interrupt urgent work: \"Enable the Claude Code task-list tools for credo (sets CLAUDE_CODE_ENABLE_TODO_TOOLS=1 in the profile settings.json, with a backup)?\" with the options:
- Yes, enable -> run \`\"${TOOL}\" enable\` (a restart of Claude Code may be needed if the tools do not appear)
- Not now -> do nothing (asked again in a few days)
- Never ask again -> run \`\"${TOOL}\" decline\` (/credo:setup can still enable it)
Never change settings.json without a Yes."

"$TOOL" hinted >/dev/null 2>&1 || true
jq -n --arg ctx "$OUT" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null
exit 0
