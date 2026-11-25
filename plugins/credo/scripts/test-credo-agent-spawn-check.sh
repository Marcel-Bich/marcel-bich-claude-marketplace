#!/usr/bin/env bash
# Tests for hooks/credo-agent-spawn-check.sh + scripts/credo-preset-guard.py: the PreToolUse
# guard on Agent and Task calls. The active preset is a minimum: a spawn below every rung of
# the ladders that fit its kind (Explore/Plan -> explore; others -> build/review/hard) is
# denied, as is a missing model or effort; an equal pair passes, a stronger pair passes with a
# visible "stronger than preset" line. A fork passes only when the parent's model is >= a rung
# model. "preset exception:" lines from .credo/RULES.md and valid owner handoff rules with an
# until date may allow a weaker pair. Silent without a configured preset; fails open on
# internal errors.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/credo-agent-spawn-check.sh"

pass=0
fail=0
TMP="$(mktemp -d)"
trap '[ -n "$TMP" ] && rm -rf -- "$TMP"' EXIT
unset CLAUDE_CONFIG_DIR CLAUDE_PLUGIN_ROOT CLAUDE_CODE_SESSION_ID CREDO_CONFIG_STDLIB_YAML
unset CREDO_SESSION_ID CREDO_SESSION_PROJECTS_DIR CREDO_DIR CREDO_TASK_BACKEND
export CREDO_GLOBAL="$TMP/global/config"
export CREDO_PROFILE=""
export CREDO_PROJECT="$TMP/project/.credo/config"
export CREDO_AGENT_SPAWN_CHECK=1
export CREDO_PRESET_GUARD_TODAY=2030-06-15
export CREDO_PRESET_GUARD_LOG="$TMP/guard.log"
mkdir -p "$TMP/project/.credo" "$TMP/q/.credo"
printf 'preset: balanced\n' > "$CREDO_PROJECT"
QUALITY="$TMP/q/.credo/config"
printf 'preset: quality\n' > "$QUALITY"

# a repo without .credo files for the plain cases
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

check() { # name want got
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $1 (want $2, got $3)"
    fi
}

has() { # name needle haystack
    case "$3" in
        *"$2"*) pass=$((pass + 1)) ;;
        *) fail=$((fail + 1)); echo "FAIL: $1 (missing: $2)" ;;
    esac
}

# call <tool name> <tool_input JSON> [cwd] [transcript] [agent_id]: the PreToolUse hook input
call() {
    jq -n --arg t "$1" --argjson i "$2" --arg c "${3:-$REPO}" --arg tp "${4:-}" --arg a "${5:-}" \
        '{session_id: "11111111-2222-3333-4444-555555555555", hook_event_name: "PreToolUse",
          cwd: $c, tool_name: $t, tool_input: $i}
         + (if $tp != "" then {transcript_path: $tp} else {} end)
         + (if $a != "" then {agent_id: $a} else {} end)'
}

# run_hook <hook input>: raw hook stdout
run_hook() { printf '%s' "$1" | bash "$HOOK" 2>/dev/null; }
decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null; }
reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }
ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }
sysmsg() { printf '%s' "$1" | jq -r '.systemMessage // ""' 2>/dev/null; }

LADDER_BAL='explore: 1+ haiku/low; build: 1+ haiku/xhigh; review: 1+ haiku/xhigh; hard: 1-2 haiku/xhigh, 3-7 opus/medium, attempt 8 back-to-human'

# --- equal to a rung ------------------------------------------------------------------
out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","model":"haiku","effort":"xhigh"}')")"
check "build rung haiku/xhigh: allowed" allow "$(decision "$out")"
has "equal: short advisory" "[credo-preset] ok: haiku/xhigh is a rung of the build/review/hard roles (preset balanced)" "$(ctx "$out")"
check "equal: no visible line" "" "$(sysmsg "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","model":"opus","effort":"medium"}')")"
check "hard attempt-3 rung opus/medium: allowed" allow "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"claude-opus-5-5","effort":"medium"}')")"
check "full model id maps to the alias: allowed" allow "$(decision "$out")"

