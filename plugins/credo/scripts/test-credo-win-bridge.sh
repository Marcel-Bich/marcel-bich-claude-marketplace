#!/bin/bash
# Tests for the WSL <-> Windows peer bridge (credo-win-bridge.py + credo-win-bridge.ps1 +
# credo-win-common.ps1) and the native Windows LAN relay helpers (credo-peer-lan-win.ps1).
#
# Never touches a real session registry: every profile, sessions dir, state dir and
# Windows-side sessions dir is a fresh temp dir; every token is a fake test token.
#
#   1. pure Python logic: pipe names, canonical path + key file name, auth line build /
#      check / strip, constant-time compare, address rewrite, Windows list parsing,
#      publish list (dedupe, own marker excluded), descriptor build, cleanup of own
#      markers only, config switch.
#   2. the daemon against a FAKE PowerShell (a Python stand-in speaking the stdio
#      protocol): Windows sessions become holder mirrors in every profile, a WSL write
#      reaches the fake Windows side with the reply address swapped and no auth line, a
#      Windows message reaches the WSL inbox written BY THE HOLDER (SO_PEERCRED), and a
#      shutdown removes only our own files.
#   3. only when powershell.exe works (WSL with interop) and CREDO_TEST_WINDOWS is not 0:
#      the REAL PowerShell half against a fake Windows inbox in a temp dir under
#      %TEMP%: PowerShell helper unit checks (same key file name as Python, token
#      compare, envelope check of the native relay), then both message directions end to
#      end, an unauthenticated connection dropped, and nothing left behind.
#
# Usage: bash test-credo-win-bridge.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$SCRIPT_DIR/credo-win-bridge.py"
[ -f "$BRIDGE" ] || { echo "FAIL: $BRIDGE missing"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 missing"; exit 0; }

# unix socket paths are limited to 107 bytes: keep the tree short
TMP="$(mktemp -d /tmp/cwb.XXXXXX)"
WINFIX=""
cleanup() {
    if [ -n "$WINFIX" ] && [ -d "$WINFIX" ]; then
        # only the files this test created in its own fixture dir, then the dir itself
        python3 - "$WINFIX" <<'PY'
import os, re, sys
d = sys.argv[1]
if os.path.basename(d).startswith("credo-wbtest-"):
    for n in os.listdir(d):
        if re.search(r"\.(json|key|txt|ps1|tmp|stop)$", n):
            os.remove(os.path.join(d, n))
    os.rmdir(d)
PY
    fi
    rm -rf -- "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
run_py() { # name, python file
    local out rc
    out="$(cd "$TMP" && CREDO_SCRIPTS="$SCRIPT_DIR" timeout 180 python3 "$2" 2>&1)"
    rc=$?
    while IFS= read -r l; do
        case "$l" in
            "PASS "*) PASS=$((PASS + 1)); [ -n "${VERBOSE:-}" ] && echo "$l" ;;
            "FAIL "*) FAIL=$((FAIL + 1)); echo "$l" ;;
            "SKIP "*) echo "$l" ;;
            *) [ -n "$l" ] && echo "  | $l" ;;
        esac
    done <<< "$out"
    if [ "$rc" != "0" ]; then FAIL=$((FAIL + 1)); echo "FAIL $1 exited $rc"; fi
}

# shared test module: loads the bridge as a module, assertion helpers
cat > "$TMP/wbt.py" <<'PY'
import importlib.util, json, os, sys
SCRIPTS = os.environ["CREDO_SCRIPTS"]
sys.path.insert(0, SCRIPTS)
spec = importlib.util.spec_from_file_location("cwb", os.path.join(SCRIPTS, "credo-win-bridge.py"))
wb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wb)

def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond or not detail else "  -- " + str(detail)))

def ns_domain():
    try:
        return "linux:test:pid:" + os.readlink("/proc/self/ns/pid").split(":", 1)[1]
    except OSError:
        return "linux:test"
PY

# --------------------------------------------------------------------------------
# 1. pure logic
# --------------------------------------------------------------------------------
cat > "$TMP/t1.py" <<'PY'
import hashlib, json, os, sys, tempfile, time
from wbt import wb, check, ns_domain

TOK = "0123456789abcdef0123456789abcdef"   # fake test token
P = "\\\\.\\pipe\\LOCAL\\cc-msg-0123456789ABCDEF0123456789ABCDEF"

check("pipe_name LOCAL", wb.pipe_name(P) == "LOCAL\\cc-msg-0123456789ABCDEF0123456789ABCDEF")
check("pipe_name forward slashes", wb.pipe_name("//./pipe/LOCAL/cc-msg-" + "a" * 32) == "LOCAL\\cc-msg-" + "a" * 32)
check("pipe_name no LOCAL", wb.pipe_name("\\\\.\\pipe\\foo") == "foo")
check("pipe_name rejects unix path", wb.pipe_name("/tmp/cc-socks-1000/1.sock") is None)
check("pipe_name rejects trailing dot", wb.pipe_name("\\\\.\\pipe\\foo.") is None)
check("pipe_name rejects extra segment", wb.pipe_name("\\\\.\\pipe\\a\\b\\c") is None)
canon = wb.canonical_pipe_path(P)
check("canonical lowercases A-Z", canon == "\\\\.\\pipe\\local\\cc-msg-0123456789abcdef0123456789abcdef", canon)
kf = wb.key_file_name(4242, P)
check("key file name = pid.sha256(canonical).key",
      kf == "4242.%s.key" % hashlib.sha256(canon.encode()).hexdigest(), kf)
check("key file name None for unix path", wb.key_file_name(1, "/tmp/x.sock") is None)

line = wb.auth_line(TOK)
check("auth line form", line == b'{"type":"auth","token":"%s"}\n' % TOK.encode())
try:
    wb.auth_line("not-a-token")
    check("auth line rejects bad token", False)
except ValueError:
    check("auth line rejects bad token", True)
