#!/bin/bash
# notice-applies-discard - "applies" check of the dogma-discard-uncommitted notice
# (see notices.json and notices-pending.sh). Read-only.
#
# Applies (exit 0) when an effective DOGMA-PERMISSIONS.md resolves for the current
# directory (lib-permissions.sh: own file upward or in the main worktree, else the
# inherited session-folder file, DOGMA_SESSION_DIR) and neither it nor the file it
# inherits from defines the discard setting (stable id (§b4dk) first, else the text
# "discard uncommitted changes"). Exit 1 otherwise.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-permissions.sh
source "$SCRIPT_DIR/lib-permissions.sh"

SPEC="§b4dk|discard uncommitted changes"
# the current directory is the target: no credo pin lookup here (notices-pending.sh
# already ran its context resolution and starts this script there)
load_permissions "$(pwd)" || exit 1
if perm_lookup "${PERMS_SECTION:-}" "$SPEC" "${PERMS_SECTION:-}" >/dev/null 2>&1; then
    exit 1
fi
if [ -n "${DOGMA_INHERIT_FILE:-}" ] && perm_lookup_inherited "$SPEC" >/dev/null 2>&1; then
    exit 1
fi
exit 0
