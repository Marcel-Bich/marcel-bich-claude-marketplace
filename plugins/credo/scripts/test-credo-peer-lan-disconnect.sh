#!/bin/bash
# Tests for credo-peer-lan.py disconnect-all (the reset that removes every LAN pairing,
# trust grant, stored peer address and LAN mirror of this machine).
#
# Same sandbox as test-credo-peer-lan.sh: a throwaway HOME with fake Claude Code profile
# dirs in a temp root, loopback only, no real network detection, no real scheduled task.
# The Windows tools are never run for real: a fake powershell.exe and wslpath first on
# PATH only record their arguments. The WSL check is steered with CREDO_PEER_LAN_PROCVERSION.
# The restart check runs a real daemon on loopback with an ephemeral port.
#
# It checks:
#   - --dry-run prints the plan (per profile counts, stored peers) and changes nothing,
#   - without a terminal and without --yes it refuses and changes nothing,
#   - --yes removes the pairings, pending repairs, trust grants and LAN mirrors of every
#     SERVED profile, keeps this machine's identity, the bound networks, the profiles
#     list and non-LAN descriptors, and never touches an unserved profile,
#   - a running relay is restarted with a new pid; a stopped one is not started,
#   - --full runs the elevated Windows removal (stubbed) only under WSL, never elsewhere,
#     and a failing Windows step is reported while the local part is still done,
#   - an unreadable trust list refuses before anything is changed.
#
# Usage: bash test-credo-peer-lan-disconnect.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="$SCRIPT_DIR/credo-peer-lan.py"
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "SKIP: python3 not found"; exit 0; fi
if [ ! -f "$DAEMON" ]; then echo "FAIL: $DAEMON missing"; exit 1; fi

# SAFETY: never real network detection, never the real Windows allowlist, scheduled task
# or firewall, never the real ufw/firewalld. Same stubs as test-credo-peer-lan.sh.
export CREDO_PEER_LAN_NETINFO='{"ip":"127.0.0.1"}'
export CREDO_PEER_LAN_WINALLOW_FILE=/nonexistent-credo-test/peer-lan-allow.json
export CREDO_PEER_LAN_WINPROGRAMDATA=/nonexistent-credo-test/programdata
export CREDO_PEER_LAN_WINPROXY=0
export CREDO_PEER_LAN_MOUNTS=/nonexistent-credo-test/mounts
export CREDO_PEER_LAN_WSLCONF=/nonexistent-credo-test/wsl.conf
export CREDO_PEER_LAN_WSLINTEROP=/nonexistent-credo-test/WSLInterop
export CREDO_PEER_LAN_UFW_STATUS=''
export CREDO_PEER_LAN_FIREWALLD_STATE=none
unset WSL_INTEROP WSL_DISTRO_NAME

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cdc.XXXXXX")"
mkdir -p "$TMP/home"
export HOME="$TMP/home"
export CLAUDE_CONFIG_DIR="$TMP/home/.claude"
M="$TMP/home/.claude"            # machine profile (holds the machine config)
S="$TMP/home/.claude-work"       # served sibling profile
O="$TMP/home/.claude-other"      # sibling profile NOT served by the config
BIN="$TMP/bin"                   # fake Windows tools, first on PATH
export PSLOG="$TMP/ps.log"
PV_LINUX="$TMP/procver-linux"
PV_WSL="$TMP/procver-wsl"
printf 'Linux version 6.8.0-generic (builder)\n' > "$PV_LINUX"
printf 'Linux version 6.18.40.1-microsoft-standard-WSL2\n' > "$PV_WSL"
mkdir -p "$BIN"
cat > "$BIN/powershell.exe" <<'SHEOF'
#!/bin/sh
printf '%s\n' "$@" >> "$PSLOG"
exit "${FAKE_PS_RC:-0}"
SHEOF
cat > "$BIN/wslpath" <<'SHEOF'
#!/bin/sh
printf '%s\n' 'C:\credo-stub\credo-peer-lan-winproxy.ps1'
SHEOF
chmod +x "$BIN/powershell.exe" "$BIN/wslpath"

