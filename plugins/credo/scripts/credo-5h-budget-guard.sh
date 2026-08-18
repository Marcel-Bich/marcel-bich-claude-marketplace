#!/usr/bin/env bash
# credo-5h-budget-guard.sh - credo plugin (PreToolUse hook).
#
# Purpose: the HARD NET for autonomous 5h-budget pacing. It fires before every
# relevant tool call - in the MAIN agent AND inside every subagent - reads the
# live 5h utilization from the limit-plugin cache, and applies a two-track
# threshold ladder (concept: docs/TODO-credo-5h-budget-guard-concept.md,
# sections 4-8). In the soft zone it INJECTS a concrete recommendation without
# blocking; in the hard zone it BLOCKS the tool calls that are not allowed at
# that stage, so a parallel burst can no longer overshoot the Anthropic 5h cap.
#
# Scope: ONLY autonomous runs (credo-autonomy-active flag set). active/passive/
# normal sessions are completely unaffected (clean no-op / allow). Without the
# limit plugin present, or without a fresh cache, it never disturbs a tool call.
#
# Data sources (display values only, NEVER credentials):
#   - credo-budget-read.sh  (sibling)  -> five_hour_utilization from the cache.
#   - refresh-usage.sh (limit plugin)  -> best-effort cache warm-keeping, time
#     throttled; its output/exit is ignored and never surfaced.
#
# I/O follows the documented PreToolUse contract (hooks.md):
#   deny  -> stdout JSON hookSpecificOutput{hookEventName:PreToolUse,
#            permissionDecision:"deny", permissionDecisionReason:<why + what is
#            allowed now>}, exit 0.
#   soft/allowed context -> non-blocking additionalContext (see emit_context),
#            exit 0. The tool call proceeds.
#   no decision -> exit 0 with no output (normal permission flow).
#
# Failure-safe: ANY unexpected problem -> allow the tool (exit 0, no output).
# A budget guard must never break tool calls because of its own error; only the
# intentional threshold denies ever block.
#
# Security: reads ONLY display-value caches via credo-budget-read.sh and triggers
# refresh-usage.sh (which owns the token in isolation). This script never reads a
# credential/token and never prints one. No `set -x` (parity with refresh-usage).

set -euo pipefail

# --- toggle (default on) -----------------------------------------------------
[[ "${CREDO_5H_GUARD:-true}" == "true" ]] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# =============================================================================
# GATE 1 - autonomous only. Without the autonomy flag this hook is a pure no-op.
# =============================================================================
[[ -f "$CONFIG_DIR/credo-autonomy-active" ]] || exit 0

# Deliberate opt-out (credo-autonomy-off) -> stand down like the keep-alive hook.
[[ -f "$CONFIG_DIR/credo-autonomy-paused" ]] && exit 0

# --- read hook stdin ---------------------------------------------------------
INPUT=$(cat 2>/dev/null) || exit 0
[[ -n "$INPUT" ]] || exit 0

tool_name=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || tool_name=""
agent_id=$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null) || agent_id=""
cmd=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null) || cmd=""
fpath=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || fpath=""
[[ "$tool_name" == "null" ]] && tool_name=""
[[ "$agent_id" == "null" ]] && agent_id=""
[[ "$cmd" == "null" ]] && cmd=""
[[ "$fpath" == "null" ]] && fpath=""

# TRACK: a present agent_id means we run INSIDE a subagent; absent -> main agent.
if [[ -n "$agent_id" ]]; then
    TRACK="sub"
else
    TRACK="main"
fi

