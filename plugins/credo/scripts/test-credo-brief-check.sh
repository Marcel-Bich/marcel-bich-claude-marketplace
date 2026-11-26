#!/usr/bin/env bash
# Tests for scripts/credo_brief_check.py through hooks/credo-agent-spawn-check.sh: a build,
# review or hard spawn whose brief asks for the project's full check (dogma `all` stage
# command, a full-check command from .credo/RULES.md, or a marker like --full / "full suite"
# / "all tests") gets a warning (additionalContext + systemMessage), never a deny. Negated
# or main-agent clauses, explore spawns and narrowed runs stay silent. The preset guard
# still decides as before (run in the same process); its deny keeps the warning appended.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/credo-agent-spawn-check.sh"

pass=0
fail=0
TMP="$(mktemp -d)"
trap '[ -n "$TMP" ] && rm -rf -- "$TMP"' EXIT
unset CLAUDE_CONFIG_DIR CLAUDE_PLUGIN_ROOT CLAUDE_CODE_SESSION_ID CREDO_CONFIG_STDLIB_YAML
unset CREDO_SESSION_ID CREDO_SESSION_PROJECTS_DIR CREDO_DIR CREDO_TASK_BACKEND CREDO_BRIEF_CHECK
export CREDO_GLOBAL="$TMP/global/config"
export CREDO_PROFILE=""
export CREDO_PROJECT="$TMP/none/.credo/config"
export CREDO_AGENT_SPAWN_CHECK=1
export CREDO_PRESET_GUARD_TODAY=2030-06-15
export CREDO_PRESET_GUARD_LOG="$TMP/guard.log"
mkdir -p "$TMP/global" "$TMP/none/.credo" "$TMP/p/.credo"
: > "$CREDO_PROJECT"
PRESET="$TMP/p/.credo/config"
printf 'preset: balanced\n' > "$PRESET"

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

lacks() { # name needle haystack
    case "$3" in
        *"$2"*) fail=$((fail + 1)); echo "FAIL: $1 (unexpected: $2)" ;;
        *) pass=$((pass + 1)) ;;
    esac
}

# a plain repo, a repo with dogma test commands + RULES.md, and a linked worktree of it
PLAIN="$TMP/plain"
mkdir -p "$PLAIN"
git -C "$PLAIN" init -q
PROJ="$TMP/proj"
mkdir -p "$PROJ/.credo"
git -C "$PROJ" init -q
cat > "$PROJ/DOGMA-PERMISSIONS.md" <<'EOF'
# Permissions
<permissions>
### Test Commands (§ly5v)
- relevant: `make test-fast`
- all [main]: `make test-all`
</permissions>
EOF
cat > "$PROJ/.credo/RULES.md" <<'EOF'
# rules
## R9 - full check
- Only the main agent runs the full check (`./acme verify`). Builders run touched-module tests plus `make test-fast`.
EOF
printf 'x\n' > "$PROJ/readme.txt"
git -C "$PROJ" add readme.txt
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -q -m init >/dev/null 2>&1
WT="$TMP/wt-box-1"
git -C "$PROJ" worktree add -q -b wt-box-1 "$WT" 2>/dev/null

# call <tool name> <tool_input JSON> [cwd]: the PreToolUse hook input
call() {
    jq -n --arg t "$1" --argjson i "$2" --arg c "${3:-$PLAIN}" \
        '{session_id: "11111111-2222-3333-4444-555555555555", hook_event_name: "PreToolUse",
          cwd: $c, tool_name: $t, tool_input: $i}'
}
# brief <prompt> [description] [subagent_type]: a tool_input JSON with model + effort
brief() {
    jq -n --arg p "$1" --arg d "${2:-[credo-role: build#1] acme-task}" --arg s "${3:-general-purpose}" \
        '{subagent_type: $s, description: $d, prompt: $p, model: "opus", effort: "medium"}'
}
run_hook() { printf '%s' "$1" | bash "$HOOK" 2>/dev/null; }
decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null; }
reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }
ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }
sysmsg() { printf '%s' "$1" | jq -r '.systemMessage // ""' 2>/dev/null; }

# --- markers (no preset configured, plain repo) ------------------------------------------
out="$(run_hook "$(call Agent "$(brief 'Fix the parser. Before reporting run ./acme check --full and report.')")")"
check "--full in a build brief: allowed" allow "$(decision "$out")"
has "--full: warning in context" "[credo-brief] warning: this build brief asks the subagent to run the full check (the full-check marker \"--full\"" "$(ctx "$out")"
has "--full: warning visible" "[credo-brief] warning" "$(sysmsg "$out")"
has "--full: names the rule" "Full check only in the main agent" "$(ctx "$out")"
has "--full: names the fix" "Fix: replace that line in the brief with the touched-module tests plus the fast check" "$(ctx "$out")"
has "--full: quotes the brief" "run ./acme check --full and report" "$(ctx "$out")"
out="$(run_hook "$(call Agent "$(brief 'Then run the full suite.' '[credo-role: review#2] acme-task')")")"
has "full suite in a review brief: warns" "this review brief asks" "$(ctx "$out")"
out="$(run_hook "$(call Agent "$(brief 'Run ALL tests before you report.' 'acme-task')")")"
has "untagged general-purpose + run ALL tests: warns" "the full-check marker \"all tests\"" "$(ctx "$out")"
has "untagged: role list" "this build/review/hard brief" "$(ctx "$out")"
out="$(run_hook "$(call Agent "$(brief 'Do a full check of everything.' '[credo-role: hard#3] acme-task')")")"
has "full check in a hard brief: warns" "this hard brief asks" "$(ctx "$out")"
out="$(run_hook "$(call Task "$(brief 'run the full test suite')")")"
has "Task tool is checked too" "[credo-brief] warning" "$(ctx "$out")"

