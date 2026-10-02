#!/usr/bin/env bash
#
# credo-peer-lan-autostart.sh
#
# SessionStart hook: bring up the LAN peer relay daemon automatically, once per
# machine, so cross-machine peer sessions appear in ListAgents without a manual
# /credo:peer-lan start. The daemon is started DETACHED, so this hook returns
# immediately and never blocks session start.
#
# It also prints one onboarding line for the agent (no config yet / no network bound;
# see the onboarding block below). No-op unless a config file exists (the relay itself is a no-op without one). This hook
# delegates all run/replace/start decisions to the daemon's `ensure` subcommand: ensure
# leaves a current/newer running daemon untouched, self-heals an OLDER one after a plugin
# update (cc-up), and otherwise starts fresh. The daemon's bind-retry makes a concurrent
# start race-safe, so this hook no longer needs its own pgrep pre-check.
#
# Under WSL (NAT mode) it ALSO best-effort triggers the Windows scheduled task that
# refreshes the portproxy (Windows-LAN-IP:PORT -> current WSL-IP:PORT), so a LAN peer
# can reach the daemon even though the WSL IP changed since last boot. See
# scripts/credo-peer-lan-winproxy.ps1 (the user registers that task once per machine).
# On native Linux there is no NAT and no portproxy is needed, so that trigger is skipped.
#
# SAFETY / fail-safe:
#   - Always exits 0. A missing python3, a missing config, a missing powershell.exe, an
#     unregistered task, or any other error must never surface as a hook failure or
#     abort the session.
#   - Disable the whole relay (daemon + proxy trigger) with CREDO_PEER_LAN set to
#     0/false/no/off (the same toggle the daemon honors).
#   - Disable ONLY the Windows portproxy trigger (still start the daemon) with
#     CREDO_PEER_LAN_WINPROXY set to 0/false/no/off.

# Intentionally NO `set -e`: a SessionStart hook must never abort the session.

case "${CREDO_PEER_LAN:-1}" in
  0|false|no|off) exit 0 ;;
esac

cfgdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
cfgdir="${cfgdir%/}"

# config path: CREDO_PEER_LAN_CONFIG wins, else <configdir>/credo/peer-lan.json
cfg="${CREDO_PEER_LAN_CONFIG:-$cfgdir/credo/peer-lan.json}"

# Onboarding context for the AGENT (SessionStart stdout = injected context; this hook
# never prompts). The lines stay English (agent-facing) but tell the agent to talk to
# the user in the user's language, English fallback. Cheap: reads only files, never runs network detection.
#   no config, not declined -> offer the guided setup once (decline writes a marker)
#   config but no network bound (legacy / after the 0.72 upgrade) -> relay DISABLED note
#   bound (matching or not) / declined -> say nothing
if [ ! -f "$cfg" ]; then
  if [ ! -f "$(dirname "$cfg")/peer-lan-onboarding-declined" ]; then
    echo "[credo-peer-lan] credo can now connect Claude Code sessions across your machines on the home LAN (no cloud). In an interactive session ask the user once (Ask tool) whether to set it up (guided, /credo:peer-lan Setup flow); if they decline, run \`\${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py onboarding --decline\` so this is never offered again. In autonomous mode do not ask. Ask and explain in the user's language (the language of the conversation); fall back to English if unknown or unsure."
  fi
  exit 0                         # no config -> the relay is a no-op, start nothing
fi

script="${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py"
[ -f "$script" ] || exit 0

to5=""
command -v timeout >/dev/null 2>&1 && to5="timeout 5"
# shellcheck disable=SC2086  # $to5 is an intentional optional command prefix
state="$($to5 "$script" onboarding --state 2>/dev/null | tail -n1)"
if [ "$state" = "unbound" ]; then
  echo "[credo-peer-lan] The LAN relay is DISABLED: no network is bound yet (new allowlist + network binding since credo 0.72). In an interactive session offer the user the guided setup from /credo:peer-lan (Setup flow) via the Ask tool; in autonomous mode do not ask, just mention it in the next report. Ask and explain in the user's language (the language of the conversation); fall back to English if unknown or unsure."
fi

mkdir -p "$cfgdir/credo" 2>/dev/null || true

# Start detached via `ensure` so the hook returns at once and never blocks session
# start. ensure itself decides running/replace/start (reading the daemon's pidfile) and
# the daemon's bind-retry guards concurrent starts, so no pgrep pre-check is needed: a
# current/newer daemon is left alone, an older one (after cc-up) is replaced, and a
# losing racer exits 0 without disturbing the incumbent.
nohup "$script" ensure >>"$cfgdir/credo/peer-lan.log" 2>&1 &
disown 2>/dev/null || true

# WSL only: refresh the Windows portproxy so the just-started daemon is reachable from
# the LAN despite a changed WSL IP. Best-effort, non-blocking, fail-safe - it only
# triggers an already-registered scheduled task; it never changes the firewall or the
# portproxy itself (that is the user's one-time elevated -Install step). On native Linux
# this block is skipped (no NAT -> the daemon already listens on the LAN directly).
case "${CREDO_PEER_LAN_WINPROXY:-1}" in
  0|false|no|off) : ;;   # proxy-trigger opt-out: the daemon was still started above
  *)
    # CREDO_PEER_LAN_PROCVERSION overrides the proc-version path (defaults to the real
    # /proc/version); it exists only so the test suite can simulate a non-WSL host on a
    # WSL machine. In production it is unset and the real file is read.
    procver="${CREDO_PEER_LAN_PROCVERSION:-/proc/version}"
    if grep -qi microsoft "$procver" 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
      if command -v powershell.exe >/dev/null 2>&1; then
        task="${CREDO_PEER_LAN_WINPROXY_TASK:-credo-peer-lan-proxy}"
        # Cap the call with timeout when available so a slow/hung powershell cannot
        # linger; it is backgrounded and disowned either way, so the hook never blocks.
        to=""
        command -v timeout >/dev/null 2>&1 && to="timeout 15"
        # shellcheck disable=SC2086  # $to is an intentional optional command prefix
        ( $to powershell.exe -NoProfile -Command "schtasks /Run /TN $task" >/dev/null 2>&1 || true ) &
        disown 2>/dev/null || true
      fi
    fi
    ;;
esac

exit 0
