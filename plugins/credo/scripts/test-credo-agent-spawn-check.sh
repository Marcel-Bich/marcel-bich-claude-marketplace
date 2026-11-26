#!/usr/bin/env bash
# Tests for hooks/credo-agent-spawn-check.sh + scripts/credo-preset-guard.py: the PreToolUse
# guard on Agent and Task calls. A spawn must use a pair the fitting rung allows (fixed pair,
# any, from-to range or allowed-pairs; Explore/Plan -> explore, others -> build/review/hard);
# a pair above every pair of the rung passes with a visible "stronger than preset" line.
# The spawn limits are hard and win over everything: above max-allowed or below
# min-allowed is denied, a forbidden-models pair is denied (block) or passes with a visible
# warning (warn). A fork is denied above the max-allowed model; the same model passes with
# "fork effort not checkable". "preset exception:" lines from .credo/RULES.md and valid owner
# handoff rules with an until date may allow a cheaper pair within the limits. A
# [credo-role: <role>#<attempt>] tag checks exactly the rung of that attempt; a multi-rung
# role without attempt is denied; a back-to-human attempt is denied unless a
# "preset continue:" line or an exception covers the role. Silent without a configured
# preset; fails open on internal errors.
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
mkdir -p "$TMP/project/.credo" "$TMP/q/.credo" "$TMP/s/.credo" "$TMP/b/.credo" "$TMP/c/.credo"
printf 'preset: balanced\n' > "$CREDO_PROJECT"
QUALITY="$TMP/q/.credo/config"
printf 'preset: quality\n' > "$QUALITY"
# strict: every build/review/hard rung opus/medium, no min-allowed (for the exception cases)
STRICT="$TMP/s/.credo/config"
cat > "$STRICT" <<'YAML'
preset: strict
presets:
  strict:
    mainagent:
      model: claude-opus-5-5
      effort: medium
    explore:
      model: claude-haiku-5-5
      effort: xhigh
    build:
      model: claude-opus-5-5
      effort: medium
    review:
      model: claude-opus-5-5
      effort: medium
    hard:
      model: claude-opus-5-5
      effort: medium
YAML
# balanced with the forbidden action overridden to block (the rest of the defaults inherited)
BLOCK="$TMP/b/.credo/config"
cat > "$BLOCK" <<'YAML'
preset: balanced
default-spawn-limits:
  forbidden-action: block
YAML
# custom: every format feature and own spawn limits
CUSTOM="$TMP/c/.credo/config"
cat > "$CUSTOM" <<'YAML'
preset: custom
presets:
  custom:
    mainagent:
      model: claude-opus-5-5
      effort: medium
    spawn-limits:
      min-allowed:
        model: claude-haiku-5-5
        effort: medium
      max-allowed:
        model: claude-opus-5-5
        effort: xhigh
      forbidden-models:
        - model: claude-haiku-5-5
          effort: high
          roles: [explore]
          action: block
    explore:
      model: claude-haiku-5-5
      effort: any
    build:
      allowed-pairs:
        - model: claude-haiku-5-5
          effort: xhigh
        - model: claude-opus-5-5
          effort: { from: medium, to: high }
    review:
      model: any
    hard:
      model: { from: claude-sonnet-5-5, to: claude-opus-5-5 }
      effort: high
YAML

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
        *) fail=$((fail + 1)); echo "FAIL: $1 (missing: $2)"; echo "  in: $3" ;;
    esac
}

lacks() { # name needle haystack
    case "$3" in
        *"$2"*) fail=$((fail + 1)); echo "FAIL: $1 (unexpected: $2)" ;;
        *) pass=$((pass + 1)) ;;
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
# spawn <description> <model> <effort> [cwd]: a general-purpose spawn
spawn() {
    run_hook "$(call Agent "{\"subagent_type\":\"general-purpose\",\"description\":\"$1\",\"model\":\"$2\",\"effort\":\"$3\"}" "${4:-$REPO}")"
}

