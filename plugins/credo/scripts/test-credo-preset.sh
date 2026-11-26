#!/bin/bash
# Tests for credo-preset.sh (model presets), the presets layer of credo-config.sh,
# the SessionStart injection of the main-agent prompt, and the doc invariants that
# keep the SOTA decision rule inside the preset config.
# Builds a throwaway config cascade in a temp dir (removed on exit).
# Usage: bash test-credo-preset.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SUT="$SCRIPT_DIR/credo-preset.sh"
CFG="$SCRIPT_DIR/credo-config.sh"
HOOK="$PLUGIN_DIR/hooks/credo-session-start.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-preset-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
contains() { # name needle haystack
    case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing: %s\n  in:      %s\n' "$1" "$2" "$3" ;; esac
}
lacks() { # name needle haystack
    case "$3" in *"$2"*) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  unexpected: %s\n  in:         %s\n' "$1" "$2" "$3" ;; *) PASS=$((PASS + 1)) ;; esac
}

# Isolated cascade: no profile layer, no real user config, no session state.
unset CLAUDE_CONFIG_DIR CLAUDE_PLUGIN_ROOT CLAUDE_CODE_SESSION_ID CREDO_CONFIG_STDLIB_YAML
unset CREDO_SESSION_ID CREDO_SESSION_PROJECTS_DIR CREDO_DIR CREDO_TASK_BACKEND
export CREDO_GLOBAL="$TMP/global/config"
export CREDO_PROFILE=""
export CREDO_PROJECT="$TMP/project/.credo/config"

# The approved built-in texts (English, see the spec "Built-in texts").
U='Read the source (rules, skill, code, tests) before you decide or change anything - never answer a rule question from memory or a handoff.'
UB=' Save tokens without lowering quality: keep reports short, do not re-read files you already have.'
M='Build everything as well as at all possible. When you decide an open question yourself (an agent-owned clarify item in an autonomous run, or a build-time detail of a GO item), decide in this order: 1. SOTA - the best solution known today; 2. else best effort; 3. else note it and present it to the user later. Size or effort is never a reason against a solution: feasible = GO.'
MB=' Delegate searches to the explore stage.'
E='Locate only: return file:line findings and short facts. No fixes, no long excerpts.'
B='If the project has tests, write the failing test first. Report what you changed (file:line) and the test result.'
RB='Review against the verbatim requirement. Report each finding as file:line - severity - concrete failure scenario, then PASS or FAIL.'
R_BAL="$RB"' No praise, no style nits unless they change meaning.'
R_BUD="$RB"' No praise, no nits in general unless they change meaning.'
R_QUAL="$RB"' Report nits too: fix them where possible, unless that causes too much work or refactoring.'
ESC='Earlier attempts failed. Read their findings first and do not repeat the same approach.'
NL=$'\n\n'

reset_cfg() { rm -rf "$TMP/global" "$TMP/project"; }
write_global() { mkdir -p "$(dirname "$CREDO_GLOBAL")"; cat > "$CREDO_GLOBAL"; }
write_project() { mkdir -p "$(dirname "$CREDO_PROJECT")"; cat > "$CREDO_PROJECT"; }
sf() { "$SUT" stage "$2" "$3" --field "$1" 2>"$TMP/err"; }   # field role attempt
mf() { "$SUT" mainagent --field "$1" 2>"$TMP/err"; }          # field
err() { cat "$TMP/err" 2>/dev/null; }

# --- 1. built-in presets and the helper surface -------------------------------
reset_cfg
check "list builtins" "balanced budget quality" "$("$SUT" list 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "active default is balanced" "balanced" "$("$SUT" active 2>/dev/null)"
check "config get preset: unset in the shipped template" "" "$("$CFG" get preset 2>/dev/null)"
check "config get builtin preset model" "claude-opus-5-5" "$("$CFG" get presets.quality.hard.model 2>/dev/null)"
contains "config paths lists presets builtin" "presets" "$("$CFG" paths 2>/dev/null)"

# unset preset = balanced: a copy of the plugin without the preset key
PLUG="$TMP/plugin"
mkdir -p "$PLUG/scripts" "$PLUG/templates"
cp "$SUT" "$CFG" "$PLUG/scripts/"
cp "$PLUGIN_DIR/templates/presets.default.yaml" "$PLUG/templates/"
grep -v '^preset:' "$PLUGIN_DIR/templates/config.default.yaml" > "$PLUG/templates/config.default.yaml"
check "unset preset falls back to balanced" "balanced" "$("$PLUG/scripts/credo-preset.sh" active 2>/dev/null)"

# --- 2. balanced stage chain (hard) -------------------------------------------
check "balanced hard 1 model" "claude-haiku-5-5" "$(sf model hard 1)"
check "balanced hard 1 alias" "haiku" "$(sf alias hard 1)"
check "balanced hard 1 effort" "xhigh" "$(sf effort hard 1)"
check "balanced hard 1 stage" "1 of 2" "$(sf stage hard 1)"
check "balanced hard 1 attempts" "2" "$(sf attempts hard 1)"
check "balanced hard 1 action" "spawn" "$(sf action hard 1)"
check "balanced hard 1 next" "retry" "$(sf next hard 1)"
check "balanced hard 1 prompt is universal only" "$U" "$(sf prompt hard 1)"
check "balanced hard 2 next is next-stage" "next-stage" "$(sf next hard 2)"
check "balanced hard 2 next model" "claude-opus-5-5" "$(sf next-model hard 2)"
check "balanced hard 2 next effort" "medium" "$(sf next-effort hard 2)"
check "balanced hard 3 model" "claude-opus-5-5" "$(sf model hard 3)"
check "balanced hard 3 effort" "medium" "$(sf effort hard 3)"
check "balanced hard 3 stage" "2 of 2" "$(sf stage hard 3)"
check "balanced hard 3 prompt" "$U$NL$ESC" "$(sf prompt hard 3)"
check "balanced hard 3 next is retry (5 attempts)" "retry" "$(sf next hard 3)"
check "balanced hard 7 is last opus attempt" "back-to-human" "$(sf next hard 7)"
check "balanced hard 8 chain exhausted" "back-to-human" "$(sf action hard 8)"

# --- 3. balanced build, explore, review, mainagent ----------------------------
check "balanced build model" "claude-haiku-5-5" "$(sf model build 1)"
check "balanced build effort" "xhigh" "$(sf effort build 1)"
check "balanced build prompt" "$U$NL$B" "$(sf prompt build 1)"
check "balanced build next is retry (until-done default)" "retry" "$(sf next build 1)"
check "balanced build stage 1 has 4 attempts" "4" "$(sf attempts build 1)"
check "balanced explore effort" "low" "$(sf effort explore 1)"
check "balanced explore prompt" "$U$NL$E" "$(sf prompt explore 1)"
check "balanced review prompt" "$U$NL$R_BAL" "$(sf prompt review 1)"
check "balanced mainagent model" "claude-opus-5-5" "$(mf model)"
check "balanced mainagent alias" "opus" "$(mf alias)"
check "balanced mainagent effort" "medium" "$(mf effort)"
check "balanced mainagent prompt" "$U$NL$M" "$(mf prompt)"