PORT="$("$PY" -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
ID_A="0123456789abcdef0123456789abcdef"
ID_B="fedcba9876543210fedcba9876543210"
ID_C="11112222333344445555666677778888"
KEY="$(printf 'ab%.0s' $(seq 1 32))"

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
ok() { # name cond(0=pass)
    if [ "$2" = "0" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; fi
}

cleanup() {
    CLAUDE_CONFIG_DIR="$M" "$PY" "$DAEMON" stop >/dev/null 2>&1 || true
    case "$TMP" in
        "${TMPDIR:-/tmp}"/cdc.??????) rm -rf -- "$TMP" ;;
        *) echo "refusing to remove unexpected temp root: '$TMP'" >&2 ;;
    esac
}
trap cleanup EXIT

dc() { "$PY" "$DAEMON" disconnect-all "$@"; }

snap() { # every file under HOME with its checksum (a change of anything shows)
    (cd "$TMP/home" && find . -type f -print0 | sort -z | xargs -0 cksum 2>/dev/null)
}
snap_dir() { # the same for one profile dir
    (cd "$1" && find . -type f -print0 | sort -z | xargs -0 cksum 2>/dev/null)
}

count_peer_files() { # peer-<id>.json pairing records in a keystore dir
    find "$1" -maxdepth 1 -name 'peer-*.json' 2>/dev/null | wc -l | tr -d ' '
}

count_trust() { # trusted entries in a trust file (0 when absent)
    "$PY" -c 'import json, os, sys
p = sys.argv[1]
print(len(json.load(open(p)).get("trusted", [])) if os.path.exists(p) else 0)' "$1"
}

count_marked() { # session descriptors carrying the credoPeerLan marker in a sessions dir
    "$PY" -c 'import json, os, sys
d = sys.argv[1]
n = 0
for f in (os.listdir(d) if os.path.isdir(d) else []):
    if f.endswith(".json") and f[:-5].isdigit():
        try:
            if json.load(open(os.path.join(d, f))).get("credoPeerLan"):
                n += 1
        except Exception:
            pass
print(n)' "$1"
}

cfg_key() { # cfg_key <key> : canonical JSON of one machine config key ("absent" when missing)
    "$PY" -c 'import json, sys
d = json.load(open(sys.argv[1]))
print(json.dumps(d[sys.argv[2]], sort_keys=True) if sys.argv[2] in d else "absent")' \
        "$M/credo/peer-lan.json" "$1"
}

pid_of_status() {
    "$PY" "$DAEMON" status 2>/dev/null | sed -n 's/^relay running: pid \([0-9]*\),.*/\1/p'
}

mk_fixture() {
    case "$TMP" in
        "${TMPDIR:-/tmp}"/cdc.??????) rm -rf -- "${TMP:?}/home" ;;
        *) echo "refusing to reset unexpected temp root: '$TMP'" >&2; exit 1 ;;
    esac
    rm -f -- "${PSLOG:?}"
    mkdir -p "$TMP/home"
    mkdir -p "$M/credo/peer-lan-keys" "$M/sessions" \
             "$S/credo/peer-lan-keys" "$S/sessions" \
             "$O/credo/peer-lan-keys" "$O/sessions"
    cat > "$M/credo/peer-lan.json" <<JSONEOF
{"this_machine": "box-1", "listen_host": "127.0.0.1", "listen_port": $PORT,
 "peers": ["192.168.1.42:48610", "10.0.0.7"], "profiles": [".claude-work"],
 "networks": {"home": {"label": "home-net", "group": "home",
                       "router_mac": "02:00:00:00:00:01", "subnet": "192.168.1.0/24",
                       "allow": ["192.168.1.42"]}}}
