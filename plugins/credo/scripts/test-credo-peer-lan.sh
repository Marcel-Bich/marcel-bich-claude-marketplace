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
#   - with a shared token configured, a wrong token is rejected (nothing is delivered),
#   - token-less (no token configured on either side): two daemons still deliver a
#     message proxy->inbox end to end, the token-less daemon logs the startup warning,
#     and the injected envelope STILL carries NO from-mode,
#   - mixed case: a token-less sender (unsigned frame) against a token-requiring
#     receiver is dropped and the receiver stays responsive to a later signed message,
#   - a "credoPeerLan"-marked descriptor is created for a remote session and it is
#     NOT a "credoPeerBridge" one,
#   - single instance: a second daemon on the same listen port exits 0 cleanly
#     (EADDRINUSE lock) and the first daemon keeps relaying undisturbed,
#   - whoami native path: a mocked `ip route get` yields the src IP, never 127.0.0.1,
#   - reachability probe: a live loopback listener reads "reachable", a closed port
#     reads "not reachable",
#   - init writes a valid token-less config from one or many IPs and merges/dedupes
#     on re-run,
#   - ADDRESS-based routing: two daemons configured by plain IP strings (no name
#     contract) still deliver proxy->inbox with NO from-mode, and a 3-peer config
#     (one daemon, two peer addresses) starts without error.
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

# --- N2: concurrent proxy writers, no head-of-line block --------------------
# Two local clients write into the SAME proxy socket on A at once. One connects
# first and holds its socket open WITHOUT sending for a while; the other connects
# right after and sends immediately. With per-connection worker threads in the
# holder, the fast writer is delivered to B promptly even while the slow connection
# is still held. (With the old inline accept loop the slow connection would block
# the accept() so the fast message could not be delivered until the slow handler's
# socket timeout - this test would then fail, which is the point.) Finally the slow
# writer sends too, so both frames are delivered.
cat > "$TMP/slowproxy.py" <<'PYEOF'
import json, socket, sys, time, uuid
path, name, body, reply, delay = sys.argv[1:6]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(path)
time.sleep(float(delay))  # hold the connection open before sending anything
env = '<cross-session-message from="%s" from-name="%s">\n%s\n</cross-session-message>' % (reply, name, body)
frame = {"type": "user", "message": {"content": env}, "uuid": str(uuid.uuid4()), "priority": "next", "from": reply}
s.sendall((json.dumps(frame) + "\n").encode())
s.shutdown(socket.SHUT_WR)
s.close()
PYEOF

if [ -n "${PROXY_A:-}" ] && [ -S "$PROXY_A" ]; then
    # slow writer: connects now, holds 4s, then sends. started first so the holder
    # accepts it before the fast one.
    "$PY" "$TMP/slowproxy.py" "$PROXY_A" "slowA" "slow-concurrent-msg" "uds:$SENDER_A" 4 &
    SLOW_PID=$!; PIDS="$PIDS $SLOW_PID"
    sleep 0.5   # ensure the slow connection is accepted and held first
    "$PY" "$TMP/sendproxy.py" "$PROXY_A" "fastA" "fast-concurrent-msg" "uds:$SENDER_A"
    # the fast frame must arrive well before the slow writer sends (at 4s): a 3s
    # window is comfortably above normal loopback latency but below the slow send.
    fast=""
    for _ in $(seq 1 15); do
        if grep -q "fast-concurrent-msg" "$TMP/B/inbox.log" 2>/dev/null; then fast=1; break; fi
        sleep 0.2
    done
    ok "fast proxy writer is delivered while a slow connection is held (no head-of-line block)" "$([ -n "$fast" ] && echo 0 || echo 1)"
    # both frames must ultimately be delivered
    slow=""
    for _ in $(seq 1 40); do
        if grep -q "slow-concurrent-msg" "$TMP/B/inbox.log" 2>/dev/null; then slow=1; break; fi
        sleep 0.2
    done
    ok "both concurrent proxy writers are delivered" "$([ -n "$fast" ] && [ -n "$slow" ] && echo 0 || echo 1)"