LADDER_BAL='explore: 1+ haiku/low..xhigh; build: 1-4 haiku/xhigh, 5-6 opus/medium, 7-10 haiku/xhigh, 11+ opus/medium; review: 1+ haiku/xhigh; hard: 1-2 haiku/xhigh, 3-7 opus/medium, attempt 8 back-to-human'

# --- a pair of the rung -----------------------------------------------------------------
out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","model":"haiku","effort":"xhigh"}')")"
check "build rung haiku/xhigh: allowed" allow "$(decision "$out")"
has "equal: short advisory" "[credo-preset] ok: haiku/xhigh is allowed by a rung of the build/review/hard roles (untagged) (preset balanced); the role is unknown, so tag [credo-role: <role>#<attempt>]" "$(ctx "$out")"
check "equal: no visible line" "" "$(sysmsg "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","model":"opus","effort":"medium"}')")"
check "rung opus/medium: allowed" allow "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"claude-opus-5-5","effort":"medium"}')")"
check "full model id maps to the alias: allowed" allow "$(decision "$out")"

# --- cost order: model first, then effort (#216) ------------------------------------------
out="$(spawn 'review it [credo-role: review#1]' opus medium)"
check "opus/medium satisfies a haiku/xhigh rung: allowed" allow "$(decision "$out")"
has "stronger line names rung, role and max" "stronger than preset: opus/medium vs haiku/xhigh (review role, attempt 1 (tagged), preset balanced; within the max-allowed opus/medium) - report it." "$(sysmsg "$out")"
out="$(run_hook "$(call Agent '{"model":"opus","effort":"low"}')")"
check "stronger model at a lower effort: allowed" allow "$(decision "$out")"
has "opus/low vs haiku/xhigh" "stronger than preset: opus/low vs haiku/xhigh (" "$(ctx "$out")"
out="$(spawn 'review it [credo-role: review#1]' opus xhigh)"
check "opus/xhigh above the default max-allowed: denied" deny "$(decision "$out")"
r="$(reason "$out")"
has "max deny names the limit" "chosen opus/xhigh is above the max-allowed opus/medium of preset balanced - a hard limit, no preset exception or continue rule lifts it" "$r"
has "max deny names the cheapest allowed pair" "the cheapest allowed pair here is haiku/xhigh" "$r"
has "max deny gives the exact fix" "Fix: pass model: haiku, effort: xhigh, tag [credo-role: review#1]" "$r"
has "deny explains the order" "Cost order of a pair: model first (haiku < sonnet < opus < fable), then effort" "$r"
has "deny lists the spawn limits" "Spawn limits of preset balanced: max-allowed opus/medium, forbidden-models sonnet/any (warn)" "$r"
out="$(run_hook "$(call Agent '{"model":"fable","effort":"low"}')")"
check "fable above the max-allowed: denied" deny "$(decision "$out")"
out="$(run_hook "$(call Agent '{"model":"sonnet","effort":"max"}')")"
check "sonnet/max (forbidden with warn): allowed" allow "$(decision "$out")"
has "warn line names the entry" "forbidden model (warn): sonnet/max matches forbidden-models sonnet/any of preset balanced - allowed because the action is warn; report it." "$(sysmsg "$out")"
has "warn line keeps the stronger note" "stronger than preset: sonnet/max vs haiku/xhigh" "$(ctx "$out")"

# --- below the rung / missing ---------------------------------------------------------
out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","model":"haiku","effort":"high"}')")"
check "haiku/high below every build rung: denied" deny "$(decision "$out")"
r="$(reason "$out")"
has "deny names the problem" "haiku/high is not allowed by any rung of the build/review/hard roles (untagged) (the cheapest allowed pair here is haiku/xhigh)" "$r"
has "deny lists the allowed rungs once" "Allowed for the build/review/hard roles (untagged): haiku/xhigh or opus/medium." "$r"
has "deny names the lookup command with its absolute path" "bash $HERE/credo-preset.sh stage <role> <attempt>" "$r"
has "deny says how to declare the role" "Declare role and attempt with [credo-role: <role>#<attempt>]" "$r"
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