# =============================================================================
# GATE 2 - resolve the limit plugin install path. Without limit -> no-op/allow.
# =============================================================================
resolve_limit_path() {
    local reg="$CONFIG_DIR/plugins/installed_plugins.json"
    local p=""
    if [[ -f "$reg" ]]; then
        p=$(jq -r '
            (.plugins["limit@marcel-bich-claude-marketplace"] // [])
            | (map(select(.installPath and (.installPath|type=="string"))) )
            | (.[0].installPath // "")
        ' "$reg" 2>/dev/null) || p=""
        [[ "$p" == "null" ]] && p=""
    fi
    if [[ -n "$p" && -d "$p" ]]; then
        printf '%s\n' "$p"
        return 0
    fi
    # Fallback: highest semver under the marketplace cache.
    local base="$CONFIG_DIR/plugins/cache/marcel-bich-claude-marketplace/limit"
    if [[ -d "$base" ]]; then
        local newest
        newest=$(ls -1d "$base"/*/ 2>/dev/null \
            | sed 's:/*$::' \
            | awk -F/ '{print $NF}' \
            | sort -V \
            | tail -1) || newest=""
        if [[ -n "$newest" && -d "$base/$newest" ]]; then
            printf '%s\n' "$base/$newest"
            return 0
        fi
    fi
    return 1
}

LIMIT_PATH=""
LIMIT_PATH=$(resolve_limit_path) || LIMIT_PATH=""
[[ -n "$LIMIT_PATH" ]] || exit 0   # no limit plugin -> never disturb a tool call

# =============================================================================
# REFRESH TRIGGER - time-throttled cache warm-keeping. Best-effort, output and
# exit ignored. refresh-usage.sh itself has flock + a 60s floor; the extra ~30s
# marker here just avoids spawning a process on every single tool call.
# =============================================================================
PROFILE_NAME="$(basename "$CONFIG_DIR")"
REFRESH_MARKER="/tmp/claude-mb-credo-guard-refresh_${PROFILE_NAME}"
REFRESH_THROTTLE="${CREDO_GUARD_REFRESH_THROTTLE_SECONDS:-30}"

maybe_refresh() {
    local refresh_sh="$LIMIT_PATH/scripts/refresh-usage.sh"
    [[ -x "$refresh_sh" ]] || return 0
    local do_it="yes" mtime now age
    if [[ -f "$REFRESH_MARKER" ]]; then
        mtime=$(stat -c %Y "$REFRESH_MARKER" 2>/dev/null || stat -f %m "$REFRESH_MARKER" 2>/dev/null) || mtime=0
        now=$(date +%s 2>/dev/null) || now=0
        age=$((now - mtime))
        [[ "$age" -lt "$REFRESH_THROTTLE" ]] && do_it="no"
    fi
    if [[ "$do_it" == "yes" ]]; then
        touch "$REFRESH_MARKER" 2>/dev/null || true
        # Fully detached and silenced - never let its status/exit reach the model.
        "$refresh_sh" >/dev/null 2>&1 || true
    fi
    return 0
}
maybe_refresh || true

# =============================================================================
# READ STATE - five_hour_utilization via credo-budget-read.sh (stricter max age).
# =============================================================================
BUDGET_READ="$SCRIPT_DIR/credo-budget-read.sh"
[[ -x "$BUDGET_READ" ]] || exit 0

MAX_AGE="${CREDO_GUARD_MAX_AGE_SECONDS:-180}"

set +e
raw=$(CREDO_BUDGET_MAX_AGE_SECONDS="$MAX_AGE" "$BUDGET_READ" 2>/dev/null)
read_rc=$?
set -e

# --- emitters (documented PreToolUse contract) -------------------------------
emit_deny() {
    # Hard-zone block. permissionDecisionReason is shown to the model on deny.
    jq -n --arg r "$1" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
    exit 0
}

emit_context() {
    # Non-blocking recommendation/notice. Uses hookSpecificOutput.additionalContext
    # (the documented PreToolUse context-injection field); the tool call proceeds.
    jq -n --arg c "$1" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c},suppressOutput:true}' 2>/dev/null
    exit 0
}

# Throttled variant for the SOFT/advisory stages only. Per (track, stage) marker
# under /tmp: inject only if the marker is older than the interval, else stay
# SILENT (exit 0, tool proceeds) so a long autonomous run is not flooded. A stage
# change (e.g. 83 -> 87) has its own marker, so the new stage injects immediately.
# NEVER used for deny (hard blocks fire on every call) nor for the hard-zone
# allowed-action notices (those stay unthrottled by design).
emit_context_throttled() {
    local ctx="$1" key="$2" interval="$3"
    local marker="/tmp/claude-mb-credo-guard-soft_${PROFILE_NAME}_${key}"
    if [[ -f "$marker" ]]; then
        local mtime now age
        mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null) || mtime=0
        now=$(date +%s 2>/dev/null) || now=0
        age=$((now - mtime))
        [[ "$age" -lt "$interval" ]] && exit 0   # too soon -> silent, tool proceeds
    fi
    touch "$marker" 2>/dev/null || true
    emit_context "$ctx"
}

# exit 3 = no cache -> cannot decide -> allow silently (never disturb).
[[ "$read_rc" -eq 3 ]] && exit 0

# exit 4 = STALE -> SOFT warning only, NEVER a hard block on unsure data.
if [[ "$read_rc" -eq 4 ]]; then
    emit_context "[5h ?] Budget state unclear (limit cache stale, older than ${MAX_AGE}s). Work conservatively: no large new subagents/fan-outs/builds; prefer small units. No hard block on uncertain data."
fi

# any other non-zero (hard error) -> allow silently.
[[ "$read_rc" -eq 0 ]] || exit 0

# --- parse utilization -------------------------------------------------------
util=$(printf '%s\n' "$raw" | awk -F= '/^five_hour_utilization=/{print $2; exit}') || util=""
# Not a plain number (e.g. "None") -> cannot decide -> allow silently.
[[ "$util" =~ ^[0-9]+(\.[0-9]+)?$ ]] || exit 0

# integer percent for display
util_disp=$(awk -v u="$util" 'BEGIN{printf "%d", u}') || util_disp="$util"

# =============================================================================
# LADDER (from config, with concept defaults). The NUMBERS are config-tunable;
# the SEMANTICS per position are fixed by the concept (sections 5a/5b/6).
# =============================================================================
CONFIG="$SCRIPT_DIR/credo-config.sh"

read_ladder() {
    local key="$1"; shift
    local -a def=("$@")
    local out rc
    set +e
    out=$(CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}" "$CONFIG" get "$key" 2>/dev/null)
    rc=$?
    set -e
    if [[ $rc -ne 0 || -z "$out" ]]; then
        printf '%s\n' "${def[@]}"
        return 0
    fi
    printf '%s\n' "$out"
}

mapfile -t MAIN_LADDER < <(read_ladder budget.autonomous_5h.main_ladder 83 87 90 92 97) || MAIN_LADDER=(83 87 90 92 97)
mapfile -t SUB_LADDER  < <(read_ladder budget.autonomous_5h.subagent_ladder 83 90 92) || SUB_LADDER=(83 90 92)

# validate: exact length + all numeric, else fall back to concept defaults.
valid_ladder() {
    local want="$1"; shift
    [[ "$#" -eq "$want" ]] || return 1
    local v
    for v in "$@"; do
        [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
    done
    return 0
}
valid_ladder 5 "${MAIN_LADDER[@]}" || MAIN_LADDER=(83 87 90 92 97)
valid_ladder 3 "${SUB_LADDER[@]}"  || SUB_LADDER=(83 90 92)

# --- float compare: ge a b  -> exit 0 iff a >= b -----------------------------
ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }

# --- tool / command classification ------------------------------------------
is_spawn() { [[ "$1" == "Task" || "$1" == "Agent" ]]; }

is_git_cmd() {
    # Allowed only when git is a COMMAND WORD (at the start, or directly after a
    # && / ; / | separator, with optional leading "cd ... &&|;" segments) followed
    # by a real git subcommand. So "cd /p && git commit -m x" and "cd x; git push"
    # are allowed, while a command that merely CONTAINS the word git (e.g.
    # "rm foo && echo git") stays blocked. Pattern kept deliberately narrow.
    local c="$1"
    printf '%s' "$c" | grep -Eq \
        '(^|&&|;|\|)[[:space:]]*git[[:space:]]+(commit|push|add|status|log|diff|show|fetch|pull|rev-parse|remote|branch|tag|config|describe|stash|restore)([[:space:]]|$)' \
        2>/dev/null
}

is_wake_cmd() {
    case "$1" in
        *credo-autonomy-wake-mark*|*credo-autonomy-off*) return 0 ;;
    esac
    return 1
}

is_credo_path() {
    case "$1" in
        .credo/*|*/.credo/*) return 0 ;;
    esac
    return 1
}

# =============================================================================
# DECISION
# =============================================================================
if [[ "$TRACK" == "main" ]]; then
    T0="${MAIN_LADDER[0]}" T1="${MAIN_LADDER[1]}" T2="${MAIN_LADDER[2]}" T3="${MAIN_LADDER[3]}" T4="${MAIN_LADDER[4]}"

    if ge "$util" "$T4"; then
        # ---- 97% LOCKDOWN: only the resume-wakeup path survives -------------
        if [[ "$tool_name" == "Bash" ]] && is_wake_cmd "$cmd"; then
            emit_context "[5h ${util_disp}%] LOCKDOWN (main >=${T4}%). Only the resume wakeup is allowed: set ScheduleWakeup for the 5h reset, mark it with credo-autonomy-wake-mark.sh, then stop. Nothing after that."
        fi
        emit_deny "[5h ${util_disp}%] LOCKDOWN (main >=${T4}%). STOP. ONLY the resume wakeup is still allowed: set ScheduleWakeup for the 5h reset, mark it with credo-autonomy-wake-mark.sh, then stop. Drop EVERYTHING else immediately - including an open commit/push. This tool call (${tool_name}) is blocked."

    elif ge "$util" "$T3"; then
        # ---- 92% HARD: only organizational actions allowed ------------------
        if is_spawn "$tool_name"; then
            emit_deny "[5h ${util_disp}%] HARD (main >=${T3}%). No new subagents. Now ONLY: stop running subagents via TaskStop, commit/push results (Bash 'git ...'), write .credo/process/resume-after-reset.md, update task status, set ScheduleWakeup. A new agent spawn (${tool_name}) is blocked."
        fi
        if [[ "$tool_name" == "Bash" ]]; then
            if is_git_cmd "$cmd" || is_wake_cmd "$cmd"; then
                emit_context "[5h ${util_disp}%] HARD (main >=${T3}%). This organizational action (git/commit/push or wake) is allowed. Do not start anything new/heavy - only finish, secure, prepare resume, set wakeup."
            fi
            emit_deny "[5h ${util_disp}%] HARD (main >=${T3}%). Only organizational Bash actions are allowed (git commit/push, credo-autonomy-wake-mark/off). This Bash call is blocked. Now: secure, write .credo/process/resume-after-reset.md, set ScheduleWakeup."
        fi
        if [[ "$tool_name" == "Edit" || "$tool_name" == "Write" || "$tool_name" == "MultiEdit" || "$tool_name" == "NotebookEdit" ]]; then
            if is_credo_path "$fpath"; then
                emit_context "[5h ${util_disp}%] HARD (main >=${T3}%). Writing under .credo/ (resume block/task status) is allowed. Do not start anything new/heavy."
            fi
            emit_deny "[5h ${util_disp}%] HARD (main >=${T3}%). Only writing under .credo/ (resume block, task status) is allowed. This write call to '${fpath}' is blocked."
        fi
        # any other matched tool (WebFetch/WebSearch/...) -> block.
        emit_deny "[5h ${util_disp}%] HARD (main >=${T3}%). New/heavy work is blocked. Still allowed: TaskStop, git commit/push, .credo/ writes, ScheduleWakeup, wakeup mark. This tool call (${tool_name}) is not one of those."

    elif ge "$util" "$T2"; then
        emit_context_throttled "[5h ${util_disp}%] (main) Bring in subagent results + secure them (commit/push). Prepare the resume block (.credo/process/resume-after-reset.md). Do not start anything new. Hard net from ${T3}%." "main_90" 30
    elif ge "$util" "$T1"; then
        emit_context_throttled "[5h ${util_disp}%] (main) Actively tell running subagents via SendMessage to pause soon (wrap up + report back, do NOT kill them). Yourself, nothing new except finishing/committing small units. Hard net from ${T3}%." "main_87" 60
    elif ge "$util" "$T0"; then
        emit_context_throttled "[5h ${util_disp}%] Soft cap (main). No large new subagents/fan-outs/explores/parallel bursts anymore. Only small targeted subagents (one file / one lookup / one small fix, roughly < 40-60k tokens) OR do small changes yourself directly. Finish running subagents. You decide by judgment; hard net from ${T3}%." "main_83" 120
    fi
    # below T0 -> no output, normal flow.
    exit 0

else
    # ---- SUBAGENT track: 83 soft / 90 hard / 92 hard -----------------------
    S0="${SUB_LADDER[0]}" S1="${SUB_LADDER[1]}" S2="${SUB_LADDER[2]}"

    if ge "$util" "$S2"; then
        # >=92: stop now, minimal report, end. Block every matched tool.
        emit_deny "[5h ${util_disp}%] HARD (subagent >=${S2}%). Stop immediately: write a minimal report to the main agent (done / open / next steps) and end yourself. Further tools (${tool_name}) are blocked."
    elif ge "$util" "$S1"; then
        # >=90: only minimal completion - deny the expensive tools.
        if is_spawn "$tool_name" || [[ "$tool_name" == "WebFetch" || "$tool_name" == "WebSearch" ]]; then
            emit_deny "[5h ${util_disp}%] HARD (subagent >=${S1}%). Finish immediately: finalize only the minimal current step, write unfinished work + next steps into your report to the main agent, then end. Expensive tools (${tool_name}) are blocked."
        fi
        emit_context "[5h ${util_disp}%] HARD (subagent >=${S1}%). Finalize only the minimal current step, then report to the main agent (done / open / next steps) and end. No more expensive tools/new steps."
    elif ge "$util" "$S0"; then
        emit_context_throttled "[5h ${util_disp}%] Soft cap (subagent). Within your task, do not start anything big/new (no broad sweeps, no additional expensive steps). Head straight for a clean completion of your specific task. Hard net from ${S1}%." "sub_83" 120
    fi
    # below S0 -> no output, normal flow.
    exit 0
fi
