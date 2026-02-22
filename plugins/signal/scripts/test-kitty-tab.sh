#!/bin/bash
# test-kitty-tab.sh: Manual test for kitty tab indicator
# Usage: CLAUDE_MB_SIGNAL_DEBUG=true bash plugins/signal/scripts/test-kitty-tab.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export CLAUDE_MB_SIGNAL_DEBUG="true"

echo "=== Kitty Tab Indicator Test ==="
echo ""

source "$SCRIPT_DIR/kitty-tab.sh"

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

PROJECT="test-project"

echo "Setting [ai...] indicator..."
kitty_tab_save_and_mark "$PROJECT" "$$"
echo "Tab should now show '[ai...] <original-title>' prefix."
echo "Waiting 3 seconds..."
sleep 3

echo ""
echo "Setting [fin] indicator..."
kitty_tab_restore "$PROJECT" "$$"
echo "Tab should now show '[fin] <original-title>' prefix."
echo ""
echo "Switch to another tab, then switch back to this tab."
echo "The [fin] prefix should disappear when you focus this tab."
echo ""
echo "Waiting 30 seconds for you to test focus-based reset..."
sleep 30

echo "=== Test complete ==="
