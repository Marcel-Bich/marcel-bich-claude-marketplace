#!/usr/bin/env bash
# Tests for hooks/credo-agent-spawn-check.sh + scripts/credo-preset-guard.py: the PreToolUse
# guard on Agent and Task calls. The active preset is a minimum: a spawn below every rung of
# the ladders that fit its kind (Explore/Plan -> explore; others -> build/review/hard) is
# denied, as is a missing model or effort; an equal pair passes, a stronger pair passes with a
# visible "stronger than preset" line. A fork passes only when the parent's model is >= a rung
# model. "preset exception:" lines from .credo/RULES.md and valid owner handoff rules with an
# until date may allow a weaker pair. A [credo-role: <role>#<attempt>] tag checks exactly the
# rung of that attempt; a multi-rung role without attempt is denied; a back-to-human attempt
# is denied unless a "preset continue:" line or an exception covers the role. Silent without
# a configured preset; fails open on internal errors.
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
has "equal: short advisory" "[credo-preset] ok: haiku/xhigh is a rung of the build/review/hard roles (untagged) (preset balanced); the role is unknown, so tag [credo-role: <role>#<attempt>]" "$(ctx "$out")"
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
has "deny lists the minimum pairs" "Minimum for the build/review/hard roles (untagged): one of haiku/xhigh, opus/medium" "$r"
has "deny names the lookup command with its absolute path" "bash $HERE/credo-preset.sh stage <role> <attempt>" "$r"
has "deny says how to declare the role" "Declare role and attempt with [credo-role: <role>#<attempt>]" "$r"
out="$(run_hook "$(call Agent '{"model":"opus","effort":"low"}')")"
check "stronger model but lower effort: denied" deny "$(decision "$out")"
has "mixed: both must reach the rung" "model and effort must both reach the rung" "$(reason "$out")"
out="$(run_hook "$(call Agent '{"model":"haiku","effort":"low"}')")"
check "haiku/low: denied" deny "$(decision "$out")"
case "$(reason "$out")" in
    *"must both reach"*) fail=$((fail + 1)); echo "FAIL: purely weaker pair gets no mixed sentence" ;;
    *) pass=$((pass + 1)) ;;
esac
has "deny shows the ladder" "Active ladder: $LADDER_BAL." "$r"
has "deny names the exception format" "preset exception: <all|role,...> -> <model>/<effort>" "$r"
out="$(run_hook "$(call Agent '{"model":"haiku","effort":"low"}')")"
check "explore-level pair on a build spawn: denied" deny "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"gpt-x","effort":"max"}')")"
check "unknown model: denied" deny "$(decision "$out")"
has "unknown model named" "unknown model gpt-x" "$(reason "$out")"

out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","model":"opus"}')")"
check "missing effort: denied" deny "$(decision "$out")"
has "missing effort: named" "(preset balanced): Untagged general-purpose spawn, role unknown; no effort." "$(reason "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","effort":"max"}')")"
check "missing model: denied" deny "$(decision "$out")"
has "missing model: named" "no model given - the agent definition's or the parent's model cannot be checked; pass model and effort explicitly" "$(reason "$out")"
out="$(run_hook "$(call Task '{"subagent_type":"general-purpose"}')")"
check "Task tool name is checked too" deny "$(decision "$out")"
has "neither: both named" "pass model and effort explicitly; no effort." "$(reason "$out")"

# --- model id normalisation -----------------------------------------------------------
out="$(run_hook "$(call Agent '{"model":"us.anthropic.claude-opus-4-v1:0","effort":"medium"}')")"
check "Bedrock id us.anthropic.claude-opus-4-v1:0 -> opus: allowed" allow "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"claude-opus-5-5[1m]","effort":"medium"}')")"
check "context suffix [1m] stripped: allowed" allow "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"claude-opus-4@20250514","effort":"medium"}')")"
check "Vertex id with @date: allowed" allow "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"claude-3-5-sonnet-20241022","effort":"max"}')")"
has "old-style full id maps to sonnet" "stronger than preset: sonnet/max" "$(ctx "$out")"