# --- stronger than a rung -------------------------------------------------------------
out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","model":"opus","effort":"xhigh"}')")"
check "stronger opus/xhigh: allowed" allow "$(decision "$out")"
has "stronger: line names the covered rungs" "stronger than preset: opus/xhigh vs haiku/xhigh or opus/medium" "$(ctx "$out")"
has "stronger: visible system message" "stronger than preset: opus/xhigh" "$(sysmsg "$out")"
out="$(run_hook "$(call Agent '{"model":"sonnet","effort":"max"}')")"
check "stronger sonnet/max (>= haiku/xhigh): allowed" allow "$(decision "$out")"
has "sonnet/max vs haiku/xhigh only" "stronger than preset: sonnet/max vs haiku/xhigh (" "$(ctx "$out")"
out="$(run_hook "$(call Agent '{"model":"fable","effort":"max"}')")"
check "fable ranks above opus: allowed" allow "$(decision "$out")"

# --- below the preset / missing -------------------------------------------------------
out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","model":"sonnet","effort":"medium"}')")"
check "weaker sonnet/medium: denied" deny "$(decision "$out")"
r="$(reason "$out")"
has "deny names the weakness" "sonnet/medium is below every rung of the build/review/hard roles" "$r"
has "deny lists the minimum pairs" "Minimum for the build/review/hard roles: one of haiku/xhigh, opus/medium" "$r"
has "deny names the lookup command" "credo-preset.sh stage <role> <attempt>" "$r"
has "deny shows the ladder" "Active ladder: $LADDER_BAL." "$r"
has "deny names the exception format" "preset exception: <all|role,...> -> <model>/<effort>" "$r"
out="$(run_hook "$(call Agent '{"model":"haiku","effort":"low"}')")"
check "explore-level pair on a build spawn: denied" deny "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"gpt-x","effort":"max"}')")"
check "unknown model: denied" deny "$(decision "$out")"
has "unknown model named" "unknown model gpt-x" "$(reason "$out")"

out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","model":"opus"}')")"
check "missing effort: denied" deny "$(decision "$out")"
has "missing effort: named" "(preset balanced): no effort." "$(reason "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","effort":"max"}')")"
check "missing model: denied" deny "$(decision "$out")"
has "missing model: named" "no model (it would inherit the parent's model)" "$(reason "$out")"
out="$(run_hook "$(call Task '{"subagent_type":"general-purpose"}')")"
check "Task tool name is checked too" deny "$(decision "$out")"
has "neither: both named" "no model (it would inherit the parent's model); no effort." "$(reason "$out")"

# --- Explore / Plan: explore role only ------------------------------------------------
out="$(run_hook "$(call Agent '{"subagent_type":"Explore","model":"haiku","effort":"low"}')")"
check "Explore on the explore rung: allowed" allow "$(decision "$out")"
has "Explore advisory names the explore role" "explore role (Explore)" "$(ctx "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"Plan","model":"opus","effort":"medium"}')")"
check "Plan stronger than explore: allowed" allow "$(decision "$out")"
has "Plan stronger line" "stronger than preset: opus/medium vs haiku/low" "$(ctx "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"Explore"}')")"
check "Explore without model/effort: denied" deny "$(decision "$out")"
out="$(CREDO_PROJECT="$QUALITY" run_hook "$(call Agent '{"subagent_type":"Explore","model":"haiku","effort":"low"}')")"
check "quality: Explore below haiku/xhigh: denied" deny "$(decision "$out")"
has "Explore deny lists only explore pairs" "Minimum for the explore role (Explore): one of haiku/xhigh" "$(reason "$out")"

# --- fork: parent model ---------------------------------------------------------------
TR="$TMP/sess.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"x"}}' \
    '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[]}}' \
    '{"type":"user","message":{"content":"y","model":"claude-haiku-5-5"}}' > "$TR"
