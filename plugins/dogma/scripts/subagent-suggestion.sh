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

# Output compact reminder
echo ""
echo "<dogma-subagent-reminder>"
echo "Subagent-First: Check before EVERY action if a specialized agent exists."
echo ""
echo "Available agents:"
echo "- Code Analysis: code-reviewer, code-architect, code-explorer"
echo "- Development: agent-creator, plugin-validator, skill-reviewer"
echo "- Auditing: skill-auditor, slash-command-auditor, subagent-auditor"
echo "- Built-in: Explore, Plan, general-purpose"
echo ""
echo "Rules:"
echo "- 2+ independent tasks -> use Hydra"
if [ "$TESTS_EXIST" = "true" ]; then
    echo "- Tests exist -> TDD is mandatory"
fi
echo ""
echo "See @${SUBAGENTS_FILE}"
if [ -n "$PERMISSIONS_FILE" ]; then
    echo "Permissions: @${PERMISSIONS_FILE}"
fi
echo "</dogma-subagent-reminder>"

exit 0