# --- 4. budget chain and prompts ----------------------------------------------
"$SUT" active >/dev/null 2>&1
write_global <<'EOF'
preset: budget
EOF
check "budget active" "budget" "$("$SUT" active 2>/dev/null)"
check "budget hard 3 next-stage" "next-stage" "$(sf next hard 3)"
check "budget hard 4 opus" "claude-opus-5-5" "$(sf model hard 4)"
check "budget hard 4 next back-to-human" "back-to-human" "$(sf next hard 4)"
check "budget hard 5 exhausted" "back-to-human" "$(sf action hard 5)"
check "budget build prompt" "$U$UB$NL$B" "$(sf prompt build 1)"
check "budget review prompt" "$U$UB$NL$R_BUD" "$(sf prompt review 1)"
check "budget explore effort" "low" "$(sf effort explore 1)"
check "budget mainagent model" "claude-haiku-5-5" "$(mf model)"
check "budget mainagent effort" "xhigh" "$(mf effort)"
check "budget mainagent prompt" "$U$UB$NL$M$MB" "$(mf prompt)"
check "budget hard 4 prompt" "$U$UB$NL$ESC" "$(sf prompt hard 4)"

# --- 5. quality (no chain, nits reported, until-done) -------------------------
write_global <<'EOF'
preset: quality
EOF
check "quality hard model" "claude-opus-5-5" "$(sf model hard 1)"
check "quality hard effort" "medium" "$(sf effort hard 1)"
check "quality hard attempts until-done" "until-done" "$(sf attempts hard 1)"
check "quality hard next retry" "retry" "$(sf next hard 1)"
check "quality hard attempt 40 still spawns" "spawn" "$(sf action hard 40)"
check "quality hard prompt universal only" "$U" "$(sf prompt hard 1)"
check "quality review prompt" "$U$NL$R_QUAL" "$(sf prompt review 1)"
check "quality explore model" "claude-haiku-5-5" "$(sf model explore 1)"
check "quality explore effort" "xhigh" "$(sf effort explore 1)"
check "quality build model" "claude-opus-5-5" "$(sf model build 1)"
check "quality mainagent prompt" "$U$NL$M" "$(mf prompt)"

# --- 6. config cascade: project overrides global ------------------------------
write_project <<'EOF'
preset: budget
EOF
check "project overrides global" "budget" "$("$SUT" active 2>/dev/null)"
rm -f "$CREDO_PROJECT"
check "global used without project" "quality" "$("$SUT" active 2>/dev/null)"
reset_cfg

# --- 7. custom presets (any model, flow-map syntax, missing keys add nothing) -
write_global <<'EOF'
preset: my-mix
presets:
  my-mix:
    universal-prompt: "Answer in short sentences."
    mainagent: {model: claude-opus-5-5, effort: medium, mainagent-prompt: "KISS: simplest working solution, effort counts."}
    explore: {model: claude-haiku-5-5, effort: low}
    build: {model: claude-sonnet-5-5, effort: low, subagent-prompt: "Sonnet build."}
    review: {model: claude-haiku-5-5, effort: xhigh, attempts: 1, subagent-prompt: "Check only the surface and report back fast."}
    hard:
      - {model: claude-haiku-5-5, effort: xhigh, attempts: 2}
      - back-to-human
EOF
check "custom preset active" "my-mix" "$("$SUT" active 2>/dev/null)"
check "custom preset listed" "my-mix" "$("$SUT" list 2>/dev/null | grep -x my-mix)"
check "custom build alias sonnet" "sonnet" "$(sf alias build 1)"
check "custom build effort" "low" "$(sf effort build 1)"
check "custom build prompt" "Answer in short sentences.$NL""Sonnet build." "$(sf prompt build 1)"
check "custom explore prompt is universal only" "Answer in short sentences." "$(sf prompt explore 1)"
check "custom review next back-to-human (1 attempt)" "back-to-human" "$(sf next review 1)"
check "custom hard 2 next back-to-human" "back-to-human" "$(sf next hard 2)"
check "custom hard 3 exhausted" "back-to-human" "$(sf action hard 3)"
check "custom mainagent prompt" "Answer in short sentences.$NL""KISS: simplest working solution, effort counts." "$(mf prompt)"
check "custom: only the forbidden-models warning (default sonnet entry)" "credo-preset: warning: role build stage 1 of preset 'my-mix' (claude-sonnet-5-5 / low) requests forbidden claude-sonnet-5-5/low (forbidden-models)" "$(err)"
sed 's/effort: low, subagent-prompt: "Sonnet/effort: max, subagent-prompt: "Sonnet/' "$CREDO_GLOBAL" > "$TMP/g2"
check "custom max effort accepted" "max" "$(CREDO_GLOBAL="$TMP/g2" "$SUT" stage build 1 --field effort 2>/dev/null)"
check "custom max effort: only the forbidden warning" "credo-preset: warning: role build stage 1 of preset 'my-mix' (claude-sonnet-5-5 / max) requests forbidden claude-sonnet-5-5/max (forbidden-models)" "$(CREDO_GLOBAL="$TMP/g2" "$SUT" stage build 1 --field effort 2>&1 >/dev/null)"
reset_cfg

# stdlib YAML parser (no PyYAML) must read the same flow syntax
write_global <<'EOF'
preset: my-mix
presets:
  my-mix:
    universal-prompt: "Answer in short sentences."
    mainagent: {model: claude-opus-5-5, effort: medium, mainagent-prompt: "KISS: simplest working solution, effort counts."}
    explore: {model: claude-haiku-5-5, effort: low}
    build: {model: claude-sonnet-5-5, effort: low, subagent-prompt: "Sonnet build."}
    review: {model: claude-haiku-5-5, effort: xhigh, attempts: 1, subagent-prompt: "Check only the surface and report back fast."}
    hard:
      - {model: claude-haiku-5-5, effort: xhigh, attempts: 2}
      - back-to-human
EOF
check "stdlib parser: custom build model" "claude-sonnet-5-5" "$(CREDO_CONFIG_STDLIB_YAML=1 "$SUT" stage build 1 --field model 2>/dev/null)"
check "stdlib parser: custom build prompt" "Answer in short sentences.$NL""Sonnet build." "$(CREDO_CONFIG_STDLIB_YAML=1 "$SUT" stage build 1 --field prompt 2>/dev/null)"
check "stdlib parser: hard chain" "back-to-human" "$(CREDO_CONFIG_STDLIB_YAML=1 "$SUT" stage hard 2 --field next 2>/dev/null)"
check "stdlib parser: mainagent prompt" "Answer in short sentences.$NL""KISS: simplest working solution, effort counts." "$(CREDO_CONFIG_STDLIB_YAML=1 "$SUT" mainagent --field prompt 2>/dev/null)"
reset_cfg

# missing prompt keys add nothing and do not warn
write_global <<'EOF'
preset: bare
presets:
  bare:
    mainagent: {model: claude-haiku-5-5, effort: low}
    explore: {model: claude-haiku-5-5, effort: low}
    build: {model: claude-haiku-5-5, effort: low}
    review: {model: claude-haiku-5-5, effort: low}
    hard: {model: claude-haiku-5-5, effort: low}