out="$(run_hook "$(call Agent '{"subagent_type":"fork","prompt":"x"}' "$REPO" "$TR")")"
check "fork with an opus parent: allowed" allow "$(decision "$out")"
has "fork advisory: effort not checked" "fork ok: parent model opus" "$(ctx "$out")"
TR2="$TMP/sess2.jsonl"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5-5","content":[]}}' > "$TR2"
out="$(run_hook "$(call Agent '{"subagent_type":"fork"}' "$REPO" "$TR2")")"
check "balanced: fork with a sonnet parent (>= haiku): allowed" allow "$(decision "$out")"
out="$(CREDO_PROJECT="$QUALITY" run_hook "$(call Agent '{"subagent_type":"fork","model":"opus","effort":"max"}' "$REPO" "$TR2")")"
check "quality: fork with a sonnet parent (< opus): denied, call model ignored" deny "$(decision "$out")"
has "fork deny suggests a regular spawn" "Spawn a regular subagent" "$(reason "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"fork"}')")"
check "fork without a transcript: denied" deny "$(decision "$out")"
has "fork deny: parent unknown" "model (unknown)" "$(reason "$out")"
mkdir -p "$TMP/sess2/subagents"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[]}}' \
    > "$TMP/sess2/subagents/agent-abc123.jsonl"
out="$(CREDO_PROJECT="$QUALITY" run_hook "$(call Agent '{"subagent_type":"fork"}' "$REPO" "$TR2" abc123)")"
check "fork inside a subagent reads the subagent transcript (opus): allowed" allow "$(decision "$out")"

# --- RULES.md override (may allow a weaker pair) --------------------------------------
RR="$TMP/rulesrepo"
mkdir -p "$RR/.credo"
git -C "$RR" init -q
cat > "$RR/.credo/RULES.md" <<'MD'
# rules

```
preset exception: all -> haiku/low
```

- `preset exception: build, review -> haiku/high` | owner allows haiku high here
preset exception: explore -> haiku/medium
preset exception: nonsense -> sonnet/low
MD
out="$(run_hook "$(call Agent '{"model":"haiku","effort":"high"}' "$RR")")"
check "RULES.md override haiku/high for build: allowed" allow "$(decision "$out")"
has "override advisory names the source" "ok by preset exception (RULES.md): haiku/high" "$(ctx "$out")"
out="$(run_hook "$(call Agent '{"model":"haiku","effort":"medium"}' "$RR")")"
check "explore-scoped override does not widen build: denied" deny "$(decision "$out")"
has "deny lists the granted pair too" "haiku/high" "$(reason "$out")"
out="$(run_hook "$(call Agent '{"model":"haiku","effort":"low"}' "$RR")")"
check "override inside a code fence is ignored: denied" deny "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"sonnet","effort":"low"}' "$RR")")"
check "override with an unknown scope is ignored: denied" deny "$(decision "$out")"

# linked worktree: .credo lives in the main checkout
git -C "$RR" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$RR" worktree add -q "$TMP/rr-wt" -b wt 2>/dev/null
out="$(run_hook "$(call Agent '{"model":"haiku","effort":"high"}' "$TMP/rr-wt")")"
check "worktree cwd reads the main checkout RULES.md: allowed" allow "$(decision "$out")"

# --- handoff temporary rule -----------------------------------------------------------
HR="$TMP/handoffrepo"
mkdir -p "$HR/.credo/process/handoffs"
git -C "$HR" init -q
H="$HR/.credo/process/handoffs/HANDOFF.md"
cat > "$H" <<'MD'
# Handoff

## Rules (temporary)

- preset exception: build -> haiku/high | source: owner "haiku high for the refactor" (2030-06-01) | until: 2030-06-20
- preset exception: build -> haiku/medium | source: owner "haiku medium" (2030-06-01) | until: 2030-06-10
- preset exception: build -> sonnet/low | source: agent decision | until: 2030-06-20
- preset exception: build -> sonnet/medium | source: owner "sonnet medium" (2030-06-01) | until: the refactor is merged
- preset exception: build -> opus/low | source: owner "opus low" (2030-06-01)

## Notes

