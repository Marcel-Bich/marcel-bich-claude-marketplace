#!/bin/bash
# Token Protection Hook - Blocks commands/reads that could expose tokens/credentials
# PreToolUse hook for Bash and Read - runs BEFORE tool execution

# ALWAYS log to verify hook is called
echo "=== token-protection.sh INVOKED $(date) ===" >> /tmp/dogma-token-protection.log

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

# Log function - always log for debugging
log_debug() {
    echo "[$(date '+%H:%M:%S')] $1" >> /tmp/dogma-token-protection.log
}

log_debug "Hook invoked"

# Master switch
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    log_debug "Master switch OFF - exiting"
    exit 0
fi

# Feature switch
ENABLED="${CLAUDE_MB_DOGMA_TOKEN_PROTECTION:-true}"
if [ "$ENABLED" != "true" ]; then
    log_debug "Token protection disabled - exiting"
    exit 0
fi

# Read input
INPUT=$(cat 2>/dev/null || true)
if [ -z "$INPUT" ]; then
    log_debug "No input received - exiting"
    exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
log_debug "Tool: $TOOL_NAME"

# =============================================================================
# READ TOOL - Scan file for tokens BEFORE reading
# =============================================================================
log_debug "Checking tool type..."
if [ "$TOOL_NAME" = "Read" ]; then
    log_debug "Processing Read tool"
    log_debug "Processing Read tool"
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    log_debug "File path: $FILE_PATH"
    if [ -z "$FILE_PATH" ]; then
        log_debug "Empty file path - exiting"
        exit 0
    fi
    if [ ! -f "$FILE_PATH" ]; then
        log_debug "File does not exist - exiting"
        exit 0
    fi
    log_debug "Scanning file for tokens..."

    # Block known credential files by name
    if echo "$FILE_PATH" | grep -qiE '(\.env|\.netrc|credentials|secrets|\.git-credentials|\.npmrc|\.pypirc|id_rsa|id_ed25519|id_ecdsa|\.pem|\.key)$'; then
        output_block "BLOCKED: Reading credential/secrets file '$FILE_PATH'. These files typically contain sensitive tokens."
    fi

    # Scan file content for token patterns (only if file is small enough)
    FILE_SIZE=$(stat -c%s "$FILE_PATH" 2>/dev/null || echo "0")
    if [ "$FILE_SIZE" -lt 1000000 ]; then  # Only scan files < 1MB
        # GitHub token
        if grep -qE 'ghp_[a-zA-Z0-9]{36}' "$FILE_PATH" 2>/dev/null; then
            output_block "BLOCKED: File '$FILE_PATH' contains a GitHub Personal Access Token (ghp_...). Reading would expose credentials."
        fi
        # Generic token in URL (x-access-token pattern)
        if grep -qE 'x-access-token:[a-zA-Z0-9_-]+@' "$FILE_PATH" 2>/dev/null; then
            output_block "BLOCKED: File '$FILE_PATH' contains embedded access tokens in URLs. Reading would expose credentials."
        fi
        # OpenAI key
        if grep -qE 'sk-[a-zA-Z0-9]{20,}' "$FILE_PATH" 2>/dev/null; then
            if ! grep -qE 'sk-your|sk-xxx|sk-\.\.\.' "$FILE_PATH" 2>/dev/null; then
                output_block "BLOCKED: File '$FILE_PATH' contains an OpenAI API key (sk-...). Reading would expose credentials."
            fi
        fi
        # Anthropic key
        if grep -qE 'sk-ant-[a-zA-Z0-9]{20,}' "$FILE_PATH" 2>/dev/null; then
            output_block "BLOCKED: File '$FILE_PATH' contains an Anthropic API key (sk-ant-...). Reading would expose credentials."
        fi
        # AWS keys
        if grep -qE 'AKIA[0-9A-Z]{16}' "$FILE_PATH" 2>/dev/null; then
            output_block "BLOCKED: File '$FILE_PATH' contains an AWS Access Key. Reading would expose credentials."
        fi
        # Private keys
        if grep -qE '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----' "$FILE_PATH" 2>/dev/null; then
            output_block "BLOCKED: File '$FILE_PATH' contains a private key. Reading would expose credentials."
        fi
    fi

    exit 0
fi

# =============================================================================
# BASH TOOL - Block dangerous commands
# =============================================================================
if [ "$TOOL_NAME" != "Bash" ]; then
    log_debug "Not Bash tool, exiting"
    exit 0
fi

log_debug "Processing Bash tool"
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
log_debug "Command: $COMMAND"

if [ -z "$COMMAND" ]; then
    log_debug "Empty command, exiting"
    exit 0
fi

# =============================================================================
# DANGEROUS COMMANDS - Commands that could expose tokens in output
# =============================================================================
log_debug "Checking dangerous commands..."

# Git remote commands (tokens can be embedded in URLs)
# Catches: git remote -v, git remote --verbose, git remote show, git remote get-url
# Also: /usr/bin/git, command git, sudo git
if echo "$COMMAND" | grep -qE '(^|\||;|&&|\|\||\s)(sudo\s+)?(command\s+)?([/a-z]*\/)?git\s+remote\s+(-v|--verbose|show|get-url)'; then
    log_debug "BLOCKING: git remote"
    output_block "BLOCKED: 'git remote -v/--verbose/show/get-url' can expose tokens embedded in remote URLs. Use 'git remote' (without -v) to list remote names only."
fi

# Git config remote URL
if echo "$COMMAND" | grep -qE 'git\s+config.*(remote\.|url\.)'; then
    output_block "BLOCKED: 'git config' with remote/url can expose tokens embedded in remote URLs."
fi

# Environment variable dumps (expose all tokens)
# Catches: env, printenv, export, set (alone or piped)
# Also: /usr/bin/env, command env, sudo env, bash -c "env"
log_debug "Checking env pattern against: $COMMAND"
if echo "$COMMAND" | grep -qE '(^|\||;|&&|\|\||\s)(sudo\s+)?(command\s+)?([/a-z]*\/)?(env|printenv)(\s*$|\s*\||\s+[^=])'; then
    log_debug "BLOCKING: env/printenv"
    output_block "BLOCKED: 'env'/'printenv' would expose all environment variables including tokens. Use specific variable checks instead."
fi
# Standalone export/set (without variable assignment)
if echo "$COMMAND" | grep -qE '(^|\||;|&&|\|\|)\s*(export|set)\s*($|\|)'; then
    log_debug "BLOCKING: export/set"
    output_block "BLOCKED: 'export'/'set' without arguments exposes all variables. Use specific variable checks instead."
fi
# bash -c with env inside
if echo "$COMMAND" | grep -qE 'bash\s+-c\s+["\x27].*\b(env|printenv)\b'; then
    log_debug "BLOCKING: bash -c env"
    output_block "BLOCKED: Running env/printenv via bash -c would expose all environment variables including tokens."
fi
log_debug "env pattern check done"

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
