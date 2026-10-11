#!/usr/bin/env bash
#
# credo-peer-lan-autostart.sh
#
# SessionStart hook: bring up the LAN peer relay daemon automatically, once per
# machine, so cross-machine peer sessions appear in ListAgents without a manual
# /credo:peer-lan start. The daemon is started DETACHED, so this hook returns
# immediately and never blocks session start.
#
# There is ONE relay per machine with ONE machine config (see credo-peer-lan.py
# config_path). The hook starts it only from a profile that this config serves (the
# profile holding it, or a sibling profile the config lists or every sibling when it
# names no list); from any other profile it prints the add-profile note instead and
# never creates a second config. It also prints one onboarding line for the agent (no
# config yet / profile not served / no network bound; see the onboarding block below). This hook
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

script="${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py"
[ -f "$script" ] || exit 0

to5=""
command -v timeout >/dev/null 2>&1 && to5="timeout 5"

# Onboarding context for the AGENT (SessionStart stdout = injected context; this hook
# never prompts). The lines stay English (agent-facing) but tell the agent to talk to
# the user in the user's language, English fallback. Cheap: one config-only daemon call,
# never network detection. The daemon resolves THE machine config (one relay per machine)
# and says whether this profile is served by it; the second field is that config's
# directory, where the relay state (pidfile, log, pairing keys) lives.
#   not-configured  no machine config, not declined -> offer the guided setup once
#   unserved        a machine config exists, this profile is not served -> offer to add
#                   this profile to it (never a second config or relay in this profile)
#   unbound         served, no network bound (legacy / after the 0.72 upgrade) -> DISABLED note
#   bound           served and bound -> say nothing
#   declined        this profile declined the offer -> say nothing
# shellcheck disable=SC2086  # $to5 is an intentional optional command prefix
out="$($to5 "$script" onboarding --state --dir 2>/dev/null | tail -n1)"
state="${out%% *}"
mdir="${out#* }"
[ "$mdir" = "$out" ] && mdir=""
profile="$(basename "$cfgdir")"
if [ "$state" = "not-configured" ]; then
  echo "[credo-peer-lan] credo can now connect Claude Code sessions across your machines on the home LAN (no cloud). One relay serves every Claude Code profile of this machine, so the setup asks which profiles to serve (default: all found). In an interactive session ask the user once (Ask tool) whether to set it up (guided, /credo:peer-lan Setup flow); if they decline, run \`\${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py onboarding --decline\` so this is never offered again. In autonomous mode do not ask. Ask and explain in the user's language (the language of the conversation); fall back to English if unknown or unsure."
fi
if [ "$state" = "unserved" ]; then
  echo "[credo-peer-lan] This Claude Code profile ($profile) is not served by the LAN relay of this machine (one relay per machine; its config lives in $mdir). Do not set up a second config or relay here. In an interactive session ask the user once (Ask tool) whether this profile should be served too; if yes, run \`\${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py profiles add $profile\`; if no, run \`\${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py onboarding --decline\` so this is never offered again. In autonomous mode do not ask. Ask and explain in the user's language (the language of the conversation); fall back to English if unknown or unsure."
fi
if [ "$state" = "unbound" ] && { [ -z "$mdir" ] || [ "$mdir" = "$cfgdir/credo" ]; }; then
  echo "[credo-peer-lan] The LAN relay is DISABLED: no network is bound yet (new allowlist + network binding since credo 0.72). In an interactive session offer the user the guided setup from /credo:peer-lan (Setup flow) via the Ask tool; in autonomous mode do not ask, just mention it in the next report. Ask and explain in the user's language (the language of the conversation); fall back to English if unknown or unsure."
fi

# A served profile that does not hold the machine config is never offered the setup again:
# the holder profile offers it. Only an informational note here.
if [ "$state" = "unbound" ] && [ -n "$mdir" ] && [ "$mdir" != "$cfgdir/credo" ]; then
  echo "[credo-peer-lan] The machine LAN relay is DISABLED: no network is bound yet. Its config lives in another profile ($mdir), where the setup belongs. Do not offer the LAN setup in this profile; mention the state only when the user asks about LAN peers. Explain in the user's language (the language of the conversation); fall back to English if unknown or unsure."
fi

# Only a SERVED profile (unbound or bound) starts the machine relay here; anything else
# (declined, unserved, not configured) ends the hook. The fallback dir only matters when
# the daemon did not answer at all.
case "$state" in
  unbound|bound) ;;
  *) exit 0 ;;
esac
[ -n "$mdir" ] || mdir="$cfgdir/credo"

# Pairing repair pending (the relay refused a new peer id at the address of a paired
# peer, a paired peer at another address, or a relay without pairing support at a
# paired address, and recorded it): tell the agent, never accept it on its own.
# Reads one file.
pending="$mdir/peer-lan-keys/pending-repair.json"
if [ -s "$pending" ] && grep -q '"slot"' "$pending" 2>/dev/null; then
  echo "[credo-peer-lan] A LAN peer pairing repair is pending: the relay saw an unexpected key or address change (a new id at the address of a paired peer, a paired peer at another address, or a relay without pairing support at a paired address) and refused it. Run \`\${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py pairs\` and tell the user; run the pair-reset command it prints only after the user confirmed (Ask tool) that this peer really was reinstalled, reset or moved (or that the older relay really lives at that address). In autonomous mode never run it, just mention it in the next report. Explain in the user's language (the language of the conversation); fall back to English if unknown or unsure."
