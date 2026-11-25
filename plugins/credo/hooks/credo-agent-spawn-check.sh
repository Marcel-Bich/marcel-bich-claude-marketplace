#!/usr/bin/env bash
# credo-agent-spawn-check.sh - credo plugin (PreToolUse hook on Agent and Task).
#
# Purpose: enforce the active model preset as a minimum on every spawn. A spawn whose
# model/effort is below every rung of the ladders that fit its kind (Explore/Plan ->
# explore role; any other type -> build, review and hard roles) is DENIED with the minimum
# pairs and the lookup command credo-preset.sh stage <role> <attempt>. Missing model or
# effort is a mismatch. An equal pair passes; a stronger pair passes with a visible
# "stronger than preset" line. A fork passes only when the parent's model is >= a fitting
# rung model. A weaker pair only via a "preset exception:" line in .credo/RULES.md or a
# valid owner rule with an until date in the handoff "## Rules (temporary)". No preset
# configured -> no check.
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
