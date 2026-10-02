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

# isolated config dir; the config file path is pinned via CREDO_PEER_LAN_CONFIG
CFGDIR="$TMP/cfg"
mkdir -p "$CFGDIR/credo"
CFG="$CFGDIR/credo/peer-lan.json"

run_hook() { # extra env assignments passed as KEY=VAL ...
    env -i PATH="$BIN:$PATH" HOME="$TMP/home" \
        CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" CLAUDE_CONFIG_DIR="$CFGDIR" \
        CREDO_PEER_LAN_CONFIG="$CFG" \
        "$@" bash "$HOOK" </dev/null
}

wait_sentinel() { # returns 0 if the sentinel appears within ~3s
    for _ in $(seq 1 30); do
        [ -f "$SENTINEL" ] && return 0
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

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
