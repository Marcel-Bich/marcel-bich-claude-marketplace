#!/bin/bash
# Tests for the credo defaults: the config keys with their built-in values
# (read through credo-config.sh), and the wording invariants of the skills, docs
# and commands (no fixed fail-count brake, builder range, capacity and stall
# limits, Ask and veto rules, safety and verify rules, release and
# dont_ask_twice, owner actions in full while the owner is present). Wording checks
# are grep-based, like the other doc invariants.
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
check "items.go_stall_hours default" "24" "$("$CFG" get items.go_stall_hours 2>/dev/null)"

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
HOOK="$PLUGIN_DIR/hooks/credo-session-start.sh"
MOVE="$PLUGIN_DIR/scripts/credo-item-move.sh"

hasany "fix rounds follow the preset ladder" "stage ladder" "$AUDIT" "$ORCH" "$ITEMS"
# fix-round hand-back: the active preset is the only source of the escalation stages, the
# main agent decides while attempts are left, the audit never brakes, the owner is asked only
# at back-to-human or for a genuine owner decision, and the early hand-back on an unchanged
# finding is a default that a repo's RULES.md can switch off
has "audit: the active preset is the only source of the escalation stages" "$AUDIT" "escalation stages for fix rounds"
has "orchestration: the active preset is the only source of the escalation stages" "$ORCH" "is the only source of the escalation stages"
has "audit: no owner question while attempts are left" "$AUDIT" "never an owner question"
has "orchestration: no owner question while attempts are left" "$ORCH" "never an owner question"
has "items: next fix round is the main agent's decision" "$ITEMS" "main agent's decision"
has "audit: an audit subagent never declares a brake" "$AUDIT" "declares a brake"
has "orchestration: an audit subagent never declares a brake" "$ORCH" "declares a brake"
has "audit: no fail count and no brake of its own" "$AUDIT" "keep no fail count and no brake"
has "orchestration: no fail count and no brake of its own" "$ORCH" "keep no fail count and no brake"
has "items: an audit subagent never declares a brake" "$ITEMS" "never declares a brake itself"
has "audit: unchanged-finding hand-back is switchable by RULES.md" "$AUDIT" "can switch that default off"
has "orchestration: unchanged-finding hand-back is switchable by RULES.md" "$ORCH" "can switch that default off"
has "items: unchanged-finding hand-back is switchable by RULES.md" "$ITEMS" "can switch that default off"
has "presets template: hand-back is switchable by RULES.md" "$PLUGIN_DIR/templates/presets.default.yaml" "can switch that default off"
has "guide: hand-back is switchable by RULES.md" "$GUIDE" "can switch that default off"
has "audit: RULES.md overrides the defaults" "$AUDIT" "overrides these defaults"
has "orchestration: RULES.md overrides the defaults" "$ORCH" "overrides these defaults"
has "orchestration: every brief carries the mandatory RULES.md brief lines" "$ORCH" "mandatory brief lines from"
has "orchestration: blocker claims are proposals the main agent verifies" "$ORCH" "owner-decision claims are proposals"
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
has "autonomous: veto only for decisions the owner notices in the product" "$AUTO" "the owner notices in the product"
has "verify: a veto is only for decisions the owner notices in the product" "$VERIFY" "the owner notices in the product"
has "verify: internal process decisions get no veto code" "$VERIFY" "get no veto code"
has "verify: the agent closes a veto itself when its item is done" "$VERIFY" "closes it itself"
has "session-start legend: product-visible veto threshold" "$HOOK" "the owner notices in the product"
has "session-start legend: the agent closes vetos itself" "$HOOK" "you close a veto yourself"
has "active: veto only for decisions the owner notices in the product" "$ACTIVE" "the owner notices in the product"
has "items: veto only for decisions the owner notices in the product" "$ITEMS" "notices in the product"
has "session-start legend: every new number from credo-code-next.sh" "$HOOK" "Get every new T/Q/V number from credo-code-next.sh <type>"
has "session-start legend: the handoff's next free number is informational" "$HOOK" "the handoff's next free number is informational only"
has "verify: every new number from credo-code-next.sh" "$VERIFY" "Get every new T/Q/V number from credo-code-next.sh <type>"
has "verify: the counters are per project, not per session" "$VERIFY" "Three separate counters per project"
has "item-move: internal process decisions stay in the History" "$MOVE" "Internal process decisions stay in the History"
lacks "no veto demand for every agent decision (old wording)" 'name it in the next (reply|report)[^.]*so the user can veto'
has "active: ntfy lists one line per finished item" "$ACTIVE" "one line per finished item"
has "active: ntfy text in the owner's language with umlauts" "$ACTIVE" "real umlauts"
has "autonomous: end-of-run report lists finished items" "$AUTO" "end-of-run report: one line per item finished"
has "budget: money inside approved budgets" "$BUDGET" "inside approved budgets"
has "budget: active mode applies no budget stops" "$BUDGET" "In active mode credo applies no budget stops"