else
    FAIL=$((FAIL + 1)); printf 'FAIL N2: no proxy socket to test concurrent writers\n'
fi

# --- N1: bounded inbound handler threads shed load without wedging -----------
# A dedicated daemon D1 runs with a tiny max_conn_threads so the cap is easy to hit.
# Several clients connect and stall (send nothing), filling the handler pool; extra
# connections are sampled by accept() and shed (logged "connection cap reached")
# instead of spawning unbounded threads. After the stalls are released, a valid,
# authenticated deliver still succeeds - proving the cap sheds load without wedging.
read PD < <("$PY" - <<'PYEOF'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PYEOF
)
mkdir -p "$TMP/D1/cfg/sessions" "$TMP/D1/cfg/credo" "$TMP/D1/sock"
INBOX_D="$TMP/D1/inbox.sock"
: > "$TMP/D1/inbox.log"
cat > "$TMP/D1/cfg/credo/peer-lan.json" <<EOF
{"this_machine":"D1","listen_host":"127.0.0.1","listen_port":$PD,"token":"$TOKEN",
 "roster_interval":60,"machine_timeout":600,"max_conn_threads":2,"peers":[]}
EOF
"$PY" "$TMP/inbox.py" "$INBOX_D" "$TMP/D1/inbox.log" &
PIDS="$PIDS $!"
sleep 600 & SLEEP_D=$!; PIDS="$PIDS $SLEEP_D"
write_descriptor "$TMP/D1/cfg/sessions/$SLEEP_D.json" "$SLEEP_D" "sid-D" "$INBOX_D" "werkbank-d1"
CLAUDE_CONFIG_DIR="$TMP/D1/cfg" CREDO_PEER_LAN_CONFIG="$TMP/D1/cfg/credo/peer-lan.json" \
    CREDO_PEER_LAN_SOCKDIR="$TMP/D1/sock" "$PY" "$DAEMON" daemon >"$TMP/D1/daemon.log" 2>&1 &
D1_PID=$!; PIDS="$PIDS $D1_PID"

# stall client: open 6 TCP connections and hold them open, sending nothing.
cat > "$TMP/stallconns.py" <<'PYEOF'
import socket, sys, time
host, port, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
socks = []
for _ in range(n):
    try:
        socks.append(socket.create_connection((host, port), timeout=5))
    except Exception:
        pass
while True:
    time.sleep(1)
PYEOF

# wait for D1 to be listening
for _ in $(seq 1 40); do
    if "$PY" -c 'import socket,sys; socket.create_connection(("127.0.0.1",int(sys.argv[1])),timeout=1).close()' "$PD" 2>/dev/null; then break; fi
    sleep 0.1
done
"$PY" "$TMP/stallconns.py" 127.0.0.1 "$PD" 6 &
STALL_PID=$!; PIDS="$PIDS $STALL_PID"

# with cap=2 and 6 stalls, the surplus connections must be shed and logged
shed=""
for _ in $(seq 1 40); do
    if grep -q "connection cap reached" "$TMP/D1/daemon.log" 2>/dev/null; then shed=1; break; fi
    sleep 0.2
done
ok "inbound handler pool sheds surplus connections at the cap" "$([ -n "$shed" ] && echo 0 || echo 1)"

# release the stalls (closing the sockets frees the held handler slots)
kill -KILL "$STALL_PID" 2>/dev/null || true

# the daemon is still responsive: a valid, authenticated deliver lands in the inbox
before_d="$(wc -c < "$TMP/D1/inbox.log" 2>/dev/null || echo 0)"
GOOD_BODY='{"body":"responsive-after-flood","from_name":"n1","from_sessionId":"","kind":"deliver","target_sessionId":"sid-D"}'
delivered=""
for _ in $(seq 1 25); do
    "$PY" "$TMP/sendtcp.py" 127.0.0.1 "$PD" "$TOKEN" "$GOOD_BODY" 2>/dev/null || true
    if grep -q "responsive-after-flood" "$TMP/D1/inbox.log" 2>/dev/null; then delivered=1; break; fi
    sleep 0.2
