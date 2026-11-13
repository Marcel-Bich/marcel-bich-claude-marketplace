#!/usr/bin/env bash
#
# credo-win-bridge-autostart.sh
#
# SessionStart hook: bring up the WSL <-> Windows peer bridge (scripts/credo-win-bridge.py)
# so native Windows Claude Code sessions of this machine appear in ListAgents of WSL
# sessions and the other way round. Only under WSL; the bridge itself checks that Windows
# interop (powershell.exe) works and that it is switched on. It is started DETACHED via the
# `ensure` subcommand, so this hook returns at once: ensure leaves a current/newer daemon
# alone, replaces an older one after a plugin update and stops a running one when the
# switch is off.
#
# Off switch: credo config `peer.win_bridge.enabled: false` or CREDO_WIN_BRIDGE=0.
#
# Always exits 0: a missing python3, no WSL, no interop or any other error must never
# surface as a hook failure.

case "${CREDO_WIN_BRIDGE:-}" in
  0|false|no|off) exit 0 ;;
esac

if ! grep -qi microsoft "${CREDO_WIN_BRIDGE_PROCVERSION:-/proc/version}" 2>/dev/null && [ -z "${WSL_DISTRO_NAME:-}" ]; then
  exit 0
fi

script="${CLAUDE_PLUGIN_ROOT}/scripts/credo-win-bridge.py"
[ -f "$script" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# detached: own session, no inherited stdio, so the hook never waits for it
if command -v setsid >/dev/null 2>&1; then
  setsid python3 "$script" ensure </dev/null >/dev/null 2>&1 &
else
  nohup python3 "$script" ensure </dev/null >/dev/null 2>&1 &
fi
exit 0
