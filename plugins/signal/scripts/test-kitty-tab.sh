#!/bin/bash
# test-kitty-tab.sh: Manual test for kitty tab indicator
# Usage: CLAUDE_MB_SIGNAL_DEBUG=true bash plugins/signal/scripts/test-kitty-tab.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Enable debug output for testing
export CLAUDE_MB_SIGNAL_DEBUG="true"

echo "=== Kitty Tab Indicator Test ==="
echo ""

source "$SCRIPT_DIR/kitty-tab.sh"

# Check availability
echo "Checking kitty tab availability..."
if ! kitty_tab_available; then
    echo "FAIL: kitty tab not available (see debug output above)"
    echo ""
    echo "Make sure kitty.conf has:"
    echo "  allow_remote_control yes"
    echo "  listen_on unix:/tmp/mykitty"
    echo ""
    echo "Then restart kitty."
    exit 1
fi
echo "OK: kitty tab available"
echo ""

# Test with a project name
PROJECT="test-project"

echo "Saving current title and setting indicator..."
kitty_tab_save_and_mark "$PROJECT"
echo ""

echo "Tab should now show '[cc...]' suffix."
echo "Waiting 3 seconds before restoring..."
sleep 3

echo ""
echo "Restoring original title..."
kitty_tab_restore "$PROJECT"
echo ""

echo "=== Test complete ==="
