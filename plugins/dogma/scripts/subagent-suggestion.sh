#!/bin/bash
# Dogma: Subagent Suggestion Reminder
# Reminds Claude to consider using subagents before actions
#
# Shows a compact reminder at every prompt to check if a specialized
# subagent exists for the task. References CLAUDE.subagents.md.
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch
# ENV: CLAUDE_MB_DOGMA_SUBAGENT_SUGGESTION=true (default) | false

trap 'exit 0' ERR

# === DEBUG MODE ===
DEBUG="${CLAUDE_MB_DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== subagent-suggestion.sh START $(date) ===" >&2
fi

# === MASTER SWITCH ===
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${CLAUDE_MB_DOGMA_SUBAGENT_SUGGESTION:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Read JSON input from stdin
INPUT=$(cat 2>/dev/null || true)

# Find CLAUDE.subagents.md
SUBAGENTS_FILE=""
if [ -f "CLAUDE/CLAUDE.subagents.md" ]; then
    SUBAGENTS_FILE="CLAUDE/CLAUDE.subagents.md"
elif [ -f "CLAUDE.subagents.md" ]; then
    SUBAGENTS_FILE="CLAUDE.subagents.md"
elif [ -f ".claude/CLAUDE.subagents.md" ]; then
    SUBAGENTS_FILE=".claude/CLAUDE.subagents.md"
fi

# If no subagents file, skip
if [ -z "$SUBAGENTS_FILE" ]; then
    exit 0
fi

# Check for DOGMA-PERMISSIONS.md (workflow permissions)
PERMISSIONS_FILE=""
if [ -f "DOGMA-PERMISSIONS.md" ]; then
    PERMISSIONS_FILE="DOGMA-PERMISSIONS.md"
elif [ -f ".claude/DOGMA-PERMISSIONS.md" ]; then
    PERMISSIONS_FILE=".claude/DOGMA-PERMISSIONS.md"
fi

# Check delegation settings from DOGMA-PERMISSIONS.md
SKILL_DELEGATION="false"
TASK_DELEGATION="false"
if [ -n "$PERMISSIONS_FILE" ]; then
    PERMS_CONTENT=$(cat "$PERMISSIONS_FILE" 2>/dev/null || true)
    if echo "$PERMS_CONTENT" | grep -qiE '^\s*-\s*\[x\].*Skill tool.*counts as delegation'; then
        SKILL_DELEGATION="true"
    fi
    if echo "$PERMS_CONTENT" | grep -qiE '^\s*-\s*\[x\].*Task tool.*counts as delegation'; then
        TASK_DELEGATION="true"
    fi
fi

# Check if tests exist (for TDD rule)
TESTS_EXIST="false"
if [ -d "tests" ] || [ -d "test" ] || [ -d "__tests__" ] || [ -d "spec" ]; then
    TESTS_EXIST="true"
fi
# Also check for common test file patterns
if ls *.test.* *.spec.* 2>/dev/null | head -1 >/dev/null 2>&1; then
    TESTS_EXIST="true"
fi

# Output MANDATORY orchestration instruction
echo ""
echo "<dogma-orchestration>"
echo "MANDATORY ORCHESTRATION FLOW - Follow this for EVERY task:"
echo ""
echo "== STEP 0: PARALLELIZATION ANALYSIS (AUTONOMOUS) =="
echo "For EVERY new user prompt, immediately analyze:"
echo "1. Can 2+ independent tasks be identified in the prompt?"
echo "   - Independent = no shared state, no dependencies"
echo "   - Examples: 'Do A and B' or 'Implement X, Y, Z'"
echo "2. YES with file changes -> Hydra (/hydra:parallel) for isolated worktrees"
echo "3. YES but read-only/explore/planning -> Parallel Task calls (no Hydra needed)"
echo "4. NO -> Sequential with subagents"
echo ""
echo "Hydra = implementation needing isolation. Parallel Tasks = research/planning."
echo "IMPORTANT: YOU decide this autonomously - NO user confirmation needed!"
echo "Goal: Maximum parallelization where sensible."
echo ""
echo "== STEP 1: DELEGATION CHECK =="
echo "Before ANY action, check:"
echo "- User interaction needed? -> You may act directly"
echo "- Specialized agent exists? -> USE Task tool with that agent"
echo "- No specialized agent? -> USE Task tool with general-purpose"
echo "- 2+ independent tasks? -> USE Hydra (/hydra:parallel) MANDATORY"
echo ""
echo "FORBIDDEN without Task first: Bash, Write, Edit for implementation"
echo "ALLOWED without Task: Read, Glob, Grep (research), user questions"
echo ""
# Show delegation rules based on checkbox settings
if [ "$SKILL_DELEGATION" = "true" ] || [ "$TASK_DELEGATION" = "true" ]; then
    echo "== DELEGATION PERMISSIONS (from DOGMA-PERMISSIONS.md) =="
    if [ "$SKILL_DELEGATION" = "true" ]; then
        echo "- [x] Skill tool counts as delegation -> Execute skills DIRECTLY (NO subagent!)"
        echo "      /skill-name call -> use Skill tool -> execute yourself"
    fi
    if [ "$TASK_DELEGATION" = "true" ]; then
        echo "- [x] Task tool counts as delegation -> Task calls count as delegation"
    fi
    echo ""
fi
echo "== STEP 2: ANALYSIS =="
echo "a) Tests exist in project? -> TDD is MANDATORY"
echo "b) Multiple independent tasks? -> Hydra is MANDATORY"
echo ""
echo "== STEP 3: EXECUTION FLOW =="
if [ "$TESTS_EXIST" = "true" ]; then
echo "TDD MODE (tests detected):"
echo "  1. Test-Agent: Write failing test first"
echo "  2. Coding-Agent: Implement until test passes"
else
echo "NON-TDD MODE (no tests):"
echo "  1. Coding-Agent: Implement feature"
echo "  2. Consider: spawn subagent for verification"
fi
echo ""
echo "== STEP 4: REVIEW =="
echo "After implementation:"
echo "  1. Spawn code-reviewer agent"
echo "  2. Apply corrections via subagents"
echo "  3. Run /dogma:lint if available"
echo ""
echo "== STEP 5: FINALIZATION =="
echo "  1. If Hydra: merge worktrees"
echo "  2. Run ALL tests (final verification)"
echo "  3. Inform user with summary"
echo "  4. User accepts -> spawn checklist-manager"
echo ""
echo "== SUBAGENT CONTEXT RULES =="
echo "When spawning Task, ALWAYS include in prompt:"
echo "  0. ANNOUNCE before spawning: '**Spawning:** [agent] **Task:** [summary]'"
echo "  1. User's goal/intent (WHY this task)"
echo "  2. What is TEST/temporary vs REAL work"
echo "  3. What should NOT be committed"
echo "  4. 'Read CLAUDE.md first for project rules'"
echo "  5. 'NO git push - report back to main agent'"
echo "  6. HANDOFF CHAIN - Each subagent tells Main Agent the next step:"
echo "     a) Implementation-Agent -> 'spawn Test-Agent to verify'"
echo "     b) Test-Agent -> bugs found? 'spawn Debug-Agent' : success? continue"
echo "     c) Debug-Agent -> 'spawn Reviewer-Agent'"
echo "     d) Reviewer-Agent -> 'spawn Final-Test-Agent'"
echo "     e) Final-Test-Agent -> runs ALL tests if exist, then 'Main Agent may bump/push'"
echo "  7. When no TDD possible (no tests), Main Agent MUST spawn a verification subagent to check implementation"
echo "  8. 'NEVER add/commit .gitignore-d files - they are ignored intentionally. Run git status, accept ignored files.'"
echo ""
echo "Subagents MAY commit (correct files only), but NEVER push."
echo "Main agent handles push after review."
echo ""
echo "Available agents: code-reviewer, code-architect, code-explorer,"
echo "agent-creator, plugin-validator, skill-reviewer, silent-failure-hunter,"
echo "skill-auditor, slash-command-auditor, subagent-auditor,"
echo "Explore, Plan, general-purpose"
echo ""
echo "Reference: @${SUBAGENTS_FILE}"
if [ -n "$PERMISSIONS_FILE" ]; then
    echo "Permissions: @${PERMISSIONS_FILE}"
fi
echo "</dogma-orchestration>"

# === RESET SUBAGENT STATE EVERY N PROMPTS ===
# This ensures the subagent-first warning triggers again periodically
STATE_DIR="/tmp/dogma-subagent-state"
COUNTER_FILE="$STATE_DIR/prompt-counter"
RESET_INTERVAL=2  # Reset every N prompts

if [ -d "$STATE_DIR" ]; then
    # Read and increment counter
    COUNTER=0
    if [ -f "$COUNTER_FILE" ]; then
        COUNTER=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
    fi
    COUNTER=$((COUNTER + 1))
    # Reset counter if too large to prevent infinite growth
    if [ "$COUNTER" -gt 100 ]; then
        COUNTER=1
    fi
    echo "$COUNTER" > "$COUNTER_FILE" 2>/dev/null || true

    # Reset ALL state every N prompts (not just warning flags)
    if [ $((COUNTER % RESET_INTERVAL)) -eq 0 ]; then
        # Delete warning flags
        find "$STATE_DIR" -name "*.hydra-warned" -delete 2>/dev/null || true
        find "$STATE_DIR" -name "*.fallback-warned" -delete 2>/dev/null || true
        # Delete state files (tool tracking) - but keep counter
        find "$STATE_DIR" -type f ! -name "prompt-counter" -delete 2>/dev/null || true
        if [ "$DEBUG" = "true" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reset ALL subagent state (prompt $COUNTER)" >> /tmp/dogma-debug.log
        fi
    fi
fi

exit 0