done
ok "daemon stays responsive after a connection flood (valid deliver still succeeds)" "$([ -n "$delivered" ] && echo 0 || echo 1)"

# --- SI: single instance - a second daemon on the same port exits 0 cleanly -----
# Start a second daemon with machine A's EXACT config (same 127.0.0.1:$PA). The bind
# must fail with EADDRINUSE, so it logs "another daemon already listening" and exits 0
# without touching any descriptor or socket daemon A owns. Daemon A keeps working.
before_desc="$(marked_desc "$TMP/A/cfg/sessions" || true)"
SECOND_LOG="$TMP/A/daemon2.log"
: > "$SECOND_LOG"
CLAUDE_CONFIG_DIR="$TMP/A/cfg" CREDO_PEER_LAN_CONFIG="$TMP/A/cfg/credo/peer-lan.json" \
    CREDO_PEER_LAN_SOCKDIR="$TMP/A/sock" "$PY" "$DAEMON" daemon >"$SECOND_LOG" 2>&1 &
SECOND_PID=$!; PIDS="$PIDS $SECOND_PID"
second_rc=""
for _ in $(seq 1 30); do   # it must exit well within a couple of seconds
    if ! kill -0 "$SECOND_PID" 2>/dev/null; then
        wait "$SECOND_PID"; second_rc=$?; break
    fi
    sleep 0.1
done
if [ -z "$second_rc" ]; then
    kill -KILL "$SECOND_PID" 2>/dev/null || true
    FAIL=$((FAIL + 1)); printf 'FAIL SI: second daemon did not exit promptly\n'
else
    check "second daemon on the same listen port exits 0" "0" "$second_rc"
fi
grep -q "already listening" "$SECOND_LOG"; ok "second daemon logs the single-instance notice" "$?"
# daemon A is undisturbed: its credoPeerLan descriptor (and proxy socket) still exist,
# and a fresh message through A's holder proxy still reaches B - proving the second
# daemon neither clobbered A's descriptor/socket nor killed its holder.
after_desc="$(marked_desc "$TMP/A/cfg/sessions" || true)"
ok "first daemon still has its credoPeerLan descriptor after the second exits" \
   "$([ -n "$after_desc" ] && echo 0 || echo 1)"
si_ok=""
if [ -n "${PROXY_A:-}" ] && [ -S "$PROXY_A" ]; then
    "$PY" "$TMP/sendproxy.py" "$PROXY_A" "localA" "alive-after-second-start" "uds:$SENDER_A"
    for _ in $(seq 1 30); do
        if grep -q "alive-after-second-start" "$TMP/B/inbox.log" 2>/dev/null; then si_ok=1; break; fi
        sleep 0.2
    done
fi
ok "first daemon keeps relaying through its holder after the second one exits" "$([ -n "$si_ok" ] && echo 0 || echo 1)"

# --- TL: token-less end to end ----------------------------------------------
# Two fresh daemons E and F with NO "token" key at all. They must still deliver a
# message proxy->inbox, the sending daemon must log the no-token startup warning,
# and the injected envelope must STILL carry NO from-mode (the key invariant).
read PE PF < <("$PY" - <<'PYEOF'
import socket
ps = []
for _ in range(2):
    s = socket.socket(); s.bind(("127.0.0.1", 0)); ps.append(s.getsockname()[1]); s.close()
print(ps[0], ps[1])
PYEOF
)
for M in E F; do
    mkdir -p "$TMP/$M/cfg/sessions" "$TMP/$M/cfg/credo" "$TMP/$M/sock"
done
INBOX_F="$TMP/F/inbox.sock"
SENDER_E="$TMP/E/sender.sock"   # path only; no live listener needed on E
: > "$TMP/F/inbox.log"
# NOTE: no "token" key at all -> token-less mode on both machines
cat > "$TMP/E/cfg/credo/peer-lan.json" <<EOF
{"this_machine":"E","listen_host":"127.0.0.1","listen_port":$PE,
 "roster_interval":0.3,"machine_timeout":60,
 "peers":[{"name":"F","host":"127.0.0.1","port":$PF}]}
