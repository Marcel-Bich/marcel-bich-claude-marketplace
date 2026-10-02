#!/bin/bash
# Tests for credo-peer-bridge.sh - the cross-profile peer discovery bridge.
#
# Everything runs against throwaway HOME/profile dirs in a temp tree. No real
# session is ever touched, nothing is installed, no daemon is started.
#
# It checks the N3 guard: the bridge mirrors a plain sibling-profile descriptor
# into the current profile, but must NOT mirror a sibling descriptor that carries
# the credo-peer-lan marker ("credoPeerLan") - those proxy descriptors belong to
# the LAN relay and bridging them would create a confusing double mirror.
#
# Usage: bash test-credo-peer-bridge.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$SCRIPT_DIR/../hooks/credo-peer-bridge.sh"
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "SKIP: python3 not found"; exit 0; fi
if [ ! -f "$BRIDGE" ]; then echo "FAIL: $BRIDGE missing"; exit 1; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/clb.XXXXXX")"

PIDS=""
cleanup() {
    for p in $PIDS; do kill -KILL "$p" 2>/dev/null || true; done
    rm -rf -- "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() { # name cond(0=pass)
    if [ "$2" = "0" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; fi
}

# current profile and a sibling profile (both match the bridge's "$HOME"/.claude* glob)
HOME_DIR="$TMP/home"
CUR_CFG="$HOME_DIR/.claude"
SIB_CFG="$HOME_DIR/.claude-sibling"
mkdir -p "$CUR_CFG/sessions" "$SIB_CFG/sessions"

# two live processes so the sibling descriptors have alive pids (the bridge skips
# descriptors whose pid is not alive)
sleep 600 & PLAIN_PID=$!; PIDS="$PIDS $PLAIN_PID"
sleep 600 & LAN_PID=$!;   PIDS="$PIDS $LAN_PID"

# plain real-local descriptor (no marker) - the bridge SHOULD mirror this one
"$PY" - "$SIB_CFG/sessions/$PLAIN_PID.json" "$PLAIN_PID" <<'PYEOF'
import json, sys
path, pid = sys.argv[1], int(sys.argv[2])
json.dump({"pid": pid, "sessionId": "sid-plain",
           "messagingSocketPath": "/tmp/plain.sock", "name": "plain-session"},
          open(path, "w"))
PYEOF

# credo-peer-lan descriptor (marker is a real top-level key) - MUST NOT be mirrored
"$PY" - "$SIB_CFG/sessions/$LAN_PID.json" "$LAN_PID" <<'PYEOF'
import json, sys
path, pid = sys.argv[1], int(sys.argv[2])
json.dump({"pid": pid, "sessionId": "sid-lan",
           "messagingSocketPath": "/tmp/lan.sock", "name": "lan-session@remote",
           "credoPeerLan": True, "credoPeerLanFrom": "remote"},
          open(path, "w"))
PYEOF

# run the bridge against the current profile
HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$CUR_CFG" bash "$BRIDGE"

# the plain descriptor must be mirrored (present and carrying the bridge marker)
mirrored_plain=1
if [ -f "$CUR_CFG/sessions/$PLAIN_PID.json" ]; then
    grep -q '"credoPeerBridge"' "$CUR_CFG/sessions/$PLAIN_PID.json" 2>/dev/null && mirrored_plain=0
fi
ok "plain sibling descriptor is mirrored into the current profile" "$mirrored_plain"

# the credoPeerLan descriptor must NOT be mirrored
mirrored_lan=1
[ -e "$CUR_CFG/sessions/$LAN_PID.json" ] || mirrored_lan=0
ok "credoPeerLan sibling descriptor is NOT mirrored (bridge skips it)" "$mirrored_lan"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
