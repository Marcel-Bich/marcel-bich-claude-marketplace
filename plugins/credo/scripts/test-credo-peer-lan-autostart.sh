#!/bin/bash
# Tests for credo-peer-lan-autostart.sh - the SessionStart auto-start hook.
#
# Everything runs against throwaway config dirs in a temp tree with a FAKE daemon
# script (so no real daemon is ever started, no LAN port is opened, nothing lingers).
# The fake "daemon" just touches a sentinel file and exits, so a successful start is
# observable without a real process. A fake pgrep on PATH makes the "already running"
# check deterministic regardless of what runs on the host.
#
# It checks the gates:
#   - CREDO_PEER_LAN=0 / false -> no-op (exit 0, starts nothing),
#   - no config file           -> no-op (exit 0, starts nothing),
#   - config present + nothing running -> the hook starts the (fake) daemon detached.
#
# Usage: bash test-credo-peer-lan-autostart.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/credo-peer-lan-autostart.sh"
if [ ! -f "$HOOK" ]; then echo "FAIL: $HOOK missing"; exit 1; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cla.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
ok() { # name cond(0=pass)
    if [ "$2" = "0" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; fi
}

# fake plugin root with a fake daemon script that records it was started, then exits.
FAKE_ROOT="$TMP/plugin"
mkdir -p "$FAKE_ROOT/scripts"
SENTINEL="$TMP/started"
cat > "$FAKE_ROOT/scripts/credo-peer-lan.py" <<EOF
#!/usr/bin/env bash
# fake daemon: record the start and exit at once (never lingers, never binds a port)
echo "started \$*" >> "$SENTINEL"
exit 0
EOF
chmod +x "$FAKE_ROOT/scripts/credo-peer-lan.py"

# fake pgrep that never matches, so the hook's "already running?" check is
# deterministic (a real daemon on the host must not influence these tests).
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/pgrep" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$BIN/pgrep"

# fake powershell.exe in its OWN dir, added to PATH only in the WSL-trigger tests. It
# records that it was called and exits non-zero, simulating a trigger error (e.g. the
# scheduled task not registered yet) so the tests prove the hook stays fail-safe. The
# real Windows powershell.exe is NEVER reachable: run_hook uses an isolated PATH that
# excludes /mnt/c, so no state-changing Windows call can ever happen from these tests.
PSBIN="$TMP/psbin"
mkdir -p "$PSBIN"
PSLOG="$TMP/ps-called"
cat > "$PSBIN/powershell.exe" <<EOF
#!/bin/bash
echo "called \$*" >> "$PSLOG"
exit 1
EOF
chmod +x "$PSBIN/powershell.exe"

# fake /proc/version files so WSL detection is deterministic regardless of whether the
# test host itself is WSL (on a real WSL host the true /proc/version contains microsoft).
PROCVER_LINUX="$TMP/procversion-linux"
printf 'Linux version 6.1.0-generic (gcc) #1 SMP\n' > "$PROCVER_LINUX"
PROCVER_WSL="$TMP/procversion-wsl"
printf 'Linux version 6.6.0-microsoft-standard-WSL2 (oe-user) #1 SMP\n' > "$PROCVER_WSL"

# isolated config dir; the config file path is pinned via CREDO_PEER_LAN_CONFIG
CFGDIR="$TMP/cfg"
mkdir -p "$CFGDIR/credo"
CFG="$CFGDIR/credo/peer-lan.json"

# Isolated PATH: the fake bin plus coreutils only (no /mnt/c), so the real Windows
# powershell.exe is unreachable. Default proc-version simulates a NON-WSL host, so the
# existing tests never reach the WSL proxy-trigger block; the proxy tests override these
# via trailing KEY=VAL (env keeps the LAST assignment, so a later PATH/PROCVERSION wins).
run_hook() { # extra env assignments passed as KEY=VAL ...
    env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP/home" \
        CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" CLAUDE_CONFIG_DIR="$CFGDIR" \
        CREDO_PEER_LAN_CONFIG="$CFG" \
        CREDO_PEER_LAN_PROCVERSION="$PROCVER_LINUX" \
        "$@" bash "$HOOK" </dev/null
}

wait_sentinel() { # returns 0 if the sentinel appears within ~3s
    for _ in $(seq 1 30); do
        [ -f "$SENTINEL" ] && return 0
        sleep 0.1
    done
    return 1
}

wait_file() { # path -> 0 if it appears within ~3s
    for _ in $(seq 1 30); do
        [ -f "$1" ] && return 0
        sleep 0.1
    done
    return 1
}

# --- gate 1: CREDO_PEER_LAN=0 -> no-op even though a config exists -------------
printf '{"this_machine":"X","token":"t","peers":[]}\n' > "$CFG"
rm -f "$SENTINEL"
run_hook CREDO_PEER_LAN=0; rc=$?
ok "CREDO_PEER_LAN=0 exits 0" "$rc"
sleep 0.3
ok "CREDO_PEER_LAN=0 starts nothing" "$([ ! -f "$SENTINEL" ] && echo 0 || echo 1)"

# --- gate 1b: CREDO_PEER_LAN=false -> same no-op (false must work like 0) ------
rm -f "$SENTINEL"
run_hook CREDO_PEER_LAN=false; rc=$?
ok "CREDO_PEER_LAN=false exits 0" "$rc"
sleep 0.3
ok "CREDO_PEER_LAN=false starts nothing" "$([ ! -f "$SENTINEL" ] && echo 0 || echo 1)"

# --- gate 2: no config file -> no-op -------------------------------------------
rm -f "$CFG" "$SENTINEL"
run_hook; rc=$?
ok "no config exits 0" "$rc"
sleep 0.3
ok "no config starts nothing" "$([ ! -f "$SENTINEL" ] && echo 0 || echo 1)"

# --- start path: config present, nothing running -> the hook starts the daemon -
printf '{"this_machine":"X","token":"t","peers":[]}\n' > "$CFG"
rm -f "$SENTINEL"
run_hook; rc=$?
ok "config present exits 0" "$rc"
ok "config present starts the (fake) daemon detached" "$(wait_sentinel && echo 0 || echo 1)"

# --- proxy trigger, NON-WSL host: no portproxy needed -> no powershell attempt --------
# Even with a fake powershell.exe ON the PATH, a non-WSL host must never trigger it.
printf '{"this_machine":"X","token":"t","peers":[]}\n' > "$CFG"
rm -f "$SENTINEL" "$PSLOG"
run_hook PATH="$PSBIN:$BIN:/usr/bin:/bin" CREDO_PEER_LAN_PROCVERSION="$PROCVER_LINUX"; rc=$?
ok "non-WSL exits 0" "$rc"
ok "non-WSL still starts the daemon" "$(wait_sentinel && echo 0 || echo 1)"
sleep 0.4
ok "non-WSL does NOT trigger the Windows portproxy" "$([ ! -f "$PSLOG" ] && echo 0 || echo 1)"

# --- proxy trigger, WSL host (via fake /proc/version), powershell present but errors ---
# The trigger is attempted; a failing/stubbed powershell.exe must not fail or block.
printf '{"this_machine":"X","token":"t","peers":[]}\n' > "$CFG"
rm -f "$SENTINEL" "$PSLOG"
run_hook PATH="$PSBIN:$BIN:/usr/bin:/bin" CREDO_PEER_LAN_PROCVERSION="$PROCVER_WSL"; rc=$?
ok "WSL exits 0 despite failing proxy trigger" "$rc"
ok "WSL still starts the daemon" "$(wait_sentinel && echo 0 || echo 1)"
ok "WSL attempts the Windows portproxy trigger" "$(wait_file "$PSLOG" && echo 0 || echo 1)"

# --- proxy trigger, WSL host (via WSL_DISTRO_NAME), powershell present ------------------
# Prove the env-var detection path also triggers (not only the /proc/version path).
printf '{"this_machine":"X","token":"t","peers":[]}\n' > "$CFG"
rm -f "$SENTINEL" "$PSLOG"
run_hook PATH="$PSBIN:$BIN:/usr/bin:/bin" CREDO_PEER_LAN_PROCVERSION="$PROCVER_LINUX" WSL_DISTRO_NAME=Ubuntu; rc=$?
ok "WSL_DISTRO_NAME exits 0" "$rc"
ok "WSL_DISTRO_NAME attempts the trigger" "$(wait_file "$PSLOG" && echo 0 || echo 1)"

# --- proxy trigger opt-out under WSL: CREDO_PEER_LAN_WINPROXY=0 skips the trigger -------
# The daemon must still start; only the portproxy trigger is suppressed.
printf '{"this_machine":"X","token":"t","peers":[]}\n' > "$CFG"
rm -f "$SENTINEL" "$PSLOG"
run_hook PATH="$PSBIN:$BIN:/usr/bin:/bin" CREDO_PEER_LAN_PROCVERSION="$PROCVER_WSL" CREDO_PEER_LAN_WINPROXY=0; rc=$?
ok "WINPROXY=0 exits 0" "$rc"
ok "WINPROXY=0 still starts the daemon" "$(wait_sentinel && echo 0 || echo 1)"
sleep 0.4
ok "WINPROXY=0 does NOT trigger the portproxy" "$([ ! -f "$PSLOG" ] && echo 0 || echo 1)"

# --- proxy trigger, WSL host but powershell.exe MISSING: must not fail or block ---------
# PATH excludes the fake powershell dir, so command -v powershell.exe fails; the hook
# must swallow this and still exit 0 with the daemon started.
printf '{"this_machine":"X","token":"t","peers":[]}\n' > "$CFG"
rm -f "$SENTINEL" "$PSLOG"
run_hook PATH="$BIN:/usr/bin:/bin" CREDO_PEER_LAN_PROCVERSION="$PROCVER_WSL"; rc=$?
ok "WSL without powershell.exe exits 0" "$rc"
ok "WSL without powershell.exe still starts the daemon" "$(wait_sentinel && echo 0 || echo 1)"
sleep 0.4
ok "WSL without powershell.exe makes no trigger" "$([ ! -f "$PSLOG" ] && echo 0 || echo 1)"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