# --- role tag, ranges and read-only types ---------------------------------------------
out="$(spawn 'find X [credo-role: explore]' haiku low)"
check "general-purpose tagged explore at the bottom of the range: allowed" allow "$(decision "$out")"
has "range rung named in the advisory" "ok: role explore, attempt not given (single rung), expected rung haiku/low..xhigh, chosen haiku/low (preset balanced)." "$(ctx "$out")"
out="$(spawn 'find X [credo-role: explore]' haiku high)"
check "explore inside the effort range: allowed" allow "$(decision "$out")"
has "inside the range: ok line" "expected rung haiku/low..xhigh, chosen haiku/high" "$(ctx "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"general-purpose","prompt":"x\n[credo-role: review]\ny","model":"haiku","effort":"xhigh"}')")"
check "role tag in the prompt: allowed" allow "$(decision "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"Explore","description":"[credo-role: hard#3]","model":"haiku","effort":"low"}')")"
check "Explore tagged hard#3 checks the hard ladder: denied" deny "$(decision "$out")"
has "tagged deny names the role" "Allowed for the hard role, attempt 3 (tagged): opus/medium." "$(reason "$out")"
for t in web-fetch claude-code-guide caveman:cavecrew-investigator; do
    out="$(run_hook "$(call Agent "{\"subagent_type\":\"$t\",\"model\":\"haiku\",\"effort\":\"low\"}")")"
    check "read-only type $t maps to explore: allowed" allow "$(decision "$out")"
done

# --- attempt in the role tag (balanced hard: 1-2 haiku/xhigh, 3-7 opus/medium, 8 back-to-human)
hard() { # <attempt suffix> <model> <effort> [cwd]
    spawn "fix it [credo-role: hard$1]" "$2" "$3" "${4:-$REPO}"
}
out="$(hard '#3' opus medium)"
check "hard#3 on its rung opus/medium: allowed" allow "$(decision "$out")"
has "ok names role, attempt, expected rung, chosen pair" "[credo-preset] ok: role hard, attempt 3, expected rung opus/medium, chosen opus/medium (preset balanced)." "$(ctx "$out")"
out="$(hard '#1' haiku xhigh)"
check "hard#1 on its rung haiku/xhigh: allowed" allow "$(decision "$out")"
out="$(hard '#3' haiku xhigh)"
check "hard#3 with the attempt-1 rung: denied" deny "$(decision "$out")"
r="$(reason "$out")"
has "cheaper deny names role, attempt, rung, chosen" "Role hard, attempt 3 expects opus/medium; chosen haiku/xhigh is cheaper than the expected rung opus/medium (the cheapest allowed pair here is opus/medium)" "$r"
has "cheaper deny gives the exact fix" "Fix: pass model: opus, effort: medium, tag [credo-role: hard#3]" "$r"
has "cheaper deny says how the attempt grows" "grows by one per failed try" "$r"
out="$(hard '#3' opus max)"
check "hard#3 opus/max above the max-allowed: denied" deny "$(decision "$out")"
out="$(hard '#1' opus low)"
check "hard#1 opus/low above the haiku/xhigh rung: allowed" allow "$(decision "$out")"
has "stronger line vs the attempt rung" "stronger than preset: opus/low vs haiku/xhigh (hard role, attempt 1 (tagged), preset balanced; within the max-allowed opus/medium)" "$(sysmsg "$out")"
out="$(hard '' opus medium)"
check "multi-rung role without attempt: denied" deny "$(decision "$out")"
r="$(reason "$out")"
has "missing attempt: names the tag form" "role hard has more than one rung, so the role tag needs the attempt: [credo-role: hard#<attempt>]" "$r"
has "missing attempt: attempt -> rung map" "Attempt -> rung: hard: 1-2 haiku/xhigh, 3-7 opus/medium, attempt 8 back-to-human." "$r"
has "missing attempt: example tag" "Example: first try of hard: pass model: haiku, effort: xhigh, tag [credo-role: hard#1]." "$r"
out="$(spawn '[credo-role: build#5]' haiku xhigh)"
check "balanced build#5 is the opus/medium stage: haiku/xhigh denied" deny "$(decision "$out")"
out="$(spawn '[credo-role: build#7]' haiku xhigh)"
check "balanced build#7 is haiku/xhigh again: allowed" allow "$(decision "$out")"
out="$(spawn '[credo-role: build#40]' opus medium)"
check "balanced build until-done opus/medium serves any later attempt: allowed" allow "$(decision "$out")"
out="$(run_hook "$(call Agent '{"prompt":"go\n[credo-role: review #2]","model":"haiku","effort":"xhigh"}')")"
check "attempt tag with a space in the prompt: allowed" allow "$(decision "$out")"
has "spaced tag parsed" "role review, attempt 2" "$(ctx "$out")"
for a in '#x' '#0' '#'; do
    out="$(hard "$a" opus medium)"
    check "invalid attempt '$a': denied" deny "$(decision "$out")"
    has "invalid attempt '$a': named" "is not a positive whole number" "$(reason "$out")"