EOF
check "bare build prompt empty" "" "$(sf prompt build 1)"
check "bare mainagent prompt empty" "" "$(mf prompt)"
check "bare no warnings" "" "$(err)"
check "bare hard is until-done" "until-done" "$(sf attempts hard 1)"
reset_cfg

# --- 8. validation: warning on stderr, fallback to balanced -------------------
write_global <<'EOF'
preset: typo
presets:
  typo:
    build: {model: claude-sonnet-5-5, effort: turbo}
    explore: {model: claude-haiku-5-5, effort: low}
    review: {model: claude-haiku-5-5, effort: xhigh}
    hard: {model: claude-haiku-5-5, effort: xhigh}
    mainagent: {model: claude-opus-5-5, effort: medium}
EOF
check "bad effort: fallback model" "claude-haiku-5-5" "$(sf model build 1)"
check "bad effort: fallback effort" "xhigh" "$(sf effort build 1)"
check "bad effort: warning" "1" "$(err | grep -c 'invalid effort')"
reset_cfg

write_global <<'EOF'
preset: typo
presets:
  typo:
    build: {model: claude-foo-9, effort: low}
    explore: {model: claude-haiku-5-5, effort: low}
    review: {model: claude-haiku-5-5, effort: xhigh}
    hard: {model: claude-haiku-5-5, effort: xhigh}
    mainagent: {model: claude-opus-5-5, effort: medium}
EOF
check "unknown model: fallback alias" "haiku" "$(sf alias build 1)"
check "unknown model: warning" "1" "$(err | grep -c 'unknown model')"
reset_cfg

write_global <<'EOF'
preset: typo
presets:
  typo:
    build: {model: claude-haiku-5-5, effort: low}
    explore: {model: claude-haiku-5-5, effort: low}
    review: {model: claude-haiku-5-5, effort: xhigh}
    hard:
      - {model: claude-haiku-5-5, effort: xhigh, attempts: 0}
      - back-to-human
    mainagent: {model: claude-opus-5-5, effort: medium}
EOF
check "attempts 0: fallback hard attempts" "2" "$(sf attempts hard 1)"
check "attempts 0: warning" "1" "$(err | grep -c 'invalid attempts')"
reset_cfg

write_global <<'EOF'
preset: typo
presets:
  typo:
    build: {model: claude-haiku-5-5, effort: low}
    explore: {model: claude-haiku-5-5, effort: low}
    review: {model: claude-haiku-5-5, effort: xhigh}
    hard:
      - {model: claude-haiku-5-5, effort: xhigh, attempts: many}
    mainagent: {model: claude-opus-5-5, effort: medium}
EOF
check "attempts word: fallback hard attempts" "2" "$(sf attempts hard 1)"
check "attempts word: warning" "1" "$(err | grep -c 'invalid attempts')"
reset_cfg

write_global <<'EOF'
preset: typo
presets:
  typo:
    build: {model: claude-haiku-5-5, effort: low}
    explore: {model: claude-haiku-5-5, effort: low}
    review: {model: claude-haiku-5-5, effort: xhigh}
    hard:
      - {model: claude-haiku-5-5, effort: low, attempts: until-done}
      - {model: claude-opus-5-5, effort: medium, attempts: 2}
    mainagent: {model: claude-opus-5-5, effort: medium}
EOF
check "until-done not last: fallback" "2" "$(sf attempts hard 1)"
check "until-done not last: warning" "1" "$(err | grep -c 'until-done must be the last')"
reset_cfg

write_global <<'EOF'
preset: typo
presets:
  typo:
    build: {model: claude-haiku-5-5, effort: low}
    explore: {model: claude-haiku-5-5, effort: low}
    review: {model: claude-haiku-5-5, effort: xhigh}
    hard:
      - back-to-human
      - {model: claude-opus-5-5, effort: medium, attempts: 2}
    mainagent: {model: claude-opus-5-5, effort: medium}
EOF
check "back-to-human not last: fallback" "2" "$(sf attempts hard 1)"
check "back-to-human not last: warning" "1" "$(err | grep -c 'back-to-human must be the last')"
reset_cfg

write_global <<'EOF'
preset: typo
presets:
  typo:
    buidl: {model: claude-haiku-5-5, effort: low}
    build: {model: claude-sonnet-5-5, effort: low}
    explore: {model: claude-haiku-5-5, effort: low}
    review: {model: claude-haiku-5-5, effort: xhigh}
    hard: {model: claude-haiku-5-5, effort: xhigh}
    mainagent: {model: claude-opus-5-5, effort: medium}
EOF
check "unknown role key ignored, valid role kept" "claude-sonnet-5-5" "$(sf model build 1)"
check "unknown role key: warning" "1" "$(err | grep -c 'unknown role')"
reset_cfg

write_global <<'EOF'
preset: nope
EOF
check "unknown preset name: fallback balanced" "balanced" "$("$SUT" active 2>/dev/null)"
check "unknown preset name: warning" "1" "$("$SUT" active 2>&1 >/dev/null | grep -c 'unknown preset')"
reset_cfg

"$SUT" stage nope 1 >/dev/null 2>"$TMP/err"; check "cli unknown role exit" 2 "$?"
contains "cli unknown role message" "unknown role" "$(err)"
"$SUT" stage build 0 >/dev/null 2>"$TMP/err"; check "cli attempt 0 exit" 2 "$?"
contains "cli attempt message" "attempt must be a positive integer" "$(err)"

# --- 9. show, list and the readable preset dump -------------------------------
out="$("$SUT" show quality 2>/dev/null)"
contains "show header" "preset: quality" "$out"
contains "show mainagent line" "mainagent: claude-opus-5-5 / medium" "$out"
contains "show mainagent prompt" "$M" "$out"
contains "show hard chain" "1. claude-opus-5-5 / medium, attempts until-done" "$out"
contains "show explicit until-done" "attempts until-done" "$out"
out="$("$SUT" show balanced 2>/dev/null)"
contains "show balanced chain stage 2" "2. claude-opus-5-5 / medium, attempts 5" "$out"
contains "show balanced back-to-human" "3. back-to-human" "$out"
contains "show balanced escalation prompt" "$ESC" "$out"
out="$("$SUT" show nope 2>"$TMP/err")"
contains "show unknown falls back to balanced" "preset: balanced" "$out"
contains "show unknown warns" "unknown preset" "$(err)"

# --- 10. session start injects the main-agent prompt ------------------------
hook_run() { # session_id source [task-backend] - runs the hook on the current state, prints additionalContext
    local sid="$1" src="$2" backend="${3:-}"
    local modes="$TMP/hook/modes" decisions="$TMP/hook/decisions"
    ( cd "$TMP/hook/cwd" && printf '{"session_id":"%s","source":"%s","cwd":"%s"}' "$sid" "$src" "$TMP/hook/cwd" \
        | CLAUDE_CONFIG_DIR="$TMP/hook/cfg" CREDO_SESSION_MODES_DIR="$modes" CREDO_SESSION_DECISIONS_DIR="$decisions" \
          CREDO_SESSION_START_SHORTHANDS=false CREDO_TMUX_HINT=false CREDO_TASK_BACKEND="$backend" \
          bash "$HOOK" 2>/dev/null ) | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}
