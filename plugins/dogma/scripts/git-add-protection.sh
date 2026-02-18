#!/bin/bash
# Dogma: Git Add Protection Hook
# Blocks git add for:
# 1. Files in .git/info/exclude (AI/agent files)
# 2. Secret files (.env, *.pem, *credentials*)
#
# IDEA.md line 164-182 (AI files) and 391-403 (Secret files)
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch for all hooks
# ENV: CLAUDE_MB_DOGMA_GIT_ADD_PROTECTION=true (default) | false

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# === JSON OUTPUT FOR BLOCKING ===
# Claude Code expects JSON with permissionDecision
# Using "deny" - secrets and AI files must NEVER be committed
output_block() {
    local reason="$1"
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"$reason"}}
EOF
    exit 0
}

# === DEBUG MODE ===
DEBUG="${CLAUDE_MB_DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== git-add-protection.sh START $(date) ===" >&2
    echo "PWD: $(pwd)" >&2
fi

# === MASTER SWITCH ===
# CLAUDE_MB_DOGMA_ENABLED=false disables ALL dogma hooks at once
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${CLAUDE_MB_DOGMA_GIT_ADD_PROTECTION:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Read JSON input from stdin
INPUT=$(cat 2>/dev/null || true)

# Extract the command being run
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only process Bash tool calls
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# ============================================
# Part 1: Check for git add commands
# ============================================
if ! echo "$TOOL_INPUT" | grep -qE '(^|\s|;|&&|\||\|\||\$\(|\(|`)git\s+add\s'; then
    # Also check for git commit -a (adds all modified files including secrets)
    if echo "$TOOL_INPUT" | grep -qE '(^|\s|;|&&|\||\|\||\$\(|\(|`)git\s+commit\s.*-a'; then
        # Check if .env exists and is modified
        if [ -f ".env" ]; then
            if git status --porcelain .env 2>/dev/null | grep -q '^.M\|^M'; then
                output_block "BLOCKED by dogma: git commit -a would include .env! .env may contain secrets. Use git add <specific-files> without .env, then git commit."
            fi
        fi
    fi
    exit 0
fi

# Note: -f flag is NOT a bypass for Claude
# Both AI files and secret files can NEVER be added by Claude
# User must always run git add manually for these files

# Check if we're in a git repository
if [ ! -d ".git" ]; then
    exit 0
fi

# Extract file paths from git add command
# Stop at && ; | to handle chained commands like "git add file && git commit"
GIT_ADD_PART=$(echo "$TOOL_INPUT" | sed 's/\s*&&.*//; s/\s*;.*//; s/\s*|.*//')
FILES=$(echo "$GIT_ADD_PART" | sed 's/^git\s\+add\s\+//' | tr ' ' '\n' | grep -v '^-')

# ============================================
# Part 2: Secret File Detection (OPTIMIZED)
# ============================================
# Single regex for all secret patterns - no loops needed
#
# Covered patterns:
# - .env files: .env, .env.local, .env.production, .env.* (except .env.example/sample/template)
# - Crypto keys: *.pem, *.key, *.p12, *.pfx, *.crt, *.keystore, *.jks
# - SSH keys: id_rsa, id_ed25519, id_ecdsa, id_dsa, *.pub (in .ssh context)
# - SSH dir: .ssh/* (entire directory)
# - Cloud creds: .aws/*, .kube/*, .gcloud/*, .azure/*
# - Package tokens: .npmrc, .pypirc, .netrc, .docker/config.json
# - Git creds: .git-credentials, .gitconfig (can contain tokens)
# - Vault/tokens: .vault-token, *token*, *password*
# - Generic: *credentials*, *secret*, *.secrets, .htpasswd
# - GCP: service-account*.json
#
SECRET_REGEX='(^|/)('
SECRET_REGEX+='\.env(\..*)?'                    # .env files
SECRET_REGEX+='|.*\.(pem|key|p12|pfx|crt|keystore|jks)'  # crypto files
SECRET_REGEX+='|id_(rsa|ed25519|ecdsa|dsa)'     # SSH private keys
SECRET_REGEX+='|\.ssh/.*'                       # entire .ssh directory
SECRET_REGEX+='|\.(aws|kube|gcloud|azure)/.*'   # cloud config dirs
SECRET_REGEX+='|\.(npmrc|pypirc|netrc)'         # package manager tokens
SECRET_REGEX+='|\.docker/config\.json'          # docker registry creds
SECRET_REGEX+='|\.git-credentials'              # git credentials
SECRET_REGEX+='|\.vault-token'                  # hashicorp vault
SECRET_REGEX+='|.*credentials.*'                # generic credentials
SECRET_REGEX+='|.*secret.*'                     # generic secrets
SECRET_REGEX+='|.*password.*'                   # password files
SECRET_REGEX+='|.*token.*'                      # token files
SECRET_REGEX+='|.*\.secrets'                    # *.secrets files
SECRET_REGEX+='|\.htpasswd'                     # apache passwords
SECRET_REGEX+='|kubeconfig'                     # kubernetes config
SECRET_REGEX+='|service-account.*\.json'        # GCP service accounts
SECRET_REGEX+=')$'

# File extensions that are CODE, not secrets (even if name matches)
# Note: .txt, .json, .dat are NOT here - they can contain actual secrets
CODE_EXT_REGEX='\.(sh|bash|py|js|ts|tsx|jsx|rb|go|rs|java|php|pl|c|cpp|h|hpp|cs|swift|kt|scala|vue|svelte|md|html|css|scss|less|xml|yaml|yml|toml)$'

# Filter secret files from a list (stdin -> stdout)
# Usage: echo "$FILES" | filter_secrets
filter_secrets() {
    grep -iE "$SECRET_REGEX" | grep -ivE '\.env\.(example|sample|template)$' | grep -ivE "$CODE_EXT_REGEX" || true
}

# ============================================
# Part 3: Excluded File Detection (OPTIMIZED)
# ============================================
# Uses single git check-ignore --stdin call for ALL files at once
# Returns files that are in .git/info/exclude (not .gitignore)

# Get all files excluded by .git/info/exclude in one batch call
# Usage: echo "$FILES" | get_excluded_files
get_excluded_files() {
    # git check-ignore -v --stdin outputs: <source>:<line>:<pattern>\t<file>
    # Filter only lines from .git/info/exclude
    git check-ignore -v --stdin 2>/dev/null | grep "^\.git/info/exclude:" | cut -f2 || true
}

# ============================================
# Part 4: Collect files to check
# ============================================
FILES_TO_CHECK=""

for FILE in $FILES; do
    # Handle git add . or git add -A
    if [ "$FILE" = "." ] || [ "$FILE" = "-A" ] || [ "$FILE" = "--all" ]; then
        # Get all untracked and modified files
        FILES_TO_CHECK=$(git status --porcelain 2>/dev/null | awk '{print $2}')
        break
    fi

    # Skip if file doesn't exist
    if [ -e "$FILE" ]; then
        FILES_TO_CHECK="$FILES_TO_CHECK
$FILE"
    fi
done

# Remove empty lines
FILES_TO_CHECK=$(echo "$FILES_TO_CHECK" | grep -v '^$' || true)

# Exit early if no files to check
if [ -z "$FILES_TO_CHECK" ]; then
    exit 0
fi

# ============================================
# Part 5: Batch check all files at once
# ============================================

# Check for secrets (simple regex, no subprocess per file)
BLOCKED_SECRET_FILES=$(echo "$FILES_TO_CHECK" | filter_secrets | tr '\n' ' ')

# Check for excluded files (single git call for ALL files)
BLOCKED_AI_FILES=$(echo "$FILES_TO_CHECK" | get_excluded_files | tr '\n' ' ')

# ============================================
# Part 6: Output blocking messages
# ============================================

# Block AI files - Claude can NEVER add these
if [ -n "$BLOCKED_AI_FILES" ]; then
    FILES_LIST=$(echo $BLOCKED_AI_FILES | tr ' ' ', ')
    output_block "BLOCKED by dogma: AI files in .git/info/exclude ($FILES_LIST). These files reveal AI usage. Claude cannot add these - user must run git add manually."
fi

# Block secret files - Claude can NEVER add these
if [ -n "$BLOCKED_SECRET_FILES" ]; then
    FILES_LIST=$(echo $BLOCKED_SECRET_FILES | tr ' ' ', ')
    output_block "BLOCKED by dogma: Secret files detected ($FILES_LIST). Claude cannot add secrets - user must run git add manually if really intended."
fi

exit 0