msg = b'{"type":"user","message":{"role":"user","content":"hi"},"from":"uds:/tmp/a.sock"}\n'
ok, rest = wb.check_auth(line + msg, TOK)
check("check_auth ok + rest byte-identical", ok and rest == msg)
ok, rest = wb.check_auth(wb.auth_line("f" * 32) + msg, TOK)
check("check_auth wrong token", not ok and rest == b"")
ok, rest = wb.check_auth(msg, TOK)
check("check_auth missing auth line", not ok)
ok, _ = wb.check_auth(b'{"type":"auth","token":5}\n' + msg, TOK)
check("check_auth non-string token", not ok)
check("strip_auth drops a leading auth line", wb.strip_auth(line + msg) == msg)
check("strip_auth leaves other data", wb.strip_auth(msg) == msg)
check("token_equal", wb.token_equal(TOK, TOK) and not wb.token_equal(TOK, TOK[:-1] + "0")
      and not wb.token_equal(TOK, None))

# address rewrite: frame field and envelope attribute, nothing else
frame = {"msgV": 1, "msg_id": "m1", "type": "user",
         "message": {"role": "user", "content": "<cross-session-message from=\"uds:/tmp/cc-socks-1000/11.sock\" from-name=\"alice\" from-mode=\"bypass\">\nping /tmp/cc-socks-1000/11.sock\n</cross-session-message>"},
         "priority": "next", "from": "uds:/tmp/cc-socks-1000/11.sock"}
raw = json.dumps(frame, separators=(",", ":")).encode()
out = wb.rewrite_address(raw, "/tmp/cc-socks-1000/11.sock", P)
o = json.loads(out)
check("rewrite: frame from", o["from"] == "uds:" + P, o["from"])
check("rewrite: envelope from attribute",
      o["message"]["content"].startswith('<cross-session-message from="uds:%s"' % P))
check("rewrite: body text untouched", "ping /tmp/cc-socks-1000/11.sock" in o["message"]["content"])
check("rewrite: from-mode kept", 'from-mode="bypass"' in o["message"]["content"])
back = wb.rewrite_address(out, P, "/tmp/cc-socks-1000/11.sock")
check("rewrite: round trip byte-identical", back == raw)
both = wb.rewrite_lines(raw + b"\n" + raw + b"\n", lambda a: P if a == "/tmp/cc-socks-1000/11.sock" else None)
check("rewrite_lines: every line, trailing newline kept",
      both.count(json.dumps("uds:" + P)[1:-1].encode()) == 4 and both.endswith(b"\n"))
check("rewrite_lines: unknown sender unchanged", wb.rewrite_lines(raw, lambda a: None) == raw)
check("frame_from", wb.frame_from(raw) == "/tmp/cc-socks-1000/11.sock")

# Windows list parsing
good = {"pid": 4242, "sessionId": "sid-1", "messagingSocketPath": P, "name": "wsl-recovery",
        "pidDomain": "win32:box-1", "updatedAt": 5}
items = [good,
         dict(good, sessionId="sid-2", credoWinBridge=True),
         dict(good, sessionId="sid-3", credoPeerLan=True),
         dict(good, sessionId="sid-4", messagingSocketPath="\\\\.\\pipe\\other"),
         dict(good, sessionId="sid-5", pid="12"),
         dict(good, sessionId="bad id"),
         dict(good, updatedAt=1, name="older")]
parsed = wb.parse_win_sessions(items)
check("parse_win_sessions keeps only real Claude pipes, newest per id",
      [d["sessionId"] for d in parsed] == ["sid-1"] and parsed[0]["name"] == "wsl-recovery", parsed)
check("win_host from pidDomain", wb.win_host(good) == "box-1")
name = wb.win_mirror_name(good, "alice")
check("win mirror name follows the LAN convention",
      name.startswith("`Claude Code`--`Windows`--`box-1`--`alice`--`.claude`--`wsl-recovery`+"), name)

# switch
check("switch default on", wb.switch_value(None, None) is True)
check("switch config off", wb.switch_value(None, "false") is False)
check("switch env wins", wb.switch_value("1", "false") is True and wb.switch_value("off", "true") is False)
os.environ["CREDO_WIN_BRIDGE"] = "0"
check("enabled() honors CREDO_WIN_BRIDGE=0", wb.enabled() is False)
os.environ["CREDO_WIN_BRIDGE"] = "on"
check("enabled() honors CREDO_WIN_BRIDGE=on", wb.enabled() is True)
del os.environ["CREDO_WIN_BRIDGE"]

# publish list, templates, descriptors, cleanup (temp profiles)
root = tempfile.mkdtemp(dir=".")
sd1 = os.path.join(root, ".claude", "sessions")
sd2 = os.path.join(root, ".claude-work", "sessions")
for d in (sd1, sd2):
    os.makedirs(d)
me = os.getpid()
pst = wb.lan().proc_start(me)
dom = ns_domain()
real = {"pid": me, "sessionId": "real-1", "procStart": pst, "pidDomain": dom,
        "messagingSocketPath": "/tmp/cc-socks-1000/%d.sock" % me, "name": "bugs", "nameSource": "user",
        "status": "busy", "version": "2.1.323", "peerFeatures": ["x"], "updatedAt": 2}
json.dump(real, open(os.path.join(sd1, "%d.json" % me), "w"))
lanm = dict(real, sessionId="lan-1", credoPeerLan=True, name="`Claude Code`--`home`--`box-2`--`bob`--`.claude`--`x`+a-b",
            messagingSocketPath="/tmp/pl-1.sock", pid=me)