# --- silent cases ---------------------------------------------------------------------------
out="$(run_hook "$(call Agent "$(brief 'Run the touched-module tests. Never run the full suite.')")")"
check "negated (never): silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief 'Do not run ./acme check --full; run the module tests.')")")"
check "negated (do not) --full: silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief 'Report back; the main agent runs the full check after the merge.')")")"
check "main agent clause: silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief 'Run the full suite only in the main agent.')")")"
check "main agent after the match: silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief 'Run all tests of the touched module.')")")"
check "all tests of <module>: silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief 'Inspect git log --full-history for the file.')")")"
check "--full-history is no marker: silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief 'run ./acme check --full' '[credo-role: explore#1] look')")")"
check "explore tag: silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief 'run the full suite and summarise failures' 'look around' Explore)")")"
check "untagged Explore: silent" "" "$out"
out="$(run_hook "$(call Bash '{"command":"make test-all --full"}')")"
check "non-Agent tool: silent" "" "$out"
out="$(CREDO_BRIEF_CHECK=0 run_hook "$(call Agent "$(brief 'run the full suite')")")"
check "CREDO_BRIEF_CHECK=0: silent" "" "$out"
out="$(CREDO_AGENT_SPAWN_CHECK=0 run_hook "$(call Agent "$(brief 'run the full suite')")")"
check "CREDO_AGENT_SPAWN_CHECK=0: silent" "" "$out"

# --- project commands: dogma `all` stage and RULES.md ---------------------------------------
out="$(run_hook "$(call Agent "$(brief 'When done, run make test-all and report.')" "$PROJ")")"
has "dogma all command: warns" "the project's \`all\` stage command \`make test-all\`" "$(ctx "$out")"
has "dogma all command: names the relevant command" "the dogma \`relevant\` command \`make test-fast\`" "$(ctx "$out")"
has "dogma all command: quotes the RULES.md line" ".credo/RULES.md: \"Only the main agent runs the full check" "$(ctx "$out")"
out="$(run_hook "$(call Agent "$(brief 'Run make test-all plugins/acme/test-box.sh only.')" "$PROJ")")"
check "all command narrowed by a path: silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief 'Run make test-fast and report.')" "$PROJ")")"
check "relevant command: silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief 'Finally run ./acme verify.')" "$PROJ")")"
has "RULES.md full-check command: warns" "the full-check command \`./acme verify\` from .credo/RULES.md" "$(ctx "$out")"
out="$(run_hook "$(call Agent "$(brief 'When done, run `make test-all`.')" "$WT")")"
has "linked worktree cwd: reads the main checkout files" "\`all\` stage command \`make test-all\`" "$(ctx "$out")"
sed -i 's/- relevant: `make test-fast`/- relevant: `make test-all`/' "$PROJ/DOGMA-PERMISSIONS.md"
out="$(run_hook "$(call Agent "$(brief 'When done, run make test-all and report.')" "$PROJ")")"
check "all == relevant: silent" "" "$out"

# --- merged with the preset guard -----------------------------------------------------------
export CREDO_PROJECT="$PRESET"
out="$(run_hook "$(call Agent "$(brief 'run the full suite')")")"
check "preset ok + marker: allowed" allow "$(decision "$out")"
has "preset ok + marker: preset line kept" "[credo-preset]" "$(ctx "$out")"
has "preset ok + marker: warning appended" "[credo-brief] warning" "$(ctx "$out")"
has "preset ok + marker: warning visible" "[credo-brief] warning" "$(sysmsg "$out")"
weak="$(jq -n '{subagent_type: "general-purpose", description: "[credo-role: build#1] t", prompt: "run the full suite", model: "haiku", effort: "low"}')"
out="$(run_hook "$(call Agent "$weak")")"
check "preset deny stays a deny" deny "$(decision "$out")"
has "preset deny: reason kept" "[credo-preset]" "$(reason "$out")"
has "preset deny: warning appended" "[credo-brief] warning" "$(reason "$out")"
weak_clean="$(jq -n '{subagent_type: "general-purpose", description: "[credo-role: build#1] t", prompt: "fix it", model: "haiku", effort: "low"}')"
out="$(run_hook "$(call Agent "$weak_clean")")"
check "preset deny without marker: deny" deny "$(decision "$out")"
lacks "preset deny without marker: no warning" "[credo-brief]" "$(reason "$out")"
export CREDO_PROJECT="$TMP/none/.credo/config"

# --- fail open and speed --------------------------------------------------------------------
out="$(run_hook 'not json')"
check "unparseable input: silent" "" "$out"
printf '%s' 'not json' | bash "$HOOK" >/dev/null 2>&1
check "unparseable input: exit 0" 0 "$?"
out="$(run_hook "$(call Agent "$(brief 'run the full suite')" "$TMP/missing-dir")")"
has "missing cwd: markers still checked" "[credo-brief] warning" "$(ctx "$out")"
start=$(date +%s%N)
run_hook "$(call Agent "$(brief 'run the full suite')" "$PROJ")" >/dev/null
ms=$(( ($(date +%s%N) - start) / 1000000 ))
if [ "$ms" -lt 3000 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: hook too slow (${ms} ms)"; fi

echo "credo-brief-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
