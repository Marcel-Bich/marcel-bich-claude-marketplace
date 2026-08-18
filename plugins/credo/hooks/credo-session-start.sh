#!/usr/bin/env bash
# credo-session-start.sh - credo plugin (SessionStart hook)
#
# Purpose: make a session reliably aware of the credo workflow. Two SEPARATE
# mechanisms, driven by on-disk per-session state (which survives compaction,
# because compaction wipes the model context but NOT the disk files or the
# session_id):
#
#   1. ASK (one-time activation). While the session has made NO credo decision
#      yet, and only on a genuine (re)start where a human is present, inject an
#      instruction telling the agent to ask the user - via AskUserQuestion -
#      whether to use the credo workflow. Yes -> /credo:session-init; No -> record
#      a "declined" marker so this is never asked again. Never in autonomous work.
#
#   2. KNOWLEDGE (re-feed after every reset). Once credo is ACTIVE for the
#      session, re-inject the full credo command + skill list on every
#      SessionStart (startup, resume, clear, compact, fork), because the model
#      context - and thus that knowledge - is gone after each reset. The list is
#      tagged with an execution class (A/B/C) so the agent knows which commands
#      it may run itself, which need the user, and which it must never trigger
#      autonomously.
#
# State (keyed by session_id, mirrors session-mode-set.sh / credo-decision-set.sh):
#   mode      : ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-modes/<id>      (active|passive|autonomous)
#   decision  : ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-decisions/<id>  (accepted|declined)
# Derived session state:
#   active   = a mode is set, OR decision == accepted   -> KNOWLEDGE (any source)
#   declined = decision == declined (and no mode)        -> stay silent
#   open     = neither                                   -> ASK on startup/clear only
#
# The decision x source matrix (open state only; active always feeds KNOWLEDGE,
# declined always stays silent):
#   startup -> ASK        clear   -> ASK
#   compact -> nothing    resume  -> nothing    fork -> nothing
# (compact/resume/fork never ASK: after a reset the decision is either already
# made, or - if still open - we do not push an unrequested workflow.)
#
# Pattern mirrors session-mode-inject.sh: emit hookSpecificOutput.additionalContext
# with jq, suppressOutput so the user chat is not flooded.
#
# Failure-safe: ANY problem -> exit 0 with no output. Never disrupt a session.

# --- toggle (default on) ---
[[ "${CREDO_SESSION_START_INJECT:-true}" == "true" ]] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

# --- read hook stdin ---
INPUT=$(cat 2>/dev/null) || exit 0
[[ -n "$INPUT" ]] || exit 0

session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || session_id=""
[[ "$session_id" == "null" ]] && session_id=""
[[ -n "$session_id" ]] || exit 0
case "$session_id" in
    *[!A-Za-z0-9._-]*) exit 0 ;;
esac

source=$(printf '%s' "$INPUT" | jq -r '.source // ""' 2>/dev/null) || source=""
[[ "$source" == "null" ]] && source=""

# --- read per-session state ---
MODES_DIR="${CREDO_SESSION_MODES_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-modes}"
DECISIONS_DIR="${CREDO_SESSION_DECISIONS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-decisions}"

mode=""
[[ -f "$MODES_DIR/$session_id" ]] && \
    mode=$(tr -d '[:space:]' < "$MODES_DIR/$session_id" 2>/dev/null | tr '[:upper:]' '[:lower:]')
decision=""
[[ -f "$DECISIONS_DIR/$session_id" ]] && \
    decision=$(tr -d '[:space:]' < "$DECISIONS_DIR/$session_id" 2>/dev/null | tr '[:upper:]' '[:lower:]')

active=false
case "$mode" in active|passive|autonomous) active=true ;; esac
[[ "$decision" == "accepted" ]] && active=true

# --- resolve the decision-set script path for the ASK instruction ---
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || HOOK_DIR=""
DECISION_SCRIPT="${HOOK_DIR}/../scripts/credo-decision-set.sh"
# Prefer the normalized absolute path (drops the ../ for a cleaner instruction);
# if HOOK_DIR could not be resolved, fall back to ${CLAUDE_PLUGIN_ROOT} rather
# than emitting a broken /../ path.
_scripts_dir="$(cd "${HOOK_DIR}/../scripts" 2>/dev/null && pwd)" || _scripts_dir=""
if [[ -n "$_scripts_dir" ]]; then
    DECISION_SCRIPT="${_scripts_dir}/credo-decision-set.sh"