json.dump(lanm, open(os.path.join(sd2, "%d.json" % me), "w"))
dup = dict(real, sessionId="real-1", credoPeerLan=True, messagingSocketPath="/tmp/pl-2.sock")
json.dump(dup, open(os.path.join(sd2, "1.json"), "w"))      # dead pid 1? also a LAN copy of a real id
ours = dict(real, sessionId="win-1", credoWinBridge=True, messagingSocketPath="/tmp/wb-x.sock")
json.dump(ours, open(os.path.join(sd2, "999999.json"), "w"))
copy = dict(real, sessionId="copy-1", credoPeerBridge=True)
json.dump(copy, open(os.path.join(sd1, "999998.json"), "w"))
dead = dict(real, sessionId="dead-1", pid=999997, procStart="1")
json.dump(dead, open(os.path.join(sd1, "999997.json"), "w"))
pl = wb.publish_list([sd1, sd2], live=lambda d: d.get("pid") == me)
ids = [e["sessionId"] for e in pl]
check("publish_list: real + LAN mirror, never own/peer-bridge/dead", ids == ["lan-1", "real-1"], ids)
r1 = [e for e in pl if e["sessionId"] == "real-1"][0]
check("publish_list: real session wins over a LAN copy of the same id", r1["sock"] == real["messagingSocketPath"])
check("publish_list: real name qualified", r1["name"].startswith("`Claude Code`--`WSL`--") and "`bugs`+" in r1["name"], r1["name"])
l1 = [e for e in pl if e["sessionId"] == "lan-1"][0]
check("publish_list: LAN mirror keeps its name", l1["name"] == lanm["name"])
tpl = wb.template_for(sd1, live=lambda d: d.get("pid") == me)
check("template_for picks the live real session", tpl is not None and tpl["sessionId"] == "real-1")
d = wb.build_wsl_descriptor(good, 4242, "777", tpl, "/tmp/wb-a.sock", name, 99)
check("descriptor: holder pid/procStart, pidDomain from template, marker",
      d["pid"] == 4242 and d["procStart"] == "777" and d["pidDomain"] == dom and d["credoWinBridge"] is True
      and d["messagingSocketPath"] == "/tmp/wb-a.sock" and d["credoWinName"] == "wsl-recovery"
      and "credoPeerLan" not in d and "credoPeerBridge" not in d)
removed = wb.prune_own_descriptors([sd1, sd2])
check("prune removes only our marker", [os.path.basename(p) for p in removed] == ["999999.json"]
      and os.path.exists(os.path.join(sd1, "%d.json" % me)) and os.path.exists(os.path.join(sd1, "999998.json"))
      and os.path.exists(os.path.join(sd2, "1.json")), removed)
check("foreign_file", wb.foreign_file(os.path.join(sd1, "%d.json" % me)) and not wb.foreign_file(os.path.join(sd1, "nope.json")))
sdir = os.path.join(root, "sock")
os.makedirs(sdir)
for n in ("wb-a.sock", "wb-b.sock", "other.sock"):
    open(os.path.join(sdir, n), "w").close()
gone = wb.prune_own_sockets(sdir, keep=(os.path.join(sdir, "wb-b.sock"),))
check("prune sockets: own unreferenced only", [os.path.basename(p) for p in gone] == ["wb-a.sock"]
      and sorted(os.listdir(sdir)) == ["other.sock", "wb-b.sock"])
PY
run_py "pure logic" "$TMP/t1.py"

# --------------------------------------------------------------------------------
# 1b. LAN relay integration: a Windows session mirrored by the bridge is a local session
#     for the LAN relay (published once, under its Windows name; delivers reach it; a
#     roster entry with its id is never mirrored back; the LAN prune leaves it alone)
# --------------------------------------------------------------------------------
mkdir -p "$TMP/L/home/.claude/sessions" "$TMP/L/home/.claude/credo" "$TMP/L/home/.claude-work/sessions" "$TMP/L/sock"
echo '{"this_machine":"box-b","listen_port":48610,"peers":[]}' > "$TMP/L/home/.claude/credo/peer-lan.json"
cat > "$TMP/t1b.py" <<'PY'
import json, os, socket, sys, threading, time
from wbt import wb, check, ns_domain
lan = wb.lan()
lan.log = lambda m: None
root = os.environ["L_ROOT"]
sd1 = os.path.join(root, "home", ".claude", "sessions"); sd2 = os.path.join(root, "home", ".claude-work", "sessions")
me = os.getpid()
inbox = os.path.join(root, "sock", "wb-test.sock")
got = []
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); srv.bind(inbox); srv.listen(4)
def serve():
    while True:
        c, _ = srv.accept(); data = b""
        while True:
            ch = c.recv(65536)
            if not ch: break
            data += ch
        got.append(data); c.close()
threading.Thread(target=serve, daemon=True).start()
win = {"pid": 4321, "sessionId": "win-sid-1", "name": "wsl-recovery", "pidDomain": "win32:box-1", "status": "idle"}
tpl = {"pidDomain": ns_domain(), "version": "2.1.323"}
for sd in (sd1, sd2):   # the bridge writes one descriptor per profile, same holder pid
    d = wb.build_wsl_descriptor(win, me, lan.proc_start(me), tpl, inbox, wb.win_mirror_name(win, "alice"), 1)
    json.dump(d, open(os.path.join(sd, "%d.json" % me), "w"))
daemon = lan.Daemon({"this_machine": "box-b", "peers": ["127.0.0.1:41001"], "listen_port": 41002})
ros = [e for e in daemon._roster_sessions() if e["sessionId"] == "win-sid-1"]
check("LAN roster: Windows mirror published once", len(ros) == 1, ros)
check("LAN roster: under its Windows name and the windows profile label",
      ros and ros[0]["name"] == "wsl-recovery" and ros[0]["profile"] == "windows/.claude", ros)
sock = lan.deliver_local(lan.profile_sessions_dirs(), "win-sid-1", "peer-x", "hello windows", None)
for _ in range(50):
    if got: break
    time.sleep(0.05)
check("LAN deliver reaches the bridge holder socket", sock == inbox and got and b"hello windows" in got[0], (sock, got))
daemon._on_roster({"kind": "roster", "machine": "box-r", "listen_port": 41001,
                   "sessions": [{"sessionId": "win-sid-1", "name": "loop", "status": "idle"}]}, "127.0.0.1")
check("LAN roster entry with the Windows session id is not mirrored back",
      ("127.0.0.1:41001", "win-sid-1") not in daemon.remotes, sorted(daemon.remotes))
