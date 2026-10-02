#!/bin/bash
# notice-applies-test-commands - "applies" check of the dogma-test-commands notice
# (see notices.json and notices-pending.sh). Read-only.
#
# Applies (exit 0) when a DOGMA-PERMISSIONS.md is found upward from the current
# directory and it has no Test Commands heading yet (stable id (§ly5v) first, else the
# text "### Test Commands"). Exit 1 otherwise.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-permissions.sh
source "$SCRIPT_DIR/lib-permissions.sh"

FILE="$(find_permissions_file)" || exit 1
if perm_has_heading "$(cat "$FILE" 2>/dev/null)" ly5v 'Test Commands'; then
    exit 1
fi
exit 0
