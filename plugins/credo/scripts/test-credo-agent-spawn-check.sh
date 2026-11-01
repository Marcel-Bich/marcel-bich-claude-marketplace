#!/usr/bin/env bash
# Tests for hooks/credo-agent-spawn-check.sh: a PreToolUse check on Agent and Task calls.
# It adds a non-blocking warning when the call has no model or effort, or a model/effort
# pair that matches no stage of the active preset, names credo-preset.sh stage and the
# active ladder, skips Explore and Plan when the preset has no explore model, and stays
# silent otherwise. It never denies a call.
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

# call <tool name> <tool_input JSON>: the PreToolUse hook input
call() {
    jq -n --arg t "$1" --argjson i "$2" \
        '{session_id: "11111111-2222-3333-4444-555555555555", hook_event_name: "PreToolUse", tool_name: $t, tool_input: $i}'
}

# ctx_of <hook path> <hook input>: the injected additionalContext ("" when silent)
ctx_of() {
    printf '%s' "$2" | bash "$1" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}

LADDER_BAL='explore: 1+ haiku/low; build: 1+ haiku/xhigh; review: 1+ haiku/xhigh; hard: 1-2 haiku/xhigh, 3-7 opus/medium, attempt 8 back-to-human'

# --- real built-in balanced preset -------------------------------------------------
ok_ctx="$(ctx_of "$HOOK" "$(call Agent '{"subagent_type":"general-purpose","model":"haiku","effort":"xhigh"}')")"
check "valid build pair: silent" "" "$ok_ctx"
ok_hard="$(ctx_of "$HOOK" "$(call Agent '{"subagent_type":"general-purpose","model":"opus","effort":"medium"}')")"
check "valid hard attempt-3 pair (opus medium): silent" "" "$ok_hard"

noeff="$(ctx_of "$HOOK" "$(call Agent '{"subagent_type":"general-purpose","model":"haiku"}')")"
has "no effort: warning" "[credo-preset] Check this spawn against the active preset (balanced): no effort." "$noeff"
has "no effort: names the stage helper" "credo-preset.sh stage <role> <attempt>" "$noeff"
has "no effort: active ladder with attempt ranges" "Active ladder: $LADDER_BAL." "$noeff"

nomodel="$(ctx_of "$HOOK" "$(call Agent '{"subagent_type":"general-purpose","effort":"xhigh"}')")"
has "no model: warning" "(balanced): no model." "$nomodel"

neither="$(ctx_of "$HOOK" "$(call Agent '{"prompt":"x"}')")"
has "no model and no effort: both named" "(balanced): no model; no effort." "$neither"

off_pair="$(ctx_of "$HOOK" "$(call Agent '{"model":"opus","effort":"xhigh"}')")"
has "pair outside the ladder: warning" "opus/xhigh matches no stage of the preset." "$off_pair"

medium_haiku="$(ctx_of "$HOOK" "$(call Agent '{"model":"haiku","effort":"medium"}')")"
has "haiku medium is not on the balanced ladder" "haiku/medium matches no stage of the preset." "$medium_haiku"

full_id="$(ctx_of "$HOOK" "$(call Agent '{"model":"claude-opus-5-5","effort":"medium"}')")"
check "full model id maps to the alias: silent" "" "$full_id"

task_name="$(ctx_of "$HOOK" "$(call Task '{"subagent_type":"general-purpose"}')")"
has "Task tool name is checked too" "no model; no effort." "$task_name"

bash_call="$(ctx_of "$HOOK" "$(call Bash '{"command":"ls"}')")"
check "Bash call is not checked" "" "$bash_call"

explore_bare="$(ctx_of "$HOOK" "$(call Agent '{"subagent_type":"Explore"}')")"
has "Explore without model: checked (balanced explore has a model)" "no model; no effort." "$explore_bare"
explore_ok="$(ctx_of "$HOOK" "$(call Agent '{"subagent_type":"Explore","model":"haiku","effort":"low"}')")"
check "Explore on the explore stage pair: silent" "" "$explore_ok"

out="$(printf '%s' "$(call Agent '{"model":"haiku"}')" | bash "$HOOK" 2>/dev/null)"
check "output event name is PreToolUse" PreToolUse \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)"
check "output is suppressed from the chat" true \
    "$(printf '%s' "$out" | jq -r '.suppressOutput' 2>/dev/null)"
check "output never denies the call" "" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)"

