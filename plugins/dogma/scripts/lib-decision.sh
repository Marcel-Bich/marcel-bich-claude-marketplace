#!/bin/bash
# Dogma: shared emitter for the "ask" decision of the PreToolUse hooks
#
# Every dogma hook that asks the user for confirmation prints its decision through
# dogma_emit_ask. In an interactive session that is a normal "ask". When no human can
# answer the prompt (credo's autonomy keep-alive is running for the session, see
# dogma_credo_unattended in lib-credo.sh) a prompt would stall the whole unattended run,
# so the ask becomes a "deny" with the same reason plus a retry hint. An ask never turns
# into an allow. Anything unclear keeps the ask.
#
# ENV: CLAUDE_MB_DOGMA_UNATTENDED_DENY=true (default) | false - any value other than
#      true keeps every ask, also in an autonomous run.
#
# Usage:
#   source lib-decision.sh
#   dogma_emit_ask "$INPUT" "dogma: ... requires confirmation."   # INPUT = the hook's stdin JSON

DOGMA_DECISION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-credo.sh
. "$DOGMA_DECISION_LIB_DIR/lib-credo.sh"

# The text added to a reason when an ask becomes a deny in an unattended run
DOGMA_UNATTENDED_HINT="[unattended] No human can answer a confirmation prompt in this autonomous run, so dogma denies instead of asking. Retry in a form that needs no prompt: literal paths (no \$var targets), the Edit or Write tool per file instead of shell loops with sed -i, redirects only into the session TMPDIR or scratchpad, long compound commands split into small ones. If the step really needs the owner, note it for the owner and go on with other work."

# JSON string body: backslashes and quotes escaped, control characters (a raw tab or
# newline would break the JSON) become spaces.
dogma_json_text() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\"/\\\"}"
    text="${text//[[:cntrl:]]/ }"
    printf '%s' "$text"
}

# Print one PreToolUse decision (ask or deny) with its reason.
dogma_emit_decision() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
        "$1" "$(dogma_json_text "$2")"
}

# The hint for a git add/commit/push the owner must confirm ([?]): in an autonomous run that is a
# showstopper per credo (work cannot be secured), so the agent warns via ntfy and stops.
# Usage: dogma_unattended_git_hint <op>
dogma_unattended_git_hint() {
    printf '[unattended] git %s needs the owner'"'"'s OK here (DOGMA [?]); per credo this is a showstopper in an autonomous run: warn the owner via ntfy (credo-ntfy-send.sh) and stop instead of building on unsaved work.' "$1"
}

# Print the decision for a confirmation the hook wants: "ask", or "deny" with the
# reason plus a hint when no human can answer: the given hint, else DOGMA_UNATTENDED_HINT.
# Does not exit.
# Usage: dogma_emit_ask <input> <reason> [hint]
dogma_emit_ask() {
    local input="$1" reason="$2" hint="${3:-$DOGMA_UNATTENDED_HINT}"
    if [ "${CLAUDE_MB_DOGMA_UNATTENDED_DENY:-true}" = "true" ] && dogma_credo_unattended "$input"; then
        dogma_emit_decision deny "$reason $hint"
        return 0
    fi
    dogma_emit_decision ask "$reason"
}