# --- role tag and read-only types -----------------------------------------------------
out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","description":"find X [credo-role: explore]","model":"haiku","effort":"low"}')")"
check "general-purpose tagged explore at the explore rung: allowed" allow "$(decision "$out")"
has "tag named in the advisory" "ok: role explore, attempt not given (single rung), expected rung haiku/low, chosen haiku/low (preset balanced)." "$(ctx "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","prompt":"x\n[credo-role: review]\ny","model":"haiku","effort":"xhigh"}')")"
check "role tag in the prompt: allowed" allow "$(decision "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"Explore","description":"[credo-role: build]","model":"haiku","effort":"low"}')")"
check "Explore tagged build checks the build ladder: denied" deny "$(decision "$out")"
has "tagged deny names the role" "Minimum for the build role (tagged): one of haiku/xhigh. Look up" "$(reason "$out")"
for t in web-fetch claude-code-guide caveman:cavecrew-investigator; do
    out="$(run_hook "$(call Agent "{\"subagent_type\":\"$t\",\"model\":\"haiku\",\"effort\":\"low\"}")")"
    check "read-only type $t maps to explore: allowed" allow "$(decision "$out")"
done

# --- attempt in the role tag (balanced hard: 1-2 haiku/xhigh, 3-7 opus/medium, 8 back-to-human)
hard() { # <attempt suffix> <model> <effort> [cwd]
    run_hook "$(call Agent "{\"subagent_type\":\"general-purpose\",\"description\":\"fix it [credo-role: hard$1]\",\"model\":\"$2\",\"effort\":\"$3\"}" "${4:-$REPO}")"
}
out="$(hard '#3' opus medium)"
check "hard#3 on its rung opus/medium: allowed" allow "$(decision "$out")"
has "ok names role, attempt, expected rung, chosen pair" "[credo-preset] ok: role hard, attempt 3, expected rung opus/medium, chosen opus/medium (preset balanced)." "$(ctx "$out")"
out="$(hard '#1' haiku xhigh)"
check "hard#1 on its rung haiku/xhigh: allowed" allow "$(decision "$out")"
out="$(hard '#3' haiku xhigh)"
check "hard#3 with the attempt-1 rung: denied" deny "$(decision "$out")"
r="$(reason "$out")"
has "weaker deny names role, attempt, rung, chosen" "Role hard, attempt 3 expects opus/medium; chosen haiku/xhigh is weaker than the expected rung opus/medium" "$r"
has "weaker deny gives the exact fix" "Fix: pass model: opus, effort: medium, tag [credo-role: hard#3]" "$r"
has "weaker deny says how the attempt grows" "grows by one per failed try" "$r"
out="$(hard '#3' opus max)"
check "hard#3 stronger opus/max: allowed" allow "$(decision "$out")"
has "stronger line vs the attempt rung" "stronger than preset: opus/max vs opus/medium (hard role, attempt 3 (tagged), preset balanced)" "$(sysmsg "$out")"
out="$(hard '' opus medium)"
check "multi-rung role without attempt: denied" deny "$(decision "$out")"
r="$(reason "$out")"
has "missing attempt: names the tag form" "role hard has more than one rung, so the role tag needs the attempt: [credo-role: hard#<attempt>]" "$r"
has "missing attempt: attempt -> rung map" "Attempt -> rung: hard: 1-2 haiku/xhigh, 3-7 opus/medium, attempt 8 back-to-human." "$r"
has "missing attempt: example tag" "Example: first try of hard: pass model: haiku, effort: xhigh, tag [credo-role: hard#1]." "$r"
out="$(run_hook "$(call Agent '{"description":"[credo-role: build#5]","model":"haiku","effort":"xhigh"}')")"
check "until-done rung serves any attempt: allowed" allow "$(decision "$out")"
out="$(run_hook "$(call Agent '{"prompt":"go\n[credo-role: review #2]","model":"haiku","effort":"xhigh"}')")"
check "attempt tag with a space in the prompt: allowed" allow "$(decision "$out")"
has "spaced tag parsed" "role review, attempt 2" "$(ctx "$out")"
for a in '#x' '#0' '#'; do
    out="$(hard "$a" opus medium)"
    check "invalid attempt '$a': denied" deny "$(decision "$out")"
    has "invalid attempt '$a': named" "is not a positive whole number" "$(reason "$out")"
done
out="$(hard '#8' opus max)"
check "back-to-human attempt without an owner rule: denied" deny "$(decision "$out")"
r="$(reason "$out")"
has "back-to-human: owner decides now" "role hard, attempt 8 is back-to-human - the ladder of this role is used up and the owner decides now" "$r"
has "back-to-human: names the continue form" "preset continue: <all|role,...>" "$r"
has "back-to-human: names the exception form" "preset exception: <all|role,...> -> <model>/<effort>" "$r"
case "$r" in
    *"Fix: pass model"*) fail=$((fail + 1)); echo "FAIL: back-to-human deny proposes no model" ;;
    *) pass=$((pass + 1)) ;;
