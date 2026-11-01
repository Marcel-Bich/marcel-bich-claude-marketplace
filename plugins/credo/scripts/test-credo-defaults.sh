#!/bin/bash
# Tests for the credo defaults: the config keys with their built-in values
# (read through credo-config.sh), and the wording invariants of the skills, docs
# and commands (no fixed fail-count brake, builder range, capacity and stall
# limits, Ask and veto rules, safety and verify rules, release and
# dont_ask_twice). Wording checks are grep-based, like the other doc invariants.
# Usage: bash test-credo-defaults.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CFG="$SCRIPT_DIR/credo-config.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-defaults-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
has() { # name file pattern   (case-insensitive, fixed string)
    if grep -q -i -F -- "$3" "$2" 2>/dev/null; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing in %s: %s\n' "$1" "${2#"$PLUGIN_DIR"/}" "$3"; fi
}
hasany() { # name pattern file...   (case-insensitive, fixed string, at least one file)
    local name="$1" pat="$2"; shift 2
    if grep -q -i -F -- "$pat" "$@" 2>/dev/null; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing in any of the files: %s\n' "$name" "$pat"; fi
}
lacks() { # name extended-regex   (case-insensitive, over the live credo text)
    local name="$1" pat="$2" hits
    hits="$(cd "$PLUGIN_DIR" && grep -rn -i -E -- "$pat" skills docs README.md commands hooks scripts \
        --include='*.md' --include='*.sh' --include='*.py' --include='*.ts' --include='*.tsx' \
        --exclude='test-*.sh' 2>/dev/null | grep -v -E '^scripts/test-' | head -5)"
    if [ -z "$hits" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  unexpected match of /%s/:\n%s\n' "$name" "$pat" "$hits"; fi
}

# Isolated cascade: no profile layer, no real user config, no session state.
unset CLAUDE_CONFIG_DIR CLAUDE_PLUGIN_ROOT CLAUDE_CODE_SESSION_ID CREDO_CONFIG_STDLIB_YAML
unset CREDO_SESSION_ID CREDO_SESSION_PROJECTS_DIR CREDO_DIR CREDO_TASK_BACKEND
export CREDO_GLOBAL="$TMP/global/config"
export CREDO_PROFILE=""
export CREDO_PROJECT="$TMP/project/.credo/config"

# --- 1. built-in config defaults (read through the cascade) -------------------
check "builders.min_per_area default" "2" "$("$CFG" get builders.min_per_area 2>/dev/null)"
check "builders.max_per_area default" "4" "$("$CFG" get builders.max_per_area 2>/dev/null)"
check "release.auto default off" "false" "$("$CFG" get release.auto 2>/dev/null)"
check "release.fallback_fragments default" "15" "$("$CFG" get release.fallback_fragments 2>/dev/null)"
check "release.fallback_days default" "7" "$("$CFG" get release.fallback_days 2>/dev/null)"
check "dont_ask_twice default off" "false" "$("$CFG" get dont_ask_twice 2>/dev/null)"
check "resources.max_busy_percent default" "90" "$("$CFG" get resources.max_busy_percent 2>/dev/null)"

# --- 2. fixed fail-count brake is gone everywhere -----------------------------
lacks "no emergency brake wording" 'emergency brake'
lacks "no fixed 2-FAIL brake wording" '(2|two)[ -]FAIL|after 2 FAIL'

# --- 3. workflow and audit (fix rounds, DoD scope, facts, best effort, flaky tests) ---
ORCH="$PLUGIN_DIR/skills/orchestration/SKILL.md"
AUDIT="$PLUGIN_DIR/skills/audit/SKILL.md"
ITEMS="$PLUGIN_DIR/skills/items/SKILL.md"
VERIFY="$PLUGIN_DIR/skills/verify/SKILL.md"
SAFETY="$PLUGIN_DIR/skills/safety/SKILL.md"
BUDGET="$PLUGIN_DIR/skills/budget/SKILL.md"
ACTIVE="$PLUGIN_DIR/skills/session-active/SKILL.md"
PASSIVE="$PLUGIN_DIR/skills/session-passive/SKILL.md"
AUTO="$PLUGIN_DIR/skills/session-autonomous/SKILL.md"
SETUP="$PLUGIN_DIR/commands/setup.md"
MIGRATE="$PLUGIN_DIR/skills/migrate/SKILL.md"
GUIDE="$PLUGIN_DIR/docs/credo-guide.md"

hasany "fix rounds follow the preset ladder" "stage ladder" "$AUDIT" "$ORCH" "$ITEMS"
hasany "back to owner after unchanged finding" "returns unchanged twice" "$AUDIT" "$ORCH" "$ITEMS"
has "orchestration names the builder range" "$ORCH" "builders.min_per_area"
has "orchestration names the builder max" "$ORCH" "builders.max_per_area"
lacks "no fixed 3-4 builder default" '3-4 (single-item )?builders'
has "audit: collection item for MINOR/NIT" "$AUDIT" "collection item"
has "items: collection item for beyond-DoD findings" "$ITEMS" "collection item"
has "audit: DoD targets never lowered" "$AUDIT" "never lowered"
has "items: facts the owner stated go into the item" "$ITEMS" "facts the owner already stated"
has "audit: best effort for unreachable goals" "$AUDIT" "best effort"
has "audit: residual risk becomes a follow-up clarify item" "$AUDIT" "residual"
has "verify: flaky tests are fixed, never retried, skipped or deferred" "$VERIFY" "never retried, skipped or deferred"
has "items: large requirements get their own items" "$ITEMS" "their own items"
has "items: one state-of-the-art check per feature" "$ITEMS" "state-of-the-art check"
has "items: no legacy code unless the owner marks it" "$ITEMS" "legacy"
has "verify: tests are optimised for speed" "$VERIFY" "never waits longer"

# --- 4. capacity, stall limits and background shells --------------------------
has "orchestration: idle capacity rule" "$ORCH" "idle capacity"
has "orchestration: resource check before every start" "$ORCH" "max_busy_percent"
has "orchestration: 30 min stall check" "$ORCH" "30 min"
has "orchestration: 60 tool calls stall check" "$ORCH" "60 tool calls"
has "orchestration: 15 min stop rule" "$ORCH" "15 min"
has "orchestration: subagent briefs forbid background shells" "$ORCH" "run_in_background"

# --- 5. communication (ask rules, dont_ask_twice, veto codes) ---
hasany "dont_ask_twice documented in the ask skills" "dont_ask_twice" "$ACTIVE" "$PASSIVE"
has "active: ask generously unless completely clear" "$ACTIVE" "completely clear"
has "passive: ask generously unless completely clear" "$PASSIVE" "completely clear"
has "active: GO question as soon as no open question is left" "$ACTIVE" "no open question left"
has "autonomous: no Ask tool at all" "$AUTO" "No Ask tool"
has "autonomous: veto codes only for real consequences" "$AUTO" "real consequences"
has "active: ntfy lists one line per finished item" "$ACTIVE" "one line per finished item"
has "active: ntfy text in the owner's language with umlauts" "$ACTIVE" "real umlauts"
has "autonomous: end-of-run report lists finished items" "$AUTO" "end-of-run report: one line per item finished"
has "budget: money inside approved budgets" "$BUDGET" "inside approved budgets"
has "budget: active mode applies no budget stops" "$BUDGET" "In active mode credo applies no budget stops"

# --- 6. safety (target paths, shell variables, sensitive data, licences, redaction) ---
has "safety: check target path before every write" "$SAFETY" "target path"
has "safety: no delete of a path with a shell variable" "$SAFETY" "shell variable"
has "safety: literal paths only" "$SAFETY" "literal path"
has "safety: no sensitive data in searches or fetches" "$SAFETY" "sensitive data"
has "safety: licence rule" "$SAFETY" "explicit licence"
has "safety: permissive licences for foreign code" "$SAFETY" "permissive"
has "safety: GPL and AGPL only as inspiration or a separate service" "$SAFETY" "GPL"
has "safety: redact personal data before commit" "$SAFETY" "redact"
has "safety: own disposable files may be deleted" "$SAFETY" "disposable"

# --- 7. release and setup ---
has "autonomous: release when no GO item is buildable" "$AUTO" "release.auto"
has "setup asks once for release.auto" "$SETUP" "release finished changes automatically"
has "migrate asks once for release.auto" "$MIGRATE" "release finished changes automatically"

# --- 8. docs ------------------------------------------------------------------
has "credo guide: builder range" "$GUIDE" "builders.min_per_area"
has "credo guide: release.auto" "$GUIDE" "release.auto"
has "credo guide: dont_ask_twice" "$GUIDE" "dont_ask_twice"

echo "test-credo-defaults: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