fi

mkdir -p "$mdir" 2>/dev/null || true

# Start detached via `ensure` so the hook returns at once and never blocks session
# start. ensure itself decides running/replace/start (reading the daemon's pidfile) and
# the daemon's bind-retry guards concurrent starts, so no pgrep pre-check is needed: a
# current/newer daemon is left alone, an older one (after cc-up) is replaced, and a
# losing racer exits 0 without disturbing the incumbent.
nohup "$script" ensure >>"$mdir/peer-lan.log" 2>&1 &
disown 2>/dev/null || true

# WSL only: refresh the Windows portproxy so the just-started daemon is reachable from
# the LAN despite a changed WSL IP. Best-effort, non-blocking, fail-safe - it only
# triggers an already-registered scheduled task; it never changes the firewall or the
# portproxy itself (that is the user's one-time elevated -Install step). On native Linux
# this block is skipped (no NAT -> the daemon already listens on the LAN directly).
# powershell.exe when the WSL session PATH lost the Windows dirs (appendWindowsPath not
# applied, e.g. after a WSL crash). Generic, no fixed path: every drvfs mount (or 9p
# mount naming drvfs) in /proc/mounts plus the single-letter dirs below the
# [automount] root of /etc/wsl.conf are tried as Windows drive roots; the path below a
# root is matched case-insensitively. Both files are overridable for tests
# (CREDO_PEER_LAN_MOUNTS, CREDO_PEER_LAN_WSLCONF). Prints the path, or returns 1.
find_win_powershell() {
  local mounts conf roots root mp fstype opts cur part hit e
  mounts="${CREDO_PEER_LAN_MOUNTS:-/proc/mounts}"
  conf="${CREDO_PEER_LAN_WSLCONF:-/etc/wsl.conf}"
  roots=()
  if [ -r "$mounts" ]; then
    while read -r _ mp fstype opts _; do
      case "$fstype" in
        drvfs) ;;
        9p) case "$opts" in *drvfs*) ;; *) continue ;; esac ;;
        *) continue ;;
      esac
      # /proc/mounts escapes space/tab/backslash as \NNN octal
      roots+=("$(printf '%b' "$(printf '%s' "$mp" | sed 's/\\\([0-7][0-7][0-7]\)/\\0\1/g')")")
    done < "$mounts"
  fi
  if [ -r "$conf" ]; then
    root="$(awk '
      /^[[:space:]]*\[/ { sec = tolower($0); gsub(/[[:space:]\[\]]/, "", sec); next }
      sec == "automount" && tolower($0) ~ /^[[:space:]]*root[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*(#.*)?$/, ""); gsub(/"/, ""); print; exit }
    ' "$conf" 2>/dev/null)"
    if [ -n "$root" ] && [ -d "$root" ]; then
      for e in "$root"/?; do [ -d "$e" ] && roots+=("$e"); done
    fi
  fi
  for root in "${roots[@]}"; do
    if [ -x "$root/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]; then
      printf '%s\n' "$root/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"; return 0
    fi
    cur="$root"
    for part in windows system32 windowspowershell v1.0 powershell.exe; do
      hit=""
      for e in "$cur"/*; do
        [ "$(printf '%s' "${e##*/}" | tr '[:upper:]' '[:lower:]')" = "$part" ] && { hit="$e"; break; }
      done
      [ -n "$hit" ] || { cur=""; break; }
      cur="$hit"
    done
    if [ -n "$cur" ] && [ -f "$cur" ] && [ -x "$cur" ]; then printf '%s\n' "$cur"; return 0; fi
  done
  return 1
}

case "${CREDO_PEER_LAN_WINPROXY:-1}" in
  0|false|no|off) : ;;   # proxy-trigger opt-out: the daemon was still started above
  *)
    # CREDO_PEER_LAN_PROCVERSION overrides the proc-version path (defaults to the real
    # /proc/version); it exists only so the test suite can simulate a non-WSL host on a
    # WSL machine. In production it is unset and the real file is read.
    procver="${CREDO_PEER_LAN_PROCVERSION:-/proc/version}"
    if grep -qi microsoft "$procver" 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
      task="${CREDO_PEER_LAN_WINPROXY_TASK:-credo-peer-lan-proxy}"
      # Cap the call with timeout when available so a slow/hung powershell cannot
      # linger. Resolution and call run backgrounded and disowned, so the hook never
      # blocks; a missing powershell.exe simply means no trigger.
      to=""
      command -v timeout >/dev/null 2>&1 && to="timeout 15"
      (
        ps_exe="$(command -v powershell.exe 2>/dev/null || find_win_powershell || true)"
        # shellcheck disable=SC2086  # $to is an intentional optional command prefix
        [ -n "$ps_exe" ] && $to "$ps_exe" -NoProfile -Command "schtasks /Run /TN $task" >/dev/null 2>&1
        true
      ) &
      disown 2>/dev/null || true
    fi
    ;;
esac

exit 0