lan._prune_stale_descriptors_in(sd1)
check("LAN stale prune leaves bridge mirrors alone", os.path.exists(os.path.join(sd1, "%d.json" % me)))
PY
# config switch through the real credo-config.sh: global and profile layers count, a
# project .credo/config never does
mkdir -p "$TMP/C"
printf 'peer:\n  win_bridge:\n    enabled: false\n' > "$TMP/C/off.yaml"
printf 'peer:\n  win_bridge:\n    enabled: true\n' > "$TMP/C/on.yaml"
cat > "$TMP/t1c.py" <<'PY'
import os
from wbt import wb, check
C = os.environ["C_DIR"]
os.environ.pop("CREDO_WIN_BRIDGE", None)
os.environ.update(CREDO_GLOBAL=os.path.join(C, "none.yaml"), CREDO_PROFILE=os.path.join(C, "none.yaml"))
check("config: builtin default is on", wb.enabled() is True)
os.environ["CREDO_GLOBAL"] = os.path.join(C, "off.yaml")
check("config: global false switches off", wb.enabled() is False)
os.environ["CREDO_PROFILE"] = os.path.join(C, "on.yaml")
check("config: profile layer overrides global", wb.enabled() is True)
os.environ.update(CREDO_GLOBAL=os.path.join(C, "none.yaml"), CREDO_PROFILE=os.path.join(C, "none.yaml"),
                  CREDO_PROJECT=os.path.join(C, "off.yaml"))
check("config: a project config cannot switch it off", wb.enabled() is True)
os.environ["CREDO_WIN_BRIDGE"] = "0"
check("config: env wins", wb.enabled() is False)
PY
C_DIR="$TMP/C" CREDO_SKIP_ENSURE=1 run_py "config switch" "$TMP/t1c.py"