printf '%s' "$(call Agent '{"model":"haiku"}')" | bash "$HOOK" >/dev/null 2>&1
check "hook exits 0 on a warning" 0 "$?"

# --- disable switch, bad input: silent ----------------------------------------------
off_ctx="$(CREDO_AGENT_SPAWN_CHECK=0 ctx_of "$HOOK" "$(call Agent '{"model":"haiku"}')")"
check "CREDO_AGENT_SPAWN_CHECK=0: silent" "" "$off_ctx"
junk_ctx="$(ctx_of "$HOOK" 'not json at all')"
check "non-JSON input: silent" "" "$junk_ctx"
printf '' | bash "$HOOK" >/dev/null 2>&1
check "empty input: exit 0" 0 "$?"

# --- project preset quality (explore haiku xhigh, build and hard opus medium) --------
Q_CTX="$(
    export CREDO_PROJECT="$TMP/quality/.credo/config"
    mkdir -p "$TMP/quality/.credo"
    printf 'preset: quality\n' > "$CREDO_PROJECT"
    ctx_of "$HOOK" "$(call Agent '{"subagent_type":"general-purpose","model":"haiku","effort":"low"}')"
)"
has "quality preset: named in the warning" "(quality): haiku/low matches no stage of the preset." "$Q_CTX"
has "quality preset: its build ladder" "build: 1+ opus/medium" "$Q_CTX"
Q_OK="$(
    export CREDO_PROJECT="$TMP/quality/.credo/config"
    ctx_of "$HOOK" "$(call Agent '{"subagent_type":"general-purpose","model":"opus","effort":"medium"}')"
)"
check "quality preset: opus medium is on its ladder: silent" "" "$Q_OK"

# --- stub plugin: parser edge cases and the Explore skip ---------------------------
STUB="$TMP/stubplugin"
mkdir -p "$STUB/hooks" "$STUB/scripts"
cp "$HOOK" "$STUB/hooks/"
printf '#!/bin/bash\ncat "$STUB_SHOW"\n' > "$STUB/scripts/credo-preset.sh"
STUB_HOOK="$STUB/hooks/credo-agent-spawn-check.sh"

# no explore stage at all: Explore and Plan are skipped, a general-purpose call is still checked
cat > "$TMP/show-noexplore.txt" <<'SHOW'
preset: stub (custom)
universal-prompt: (none)
mainagent: claude-opus-5-5 / medium (recommendation only)
explore:
build:
  1. claude-haiku-5-5 / xhigh, attempts until-done
review:
  1. claude-haiku-5-5 / xhigh, attempts until-done
hard:
  1. claude-haiku-5-5 / xhigh, attempts 1
  2. back-to-human
SHOW
export STUB_SHOW="$TMP/show-noexplore.txt"
skip_explore="$(ctx_of "$STUB_HOOK" "$(call Agent '{"subagent_type":"Explore"}')")"
check "no explore model: Explore skipped" "" "$skip_explore"
skip_plan="$(ctx_of "$STUB_HOOK" "$(call Agent '{"subagent_type":"Plan"}')")"
check "no explore model: Plan skipped" "" "$skip_plan"
stub_gp="$(ctx_of "$STUB_HOOK" "$(call Agent '{"subagent_type":"general-purpose"}')")"
has "no explore model: general-purpose still checked" "no model; no effort." "$stub_gp"
has "single attempt segment: 1 haiku/xhigh" "hard: 1 haiku/xhigh, attempt 2 back-to-human" "$stub_gp"
has "until-done segment: build 1+" "build: 1+ haiku/xhigh" "$stub_gp"
has "stub preset name is shown" "(stub): no model" "$stub_gp"

# unreadable preset output: silent
printf 'garbage line\n' > "$TMP/show-garbage.txt"
export STUB_SHOW="$TMP/show-garbage.txt"
garbage_ctx="$(ctx_of "$STUB_HOOK" "$(call Agent '{"model":"haiku"}')")"
check "unparseable preset output: silent" "" "$garbage_ctx"

# no preset helper at all (a plugin copy with only the hook): silent
BARE="$TMP/bareplugin"
mkdir -p "$BARE/hooks"
cp "$HOOK" "$BARE/hooks/"
nohelper_ctx="$(ctx_of "$BARE/hooks/credo-agent-spawn-check.sh" "$(call Agent '{"model":"haiku"}')")"
check "no preset helper: silent" "" "$nohelper_ctx"

echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
