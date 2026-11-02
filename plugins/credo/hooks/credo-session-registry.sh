#!/usr/bin/env bash
# credo-session-registry.sh - credo plugin (SessionStart + UserPromptSubmit hook)
#
# Writes or refreshes this session's entry in the session registry: session id, name, host,
# pid and start time, the tmux socket and pane when the process tree confirms them, the credo
# mode and the updated time. Logic and entry format: scripts/credo_session_registry.py.
# The file is rewritten only when its content changed. SessionStart also drops entries of
# gone processes that are older than a day.
#
# Prints nothing and always exits 0. Disable with CREDO_SESSION_REGISTRY=0.

case "${CREDO_SESSION_REGISTRY:-1}" in
    0|false|no|off) exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 || exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
python3 "$HOOK_DIR/../scripts/credo-session-registry.py" record >/dev/null 2>&1
exit 0