EOF
cat > "$TMP/F/cfg/credo/peer-lan.json" <<EOF
{"this_machine":"F","listen_host":"127.0.0.1","listen_port":$PF,
 "roster_interval":0.3,"machine_timeout":60,
 "peers":[{"name":"E","host":"127.0.0.1","port":$PE}]}
EOF
"$PY" "$TMP/inbox.py" "$INBOX_F" "$TMP/F/inbox.log" &
PIDS="$PIDS $!"
sleep 600 & SLEEP_E=$!; PIDS="$PIDS $SLEEP_E"
sleep 600 & SLEEP_F=$!; PIDS="$PIDS $SLEEP_F"
write_descriptor "$TMP/E/cfg/sessions/$SLEEP_E.json" "$SLEEP_E" "sid-E" "$SENDER_E" "werkbank-plan-e"
write_descriptor "$TMP/F/cfg/sessions/$SLEEP_F.json" "$SLEEP_F" "sid-F" "$INBOX_F" "werkbank-task-f"
CLAUDE_CONFIG_DIR="$TMP/E/cfg" CREDO_PEER_LAN_CONFIG="$TMP/E/cfg/credo/peer-lan.json" \
    CREDO_PEER_LAN_SOCKDIR="$TMP/E/sock" "$PY" "$DAEMON" daemon >"$TMP/E/daemon.log" 2>&1 &
PIDS="$PIDS $!"
CLAUDE_CONFIG_DIR="$TMP/F/cfg" CREDO_PEER_LAN_CONFIG="$TMP/F/cfg/credo/peer-lan.json" \
    CREDO_PEER_LAN_SOCKDIR="$TMP/F/sock" "$PY" "$DAEMON" daemon >"$TMP/F/daemon.log" 2>&1 &
PIDS="$PIDS $!"

DESC_E=""
for _ in $(seq 1 60); do
    [ -n "$DESC_E" ] || DESC_E="$(marked_desc "$TMP/E/cfg/sessions" || true)"
    [ -n "$DESC_E" ] && break
    sleep 0.25
done
ok "token-less daemon E created a credoPeerLan descriptor for the remote session" "$([ -n "$DESC_E" ] && echo 0 || echo 1)"
grep -q "running without a shared token" "$TMP/E/daemon.log"; ok "token-less daemon logs the no-token startup warning" "$?"

if [ -n "$DESC_E" ]; then
    PROXY_E="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["messagingSocketPath"])' "$DESC_E" 2>/dev/null)"
else
    PROXY_E=""
fi
if [ -n "${PROXY_E:-}" ]; then
    for _ in $(seq 1 40); do [ -S "$PROXY_E" ] && break; sleep 0.1; done
    "$PY" "$TMP/sendproxy.py" "$PROXY_E" "localE" "hello token-less" "uds:$SENDER_E"
    gotE=""
    for _ in $(seq 1 60); do
        if grep -q "hello token-less" "$TMP/F/inbox.log" 2>/dev/null; then gotE=1; break; fi
        sleep 0.2
    done
    ok "token-less: message written to proxy on E arrives at the inbox on F" "$([ -n "$gotE" ] && echo 0 || echo 1)"
    if [ -n "$gotE" ]; then
        lineE="$(grep "hello token-less" "$TMP/F/inbox.log" | tail -n1)"
        # THE key assertion is preserved token-less too: no from-mode anywhere
        case "$lineE" in *from-mode*) FAIL=$((FAIL + 1)); printf 'FAIL token-less injected message contains from-mode (forbidden)\n  %s\n' "$lineE" ;; *) PASS=$((PASS + 1)) ;; esac
    fi
else
    FAIL=$((FAIL + 1)); printf 'FAIL token-less: no proxy socket to test end to end\n'
fi

