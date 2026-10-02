#!/bin/bash
# notice-applies-test-commands - "applies" check of the dogma-test-commands notice
# (see notices.json and notices-pending.sh). Read-only.
#
# Applies (exit 0) when an effective DOGMA-PERMISSIONS.md resolves for the current
# directory (lib-permissions.sh: own file upward or in the main worktree, else the
# inherited session-folder file, DOGMA_SESSION_DIR) and neither it nor the file it
# inherits from has a Test Commands heading yet (stable id (§ly5v) first, else the
# text "### Test Commands"). Exit 1 otherwise.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-permissions.sh
source "$SCRIPT_DIR/lib-permissions.sh"

# the current directory is the target: no credo pin lookup here (notices-pending.sh
# already ran its context resolution and starts this script there)
load_permissions "$(pwd)" || exit 1
if perm_has_heading "$(cat "${PERMS_FILE:-}" 2>/dev/null)" ly5v 'Test Commands'; then
    exit 1
fi
exit 0