esac
out="$(hard '#9' opus max)"
check "attempt past back-to-human: denied" deny "$(decision "$out")"

# --- Explore / Plan: explore role only ------------------------------------------------
out="$(run_hook "$(call Agent '{"subagent_type":"Explore","model":"haiku","effort":"low"}')")"
check "Explore on the explore rung: allowed" allow "$(decision "$out")"
has "Explore advisory: untagged read-only = explore attempt 1" "ok: role explore, attempt 1, expected rung haiku/low, chosen haiku/low" "$(ctx "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"Plan","model":"opus","effort":"medium"}')")"
check "Plan stronger than explore: allowed" allow "$(decision "$out")"
has "Plan stronger line" "stronger than preset: opus/medium vs haiku/low" "$(ctx "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"Explore"}')")"
check "Explore without model/effort: denied" deny "$(decision "$out")"
out="$(CREDO_PROJECT="$QUALITY" run_hook "$(call Agent '{"subagent_type":"Explore","model":"haiku","effort":"low"}')")"
check "quality: Explore below haiku/xhigh: denied" deny "$(decision "$out")"
has "Explore deny lists only explore pairs" "Minimum for the explore role, attempt 1 (Explore, untagged): one of haiku/xhigh." "$(reason "$out")"

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

- preset exception: build, review -> haiku/high | owner allows haiku high here
preset exception: explore -> haiku/medium
preset exception: nonsense -> sonnet/low
- `preset exception: build -> sonnet/medium` (an example in backticks)
MD
out="$(run_hook "$(call Agent '{"model":"sonnet","effort":"medium"}' "$RR")")"
check "override in inline backticks is an example and ignored: denied" deny "$(decision "$out")"
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

# --- exceptions with a tagged attempt, owner rules at back-to-human -------------------
out="$(run_hook "$(call Agent '{"description":"[credo-role: review#2]","model":"haiku","effort":"high"}' "$RR")")"
check "tagged attempt: RULES.md exception still counts: allowed" allow "$(decision "$out")"
has "exception line names the expected rung" "ok by preset exception (RULES.md): haiku/high for the review role, attempt 2 (tagged) (preset balanced), expected rung without it: haiku/xhigh." "$(ctx "$out")"
out="$(hard '#8' opus max "$RR")"
check "back-to-human: exception for other roles does not allow hard: denied" deny "$(decision "$out")"

CR="$TMP/continuerepo"
mkdir -p "$CR/.credo"
git -C "$CR" init -q
cat > "$CR/.credo/RULES.md" <<'MD'
- preset continue: hard | owner allows more tries here
- `preset continue: review` (an example in backticks)

```
preset continue: build
```
MD
out="$(hard '#8' opus medium "$CR")"
check "preset continue: last rung at back-to-human: allowed" allow "$(decision "$out")"
has "continue: visible owner-rule note" "[credo-preset] attempt 8 is back-to-human in preset balanced, continuing per owner rule RULES.md" "$(sysmsg "$out")"
has "continue: expects the last rung" "expected rung opus/medium, chosen opus/medium" "$(ctx "$out")"
out="$(hard '#8' haiku xhigh "$CR")"
check "preset continue: below the last rung: denied" deny "$(decision "$out")"
has "continue deny: last rung named" "Role hard, attempt 8 expects opus/medium (attempt is back-to-human, continuing on the last rung)" "$(reason "$out")"
printf '%s\n' 'preset exception: hard -> sonnet/high' > "$CR/.credo/RULES.md"
out="$(hard '#8' sonnet high "$CR")"
check "exception for the role at back-to-human: allowed" allow "$(decision "$out")"
has "exception at back-to-human: visible note" "attempt 8 is back-to-human in preset balanced, continuing per owner rule RULES.md" "$(sysmsg "$out")"
out="$(hard '#8' haiku low "$CR")"
check "exception at back-to-human: below the pair: denied" deny "$(decision "$out")"
has "exception-only deny: fix names the pairs" "Fix: pass one of the exception pairs sonnet/high and keep the tag [credo-role: hard#8]" "$(reason "$out")"
printf '%s\n' '`preset continue: hard`' > "$CR/.credo/RULES.md"
out="$(hard '#8' opus medium "$CR")"
check "continue in inline backticks is ignored: denied" deny "$(decision "$out")"
printf '%s\n' '- preset continue: review' > "$CR/.credo/RULES.md"
out="$(hard '#8' opus medium "$CR")"
check "continue scoped to another role: denied" deny "$(decision "$out")"
printf '%s\n' '- preset continue: all' > "$CR/.credo/RULES.md"
out="$(hard '#8' opus medium "$CR")"
check "continue for all roles: allowed" allow "$(decision "$out")"

