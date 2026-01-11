#!/bin/bash
# Dogma: Prompt Intervention Reminder
# Reminds Claude to consider using skills proactively
#
# Shows a compact reminder at every prompt to suggest relevant skills
# before diving into work. References CLAUDE.prompt-intervention.md.
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch
# ENV: CLAUDE_MB_DOGMA_PROMPT_INTERVENTION=true (default) | false

trap 'exit 0' ERR

# === DEBUG MODE ===
DEBUG="${CLAUDE_MB_DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== prompt-intervention-reminder.sh START $(date) ===" >&2
fi

# === MASTER SWITCH ===
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${CLAUDE_MB_DOGMA_PROMPT_INTERVENTION:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Read JSON input from stdin
INPUT=$(cat 2>/dev/null || true)

# Find CLAUDE.prompt-intervention.md
INTERVENTION_FILE=""
if [ -f "CLAUDE/CLAUDE.prompt-intervention.md" ]; then
    INTERVENTION_FILE="CLAUDE/CLAUDE.prompt-intervention.md"
elif [ -f "CLAUDE.prompt-intervention.md" ]; then
    INTERVENTION_FILE="CLAUDE.prompt-intervention.md"
elif [ -f ".claude/CLAUDE.prompt-intervention.md" ]; then
    INTERVENTION_FILE=".claude/CLAUDE.prompt-intervention.md"
fi

# If no intervention file, skip
if [ -z "$INTERVENTION_FILE" ]; then
    exit 0
fi

# Output compact reminder
echo ""
echo "<dogma-skill-reminder>"
echo "Before starting, consider if a skill would help:"
echo "- Complex/multi-step task? -> suggest /create-plan"
echo "- Need to prioritize? -> suggest /consider:eisenhower-matrix"
echo "- Debugging issue? -> suggest /debug or /debug-like-expert"
echo "- Decision needed? -> suggest /consider:* (first-principles, swot, etc.)"
echo ""
echo "Only suggest skills that are actually available!"
echo "See @${INTERVENTION_FILE}"
echo "</dogma-skill-reminder>"

exit 0