hook_out() { # session_id source [mode] [session-decision] [task-backend] - sets the state, then runs the hook
    local sid="$1" src="$2" mode="${3:-}" dec="${4:-}" backend="${5:-}"
    local modes="$TMP/hook/modes" decisions="$TMP/hook/decisions"
    mkdir -p "$modes" "$decisions" "$TMP/hook/cwd" "$TMP/hook/cfg"
    rm -f "$modes/$sid" "$decisions/$sid"
    [ -n "$mode" ] && printf '%s\n' "$mode" > "$modes/$sid"
    [ -n "$dec" ] && printf '%s\n' "$dec" > "$decisions/$sid"
    hook_run "$sid" "$src" "$backend"
}
reset_cfg
out="$(hook_out hookA startup active)"
contains "hook active startup: universal prompt" "$U" "$out"
contains "hook active startup: mainagent prompt" "$M" "$out"
contains "hook active startup: marked as preset" "Model preset 'balanced'" "$out"
contains "hook active startup: per-spawn stage rule" 'credo-preset.sh" stage <role> <attempt>' "$out"
out="$(hook_out hookB compact active)"
contains "hook active after compact: mainagent prompt" "$M" "$out"
out="$(hook_out hookC startup "")"
contains "hook open decision: ASK still injected" "NOT yet activated" "$out"
contains "hook open decision: preset block still injected" "Model preset 'balanced'" "$out"
lacks "hook open decision: no items knowledge" "credo workflow is ACTIVE" "$out"
write_global <<'EOF'
preset: bare
presets:
  bare:
    mainagent: {model: claude-haiku-5-5, effort: low}
    explore: {model: claude-haiku-5-5, effort: low}
    build: {model: claude-haiku-5-5, effort: low}
    review: {model: claude-haiku-5-5, effort: low}
    hard: {model: claude-haiku-5-5, effort: low}
EOF
out="$(hook_out hookD startup active)"
lacks "hook bare preset: no preset block" "Model preset" "$out"
contains "hook bare preset: credo workflow still injected" "credo workflow is ACTIVE" "$out"
reset_cfg

# declined directory - declining credo drops only the items workflow, the preset stays
( cd "$TMP/hook/cwd" && CLAUDE_CONFIG_DIR="$TMP/hook/cfg" "$PLUGIN_DIR/scripts/credo-dir-decision.sh" set declined >/dev/null )
out="$(hook_out hookE startup "")"
contains "declined dir: universal prompt" "$U" "$out"
contains "declined dir: mainagent prompt" "$M" "$out"
contains "declined dir: preset marked" "Model preset 'balanced'" "$out"
contains "declined dir: per-spawn stage rule" 'credo-preset.sh" stage <role> <attempt>' "$out"
lacks "declined dir: no ASK" "NOT yet activated" "$out"
lacks "declined dir: no items knowledge" "credo workflow is ACTIVE" "$out"
lacks "declined dir: no items skill list" "work-item model" "$out"
out="$(hook_out hookF compact "")"
contains "declined dir after compact: preset still injected" "$M" "$out"
out="$(hook_out hookG startup "" declined)"
contains "declined session: preset still injected" "$M" "$out"
lacks "declined session: no items knowledge" "credo workflow is ACTIVE" "$out"
out="$(cd "$TMP/hook/cwd" && printf '{"session_id":"hookH","source":"startup","cwd":"%s"}' "$TMP/hook/cwd" \
    | CLAUDE_CONFIG_DIR="$TMP/hook/cfg" CREDO_SESSION_START_INJECT=false bash "$HOOK" 2>/dev/null)"
check "global off switch silences the declined dir preset" "" "$out"
rm -rf "$TMP/hook/cfg"

# gsd task backend: the items workflow text stands down, the preset block and the shorthands stay
out="$(hook_out hookI startup "" "" gsd)"
contains "gsd: universal prompt" "$U" "$out"
contains "gsd: mainagent prompt" "$M" "$out"
contains "gsd: preset marked" "Model preset 'balanced'" "$out"
contains "gsd: per-spawn stage rule" 'credo-preset.sh" stage <role> <attempt>' "$out"
lacks "gsd: no ASK" "NOT yet activated" "$out"
lacks "gsd: no items knowledge" "credo workflow is ACTIVE" "$out"
lacks "gsd: no items skill list" "work-item model" "$out"
out="$(hook_out hookJ startup active "" gsd)"
contains "gsd active: preset block" "$M" "$out"
lacks "gsd active: no items knowledge" "credo workflow is ACTIVE" "$out"
out="$(cd "$TMP/hook/cwd" && printf '{"session_id":"hookK","source":"startup","cwd":"%s"}' "$TMP/hook/cwd" \
    | CLAUDE_CONFIG_DIR="$TMP/hook/cfg" CREDO_TASK_BACKEND=gsd CREDO_TMUX_HINT=false bash "$HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // ""')"
contains "gsd: shorthand legend still appended" "USER SHORTHANDS" "$out"
contains "gsd: preset block still before the legend" "Model preset 'balanced'" "$out"
rm -rf "$TMP/hook/cfg"

# dont_ask_twice (opt-in config key, default off): one extra line after the preset block,
# in every state like the preset block; off, absent or invalid = no line
DAT="[credo] dont_ask_twice is on: before every question, search the requirement logs, the items, the handoff and earlier Ask answers; an earlier approval counts as the owner's answer."
reset_cfg
out="$(hook_out hookM startup active)"
lacks "dont_ask_twice default: no line" "dont_ask_twice" "$out"
printf 'dont_ask_twice: true\n' | write_project
out="$(hook_out hookN startup active)"
contains "dont_ask_twice on (project): line injected" "$DAT" "$out"
case "$out" in *"Model preset 'balanced'"*"$DAT"*) dat_order=after ;; *) dat_order=other ;; esac
check "dont_ask_twice on: line follows the preset block" "after" "$dat_order"
out="$(hook_out hookO startup "")"
contains "dont_ask_twice on, open decision: line injected" "$DAT" "$out"
out="$(hook_out hookP compact "" declined)"
contains "dont_ask_twice on, declined session: line injected" "$DAT" "$out"
out="$(hook_out hookQ startup "" "" gsd)"
contains "dont_ask_twice on, gsd backend: line injected" "$DAT" "$out"
reset_cfg
printf 'dont_ask_twice: true\n' | write_global
out="$(hook_out hookR resume active)"
contains "dont_ask_twice on (global): line injected" "$DAT" "$out"
printf 'dont_ask_twice: false\n' | write_project
out="$(hook_out hookS startup active)"
lacks "dont_ask_twice off in project beats global on" "dont_ask_twice" "$out"
printf 'dont_ask_twice: maybe\n' | write_project
out="$(hook_out hookT startup active)"
lacks "dont_ask_twice invalid value: no line" "dont_ask_twice" "$out"
reset_cfg
write_global <<'EOF'
dont_ask_twice: true
preset: bare
presets:
  bare:
    mainagent: {model: claude-haiku-5-5, effort: low}
    explore: {model: claude-haiku-5-5, effort: low}
    build: {model: claude-haiku-5-5, effort: low}
    review: {model: claude-haiku-5-5, effort: low}
    hard: {model: claude-haiku-5-5, effort: low}
