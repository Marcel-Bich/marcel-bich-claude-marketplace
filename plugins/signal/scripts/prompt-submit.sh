#!/bin/bash
# prompt-submit.sh: Mark kitty tab as working when user sends a prompt

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/kitty-tab.sh"

PROJECT=$(basename "$PWD" 2>/dev/null || echo "claude")
kitty_tab_save_and_mark "$PROJECT"

exit 0