# --- 5b. owner actions in full while the owner is present (presence rule) ---
has "active: owner actions in full while the owner is present" "$ACTIVE" "Owner actions in full while the owner is present"
has "active: presence from an owner prompt within the last hour" "$ACTIVE" "within the last hour"
has "active: away after more than an hour without owner prompt" "$ACTIVE" "over an hour"
has "active: away keeps the owner action open" "$ACTIVE" "keep the owner action open"
has "active: owner action presented again at the first owner prompt" "$ACTIVE" "first owner prompt after the absence"
has "passive: owner actions rule shared with active" "$PASSIVE" "Owner actions in full while the owner is present"
has "autonomous: keep-alive and self-wake are not owner prompts" "$AUTO" "NOT owner prompts"
has "autonomous: owner action stays open while away" "$AUTO" "stays open"
has "verify: owner-facing tests follow the presence rule" "$VERIFY" "Owner-facing tests and tasks follow the presence rule"
has "credo guide: owner actions in full" "$GUIDE" "Owner actions in full while the owner is present"
has "README: owner actions in full" "$PLUGIN_DIR/README.md" "Owner actions (commands, installs, tests, clicks)"

# --- 6. safety (target paths, shell variables, sensitive data, licences, redaction) ---
has "safety: check target path before every write" "$SAFETY" "target path"
has "safety: no delete of a path with a shell variable" "$SAFETY" "shell variable"
has "safety: literal paths only" "$SAFETY" "literal path"
has "safety: no sensitive data in searches or fetches" "$SAFETY" "sensitive data"
has "safety: licence rule" "$SAFETY" "explicit licence"
has "safety: permissive licences for foreign code" "$SAFETY" "permissive"
has "safety: GPL and AGPL only as inspiration or a separate service" "$SAFETY" "GPL"
has "safety: redact personal data before commit" "$SAFETY" "redact"
has "safety: in-process key loading only when the repo grants it" "$SAFETY" "In-process key loading (repo-granted)"
has "safety: a blocked command is not no access" "$SAFETY" "A blocked command is not"
has "safety: own disposable files may be deleted" "$SAFETY" "disposable"

# --- 7. release and setup ---
has "autonomous: release when no GO item is buildable" "$AUTO" "release.auto"
has "setup asks once for release.auto" "$SETUP" "release finished changes automatically"
has "migrate asks once for release.auto" "$MIGRATE" "release finished changes automatically"

# --- 8. docs ------------------------------------------------------------------
has "credo guide: builder range" "$GUIDE" "builders.min_per_area"
has "credo guide: release.auto" "$GUIDE" "release.auto"
has "credo guide: dont_ask_twice" "$GUIDE" "dont_ask_twice"

# --- 9. GO stall classification, handoff labels, duplicates, grants (#142) ---
COMPACT="$PLUGIN_DIR/skills/compact-plus/SKILL.md"
RULES_SKILL="$PLUGIN_DIR/skills/rules/SKILL.md"
SAFETY_SKILL="$PLUGIN_DIR/skills/safety/SKILL.md"
has "items: GO stall classification section" "$ITEMS" "GO stall classification"
has "items: idle report names the class of each GO item" "$ITEMS" "All GO items wait on the owner"
has "items: handoff labels re-checked against the DoD" "$ITEMS" "Handoff labels and unticked DoD boxes"
has "items: duplicate removal only with the owner yes" "$ITEMS" "--remove-duplicate <path>"
has "autonomous: classify stalled GO items before an idle report" "$AUTO" "Classify stalled GO items"
has "autonomous: the stall helper is named" "$AUTO" "credo-go-stall.sh"
has "compact-plus: handoff labels checked against open DoD" "$COMPACT" "waits on T38"
has "compact-plus: next free number is informational" "$COMPACT" "informational only, the real numbers always come from"
has "verify: shortened repeats keep the copyable command" "$VERIFY" "Shortened repeats keep the command"
has "rules: owner question checked against grants first" "$RULES_SKILL" "Before an owner question or an approval park"
has "safety: grant check before an install park" "$SAFETY_SKILL" "waits on approval"

echo "test-credo-defaults: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