# --- MX: token-less sender vs token-requiring receiver ----------------------
# A token-less sender transmits an UNSIGNED frame (no "mac") to the token-requiring
# daemon B. B must reject it via its existing verify path (nothing delivered) and must
# NOT crash: a subsequent VALID signed deliver still lands, proving B stays responsive.
cat > "$TMP/sendtcp_nosig.py" <<'PYEOF'
import json, socket, sys
host, port, body = sys.argv[1], int(sys.argv[2]), sys.argv[3]
line = json.dumps({"body": body}) + "\n"   # no "mac": a token-less sender's frame
s = socket.create_connection((host, port), timeout=5)
s.sendall(line.encode())
s.shutdown(socket.SHUT_WR)
s.close()
PYEOF

before_mx="$(wc -c < "$TMP/B/inbox.log" 2>/dev/null || echo 0)"
MX_BAD='{"body":"UNSIGNED-SHOULD-NOT-ARRIVE","from_name":"notoken","from_sessionId":"","kind":"deliver","target_sessionId":"sid-B"}'
"$PY" "$TMP/sendtcp_nosig.py" 127.0.0.1 "$PB" "$MX_BAD" 2>/dev/null || true
sleep 0.6
after_mx="$(wc -c < "$TMP/B/inbox.log" 2>/dev/null || echo 0)"
check "token-requiring receiver drops an unsigned frame from a token-less sender" "$before_mx" "$after_mx"

MX_GOOD='{"body":"signed-after-unsigned","from_name":"mx","from_sessionId":"","kind":"deliver","target_sessionId":"sid-B"}'
mx_ok=""
for _ in $(seq 1 25); do
    "$PY" "$TMP/sendtcp.py" 127.0.0.1 "$PB" "$TOKEN" "$MX_GOOD" 2>/dev/null || true
    if grep -q "signed-after-unsigned" "$TMP/B/inbox.log" 2>/dev/null; then mx_ok=1; break; fi
    sleep 0.2
done
ok "token-requiring receiver stays responsive after an unsigned frame (valid signed deliver still succeeds)" "$([ -n "$mx_ok" ] && echo 0 || echo 1)"

# --- WH: whoami native-path self-address detection (mock `ip route get`) ------
# A fake `ip` on PATH emits a canned default-route line; a non-WSL /proc/version
# override forces the native path (this test host is itself WSL2, so the override
# keeps the test off the real powershell). whoami must report the src IP, never
# 127.0.0.1.
mkdir -p "$TMP/wh/bin" "$TMP/wh/cfg/credo"
cat > "$TMP/wh/bin/ip" <<'EOF'
#!/bin/bash
# fake `ip`: a canned `ip route get` line with a known src address
echo "1.1.1.1 via 192.168.178.1 dev eth0 src 192.168.178.39 uid 1000"
echo "    cache"
EOF
chmod +x "$TMP/wh/bin/ip"
printf 'Linux version 6.1.0-generic (gcc) #1 SMP\n' > "$TMP/wh/procversion-linux"
cat > "$TMP/wh/cfg/credo/peer-lan.json" <<EOF
{"this_machine":"WH","listen_host":"0.0.0.0","listen_port":48610,"peers":[]}
EOF
WH_OUT="$(PATH="$TMP/wh/bin:$PATH" CREDO_PEER_LAN_PROCVERSION="$TMP/wh/procversion-linux" \
    CREDO_PEER_LAN_CONFIG="$TMP/wh/cfg/credo/peer-lan.json" "$PY" "$DAEMON" whoami 2>/dev/null)"
case "$WH_OUT" in *"192.168.178.39:48610"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL whoami did not report the mocked src IP\n  %s\n' "$WH_OUT" ;; esac
case "$WH_OUT" in *127.0.0.1*) FAIL=$((FAIL + 1)); printf 'FAIL whoami leaked 127.0.0.1\n' ;; *) PASS=$((PASS + 1)) ;; esac

