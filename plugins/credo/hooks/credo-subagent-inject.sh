#!/usr/bin/env bash
# credo-subagent-inject.sh - credo plugin (SubagentStart hook)
#
# Purpose: subagent self-sufficiency. Even a main agent that only delegates gets
# correct results because every subagent is primed at start with the load-bearing
# credo rules, independently of the (possibly context-rotted) main agent. This hook
# injects a compact rule block into each subagent's conversation before its first
# prompt via hookSpecificOutput.additionalContext, the mechanism documented for the
# SubagentStart event. It complements the credo skill descriptions, which are
# written to auto-trigger inside subagents as well.
#
# Event: SubagentStart. Fires when a subagent is spawned via the Agent tool. The
# stdin JSON carries session_id, cwd, hook_event_name, agent_id and agent_type.
# This hook applies to ALL subagent types (no matcher in hooks.json), so it primes
# every delegated agent. It cannot block subagent creation - it only adds context.
#
# Pattern mirrors the sibling session-mode-inject.sh: emit the injection JSON with
# jq, keep it out of the user chat with suppressOutput.
#
# Failure-safe: ANY problem -> exit 0 with no output. Never disrupt a subagent.

# --- toggle (default on) ---
[[ "${CREDO_SUBAGENT_INJECT:-true}" == "true" ]] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

# --- read hook stdin (not strictly required, but drain it and stay failure-safe) ---
INPUT=$(cat 2>/dev/null) || exit 0
[[ -n "$INPUT" ]] || exit 0

# agent_type is available for future filtering; every subagent is primed today.
agent_type=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null) || agent_type=""
[[ "$agent_type" == "null" ]] && agent_type=""

# --- the credo rule block injected into every subagent ---
read -r -d '' rules <<'RULES'
credo rules apply inside this subagent, independently of the main agent - follow them yourself, do not assume the main agent already handled them.

SECURITY (inherited, non-negotiable): install nothing (no pip, npm, apt, system or global packages) without explicit user approval; never read secrets or credentials (.env files, keys, tokens, credentials files, shell history); never delete /, /home, ~, $HOME, a parent of the working directory, or any mounted filesystem or device; no rm -rf upward traversal, no mkfs, dd, or wipefs; never delete local files without explicit user confirmation; when in doubt about a deletion target, STOP and ASK. Load the safety skill before any delete or install.

QUALITY GATES: if you build or touch a runtime or UI surface, prove it by driving the real thing in a browser and measuring computed layout before you claim it is done - a passing test, a served file, a node check, or a code review is NOT proof (verify skill).__ITEM_CLAUSE__ Log any requirement, decision, or GO you receive word-for-word before acting on it (requirements-verbatim skill).

HONESTY: admit uncertainty, never guess or fabricate; verify before claiming something works.

DELEGATION: if you spawn your own helpers they inherit this same security and run at a model at least as capable as yours, never weaker (orchestration skill). If you hit a blocking decision you cannot resolve, return {status: needs_decision, question: ...} instead of guessing.

OUTPUT HYGIENE: no curly quotes, no double hyphens in prose, no ellipsis character, no emojis in code or logs; ASCII identifiers only.

The relevant credo skills above auto-trigger when they apply - use them.
RULES

# --- task-backend gate (fail-safe) ---
# Resolved via credo-config.sh: env CREDO_TASK_BACKEND override (set + non-empty)
# > merged config task_backend (.credo/config cascade) > credo default. Any error
# falls back to credo. Only backend=gsd stands the credo item model down: the
# item/audit sentence is dropped from the priming. Security, quality (verify),
# honesty, delegation, and output-hygiene rules ALWAYS stay in - they are unconditional.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || HOOK_DIR=""
backend="$("$HOOK_DIR/../scripts/credo-config.sh" backend 2>/dev/null || echo credo)"
[[ -n "$backend" ]] || backend="credo"
if [[ "$backend" == "gsd" ]]; then
    item_clause=""
else
    item_clause=" Record and gate work as a credo item; work counts as done only after the mandatory post-completion audit gate, with docs updated in the same change (items and audit skills)."
fi
rules="${rules/__ITEM_CLAUSE__/$item_clause}"

status="[credo] ${rules}"

jq -n --arg ctx "$status" \
    '{hookSpecificOutput: {hookEventName: "SubagentStart", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null

exit 0