done
out="$(hard '#8' opus medium)"
check "back-to-human attempt without an owner rule: denied" deny "$(decision "$out")"
r="$(reason "$out")"
has "back-to-human: owner decides now" "role hard, attempt 8 is back-to-human - the ladder of this role is used up and the owner decides now" "$r"
has "back-to-human: names the continue form" "preset continue: <all|role,...>" "$r"
has "back-to-human: names the exception form" "preset exception: <all|role,...> -> <model>/<effort>" "$r"
lacks "back-to-human deny proposes no model" "Fix: pass model" "$r"
out="$(hard '#9' opus medium)"
check "attempt past back-to-human: denied" deny "$(decision "$out")"

# --- Explore / Plan: explore role only, quality allowed-pairs and min-allowed -----------
out="$(run_hook "$(call Agent '{"subagent_type":"Explore","model":"haiku","effort":"low"}')")"
check "Explore on the explore rung: allowed" allow "$(decision "$out")"
has "Explore advisory: untagged read-only = explore attempt 1" "ok: role explore, attempt 1, expected rung haiku/low..xhigh, chosen haiku/low" "$(ctx "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"Plan","model":"opus","effort":"medium"}')")"
check "Plan above the explore range: allowed" allow "$(decision "$out")"
has "Plan stronger line" "stronger than preset: opus/medium vs haiku/low..xhigh" "$(ctx "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"Explore"}')")"
check "Explore without model/effort: denied" deny "$(decision "$out")"
out="$(CREDO_PROJECT="$QUALITY" run_hook "$(call Agent '{"subagent_type":"Explore","model":"haiku","effort":"low"}')")"
check "quality: Explore below the min-allowed haiku/xhigh: denied" deny "$(decision "$out")"
has "min deny names the limit" "chosen haiku/low is below the min-allowed haiku/xhigh of preset quality - a hard limit" "$(reason "$out")"
has "Explore deny lists only the explore rung" "Allowed for the explore role, attempt 1 (Explore, untagged): haiku/xhigh or opus/medium." "$(reason "$out")"
out="$(CREDO_PROJECT="$QUALITY" run_hook "$(call Agent '{"subagent_type":"Explore","model":"opus","effort":"medium"}')")"
check "quality: Explore opus/medium (second allowed pair): allowed" allow "$(decision "$out")"
out="$(CREDO_PROJECT="$QUALITY" run_hook "$(call Agent '{"subagent_type":"Explore","model":"haiku","effort":"xhigh"}')")"
check "quality: Explore haiku/xhigh (first allowed pair): allowed" allow "$(decision "$out")"
out="$(CREDO_PROJECT="$QUALITY" run_hook "$(call Agent '{"subagent_type":"Explore","model":"haiku","effort":"max"}')")"
check "quality: Explore haiku/max between the allowed pairs: denied" deny "$(decision "$out")"
has "between deny: nothing in between" "is not one of the pairs of the expected rung haiku/xhigh or opus/medium - nothing in between is allowed" "$(reason "$out")"