elif [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    DECISION_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/credo-decision-set.sh"
fi

# --- gating: whole-hook backend gate + a dedicated ASK toggle ---------------
# Backend is resolved via credo-config.sh (env CREDO_TASK_BACKEND > .credo/config
# cascade > default credo); any error falls back to credo. When the backend is
# gsd, the ENTIRE credo SessionStart hook stands down (no ASK, no KNOWLEDGE):
# GSD is the task system, so advertising the credo item workflow would mislead.
backend="$("${HOOK_DIR}/../scripts/credo-config.sh" backend 2>/dev/null || echo credo)"
[[ -n "$backend" ]] || backend="credo"
[[ "$backend" == "gsd" ]] && exit 0

# CREDO_SESSION_START_ASK (default on) turns ONLY the one-time activation ASK
# off, independently of the KNOWLEDGE re-feed (CREDO_SESSION_START_INJECT still
# gates the whole hook).
ask_enabled=true
[[ "${CREDO_SESSION_START_ASK:-true}" == "true" ]] || ask_enabled=false
# Autonomy guard: if a global full-autonomy run is active (the same flag the
# keep-alive Stop hook uses), never inject the ASK - nobody is at the keyboard
# to answer AskUserQuestion. This closes the gap where a fresh autonomous
# session has no mode file yet at its first startup (state would be "open").
[[ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo-autonomy-active" ]] && ask_enabled=false

emit() {
    jq -n --arg ctx "$1" \
        '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null
}

# --- KNOWLEDGE block (credo active): full list, tagged by execution class ---
read -r -d '' KNOWLEDGE <<'K'
[credo] credo workflow is ACTIVE for this session. Prefer these credo skills and commands over the generic/default approach so the workflow runs cleanly.

SKILLS (auto-trigger by their description - use them actively whenever they apply): items (the work-item model = the task system), audit (mandatory post-completion review gate), verify (visual Definition of Done for any UI/runtime surface), diag (read-only root-cause diagnosis), safety (before ANY delete or install), rules (per-repo special rules from .credo/RULES.md - load and honor at start), requirements-verbatim (log approved intent word-for-word), orchestration (delegation rules), budget (API cap + reset rules), compact-plus (secure approved state before a compact), pr-vetting, issue-triage, skill-capture, cross-cutting-checklist-generator, wsl-env.

COMMANDS by execution class:
[A] may be run by the agent itself when useful: /credo:session-init, /credo:project (show only, no path argument).
[B] only on explicit user request (interactive or the user's call to make): /credo:session-active, /credo:session-passive, /credo:psalm, /credo:project <path> (pin a target).
[C] NEVER run autonomously - only the user decides these (mode escalation / installs / structural migration): /credo:session-autonomous, /credo:setup, /credo:migrate.
K

# --- ASK block (credo decision still open) ---
read -r -d '' ASK <<K
[credo] The credo workflow is available but NOT yet activated for this session. Before doing anything else, ask the user via the AskUserQuestion tool HOW to work this session (a mode choice, not a plain yes/no). First show this short reminder to the user (render each slash-command in code-style so they read as commands):

Use the credo workflow this session? Quick reminder:
- work is tracked as "items" with a strict done-gate
- /compact-plus saves your approved state so a /compact cannot drop it
- /credo:session-active - intensive live collaboration
- /credo:session-passive - available only for clarifications
- /credo:session-autonomous - full unattended work, turn on when needed
- /credo:psalm - the full credo guide (all commands + workflow); run it anytime you need help or want to learn more

Then offer exactly these AskUserQuestion options:
- Active  -> run the /credo:session-active command (sets the mode to active and records the credo decision)
- Passive -> run the /credo:session-passive command (sets the mode to passive and records the credo decision)
- No      -> run \`"${DECISION_SCRIPT}" declined ${session_id}\` so this is not asked again
Do NOT offer autonomous as a selectable option - only mention it can be turned on anytime via /credo:session-autonomous. Do NOT ask this in autonomous/unattended work. This is a one-time setup question - handle it first, then continue with the user's request.
K

# --- Gap A: one-shot post-reset rehydrate breadcrumb (left by compact-plus) --
# After a reset (compact|resume|fork), if compact-plus dropped a breadcrumb for
# this session, tell the agent to reload the state it secured to disk, then
# consume (delete) the breadcrumb so it never fires again on stale info.
REHYDRATE=""
REHYDRATE_DIR="${CREDO_REHYDRATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/rehydrate}"
breadcrumb="$REHYDRATE_DIR/$session_id"
case "$source" in
    compact|resume|fork)
        if [[ -f "$breadcrumb" ]]; then
            handoff_path=$(head -n1 "$breadcrumb" 2>/dev/null)
            [[ -z "$handoff_path" ]] && handoff_path=".credo/process/handoffs/HANDOFF.md"
            mode_hint=""
            [[ -z "$mode" ]] && mode_hint=" (No session mode set - if this is attended work, pick one: /credo:session-active or /credo:session-passive.)"
            REHYDRATE="[credo] You secured state with /compact-plus before this compaction. Reload it now before continuing: the handoff file at ${handoff_path}, the latest .credo/process/requirements/ entry, and .credo/process/resume-after-reset.md if present. Then resume where you left off.${mode_hint}"
            rm -f "$breadcrumb" 2>/dev/null || true
        fi
        ;;
esac

# --- decision logic: assemble the output, then emit once ---------------------
OUT=""
if [[ "$active" == true ]]; then
    OUT="$KNOWLEDGE"
elif [[ "$decision" == "declined" ]]; then
    OUT=""
elif [[ "$mode" != "autonomous" ]]; then
    # open decision: ASK only on a human-present (re)start, never in autonomous work
    case "$source" in
        startup|clear) [[ "$ask_enabled" == true ]] && OUT="$ASK" ;;
    esac
fi

# Append the rehydrate ACTION (Gap A) to whatever we emit, or emit it alone.
if [[ -n "$REHYDRATE" ]]; then
    if [[ -n "$OUT" ]]; then
        OUT="$OUT"$'\n\n'"$REHYDRATE"
    else
        OUT="$REHYDRATE"
    fi
fi

[[ -n "$OUT" ]] && emit "$OUT"
exit 0