EOF
out="$(hook_out hookU startup active)"
lacks "dont_ask_twice on, bare preset: no preset block" "Model preset" "$out"
contains "dont_ask_twice on, bare preset: line still injected" "$DAT" "$out"
reset_cfg
rm -rf "$TMP/hook/cfg"

# /credo:disable in an already active session. The disable steps also record the session as
# declined, so resume and compact do not bring the workflow back (an accepted session is active)
out="$(hook_out hookL startup active accepted)"
contains "disable active: workflow text before disable" "credo workflow is ACTIVE" "$out"
# The three calls the disable skill makes (dir decision, session mode clear, session decision)
( cd "$TMP/hook/cwd" && CLAUDE_CONFIG_DIR="$TMP/hook/cfg" "$PLUGIN_DIR/scripts/credo-dir-decision.sh" set declined >/dev/null )
CLAUDE_CONFIG_DIR="$TMP/hook/cfg" CREDO_SESSION_MODES_DIR="$TMP/hook/modes" CLAUDE_CODE_SESSION_ID=hookL "$PLUGIN_DIR/hooks/session-mode-set.sh" clear >/dev/null
CLAUDE_CONFIG_DIR="$TMP/hook/cfg" CREDO_SESSION_DECISIONS_DIR="$TMP/hook/decisions" CLAUDE_CODE_SESSION_ID=hookL "$PLUGIN_DIR/scripts/credo-decision-set.sh" declined >/dev/null
check "disable steps: session decision is declined" "declined" "$(cat "$TMP/hook/decisions/hookL")"
out="$(hook_run hookL resume)"
contains "disabled resume: preset still injected" "$M" "$out"
lacks "disabled resume: no KNOWLEDGE" "credo workflow is ACTIVE" "$out"
lacks "disabled resume: no ASK" "NOT yet activated" "$out"
out="$(hook_run hookL compact)"
contains "disabled compact: preset still injected" "$M" "$out"
lacks "disabled compact: no KNOWLEDGE" "credo workflow is ACTIVE" "$out"
rm -rf "$TMP/hook/cfg"

# --- 11. doc invariants: decision philosophy lives in the preset config --------
SKILLS="$PLUGIN_DIR/skills"
for f in items orchestration session-active session-autonomous role-plan migrate; do
    # the legacy marker "(GO: agent per SOTA rule, ...)" stays valid and may be cited
    n="$(grep 'SOTA' "$SKILLS/$f/SKILL.md" | grep -vc 'per SOTA rule')"
    check "no SOTA in skill $f" "0" "$n"
done
check "no SOTA in credo guide" "0" "$(grep 'SOTA' "$PLUGIN_DIR/docs/credo-guide.md" | grep -vc 'per SOTA rule')"
check "no SOTA in README" "0" "$(grep 'SOTA' "$PLUGIN_DIR/README.md" | grep -vc 'per SOTA rule')"
contains "orchestration: every code track worktree heading" "### Worktrees for every code track" "$(cat "$SKILLS/orchestration/SKILL.md")"
contains "orchestration: hard rule isolation" 'never use the Agent tool'"'"'s built-in `isolation: "worktree"`' "$(cat "$SKILLS/orchestration/SKILL.md")"
contains "orchestration: model presets section" "credo-preset.sh\" stage" "$(cat "$SKILLS/orchestration/SKILL.md")"
lacks "orchestration: old model policy removed" "no model-choice logic" "$(cat "$SKILLS/orchestration/SKILL.md")"
contains "setup: preset menu" "Which preset do you want?" "$(cat "$PLUGIN_DIR/commands/setup.md")"
contains "setup: author experience quote kept" "Author's experience" "$(cat "$PLUGIN_DIR/commands/setup.md")"
contains "setup: presets helper referenced" "credo-preset.sh\" show" "$(cat "$PLUGIN_DIR/commands/setup.md")"
contains "session-init: mainagent comparison" "credo-preset.sh\" mainagent" "$(cat "$PLUGIN_DIR/commands/session-init.md")"
contains "guide: presets documented" "credo-preset.sh" "$(cat "$PLUGIN_DIR/docs/credo-guide.md")"
contains "README: presets documented" "## Model presets" "$(cat "$PLUGIN_DIR/README.md")"
contains "orchestration: back-to-human push is high priority" 'CREDO_NTFY_PRIORITY=high "${CLAUDE_PLUGIN_ROOT}/scripts/credo-ntfy-send.sh"' "$(cat "$SKILLS/orchestration/SKILL.md")"
contains "orchestration: builder brief carries the mainagent prompt" 'credo-preset.sh" mainagent --field prompt' "$(cat "$SKILLS/orchestration/SKILL.md")"
contains "session-active: prints the mainagent prompt once" 'credo-preset.sh" mainagent --field prompt' "$(cat "$PLUGIN_DIR/commands/session-active.md")"
contains "session-active: preset helper allowed" 'Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-preset.sh:*)' "$(cat "$PLUGIN_DIR/commands/session-active.md")"
contains "session-init: prints the mainagent prompt" 'credo-preset.sh" mainagent --field prompt' "$(cat "$PLUGIN_DIR/commands/session-init.md")"
contains "session-init: preset helper allowed" 'Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-preset.sh:*)' "$(cat "$PLUGIN_DIR/commands/session-init.md")"
contains "disable skill: presets stay on" "model presets" "$(cat "$SKILLS/disable/SKILL.md")"
lacks "disable skill: no prompt-line claim" "prompt line" "$(cat "$SKILLS/disable/SKILL.md")"
contains "disable command: presets stay on" "model presets" "$(cat "$PLUGIN_DIR/commands/disable.md")"
lacks "disable command: no prompt-line claim" "prompt line" "$(cat "$PLUGIN_DIR/commands/disable.md")"
contains "disable command: session decision recorded" 'Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-decision-set.sh:*)' "$(cat "$PLUGIN_DIR/commands/disable.md")"
contains "disable command: shorthands stay on" "model presets and shorthands stay on" "$(cat "$PLUGIN_DIR/commands/disable.md")"
contains "disable skill: session decision recorded" 'credo-decision-set.sh" declined' "$(cat "$SKILLS/disable/SKILL.md")"
contains "setup: unset preset (exit 3) reads as nothing chosen" "exit 3, the key is unset" "$(cat "$PLUGIN_DIR/commands/setup.md")"
lacks "setup: no builtin source wording" '`builtin:` means nothing' "$(cat "$PLUGIN_DIR/commands/setup.md")"

# --- 12. fresh install: no preset line in the shipped template -> setup shows the menu
reset_cfg
"$CFG" ensure-global >/dev/null 2>&1
check "fresh global has no preset line" "" "$(grep '^preset:' "$CREDO_GLOBAL" 2>/dev/null)"
check "fresh install: preset source is unset" "" "$("$CFG" source preset 2>/dev/null)"
check "fresh install: active is balanced" "balanced" "$("$SUT" active 2>/dev/null)"
reset_cfg

