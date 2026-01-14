#!/bin/bash
# Token Protection Hook - Blocks commands that could expose tokens/credentials
# PreToolUse hook for Bash - runs BEFORE command execution

# Exit cleanly on any error (don't break Claude)
trap 'exit 0' ERR

# Output helper for blocking
output_block() {
    local reason="$1"
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"$reason"}}
EOF
    exit 0
}

# Debug mode
DEBUG="${CLAUDE_MB_DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-debug.log
    set -x
fi

# Master switch
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# Feature switch
ENABLED="${CLAUDE_MB_DOGMA_TOKEN_PROTECTION:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Read input
INPUT=$(cat 2>/dev/null || true)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$TOOL_NAME" != "Bash" ] && exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# =============================================================================
# DANGEROUS COMMANDS - Commands that could expose tokens in output
# =============================================================================

# Git remote commands (tokens can be embedded in URLs)
if echo "$COMMAND" | grep -qE '^\s*git\s+remote\s+(-v|show|get-url)'; then
    output_block "BLOCKED: 'git remote -v/show/get-url' can expose tokens embedded in remote URLs. Use 'git remote' (without -v) to list remote names only, or check .git/config manually if needed."
fi

if echo "$COMMAND" | grep -qE 'git\s+config.*remote\..*\.url'; then
    output_block "BLOCKED: 'git config remote.*.url' can expose tokens embedded in remote URLs."
fi

# Environment variable dumps (expose all tokens)
if echo "$COMMAND" | grep -qE '^\s*(env|printenv|export|set)\s*$'; then
    output_block "BLOCKED: '$COMMAND' would expose all environment variables including tokens. Use specific variable checks like '[ -n \"\$VAR\" ]' instead."
fi

# Direct token variable access
if echo "$COMMAND" | grep -qE '\$\{?(GITHUB_TOKEN|GITLAB_TOKEN|BITBUCKET_TOKEN|NPM_TOKEN|PYPI_TOKEN|AWS_SECRET|API_KEY|AUTH_TOKEN|ACCESS_TOKEN|BEARER_TOKEN|SECRET_KEY|PRIVATE_KEY)'; then
    output_block "BLOCKED: Command references a token/secret variable directly. This could expose sensitive credentials in output."
fi

# Credential files
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat|view)\s+.*(\~\/\.netrc|\.git-credentials|\.npmrc|\.pypirc|credentials|secrets|\.env)'; then
    output_block "BLOCKED: Command would read a credential/secrets file that may contain tokens."
fi

# Git credential helpers
if echo "$COMMAND" | grep -qE 'git\s+credential'; then
    output_block "BLOCKED: 'git credential' commands can expose stored tokens."
fi

# Curl/wget with auth headers visible
if echo "$COMMAND" | grep -qiE '(curl|wget).*(-H|--header).*([Aa]uthorization|[Bb]earer|[Tt]oken)'; then
    output_block "BLOCKED: Command includes authorization headers that could expose tokens in output/logs."
fi

# SSH key content
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more)\s+.*id_(rsa|ed25519|ecdsa|dsa)'; then
    output_block "BLOCKED: Command would expose SSH private key content."
fi

# All checks passed
exit 0