- preset exception: build -> haiku/low | source: owner "x" (2030-06-01) | until: 2030-06-20
MD
out="$(run_hook "$(call Agent '{"model":"haiku","effort":"high"}' "$HR")")"
check "valid owner handoff exception: allowed" allow "$(decision "$out")"
has "handoff advisory names the until" "ok by preset exception (handoff until 2030-06-20)" "$(ctx "$out")"
out="$(run_hook "$(call Agent '{"model":"haiku","effort":"medium"}' "$HR")")"
check "expired handoff exception: denied" deny "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"sonnet","effort":"low"}' "$HR")")"
check "agent-decision handoff exception: denied" deny "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"sonnet","effort":"medium"}' "$HR")")"
check "handoff exception without an until date: denied" deny "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"opus","effort":"low"}' "$HR")")"
check "handoff exception without until: denied" deny "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"haiku","effort":"low"}' "$HR")")"
check "exception outside Rules (temporary): denied" deny "$(decision "$out")"
out="$(CREDO_PRESET_GUARD_TODAY=2030-06-21 run_hook "$(call Agent '{"model":"haiku","effort":"high"}' "$HR")")"
check "handoff exception after its until date: denied" deny "$(decision "$out")"

# --- other preset ---------------------------------------------------------------------
out="$(CREDO_PROJECT="$QUALITY" run_hook "$(call Agent '{"model":"haiku","effort":"xhigh"}')")"
check "quality preset: haiku/xhigh below opus/medium: denied" deny "$(decision "$out")"
has "quality preset named" "(preset quality)" "$(reason "$out")"
out="$(CREDO_PROJECT="$QUALITY" run_hook "$(call Agent '{"model":"opus","effort":"max"}')")"
check "quality preset: opus/max stronger: allowed" allow "$(decision "$out")"

# --- no check -------------------------------------------------------------------------
out="$(CREDO_PROJECT="$TMP/none/.credo/config" run_hook "$(call Agent '{"model":"sonnet"}')")"
check "no preset configured: silent" "" "$out"
out="$(run_hook "$(call Bash '{"command":"ls"}')")"
check "Bash call is not checked" "" "$out"
out="$(CREDO_AGENT_SPAWN_CHECK=0 run_hook "$(call Agent '{"model":"sonnet"}')")"
check "CREDO_AGENT_SPAWN_CHECK=0: silent" "" "$out"
check "non-JSON input: silent" "" "$(run_hook 'not json at all')"
printf '' | bash "$HOOK" >/dev/null 2>&1
check "empty input: exit 0" 0 "$?"
printf '%s' "$(call Agent '{"model":"sonnet"}')" | bash "$HOOK" >/dev/null 2>&1
check "hook exits 0 on a deny" 0 "$?"

# --- internal error: fail open with a logged warning ----------------------------------
STUB="$TMP/stubplugin"
mkdir -p "$STUB/hooks" "$STUB/scripts"
cp "$HOOK" "$HERE/../hooks/credo-python-lib.sh" "$STUB/hooks/"
cp "$HERE/credo-preset-guard.py" "$HERE/credo-config.sh" "$HERE/credo-handoff-rules.py" "$STUB/scripts/"
printf '#!/bin/bash\necho garbage\n' > "$STUB/scripts/credo-preset.sh"
rm -f "$CREDO_PRESET_GUARD_LOG"
out="$(printf '%s' "$(call Agent '{"model":"sonnet"}')" | bash "$STUB/hooks/credo-agent-spawn-check.sh" 2>/dev/null)"
check "unparseable preset: fail open (silent)" "" "$out"
has "fail open writes a warning to the log" "spawn allowed unchecked" "$(cat "$CREDO_PRESET_GUARD_LOG" 2>/dev/null)"
BARE="$TMP/bareplugin"
mkdir -p "$BARE/hooks"
cp "$HOOK" "$BARE/hooks/"
out="$(printf '%s' "$(call Agent '{"model":"sonnet"}')" | bash "$BARE/hooks/credo-agent-spawn-check.sh" 2>/dev/null)"
check "no guard script: silent" "" "$out"

echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