# --- fork: parent model ---------------------------------------------------------------
TR="$TMP/sess.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"x"}}' \
    '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[]}}' \
    '{"type":"user","message":{"content":"y","model":"claude-haiku-5-5"}}' > "$TR"
out="$(run_hook "$(call Agent '{"subagent_type":"fork","prompt":"x"}' "$REPO" "$TR")")"
check "fork with an opus parent (= max-allowed model): allowed" allow "$(decision "$out")"
has "fork: effort not checkable, visible" "fork ok, fork effort not checkable: the parent model opus is the max-allowed model" "$(sysmsg "$out")"
TRH="$TMP/sessh.jsonl"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-haiku-5-5","content":[]}}' > "$TRH"
out="$(run_hook "$(call Agent '{"subagent_type":"fork"}' "$REPO" "$TRH")")"
check "balanced: fork with a haiku parent: allowed" allow "$(decision "$out")"
has "fork below the max model: plain ok" "fork ok: parent model haiku is >= a rung model" "$(ctx "$out")"
check "fork below the max model: not visible" "" "$(sysmsg "$out")"
TR2="$TMP/sess2.jsonl"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5-5","content":[]}}' > "$TR2"
out="$(run_hook "$(call Agent '{"subagent_type":"fork"}' "$REPO" "$TR2")")"
check "balanced: fork with a sonnet parent (forbidden, warn): allowed" allow "$(decision "$out")"
has "fork sonnet: warn note" "forbidden model (warn): the fork inherits sonnet" "$(sysmsg "$out")"
out="$(CREDO_PROJECT="$QUALITY" run_hook "$(call Agent '{"subagent_type":"fork","model":"opus","effort":"max"}' "$REPO" "$TR2")")"
check "quality: fork with a sonnet parent (< opus rungs): denied, call model ignored" deny "$(decision "$out")"
has "fork deny suggests a regular spawn" "Spawn a regular subagent" "$(reason "$out")"
TRF="$TMP/sessf.jsonl"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-fable-5","content":[]}}' > "$TRF"
out="$(run_hook "$(call Agent '{"subagent_type":"fork"}' "$REPO" "$TRF")")"
check "fork with a parent above the max-allowed model: denied" deny "$(decision "$out")"
has "fork above max named" "model (fable), which is above the max-allowed opus/medium" "$(reason "$out")"
out="$(run_hook "$(call Agent '{"subagent_type":"fork"}')")"
check "fork without a transcript: denied" deny "$(decision "$out")"
has "fork deny: parent unknown" "model (unknown)" "$(reason "$out")"
mkdir -p "$TMP/sess2/subagents"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[]}}' \
    > "$TMP/sess2/subagents/agent-abc123.jsonl"
out="$(CREDO_PROJECT="$QUALITY" run_hook "$(call Agent '{"subagent_type":"fork"}' "$REPO" "$TR2" abc123)")"
check "fork inside a subagent reads the subagent transcript (opus): allowed" allow "$(decision "$out")"