JSONEOF
    # machine keystore: own identity, two pairings, one pending repair
    printf '{"id": "%s", "x": "1", "pub": "1"}\n' "$ID_C" > "$M/credo/peer-lan-keys/self.json"
    printf '{"id": "%s", "pub": "%s", "key": "%s", "slot": "192.168.1.42:48610", "machine": "box-2"}\n' \
        "$ID_A" "$KEY" "$KEY" > "$M/credo/peer-lan-keys/peer-$ID_A.json"
    printf '{"id": "%s", "pub": "%s", "key": "%s", "slot": "10.0.0.7:48610", "machine": "box-3"}\n' \
        "$ID_B" "$KEY" "$KEY" > "$M/credo/peer-lan-keys/peer-$ID_B.json"
    printf '[{"slot": "192.168.1.42:48610", "old_id": "%s", "new_id": "%s", "machine": "box-2", "reason": "new-id", "fix": ""}]\n' \
        "$ID_A" "$ID_C" > "$M/credo/peer-lan-keys/pending-repair.json"
    # machine trust list: one caption grant
    printf '{"key": "%s", "trusted": [{"peer_id": "%s", "pub": "ab12", "caption": "Alpha", "machine": "box-2"}]}\n' \
        "$KEY" "$ID_A" > "$M/credo/peer-lan-trust.json"
    chmod 600 "$M/credo/peer-lan-trust.json"
    # served sibling: its copy of the pairing and its own trust list
    printf '{"id": "%s", "pub": "%s", "key": "%s", "slot": "10.0.0.7:48610", "machine": "box-3"}\n' \
        "$ID_B" "$KEY" "$KEY" > "$S/credo/peer-lan-keys/peer-$ID_B.json"
    printf '{"key": "%s", "trusted": [{"peer_id": "%s", "pub": "ab12", "caption": "Beta", "machine": "box-3"}]}\n' \
        "$KEY" "$ID_B" > "$S/credo/peer-lan-trust.json"
    chmod 600 "$S/credo/peer-lan-trust.json"
    # LAN mirrors (marker) next to ordinary local descriptors, in machine and served profile
    printf '{"pid": 91001, "sessionId": "remote-1", "name": "Remote Alpha", "credoPeerLan": true, "credoPeerLanFrom": "box-2"}\n' > "$M/sessions/91001.json"
    printf '{"pid": 91002, "sessionId": "local-1", "name": "Local"}\n' > "$M/sessions/91002.json"
    printf 'keep me\n' > "$M/sessions/notes.txt"
    printf '{"pid": 91011, "sessionId": "remote-2", "name": "Remote Beta", "credoPeerLan": true, "credoPeerLanFrom": "box-3"}\n' > "$S/sessions/91011.json"
    printf '{"pid": 91012, "sessionId": "local-2", "name": "Local work"}\n' > "$S/sessions/91012.json"
    # the unserved profile holds the same kinds of state: it must never be touched
    printf '{"id": "%s", "pub": "%s", "key": "%s", "slot": "10.0.0.9:48610", "machine": "box-9"}\n' \
        "$ID_C" "$KEY" "$KEY" > "$O/credo/peer-lan-keys/peer-$ID_C.json"
    printf '{"key": "%s", "trusted": [{"peer_id": "%s", "pub": "ab12", "caption": "Gamma", "machine": "box-9"}]}\n' \
        "$KEY" "$ID_C" > "$O/credo/peer-lan-trust.json"
    printf '{"pid": 91031, "sessionId": "remote-3", "credoPeerLan": true}\n' > "$O/sessions/91031.json"
}

# --- dry run ----------------------------------------------------------------
mk_fixture
BEFORE="$(snap)"
OUT="$(dc --dry-run </dev/null 2>&1)"; RC=$?
check "dry-run exits 0" "0" "$RC"
grep -q "pairings" <<<"$OUT"; ok "dry-run lists the pairings" "$?"
grep -q "trust" <<<"$OUT"; ok "dry-run lists the trust entries" "$?"
grep -q "LAN mirror" <<<"$OUT"; ok "dry-run lists the LAN mirrors" "$?"
grep -q ".claude-work" <<<"$OUT"; ok "dry-run lists the served sibling profile" "$?"
grep -q "192.168.1.42" <<<"$OUT"; ok "dry-run lists the stored peer addresses" "$?"
grep -q "dry-run" <<<"$OUT"; ok "dry-run says that nothing was changed" "$?"
check "dry-run changes nothing" "$BEFORE" "$(snap)"