# --- 13. setup examples a) to d) parse with the stdlib YAML parser (no PyYAML) ---
# Each example body becomes preset ex-<letter> and is shown with CREDO_CONFIG_STDLIB_YAML=1.
ex_body() { # letter -> the YAML lines of example <letter>, 3-space indent removed
    awk -v L="$1" '
        /^What else you can do/ { on = 1 }
        /^Which preset do you want/ { on = 0 }
        on && $0 ~ ("^" L "\\) ") { inex = 1; body = 0; next }
        /^[a-f]\) / { inex = 0 }
        inex && !body && /^   [a-z-]+:/ { body = 1 }
        inex && body && /^$/ { inex = 0; body = 0 }
        inex && body { sub(/^   /, ""); print }
    ' "$PLUGIN_DIR/commands/setup.md"
}
ex_show() { # letter -> readable dump of the example preset (stderr in $TMP/err)
    mkdir -p "$(dirname "$CREDO_GLOBAL")"
    {
        printf 'preset: ex-%s\npresets:\n  ex-%s:\n' "$1" "$1"
        ex_body "$1" | sed 's/^/    /'
    } > "$CREDO_GLOBAL"
    CREDO_CONFIG_STDLIB_YAML=1 "$SUT" show 2>"$TMP/err"
}
ex_out="$(ex_show a)"; check "setup example a: no invalid value" "" "$(grep -v 'not set in preset' "$TMP/err")"
contains "setup example a: mainagent recommendation" "mainagent: claude-opus-5-5 / medium" "$ex_out"
contains "setup example a: mainagent prompt read" "mainagent-prompt: KISS: simplest working solution, effort counts." "$ex_out"
contains "setup example a: universal prompt read" "universal-prompt: Answer in short sentences." "$ex_out"
ex_out="$(ex_show b)"; check "setup example b: no invalid value" "" "$(grep -v 'not set in preset' "$TMP/err")"
contains "setup example b: quick first stage" "1. claude-haiku-5-5 / low, attempts 1" "$ex_out"
contains "setup example b: thorough second stage" "2. claude-haiku-5-5 / xhigh, attempts 2" "$ex_out"
contains "setup example b: stage prompt read" "subagent-prompt: Check only the surface and report back fast." "$ex_out"
ex_out="$(ex_show c)"; check "setup example c: no invalid value" "" "$(grep -v 'not set in preset' "$TMP/err")"
contains "setup example c: low effort stage" "1. claude-haiku-5-5 / low, attempts 2" "$ex_out"
contains "setup example c: xhigh effort stage" "2. claude-haiku-5-5 / xhigh, attempts 2" "$ex_out"
contains "setup example c: back-to-human" "3. back-to-human" "$ex_out"
ex_out="$(ex_show d)"; check "setup example d: no invalid value" "" "$(grep -v 'not set in preset' "$TMP/err")"
contains "setup example d: until-done stage" "1. claude-opus-5-5 / medium, attempts until-done" "$ex_out"
reset_cfg

# --- 14. session project pin: the whole project layer follows the pin ---------
# Precedence: CREDO_PROJECT > CREDO_DIR > session pin > cwd git toplevel (or cwd).
# Each source writes its own `probe` value, so a failure names the layer that won.
PIN="$TMP/pins"
PINREPO="$TMP/pinrepo"
HUB="$TMP/hub"
pin_fixture() {
    reset_cfg
    rm -rf "$PIN" "$PINREPO" "$HUB" "$TMP/envproj" "$TMP/envdir"
    mkdir -p "$PIN" "$PINREPO/.credo" "$HUB/.credo" "$TMP/envproj/.credo" "$TMP/envdir/.credo"
    printf 'preset: quality\n' | write_global
    printf 'hub: true\npreset: balanced\nprobe: hub\n' > "$HUB/.credo/config"
    printf 'preset: budget\nprobe: pin\ntask_backend: gsd\n' > "$PINREPO/.credo/config"
    printf 'preset: quality\nprobe: env\n' > "$TMP/envproj/.credo/config"
    printf 'preset: quality\nprobe: envdir\n' > "$TMP/envdir/.credo/config"
    printf '%s\n' "$PINREPO" > "$PIN/s-pin"
}
# run_hub <session-id> <command...>: hub cwd, pin dir set, no explicit project target
run_hub() {
    local sid="$1"; shift
    ( cd "$HUB" && unset CREDO_PROJECT CREDO_DIR && CREDO_SESSION_ID="$sid" CREDO_SESSION_PROJECTS_DIR="$PIN" "$@" 2>/dev/null )
}

pin_fixture
check "pin: hub cwd uses the pinned preset" "budget" "$(run_hub s-pin "$SUT" active)"
check "pin: config get reads the pinned project layer" "pin" "$(run_hub s-pin "$CFG" get probe)"
check "pin: config get preset from the pinned repo" "budget" "$(run_hub s-pin "$CFG" get preset)"
check "pin: backend from the pinned repo" "gsd" "$(run_hub s-pin "$CFG" backend)"
check "pin: source names the pinned project file" "project: $PINREPO/.credo/config" "$(run_hub s-pin "$CFG" source preset)"
contains "pin: paths show the pinned project file" "project: $PINREPO/.credo/config" "$(run_hub s-pin "$CFG" paths)"
check "pin: resolve-project prints the pinned .credo" "$PINREPO/.credo" "$(run_hub s-pin "$CFG" resolve-project)"
check "pin: CLAUDE_CODE_SESSION_ID is the fallback id" "pin" "$(run_hub "" env CLAUDE_CODE_SESSION_ID=s-pin "$CFG" get probe)"

check "CREDO_PROJECT beats the pin" "env" "$(run_hub s-pin env CREDO_PROJECT="$TMP/envproj/.credo/config" "$CFG" get probe)"
check "CREDO_DIR beats the pin" "envdir" "$(run_hub s-pin env CREDO_DIR="$TMP/envdir/.credo" "$CFG" get probe)"
check "CREDO_PROJECT beats CREDO_DIR" "env" "$(run_hub s-pin env CREDO_PROJECT="$TMP/envproj/.credo/config" CREDO_DIR="$TMP/envdir/.credo" "$CFG" get probe)"
check "resolve-project: CREDO_DIR beats the pin" "$TMP/envdir/.credo" "$(run_hub s-pin env CREDO_DIR="$TMP/envdir/.credo" "$CFG" resolve-project)"

check "no session id: cwd hub config" "hub" "$(run_hub "" "$CFG" get probe)"
check "no pin file for the session: cwd hub config" "hub" "$(run_hub s-none "$CFG" get probe)"
printf '%s\n' "$PINREPO" > "$PIN/s+bad"
check "invalid session id: pin ignored, cwd hub config" "hub" "$(run_hub 's+bad' "$CFG" get probe)"
printf '%s\n' "$TMP/no-such-repo" > "$PIN/s-gone"
check "pin dir missing: pin ignored, cwd hub config" "hub" "$(run_hub s-gone "$CFG" get probe)"
run_hub s-gone "$CFG" resolve-project >/dev/null
check "pin dir missing: resolve-project falls back to the hub rule (exit 4)" 4 "$?"
check "hub cwd without a pin: cwd preset unchanged" "balanced" "$(run_hub "" "$SUT" active)"

