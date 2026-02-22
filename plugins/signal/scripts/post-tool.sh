#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/kitty-tab.sh"
PROJECT=$(basename "$PWD" 2>/dev/null || echo "claude")
kitty_tab_set_working "$PROJECT"
exit 0
