#!/bin/bash
# Tests for credo-peer-lan.py - the LAN peer relay.
#
# Everything runs on loopback (127.0.0.1) with two throwaway HOME/config dirs and
# FAKE inbox sockets in a temp dir. No real session is ever touched, no LAN-facing
# port is opened, nothing is installed, no long-lived daemon survives the run.
#
# It checks:
#   - a message written into a proxy socket on daemon A arrives at the fake inbox
#     socket on daemon B with the right from-name + body + a reply "from", and
#     carries NO from-mode attribute (the most important assertion),
#   - a wrong shared token is rejected (nothing is delivered),
#   - a "credoPeerLan"-marked descriptor is created for a remote session and it is
#     NOT a "credoPeerBridge" one.
#
# Usage: bash test-credo-peer-lan.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="$SCRIPT_DIR/credo-peer-lan.py"
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "SKIP: python3 not found"; exit 0; fi
if [ ! -f "$DAEMON" ]; then echo "FAIL: $DAEMON missing"; exit 1; fi

# short temp root so unix socket paths stay well under the 108-char sun_path limit
TMP="$(mktemp -d "${TMPDIR:-/tmp}/clt.XXXXXX")"

PIDS=""
cleanup() {
    # SIGTERM the daemons first so they remove their own descriptors + holders
    for p in $PIDS; do kill -TERM "$p" 2>/dev/null || true; done
    sleep 1
    for p in $PIDS; do kill -KILL "$p" 2>/dev/null || true; done
    rm -rf -- "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
ok() { # name cond(0=pass)
    if [ "$2" = "0" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; fi
}

# --- helper python programs -------------------------------------------------
cat > "$TMP/inbox.py" <<'PYEOF'
import os, socket, sys
path, out = sys.argv[1], sys.argv[2]
try:
    os.unlink(path)
except OSError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(8)
while True:
    c, _ = s.accept()
    data = b""
    while True:
        chunk = c.recv(65536)
        if not chunk:
            break
        data += chunk
    c.close()
    if data and not data.endswith(b"\n"):
        data += b"\n"
    with open(out, "ab") as f:
        f.write(data)
PYEOF

cat > "$TMP/sendproxy.py" <<'PYEOF'
import json, socket, sys, uuid
path, name, body, reply = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
env = '<cross-session-message from="%s" from-name="%s">\n%s\n</cross-session-message>' % (reply, name, body)
frame = {"type": "user", "message": {"content": env}, "uuid": str(uuid.uuid4()), "priority": "next", "from": reply}
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(path)
s.sendall((json.dumps(frame) + "\n").encode())
s.shutdown(socket.SHUT_WR)
s.close()
PYEOF

cat > "$TMP/sendtcp.py" <<'PYEOF'
import hashlib, hmac, json, socket, sys
host, port, token, body = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
mac = hmac.new(token.encode(), body.encode(), hashlib.sha256).hexdigest()
line = json.dumps({"mac": mac, "body": body}) + "\n"
s = socket.create_connection((host, port), timeout=5)
s.sendall(line.encode())
s.shutdown(socket.SHUT_WR)
s.close()
PYEOF

procstart() { # pid -> field 22 of /proc/pid/stat
    local st; st="$(cat /proc/"$1"/stat 2>/dev/null)" || return 1
    st="${st##*) }"; set -- $st; echo "${20}"
}

write_descriptor() { # file pid sid socketpath name
    "$PY" - "$1" "$2" "$3" "$4" "$5" "$(procstart "$2")" <<'PYEOF'
import json, sys
path, pid, sid, sock, name, pstart = sys.argv[1:7]
d = {
    "pid": int(pid), "sessionId": sid, "cwd": "/tmp", "startedAt": 1,
    "procStart": pstart, "version": "2.1.293", "peerProtocol": 1,
    "peerFeatures": ["notify_idle"], "kind": "interactive", "entrypoint": "cli",
    "pidDomain": "linux:testhost0000000000000000000000:pid:[1]",
    "messagingSocketPath": sock, "name": name, "nameSource": "user",
    "updatedAt": 1, "status": "idle", "statusUpdatedAt": 1,
}
open(path, "w").write(json.dumps(d))
PYEOF
}

# --- pick two free loopback ports ------------------------------------------
read PA PB < <("$PY" - <<'PYEOF'
import socket
ps = []
for _ in range(2):
    s = socket.socket(); s.bind(("127.0.0.1", 0)); ps.append(s.getsockname()[1]); s.close()
print(ps[0], ps[1])
PYEOF
)

# --- build the two machines -------------------------------------------------
TOKEN="shared-secret-123"
for M in A B; do
    mkdir -p "$TMP/$M/cfg/sessions" "$TMP/$M/cfg/credo" "$TMP/$M/sock"
done
INBOX_B="$TMP/B/inbox.sock"
SENDER_A="$TMP/A/sender.sock"   # path only; no live listener needed on A
: > "$TMP/B/inbox.log"          # exists up front so the byte-count checks are quiet

cat > "$TMP/A/cfg/credo/peer-lan.json" <<EOF
{"this_machine":"A","listen_host":"127.0.0.1","listen_port":$PA,"token":"$TOKEN",
 "roster_interval":0.3,"machine_timeout":60,
 "peers":[{"name":"B","host":"127.0.0.1","port":$PB}]}
EOF
cat > "$TMP/B/cfg/credo/peer-lan.json" <<EOF
{"this_machine":"B","listen_host":"127.0.0.1","listen_port":$PB,"token":"$TOKEN",
 "roster_interval":0.3,"machine_timeout":60,
 "peers":[{"name":"A","host":"127.0.0.1","port":$PA}]}
EOF

# fake inbox listener for machine B's real session
"$PY" "$TMP/inbox.py" "$INBOX_B" "$TMP/B/inbox.log" &
PIDS="$PIDS $!"

# two live processes to back the two fake "real" sessions (real pids + procStart)
sleep 600 & SLEEP_A=$!; PIDS="$PIDS $SLEEP_A"
sleep 600 & SLEEP_B=$!; PIDS="$PIDS $SLEEP_B"

write_descriptor "$TMP/A/cfg/sessions/$SLEEP_A.json" "$SLEEP_A" "sid-A" "$SENDER_A" "werkbank-plan"
write_descriptor "$TMP/B/cfg/sessions/$SLEEP_B.json" "$SLEEP_B" "sid-B" "$INBOX_B" "werkbank-task"

# --- start the daemons ------------------------------------------------------
CLAUDE_CONFIG_DIR="$TMP/A/cfg" CREDO_PEER_LAN_CONFIG="$TMP/A/cfg/credo/peer-lan.json" \
    CREDO_PEER_LAN_SOCKDIR="$TMP/A/sock" "$PY" "$DAEMON" daemon >"$TMP/A/daemon.log" 2>&1 &
PIDS="$PIDS $!"
CLAUDE_CONFIG_DIR="$TMP/B/cfg" CREDO_PEER_LAN_CONFIG="$TMP/B/cfg/credo/peer-lan.json" \
    CREDO_PEER_LAN_SOCKDIR="$TMP/B/sock" "$PY" "$DAEMON" daemon >"$TMP/B/daemon.log" 2>&1 &
PIDS="$PIDS $!"

# --- wait for the mirrored descriptors to appear ----------------------------
# A should mirror remote session sid-B (named "werkbank-task@B");
# B should mirror remote session sid-A (needed so B can set the reply "from").
marked_desc() { # sessions_dir  -> path of a credoPeerLan descriptor, or empty
    for f in "$1"/*.json; do
        [ -f "$f" ] || continue
        grep -q '"credoPeerLan"' "$f" 2>/dev/null && { echo "$f"; return 0; }
    done
    return 1
}

DESC_A=""
DESC_B=""
for _ in $(seq 1 60); do
    [ -n "$DESC_A" ] || DESC_A="$(marked_desc "$TMP/A/cfg/sessions" || true)"
    [ -n "$DESC_B" ] || DESC_B="$(marked_desc "$TMP/B/cfg/sessions" || true)"
    [ -n "$DESC_A" ] && [ -n "$DESC_B" ] && break
    sleep 0.25
done

ok "daemon A created a credoPeerLan descriptor for the remote session" "$([ -n "$DESC_A" ] && echo 0 || echo 1)"
ok "daemon B created a credoPeerLan descriptor for the remote session" "$([ -n "$DESC_B" ] && echo 0 || echo 1)"

if [ -n "$DESC_A" ]; then
    grep -q '"credoPeerLan"' "$DESC_A"; ok "descriptor carries the credoPeerLan marker" "$?"
    if grep -q '"credoPeerBridge"' "$DESC_A"; then
        FAIL=$((FAIL + 1)); printf 'FAIL descriptor must NOT carry credoPeerBridge\n'
    else
        PASS=$((PASS + 1))
    fi
    name="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["name"])' "$DESC_A" 2>/dev/null)"
    check "mirrored name is suffixed with the remote machine" "werkbank-task@B" "$name"
    PROXY_A="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["messagingSocketPath"])' "$DESC_A" 2>/dev/null)"
else
    PROXY_A=""
fi

# --- wrong token is rejected (nothing delivered) ----------------------------
before="$(wc -c < "$TMP/B/inbox.log" 2>/dev/null || echo 0)"
BAD_BODY='{"body":"SHOULD-NOT-ARRIVE","from_name":"evil","from_sessionId":"sid-A","kind":"deliver","target_sessionId":"sid-B"}'
"$PY" "$TMP/sendtcp.py" 127.0.0.1 "$PB" "wrong-token" "$BAD_BODY" 2>/dev/null || true
sleep 0.6
after="$(wc -c < "$TMP/B/inbox.log" 2>/dev/null || echo 0)"
check "wrong token delivers nothing" "$before" "$after"

# --- end to end over the proxy socket, with reply + no from-mode ------------
if [ -n "${PROXY_A:-}" ]; then
    for _ in $(seq 1 40); do [ -S "$PROXY_A" ] && break; sleep 0.1; done
    "$PY" "$TMP/sendproxy.py" "$PROXY_A" "localA" "hello over lan" "uds:$SENDER_A"
    got=""
    for _ in $(seq 1 60); do
        if grep -q "hello over lan" "$TMP/B/inbox.log" 2>/dev/null; then got=1; break; fi
        sleep 0.2
    done
    ok "message written to proxy on A arrives at the inbox on B" "$([ -n "$got" ] && echo 0 || echo 1)"

    if [ -n "$got" ]; then
        line="$(grep "hello over lan" "$TMP/B/inbox.log" | tail -n1)"
        content="$("$PY" -c 'import json,sys;print(json.loads(sys.argv[1])["message"]["content"])' "$line" 2>/dev/null)"
        topfrom="$("$PY" -c 'import json,sys;print(json.loads(sys.argv[1]).get("from",""))' "$line" 2>/dev/null)"
        case "$content" in *'from-name="localA"'*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL envelope missing from-name\n  %s\n' "$content" ;; esac
        case "$content" in *'hello over lan'*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL envelope missing body\n' ;; esac
        # the reply "from" must be present (so a reply can route home over the LAN)
        ok "injected frame has a reply from address" "$([ -n "$topfrom" ] && echo 0 || echo 1)"
        case "$topfrom" in uds:*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL reply from is not a uds: address: %s\n' "$topfrom" ;; esac
        # THE key assertion: no from-mode anywhere in the injected message
        case "$line" in *from-mode*) FAIL=$((FAIL + 1)); printf 'FAIL injected message contains from-mode (forbidden)\n  %s\n' "$line" ;; *) PASS=$((PASS + 1)) ;; esac
    fi
else
    FAIL=$((FAIL + 1)); printf 'FAIL no proxy socket to test end to end\n'
fi

# --- S3: a non-dict roster entry must not crash the handler; valid ones still ----
# materialize. Injected as machine "C" so the live A<->B roster loops never touch it.
# The non-dict entry is first in the list, so a pre-fix handler would raise before
# reaching the valid entry and no "werkbank-remote@C" descriptor would ever appear.
# A holder refuses to start for a machine it does not know, so add "C" as a peer in
# B's config file. The already-running daemon keeps its loaded peer list (no roster
# traffic to C); only the freshly spawned holder reads this updated file.
cat > "$TMP/B/cfg/credo/peer-lan.json" <<EOF
{"this_machine":"B","listen_host":"127.0.0.1","listen_port":$PB,"token":"$TOKEN",
 "roster_interval":0.3,"machine_timeout":60,
 "peers":[{"name":"A","host":"127.0.0.1","port":$PA},{"name":"C","host":"127.0.0.1","port":$PA}]}
EOF
ROSTER_C='{"kind":"roster","machine":"C","sessions":["i-am-not-a-dict",{"name":"werkbank-remote","sessionId":"sid-C","status":"idle"}]}'
"$PY" "$TMP/sendtcp.py" 127.0.0.1 "$PB" "$TOKEN" "$ROSTER_C" 2>/dev/null || true
gotC=""
for _ in $(seq 1 60); do
    if grep -rq '"werkbank-remote@C"' "$TMP/B/cfg/sessions" 2>/dev/null; then gotC=1; break; fi
    sleep 0.2
done
ok "roster with a non-dict entry does not crash; the valid entry materializes" "$([ -n "$gotC" ] && echo 0 || echo 1)"

# --- S1: a pre-existing NON-marker descriptor at the holder pid path is NOT ------
# overwritten (pid-reuse guard). Driven at the module level so the collision is
# deterministic: a fake Popen plants a foreign descriptor at the holder pid before
# _create_remote_locked reaches its guard.
mkdir -p "$TMP/S1/cfg/sessions" "$TMP/S1/cfg/credo" "$TMP/S1/sock"
cat > "$TMP/S1/cfg/credo/peer-lan.json" <<EOF
{"this_machine":"S1H","token":"$TOKEN","peers":[]}
EOF
cat > "$TMP/S1/s1test.py" <<'PYEOF'
import importlib.util, json, os, subprocess, sys, time
daemon_path, sess_dir, sock_dir, cfg_path = sys.argv[1:5]
os.environ["CLAUDE_CONFIG_DIR"] = os.path.dirname(os.path.dirname(cfg_path))
os.environ["CREDO_PEER_LAN_SOCKDIR"] = sock_dir
os.environ["CREDO_PEER_LAN_CONFIG"] = cfg_path
spec = importlib.util.spec_from_file_location("credo_peer_lan", daemon_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
d = mod.Daemon({"token": "t", "this_machine": "S1H"})
os.makedirs(d.sess_dir, exist_ok=True)
os.makedirs(d.sock_dir, exist_ok=True)
real_popen = mod.subprocess.Popen
holders = []
def fake_popen(argv, **kw):
    proxy = argv[argv.index("--proxy") + 1]
    p = real_popen(["sleep", "600"])
    holders.append(p)
    # make os.path.exists(proxy) true so the bind-wait loop returns at once
    open(proxy, "w").close()
    # plant a FOREIGN (non-marker) descriptor at this holder pid path (pid reuse)
    dp = os.path.join(d.sess_dir, "%d.json" % p.pid)
    with open(dp, "w") as fh:
        json.dump({"pid": p.pid, "sessionId": "real-local-session",
                   "messagingSocketPath": "/tmp/real.sock"}, fh)
    return p
mod.subprocess.Popen = fake_popen
rc = 0
try:
    template = {"pidDomain": "linux:x:pid:[1]", "cwd": "/tmp",
                "version": "1", "procStart": "123"}
    d._create_remote_locked(("REMOTE", "sid-x"),
                            {"name": "werk", "status": "idle"}, template)
    p = holders[0]
    dp = os.path.join(d.sess_dir, "%d.json" % p.pid)
    with open(dp) as fh:
        after = json.load(fh)
    assert after.get("sessionId") == "real-local-session", "foreign descriptor overwritten"
    assert mod.MARK not in after, "our marker leaked into a foreign descriptor"
    assert ("REMOTE", "sid-x") not in d.remotes, "remote registered despite collision"
    for _ in range(40):
        if p.poll() is not None:
            break
        time.sleep(0.05)
    assert p.poll() is not None, "holder was not terminated after the skip"
    print("S1_OK")
except Exception as exc:
    sys.stderr.write("S1 test failure: %s\n" % exc)
    rc = 1
finally:
    for p in holders:
        try:
            p.kill()
        except Exception:
            pass
sys.exit(rc)
PYEOF
"$PY" "$TMP/S1/s1test.py" "$DAEMON" "$TMP/S1/cfg/sessions" "$TMP/S1/sock" \
    "$TMP/S1/cfg/credo/peer-lan.json" >"$TMP/S1/out.log" 2>&1
ok "pre-existing non-marker descriptor at the holder pid path is NOT overwritten" "$?"

# --- S2 note ----------------------------------------------------------------
# S2 has two parts. The startup proxy-socket sweep (_cleanup_stale_sockets) is
# exercised implicitly by every run (daemons start cleanly with a sock dir). The
# orphan-holder self-exit (holder notices os.getppid() changed after its parent is
# SIGKILLed/power-lost and exits) cannot be tested deterministically without racing
# a kill -9 against the OS reparent-to-init; it is covered by manual/live testing
# rather than forcing a flaky assertion here.

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
