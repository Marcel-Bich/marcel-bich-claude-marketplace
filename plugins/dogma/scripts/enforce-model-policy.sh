#!/bin/bash
# For Anthropic plugin agents: if no model specified, inherit from parent
# This ensures subagents use the main agent's model instead of the plugin's
# hardcoded default (often sonnet)
#
# Behavior:
# - Explicit model passed -> respect it (no override)
# - No model + Anthropic plugin -> inherit from ~/.claude/settings.json
# - No model + Third-party plugin -> unchanged (use agent default)
#
# Technical notes:
# - "inherit" is not a valid API value, only sonnet/opus/haiku
# - The hook resolves inherit by reading from settings.json
# - The hook must output the full merged tool_input (Claude Code replaces, not merges)
#
# ENV: CLAUDE_MB_DOGMA_DEBUG=true | false (default) - debug logging to /tmp/dogma-debug.log

# Source shared library for debug logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-permissions.sh"

dogma_debug_log "=== enforce-model-policy.sh START ==="

# Read JSON from stdin
input=$(cat)

# Extract parameters
AGENT_TYPE=$(echo "$input" | jq -r '.tool_input.subagent_type // empty')
MODEL=$(echo "$input" | jq -r '.tool_input.model // empty')

# No agent type specified - allow as-is
if [[ -z "$AGENT_TYPE" ]]; then
  dogma_debug_log "No agent type - skipping"
  dogma_debug_log "=== enforce-model-policy.sh END ==="
  exit 0
fi

dogma_debug_log "Agent: $AGENT_TYPE, Model: ${MODEL:-<none>}"

# Built-in agents (no colon) - allow as-is
if [[ "$AGENT_TYPE" != *":"* ]]; then
  dogma_debug_log "Built-in agent - skipping"
  dogma_debug_log "=== enforce-model-policy.sh END ==="
  exit 0
fi

# If model is explicitly specified, respect that choice
if [[ -n "$MODEL" ]]; then
  dogma_debug_log "Model explicitly set to $MODEL - respecting"
  dogma_debug_log "=== enforce-model-policy.sh END ==="
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
  dogma_debug_log "Non-Anthropic plugin ($PLUGIN_NAME) - skipping"
  dogma_debug_log "=== enforce-model-policy.sh END ==="
  exit 0
fi

# Resolve "inherit" to actual model from settings.json
# Valid API values: sonnet, opus, haiku (not "inherit")
resolve_model() {
  local settings_model
  settings_model=$(jq -r '.model // empty' ~/.claude/settings.json 2>/dev/null)

  case "${settings_model,,}" in
    opus*|claude-opus*) echo "opus" ;;
    sonnet*|claude-sonnet*) echo "sonnet" ;;
    haiku*|claude-haiku*) echo "haiku" ;;
    *) echo "opus" ;;  # Default to opus
  esac
}

# No model specified + Anthropic plugin -> force parent model
RESOLVED_MODEL=$(resolve_model)
dogma_debug_log "Resolved model from settings: $RESOLVED_MODEL"
dogma_debug_log "Overriding model to $RESOLVED_MODEL for $AGENT_TYPE"

# Merge original tool_input with resolved model
MERGED_INPUT=$(echo "$input" | jq --arg model "$RESOLVED_MODEL" '.tool_input + {"model": $model}')
dogma_debug_log "Merged input: $MERGED_INPUT"
dogma_debug_log "=== enforce-model-policy.sh END ==="

# Output with full merged input (Claude Code replaces instead of merging)
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "updatedInput": $MERGED_INPUT
  }
}
EOF
exit 0
