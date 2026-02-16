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

# Strict mode: block all .env* files (true) or only exact .env (false)
STRICT="${CLAUDE_MB_DOGMA_TOKEN_STRICT:-true}"
log_debug "Strict mode: $STRICT"

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
    # Pattern matches:
    # - .env files (strict: all .env*, relaxed: only exact .env)
    # - Files ending with: .netrc, .git-credentials, .npmrc, .pypirc, .pem, .key
    # - Files containing: credential, secret, id_rsa, id_ed25519, id_ecdsa
    # - Hidden files like .credentials.json, .secrets.yaml
    BASENAME=$(basename "$FILE_PATH")

    # .env file check (mode-dependent)
    # Always allow safe variants
    if echo "$BASENAME" | grep -qiE '^\.env\.(example|sample|template)$'; then
        log_debug "Safe .env variant: $BASENAME"
    elif [ "$STRICT" = "true" ]; then
        # Strict: block any file whose basename starts with .env followed by end or non-alnum
        if echo "$BASENAME" | grep -qiE '^\.env($|[^a-zA-Z0-9])'; then
            output_block "BLOCKED: Reading .env file '$FILE_PATH'. These files typically contain sensitive tokens. Use .env.example instead."
        fi
    else
        # Relaxed: block exact .env and .env.local
        if [ "$BASENAME" = ".env" ] || [ "$BASENAME" = ".env.local" ]; then
            output_block "BLOCKED: Reading .env file '$FILE_PATH'. These files typically contain sensitive tokens. Use .env.example instead."
        fi
    fi

    # Other credential files (not .env - those are handled above)
    if echo "$FILE_PATH" | grep -qiE '(\.netrc|\.git-credentials|\.npmrc|\.pypirc|\.pem|\.key)$'; then
        output_block "BLOCKED: Reading credential/secrets file '$FILE_PATH'. These files typically contain sensitive tokens."
    fi
    # Match credential/secret anywhere in filename (handles .credentials.json, secrets.yaml, etc.)
    if echo "$FILE_PATH" | grep -qiE '(credential|secret|id_rsa|id_ed25519|id_ecdsa)'; then
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
        if grep -E 'sk-[a-zA-Z0-9]{20,}' "$FILE_PATH" 2>/dev/null | grep -qvE 'sk-your|sk-xxx|sk-\.\.\.'; then
            output_block "BLOCKED: File '$FILE_PATH' contains an OpenAI API key (sk-...). Reading would expose credentials."
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
# GREP TOOL - Block searching in sensitive files
# =============================================================================
if [ "$TOOL_NAME" = "Grep" ]; then
    log_debug "Processing Grep tool"
    PATH_ARG=$(echo "$INPUT" | jq -r '.tool_input.path // empty' 2>/dev/null)
    GLOB_ARG=$(echo "$INPUT" | jq -r '.tool_input.glob // empty' 2>/dev/null)

    # Check if path points to a sensitive file
    if [ -n "$PATH_ARG" ]; then
        BASENAME=$(basename "$PATH_ARG")

        # .env file check (mode-dependent)
        # Allow safe variants
        if echo "$BASENAME" | grep -qiE '^\.env\.(example|sample|template)$'; then
            log_debug "Safe .env variant: $BASENAME"
        elif [ "$STRICT" = "true" ]; then
            # Strict: block any .env* file
            if echo "$BASENAME" | grep -qiE '^\.env($|[^a-zA-Z0-9])'; then
                output_block "BLOCKED: Grep in .env file '$PATH_ARG'. Use .env.example instead."
            fi
        else
            # Relaxed: block exact .env and .env.local
            if [ "$BASENAME" = ".env" ] || [ "$BASENAME" = ".env.local" ]; then
                output_block "BLOCKED: Grep in .env file '$PATH_ARG'. Use .env.example instead."
            fi
        fi

        # Credential files (always blocked regardless of STRICT)
        if echo "$BASENAME" | grep -qiE '^(\.netrc|\.git-credentials|\.npmrc|\.pypirc)$'; then
            output_block "BLOCKED: Grep in credential file '$PATH_ARG'. This file may contain tokens."
        fi

        # Key/certificate files
        if echo "$BASENAME" | grep -qiE '\.(pem|key)$'; then
            output_block "BLOCKED: Grep in key/certificate file '$PATH_ARG'. This file may contain secrets."
        fi

        # Files with credential/secret in the path
        if echo "$PATH_ARG" | grep -qiE '(credential|secret)'; then
            output_block "BLOCKED: Grep in credential/secrets file '$PATH_ARG'. This file may contain tokens."
        fi

        # SSH key files
        if echo "$BASENAME" | grep -qE 'id_(rsa|ed25519|ecdsa|dsa)'; then
            output_block "BLOCKED: Grep in SSH key file '$PATH_ARG'. This file contains private key material."
        fi
    fi

    # Check if glob pattern targets .env files
    if [ -n "$GLOB_ARG" ]; then
        SAFE_GLOB=$(echo "$GLOB_ARG" | sed -E 's/\.env\.(example|sample|template)//g')
        if echo "$SAFE_GLOB" | grep -qE '\.env'; then
            if [ "$STRICT" = "true" ]; then
                output_block "BLOCKED: Grep with .env glob pattern '$GLOB_ARG'. Use .env.example instead."
            else
                # Relaxed: only block if the glob targets exact .env or .env.local
                if echo "$GLOB_ARG" | grep -qE '(^|\*)\.env($|\*)|\.env\.local'; then
                    output_block "BLOCKED: Grep with .env glob pattern '$GLOB_ARG'. Use .env.example instead."
                fi
            fi
        fi
        # Credential file glob patterns (always blocked)
        if echo "$GLOB_ARG" | grep -qiE '\.(netrc|git-credentials|npmrc|pypirc|pem|key)'; then
            output_block "BLOCKED: Grep with credential file glob pattern '$GLOB_ARG'."
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
# Also: /usr/bin/git, command git, sudo git, git -C /path remote -v, git --no-pager remote -v
# Uses broad match: git followed by anything, then remote with dangerous flags
if echo "$COMMAND" | grep -qE '(^|\||;|&&|\|\||\s|\$\(|\(|`)(sudo\s+)?(command\s+)?([/a-z]*\/)?git\b.*\bremote\s+(-v|--verbose|show|get-url)'; then
    log_debug "BLOCKING: git remote"
    output_block "BLOCKED: 'git remote -v/--verbose/show/get-url' can expose tokens embedded in remote URLs. Use 'git remote' (without -v) to list remote names only."