# --- PR: reachability probe (reachable live listener vs closed port) ----------
read PR_LIVE PR_DEAD < <("$PY" - <<'PYEOF'
import socket
ps = []
for _ in range(2):
    s = socket.socket(); s.bind(("127.0.0.1", 0)); ps.append(s.getsockname()[1]); s.close()
print(ps[0], ps[1])
PYEOF
)
cat > "$TMP/tcplisten.py" <<'PYEOF'
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(8)
while True:
    c, _ = s.accept(); c.close()
PYEOF
"$PY" "$TMP/tcplisten.py" "$PR_LIVE" & PIDS="$PIDS $!"
for _ in $(seq 1 40); do
    if "$PY" -c 'import socket,sys; socket.create_connection(("127.0.0.1",int(sys.argv[1])),timeout=1).close()' "$PR_LIVE" 2>/dev/null; then break; fi
    sleep 0.1
done
mkdir -p "$TMP/pr/credo"
cat > "$TMP/pr/credo/peer-lan.json" <<EOF
{"this_machine":"PR","listen_host":"0.0.0.0","listen_port":48610,"peers":["127.0.0.1:$PR_LIVE","127.0.0.1:$PR_DEAD"]}
EOF
PR_OUT="$(PATH="$TMP/wh/bin:$PATH" CREDO_PEER_LAN_PROCVERSION="$TMP/wh/procversion-linux" \
    CREDO_PEER_LAN_CONFIG="$TMP/pr/credo/peer-lan.json" "$PY" "$DAEMON" check 2>/dev/null)"
case "$PR_OUT" in *"127.0.0.1:$PR_LIVE - reachable"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL probe did not report the live peer reachable\n  %s\n' "$PR_OUT" ;; esac
case "$PR_OUT" in *"127.0.0.1:$PR_DEAD - not reachable"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL probe did not report the closed port not reachable\n  %s\n' "$PR_OUT" ;; esac

# --- IN: init writes a valid token-less config; merges + dedupes peers --------
mkdir -p "$TMP/in/credo"
IN_CFG="$TMP/in/credo/peer-lan.json"
PATH="$TMP/wh/bin:$PATH" CREDO_PEER_LAN_PROCVERSION="$TMP/wh/procversion-linux" \
    CREDO_PEER_LAN_CONFIG="$IN_CFG" "$PY" "$DAEMON" init 192.168.1.10 >/dev/null 2>&1
ok "init creates the config from one IP" "$([ -f "$IN_CFG" ] && echo 0 || echo 1)"
IN_DEFAULTS="$("$PY" - "$IN_CFG" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1]))
ok = (c.get("listen_host") == "0.0.0.0" and int(c.get("listen_port")) == 48610
      and c.get("this_machine") and not c.get("token")
      and c.get("peers") == ["192.168.1.10"])
print("OK" if ok else "BAD %r" % c)
PYEOF
)"
case "$IN_DEFAULTS" in OK) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL init one-IP config wrong: %s\n' "$IN_DEFAULTS" ;; esac
# re-run with more IPs incl an explicit port and a duplicate -> merge, no dupes
PATH="$TMP/wh/bin:$PATH" CREDO_PEER_LAN_PROCVERSION="$TMP/wh/procversion-linux" \
    CREDO_PEER_LAN_CONFIG="$IN_CFG" "$PY" "$DAEMON" init 192.168.1.11 192.168.1.12:50000 192.168.1.10 >/dev/null 2>&1
IN_MERGE="$("$PY" - "$IN_CFG" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1]))
p = c["peers"]
exp = {"192.168.1.10", "192.168.1.11", "192.168.1.12:50000"}
dup = len([x for x in p if x == "192.168.1.10"])
ok = exp.issubset(set(p)) and dup == 1 and not c.get("token")
print("OK" if ok else "BAD %r" % p)
PYEOF
)"
case "$IN_MERGE" in OK) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL init merge/dedupe wrong: %s\n' "$IN_MERGE" ;; esac
# no IPs and no pre-existing file -> a valid token-less config with empty peers
IN_EMPTY="$TMP/in/credo/empty.json"
PATH="$TMP/wh/bin:$PATH" CREDO_PEER_LAN_PROCVERSION="$TMP/wh/procversion-linux" \
    CREDO_PEER_LAN_CONFIG="$IN_EMPTY" "$PY" "$DAEMON" init >/dev/null 2>&1
