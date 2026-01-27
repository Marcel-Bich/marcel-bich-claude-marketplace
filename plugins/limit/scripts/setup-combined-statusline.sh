#!/bin/bash
# setup-combined-statusline.sh - Setup script for combining ccstatusline with limit plugin
#
# Online:  curl -sL https://raw.githubusercontent.com/Marcel-Bich/marcel-bich-claude-marketplace/main/plugins/limit/scripts/setup-combined-statusline.sh | bash
# Local:   ~/.claude/plugins/marketplaces/marcel-bich-claude-marketplace/plugins/limit/scripts/setup-combined-statusline.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Multi-Account Support: CLAUDE_CONFIG_DIR determines the profile
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
WRAPPER_SCRIPT="${CLAUDE_DIR}/statusline-mb-combined.sh"
LIMIT_SCRIPT="${CLAUDE_DIR}/plugins/marketplaces/marcel-bich-claude-marketplace/plugins/limit/scripts/usage-statusline.sh"

echo "====================================="
echo "  Combined Statusline Setup Script"
echo "====================================="
echo ""

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed.${NC}"
    echo "Install with: sudo apt install jq (Debian/Ubuntu)"
    echo "           or: brew install jq (macOS)"
    exit 1
fi

# Check if npx is available (for ccstatusline)
if ! command -v npx &> /dev/null; then
    echo -e "${YELLOW}Warning: npx not found. ccstatusline may not work.${NC}"
    echo "Install Node.js to use ccstatusline."
fi

# Check if limit plugin is installed
if [[ ! -f "$LIMIT_SCRIPT" ]]; then
    echo -e "${RED}Error: limit plugin not found at:${NC}"
    echo "$LIMIT_SCRIPT"
    echo ""
    echo "Please install the limit plugin first:"
    echo "  claude plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace"
    echo "  claude plugin install limit@marcel-bich-claude-marketplace"
    exit 1
fi

# Create wrapper script
echo -e "${GREEN}Creating wrapper script...${NC}"
cat > "$WRAPPER_SCRIPT" << 'EOF'
#!/bin/bash
# Combined statusline: ccstatusline + limit plugin

# Get ccstatusline output (all lines)
CCSTATUS=$(npx -y ccstatusline@latest 2>/dev/null)

# Get limit plugin output
LIMIT=$(~/.claude/plugins/marketplaces/marcel-bich-claude-marketplace/plugins/limit/scripts/usage-statusline.sh 2>/dev/null)

# Combine with newline
if [[ -n "$CCSTATUS" ]] && [[ -n "$LIMIT" ]]; then
    echo -e "$CCSTATUS"
    echo -e "$LIMIT"
elif [[ -n "$LIMIT" ]]; then
    echo -e "$LIMIT"
elif [[ -n "$CCSTATUS" ]]; then
    echo -e "$CCSTATUS"
fi
EOF

chmod +x "$WRAPPER_SCRIPT"
echo -e "  Created: ${WRAPPER_SCRIPT}"

# Update settings.json
echo -e "${GREEN}Updating settings.json...${NC}"

if [[ ! -f "$SETTINGS_FILE" ]]; then
    # Create new settings file
    cat > "$SETTINGS_FILE" << EOF
{
  "statusLine": {
    "type": "command",
    "command": "${WRAPPER_SCRIPT}"
  }
}
EOF
    echo -e "  Created new settings.json"
else
    # Backup existing settings
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.mb-backup"
    echo -e "  Backup: ${SETTINGS_FILE}.mb-backup"

    # Update statusLine in existing settings
    tmp_file=$(mktemp)
    jq --arg cmd "$WRAPPER_SCRIPT" '.statusLine = {"type": "command", "command": $cmd}' "$SETTINGS_FILE" > "$tmp_file"
    mv "$tmp_file" "$SETTINGS_FILE"
    echo -e "  Updated statusLine configuration"
fi

echo ""
echo -e "${GREEN}Setup complete!${NC}"
echo ""
echo "What was configured:"
echo "  1. Wrapper script: ${WRAPPER_SCRIPT}"
echo "  2. settings.json statusLine now points to wrapper"
echo ""
echo -e "${YELLOW}IMPORTANT: Restart Claude Code for changes to take effect.${NC}"
echo ""
echo "To test the wrapper script manually:"
echo "  ${WRAPPER_SCRIPT}"
echo ""
echo "To revert to limit plugin only:"
echo "  Edit ~/.claude/settings.json and change statusLine.command to:"
echo "  ~/.claude/plugins/marketplaces/marcel-bich-claude-marketplace/plugins/limit/scripts/usage-statusline.sh"
