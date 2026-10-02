#!/bin/bash
# Tests for credo-peer-lan-autostart.sh - the SessionStart auto-start hook.
#
# The gate + delegation tests run against throwaway config dirs with a FAKE daemon
# script (so no real daemon is started, no LAN port is opened, nothing lingers). The
# fake "daemon" records the subcommand it was invoked with into a sentinel and exits,
# so a successful start - and that it was the `ensure` subcommand - is observable
# without a real process.
#
# A final ensure-decision section DOES drive the REAL daemon, but only on 127.0.0.1 with
# an ephemeral port (same loopback-only model as test-credo-peer-lan.sh), to prove the
# hook -> ensure chain replaces an OLDER running daemon after a plugin update yet leaves a
# current/newer one untouched. Those daemons are tracked and killed on exit.
#
# It checks:
#   - CREDO_PEER_LAN=0 / false -> no-op (exit 0, starts nothing),
#   - no config file           -> no-op (exit 0, starts nothing),
#   - config present + nothing running -> the hook starts the daemon detached via `ensure`,
#   - WSL portproxy trigger is still gated by WSL detection (and opt-out / missing-ps),
#   - ensure via the hook: an OLDER running daemon is replaced; a same/newer one is left.
#
# Usage: bash test-credo-peer-lan-autostart.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/credo-peer-lan-autostart.sh"
if [ ! -f "$HOOK" ]; then echo "FAIL: $HOOK missing"; exit 1; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cla.XXXXXX")"

# Real daemons are only started (on loopback) by the ensure-decision section at the end;
# track their pids plus whatever the RD pidfile records so nothing lingers after the run.
PIDS=""
RD_PIDFILE=""
cleanup() {
    [ -n "$RD_PIDFILE" ] && [ -f "$RD_PIDFILE" ] && {
        rp="$(command -v python3 >/dev/null 2>&1 && python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("pid",""))' "$RD_PIDFILE" 2>/dev/null)"
        [ -n "$rp" ] && kill -KILL "$rp" 2>/dev/null || true
    }
    for p in $PIDS; do kill -KILL "$p" 2>/dev/null || true; done
    rm -rf -- "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() { # name cond(0=pass)
    if [ "$2" = "0" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; fi
}
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}

# fake plugin root with a fake daemon script that records it was started, then exits.
FAKE_ROOT="$TMP/plugin"
mkdir -p "$FAKE_ROOT/scripts"
SENTINEL="$TMP/started"
cat > "$FAKE_ROOT/scripts/credo-peer-lan.py" <<EOF
#!/usr/bin/env bash
# fake daemon: record the subcommand it was invoked with and exit at once (never
# lingers, never binds a port). The hook must invoke it as "ensure". The cheap
# "onboarding --state" query answers with FAKE_ONB_STATE (default bound) and is not
# recorded as a start.
if [ "\$1" = onboarding ]; then echo "\${FAKE_ONB_STATE:-bound}"; exit 0; fi
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
ok "hook invokes the daemon via the ensure subcommand" "$(grep -q 'started ensure' "$SENTINEL" && echo 0 || echo 1)"

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

# --- onboarding context (SessionStart stdout = injected agent context) -----------
# no config, not declined -> one-time setup offer; declined -> silent; config with no
# bound network -> DISABLED note; bound (matching or not) -> silent. CREDO_PEER_LAN=0
# -> nothing at all.
rm -f "$CFG" "$CFGDIR/credo/peer-lan-onboarding-declined"
OUT="$(run_hook)"
case "$OUT" in *"[credo-peer-lan] credo can now connect"*"onboarding --decline"*"in the user's language (the language of the conversation); fall back to English if unknown or unsure.") PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL onboarding offer missing: %s\n' "$OUT" ;; esac
: > "$CFGDIR/credo/peer-lan-onboarding-declined"
OUT="$(run_hook)"
check "onboarding: declined -> no injection" "" "$OUT"
rm -f "$CFGDIR/credo/peer-lan-onboarding-declined"
OUT="$(run_hook CREDO_PEER_LAN=0)"
check "onboarding: CREDO_PEER_LAN=0 -> no injection" "" "$OUT"
printf '{"this_machine":"X","peers":[]}\n' > "$CFG"
OUT="$(run_hook FAKE_ONB_STATE=unbound)"
case "$OUT" in *"LAN relay is DISABLED: no network is bound yet"*"in the user's language (the language of the conversation); fall back to English if unknown or unsure.") PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL onboarding unbound note missing: %s\n' "$OUT" ;; esac
OUT="$(run_hook FAKE_ONB_STATE=bound)"
check "onboarding: bound -> no injection" "" "$OUT"
OUT="$(run_hook FAKE_ONB_STATE=unbound CREDO_PEER_LAN=off)"
check "onboarding: off toggle silences the unbound note" "" "$OUT"