CH="$TMP/continuehandoff"
mkdir -p "$CH/.credo/process/handoffs"
git -C "$CH" init -q
cat > "$CH/.credo/process/handoffs/HANDOFF.md" <<'MD'
# Handoff

## Rules (temporary)

- preset continue: hard | source: owner "keep going on hard" (2030-06-01) | until: 2030-06-20
- preset continue: review | source: agent decision | until: 2030-06-20
MD
out="$(hard '#8' opus medium "$CH")"
check "handoff owner continue rule with until: allowed" allow "$(decision "$out")"
has "handoff continue: source named" "continuing per owner rule handoff until 2030-06-20" "$(sysmsg "$out")"
out="$(CREDO_PRESET_GUARD_TODAY=2030-06-21 hard '#8' opus medium "$CH")"
check "handoff continue rule after its until: denied" deny "$(decision "$out")"
printf '%s\n' '# Handoff' '' '## Rules (temporary)' '' \
    '- preset continue: hard | source: agent decision | until: 2030-06-20' > "$CH/.credo/process/handoffs/HANDOFF.md"
out="$(hard '#8' opus medium "$CH")"
check "agent-decision continue rule: denied" deny "$(decision "$out")"

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

# time budget: a hanging helper is cut off below the hook timeout and fails open
printf '#!/bin/bash\nsleep 30\n' > "$STUB/scripts/credo-preset.sh"
rm -f "$CREDO_PRESET_GUARD_LOG"
t0=$(date +%s)
out="$(printf '%s' "$(call Agent '{"model":"sonnet"}')" | CREDO_PRESET_GUARD_BUDGET=2 bash "$STUB/hooks/credo-agent-spawn-check.sh" 2>/dev/null)"
t1=$(date +%s)
check "hanging preset helper: fail open (silent)" "" "$out"
check "hanging preset helper: cut off by the budget" yes "$([ $((t1 - t0)) -le 5 ] && echo yes || echo no)"
has "budget cut-off is logged" "spawn allowed unchecked" "$(cat "$CREDO_PRESET_GUARD_LOG" 2>/dev/null)"

# session id and cwd reach the preset helpers (pins and hubs resolve the same preset)
SP="$TMP/sessplugin"
mkdir -p "$SP/hooks" "$SP/scripts" "$TMP/pinned"
cp "$HOOK" "$HERE/../hooks/credo-python-lib.sh" "$SP/hooks/"
cp "$HERE/credo-preset-guard.py" "$HERE/credo-handoff-rules.py" "$SP/scripts/"
cat > "$SP/scripts/credo-config.sh" <<SH
#!/bin/bash
[ "\$CREDO_SESSION_ID" = "11111111-2222-3333-4444-555555555555" ] && [ "\$PWD" = "$TMP/pinned" ] && echo pinned
SH
cat > "$SP/scripts/credo-preset.sh" <<'SH'
#!/bin/bash
printf 'preset: pinned (custom)\nexplore:\n  1. claude-haiku-5-5 / low, attempts until-done\nbuild:\n  1. claude-opus-5-5 / high, attempts until-done\nreview:\n  1. claude-opus-5-5 / high, attempts until-done\nhard:\n  1. claude-opus-5-5 / high, attempts until-done\n'
SH
out="$(printf '%s' "$(call Agent '{"model":"opus","effort":"medium"}' "$TMP/pinned")" | bash "$SP/hooks/credo-agent-spawn-check.sh" 2>/dev/null)"
check "session id + cwd passed: pinned preset enforced" deny "$(decision "$out")"
has "pinned preset named" "(preset pinned)" "$(reason "$out")"
out="$(printf '%s' "$(call Agent '{"model":"opus","effort":"medium"}' "$REPO")" | bash "$SP/hooks/credo-agent-spawn-check.sh" 2>/dev/null)"
check "other cwd: the stub sees no preset: silent" "" "$out"

echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
