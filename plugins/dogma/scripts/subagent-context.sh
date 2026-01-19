#!/bin/bash
# Dogma: Subagent Context Reminder
# Reminds main agent to include proper context when spawning subagents
#
# This hook triggers on Task tool usage to ensure subagents receive
# necessary context about user intent and project rules.

trap 'exit 0' ERR

# Master switch
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# Output reminder (not blocking, just informational)
cat <<'EOF'
<dogma-subagent-context>
SUBAGENT RULES (auto-appended):
- Read CLAUDE.md for project conventions
- NO git push - only main agent pushes after permission
- Commit only files relevant to your specific task
- Report completion, do not assume overall success
</dogma-subagent-context>
EOF

exit 0