IN_EMPTY_OK="$("$PY" - "$IN_EMPTY" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1]))
print("OK" if c.get("peers") == [] and not c.get("token") and c.get("listen_host") == "0.0.0.0" else "BAD")
PYEOF
)"
case "$IN_EMPTY_OK" in OK) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL init with no IPs did not write a valid empty token-less config\n' ;; esac

# --- AB: address-based routing with STRING peers (NO name contract) -----------
# Two daemons whose peers are plain "IP:PORT" strings - no peers[].name anywhere,
# and the this_machine values are NOT referenced as peer names. Delivery must work
# proxy->inbox, the mirrored name still carries the remote this_machine, the
# injected message carries NO from-mode, and a correctly configured setup logs NO
# unexpected-peer warning.
read PG PH < <("$PY" - <<'PYEOF'
import socket
ps = []
for _ in range(2):
    s = socket.socket(); s.bind(("127.0.0.1", 0)); ps.append(s.getsockname()[1]); s.close()
print(ps[0], ps[1])
PYEOF
)
for M in G H; do mkdir -p "$TMP/$M/cfg/sessions" "$TMP/$M/cfg/credo" "$TMP/$M/sock"; done
INBOX_H="$TMP/H/inbox.sock"; SENDER_G="$TMP/G/sender.sock"; : > "$TMP/H/inbox.log"
cat > "$TMP/G/cfg/credo/peer-lan.json" <<EOF
{"this_machine":"nodeG","listen_host":"127.0.0.1","listen_port":$PG,
 "roster_interval":0.3,"machine_timeout":60,"peers":["127.0.0.1:$PH"]}
EOF
cat > "$TMP/H/cfg/credo/peer-lan.json" <<EOF
{"this_machine":"nodeH","listen_host":"127.0.0.1","listen_port":$PH,
 "roster_interval":0.3,"machine_timeout":60,"peers":["127.0.0.1:$PG"]}
EOF
"$PY" "$TMP/inbox.py" "$INBOX_H" "$TMP/H/inbox.log" & PIDS="$PIDS $!"
sleep 600 & SLEEP_G=$!; PIDS="$PIDS $SLEEP_G"
sleep 600 & SLEEP_H=$!; PIDS="$PIDS $SLEEP_H"
write_descriptor "$TMP/G/cfg/sessions/$SLEEP_G.json" "$SLEEP_G" "sid-G" "$SENDER_G" "werkbank-g"
write_descriptor "$TMP/H/cfg/sessions/$SLEEP_H.json" "$SLEEP_H" "sid-H" "$INBOX_H" "werkbank-h"
CLAUDE_CONFIG_DIR="$TMP/G/cfg" CREDO_PEER_LAN_CONFIG="$TMP/G/cfg/credo/peer-lan.json" \
    CREDO_PEER_LAN_SOCKDIR="$TMP/G/sock" "$PY" "$DAEMON" daemon >"$TMP/G/daemon.log" 2>&1 & PIDS="$PIDS $!"
CLAUDE_CONFIG_DIR="$TMP/H/cfg" CREDO_PEER_LAN_CONFIG="$TMP/H/cfg/credo/peer-lan.json" \
    CREDO_PEER_LAN_SOCKDIR="$TMP/H/sock" "$PY" "$DAEMON" daemon >"$TMP/H/daemon.log" 2>&1 & PIDS="$PIDS $!"
DESC_G=""
for _ in $(seq 1 60); do
    [ -n "$DESC_G" ] || DESC_G="$(marked_desc "$TMP/G/cfg/sessions" || true)"
    [ -n "$DESC_G" ] && break
    sleep 0.25