# autostart hook: WSL only, honors the env switch, delegates to `ensure` detached
HOOK="$SCRIPT_DIR/../hooks/credo-win-bridge-autostart.sh"
mkdir -p "$TMP/H/scripts"
cat > "$TMP/H/scripts/credo-win-bridge.py" <<PY
import sys
open("$TMP/H/called", "a").write(" ".join(sys.argv[1:]) + "\n")
PY
echo "Linux version 6.0 (microsoft-standard-WSL2)" > "$TMP/H/wsl"
echo "Linux version 6.0 (generic)" > "$TMP/H/native"
hook_run() { env -u WSL_DISTRO_NAME CLAUDE_PLUGIN_ROOT="$TMP/H" "$@" bash "$HOOK" >/dev/null 2>&1; echo $?; }
rc="$(hook_run CREDO_WIN_BRIDGE=0 CREDO_WIN_BRIDGE_PROCVERSION="$TMP/H/wsl")"; sleep 0.5
if [ "$rc" = "0" ] && [ ! -e "$TMP/H/called" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL hook: CREDO_WIN_BRIDGE=0 is a no-op"; fi
rc="$(hook_run CREDO_WIN_BRIDGE_PROCVERSION="$TMP/H/native")"; sleep 0.5
if [ "$rc" = "0" ] && [ ! -e "$TMP/H/called" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL hook: native Linux is a no-op"; fi
rc="$(hook_run CREDO_WIN_BRIDGE_PROCVERSION="$TMP/H/wsl")"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$TMP/H/called" ] && break; sleep 0.2; done
if [ "$rc" = "0" ] && [ "$(cat "$TMP/H/called" 2>/dev/null)" = "ensure" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL hook: WSL runs ensure (rc=$rc)"; fi

L_ROOT="$TMP/L" HOME="$TMP/L/home" CLAUDE_CONFIG_DIR="$TMP/L/home/.claude" CREDO_PEER_LAN_SOCKDIR="$TMP/L/sock" \
    CREDO_PEER_LAN_CONFIG="$TMP/L/home/.claude/credo/peer-lan.json" run_py "LAN integration" "$TMP/t1b.py"

# --------------------------------------------------------------------------------
# 2. daemon against a fake PowerShell
# --------------------------------------------------------------------------------
cat > "$TMP/fakeps.py" <<'PY'
# stand-in for credo-win-bridge.ps1: speaks the stdio protocol, records sends, injects
# Windows -> WSL messages from a file
import base64, json, os, select, sys, time
rec = os.environ["FAKE_REC"]
wins = os.environ["FAKE_WINS"]
inject = os.environ["FAKE_INJECT"]
def emit(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
emit({"op": "ready", "pid": os.getpid(), "host": "box-1", "user": "alice", "pidDomain": "win32:box-1"})
seen = 0
buf = b""
while True:
    r, _, _ = select.select([sys.stdin], [], [], 0.1)
    if r:
        line = sys.stdin.buffer.readline()
        if not line:
            break
        cmd = json.loads(line)
        with open(rec, "a") as fh:
            fh.write(json.dumps(cmd) + "\n")
        if cmd["op"] == "list":
            emit({"op": "list", "id": cmd["id"], "sessions": json.load(open(wins))})
        elif cmd["op"] == "publish":
            emit({"op": "published", "mirrors": [{"key": s["key"], "pipe": "\\\\.\\pipe\\LOCAL\\cc-msg-" + ("%032x" % abs(hash(s["key"])))[:32]} for s in cmd["sessions"]]})
        elif cmd["op"] == "send":
            emit({"op": "sent", "id": cmd["id"], "ok": True, "err": ""})
        elif cmd["op"] == "quit":
            break
    if os.path.exists(inject):
        lines = open(inject).read().splitlines()
        for l in lines[seen:]:
            emit(json.loads(l))
        seen = len(lines)
PY

cat > "$TMP/t2.py" <<'PY'
import base64, json, os, socket, struct, sys, tempfile, threading, time
from wbt import wb, check, ns_domain

root = os.path.abspath(tempfile.mkdtemp(dir="."))
os.environ["CREDO_WIN_BRIDGE_STATE"] = os.path.join(root, "st")
os.environ["CREDO_WIN_BRIDGE"] = "1"
rec = os.path.join(root, "rec.jsonl"); wins = os.path.join(root, "wins.json"); inject = os.path.join(root, "inject.jsonl")
os.environ.update(FAKE_REC=rec, FAKE_WINS=wins, FAKE_INJECT=inject)
sd1 = os.path.join(root, ".claude", "sessions"); sd2 = os.path.join(root, ".claude-work", "sessions")
for d in (sd1, sd2):
    os.makedirs(d)
wb.ensure_dirs()

# a fake WSL session: unix inbox recording (data, writer pid)
inbox = os.path.join(root, "in.sock")
got = []
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); srv.bind(inbox); srv.listen(4)
def serve():
    while True:
        c, _ = srv.accept()
        pid = struct.unpack("3i", c.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[0]
        data = b""
        while True:
            ch = c.recv(65536)
            if not ch: break
            data += ch
        got.append((data, pid)); c.close()
threading.Thread(target=serve, daemon=True).start()
me = os.getpid()
real = {"pid": me, "sessionId": "wsl-1", "procStart": wb.lan().proc_start(me), "pidDomain": ns_domain(),
        "messagingSocketPath": inbox, "name": "bugs", "nameSource": "user", "status": "idle", "version": "2.1.323"}
json.dump(real, open(os.path.join(sd1, "%d.json" % me), "w"))
WP = "\\\\.\\pipe\\LOCAL\\cc-msg-" + "b" * 32
json.dump([{"pid": 4321, "sessionId": "win-1", "messagingSocketPath": WP, "name": "wsl-recovery",
            "pidDomain": "win32:box-1", "status": "idle"}], open(wins, "w"))

d = wb.Daemon([sys.executable, os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "fakeps.py")],
              interval=0.3, sess_dirs_fn=lambda: [sd1, sd2])
t = threading.Thread(target=d.run, daemon=True); t.start()

def wait(cond, secs=10):
    end = time.time() + secs
    while time.time() < end:
        if cond(): return True
        time.sleep(0.05)
    return False

def mirrors(sd):
    return [x for x in wb.read_descriptors(sd) if x[1].get("credoWinBridge")]
check("holder mirror appears in every profile", wait(lambda: len(mirrors(sd1)) == 1 and len(mirrors(sd2)) == 1))
m = mirrors(sd1)[0][1]
check("mirror pid is a live holder with real procStart",
      wb.lan().proc_start(m["pid"]) == m["procStart"] and m["pid"] != me and m["sessionId"] == "win-1")
check("mirror pidDomain copied from the live session", m["pidDomain"] == real["pidDomain"])
check("mirror names the Windows session", "`wsl-recovery`+" in m["name"] and m["name"].startswith("`Claude Code`--`Windows`--`box-1`--`alice`"))
check("WSL session published", wait(lambda: "wsl-1" in d.mirror_pipe))

# WSL -> Windows: write into the holder socket like a Claude Code sender
frame = {"msgV": 1, "msg_id": "x1", "type": "user", "priority": "next", "from": "uds:" + inbox,
         "message": {"role": "user", "content": "<cross-session-message from=\"uds:%s\" from-name=\"bugs\">\nping\n</cross-session-message>" % inbox}}
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(m["messagingSocketPath"])
s.sendall(wb.auth_line("a" * 32) + json.dumps(frame).encode() + b"\n"); s.shutdown(socket.SHUT_WR)
s.settimeout(3); closed = s.recv(10) == b""; s.close()
check("holder closes the WSL connection after EOF", closed)
def sends():
    try:
        return [json.loads(l) for l in open(rec) if '"op": "send"' in l]
    except OSError:
        return []
check("send reached the PowerShell side", wait(lambda: len(sends()) == 1))
snd = sends()[0]
data = base64.b64decode(snd["data"])
check("send targets the Windows session pid + pipe", snd["pid"] == 4321 and snd["pipe"] == WP)
check("no auth line crosses from WSL", b'"auth"' not in data)
sent = json.loads(data)
check("reply address swapped for the Windows mirror pipe", sent["from"] == "uds:" + d.mirror_pipe["wsl-1"]
      and ('from="uds:%s"' % d.mirror_pipe["wsl-1"]) in sent["message"]["content"], sent["from"])

# Windows -> WSL: the PowerShell half reports a verified message for wsl-1
wframe = {"msgV": 1, "msg_id": "x2", "type": "user", "priority": "next", "from": "uds:" + WP,
          "message": {"role": "user", "content": "<cross-session-message from=\"uds:%s\" from-name=\"wsl-recovery\">\npong\n</cross-session-message>" % WP.replace("\\", "\\\\")}}
wl = json.dumps(frame and wframe).encode() + b"\n"
with open(inject, "a") as fh:
    fh.write(json.dumps({"op": "msg", "key": "wsl-1", "data": base64.b64encode(wl).decode()}) + "\n")
check("Windows message reached the WSL inbox", wait(lambda: len(got) == 1))
data, writer = got[0]
o = json.loads(data)
check("written by the sender's holder (SO_PEERCRED)", writer == m["pid"], (writer, m["pid"]))
check("reply address swapped for the holder socket", o["from"] == "uds:" + m["messagingSocketPath"], o["from"])
check("message text unchanged", "\npong\n" in o["message"]["content"] and o["msg_id"] == "x2")
with open(inject, "a") as fh:
    fh.write(json.dumps({"op": "msg", "key": "nobody", "data": base64.b64encode(wl).decode()}) + "\n")
time.sleep(0.5)
check("message for an unknown key dropped", len(got) == 1)

# a Windows session that ends disappears from WSL
json.dump([], open(wins, "w"))
check("vanished Windows session removed", wait(lambda: not mirrors(sd1) and not mirrors(sd2)))
check("its socket removed", wait(lambda: not [n for n in os.listdir(wb.sock_dir()) if n.startswith("wb-")]))
json.dump([{"pid": 4321, "sessionId": "win-1", "messagingSocketPath": WP, "name": "wsl-recovery",
            "pidDomain": "win32:box-1"}], open(wins, "w"))
check("and comes back", wait(lambda: len(mirrors(sd1)) == 1))
hp = mirrors(sd1)[0][1]["pid"]

# shutdown: our files go, the real descriptor stays, the PowerShell side got quit
d.stop_ev.set(); t.join(15)
check("daemon stopped", not t.is_alive())
check("shutdown removes our mirrors only", not mirrors(sd1) and not mirrors(sd2)
      and os.path.exists(os.path.join(sd1, "%d.json" % me)))
check("holder process ended", wait(lambda: not os.path.exists("/proc/%d" % hp) or open("/proc/%d/stat" % hp).read().split(") ")[1][0] == "Z", 5))
check("quit sent to PowerShell", any('"quit"' in l for l in open(rec)))
PY
run_py "fake powershell daemon" "$TMP/t2.py"

# --------------------------------------------------------------------------------
# 3. the real PowerShell half (WSL with interop only)
# --------------------------------------------------------------------------------
PS=""
if [ "${CREDO_TEST_WINDOWS:-1}" != "0" ] && command -v powershell.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
    WT="$(timeout 30 powershell.exe -NoProfile -NonInteractive -Command '[IO.Path]::GetTempPath()' 2>/dev/null | tr -d '\r')"
    [ -n "$WT" ] && PS="$(command -v powershell.exe)"
fi
if [ -z "$PS" ]; then
    echo "SKIP real PowerShell section (no Windows interop, or CREDO_TEST_WINDOWS=0)"
else
    WINFIX_W="${WT}credo-wbtest-$$-$RANDOM"
    WINFIX="$(wslpath -u "$WINFIX_W")"
    mkdir -p "$WINFIX"
    cp "$SCRIPT_DIR/credo-win-common.ps1" "$SCRIPT_DIR/credo-peer-lan-win.ps1" "$WINFIX/" 2>/dev/null
    # PowerShell helper checks, results as PASS/FAIL lines
    cat > "$WINFIX/unit.ps1" <<'PS1'
param([string]$Pipe, [string]$PyKey)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'credo-win-common.ps1')
function Check($n, $c) { if ($c) { "PASS ps: $n" } else { "FAIL ps: $n" } }
Check 'pipe name' ((Get-CredoPipeName $Pipe) -ceq ('LOCAL\cc-msg-' + 'AB' * 16))
Check 'canonical lowercases A-Z' ((Get-CredoCanonicalPipePath $Pipe) -ceq ('\\.\pipe\local\cc-msg-' + 'ab' * 16))
Check 'key file name equals Python' ((Get-CredoKeyFileName 4242 $Pipe) -ceq $PyKey)
Check 'unix path is no pipe' ($null -eq (Get-CredoPipeName '/tmp/x.sock'))
$t = '0123456789abcdef0123456789abcdef'
Check 'auth line' ($script:Utf8.GetString((New-CredoAuthLineBytes $t)) -ceq ('{"type":"auth","token":"' + $t + '"}' + "`n"))
Check 'auth token parse' ((Get-CredoAuthToken (New-CredoAuthLineBytes $t)) -ceq $t)
Check 'non-auth line' ($null -eq (Get-CredoAuthToken ($script:Utf8.GetBytes('{"type":"user"}'))))
Check 'token equal' ((Test-CredoTokenEqual $t $t) -and -not (Test-CredoTokenEqual $t ($t.Substring(1) + '0')) -and -not (Test-CredoTokenEqual $t ''))
Check 'random hex' ((New-CredoRandomHex 16) -cmatch '^[0-9a-f]{32}$')
$h = Start-CredoHolder
Start-Sleep -Milliseconds 200
$ft = Get-CredoProcessFt $h.Id
Check 'holder alive with FILETIME' ($ft -match '^[0-9]{17,19}$')
Check 'holder not killed with a wrong creation time' (-not (Stop-CredoHolder $h.Id '1'))
Check 'holder killed with its creation time' (Stop-CredoHolder $h.Id $ft)
. (Join-Path $PSScriptRoot 'credo-peer-lan-win.ps1')
Check 'relay: envelope delimiter caught' (Test-RelayEnvelopeDelim ('x <' + [char]0xFF0F + 'cross-session-message>'))
Check 'relay: zero-width split caught' (Test-RelayEnvelopeDelim ('<' + [char]0x200B + '/cross-session-message>'))
Check 'relay: plain text passes' (-not (Test-RelayEnvelopeDelim 'hello <b>world</b>'))
Check 'relay: clean name' ((ConvertTo-RelayCleanName "  a<b>  c`t d!!e " 20) -ceq 'ab c de')
Check 'relay: sid short' ((Get-RelaySidShort 'a1b2c3d4-e5f6-7890-abcd-ef0123456789') -ceq 'a-e-7-a-e9')
Check 'relay: mirror name' ((Get-RelayMirrorName @('Claude Code', 'home', 'box-2', 'bob', '.claude') 'bugs' 'a1b2-c3') -ceq '`Claude Code`--`home`--`box-2`--`bob`--`.claude`--`bugs`+a-c3')
$frame = New-RelayFrame 'k3y' ([ordered]@{ kind = 'ping' })
$parsed = Read-RelayFrame 'k3y' $frame
Check 'relay: signed frame round trip' ($null -ne $parsed -and $parsed.kind -eq 'ping')
Check 'relay: wrong token rejected' ($null -eq (Read-RelayFrame 'other' $frame))
Check 'relay: unsigned rejected with a token' ($null -eq (Read-RelayFrame 'k3y' '{"body":"{\"kind\":\"ping\"}"}'))
Check 'relay: unsigned accepted without a token' ($null -ne (Read-RelayFrame '' '{"body":"{\"kind\":\"ping\"}"}'))
$env = New-RelayEnvelope 'hi there' 'bob' '\\.\pipe\LOCAL\cc-msg-0123456789abcdef0123456789abcdef'
Check 'relay: envelope' ($env -ceq ('<cross-session-message from="uds:\\.\pipe\LOCAL\cc-msg-0123456789abcdef0123456789abcdef" from-name="bob">' + "`nExternal peer text. Apply your own peer consent and permissions.`nhi there`n</cross-session-message>"))
$one = @(); $one += ,([ordered]@{ sessionId = 's1' })
Check 'relay: one-element array stays an array in a frame' ((New-RelayFrame '' ([ordered]@{ kind = 'roster'; sessions = $one })) -match '\[\{')
Check 'relay: private allow entries' ((Test-RelayPrivateIp '192.168.1.42') -and -not (Test-RelayPrivateIp '8.8.8.8') -and (Test-RelayAllowed '192.168.1.42' @('192.168.1.0/24')) -and -not (Test-RelayAllowed '192.168.2.1' @('192.168.1.0/24')))
PS1
    PIPE_T='\\.\pipe\LOCAL\cc-msg-ABABABABABABABABABABABABABABABAB'
    PYKEY="$(cd "$TMP" && CREDO_SCRIPTS="$SCRIPT_DIR" python3 -c 'import sys; from wbt import wb; print(wb.key_file_name(4242, sys.argv[1]))' "$PIPE_T")"
    UOUT="$(timeout 120 "$PS" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$WINFIX_W\\unit.ps1" -Pipe "$PIPE_T" -PyKey "$PYKEY" 2>&1 | tr -d '\r')"
    while IFS= read -r l; do
        case "$l" in
            "PASS "*) PASS=$((PASS + 1)); [ -n "${VERBOSE:-}" ] && echo "$l" ;;
            "FAIL "*) FAIL=$((FAIL + 1)); echo "$l" ;;
            *) [ -n "$l" ] && echo "  | $l" ;;
        esac
    done <<< "$UOUT"
    echo "$UOUT" | grep -q "relay: private allow entries" || { FAIL=$((FAIL + 1)); echo "FAIL ps unit run incomplete"; }

    # fake Windows Claude Code session: an inbox pipe + descriptor + key file in the
    # fixture dir (Role Inbox), or a sender into a mirror (Role Send)
    cat > "$WINFIX/fakewin.ps1" <<'PS1'
