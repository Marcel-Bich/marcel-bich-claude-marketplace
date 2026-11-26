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
# quoted text and main-only (#219): a quoted commit message or feature name asks for nothing
out="$(run_hook "$(call Agent "$(brief 'Update the wiki page, then commit "acme 1.2.0: preset ranges, spawn limits, forbidden models, extends; full check main-only; code counter reconcile".')")")"
check "full check inside a quoted commit message: silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief "Use the message 'acme: run the full suite in CI' for the commit.")")")"
check "marker inside single quotes: silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief 'Document the `--full` flag in the README.')")")"
check "marker inside backticks: silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief 'Document the new feature: full check main-only.')")")"
check "main-only clause: silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief 'The full suite runs main agent only.')")")"
check "main agent only: silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief "Fix the parser. It's done when you run the full suite and it's green.")")")"
has "apostrophes are no quotes: warns" "the full-check marker \"full suite\"" "$(ctx "$out")"
out="$(run_hook "$(call Agent "$(brief 'Fix "parse_args" in cli.py, then run the full suite.')")")"
has "quotes elsewhere in the brief: still warns" "the full-check marker \"full suite\"" "$(ctx "$out")"
# verbless prohibitions and past-run reports (#219): no order
out="$(run_hook "$(call Agent "$(brief "Review the diff and run the touched tests, never the full suite; the builder's full check was green on abc1234." '[credo-role: review#1] acme-task')")")"
check "observed review brief (never ...; full check was green): silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief 'Touched-module tests only, no full check.')")")"
check "no full check: silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief 'The full suite passed on main. Fix the parser.')")")"
check "full suite passed: silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief 'I ran the full check before the merge. Fix the parser.')")")"
check "ran the full check: silent" "" "$out"
out="$(run_hook "$(call Agent "$(brief 'Fix the parser, then run ./acme check --full.')")")"
has "then run check --full: warns" "the full-check marker \"--full\"" "$(ctx "$out")"
out="$(run_hook "$(call Agent "$(brief 'The full check was green. Now run the full suite again.')")")"
has "report then order: warns" "the full-check marker \"full suite\"" "$(ctx "$out")"
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