# --- no terminal, no --yes: refuse ------------------------------------------
mk_fixture
BEFORE="$(snap)"
OUT="$(dc </dev/null 2>&1)"; RC=$?
ok "without a terminal and without --yes it refuses (non-zero)" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
grep -q -- "--yes" <<<"$OUT"; ok "the refusal names --yes" "$?"
grep -q "pairings" <<<"$OUT"; ok "the refusal still prints the list" "$?"
check "refusal changes nothing" "$BEFORE" "$(snap)"

# --- --yes: local state of every served profile -----------------------------
mk_fixture
O_BEFORE="$(snap_dir "$O")"
OUT="$(dc --yes </dev/null 2>&1)"; RC=$?
check "--yes exits 0" "0" "$RC"
check "machine pairings removed" "0" "$(count_peer_files "$M/credo/peer-lan-keys")"
check "served sibling pairing copy removed" "0" "$(count_peer_files "$S/credo/peer-lan-keys")"
ok "pending repair removed" "$([ ! -e "$M/credo/peer-lan-keys/pending-repair.json" ] && echo 0 || echo 1)"
ok "own identity (self.json) kept" "$([ -f "$M/credo/peer-lan-keys/self.json" ] && echo 0 || echo 1)"
check "machine trust grants removed" "0" "$(count_trust "$M/credo/peer-lan-trust.json")"
check "served sibling trust grants removed" "0" "$(count_trust "$S/credo/peer-lan-trust.json")"
check "machine LAN mirrors removed" "0" "$(count_marked "$M/sessions")"
check "served sibling LAN mirrors removed" "0" "$(count_marked "$S/sessions")"
ok "local (unmarked) descriptors kept" "$([ -f "$M/sessions/91002.json" ] && [ -f "$S/sessions/91012.json" ] && echo 0 || echo 1)"
ok "unrelated files kept" "$([ -f "$M/sessions/notes.txt" ] && echo 0 || echo 1)"
check "unserved profile untouched" "$O_BEFORE" "$(snap_dir "$O")"
check "stored peer addresses removed" "absent" "$(cfg_key peers)"
check "bound networks kept" \
    '{"allow": ["192.168.1.42"], "group": "home", "label": "home-net", "router_mac": "02:00:00:00:00:01", "subnet": "192.168.1.0/24"}' \
    "$(cfg_key networks | "$PY" -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read())["home"], sort_keys=True))')"
check "profiles list kept" '[".claude-work"]' "$(cfg_key profiles)"
grep -q "not running" <<<"$OUT"; ok "a stopped relay is reported as not running" "$?"
ok "a stopped relay is not started" "$([ -z "$(pid_of_status)" ] && echo 0 || echo 1)"

# --- --yes with a running relay: restarted with a new pid -------------------
mk_fixture
"$PY" "$DAEMON" start >/dev/null 2>&1; RC=$?
check "test relay started" "0" "$RC"
OLD_PID="$(pid_of_status)"
ok "test relay has a pid" "$([ -n "$OLD_PID" ] && echo 0 || echo 1)"
OUT="$(dc --yes </dev/null 2>&1)"; RC=$?
check "--yes with a running relay exits 0" "0" "$RC"
NEW_PID="$(pid_of_status)"
ok "relay restarted with a new pid" "$([ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ] && echo 0 || echo 1)"
check "pairings still removed on the restarted relay" "0" "$(count_peer_files "$M/credo/peer-lan-keys")"
# stop the test relay now: the next fixture removes its pidfile, so cleanup could not find it
"$PY" "$DAEMON" stop >/dev/null 2>&1
ok "test relay stopped before the next fixture" "$([ -z "$(pid_of_status)" ] && echo 0 || echo 1)"