# --- RULES.md override (may allow a cheaper pair; preset strict = opus/medium rungs) -----
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
preset exception: build -> opus/high
- `preset exception: build -> sonnet/medium` (an example in backticks)
MD
sx() { CREDO_PROJECT="$STRICT" run_hook "$(call Agent "{\"model\":\"$1\",\"effort\":\"$2\"}" "${3:-$RR}")"; }
# the ignored forms alone (a valid exception would let every pricier pair pass as stronger)
RI="$TMP/rulesignored"
mkdir -p "$RI/.credo"
git -C "$RI" init -q
cat > "$RI/.credo/RULES.md" <<'MD'
```
preset exception: all -> haiku/low
```

preset exception: nonsense -> sonnet/low
- `preset exception: build -> sonnet/medium` (an example in backticks)
MD
out="$(sx sonnet medium "$RI")"
check "override in inline backticks is an example and ignored: denied" deny "$(decision "$out")"
out="$(sx haiku low "$RI")"
check "override inside a code fence is ignored: denied" deny "$(decision "$out")"
out="$(sx sonnet low "$RI")"
check "override with an unknown scope is ignored: denied" deny "$(decision "$out")"
out="$(sx sonnet medium)"
check "a pair above a granted exception pair passes as stronger" allow "$(decision "$out")"
has "stronger than the exception pair" "stronger than preset: sonnet/medium vs haiku/high" "$(ctx "$out")"
out="$(sx haiku high)"
check "RULES.md override haiku/high for build: allowed" allow "$(decision "$out")"
has "override advisory names the source" "ok by preset exception (RULES.md): haiku/high" "$(ctx "$out")"
out="$(sx haiku medium)"
check "explore-scoped override does not widen build: denied" deny "$(decision "$out")"
has "deny lists the granted pair too" "haiku/high" "$(reason "$out")"
out="$(sx opus high)"
check "exception above the max-allowed grants nothing: denied" deny "$(decision "$out")"
has "exception above max: hard limit named" "above the max-allowed opus/medium of preset strict - a hard limit, no preset exception or continue rule lifts it" "$(reason "$out")"
out="$(CREDO_PROJECT="$QUALITY" run_hook "$(call Agent '{"model":"haiku","effort":"high"}' "$RR")")"
check "exception below the min-allowed grants nothing (quality): denied" deny "$(decision "$out")"
has "exception below min: hard limit named" "below the min-allowed haiku/xhigh of preset quality" "$(reason "$out")"

# linked worktree: .credo lives in the main checkout
git -C "$RR" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$RR" worktree add -q "$TMP/rr-wt" -b wt 2>/dev/null
out="$(sx haiku high "$TMP/rr-wt")"
check "worktree cwd reads the main checkout RULES.md: allowed" allow "$(decision "$out")"

# --- handoff temporary rule (preset strict) ---------------------------------------------
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
out="$(sx haiku high "$HR")"
check "valid owner handoff exception: allowed" allow "$(decision "$out")"
has "handoff advisory names the until" "ok by preset exception (handoff until 2030-06-20)" "$(ctx "$out")"
out="$(CREDO_PRESET_GUARD_TODAY=2030-06-21 sx haiku high "$HR")"
check "handoff exception after its until date: denied" deny "$(decision "$out")"
# the invalid forms alone (the valid haiku/high would let pricier pairs pass as stronger)
sed -i '/haiku high for the refactor/d' "$H"
out="$(sx haiku medium "$HR")"
check "expired handoff exception: denied" deny "$(decision "$out")"
out="$(sx sonnet low "$HR")"
check "agent-decision handoff exception: denied" deny "$(decision "$out")"
out="$(sx sonnet medium "$HR")"
check "handoff exception without an until date: denied" deny "$(decision "$out")"
out="$(sx opus low "$HR")"
check "handoff exception without until: denied" deny "$(decision "$out")"
out="$(sx haiku low "$HR")"
check "exception outside Rules (temporary): denied" deny "$(decision "$out")"

# --- exceptions with a tagged attempt, owner rules at back-to-human (balanced) ----------
out="$(run_hook "$(call Agent '{"description":"[credo-role: review#2]","model":"haiku","effort":"high"}' "$RR")")"
check "tagged attempt: RULES.md exception still counts: allowed" allow "$(decision "$out")"
has "exception line names the expected rung" "ok by preset exception (RULES.md): haiku/high for the review role, attempt 2 (tagged) (preset balanced), expected rung without it: haiku/xhigh." "$(ctx "$out")"
out="$(hard '#8' opus medium "$RR")"
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
out="$(hard '#8' opus max "$CR")"
check "preset continue never lifts the max-allowed: denied" deny "$(decision "$out")"
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
out="$(CREDO_PROJECT="$QUALITY" run_hook "$(call Agent '{"model":"opus","effort":"medium"}')")"
check "quality preset: opus/medium: allowed" allow "$(decision "$out")"
out="$(CREDO_PROJECT="$QUALITY" run_hook "$(call Agent '{"model":"opus","effort":"max"}')")"
check "quality preset: opus/max above the max-allowed: denied" deny "$(decision "$out")"

# --- forbidden-action block from a config layer (default-spawn-limits inherited) --------
out="$(CREDO_PROJECT="$BLOCK" run_hook "$(call Agent '{"model":"sonnet","effort":"max"}')")"
check "forbidden-action block in the project config: sonnet denied" deny "$(decision "$out")"
has "block deny names the entry" "chosen sonnet/max is forbidden in preset balanced (forbidden-models sonnet/any, action block) - a hard limit, no preset exception lifts it" "$(reason "$out")"
out="$(CREDO_PROJECT="$BLOCK" run_hook "$(call Agent '{"model":"opus","effort":"xhigh"}')")"
check "block layer keeps the inherited max-allowed: opus/xhigh denied" deny "$(decision "$out")"
out="$(CREDO_PROJECT="$BLOCK" run_hook "$(call Agent '{"model":"haiku","effort":"xhigh"}')")"
check "block layer: haiku/xhigh still allowed" allow "$(decision "$out")"
out="$(CREDO_PROJECT="$BLOCK" run_hook "$(call Agent '{"subagent_type":"fork"}' "$REPO" "$TR2")")"
check "block layer: fork with a sonnet parent denied" deny "$(decision "$out")"
has "fork block named" "which forbidden-models blocks at every effort (sonnet/any)" "$(reason "$out")"
printf '%s\n' 'preset exception: build -> sonnet/high' > "$CR/.credo/RULES.md"
out="$(CREDO_PROJECT="$BLOCK" run_hook "$(call Agent '{"description":"[credo-role: build#1]","model":"sonnet","effort":"high"}' "$CR")")"
check "block wins over a preset exception: denied" deny "$(decision "$out")"

# --- custom preset: every format feature and own spawn limits --------------------------
cu() { CREDO_PROJECT="$CUSTOM" spawn "$1" "$2" "$3"; }
out="$(cu '[credo-role: explore]' haiku medium)"
check "custom: effort any, haiku/medium: allowed" allow "$(decision "$out")"
has "custom: any label" "expected rung haiku/any, chosen haiku/medium" "$(ctx "$out")"
out="$(cu '[credo-role: explore]' haiku low)"
check "custom: below the own min-allowed haiku/medium: denied" deny "$(decision "$out")"
out="$(cu '[credo-role: explore]' haiku high)"
check "custom: own forbidden entry (block, explore, haiku/high): denied" deny "$(decision "$out")"
has "custom: forbidden label" "forbidden-models haiku/high, action block" "$(reason "$out")"
out="$(cu '[credo-role: review]' haiku high)"
check "custom: forbidden entry scoped to explore does not hit review: allowed" allow "$(decision "$out")"
out="$(cu '[credo-role: build]' opus high)"
check "custom: allowed-pairs opus range: allowed" allow "$(decision "$out")"
has "custom: allowed-pairs label" "expected rung haiku/xhigh or opus/medium..high, chosen opus/high" "$(ctx "$out")"
out="$(cu '[credo-role: build]' sonnet high)"
check "custom: allowed-pairs nothing in between: denied" deny "$(decision "$out")"
out="$(cu '[credo-role: build]' opus xhigh)"
check "custom: above the rung within the own max-allowed opus/xhigh: allowed" allow "$(decision "$out")"
has "custom: stronger within own max" "within the max-allowed opus/xhigh" "$(sysmsg "$out")"
out="$(cu '[credo-role: build]' opus max)"
check "custom: above the own max-allowed: denied" deny "$(decision "$out")"
out="$(cu '[credo-role: review]' opus xhigh)"
check "custom: model any covers every pair within the limits: allowed" allow "$(decision "$out")"
has "custom: model any implies effort any" "expected rung any/any, chosen opus/xhigh" "$(ctx "$out")"
out="$(cu '[credo-role: review]' haiku low)"
check "custom: model any stays within the own min-allowed: haiku/low denied" deny "$(decision "$out")"
out="$(cu '[credo-role: review]' sonnet high)"
check "custom: default forbidden entry added to the own ones: warn" allow "$(decision "$out")"
has "custom: warn from the default entry" "forbidden model (warn): sonnet/high" "$(sysmsg "$out")"
out="$(cu '[credo-role: hard]' sonnet high)"
check "custom: model range sonnet..opus with effort high: allowed" allow "$(decision "$out")"
has "custom: model range label" "expected rung sonnet..opus/high" "$(ctx "$out")"
out="$(cu '[credo-role: hard]' opus medium)"
check "custom: model range, effort below the rung: denied" deny "$(decision "$out")"

# --- extends: inherited rungs and limits are enforced; a cycle fails open with a log line
EXT="$TMP/e/.credo/config"
mkdir -p "$TMP/e/.credo"
cat > "$EXT" <<'YAML'
preset: kid
presets:
  kid:
    extends: quality
    spawn-limits:
      forbidden-models:
        - model: claude-opus-5-5
          roles: [review]
          action: block
    review:
      model: claude-haiku-5-5
      effort: xhigh
  ring-a:
    extends: ring-b
  ring-b:
    extends: ring-a
YAML
out="$(CREDO_PROJECT="$EXT" spawn '[credo-role: build]' haiku xhigh)"
check "extends: inherited build rung (quality opus/medium) enforced" deny "$(decision "$out")"
out="$(CREDO_PROJECT="$EXT" spawn '[credo-role: review]' opus medium)"
check "extends: appended forbidden entry (action block) enforced" deny "$(decision "$out")"
out="$(CREDO_PROJECT="$EXT" spawn '[credo-role: explore]' haiku low)"
check "extends: inherited min-allowed enforced" deny "$(decision "$out")"
sed -i 's/^preset: kid$/preset: ring-a/' "$EXT"
rm -f "$CREDO_PRESET_GUARD_LOG"
out="$(CREDO_PROJECT="$EXT" spawn '[credo-role: build]' haiku low)"
check "extends cycle: guard fails open (silent)" "" "$out"
has "extends cycle: logged" "spawn allowed unchecked" "$(cat "$CREDO_PRESET_GUARD_LOG" 2>/dev/null)"

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
r='{"rungs": [{"pairs": [["opus", "high"]], "label": "opus/high", "attempts": "until-done"}], "terminal": false}'
printf '{"name": "pinned", "roles": {"explore": %s, "build": %s, "review": %s, "hard": %s}, "min": null, "max": ["opus", "max"], "forbidden": []}\n' "$r" "$r" "$r" "$r"
SH
out="$(printf '%s' "$(call Agent '{"model":"opus","effort":"medium"}' "$TMP/pinned")" | bash "$SP/hooks/credo-agent-spawn-check.sh" 2>/dev/null)"
check "session id + cwd passed: pinned preset enforced" deny "$(decision "$out")"
has "pinned preset named" "(preset pinned)" "$(reason "$out")"
out="$(printf '%s' "$(call Agent '{"model":"opus","effort":"medium"}' "$REPO")" | bash "$SP/hooks/credo-agent-spawn-check.sh" 2>/dev/null)"
check "other cwd: the stub sees no preset: silent" "" "$out"

echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