param([string]$Role, [string]$Dir, [string]$Token, [string]$Out, [string]$Key, [string]$Body, [string]$FromPipe)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'credo-win-common.ps1')
if ($Role -eq 'Inbox') {
    $name = 'LOCAL\cc-msg-' + (New-CredoRandomHex 16)
    $path = '\\.\pipe\' + $name
    $me = [System.Diagnostics.Process]::GetCurrentProcess()
    $ft = [string]$me.StartTime.ToFileTimeUtc()
    $d = [ordered]@{ pid = $PID; sessionId = 'win-sess-1'; cwd = 'C:\Users\alice'; startedAt = 1; procStart = $ft; version = '2.1.323';
                     peerProtocol = 1; kind = 'interactive'; entrypoint = 'cli'; pidDomain = (Get-CredoPidDomain $Dir);
                     messagingSocketPath = $path; name = 'wsl-recovery'; nameSource = 'user'; status = 'idle'; updatedAt = 1 }
    [IO.File]::WriteAllText((Join-Path $Dir (Get-CredoKeyFileName $PID $path)), ('{"peerToken":"' + $Token + '","procStartFt":"' + $ft + '","pidDomain":"x"}'))
    [IO.File]::WriteAllText((Join-Path $Dir ('{0}.json' -f $PID)), ($d | ConvertTo-Json -Compress))
    $deadline = [DateTime]::UtcNow.AddSeconds(150)
    while ([DateTime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath ($Out + '.stop'))) {
        $srv = New-Object IO.Pipes.NamedPipeServerStream($name, [IO.Pipes.PipeDirection]::InOut, -1, [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous, 65536, 65536)
        $t = $srv.WaitForConnectionAsync()
        while (-not $t.Wait(200)) { if (Test-Path -LiteralPath ($Out + '.stop')) { break } }
        if (-not $t.IsCompleted) { $srv.Dispose(); break }
        $ms = New-Object IO.MemoryStream
        $buf = New-Object byte[] 65536
        while ($true) { $r = $srv.ReadAsync($buf, 0, $buf.Length); if (-not $r.Wait(5000)) { break }; if ($r.Result -le 0) { break }; $ms.Write($buf, 0, $r.Result) }
        $srv.Dispose()
        if ($ms.Length -gt 0) { [IO.File]::AppendAllText($Out, [Convert]::ToBase64String($ms.ToArray()) + "`n") }
    }
    exit 0
}
if ($Role -eq 'Send') {
    # find the mirror of WSL session $Key, then send like a Windows Claude Code sender
    foreach ($f in [IO.Directory]::GetFiles($Dir, '*.json')) {
        $o = Read-CredoJsonFile $f
        if ($null -ne $o -and $o.sessionId -eq $Key -and $o.credoWinBridge -eq $true) { $mpath = $o.messagingSocketPath; $mpid = $o.pid }
    }
    if (-not $mpath) { 'NOMIRROR'; exit 3 }
    $tok = if ($Token) { $Token } else { Find-CredoToken $Dir $mpid $mpath }
    $c = New-Object IO.Pipes.NamedPipeClientStream('.', (Get-CredoPipeName $mpath), [IO.Pipes.PipeDirection]::InOut)
    $c.Connect(5000)
    $msg = '{"msgV":1,"msg_id":"w1","type":"user","message":{"role":"user","content":"<cross-session-message from=\"uds:' + $FromPipe.Replace('\', '\\') + '\" from-name=\"wsl-recovery\">\n' + $Body + '\n</cross-session-message>"},"priority":"next","from":"uds:' + $FromPipe.Replace('\', '\\') + '"}'
    $b = (New-CredoAuthLineBytes $tok) + $script:Utf8.GetBytes($msg + "`n")
    $c.Write($b, 0, $b.Length); $c.Flush(); Start-Sleep -Milliseconds 300; $c.Dispose()
    'SENT'
}
PS1
    cat > "$TMP/t3.py" <<'PY'