# SessionStart from the hub: the hook passes the stdin session_id to credo-preset.sh
hub_hook_out="$(cd "$HUB" && printf '{"session_id":"s-pin","source":"startup","cwd":"%s"}' "$HUB" \
    | env -u CREDO_PROJECT -u CREDO_DIR CLAUDE_CONFIG_DIR="$TMP/hook/cfg" CREDO_SESSION_PROJECTS_DIR="$PIN" \
      CREDO_SESSION_MODES_DIR="$TMP/hook/modes" CREDO_SESSION_DECISIONS_DIR="$TMP/hook/decisions" \
      CREDO_SESSION_START_SHORTHANDS=false CREDO_TMUX_HINT=false CREDO_TASK_BACKEND= \
      bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
contains "session start from a hub: pinned preset injected" "Model preset 'budget'" "$hub_hook_out"
lacks "session start from a hub: cwd preset not injected" "Model preset 'balanced'" "$hub_hook_out"
reset_cfg

# --- 15. rung ranges, allowed-pairs and spawn limits (#216) ---------------------
# built-in defaults
T="$PLUGIN_DIR/templates/presets.default.yaml"
order="$(grep -nE '^  (budget|balanced|quality):$' "$T" | cut -d: -f2 | tr -d ' ' | tr '\n' ' ')"
check "template: presets in ascending order" "budget balanced quality " "$order"
lacks "template: an unset min-allowed is left out, never none" "min-allowed: none" "$(cat "$T")"
check "default max-allowed" '{"model": "claude-opus-5-5", "effort": "medium"}' "$("$CFG" get default-spawn-limits.max-allowed 2>/dev/null)"
check "default forbidden action" "warn" "$("$CFG" get default-spawn-limits.forbidden-action 2>/dev/null)"
check "balanced: no min-allowed" "" "$(sf min-allowed build 1)"
check "balanced: max-allowed field" "claude-opus-5-5/medium" "$(sf max-allowed build 1)"
check "balanced: forbidden field" "claude-sonnet-5-5 / any (warn)" "$(sf forbidden build 1)"
check "balanced: no load warning" "" "$(err)"
check "balanced build 5 is opus" "claude-opus-5-5" "$(sf model build 5)"
check "balanced build 4 escalates" "next-stage" "$(sf next build 4)"
check "balanced build 7 is haiku again" "claude-haiku-5-5" "$(sf model build 7)"
check "balanced build 11 is opus until done" "until-done" "$(sf attempts build 11)"
check "balanced build has no back-to-human" "spawn" "$(sf action build 99)"
check "balanced explore: cheapest of the range" "low" "$(sf effort explore 1)"
check "balanced explore: allowed range" "claude-haiku-5-5 / from low to xhigh" "$(sf allowed explore 1)"
out="$("$SUT" show balanced 2>/dev/null)"
contains "show: spawn-limits heading" "spawn-limits (hard for every spawn):" "$out"
contains "show: max-allowed" "  max-allowed: claude-opus-5-5 / medium" "$out"
contains "show: forbidden entry" "    - claude-sonnet-5-5 / any, all roles, warn" "$out"
contains "show: forbidden action" "  forbidden-action: warn" "$out"
lacks "show balanced: no min-allowed line" "min-allowed" "$out"
contains "show: range rung" "1. claude-haiku-5-5 / from low to xhigh, attempts until-done" "$out"
out="$("$SUT" show quality 2>/dev/null)"
contains "show quality: min-allowed" "  min-allowed: claude-haiku-5-5 / xhigh" "$out"
contains "show quality: allowed-pairs rung" "1. claude-haiku-5-5 / xhigh or claude-opus-5-5 / medium, attempts until-done" "$out"
out="$("$SUT" show budget 2>/dev/null)"
contains "show budget: explore range" "1. claude-haiku-5-5 / from low to high, attempts until-done" "$out"
contains "show budget: review range" "1. claude-haiku-5-5 / from medium to xhigh, attempts until-done" "$out"
contains "json: max for the guard" '"max": ["opus", "medium"]' "$("$SUT" json 2>/dev/null)"

# every format feature in one custom preset, read by PyYAML and the stdlib parser
write_global <<'EOF'
preset: fmt
presets:
  fmt:
    mainagent:
      model: claude-opus-5-5
      effort: medium
    spawn-limits:
      min-allowed:
        model: claude-haiku-5-5
        effort: medium
      max-allowed:
        model: claude-opus-5-5
        effort: high
      forbidden-models:
        - model: claude-haiku-5-5
          effort: { from: medium, to: high }
          roles: [review]
          action: block
      forbidden-action: warn
    explore:
      model: any
    build:
      allowed-pairs:
        - model: claude-haiku-5-5
          effort: xhigh
        - model: claude-opus-5-5
          effort: { from: medium, to: high }
    review:
      model: claude-haiku-5-5
      effort: any
    hard:
      - model: { from: claude-sonnet-5-5, to: claude-opus-5-5 }
        effort: low
        attempts: 1
      - model: claude-opus-5-5
        effort: max
        attempts: 1
      - model: claude-haiku-5-5
        effort: low
EOF
for P in 0 1; do
    sfp() { CREDO_CONFIG_STDLIB_YAML=$P "$SUT" stage "$2" "$3" --field "$1" 2>"$TMP/err"; }
    check "fmt[$P]: model any = cheapest pair within min-allowed" "claude-haiku-5-5/medium" "$(sfp model explore 1)/$(sfp effort explore 1)"
    check "fmt[$P]: model any implies effort any" "any / any" "$(sfp allowed explore 1)"
    check "fmt[$P]: allowed-pairs text" "claude-haiku-5-5 / xhigh or claude-opus-5-5 / from medium to high" "$(sfp allowed build 1)"
    check "fmt[$P]: allowed-pairs cheapest" "claude-haiku-5-5/xhigh" "$(sfp model build 1)/$(sfp effort build 1)"
    check "fmt[$P]: cheapest skips a forbidden pair" "claude-haiku-5-5/xhigh" "$(sfp model review 1)/$(sfp effort review 1)"
    check "fmt[$P]: cheapest model range skips forbidden sonnet (warn)" "claude-opus-5-5" "$(sfp model hard 1)"
    check "fmt[$P]: rung above the max-allowed is served by it" "claude-opus-5-5/high" "$(sfp model hard 2)/$(sfp effort hard 2)"
    contains "fmt[$P]: capped note" "lies outside the spawn limits - this rung uses claude-opus-5-5/high" "$(sfp note hard 2)"
    contains "fmt[$P]: load warning above max" "requests claude-opus-5-5/max above the max-allowed claude-opus-5-5/high" "$(err)"
    contains "fmt[$P]: load warning below min" "requests claude-haiku-5-5/low below the min-allowed claude-haiku-5-5/medium" "$(err)"
    check "fmt[$P]: rung below the min-allowed is served by it" "claude-haiku-5-5/medium" "$(sfp model hard 3)/$(sfp effort hard 3)"
    check "fmt[$P]: min-allowed field" "claude-haiku-5-5/medium" "$(sfp min-allowed build 1)"
    check "fmt[$P]: forbidden field for review (own + default)" "claude-sonnet-5-5 / any (warn); claude-haiku-5-5 / from medium to high (block)" "$(sfp forbidden review 1)"
    check "fmt[$P]: forbidden field for build (default only)" "claude-sonnet-5-5 / any (warn)" "$(sfp forbidden build 1)"
