#!/usr/bin/env bash
# Tests for hooks/credo-agent-spawn-check.sh + scripts/credo-preset-guard.py: the PreToolUse
# guard on Agent and Task calls. It denies a spawn whose model/effort is no rung of the
# ladders that fit its kind (Explore/Plan -> explore; others -> build/review/hard), denies a
# missing model or effort, allows a fork only when the parent's model is a rung model, honours
# "preset exception:" lines from .credo/RULES.md and valid owner handoff rules with an until
# date, is silent without a configured preset and fails open on internal errors.
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
mkdir -p "$TMP/project/.credo"
printf 'preset: balanced\n' > "$CREDO_PROJECT"

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

LADDER_BAL='explore: 1+ haiku/low; build: 1+ haiku/xhigh; review: 1+ haiku/xhigh; hard: 1-2 haiku/xhigh, 3-7 opus/medium, attempt 8 back-to-human'

# --- allowed --------------------------------------------------------------------------
out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","model":"haiku","effort":"xhigh"}')")"
check "build rung haiku/xhigh: allowed" allow "$(decision "$out")"
has "allowed: short advisory" "[credo-preset] ok: haiku/xhigh is a rung of the build/review/hard roles (preset balanced)" "$(ctx "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","model":"opus","effort":"medium"}')")"
check "hard attempt-3 rung opus/medium: allowed" allow "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"claude-opus-5-5","effort":"medium"}')")"
check "full model id maps to the alias: allowed" allow "$(decision "$out")"

# --- wrong model / effort ----------------------------------------------------------------
out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","model":"opus","effort":"xhigh"}')")"
check "wrong pair opus/xhigh: denied" deny "$(decision "$out")"
r="$(reason "$out")"
has "deny names the mismatch" "opus/xhigh is no rung of the build/review/hard roles" "$r"
has "deny lists the allowed pairs" "Allowed for the build/review/hard roles: haiku/xhigh, opus/medium." "$r"
has "deny names the lookup command" "credo-preset.sh stage <role> <attempt>" "$r"
has "deny shows the ladder" "Active ladder: $LADDER_BAL." "$r"
has "deny names the exception format" "preset exception: <all|role,...> -> <model>/<effort>" "$r"
out="$(run_hook "$(call Agent '{"model":"sonnet","effort":"xhigh"}')")"
check "wrong model sonnet: denied" deny "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"haiku","effort":"low"}')")"
check "explore-only pair on a build spawn: denied" deny "$(decision "$out")"

out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","model":"haiku"}')")"
check "missing effort: denied" deny "$(decision "$out")"
has "missing effort: named" "(preset balanced): no effort." "$(reason "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","effort":"xhigh"}')")"
check "missing model: denied" deny "$(decision "$out")"
has "missing model: named" "no model (it would inherit the parent's model)" "$(reason "$out")"
out="$(run_hook "$(call Task '{"subagent_type":"general-purpose"}')")"
check "Task tool name is checked too" deny "$(decision "$out")"
has "neither: both named" "no model (it would inherit the parent's model); no effort." "$(reason "$out")"

# --- Explore / Plan: explore role only ------------------------------------------------
out="$(run_hook "$(call Agent '{"subagent_type":"Explore","model":"haiku","effort":"low"}')")"
check "Explore on the explore rung: allowed" allow "$(decision "$out")"
has "Explore advisory names the explore role" "explore role (Explore)" "$(ctx "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"Explore","model":"haiku","effort":"xhigh"}')")"
check "Explore on a build rung: denied" deny "$(decision "$out")"
has "Explore deny lists only explore pairs" "Allowed for the explore role (Explore): haiku/low." "$(reason "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"Plan","model":"opus","effort":"medium"}')")"
check "Plan on a hard rung: denied" deny "$(decision "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"Explore"}')")"
check "Explore without model/effort: denied" deny "$(decision "$out")"

# --- fork: parent model ---------------------------------------------------------------
TR="$TMP/sess.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"x"}}' \
    '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[]}}' \
    '{"type":"user","message":{"content":"y","model":"claude-haiku-5-5"}}' > "$TR"
out="$(run_hook "$(call Agent '{"subagent_type":"fork","prompt":"x"}' "$REPO" "$TR")")"
check "fork with an opus parent (rung model): allowed" allow "$(decision "$out")"
has "fork advisory: effort not checked" "fork ok: parent model opus" "$(ctx "$out")"
TR2="$TMP/sess2.jsonl"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5-5","content":[]}}' > "$TR2"
out="$(run_hook "$(call Agent '{"subagent_type":"fork","model":"haiku","effort":"xhigh"}' "$REPO" "$TR2")")"
check "fork with a sonnet parent: denied (call model ignored)" deny "$(decision "$out")"
has "fork deny suggests a regular spawn" "Spawn a regular subagent" "$(reason "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"fork"}')")"
check "fork without a transcript: denied" deny "$(decision "$out")"
has "fork deny: parent unknown" "model (unknown)" "$(reason "$out")"
mkdir -p "$TMP/sess2/subagents"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-haiku-5-5","content":[]}}' \
    > "$TMP/sess2/subagents/agent-abc123.jsonl"
