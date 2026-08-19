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

# agent_type drives filtering: the built-in read-only agents Explore and Plan get a
# lighter priming (only the fresh [credo-now] line, see below); every other type gets
# the full rule block. Unknown/empty agent_type -> full block (safe default).
agent_type=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null) || agent_type=""
[[ "$agent_type" == "null" ]] && agent_type=""

# session_id is used best-effort to read the statusline cache for live budget
# numbers; may differ from the main agent's session (then the cache is absent and
# we simply omit the budget part - the time part never depends on it).
session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || session_id=""
[[ "$session_id" == "null" ]] && session_id=""

# --- the credo rule block injected into every subagent ---
read -r -d '' rules <<'RULES'
credo rules apply inside this subagent, independently of the main agent - follow them yourself, do not assume the main agent already handled them.

SECURITY (inherited, non-negotiable): install nothing (no pip, npm, apt, system or global packages) without explicit user approval; never read secrets or credentials (.env files, keys, tokens, credentials files, shell history); never delete /, /home, ~, $HOME, a parent of the working directory, or any mounted filesystem or device; no rm -rf upward traversal, no mkfs, dd, or wipefs; never delete local files without explicit user confirmation; when in doubt about a deletion target, STOP and ASK. Load the safety skill before any delete or install.

QUALITY GATES: if you build or touch a runtime or UI surface, prove it by driving the real thing in a browser and measuring computed layout before you claim it is done - a passing test, a served file, a node check, or a code review is NOT proof (verify skill).__ITEM_CLAUSE__ Log any requirement, decision, or GO you receive word-for-word before acting on it (requirements-verbatim skill).

HONESTY: admit uncertainty, never guess or fabricate; verify before claiming something works.

DELEGATION: if you spawn your own helpers they inherit this same security and run at a model at least as capable as yours, never weaker (orchestration skill). If you hit a blocking decision you cannot resolve, return {status: needs_decision, question: ...} instead of guessing.

GIT: modify files only - do NOT run git add / git commit / git push (the main / task-build agent is the single owner of the working-tree index, which avoids a .git/index.lock race); if you believe a commit is warranted, report that back instead of committing.

OUTPUT HYGIENE: no curly quotes; no ellipsis character (use ...); no emojis in code or logs; ASCII identifiers only; double hyphens (--) only where changing to - would break functionality (CLI flags, argument separators), everywhere in prose use -; no AI-filler phrases (Let me..., I'll..., Sure!, Certainly!).

LANGUAGE: follow the project's own language rules if any exist (read them). If none exist, match the language already established in the file you touch (file-local convention wins). If unclear, write everything in English including code comments; use another language only where deliberately required (UI strings, translation files). Exception: credo items themselves are written in the user's configured language if set, otherwise English.__LANG_CLAUSE__

The relevant credo skills above auto-trigger when they apply - use them.
RULES

# --- agent_type filtering (fail-safe) ---
# Explore and Plan are read-only built-ins that emit only a report to the main agent,
# no persistent code/output - so the heavy build/output/quality block is noise for
# them; they get only the fresh [credo-now] line below. Any other type (general-purpose,
# custom, empty/unknown) gets the full block. Unknown/empty -> full block (safe default).
case "$agent_type" in
    Explore|Plan) light_block=1 ;;
    *)            light_block=0 ;;
esac

