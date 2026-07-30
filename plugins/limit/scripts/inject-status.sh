#!/usr/bin/env bash
# inject-status.sh - limit plugin
#
# Hook script for UserPromptSubmit + PostToolUse. It gives the running agent an
# autonomous, session-accurate view of its own resource usage so it can trigger
# a skill (e.g. a securing/compacting skill) on its own - even during long
# autonomous runs where no user prompts arrive.
#
# Source of truth: the per-session cache written by the statusline
# (/tmp/claude-mb-context-cache_${session_id}.json). The statusline is the only
# process Claude Code hands the context window data to, and it gets the canonical,
# mid-session-correct values straight from the latest API response:
#   - context_window_size (200k vs 1M, reflects model switches AND the 1M beta)
#   - the context fill percentage
#   - the 5h / weekly limits and session cost
# This hook just reads that file and injects a short status line into the agent's
# context via hookSpecificOutput.additionalContext (visible to the agent, does not
# flood the user chat).
#
# Throttled + delta-guarded: a routine status is injected at most every
# CLAUDE_MB_LIMIT_INJECT_INTERVAL seconds AND only when ctx/5h/weekly actually moved
# by >= CLAUDE_MB_LIMIT_INJECT_DELTA points since the last inject, so quiet phases do
# not grow the context with unchanged lines. Each threshold in
# CLAUDE_MB_LIMIT_INJECT_THRESHOLDS fires once regardless and adds an action hint to
# run CLAUDE_MB_LIMIT_COMPACT_SKILL.
#
# Failure-safe: any problem -> exit 0 with no output. Never disrupt the session.

# --- toggle (default on) ---
[[ "${CLAUDE_MB_LIMIT_INJECT:-true}" == "true" ]] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

# --- read hook stdin ---
INPUT=$(cat 2>/dev/null) || exit 0
[[ -n "$INPUT" ]] || exit 0

session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || session_id=""
event=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // "PostToolUse"' 2>/dev/null) || event="PostToolUse"
[[ "$session_id" == "null" ]] && session_id=""
[[ "$event" == "null" ]] && event="PostToolUse"
[[ -n "$session_id" ]] || exit 0
# Guard against path tricks in the session_id (must be a plain token) before it is
# interpolated into the /tmp cache/state paths - mirrors the sibling credo hooks.
case "$session_id" in
    *[!A-Za-z0-9._-]*) exit 0 ;;
esac

# --- config (env-overridable) ---
SKILL="${CLAUDE_MB_LIMIT_COMPACT_SKILL:-}"               # skill to run at thresholds (empty = generic hint only)
INTERVAL="${CLAUDE_MB_LIMIT_INJECT_INTERVAL:-120}"       # seconds between routine status injects
DELTA="${CLAUDE_MB_LIMIT_INJECT_DELTA:-1}"               # min change (pct points) in ctx/5h/weekly to re-inject a routine status (delta-guard)
THRESHOLDS="${CLAUDE_MB_LIMIT_INJECT_THRESHOLDS:-70,90}" # comma-separated context-fill % that trigger the skill (e.g. 33,66,92)
MAX_AGE="${CLAUDE_MB_LIMIT_INJECT_MAX_AGE:-300}"         # ignore the cache if older than this (statusline not rendering)

# --- read the statusline per-session cache (the canonical source) ---
meta_file="/tmp/claude-mb-context-cache_${session_id}.json"
[[ -f "$meta_file" ]] || exit 0

now=$(date +%s 2>/dev/null) || now=0

# Freshness: skip if the statusline has not refreshed the cache recently
updated_at=$(jq -r '.updated_at // ""' "$meta_file" 2>/dev/null) || updated_at=""
if [[ -n "$updated_at" && "$now" -gt 0 ]]; then
    upd_epoch=$(date -d "$updated_at" +%s 2>/dev/null) || upd_epoch=0
    if [[ "$upd_epoch" -gt 0 ]] && [[ $((now - upd_epoch)) -gt "$MAX_AGE" ]]; then
        exit 0
    fi
fi

ctx_pct=$(jq -r '.ctx_pct // empty' "$meta_file" 2>/dev/null) || ctx_pct=""
ctx_tokens=$(jq -r '.ctx_tokens // 0' "$meta_file" 2>/dev/null) || ctx_tokens=0
ctx_window=$(jq -r '.ctx_window // 0' "$meta_file" 2>/dev/null) || ctx_window=0
five_h=$(jq -r '.five_hour_pct // "?"' "$meta_file" 2>/dev/null) || five_h="?"
weekly=$(jq -r '.seven_day_pct // "?"' "$meta_file" 2>/dev/null) || weekly="?"
cost=$(jq -r '.session_cost // "?"' "$meta_file" 2>/dev/null) || cost="?"

# Need a usable percentage to say anything
[[ -n "$ctx_pct" ]] || exit 0
[[ "$ctx_tokens" =~ ^[0-9]+$ ]] || ctx_tokens=0
[[ "$ctx_window" =~ ^[0-9]+$ ]] || ctx_window=0

# --- parse thresholds (comma-separated, e.g. "70,90" or "33,66,92") ---
thresh_json=$(printf '%s' "$THRESHOLDS" | jq -R -c 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(test("^[0-9]+(\\.[0-9]+)?$")) | tonumber) | sort' 2>/dev/null)
[[ -n "$thresh_json" ]] || thresh_json='[]'