fi

# Git config remote URL (also handles git -C /path config, git --no-pager config, etc.)
if echo "$COMMAND" | grep -qE 'git\b.*\bconfig.*(remote\.|url\.)'; then
    output_block "BLOCKED: 'git config' with remote/url can expose tokens embedded in remote URLs."
fi

# Environment variable dumps (expose all tokens)
# Catches: env, printenv, export, set (alone or piped)
# Also: /usr/bin/env, command env, sudo env, bash -c "env"
log_debug "Checking env pattern against: $COMMAND"
if echo "$COMMAND" | grep -qE '(^|\||;|&&|\|\||\s|\$\(|\(|`)(sudo\s+)?(command\s+)?([/a-z]*\/)?(env|printenv)(\s*$|\s*\||\s+[^=])'; then
    log_debug "BLOCKING: env/printenv"
    output_block "BLOCKED: 'env'/'printenv' would expose all environment variables including tokens. Use specific variable checks instead."
fi
# Standalone export/set (without variable assignment)
if echo "$COMMAND" | grep -qE '(^|\||;|&&|\|\||\$\(|\(|`)\s*(export|set)\s*($|\|)'; then
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

# Credential files (non-.env) - catch ANY reference, not just cat/head
# Matches: .netrc, .git-credentials, .npmrc, .pypirc, .pem, .key files
# Also matches paths containing: credentials, secrets
if echo "$COMMAND" | grep -qE '(\.netrc|\.git-credentials|\.npmrc|\.pypirc)(\s|$|;|"|'"'"'|\|)'; then
    output_block "BLOCKED: Command references a credential file that may contain tokens."
fi
# Key/certificate files - require path-like context to reduce false positives
if echo "$COMMAND" | grep -qE '(cat|less|head|tail|cp|mv|scp|rsync|source|base64|xxd|strings)\s.*\.(pem|key)(\s|$|;|"|'"'"'|\|)' || \
   echo "$COMMAND" | grep -qE '(/[a-zA-Z0-9_./-]+)\.(pem|key)(\s|$|;|"|'"'"'|\|)'; then
    output_block "BLOCKED: Command references a key/certificate file that may contain secrets."
fi
if echo "$COMMAND" | grep -qiE '(^|\s|/)credentials(\s|$|/|;|"|'"'"'|\|)'; then
    output_block "BLOCKED: Command references a credentials file that may contain tokens."
fi
if echo "$COMMAND" | grep -qiE '(^|\s|/)secrets(\s|$|/|;|"|'"'"'|\|)'; then
    output_block "BLOCKED: Command references a secrets file that may contain tokens."
fi

# .env file references in commands
ENV_REFS=$(echo "$COMMAND" | grep -oE '\.env[a-zA-Z0-9._-]*' | sort -u)
if [ -n "$ENV_REFS" ]; then
    # Filter out safe variants (.env.example, .env.sample, .env.template)
    UNSAFE=$(echo "$ENV_REFS" | grep -vE '\.env\.(example|sample|template)$')
    if [ -n "$UNSAFE" ]; then
        if [ "$STRICT" = "true" ]; then
            # Strict: block all unsafe .env refs
            output_block "BLOCKED: Command references .env file(s). Use .env.example instead."
        else
            # Relaxed: block .env (exact) and .env.local
            if echo "$UNSAFE" | grep -qxE '\.env(\.local)?'; then
                output_block "BLOCKED: Command references .env file directly. Use .env.example instead."
            fi
        fi
    fi
fi

# Git credential helpers (also handles git -C /path credential, etc.)
if echo "$COMMAND" | grep -qE 'git\b.*\bcredential'; then
    output_block "BLOCKED: 'git credential' commands can expose stored tokens."
fi

# Curl/wget with auth headers visible
if echo "$COMMAND" | grep -qiE '(curl|wget).*(-H|--header).*([Aa]uthorization|[Bb]earer|[Tt]oken)'; then
    output_block "BLOCKED: Command includes authorization headers that could expose tokens in output/logs."
fi

# SSH key files - catch ANY reference, not just cat/head
if echo "$COMMAND" | grep -qE '[/~.]id_(rsa|ed25519|ecdsa|dsa)\b' || \
   echo "$COMMAND" | grep -qE '(cat|less|head|tail|cp|mv|scp|rsync|chmod|source)\s.*id_(rsa|ed25519|ecdsa|dsa)'; then
    output_block "BLOCKED: Command references an SSH private key file."
fi

# All checks passed
exit 0