status=""
if [[ "$light_block" -eq 0 ]]; then
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

    # --- language fill-in (best-effort, fail-safe) ---
    # HONESTY CAVEAT: the `language` key in settings.json is currently UNDOCUMENTED. It
    # works today but a future Claude Code version may rename or remove it, so this read
    # is best-effort with an English fallback and must NEVER fail the hook (jq presence is
    # already checked at top; missing files/keys just skip to the English fallback).
    # Precedence, highest first: project .claude/settings.local.json > project
    # .claude/settings.json > active-profile user settings. First non-empty hit wins.
    # PROFILE CORRECTNESS: the user runs multiple profiles (.claude and .claude-private).
    # The active profile is $CLAUDE_CONFIG_DIR, which is NOT necessarily $HOME/.claude -
    # so the user-level read must use $CLAUDE_CONFIG_DIR/settings.json; falling back to
    # $HOME/.claude on a .claude-private profile would read the WRONG settings.json.
    # $HOME/.claude/settings.json is only a last resort when CLAUDE_CONFIG_DIR is unset.
    proj_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
    if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
        user_settings="$CLAUDE_CONFIG_DIR/settings.json"
    else
        user_settings="$HOME/.claude/settings.json"
    fi
    lang=""
    for lf in \
        "$proj_dir/.claude/settings.local.json" \
        "$proj_dir/.claude/settings.json" \
        "$user_settings"; do
        [[ -f "$lf" ]] || continue
        lang=$(jq -r '.language // empty' "$lf" 2>/dev/null) || lang=""
        [[ "$lang" == "null" ]] && lang=""
        lang=$(printf '%s' "$lang" | tr -d '[:cntrl:]' 2>/dev/null) || lang=""
        [[ -n "$lang" ]] && break
    done
    if [[ -n "$lang" ]]; then
        lang_clause=" The user's configured language is ${lang} - write credo items in ${lang}."
    else
        lang_clause=" No configured language is set - the credo-items fallback is English."
    fi
    rules="${rules/__LANG_CLAUSE__/$lang_clause}"

    status="[credo] ${rules}"
fi

# --- fresh time + budget line (Fix B: a subagent must not inherit the main
#     agent's possibly frozen clock/limit values). The time is always current
#     (local date call). The budget numbers are best-effort from the statusline
#     per-session cache; absent (e.g. different session_id) -> time only. This
#     line is marked authoritative so the subagent prefers it over any older
#     [credo-time]/[limit] value carried in from the main agent's context. ---
now_line=$(date '+%Y-%m-%d %H:%M (%a), TZ %Z' 2>/dev/null) || now_line=""
if [[ -n "$now_line" ]]; then
    now_line=${now_line//\\/}; now_line=${now_line//\"/}
    now_line=$(printf '%s' "$now_line" | tr -d '[:cntrl:]' 2>/dev/null) || now_line=""
fi
if [[ -n "$now_line" ]]; then
    budget=""
    if [[ -n "$session_id" ]]; then
        case "$session_id" in
            *[!A-Za-z0-9._-]*) : ;;  # unsafe token -> skip cache read
            *)
                cache="/tmp/claude-mb-context-cache_${session_id}.json"
                if [[ -f "$cache" ]]; then
                    five_h=$(jq -r '.five_hour_pct // ""' "$cache" 2>/dev/null) || five_h=""
                    weekly=$(jq -r '.seven_day_pct // ""' "$cache" 2>/dev/null) || weekly=""
                    [[ "$five_h" == "null" ]] && five_h=""
                    [[ "$weekly" == "null" ]] && weekly=""
                    [[ -n "$five_h" ]] && budget="${budget} 5h ${five_h}%,"
                    [[ -n "$weekly" ]] && budget="${budget} Weekly ${weekly}%,"
                    budget="${budget%,}"
                fi
                ;;
        esac
    fi
    now_status="[credo-now] Current local time: ${now_line}."
    [[ -n "$budget" ]] && now_status="${now_status} Budget:${budget}."
    now_status="${now_status} Authoritative as of your start - use these, not any older time/budget values inherited from the main agent's context."
    if [[ -n "$status" ]]; then
        status="${status}"$'\n'"${now_status}"
    else
        status="${now_status}"
    fi
fi

# Nothing to inject (e.g. light block and the clock read failed) -> emit no output.
[[ -n "$status" ]] || exit 0

jq -n --arg ctx "$status" \
    '{hookSpecificOutput: {hookEventName: "SubagentStart", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null

exit 0