# --- throttle + threshold + delta state (per session) ---
state_file="/tmp/claude-mb-inject-state_${session_id}.json"
last_ts=0; fired_json='[]'; last_ctx=""; last_5h=""; last_weekly=""
if [[ -f "$state_file" ]]; then
    last_ts=$(jq -r '.last_ts // 0' "$state_file" 2>/dev/null) || last_ts=0
    fired_json=$(jq -c '.fired // []' "$state_file" 2>/dev/null) || fired_json='[]'
    [[ -n "$fired_json" ]] || fired_json='[]'
    last_ctx=$(jq -r '.last_ctx // ""' "$state_file" 2>/dev/null) || last_ctx=""
    last_5h=$(jq -r '.last_5h // ""' "$state_file" 2>/dev/null) || last_5h=""
    last_weekly=$(jq -r '.last_weekly // ""' "$state_file" 2>/dev/null) || last_weekly=""
    [[ "$last_ctx" == "null" ]] && last_ctx=""
    [[ "$last_5h" == "null" ]] && last_5h=""
    [[ "$last_weekly" == "null" ]] && last_weekly=""
fi
[[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0

# Delta-guard helper: prints "1" when a routine inject is warranted - either no
# prior value recorded yet (first routine inject) or any of ctx/5h/weekly moved by
# >= DELTA points. Non-numeric values (e.g. "?") never trigger and never block.
delta_exceeded() {
    awk -v c1="$1" -v l1="$2" -v c2="$3" -v l2="$4" -v c3="$5" -v l3="$6" -v d="$7" '
        function isnum(x){ return (x ~ /^-?[0-9]+(\.[0-9]+)?$/) }
        function chk(c,l){ if(!isnum(c)) return 0; if(!isnum(l)) return 1; return ((c-l>=d)||(l-c>=d)) }
        BEGIN{ if(chk(c1,l1)||chk(c2,l2)||chk(c3,l3)) print "1"; else print "0" }' 2>/dev/null
}

# Reset: drop fired thresholds the fill has fallen back below (e.g. after a compact)
fired_json=$(printf '%s' "$fired_json" | jq -c --argjson p "${ctx_pct:-0}" '[.[] | select(. <= $p)]' 2>/dev/null) || fired_json='[]'

# Highest crossed-but-not-yet-fired threshold
to_fire=$(printf '%s' "$thresh_json" | jq -r --argjson p "${ctx_pct:-0}" --argjson f "$fired_json" \
    '[.[] | select(. <= $p) | select(. as $t | ($f | index($t)) | not)] | max // empty' 2>/dev/null)

# Decide whether and what to inject
action=""; do_inject=false
if [[ -n "$to_fire" ]]; then
    if [[ -n "$SKILL" ]]; then
        action="Context-Fill >= ${to_fire}% - run ${SKILL} now to secure progress before an auto-compact."
    else
        action="Context-Fill >= ${to_fire}% - secure progress now (set CLAUDE_MB_LIMIT_COMPACT_SKILL to a skill to auto-run it here)."
    fi
    do_inject=true
    # Mark all currently crossed thresholds as fired (so lower ones do not re-fire)
    fired_json=$(printf '%s' "$thresh_json" | jq -c --argjson p "${ctx_pct:-0}" '[.[] | select(. <= $p)]' 2>/dev/null) || fired_json='[]'
elif [[ $((now - last_ts)) -ge "$INTERVAL" ]]; then
    # Routine inject only when a value actually moved (or nothing recorded yet),
    # so quiet phases do not accumulate a status line per interval.
    if [[ "$(delta_exceeded "$ctx_pct" "$last_ctx" "$five_h" "$last_5h" "$weekly" "$last_weekly" "$DELTA")" == "1" ]]; then
        do_inject=true
    fi
fi

[[ "$do_inject" == "true" ]] || exit 0

# Persist state (record the just-injected values so the delta-guard compares
# against what the model last actually saw)
tmp=$(mktemp 2>/dev/null) && {
    jq -n --argjson last_ts "${now:-0}" --argjson fired "$fired_json" \
        --arg last_ctx "${ctx_pct:-}" --arg last_5h "${five_h:-}" --arg last_weekly "${weekly:-}" \
        '{last_ts: $last_ts, fired: $fired, last_ctx: $last_ctx, last_5h: $last_5h, last_weekly: $last_weekly}' > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$state_file" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
}

# --- build the status string ---
fmt_tok() { awk "BEGIN {t=$1; if (t>=1000000) printf \"%.1fM\", t/1000000; else if (t>=1000) printf \"%.0fk\", t/1000; else printf \"%d\", t}" 2>/dev/null; }
status="[limit] Context ${ctx_pct}%"
if [[ "$ctx_tokens" -gt 0 && "$ctx_window" -gt 0 ]]; then
    status="${status} ($(fmt_tok "$ctx_tokens")/$(fmt_tok "$ctx_window"))"
fi
[[ "$five_h" != "?" ]] && status="${status} | 5h ${five_h}%"
[[ "$weekly" != "?" ]] && status="${status} | Weekly ${weekly}%"
[[ "$cost" != "?" ]] && status="${status} | \$${cost}"
if [[ -n "$action" ]]; then
    status="${status}"$'\n'"ACTION: ${action}"
fi

# --- emit additionalContext (suppressOutput so the user chat is not flooded) ---
jq -n --arg ev "$event" --arg ctx "$status" \
    '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null

exit 0