done
out="$("$SUT" show fmt 2>"$TMP/err")"
contains "fmt show: own forbidden entry with roles" "    - claude-haiku-5-5 / from medium to high, roles review, block" "$out"
contains "fmt show: capped line" "     capped: outside the spawn limits, this rung uses claude-opus-5-5/high" "$out"
contains "fmt show: preset forbidden-action" "  forbidden-action: warn" "$out"
contains "fmt show: forbidden warning at load" "role hard stage 1 of preset 'fmt' (from claude-sonnet-5-5 to claude-opus-5-5 / low) requests forbidden claude-sonnet-5-5/low (forbidden-models)" "$(err)"
lacks "fmt show: pairs that only come from any are not reported" "role review stage 1" "$(err)"
reset_cfg

# invalid forms warn and fall back
write_global <<'EOF'
preset: bad
presets:
  bad:
    mainagent: {model: claude-opus-5-5, effort: medium}
    spawn-limits:
      min-allowed: {model: claude-opus-5-5, effort: high}
      forbidden-action: maybe
      forbidden-models:
        - {model: claude-haiku-5-5, roles: [nobody]}
    explore: {model: claude-haiku-5-5, effort: {from: high, to: low}}
    build:
      model: claude-haiku-5-5
      effort: xhigh
      allowed-pairs:
        - {model: claude-opus-5-5, effort: medium}
    review: {model: any, effort: medium}
    hard: {model: claude-opus-5-5, effort: medium}
EOF
"$SUT" show bad >/dev/null 2>"$TMP/err"
contains "bad: reversed range" "the effort range of role explore goes from high to low - from must not lie above to - using balanced for explore" "$(err)"
contains "bad: model/effort and allowed-pairs together" "use either model/effort or allowed-pairs in a stage, not both" "$(err)"
contains "bad: min above max dropped" "min-allowed claude-opus-5-5/high of preset 'bad' lies above its max-allowed claude-opus-5-5/medium - no min-allowed used" "$(err)"
contains "bad: forbidden action" "forbidden-action in spawn-limits of preset 'bad' is 'maybe' - use warn or block; using block" "$(err)"
contains "bad: forbidden entry roles" "roles in forbidden-models in spawn-limits of preset 'bad' entry 1 must be a list of explore, build, review, hard - entry ignored" "$(err)"
check "bad: explicit effort wins over model any" "medium" "$(sf effort review 1)"
check "bad: model any with a fixed effort" "any / medium" "$(sf allowed review 1)"
reset_cfg

# a config layer overrides default-spawn-limits key by key
write_global <<'EOF'
preset: balanced
default-spawn-limits:
  forbidden-action: block
EOF
out="$("$SUT" show 2>/dev/null)"
contains "layer override: forbidden-action block" "  forbidden-action: block" "$out"
contains "layer override: entries inherited with the new action" "    - claude-sonnet-5-5 / any, all roles, block" "$out"
contains "layer override: max-allowed inherited" "  max-allowed: claude-opus-5-5 / medium" "$out"
reset_cfg

# --- 16. preset inheritance: extends -------------------------------------------
write_global <<'EOF'
preset: child
presets:
  mid:
    extends: quality
    mainagent:
      mainagent-prompt: "Mid prompt."
    spawn-limits:
      forbidden-models:
        - model: claude-haiku-5-5
          effort: low
    build:
      model: claude-haiku-5-5
      effort: xhigh
  child:
    extends: mid
    universal-prompt: "Child universal."
    spawn-limits:
      max-allowed:
        model: claude-opus-5-5
        effort: high
      forbidden-models:
        - model: claude-opus-5-5
          effort: high
          roles: [explore]
    review:
      model: claude-opus-5-5
      effort: high
  loop-a:
    extends: loop-b
  loop-b:
    extends: loop-a
  self:
    extends: self
  orphan:
    extends: nowhere
EOF
out="$("$SUT" show child 2>"$TMP/err")"
check "extends: no warning for a complete chain" "" "$(err)"
contains "extends: own universal-prompt wins" "universal-prompt: Child universal." "$out"
contains "extends: mainagent model/effort from the chain root" "mainagent: claude-opus-5-5 / medium (recommendation only) (from quality)" "$out"
contains "extends: mainagent prompt merged field-wise" "  mainagent-prompt: Mid prompt. (from mid)" "$out"
contains "extends: min-allowed inherited" "  min-allowed: claude-haiku-5-5 / xhigh (from quality)" "$out"
contains "extends: own max-allowed overrides" "  max-allowed: claude-opus-5-5 / high" "$out"
lacks "extends: own max-allowed not marked" "max-allowed: claude-opus-5-5 / high (from" "$out"
contains "extends: default forbidden entry first" "    - claude-sonnet-5-5 / any, all roles, warn" "$out"
contains "extends: base forbidden entry appended" "    - claude-haiku-5-5 / low, all roles, warn (from mid)" "$out"
contains "extends: own forbidden entry appended" "    - claude-opus-5-5 / high, roles explore, warn" "$out"
contains "extends: role from the root (chain)" "explore: (from quality)" "$out"
contains "extends: role from the middle" "build: (from mid)" "$out"
contains "extends: own role replaces the base role" "review:"$'\n'"  1. claude-opus-5-5 / high, attempts until-done" "$out"
contains "extends: hard from quality" "hard: (from quality)" "$out"
check "extends: active child resolves" "claude-opus-5-5" "$(sf model review 1)"
check "extends: stage of an inherited role" "claude-haiku-5-5" "$(sf model build 1)"
check "extends: inherited role keeps its stage prompt" "Child universal.$NL$E" "$(sf prompt explore 1)"
check "extends: mid keeps quality's universal prompt" "universal-prompt: $U (from quality)" "$("$SUT" show mid 2>/dev/null | grep '^universal-prompt')"
"$SUT" show loop-a >/dev/null 2>"$TMP/err"
check "extends: cycle exits 1" 1 "$?"
contains "extends: cycle named" "credo-preset: preset inheritance cycle: loop-a -> loop-b -> loop-a" "$(err)"
"$SUT" show self >/dev/null 2>"$TMP/err"
contains "extends: self cycle named" "preset inheritance cycle: self -> self" "$(err)"
"$SUT" show orphan >/dev/null 2>"$TMP/err"
check "extends: unknown base exits 1" 1 "$?"
contains "extends: unknown base named" "preset 'orphan' extends unknown preset 'nowhere'" "$(err)"
sed -i 's/^preset: child$/preset: loop-a/' "$CREDO_GLOBAL"
"$SUT" stage build 1 >/dev/null 2>"$TMP/err"
check "extends: active preset with a cycle fails stage (exit 1)" 1 "$?"
check "stdlib parser: extends chain" "claude-opus-5-5 / medium" "$(sed -i 's/^preset: loop-a$/preset: child/' "$CREDO_GLOBAL"; CREDO_CONFIG_STDLIB_YAML=1 "$SUT" show child 2>/dev/null | sed -n 's/^mainagent: \(.*\) (recommendation only).*/\1/p')"
reset_cfg

printf 'test-credo-preset: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