import base64, json, os, socket, struct, subprocess, sys, tempfile, threading, time
from wbt import wb, check, ns_domain

PS = os.environ["T_PS"]; WFW = os.environ["T_WINFIX_W"]; WFL = os.environ["T_WINFIX"]
TOK = "c0ffee00c0ffee00c0ffee00c0ffee00"   # fake token of the fake Windows session
root = os.path.abspath(tempfile.mkdtemp(dir="."))
os.environ["CREDO_WIN_BRIDGE_STATE"] = os.path.join(root, "st")
os.environ["CREDO_WIN_BRIDGE"] = "1"
os.environ["CREDO_WIN_SESSIONS_DIR"] = WFW
os.environ["WSLENV"] = "CREDO_WIN_SESSIONS_DIR"
sd = os.path.join(root, ".claude", "sessions"); os.makedirs(sd)
wb.ensure_dirs()
recv = WFW + "\\recv.txt"; recv_l = os.path.join(WFL, "recv.txt")

inbox = os.path.join(root, "in.sock"); got = []
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); srv.bind(inbox); srv.listen(4)
def serve():
    while True:
        c, _ = srv.accept()
        pid = struct.unpack("3i", c.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[0]
        data = b""
        while True:
            ch = c.recv(65536)
            if not ch: break
            data += ch
        got.append((data, pid)); c.close()
threading.Thread(target=serve, daemon=True).start()
me = os.getpid()
json.dump({"pid": me, "sessionId": "wsl-sess-1", "procStart": wb.lan().proc_start(me), "pidDomain": ns_domain(),
           "messagingSocketPath": inbox, "name": "bugs", "nameSource": "user", "status": "idle", "version": "2.1.323"},
          open(os.path.join(sd, "%d.json" % me), "w"))

base = [PS, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"]
fake = subprocess.Popen(base + [WFW + "\\fakewin.ps1", "-Role", "Inbox", "-Dir", WFW, "-Token", TOK, "-Out", recv],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
script_w = subprocess.run(["wslpath", "-w", os.path.join(os.environ["CREDO_SCRIPTS"], "credo-win-bridge.ps1")],
                          capture_output=True, text=True).stdout.strip()
d = wb.Daemon(base + [script_w, "-Mode", "Bridge"], interval=1.0, sess_dirs_fn=lambda: [sd])
t = threading.Thread(target=d.run, daemon=True); t.start()

def wait(cond, secs=40):
    end = time.time() + secs
    while time.time() < end:
        if cond(): return True
        time.sleep(0.2)
    return False
def mirrors():
    return [x[1] for x in wb.read_descriptors(sd) if x[1].get("credoWinBridge")]
def win_files():
    return sorted(os.listdir(WFL))
try:
    check("real PS: Windows session mirrored into WSL", wait(lambda: len(mirrors()) == 1))
    m = mirrors()[0] if mirrors() else {}
    check("real PS: mirror describes the fake Windows session", m.get("sessionId") == "win-sess-1" and "`wsl-recovery`+" in m.get("name", ""))
    check("real PS: WSL session mirrored on Windows", wait(lambda: "wsl-sess-1" in d.mirror_pipe))
    mp = d.mirror_pipe.get("wsl-sess-1", "")
    wm = [f for f in win_files() if f.endswith(".json")]
    keys = [f for f in win_files() if f.endswith(".key")]
    check("real PS: Windows mirror has descriptor + own key file", len(wm) == 2 and len(keys) == 2, win_files())
    mdesc = None
    for f in wm:
        o = json.load(open(os.path.join(WFL, f), encoding="utf-8-sig"))
        if o.get("credoWinBridge"):
            mdesc = o
    check("real PS: mirror key file named like Claude Code's", mdesc is not None and
          wb.key_file_name(mdesc["pid"], mdesc["messagingSocketPath"]) in keys)
    check("real PS: mirror procStart is a FILETIME", mdesc is not None and str(mdesc["procStart"]).isdigit() and len(str(mdesc["procStart"])) >= 17)

    # WSL -> Windows
    frame = {"msgV": 1, "msg_id": "x1", "type": "user", "priority": "next", "from": "uds:" + inbox,
             "message": {"role": "user", "content": "<cross-session-message from=\"uds:%s\" from-name=\"bugs\">\nping\n</cross-session-message>" % inbox}}
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(m["messagingSocketPath"])
    s.sendall(json.dumps(frame).encode() + b"\n"); s.shutdown(socket.SHUT_WR); s.close()
    check("real PS: message reached the Windows inbox", wait(lambda: os.path.exists(recv_l) and open(recv_l).read().strip()))
    raw = base64.b64decode(open(recv_l).read().split()[0]) if os.path.exists(recv_l) else b""
    ok, rest = wb.check_auth(raw, TOK)
    check("real PS: auth line with the target's token first", ok)
    o = json.loads(rest) if ok else {}
    check("real PS: reply address is the Windows mirror pipe", o.get("from") == "uds:" + mp, o.get("from"))
    check("real PS: text unchanged", "\nping\n" in o.get("message", {}).get("content", ""))

    # Windows -> WSL
    win_pipe = None
    for f in wm:
        o2 = json.load(open(os.path.join(WFL, f), encoding="utf-8-sig"))
        if not o2.get("credoWinBridge"):
            win_pipe = o2["messagingSocketPath"]
    r = subprocess.run(base + [WFW + "\\fakewin.ps1", "-Role", "Send", "-Dir", WFW, "-Key", "wsl-sess-1", "-Body", "pong", "-FromPipe", win_pipe],
                       capture_output=True, text=True, timeout=60)
    check("real PS: Windows sender used the mirror key file", "SENT" in r.stdout, r.stdout + r.stderr)
    check("real PS: Windows message reached the WSL inbox", wait(lambda: len(got) >= 1, 20))
    if got:
        data, writer = got[0]
        o = json.loads(data)
        check("real PS: auth line stripped", b'"auth"' not in data)
        check("real PS: written by the sender's holder", writer == m.get("pid"), (writer, m.get("pid")))
        check("real PS: reply address is the holder socket", o.get("from") == "uds:" + m.get("messagingSocketPath", ""), o.get("from"))
        check("real PS: text unchanged", "\npong\n" in o["message"]["content"])
    r = subprocess.run(base + [WFW + "\\fakewin.ps1", "-Role", "Send", "-Dir", WFW, "-Key", "wsl-sess-1", "-Body", "evil", "-FromPipe", win_pipe,
                               "-Token", "ffffffffffffffffffffffffffffffff"], capture_output=True, text=True, timeout=60)
    time.sleep(3)
    check("real PS: wrong token dropped", len(got) == 1 and "SENT" in r.stdout)
finally:
    d.stop_ev.set(); t.join(30)
    open(recv_l + ".stop", "w").close()
    try:
        fake.wait(20)
    except Exception:
        fake.kill()
left = [f for f in win_files() if f.endswith(".json") or f.endswith(".key")]
own = [f for f in left if json.load(open(os.path.join(WFL, f), encoding="utf-8-sig")).get("credoWinBridge")] if left else []
check("real PS: daemon stopped", not t.is_alive())
check("real PS: no Windows mirror files left", not own, left)
check("real PS: no WSL mirror left", not mirrors())
PY
    T_PS="$PS" T_WINFIX_W="$WINFIX_W" T_WINFIX="$WINFIX" run_py "real powershell bridge" "$TMP/t3.py"
fi

echo "credo-win-bridge: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
