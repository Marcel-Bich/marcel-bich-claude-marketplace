#!/usr/bin/env bash
# credo-optimize-hook.sh - credo plugin (SessionStart + UserPromptSubmit hook)
#
# Drives the opt-in, returner-only offer of the credo optimisation audit
# (/credo:optimize). It never scans anything itself and never starts the audit; it
# only injects an instruction to ASK the user, and keeps the per-repo last-seen
# timestamp current.
#
#   UserPromptSubmit  update last-seen for this repo (credo-optimize-state.sh seen).
#                     Silent, cheap: one git call plus one small file write.
#   SessionStart      (any source, so also resume) in this order:
#                     1. opt-in never answered and credo already active here, on a
#                        human-present start (startup|clear) -> inject the one-time
#                        opt-in question. (While the credo decision itself is still
#                        open, credo-session-start.sh asks it inside its own ASK.)
#                     2. opt-in = yes and no offer pending yet -> evaluate
#                        credo-optimize-idle.sh BEFORE last-seen is updated; idle ->
#                        mark the offer pending.
#                     3. an offer is pending -> inject the returner offer, but only in
#                        an interactive session; in autonomous mode it stays pending
#                        until an attended session asks it (once per return).
#                     4. update last-seen.
#
# Silent (no output, last-seen untouched) when: not a git repo, credo declined for
# this directory (/credo:disable), or the toggle is off. SessionStart additionally
# stays silent when the task backend is gsd.
# Toggle: CREDO_OPTIMIZE_HOOK (default true).
#
# Failure-safe: ANY problem -> exit 0 with no output. Never block a prompt.

[[ "${CREDO_OPTIMIZE_HOOK:-true}" == "true" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || INPUT=""
[[ -n "$INPUT" ]] || exit 0

event=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null) || exit 0
session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || session_id=""
source=$(printf '%s' "$INPUT" | jq -r '.source // ""' 2>/dev/null) || source=""
[[ "$session_id" == "null" ]] && session_id=""
[[ "$source" == "null" ]] && source=""
case "$session_id" in *[!A-Za-z0-9._-]*) session_id="" ;; esac

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
SCRIPTS="$(cd "$HOOK_DIR/../scripts" 2>/dev/null && pwd)" || exit 0
STATE="$SCRIPTS/credo-optimize-state.sh"
[[ -x "$STATE" ]] || exit 0

dir_decision="$("$SCRIPTS/credo-dir-decision.sh" get 2>/dev/null | tr -d '[:space:]')" || dir_decision=""
[[ "$dir_decision" == "declined" ]] && exit 0

if [[ "$event" == "UserPromptSubmit" ]]; then
    "$STATE" seen >/dev/null 2>&1 || true
    exit 0
fi
[[ "$event" == "SessionStart" ]] || exit 0

# The backend gate (python YAML read) runs only here, not on every prompt.
backend="$("$SCRIPTS/credo-config.sh" backend 2>/dev/null || echo credo)"
[[ "$backend" == "gsd" ]] && exit 0

# --- session state: credo active? autonomous? --------------------------------
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

autonomous=false
[[ "$mode" == "autonomous" ]] && autonomous=true
# shellcheck source=credo-autonomy-lib.sh
if . "$HOOK_DIR/credo-autonomy-lib.sh" 2>/dev/null; then
    credo_autonomy_running "$session_id" && autonomous=true
fi

optin="$("$STATE" optin 2>/dev/null | tr -d '[:space:]')" || optin=""

OUT=""
if [[ -z "$optin" ]]; then
    if [[ "$active" == true && "$autonomous" == false ]]; then
        case "$source" in
            startup|clear)
                OUT="[credo-optimize] credo can offer an optimisation audit for this repo: a read-only scan (conflict hotspots, changelog fragments, test-stage convention, dogma settings, parallelism readiness) whose findings you then accept or decline one by one. Nothing is scanned or changed without the user's consent, and the user has not answered this yet. Ask once via the AskUserQuestion tool, at a natural point that does not interrupt urgent work: \"Optimisation audit wanted for this repo?\" with the options:
- Yes, run it now -> run \`\"${STATE}\" optin yes\`, then run /credo:optimize (later it is offered again only when you return after a longer break)
- No -> run \`\"${STATE}\" optin no\` (never offered automatically again; /credo:optimize stays available manually)
If the user skips the question, record nothing (it may be asked again on a later start)."
                ;;
        esac
    fi
elif [[ "$optin" == "yes" ]]; then
    pending="$("$STATE" get-pending 2>/dev/null | tr -d '[:space:]')" || pending=""
    idle_out=""
    if [[ -z "$pending" ]]; then
        if idle_out="$("$SCRIPTS/credo-optimize-idle.sh" 2>/dev/null)"; then
            "$STATE" pending >/dev/null 2>&1 && pending="now"
        fi
    fi
    if [[ -n "$pending" && "$autonomous" == false ]]; then
        days="$(printf '%s\n' "$idle_out" | sed -n 's/^threshold_days=//p')"
        [[ -n "$days" ]] || days="the configured number of"
        OUT="[credo-optimize] Welcome-back offer: this repo has been idle for at least ${days} days (credo last-seen, reflog, index and modified files all older), and the user opted in to the optimisation audit. Ask exactly once via the AskUserQuestion tool, before starting new work: \"Run the credo optimisation audit now (read-only scan, findings offered one by one)?\" with the options:
- Yes -> run \`\"${STATE}\" offered\`, then run /credo:optimize
- Not now -> run \`\"${STATE}\" offered\` (offered again only after the next longer break)
- Never offer again -> run \`\"${STATE}\" offered\` and \`\"${STATE}\" optin no\` (/credo:optimize stays available manually)
Do not ask in autonomous work. Never start the scan without a Yes."
    fi
fi

"$STATE" seen >/dev/null 2>&1 || true

if [[ -n "$OUT" ]]; then
    jq -n --arg ctx "$OUT" \
        '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null
fi
exit 0
