#!/bin/bash
# credo-worktree-flow - decide how credo creates worktrees for parallel code tracks.
#
# Reads the dogma checkbox "use Hydra for 2+ independent tasks" (stable id §xw1i, ### Hydra subsection of
# DOGMA-PERMISSIONS.md, via credo-dogma-mode.sh - works without dogma) and whether the
# hydra plugin is installed:
#   [x] or missing (no checkbox / no DOGMA-PERMISSIONS.md) + hydra installed
#                           -> flow=hydra   (hydra's create flow, automatically; default on)
#   [?] + hydra installed   -> flow=ask     (ask the user once per batch; in autonomous
#                                            mode never ask - treat as native)
#   [ ] or hydra not installed -> flow=native (git worktree add + setup)
#
# Usage: credo-worktree-flow.sh [--json] [dir]
# Output (kv): flow=hydra|ask|native, reason=<text>, setup=<script to run right after
# `git worktree add`: hydra's worktree-setup.sh when hydra ships it, else
# credo-worktree-setup.sh>, hydra=<hydra plugin dir or empty>.
# Exit codes: 0 always, 1 bad arguments.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="kv"
if [ "${1:-}" = "--json" ]; then
    MODE="json"
    shift
fi
case "${1:-}" in -*) echo "credo-worktree-flow: unknown argument: $1" >&2; exit 1 ;; esac
[ $# -le 1 ] || { echo "credo-worktree-flow: unexpected argument: $2" >&2; exit 1; }
DIR="${1:-$PWD}"
[ -d "$DIR" ] || { echo "credo-worktree-flow: no such dir: $DIR" >&2; exit 1; }

# Newest installed hydra (installed_plugins.json installPath entries plus the cache).
# CREDO_HYDRA_DIR overrides the lookup ("none" = not installed), mainly for tests.
find_hydra_dir() {
    if [ -n "${CREDO_HYDRA_DIR:-}" ]; then
        [ "$CREDO_HYDRA_DIR" = "none" ] || echo "$CREDO_HYDRA_DIR"
        return 0
    fi
    local cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" d
    {
        python3 - "$cfg/plugins/installed_plugins.json" 2>/dev/null <<'PY' || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for key, entries in (data.get("plugins") or {}).items():
    if key.split("@")[0] == "hydra":
        for e in entries if isinstance(entries, list) else []:
            if isinstance(e, dict) and e.get("installPath"):
                print(e["installPath"])
PY
        for d in "$cfg"/plugins/cache/*/hydra/*/; do
            [ -d "$d" ] && echo "${d%/}"
        done
    } | while IFS= read -r d; do
        [ -f "$d/commands/create.md" ] && printf '%s\t%s\n' "$(basename "$d")" "$d"
    done | sort -V -k1,1 | tail -n1 | cut -f2
}

HYDRA="$(find_hydra_dir)"
CHECK="$("$SCRIPT_DIR/credo-dogma-mode.sh" --id xw1i Hydra 'use Hydra for 2\+ independent tasks' "$DIR" 2>/dev/null || echo missing)"

if [ -z "$HYDRA" ]; then
    FLOW="native"; REASON="hydra not installed"
else
    case "$CHECK" in
        auto) FLOW="hydra"; REASON="[x] use Hydra for 2+ independent tasks" ;;
        ask)  FLOW="ask";   REASON="[?] use Hydra for 2+ independent tasks - ask once per batch (autonomous: native)" ;;
        missing) FLOW="hydra"; REASON="no Hydra checkbox in DOGMA-PERMISSIONS.md - default on while hydra is installed" ;;
        *)    FLOW="native"; REASON="Hydra checkbox is off" ;;
    esac
fi

SETUP="$SCRIPT_DIR/credo-worktree-setup.sh"
if [ -n "$HYDRA" ] && [ -f "$HYDRA/scripts/worktree-setup.sh" ]; then
    SETUP="$HYDRA/scripts/worktree-setup.sh"
fi

if [ "$MODE" = "json" ]; then
    FLOW="$FLOW" REASON="$REASON" SETUP="$SETUP" HYDRA="$HYDRA" python3 -c '
import json, os
print(json.dumps({"flow": os.environ["FLOW"], "reason": os.environ["REASON"],
                  "setup": os.environ["SETUP"], "hydra": os.environ["HYDRA"] or None}))'
else
    echo "flow=$FLOW"
    echo "reason=$REASON"
    echo "setup=$SETUP"
    echo "hydra=$HYDRA"
fi
