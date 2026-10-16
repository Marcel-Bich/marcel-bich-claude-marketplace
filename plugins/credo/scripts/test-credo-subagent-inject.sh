#!/usr/bin/env bash
# Tests for hooks/credo-subagent-inject.sh: the injected rule block carries the
# no-delete rule for every full-block subagent, and the light block (Explore, Plan)
# stays light.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/credo-subagent-inject.sh"
SID="11111111-2222-3333-4444-555555555555"

pass=0
fail=0
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/cfg"
export CLAUDE_PROJECT_DIR="$TMP/proj"
export CREDO_TASK_BACKEND=credo
mkdir -p "$CLAUDE_PROJECT_DIR"
cd "$TMP" || exit 1

check() { # name, want, got
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $1 (want $2, got $3)"
    fi
}

# ctx_of <agent_type>: the additionalContext the hook injects ("" when none)
ctx_of() {
    jq -n --arg t "$1" --arg s "$SID" '{session_id: $s, agent_type: $t, hook_event_name: "SubagentStart"}' \
        | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}

# has <name> <phrase> <context>: the phrase occurs literally in the context
has() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        check "$1" yes yes
    else
        check "$1" yes no
    fi
}

NO_DELETE="Never run a delete (rm, rm -rf, find -delete, unlink) whose target path contains a shell variable"
VAR_FORMS='($X, ${X} or $(...))'
LITERAL_PATH="Write the literal path instead"
NEW_DIR="create a NEW literal scratch dir"
PROMPT_RISK="can raise a permission prompt that blocks the whole run"

# --- full block: general-purpose subagent carries the narrowed no-delete rule -------
gp_ctx="$(ctx_of general-purpose)"
has "general-purpose: variable-target delete rule present" "$NO_DELETE" "$gp_ctx"
has "general-purpose: variable forms named" "$VAR_FORMS" "$gp_ctx"
has "general-purpose: literal path instead" "$LITERAL_PATH" "$gp_ctx"
has "general-purpose: new scratch dir instead" "$NEW_DIR" "$gp_ctx"
has "general-purpose: unattended prompt risk named" "$PROMPT_RISK" "$gp_ctx"
has "general-purpose: security rule still present" "SECURITY (inherited, non-negotiable)" "$gp_ctx"

# --- full block: unknown or empty agent_type gets the same rule ---------------------
empty_ctx="$(ctx_of "")"
has "empty agent_type: no-delete rule present" "$NO_DELETE" "$empty_ctx"

# --- light block: Explore and Plan keep only the time line --------------------------
explore_ctx="$(ctx_of Explore)"
case "$explore_ctx" in
    *"$NO_DELETE"*) check "Explore: light block has no full rule set" no yes ;;
    *) check "Explore: light block has no full rule set" no no ;;
esac
case "$explore_ctx" in
    *"[credo-now]"*) check "Explore: fresh time line kept" yes yes ;;
    *) check "Explore: fresh time line kept" yes no ;;
esac

# --- output shape: SubagentStart JSON, no chat output -------------------------------
raw="$(jq -n --arg s "$SID" '{session_id: $s, agent_type: "general-purpose", hook_event_name: "SubagentStart"}' \
    | bash "$HOOK" 2>/dev/null)"
check "output event name is SubagentStart" SubagentStart \
    "$(printf '%s' "$raw" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)"
check "output is suppressed from the chat" true \
    "$(printf '%s' "$raw" | jq -r '.suppressOutput' 2>/dev/null)"

echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
