#!/bin/bash
# For Anthropic plugin agents: ensure at least the higher model is used
# Compares agent default (usually sonnet) with parent model from settings.json
# and uses whichever is higher (opus > sonnet > haiku)
#
# Behavior:
# - No agent type -> skip
# - Explicit model + allow_downgrade=true -> respect (no override)
# - Explicit model + allow_downgrade=false -> override if lower than parent
# - Built-in agent + enforce_builtin=false -> skip
# - Built-in agent + enforce_builtin=true -> enforce parent model
# - No model + Anthropic plugin -> max(agent_default, parent_model)
# - No model + Third-party plugin -> unchanged (use agent default)
#
# Examples:
# - Agent=sonnet, Parent=opus -> opus (parent higher)
# - Agent=sonnet, Parent=haiku -> sonnet (agent higher)
# - Agent=sonnet, Parent=sonnet -> sonnet (equal)
# - Explicit=haiku, Parent=opus, allow_downgrade=false -> opus (downgrade blocked)
# - Explicit=haiku, Parent=opus, allow_downgrade=true -> haiku (downgrade allowed)
# - Built-in agent, enforce_builtin=true -> parent model enforced
#
# Technical notes:
# - "inherit" is not a valid API value, only sonnet/opus/haiku
# - The hook must output the full merged tool_input (Claude Code replaces, not merges)
#
# ENV: CLAUDE_MB_DOGMA_DEBUG=true | false (default) - debug logging to /tmp/dogma-debug.log
# ENV: CLAUDE_MB_DOGMA_BUILTIN_INHERIT_MODEL=true (default) | false - enforce model policy for built-in agents
# ENV: CLAUDE_MB_DOGMA_ALLOW_MODEL_DOWNGRADE=false (default) | true - allow explicit model to downgrade below parent

# Source shared library for debug logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-permissions.sh"

dogma_debug_log "=== enforce-model-policy.sh START ==="

# Env var defaults
BUILTIN_INHERIT="${CLAUDE_MB_DOGMA_BUILTIN_INHERIT_MODEL:-true}"
ALLOW_DOWNGRADE="${CLAUDE_MB_DOGMA_ALLOW_MODEL_DOWNGRADE:-false}"

dogma_debug_log "Config: BUILTIN_INHERIT=$BUILTIN_INHERIT, ALLOW_DOWNGRADE=$ALLOW_DOWNGRADE"

# Model ranking: opus=3, sonnet=2, haiku=1
model_rank() {
  case "${1,,}" in
    opus*|claude-opus*) echo 3 ;;
    sonnet*|claude-sonnet*) echo 2 ;;
    haiku*|claude-haiku*) echo 1 ;;
    *) echo 2 ;;  # Default to sonnet rank
  esac
}

normalize_model() {
  case "${1,,}" in
    opus*|claude-opus*) echo "opus" ;;
    sonnet*|claude-sonnet*) echo "sonnet" ;;
    haiku*|claude-haiku*) echo "haiku" ;;
    *) echo "sonnet" ;;  # Default to sonnet
  esac
}

# Get parent model from settings.json
get_parent_model() {
  local settings_model
  settings_model=$(jq -r '.model // empty' ~/.claude/settings.json 2>/dev/null)
  normalize_model "$settings_model"
}

# Choose the higher model between agent default and parent
# Anthropic agents typically default to sonnet
choose_best_model() {
  local agent_default="sonnet"  # Anthropic agents usually default to sonnet
  local parent_model
  parent_model=$(get_parent_model)

  local agent_rank parent_rank
  agent_rank=$(model_rank "$agent_default")
  parent_rank=$(model_rank "$parent_model")

  dogma_debug_log "Agent default: $agent_default (rank $agent_rank)"
  dogma_debug_log "Parent model: $parent_model (rank $parent_rank)"

  if [[ $parent_rank -ge $agent_rank ]]; then
    echo "$parent_model"
  else
    echo "$agent_default"
  fi
}

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

# If model is explicitly specified, check downgrade policy
if [[ -n "$MODEL" ]]; then
  if [[ "$ALLOW_DOWNGRADE" == "true" ]]; then
    dogma_debug_log "Model explicitly set to $MODEL - respecting (downgrade allowed)"
    dogma_debug_log "=== enforce-model-policy.sh END ==="
    exit 0
  else
    # Check if explicit model is lower than parent - override if so
    PARENT_MODEL=$(get_parent_model)
    EXPLICIT_RANK=$(model_rank "$MODEL")
    PARENT_RANK=$(model_rank "$PARENT_MODEL")
    dogma_debug_log "Downgrade check: explicit=$MODEL (rank $EXPLICIT_RANK), parent=$PARENT_MODEL (rank $PARENT_RANK)"
    if [[ $EXPLICIT_RANK -ge $PARENT_RANK ]]; then
      dogma_debug_log "Explicit model >= parent - respecting"
      dogma_debug_log "=== enforce-model-policy.sh END ==="
      exit 0
    fi
    # Explicit model is lower than parent - override to parent
    RESOLVED_MODEL="$PARENT_MODEL"
    dogma_debug_log "Explicit model < parent - overriding to $RESOLVED_MODEL (downgrade blocked)"
    MERGED_INPUT=$(echo "$input" | jq --arg model "$RESOLVED_MODEL" '.tool_input + {"model": $model}')
    dogma_debug_log "Merged input: $MERGED_INPUT"
    dogma_debug_log "=== enforce-model-policy.sh END ==="
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
  fi
fi

# Built-in agents (no colon) - check enforce policy
if [[ "$AGENT_TYPE" != *":"* ]]; then
  if [[ "$BUILTIN_INHERIT" != "true" ]]; then
    dogma_debug_log "Built-in agent - skipping (builtin_inherit=false)"
    dogma_debug_log "=== enforce-model-policy.sh END ==="
    exit 0
  fi
  # Enforce parent model for built-in agent
  PARENT_MODEL=$(get_parent_model)
  dogma_debug_log "Built-in agent - enforcing parent model: $PARENT_MODEL"
  MERGED_INPUT=$(echo "$input" | jq --arg model "$PARENT_MODEL" '.tool_input + {"model": $model}')
  dogma_debug_log "Merged input: $MERGED_INPUT"
  dogma_debug_log "=== enforce-model-policy.sh END ==="
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

# No model specified + Anthropic plugin -> use higher of (agent default, parent model)
RESOLVED_MODEL=$(choose_best_model)
dogma_debug_log "Chosen model (max of both): $RESOLVED_MODEL"
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