out="$(run_hook "$(call Agent '{"subagent_type":"fork"}' "$REPO" "$TR2" abc123)")"
check "fork inside a subagent reads the subagent transcript (haiku): allowed" allow "$(decision "$out")"

# --- RULES.md override ----------------------------------------------------------------
RR="$TMP/rulesrepo"
mkdir -p "$RR/.credo"
git -C "$RR" init -q
cat > "$RR/.credo/RULES.md" <<'MD'
# rules

```
preset exception: all -> sonnet/high
```

- `preset exception: build, review -> opus/max` | owner wants max for this repo
preset exception: explore -> opus/low
preset exception: nonsense -> opus/high
MD
out="$(run_hook "$(call Agent '{"model":"opus","effort":"max"}' "$RR")")"
check "RULES.md override opus/max for build: allowed" allow "$(decision "$out")"
has "override advisory names the source" "ok by preset exception (RULES.md): opus/max" "$(ctx "$out")"
out="$(run_hook "$(call Agent '{"model":"opus","effort":"low"}' "$RR")")"
check "explore-scoped override does not widen build: denied" deny "$(decision "$out")"
has "deny lists the granted pair too" "opus/max" "$(reason "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"Explore","model":"opus","effort":"low"}' "$RR")")"
check "explore-scoped override for Explore: allowed" allow "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"sonnet","effort":"high"}' "$RR")")"
check "override inside a code fence is ignored: denied" deny "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"opus","effort":"high"}' "$RR")")"
check "override with an unknown scope is ignored: denied" deny "$(decision "$out")"

# linked worktree: .credo lives in the main checkout
git -C "$RR" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$RR" worktree add -q "$TMP/rr-wt" -b wt 2>/dev/null
out="$(run_hook "$(call Agent '{"model":"opus","effort":"max"}' "$TMP/rr-wt")")"
check "worktree cwd reads the main checkout RULES.md: allowed" allow "$(decision "$out")"

# --- handoff temporary rule -----------------------------------------------------------
HR="$TMP/handoffrepo"
mkdir -p "$HR/.credo/process/handoffs"
git -C "$HR" init -q
H="$HR/.credo/process/handoffs/HANDOFF.md"
cat > "$H" <<'MD'
# Handoff

## Rules (temporary)

- preset exception: build -> opus/xhigh | source: owner "opus xhigh for the refactor" (2030-06-01) | until: 2030-06-20
- preset exception: build -> opus/max | source: owner "max until done" (2030-06-01) | until: 2030-06-10
- preset exception: build -> sonnet/medium | source: agent decision | until: 2030-06-20
- preset exception: build -> sonnet/high | source: owner "sonnet high" (2030-06-01) | until: the refactor is merged
- preset exception: build -> haiku/max | source: owner "haiku max" (2030-06-01)

## Notes

- preset exception: build -> sonnet/low | source: owner "x" (2030-06-01) | until: 2030-06-20
MD
out="$(run_hook "$(call Agent '{"model":"opus","effort":"xhigh"}' "$HR")")"
check "valid owner handoff exception: allowed" allow "$(decision "$out")"
has "handoff advisory names the until" "ok by preset exception (handoff until 2030-06-20)" "$(ctx "$out")"
out="$(run_hook "$(call Agent '{"model":"opus","effort":"max"}' "$HR")")"
check "expired handoff exception: denied" deny "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"sonnet","effort":"medium"}' "$HR")")"
check "agent-decision handoff exception: denied" deny "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"sonnet","effort":"high"}' "$HR")")"
check "handoff exception without an until date: denied" deny "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"haiku","effort":"max"}' "$HR")")"
check "handoff exception without until: denied" deny "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"sonnet","effort":"low"}' "$HR")")"
check "exception outside Rules (temporary): denied" deny "$(decision "$out")"
out="$(CREDO_PRESET_GUARD_TODAY=2030-06-21 run_hook "$(call Agent '{"model":"opus","effort":"xhigh"}' "$HR")")"
check "handoff exception after its until date: denied" deny "$(decision "$out")"

# --- other preset ---------------------------------------------------------------------
mkdir -p "$TMP/q/.credo"
printf 'preset: quality\n' > "$TMP/q/.credo/config"
out="$(CREDO_PROJECT="$TMP/q/.credo/config" run_hook "$(call Agent '{"model":"haiku","effort":"xhigh"}')")"
check "quality preset: haiku/xhigh is no build rung: denied" deny "$(decision "$out")"
has "quality preset named" "(preset quality)" "$(reason "$out")"

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
