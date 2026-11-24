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
# switch is off. ensure itself only launches: the daemon gets its own transient systemd
# user service (else a double fork + setsid, scripts/credo_detach.py), so it never lives
# in this session's process group or systemd scope and survives the session's end.
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
# shellcheck source-path=SCRIPTDIR source=credo-python-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/credo-python-lib.sh" 2>/dev/null || exit 0
credo_find_python || exit 0

# Fast path (this hook also runs on every UserPromptSubmit, because /reload-plugins after a
# plugin update fires no SessionStart): a live daemon of this plugin version needs nothing.
# A config switch-off is still applied by the next SessionStart or a version change.
if [ "${CREDO_WIN_BRIDGE_EVENT:-}" = "prompt" ]; then
  state="${XDG_STATE_HOME:-$HOME/.local/state}/credo/win-bridge/bridge.pid"
  ver=$(sed -n 's/^version: *//p' "${CLAUDE_PLUGIN_ROOT}/plugin.yaml" 2>/dev/null | head -1)
  rec=$(cat "$state" 2>/dev/null)
  pid=$(printf '%s' "$rec" | sed -n 's/.*"pid": *\([0-9][0-9]*\).*/\1/p')
  if [ -n "$pid" ] && [ -n "$ver" ] && [ -d "/proc/$pid" ] && printf '%s' "$rec" | grep -q "\"version\": *\"$ver\""; then
    exit 0
  fi
fi

# detached: own session, no inherited stdio, so the hook never waits for it
if command -v setsid >/dev/null 2>&1; then
  setsid "$CREDO_PYTHON" "$script" ensure </dev/null >/dev/null 2>&1 &
else
  nohup "$CREDO_PYTHON" "$script" ensure </dev/null >/dev/null 2>&1 &
fi
exit 0
