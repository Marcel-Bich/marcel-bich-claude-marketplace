#!/usr/bin/env bash
# credo-agent-spawn-check.sh - credo plugin (PreToolUse hook on Agent and Task).
#
# Purpose: enforce the active model preset on every spawn. A tag
# [credo-role: <role>#<attempt>] selects exactly the rung of that attempt; a multi-rung
# role without attempt and a back-to-human attempt without an owner rule (preset continue
# or preset exception) are denied. Untagged: Explore/Plan -> explore attempt 1; any other
# type -> any rung of build, review and hard. A pair the rung allows passes; a pair above
# every pair of the rung passes with a visible "stronger than preset" line; a pair below
# or between the allowed pairs is DENIED with role, attempt, expected rung, chosen pair
# and the exact fix. The spawn limits are hard: above max-allowed, below min-allowed or a
# blocked forbidden model is denied (a forbidden model with action warn passes with a
# visible line). Missing model or effort is a mismatch. A fork is denied above the
# max-allowed model; the same model passes with "fork effort not checkable". A cheaper
# pair only via a "preset exception:" line in .credo/RULES.md or a valid owner rule with
# an until date in the handoff "## Rules (temporary)". No preset configured -> no check.
#
# The decision lives in scripts/credo-preset-guard.py (see its docstring for the format).
# Internal errors fail open with a logged warning. Owner kill switch:
# CREDO_AGENT_SPAWN_CHECK=0.

case "${CREDO_AGENT_SPAWN_CHECK:-1}" in
    0|false|no|off) exit 0 ;;
esac

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
GUARD="$HOOK_DIR/../scripts/credo-preset-guard.py"
[[ -f "$GUARD" ]] || exit 0

# shellcheck source=credo-python-lib.sh
. "$HOOK_DIR/credo-python-lib.sh" 2>/dev/null || exit 0
if ! credo_python_ready; then
    echo "credo-agent-spawn-check: warning: no Python 3 - spawn allowed unchecked" >&2
    exit 0
fi

"$CREDO_PYTHON" -I "$GUARD"
exit 0