done
ok "address-based (string peers): daemon G mirrors the remote session" "$([ -n "$DESC_G" ] && echo 0 || echo 1)"
if [ -n "$DESC_G" ]; then
    nameG="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["name"])' "$DESC_G" 2>/dev/null)"
    check "address-based: mirrored name still suffixed with remote this_machine" "werkbank-h@nodeH" "$nameG"
    PROXY_G="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["messagingSocketPath"])' "$DESC_G" 2>/dev/null)"
else
    PROXY_G=""
fi
if [ -n "${PROXY_G:-}" ]; then
    for _ in $(seq 1 40); do [ -S "$PROXY_G" ] && break; sleep 0.1; done
    "$PY" "$TMP/sendproxy.py" "$PROXY_G" "localG" "hello address-based" "uds:$SENDER_G"
    gotG=""
    for _ in $(seq 1 60); do
        if grep -q "hello address-based" "$TMP/H/inbox.log" 2>/dev/null; then gotG=1; break; fi
        sleep 0.2
    done
    ok "address-based: message G proxy -> H inbox delivered (no name contract)" "$([ -n "$gotG" ] && echo 0 || echo 1)"
    if [ -n "$gotG" ]; then
        lineG="$(grep "hello address-based" "$TMP/H/inbox.log" | tail -n1)"
        case "$lineG" in *from-mode*) FAIL=$((FAIL + 1)); printf 'FAIL address-based injected message contains from-mode (forbidden)\n  %s\n' "$lineG" ;; *) PASS=$((PASS + 1)) ;; esac
    fi
else
    FAIL=$((FAIL + 1)); printf 'FAIL address-based: no proxy socket to test\n'
fi
if grep -q "not among this daemon's configured peer addresses" "$TMP/G/daemon.log" 2>/dev/null; then
    FAIL=$((FAIL + 1)); printf 'FAIL address-based: spurious unexpected-peer warning on a correctly configured setup\n'
else
    PASS=$((PASS + 1))
fi

# --- 3P: a 3-peer config (one daemon, two configured peer addresses) ----------
# J lists TWO peer addresses (the live H daemon + a dead port). It must start, keep
# running, and log no traceback - multiple peers work and an unreachable one is
# non-fatal.
read PJ PDEAD3 < <("$PY" - <<'PYEOF'
import socket
ps = []
for _ in range(2):
    s = socket.socket(); s.bind(("127.0.0.1", 0)); ps.append(s.getsockname()[1]); s.close()
print(ps[0], ps[1])
PYEOF
)
mkdir -p "$TMP/J/cfg/sessions" "$TMP/J/cfg/credo" "$TMP/J/sock"
cat > "$TMP/J/cfg/credo/peer-lan.json" <<EOF
{"this_machine":"nodeJ","listen_host":"127.0.0.1","listen_port":$PJ,
 "roster_interval":0.3,"machine_timeout":60,"peers":["127.0.0.1:$PH","127.0.0.1:$PDEAD3"]}
EOF
sleep 600 & SLEEP_J=$!; PIDS="$PIDS $SLEEP_J"
write_descriptor "$TMP/J/cfg/sessions/$SLEEP_J.json" "$SLEEP_J" "sid-J" "$TMP/J/sender.sock" "werkbank-j"
CLAUDE_CONFIG_DIR="$TMP/J/cfg" CREDO_PEER_LAN_CONFIG="$TMP/J/cfg/credo/peer-lan.json" \
    CREDO_PEER_LAN_SOCKDIR="$TMP/J/sock" "$PY" "$DAEMON" daemon >"$TMP/J/daemon.log" 2>&1 & J_PID=$!; PIDS="$PIDS $J_PID"
sleep 2
ok "3-peer config: daemon with two peer addresses stays up" "$(kill -0 "$J_PID" 2>/dev/null && echo 0 || echo 1)"
if grep -q "Traceback" "$TMP/J/daemon.log" 2>/dev/null; then
    FAIL=$((FAIL + 1)); printf 'FAIL 3-peer daemon logged a traceback\n'
else
    PASS=$((PASS + 1))
fi

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
