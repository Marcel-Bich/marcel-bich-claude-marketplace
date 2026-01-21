#!/bin/bash
# For Anthropic plugin agents: if no model specified, default to inherit
# This ensures subagents use the main agent's model (e.g., Opus) instead of
# the plugin's hardcoded default (often sonnet)
#
# Behavior:
# - Explicit model passed -> respect it (no override)
# - No model + Anthropic plugin -> force inherit
# - No model + Third-party plugin -> unchanged (use agent default)

# Read JSON from stdin
input=$(cat)

# Extract parameters
AGENT_TYPE=$(echo "$input" | jq -r '.tool_input.subagent_type // empty')
MODEL=$(echo "$input" | jq -r '.tool_input.model // empty')

# No agent type specified - allow as-is
if [[ -z "$AGENT_TYPE" ]]; then
  exit 0
fi

# Built-in agents (no colon) - allow as-is
if [[ "$AGENT_TYPE" != *":"* ]]; then
  exit 0
fi

# If model is explicitly specified, respect that choice
if [[ -n "$MODEL" ]]; then
  exit 0
fi

# Extract plugin name (part before colon)
PLUGIN_NAME="${AGENT_TYPE%%:*}"

# Anthropic PROPRIETARY plugins - force inherit when no model specified
# (MIT-licensed: hookify, plugin-dev, pr-review-toolkit are NOT in this list)
ANTHROPIC_PLUGINS=(
  "feature-dev"
  "code-simplifier"
  "agent-sdk-dev"
  "code-review"
  "commit-commands"
  "context7"
  "frontend-design"
  "github"
  "greptile"
  "playwright"
  "ralph-loop"
  "security-guidance"
  "superpowers"
  "typescript-lsp"
)

# Check if this is an Anthropic plugin
IS_ANTHROPIC=false
for plugin in "${ANTHROPIC_PLUGINS[@]}"; do
  if [[ "$PLUGIN_NAME" == "$plugin" ]]; then
    IS_ANTHROPIC=true
    break
  fi
done

# Allow non-Anthropic plugins as-is
if [[ "$IS_ANTHROPIC" == false ]]; then
  exit 0
fi

# No model specified + Anthropic plugin -> force inherit
cat <<EOF
{
  "hookSpecificOutput": {
    "permissionDecision": "allow",
    "updatedInput": {"model": "inherit"}
  },
  "systemMessage": "Model defaulted to inherit for Anthropic agent: $AGENT_TYPE"
}
EOF
exit 0