# --- ensure via the hook: older running daemon replaced, same/newer left untouched ---
# Drives the REAL daemon through the hook, loopback only, ephemeral port. ensure reads the
# running daemon's pidfile (pid + version) and either replaces an older one or no-ops.
REAL_ROOT="$SCRIPT_DIR/.."
REAL_DAEMON="$SCRIPT_DIR/credo-peer-lan.py"
PY="$(command -v python3 || true)"
if [ -z "$PY" ] || [ ! -f "$REAL_DAEMON" ]; then
    echo "SKIP ensure-decision section: python3 or the real daemon not available"
else
    RD_CFGDIR="$TMP/rd"
    mkdir -p "$RD_CFGDIR/credo" "$RD_CFGDIR/sessions" "$TMP/rdsock" "$TMP/home"
    RD_CFG="$RD_CFGDIR/credo/peer-lan.json"
    RD_PIDFILE="$RD_CFGDIR/credo/peer-lan.pid"   # picked up by the cleanup trap
    RDPORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
    cat > "$RD_CFG" <<EOF
{"this_machine":"RD","listen_host":"127.0.0.1","listen_port":$RDPORT,
 "roster_interval":60,"machine_timeout":600,"bind_retry_total":3,"bind_retry_interval":0.2,"peers":[]}
EOF
    rd_pid() { "$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("pid",""))' "$1" 2>/dev/null; }
    rd_ver() { "$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("version",""))' "$1" 2>/dev/null; }

    # start a real incumbent daemon directly (not via hook) with a chosen version
    start_incumbent() { # version
        rm -f "$RD_PIDFILE"
        env -i PATH="/usr/bin:/bin" HOME="$TMP/home" \
            CLAUDE_CONFIG_DIR="$RD_CFGDIR" CREDO_PEER_LAN_CONFIG="$RD_CFG" \
            CREDO_PEER_LAN_SOCKDIR="$TMP/rdsock" CREDO_PEER_LAN_VERSION="$1" \
            "$PY" "$REAL_DAEMON" daemon >>"$RD_CFGDIR/incumbent.log" 2>&1 &
        PIDS="$PIDS $!"
        for _ in $(seq 1 40); do [ -f "$RD_PIDFILE" ] && return 0; sleep 0.1; done
        return 1
    }
    # run the hook against the real daemon with a chosen current plugin version
    run_hook_real() { # version
        env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP/home" \
            CLAUDE_PLUGIN_ROOT="$REAL_ROOT" CLAUDE_CONFIG_DIR="$RD_CFGDIR" \
            CREDO_PEER_LAN_CONFIG="$RD_CFG" CREDO_PEER_LAN_SOCKDIR="$TMP/rdsock" \
            CREDO_PEER_LAN_PROCVERSION="$PROCVER_LINUX" CREDO_PEER_LAN_VERSION="$1" \
            bash "$HOOK" </dev/null
    }

    # same/newer running -> the hook's ensure leaves it untouched (incumbent v9.9.9, cur v1.0.0)
    if start_incumbent 9.9.9; then
        P0="$(rd_pid "$RD_PIDFILE")"
        run_hook_real 1.0.0; rc=$?
        ok "hook ensure (newer running) exits 0" "$rc"
        sleep 1.0
        check "hook ensure leaves a newer running daemon untouched (pid unchanged)" "$P0" "$(rd_pid "$RD_PIDFILE")"
        ok "hook ensure (newer running): incumbent still alive" "$([ -n "$P0" ] && kill -0 "$P0" 2>/dev/null && echo 0 || echo 1)"
        kill -KILL "$P0" 2>/dev/null || true
        for _ in $(seq 1 20); do kill -0 "$P0" 2>/dev/null || break; sleep 0.1; done
    else
        FAIL=$((FAIL + 1)); printf 'FAIL hook ensure no-op: incumbent did not come up\n'
    fi

    # older running -> the hook's ensure replaces it (incumbent v1.0.0, cur v9.9.9)
    if start_incumbent 1.0.0; then
        P0="$(rd_pid "$RD_PIDFILE")"
        run_hook_real 9.9.9; rc=$?
        ok "hook ensure (older running) exits 0" "$rc"
        replaced=""
        for _ in $(seq 1 60); do
            np="$(rd_pid "$RD_PIDFILE")"
            if [ -n "$np" ] && [ "$np" != "$P0" ] && kill -0 "$np" 2>/dev/null \
               && ! kill -0 "$P0" 2>/dev/null; then replaced=1; break; fi
            sleep 0.2
        done
        ok "hook ensure replaces an OLDER running daemon (cc-up self-heal)" "$([ -n "$replaced" ] && echo 0 || echo 1)"
        check "hook ensure (replaced): pidfile now records the new version" "9.9.9" "$(rd_ver "$RD_PIDFILE")"
        np="$(rd_pid "$RD_PIDFILE")"; kill -KILL "$np" 2>/dev/null || true
    else
        FAIL=$((FAIL + 1)); printf 'FAIL hook ensure replace: incumbent did not come up\n'
    fi
fi

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
