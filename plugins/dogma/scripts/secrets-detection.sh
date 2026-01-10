#!/bin/bash
# Dogma: Secrets Detection Hook
# Blocks Write/Edit operations that would write secrets to files
#
# Detects: API keys, JWT tokens, private keys, passwords
#
# ENV: DOGMA_SECRETS_DETECTION=true (default) | false

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# === DEBUG MODE ===
DEBUG="${DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== secrets-detection.sh START $(date) ===" >&2
    echo "PWD: $(pwd)" >&2
fi

# === CONFIGURATION ===
ENABLED="${DOGMA_SECRETS_DETECTION:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Read JSON input from stdin
INPUT=$(cat 2>/dev/null || true)

# Extract the tool info
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only process Write and Edit tools
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
    exit 0
fi

# Extract content being written
CONTENT=""
if [ "$TOOL_NAME" = "Write" ]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
elif [ "$TOOL_NAME" = "Edit" ]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
fi

if [ -z "$CONTENT" ]; then
    exit 0
fi

# Check for secrets patterns
FOUND_SECRETS=""

# OpenAI API Key
if echo "$CONTENT" | grep -qE 'sk-[a-zA-Z0-9]{20,}'; then
    # Check it's not a placeholder
    if ! echo "$CONTENT" | grep -qE 'sk-your-key|sk-xxx|sk-\.\.\.'; then
        FOUND_SECRETS="$FOUND_SECRETS\n- OpenAI API key (sk-...)"
    fi
fi

# Anthropic API Key
if echo "$CONTENT" | grep -qE 'sk-ant-[a-zA-Z0-9]{20,}'; then
    if ! echo "$CONTENT" | grep -qE 'sk-ant-your|sk-ant-xxx'; then
        FOUND_SECRETS="$FOUND_SECRETS\n- Anthropic API key (sk-ant-...)"
    fi
fi

# AWS Access Key
if echo "$CONTENT" | grep -qE 'AKIA[0-9A-Z]{16}'; then
    FOUND_SECRETS="$FOUND_SECRETS\n- AWS Access Key ID"
fi

# AWS Secret Key (often follows access key)
if echo "$CONTENT" | grep -qE 'aws_secret_access_key\s*=\s*[^"\s]{20,}'; then
    FOUND_SECRETS="$FOUND_SECRETS\n- AWS Secret Access Key"
fi

# JWT Token
if echo "$CONTENT" | grep -qE 'eyJ[a-zA-Z0-9_-]{10,}\.eyJ[a-zA-Z0-9_-]{10,}'; then
    # Check it's not in documentation/example context
    if ! echo "$CONTENT" | grep -qiE 'example|sample|test|mock|fake'; then
        FOUND_SECRETS="$FOUND_SECRETS\n- JWT Token"
    fi
fi

# RSA Private Key
if echo "$CONTENT" | grep -qE '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'; then
    FOUND_SECRETS="$FOUND_SECRETS\n- Private Key"
fi

# Generic password assignment (not empty or placeholder)
if echo "$CONTENT" | grep -qE '(password|passwd|pwd)\s*[=:]\s*["\047][^"\047]{8,}["\047]'; then
    # Check it's not a placeholder
    if ! echo "$CONTENT" | grep -qiE '(password|passwd|pwd)\s*[=:]\s*["\047](xxx|your|changeme|placeholder|example)'; then
        FOUND_SECRETS="$FOUND_SECRETS\n- Password"
    fi
fi

# GitHub Personal Access Token
if echo "$CONTENT" | grep -qE 'ghp_[a-zA-Z0-9]{36}'; then
    FOUND_SECRETS="$FOUND_SECRETS\n- GitHub Personal Access Token"
fi

# Slack Token
if echo "$CONTENT" | grep -qE 'xox[baprs]-[a-zA-Z0-9-]{10,}'; then
    FOUND_SECRETS="$FOUND_SECRETS\n- Slack Token"
fi

# Stripe API Key
if echo "$CONTENT" | grep -qE 'sk_live_[a-zA-Z0-9]{20,}'; then
    FOUND_SECRETS="$FOUND_SECRETS\n- Stripe Live API Key"
fi

# Database connection string with password
if echo "$CONTENT" | grep -qE '(mysql|postgres|mongodb)://[^:]+:[^@]+@'; then
    FOUND_SECRETS="$FOUND_SECRETS\n- Database connection string with credentials"
fi

# If secrets found, block the operation
if [ -n "$FOUND_SECRETS" ]; then
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // "unknown"')

    echo ""
    echo "BLOCKED by dogma: secrets detection"
    echo ""
    echo "Potential secrets detected in content for: $FILE_PATH"
    echo ""
    echo "Found:"
    echo -e "$FOUND_SECRETS"
    echo ""
    echo "NEVER write real secrets to files in the repository."
    echo ""
    echo "Instead:"
    echo "- Use environment variables: process.env.API_KEY"
    echo "- Use .env files (which are gitignored)"
    echo "- Use placeholder values: 'your-api-key-here'"
    echo "- Ask the user to add secrets manually"
    echo ""
    exit 1
fi

exit 0
