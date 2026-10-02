#!/usr/bin/env bash
#
# credo-peer-lan-autostart.sh
#
# SessionStart hook: bring up the LAN peer relay daemon automatically, once per
# machine, so cross-machine peer sessions appear in ListAgents without a manual
# /credo:peer-lan start. The daemon is started DETACHED, so this hook returns
# immediately and never blocks session start.
#
# No-op unless a config file exists (the relay itself is a no-op without one). The
# daemon binds a fixed TCP listen port, which is the single-instance lock: a second
# daemon exits cleanly on EADDRINUSE. This hook additionally checks for an already
# running daemon up front, so it does not even spawn a doomed second process.
#
# SAFETY / fail-safe:
#   - Always exits 0. A missing python3, a missing config, or any other error must
#     never surface as a hook failure or abort the session.
#   - Disable with CREDO_PEER_LAN set to 0/false/no/off (the same toggle the daemon
#     honors).

# Intentionally NO `set -e`: a SessionStart hook must never abort the session.

case "${CREDO_PEER_LAN:-1}" in
  0|false|no|off) exit 0 ;;
esac

cfgdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
cfgdir="${cfgdir%/}"

# config path: CREDO_PEER_LAN_CONFIG wins, else <configdir>/credo/peer-lan.json
cfg="${CREDO_PEER_LAN_CONFIG:-$cfgdir/credo/peer-lan.json}"
[ -f "$cfg" ] || exit 0          # no config -> the relay is a no-op, start nothing

# Already running? Do not start a second daemon. The daemon's command line contains
# "credo-peer-lan.py daemon"; this hook's own command line is the hook script path,
# which does NOT contain that pattern, so this pgrep never self-matches.
if command -v pgrep >/dev/null 2>&1; then
  if pgrep -f "credo-peer-lan.py daemon" >/dev/null 2>&1; then
    exit 0
  fi
fi

script="${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py"
[ -f "$script" ] || exit 0

mkdir -p "$cfgdir/credo" 2>/dev/null || true

# Start detached so the hook returns at once and never blocks session start. The
# daemon self-guards against a second instance via the listen port, so even if the
# pgrep check above missed a racing start, the loser exits 0 without disturbing it.
nohup "$script" daemon >>"$cfgdir/credo/peer-lan.log" 2>&1 &
disown 2>/dev/null || true

exit 0