# --- unreadable trust list: refuse before anything changes ------------------
mk_fixture
printf 'not json\n' > "$M/credo/peer-lan-trust.json"
chmod 600 "$M/credo/peer-lan-trust.json"
BEFORE="$(snap)"
OUT="$(dc --yes </dev/null 2>&1)"; RC=$?
ok "an unreadable trust list refuses (non-zero)" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
check "refusal on an unreadable trust list changes nothing" "$BEFORE" "$(snap)"

# --- unlistable keystore: refuse before anything changes --------------------
mk_fixture
if [ "$(id -u)" = "0" ]; then
    ok "unlistable keystore check runs as a user, not root (skipped as root)" 0
else
    BEFORE="$(snap)"
    chmod 000 "$M/credo/peer-lan-keys"
    OUT="$(dc --yes </dev/null 2>&1)"; RC=$?
    chmod 700 "$M/credo/peer-lan-keys"
    ok "an unlistable keystore refuses (non-zero)" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
    check "refusal on an unlistable keystore changes nothing" "$BEFORE" "$(snap)"
fi

# --- --full: Windows side only under WSL ------------------------------------
mk_fixture
OUT="$(env CREDO_PEER_LAN_PROCVERSION="$PV_LINUX" PATH="$BIN:$PATH" "$PY" "$DAEMON" disconnect-all --full --yes </dev/null 2>&1)"; RC=$?
check "--full on non-WSL exits 0" "0" "$RC"
grep -q "not WSL" <<<"$OUT"; ok "--full on non-WSL says the Windows side is skipped" "$?"
ok "--full on non-WSL never calls powershell.exe" "$([ ! -e "$PSLOG" ] && echo 0 || echo 1)"
check "--full on non-WSL still clears the local state" "0" "$(count_peer_files "$M/credo/peer-lan-keys")"

mk_fixture
BEFORE="$(snap)"
OUT="$(env CREDO_PEER_LAN_PROCVERSION="$PV_WSL" PATH="$BIN:$PATH" "$PY" "$DAEMON" disconnect-all --full --dry-run </dev/null 2>&1)"; RC=$?
check "--full --dry-run on WSL exits 0" "0" "$RC"
grep -q "credo-peer-lan-proxy" <<<"$OUT"; ok "--full --dry-run names the scheduled task" "$?"
grep -q "Windows" <<<"$OUT"; ok "--full --dry-run lists the Windows items" "$?"
ok "--full --dry-run never calls powershell.exe" "$([ ! -e "$PSLOG" ] && echo 0 || echo 1)"
check "--full --dry-run changes nothing" "$BEFORE" "$(snap)"

mk_fixture
OUT="$(env CREDO_PEER_LAN_PROCVERSION="$PV_WSL" PATH="$BIN:$PATH" "$PY" "$DAEMON" disconnect-all --full --yes </dev/null 2>&1)"; RC=$?
check "--full --yes on WSL exits 0 when the Windows step succeeds" "0" "$RC"
ok "--full on WSL runs the elevated uninstall" "$([ -s "$PSLOG" ] && grep -q "Uninstall" "$PSLOG" && echo 0 || echo 1)"
ok "the uninstall targets the relay port" "$(grep -q "$PORT" "$PSLOG" 2>/dev/null && echo 0 || echo 1)"
ok "the uninstall targets the relay scheduled task" "$(grep -q "credo-peer-lan-proxy" "$PSLOG" 2>/dev/null && echo 0 || echo 1)"
check "--full on WSL clears the local state too" "0" "$(count_peer_files "$M/credo/peer-lan-keys")"

mk_fixture
OUT="$(env CREDO_PEER_LAN_PROCVERSION="$PV_WSL" PATH="$BIN:$PATH" FAKE_PS_RC=1 "$PY" "$DAEMON" disconnect-all --full --yes </dev/null 2>&1)"; RC=$?
ok "a failing Windows step makes the command exit non-zero" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
grep -q "Windows" <<<"$OUT"; ok "a failing Windows step is reported" "$?"
check "a failing Windows step still clears the local state" "0" "$(count_peer_files "$M/credo/peer-lan-keys")"

# --- done --------------------------------------------------------------------
echo "credo-peer-lan disconnect-all: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
