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

# Check if tests exist (for TDD rule)
TESTS_EXIST="false"
if [ -d "tests" ] || [ -d "test" ] || [ -d "__tests__" ] || [ -d "spec" ]; then
    TESTS_EXIST="true"
fi
# Also check for common test file patterns
if ls *.test.* *.spec.* 2>/dev/null | head -1 >/dev/null 2>&1; then
    TESTS_EXIST="true"
fi

# Output MANDATORY instruction (not just a reminder)
echo ""
echo "<dogma-subagent-instruction>"
echo "MANDATORY: Before your FIRST action, you MUST check for subagent delegation."
echo ""
echo "Decision flow:"
echo "1. Does this need user interaction? -> You may act directly"
echo "2. Does a specialized agent exist? -> USE Task tool with that agent"
echo "3. No specialized agent? -> USE Task tool with general-purpose"
echo "4. 2+ independent tasks? -> USE Hydra (/hydra:parallel)"
echo ""
echo "Available agents: code-reviewer, code-architect, code-explorer, agent-creator,"
echo "plugin-validator, skill-reviewer, skill-auditor, slash-command-auditor,"
echo "subagent-auditor, Explore, Plan, general-purpose"
echo ""
echo "FORBIDDEN without Task first: Bash, Write, Edit for implementation work"
echo "ALLOWED without Task: Read, Glob, Grep (research), user questions"
if [ "$TESTS_EXIST" = "true" ]; then
    echo ""
    echo "TDD MANDATORY: Tests exist - write test first, then implementation"
fi
echo ""
echo "Reference: @${SUBAGENTS_FILE}"
if [ -n "$PERMISSIONS_FILE" ]; then
    echo "Permissions: @${PERMISSIONS_FILE}"
fi
echo "</dogma-subagent-instruction>"

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
