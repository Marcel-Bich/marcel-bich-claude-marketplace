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
WINFIX2=""
DD_PIDS=""
cleanup() {
    # detached test daemons (section 2b) first, by their recorded pids only
    for p in $DD_PIDS; do kill -TERM "$p" 2>/dev/null; done
    # only the files this test created in its own fixture dirs, then the dirs themselves
    for wf in "$WINFIX" "$WINFIX2"; do
        [ -n "$wf" ] && [ -d "$wf" ] || continue
        python3 - "$wf" <<'PY'
import os, re, sys
d = sys.argv[1]
if os.path.basename(d).startswith("credo-wbtest-"):
    for n in os.listdir(d):
        if re.search(r"\.(json|key|txt|ps1|tmp|stop|log|1)$", n):
            os.remove(os.path.join(d, n))
    os.rmdir(d)
PY
    done
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
good = {"pid": 4242, "sessionId": "sid-1", "messagingSocketPath": P, "name": "acme-win",
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
      [d["sessionId"] for d in parsed] == ["sid-1"] and parsed[0]["name"] == "acme-win", parsed)
check("win_host from pidDomain", wb.win_host(good) == "box-1")
name = wb.win_mirror_name(good, "alice")
check("win mirror name follows the LAN convention",
      name.startswith("`Claude Code`--`Windows`--`box-1`--`alice`--`.claude`--`acme-win`+"), name)

# switch
check("switch default on", wb.switch_value(None, None) is True)
check("switch config off", wb.switch_value(None, "false") is False)
check("switch env wins", wb.switch_value("1", "false") is True and wb.switch_value("off", "true") is False)
os.environ["CREDO_WIN_BRIDGE"] = "0"
check("enabled() honors CREDO_WIN_BRIDGE=0", wb.enabled() is False)
os.environ["CREDO_WIN_BRIDGE"] = "on"
check("enabled() honors CREDO_WIN_BRIDGE=on", wb.enabled() is True)
del os.environ["CREDO_WIN_BRIDGE"]

# elevated sender helper (#196): the elevated install command and the status line
cmd = wb.elevsend_command("C:\\Users\\alice\\x\\credo-win-elevsend.ps1", "Install")
check("elevsend: runs the copied script elevated with -Install and a result file",
      "-Verb RunAs" in cmd and "'-Install'" in cmd and "-ResultFile" in cmd and "Copy-Item" in cmd)
check("elevsend: uninstall variant", "'-Uninstall'" in wb.elevsend_command("C:\\x\\a.ps1", "Uninstall"))
for bad_path, bad_act in (("C:\\x\\it's.ps1", "Install"), ("C:\\x\\$a.ps1", "Install"), ("C:\\x\\a.ps1", "Serve")):
    try:
        wb.elevsend_command(bad_path, bad_act); refused = False
    except ValueError:
        refused = True
    check("elevsend: refuses %r / %s" % (bad_path, bad_act), refused)
check("elevsend status: not installed names the install command",
      "elevsend-install" in wb.elevsend_status_line(1, None, "/pd") and "not installed" in wb.elevsend_status_line(1, None, "/pd"))
check("elevsend status: outdated copy", "OUTDATED" in wb.elevsend_status_line(2, 1, "/pd"))
check("elevsend status: installed names the removal command", "elevsend-uninstall" in wb.elevsend_status_line(1, 1, "/pd"))
check("elevsend status: unknown ProgramData", "unknown" in wb.elevsend_status_line(1, None, None))
# the one install offer (setup, peer-lan, peer check, bridge log): decision + line
check("offer: elevated session seen + helper missing", wb.elevsend_offer_needed(["acme-admin"], 2, None))
check("offer: elevated session seen + helper outdated", wb.elevsend_offer_needed(["acme-admin"], 2, 1))
check("offer: none when the helper is current", not wb.elevsend_offer_needed(["acme-admin"], 2, 2))
check("offer: none without an elevated session", not wb.elevsend_offer_needed([], 2, None))
check("offer: setup asks even without an elevated session", wb.elevsend_offer_needed([], 2, None, always=True))
check("offer: none when the shipped version is unknown", not wb.elevsend_offer_needed(["x"], None, None, always=True))
_line = wb.elevsend_offer_text(["acme-admin"], 2, None, "/plugin/scripts/credo-win-bridge.py")
check("offer line: names the sessions, state, UAC and the exact command",
      "(acme-admin)" in _line and "not installed" in _line and "one UAC prompt" in _line
      and 'python3 "/plugin/scripts/credo-win-bridge.py" elevsend-install' in _line)
check("offer line: never unattended", "autonomous or unattended: only report" in _line)
check("offer line: outdated state", "outdated: installed v1, shipped v2" in wb.elevsend_offer_text([], 2, 1, "/x"))
check("offer line: at most three names", "a, b, c, ...)" in wb.elevsend_offer_text(["a", "b", "c", "d"], 2, None, "/x"))
_saved = (wb.elevated_sessions_seen, wb.elevsend_versions, wb.lan().wsl_interop_host)
try:
    wb.lan().wsl_interop_host = lambda: True
    wb.elevated_sessions_seen = lambda: ["acme-admin"]
    wb.elevsend_versions = lambda: (2, None, "/pd")
    check("offer(): line when needed", "acme-admin" in wb.elevsend_offer())
    wb.elevsend_versions = lambda: (2, 2, "/pd")
    check("offer(): nothing when current", wb.elevsend_offer() == "")
    wb.elevated_sessions_seen = lambda: []
    wb.elevsend_versions = lambda: (_ for _ in ()).throw(AssertionError("no Windows call needed"))
    check("offer(): no elevated session -> no Windows call, no line", wb.elevsend_offer() == "")
    wb.lan().wsl_interop_host = lambda: False
    wb.elevated_sessions_seen = lambda: ["acme-admin"]
    check("offer(): never outside WSL", wb.elevsend_offer(always=True) == "")
    wb.lan().wsl_interop_host = lambda: True
    os.environ["CREDO_ELEVSEND_OFFER"] = "0"
    check("offer(): CREDO_ELEVSEND_OFFER=0 switches it off", wb.elevsend_offer(always=True) == "")
    del os.environ["CREDO_ELEVSEND_OFFER"]
finally:
    wb.elevated_sessions_seen, wb.elevsend_versions, wb.lan().wsl_interop_host = _saved
# Windows tools print in the OEM code page: every text-mode subprocess call decodes
# tolerantly (a byte like 0x81 crashed elevsend-install after a successful install)
import re as _re
_here = os.environ["CREDO_SCRIPTS"]
for _name in ("credo-win-bridge.py", "credo-peer-lan.py"):
    _src = open(os.path.join(_here, _name), encoding="utf-8").read()
    _bad = [m.start() for m in _re.finditer(r"text=True(?![^)]*errors=)", _src)]
    check("%s: every text=True subprocess call has errors=" % _name, not _bad, _bad[:3])
_setup = open(os.path.join(_here, "..", "commands", "setup.md"), encoding="utf-8").read()
check("setup offers the elevated sender helper on WSL (never unattended)",
      "Step 12c" in _setup and "elevsend-install" in _setup and "Never run this step in\nautonomous mode" in _setup)

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
      and d["messagingSocketPath"] == "/tmp/wb-a.sock" and d["credoWinName"] == "acme-win"
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
win = {"pid": 4321, "sessionId": "win-sid-1", "name": "acme-win", "pidDomain": "win32:box-1", "status": "idle"}
tpl = {"pidDomain": ns_domain(), "version": "2.1.323"}
for sd in (sd1, sd2):   # the bridge writes one descriptor per profile, same holder pid
    d = wb.build_wsl_descriptor(win, me, lan.proc_start(me), tpl, inbox, wb.win_mirror_name(win, "alice"), 1)
    json.dump(d, open(os.path.join(sd, "%d.json" % me), "w"))
daemon = lan.Daemon({"this_machine": "box-b", "peers": ["127.0.0.1:41001"], "listen_port": 41002})
ros = [e for e in daemon._roster_sessions() if e["sessionId"] == "win-sid-1"]
check("LAN roster: Windows mirror published once", len(ros) == 1, ros)
check("LAN roster: under its Windows name and the windows profile label",
      ros and ros[0]["name"] == "acme-win" and ros[0]["profile"] == "windows/.claude", ros)
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
            # FAKE_INJECT + ".fail": report the send as failed; + ".silent": never answer
            if os.path.exists(inject + ".silent"):
                pass
            elif os.path.exists(inject + ".fail"):
                emit({"op": "sent", "id": cmd["id"], "ok": False, "err": "connect failed: access denied (test)"})
            else:
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
json.dump([{"pid": 4321, "sessionId": "win-1", "messagingSocketPath": WP, "name": "acme-win",
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
check("mirror names the Windows session", "`acme-win`+" in m["name"] and m["name"].startswith("`Claude Code`--`Windows`--`box-1`--`alice`"))
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

# delivery confirmation (#196): the sender sees success only after the PowerShell half
# reported the write; a failed or missing verdict resets the sender's socket
def claude_send(path, payload):
    """Like a Claude Code sender: write, half-close, wait for the close.
    Returns "ok", "reset" or "timeout", and the seconds it took."""
    t0 = time.time()
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.connect(path)
    c.sendall(payload); c.shutdown(socket.SHUT_WR); c.settimeout(5)
    try:
        r = "ok" if c.recv(10) == b"" else "data"
    except ConnectionResetError:
        r = "reset"
    except socket.timeout:
        r = "timeout"
    finally:
        c.close()
    return r, time.time() - t0
msg = json.dumps(frame).encode() + b"\n"
r, secs = claude_send(m["messagingSocketPath"], msg)
check("confirmed send: sender sees a clean close", r == "ok", r)
open(inject + ".fail", "w").close()
r, secs = claude_send(m["messagingSocketPath"], msg)
check("failed send: sender's socket is reset (no false success)", r == "reset", r)
check("failed send: logged as NOT delivered", wait(lambda: "NOT delivered" in open(wb.log_path()).read()))
os.unlink(inject + ".fail")
open(inject + ".silent", "w").close()
r, secs = claude_send(m["messagingSocketPath"], msg)
check("missing verdict: reset inside the sender's 5 s timeout", r == "reset" and secs < 4.8, (r, secs))
os.unlink(inject + ".silent")
big = json.dumps(dict(frame, message={"role": "user", "content": "y" * 1500000})).encode() + b"\n"
n0 = len(sends())
r, secs = claude_send(m["messagingSocketPath"], big)
check("large message (beyond the socket buffer) confirmed", r == "ok", r)
check("large message forwarded intact", wait(lambda: len(sends()) > n0) and
      json.loads(base64.b64decode(sends()[-1]["data"]))["message"]["content"] == "y" * 1500000)
check("send command carries a ttl inside the verdict window", sends()[-1].get("ttl") == wb.SEND_TTL_MS
      and wb.SEND_TTL_MS / 1000.0 < wb.VERDICT_WAIT < 5.0)
r, secs = claude_send(m["messagingSocketPath"], wb.auth_line("a" * 32))
check("auth-only connection closes cleanly without a send", r == "ok", r)
# read_held edge cases: exact bytes back, last byte still queued (so a reset is possible)
for payload in (b"", b"x", b"xy", b"hello\n"):
    a, b2 = socket.socketpair()
    a.sendall(payload); a.shutdown(socket.SHUT_WR)
    got_b = wb.read_held(b2, timeout=2)
    try:
        left = b2.recv(10, socket.MSG_PEEK | socket.MSG_DONTWAIT)
    except BlockingIOError:
        left = b""
    check("read_held returns %d-byte message intact, last byte unread" % len(payload),
          got_b == payload and left == payload[-1:], (got_b, left))
    a.close(); b2.close()
n1 = len(sends())
check("empty connection closes cleanly without a send", claude_send(m["messagingSocketPath"], b"")[0] == "ok")
check("blank 1-byte message closes cleanly without a send", claude_send(m["messagingSocketPath"], b"\n")[0] == "ok")
time.sleep(0.5)
check("no send for empty or blank messages", len(sends()) == n1, len(sends()) - n1)
check("1-byte message is confirmed", claude_send(m["messagingSocketPath"], b"x")[0] == "ok")
res = {}
def conc(i):
    res[i] = claude_send(m["messagingSocketPath"], json.dumps(dict(frame, msg_id="c%d" % i)).encode() + b"\n")[0]
ths = [threading.Thread(target=conc, args=(i,)) for i in range(2)]
[x.start() for x in ths]; [x.join(10) for x in ths]
check("two concurrent senders both confirmed", res == {0: "ok", 1: "ok"}, res)
def msg_ids(items):
    out = []
    for x in items:
        try:
            out.append(json.loads(base64.b64decode(x["data"])).get("msg_id", ""))
        except Exception:
            pass
    return sorted(out)
check("both concurrent messages forwarded", wait(lambda: msg_ids(sends()[n1:]) == ["c0", "c1"]), msg_ids(sends()[n1:]))
check("answered sends leave no pending verdict (only the unanswered one waits for its prune)", wait(lambda: len(d.pending) == 1))

# Windows -> WSL: the PowerShell half reports a verified message for wsl-1
wframe = {"msgV": 1, "msg_id": "x2", "type": "user", "priority": "next", "from": "uds:" + WP,
          "message": {"role": "user", "content": "<cross-session-message from=\"uds:%s\" from-name=\"acme-win\">\npong\n</cross-session-message>" % WP.replace("\\", "\\\\")}}
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
json.dump([{"pid": 4321, "sessionId": "win-1", "messagingSocketPath": WP, "name": "acme-win",
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
# 2b. detached daemon (item #206, parity with the LAN relay #203): log format, the
#     environment a detached daemon gets, `ensure` leaving the hook's process group
#     (double fork) and the starting session's systemd scope (own user service), and a
#     logged shutdown reason. Own state dir, HOME and profile; a minimal fake PowerShell
#     that needs no environment (the systemd unit only gets the allowlist).
# --------------------------------------------------------------------------------
cat > "$TMP/t2b.py" <<'PY'
import os, re, sys
from wbt import wb, check
os.environ["CREDO_WIN_BRIDGE_STATE"] = os.path.join(os.getcwd(), "lf")
wb.ensure_dirs()
wb.log("first line\nsecond line")
lines = open(wb.log_path()).read().splitlines()
pat = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d \[credo-win-bridge %d\] " % os.getpid())
check("log: ISO 8601 stamp with ms + offset and process tag on every line",
      len(lines) == 2 and all(pat.match(l) for l in lines), lines)
check("log: message lines kept", lines[0].endswith("first line") and lines[1].endswith("second line"), lines)

dropped = ["CREDO_SESSION_ID", "CREDO_PEER_TARGET_PID", "CREDO_SCRATCHPAD", "CREDO_WIN_BRIDGE_EVENT",
           "CREDO_WIN_BRIDGE_SPAWNED", "CREDO_X_TOKEN", "CREDO_NTFY_URL", "CREDO_AUTH_HEADER",
           "CREDO_COOKIE_JAR", "CREDO_WIFI_PSK", "CREDO_API_KEY"]
kept = ["CREDO_WIN_BRIDGE", "CREDO_WIN_BRIDGE_PS_CMD", "CREDO_WIN_BRIDGE_INTERVAL", "CREDO_WIN_BRIDGE_SPAWN"]
for k in dropped + kept:
    os.environ[k] = "v-" + k
os.environ.update(MY_SECRET="x", WSL_INTEROP="/run/x_interop", TMPDIR="/tmp/session-x")
for name, env in (("systemd", wb._spawn_env()), ("fork", wb._fork_env())):
    bad = [k for k in dropped + ["TMPDIR"] if k in env]
    if name == "systemd":
        bad += [k for k in ("MY_SECRET", "WSL_INTEROP") if k in env]
    miss = [k for k in kept + ["PATH", "HOME"] if k not in env]
    check("env %s: no session-bound or secret-like names" % name, not bad, bad)
    check("env %s: bridge settings, PATH and HOME kept" % name, not miss, miss)
    check("env %s: state dir pinned" % name, env.get("CREDO_WIN_BRIDGE_STATE") == wb.state_dir())
    if name == "fork":
        check("env fork: WSL_INTEROP kept (no systemd, its only interop path)",
              env.get("WSL_INTEROP") == "/run/x_interop")
os.environ["CREDO_WIN_BRIDGE_SPAWN"] = "bogus"
check("spawn mode: unknown value falls back to auto", wb.spawn_mode() == "auto")
PY
run_py "detached daemon: log + env" "$TMP/t2b.py"

cat > "$TMP/fakeps-min.py" <<'PY'
# minimal PowerShell stand-in for the detached-daemon checks: ready, empty lists, quit
import json, os, sys
def emit(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
emit({"op": "ready", "pid": os.getpid(), "host": "box-1", "user": "alice", "pidDomain": "win32:box-1"})
for line in sys.stdin:
    cmd = json.loads(line)
    if cmd.get("op") == "list":
        emit({"op": "list", "id": cmd["id"], "sessions": []})
    elif cmd.get("op") == "publish":
        emit({"op": "published", "mirrors": []})
    elif cmd.get("op") == "quit":
        break
PY
DD="$TMP/DD"
mkdir -p "$DD/home/.claude/sessions"
DD_PS_CMD="[\"$(command -v python3)\",\"$TMP/fakeps-min.py\"]"
dd_env() { # run a command with the isolated bridge environment
    env HOME="$DD/home" CLAUDE_CONFIG_DIR="$DD/home/.claude" CREDO_WIN_BRIDGE=1 \
        CREDO_WIN_BRIDGE_STATE="$DD/st" CREDO_WIN_BRIDGE_PS_CMD="$DD_PS_CMD" \
        CREDO_WIN_BRIDGE_INTERVAL=1 CREDO_SKIP_ENSURE=1 "$@"
}
dd_pid() { # -> daemon pid from the pidfile once alive (up to ~10 s)
    local p=""
    for _ in $(seq 1 100); do
        p="$(sed -n 's/.*"pid": *\([0-9][0-9]*\).*/\1/p' "$DD/st/bridge.pid" 2>/dev/null)"
        [ -n "$p" ] && kill -0 "$p" 2>/dev/null && { echo "$p"; return 0; }
        sleep 0.1
    done
    return 1
}
dd_stop() { # pid -> waits until it is gone
    [ -n "$1" ] || return 0
    kill -TERM "$1" 2>/dev/null
    for _ in $(seq 1 100); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
    return 1
}
okb() { if [ "$2" = "0" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL $1"; fi; }

# double fork: ensure started like the hook does, from a shell that leads its own process
# group; a SIGTERM to that whole group must not reach the daemon
mkfifo "$DD/hold.fifo"
( dd_env CREDO_WIN_BRIDGE_SPAWN=setsid setsid bash -c 'echo $$ >"$3"; "$1" "$2" ensure >/dev/null 2>&1; read -r -t 30 _ <>"$4"' \
    _ "$(command -v python3)" "$BRIDGE" "$DD/hook.pid" "$DD/hold.fifo" & ) 2>/dev/null
DD_P1="$(dd_pid)"; DD_PIDS="$DD_PIDS $DD_P1"
DD_HOOK_PGID="$(cat "$DD/hook.pid" 2>/dev/null)"
okb "detached (fork): ensure started a daemon" "$([ -n "$DD_P1" ] && echo 0 || echo 1)"
okb "detached (fork): daemon is not in the hook shell's process group" \
    "$([ -n "$DD_P1" ] && [ -n "$DD_HOOK_PGID" ] && [ "$(ps -o pgid= -p "$DD_P1" | tr -d ' ')" != "$DD_HOOK_PGID" ] && echo 0 || echo 1)"
[ -n "$DD_HOOK_PGID" ] && kill -TERM -- "-$DD_HOOK_PGID" 2>/dev/null
sleep 1
okb "detached (fork): a SIGTERM to the hook's process group does not reach the daemon" \
    "$([ -n "$DD_P1" ] && kill -0 "$DD_P1" 2>/dev/null && echo 0 || echo 1)"
grep -q "\[credo-win-bridge $DD_P1\] daemon up (version .*); daemon process: .*spawned double-fork" "$DD/st/bridge.log"
okb "detached (fork): daemon logs how it was spawned" "$?"
[ -n "$DD_P1" ] && kill -HUP "$DD_P1" 2>/dev/null
sleep 0.5
okb "detached (fork): SIGHUP leaves the daemon running" "$([ -n "$DD_P1" ] && kill -0 "$DD_P1" 2>/dev/null && echo 0 || echo 1)"
grep -q "\[credo-win-bridge $DD_P1\] SIGHUP received and ignored" "$DD/st/bridge.log"
okb "detached (fork): SIGHUP is logged" "$?"
dd_stop "$DD_P1"
okb "detached (fork): SIGTERM stops the daemon" "$?"
grep -q "\[credo-win-bridge $DD_P1\] shutting down: received SIGTERM (sender pid unknown; ppid .*spawned double-fork" "$DD/st/bridge.log"
okb "detached (fork): shutdown logs its reason (signal + process context)" "$?"
okb "detached (fork): pidfile removed on shutdown" "$([ ! -e "$DD/st/bridge.pid" ] && echo 0 || echo 1)"

# systemd: ensure inside a transient scope (like a Claude Code session started via
# systemd-run --scope); the daemon must be its own user service and survive a scope stop
if command -v systemd-run >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 \
   && systemctl --user show-environment >/dev/null 2>&1 \
   && [ "${CREDO_TEST_NO_SYSTEMD:-0}" != 1 ]; then
    DD_SCOPE="credo-test-wb-$$"
    rm -f "$DD/hold2.fifo"; mkfifo "$DD/hold2.fifo"
    ( dd_env CREDO_WIN_BRIDGE_SPAWN=systemd systemd-run --user --scope --quiet --unit="$DD_SCOPE" bash -c \
        '"$1" "$2" ensure >/dev/null 2>&1; read -r -t 30 _ <>"$3"' _ "$(command -v python3)" "$BRIDGE" "$DD/hold2.fifo" & ) 2>/dev/null
    DD_P2="$(dd_pid)"; DD_PIDS="$DD_PIDS $DD_P2"
    DD_CG="$(cat "/proc/$DD_P2/cgroup" 2>/dev/null)"
    okb "detached (systemd): daemon runs in its own user service" \
        "$(case "$DD_CG" in *"/credo-win-bridge-"*.service) echo 0 ;; *) echo 1 ;; esac)"
    okb "detached (systemd): daemon is not in the launcher's scope" \
        "$([ -n "$DD_CG" ] && case "$DD_CG" in *"$DD_SCOPE"*) echo 1 ;; *) echo 0 ;; esac)"
    DD_UNIT="$(printf '%s' "$DD_CG" | sed -n 's#.*/\(credo-win-bridge-[0-9-]*\.service\)$#\1#p')"
    systemctl --user stop "$DD_SCOPE.scope" 2>/dev/null
    sleep 1
    okb "detached (systemd): stopping the launcher's scope does not kill the daemon" \
        "$([ -n "$DD_P2" ] && kill -0 "$DD_P2" 2>/dev/null && echo 0 || echo 1)"
    grep -q "\[credo-win-bridge $DD_P2\] daemon up .*spawned systemd:credo-win-bridge-[0-9-]*\.service, cgroup .*credo-win-bridge-" "$DD/st/bridge.log"
    okb "detached (systemd): daemon logs its unit and cgroup" "$?"
    dd_stop "$DD_P2"
    grep -q "\[credo-win-bridge $DD_P2\] shutting down: received SIGTERM" "$DD/st/bridge.log"
    okb "detached (systemd): shutdown reason logged" "$?"
    sleep 0.5
    okb "detached (systemd): the unit is collected after the daemon stopped" \
        "$([ -n "$DD_UNIT" ] && [ -z "$(systemctl --user list-units --all --no-legend "$DD_UNIT" 2>/dev/null)" ] && echo 0 || echo 1)"
else
    echo "SKIP detached (systemd): no systemd user manager (systemd-run path not testable here)"
fi

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
    cp "$SCRIPT_DIR/credo-win-common.ps1" "$SCRIPT_DIR/credo-peer-lan-win.ps1" "$SCRIPT_DIR/credo-win-elevsend.ps1" "$WINFIX/" 2>/dev/null
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
$fx = Join-Path $PSScriptRoot ('atomic-' + $PID + '.txt')
Write-CredoFileAtomic $fx 'one'
$replaced = $true
try { Write-CredoFileAtomic $fx 'two' } catch { $replaced = $false }
Check 'atomic write replaces an existing file (#196)' ($replaced -and [IO.File]::ReadAllText($fx) -ceq 'two' -and
      -not (Test-Path -LiteralPath ($fx + '.credo.' + $PID + '.tmp')))
[IO.File]::Delete($fx)
$dh = @{ OwnerCache = @{ 'LOCAL\cc-msg-x' = 'S-1-5-32-544'; 'LOCAL\cc-msg-y' = 'S-1-5-21-1-2-3-1001' } }
$why = Get-CredoAccessDeniedText $dh 'LOCAL\cc-msg-x'
Check 'access denied: an Administrators-owned pipe is named as an elevated session' ((Test-CredoElevated) -or $why -match 'runs elevated')
Check 'access denied: other owners get the generic reason' ((Get-CredoAccessDeniedText $dh 'LOCAL\cc-msg-y') -match 'pipe owner S-1-5-21-1-2-3-1001')
# elevated sender helper (#196): fallback decision, request framing, target validation
Check 'helper fallback: denied + Administrators owner + not elevated' (Test-CredoUseElevHelper $true 'S-1-5-32-544' $false)
Check 'helper fallback: never when this process is elevated' (-not (Test-CredoUseElevHelper $true 'S-1-5-32-544' $true))
Check 'helper fallback: never for a user-owned pipe' (-not (Test-CredoUseElevHelper $true 'S-1-5-21-1-2-3-1001' $false))
Check 'helper fallback: never without a denial or an owner' (-not (Test-CredoUseElevHelper $false 'S-1-5-32-544' $false) -and -not (Test-CredoUseElevHelper $true $null $false))
. (Join-Path $PSScriptRoot 'credo-win-elevsend.ps1')
$tp = 'LOCAL\cc-msg-' + '0123456789abcdef' * 2
Check 'helper target: a Claude Code inbox' (Test-ElevSendTarget $tp)
Check 'helper target: refuses other pipes' (-not (Test-ElevSendTarget 'LOCAL\credo-elevsend-x') -and -not (Test-ElevSendTarget ('cc-msg-' + 'ab' * 16)) -and
      -not (Test-ElevSendTarget ('LOCAL\cc-msg-' + 'AB' * 16)) -and -not (Test-ElevSendTarget ($tp + '\x')) -and -not (Test-ElevSendTarget ('\\srv\pipe\' + $tp)))
$payload = $script:Utf8.GetBytes('{"type":"auth","token":"' + ('0' * 32) + '"}' + "`n" + '{"type":"user"}' + "`n")
$reqLine = $script:Utf8.GetString((New-CredoElevSendRequest $tp $payload)).TrimEnd("`n")
$req = ConvertFrom-ElevSendRequest $reqLine
Check 'helper request: client framing parses on the helper side' ($null -eq $req.Err -and $req.Pipe -ceq $tp -and
      [Convert]::ToBase64String($req.Data) -ceq [Convert]::ToBase64String($payload))
$tpj = $tp.Replace('\', '\\')
Check 'helper request: bad version refused' ($null -ne (ConvertFrom-ElevSendRequest ('{"v":2,"pipe":"' + $tpj + '","data":"eA=="}')).Err)
Check 'helper request: foreign pipe refused' ($null -ne (ConvertFrom-ElevSendRequest '{"v":1,"pipe":"LOCAL\\other","data":"eA=="}').Err)
Check 'helper request: non-base64 and empty data refused' ($null -ne (ConvertFrom-ElevSendRequest ('{"v":1,"pipe":"' + $tpj + '","data":"%%"}')).Err -and
      $null -ne (ConvertFrom-ElevSendRequest ('{"v":1,"pipe":"' + $tpj + '","data":""}')).Err)
Check 'helper request: not JSON refused' ($null -ne (ConvertFrom-ElevSendRequest 'nope').Err)
$okr = Read-CredoElevSendReply (New-ElevSendReply $true '')
$bad = Read-CredoElevSendReply (New-ElevSendReply $false 'no live session owns that inbox pipe')
Check 'helper reply: ok and error round trip' ($okr.Ok -and -not $bad.Ok -and $bad.Err -eq 'no live session owns that inbox pipe')
$now = [DateTime]::UtcNow
Check 'helper lifetime: keeps serving while the bridge lives and requests come' (-not (Test-ElevSendShouldExit $true $now.AddMinutes(-1) $now 5))
Check 'helper lifetime: exits when idle' (Test-ElevSendShouldExit $true $now.AddMinutes(-6) $now 5)
Check 'helper lifetime: exits when the bridge is gone' (Test-ElevSendShouldExit $false $now $now 5)
$myFt = [string]([System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToFileTimeUtc())
$af = Join-Path $PSScriptRoot ('alive-' + $PID + '.json')
[IO.File]::WriteAllText($af, ('{"pid":' + $PID + ',"ft":"' + $myFt + '"}'))
Check 'helper start gate: a live bridge alive file' (Test-ElevSendBridgeAlive $af)
[IO.File]::WriteAllText($af, ('{"pid":' + $PID + ',"ft":"1"}'))
Check 'helper start gate: a stale alive file (credo gone) is not alive' (-not (Test-ElevSendBridgeAlive $af))
[IO.File]::Delete($af)
Check 'helper start gate: no alive file is not alive' (-not (Test-ElevSendBridgeAlive $af))
$sd = Join-Path $PSScriptRoot ('sess-' + $PID)
[void](New-Item -ItemType Directory -Path $sd)
$desc = '{"pid":' + $PID + ',"procStart":"' + $myFt + '","messagingSocketPath":"\\\\.\\pipe\\' + $tpj + '"}'
[IO.File]::WriteAllText((Join-Path $sd ('{0}.json' -f $PID)), $desc)
Check 'helper target: owned by a live session' (Test-ElevSendLiveSession $sd $tp)
Check 'helper target: other pipe has no session' (-not (Test-ElevSendLiveSession $sd ('LOCAL\cc-msg-' + 'f' * 32)))
[IO.File]::WriteAllText((Join-Path $sd ('{0}.json' -f $PID)), $desc.Replace('{"pid"', '{"credoWinBridge":true,"pid"'))
Check 'helper target: a credo mirror does not count' (-not (Test-ElevSendLiveSession $sd $tp))
[IO.File]::WriteAllText((Join-Path $sd ('{0}.json' -f $PID)), $desc)
Check 'helper target: the session pid is found' ((Find-ElevSendSessionPid $sd $tp) -eq $PID)
[IO.File]::Delete((Join-Path $sd ('{0}.json' -f $PID)))
[IO.Directory]::Delete($sd)
# server identity: the pipe must be served by the session's pid, running as this user
$mySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Check 'helper identity: session pid + same user' (Test-ElevSendServerIdentity 42 42 $mySid $mySid)
Check 'helper identity: another server pid refused' (-not (Test-ElevSendServerIdentity 43 42 $mySid $mySid))
Check 'helper identity: another user refused' (-not (Test-ElevSendServerIdentity 42 42 'S-1-5-18' $mySid))
Check 'helper identity: unknown pid or owner refused' (-not (Test-ElevSendServerIdentity 0 0 $mySid $mySid) -and -not (Test-ElevSendServerIdentity 42 42 $null $mySid))
$fxName = 'LOCAL\credo-wbtest-' + [guid]::NewGuid().ToString('N')
$fxSrv = New-Object IO.Pipes.NamedPipeServerStream($fxName, 'InOut', 1, 'Byte', 'Asynchronous')
$fxWait = $fxSrv.WaitForConnectionAsync()
$fxCli = New-Object IO.Pipes.NamedPipeClientStream('.', $fxName, 'InOut')
$fxCli.Connect(2000)
Check 'helper identity: GetNamedPipeServerProcessId names the serving process' ((Get-ElevSendPipeServerPid $fxCli) -eq $PID)
$fxCli.Dispose(); $fxSrv.Dispose()
Check 'helper identity: process owner SID' ((Get-ElevSendProcessOwnerSid $PID) -eq $mySid)
Check 'helper log dir: a user folder is not admin-owned' (-not (Test-ElevSendAdminOwnedDir $PSScriptRoot))
Check 'helper log dir: the system folder is' (Test-ElevSendAdminOwnedDir ([Environment]::SystemDirectory))
Check 'helper install dir never comes from the environment' ($script:ElevInstallDir -eq (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'credo'))
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
param([string]$Role, [string]$Dir, [string]$Token, [string]$Out, [string]$Key, [string]$Body, [string]$FromPipe, [string]$Marker = 'credoWinBridge',
      [string]$Sid = 'win-sess-1', [string]$SName = 'acme-win', [switch]$Deny)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'credo-win-common.ps1')
if ($Role -eq 'Inbox') {
    $name = 'LOCAL\cc-msg-' + (New-CredoRandomHex 16)
    $path = '\\.\pipe\' + $name
    $me = [System.Diagnostics.Process]::GetCurrentProcess()
    $ft = [string]$me.StartTime.ToFileTimeUtc()
    $d = [ordered]@{ pid = $PID; sessionId = $Sid; cwd = 'C:\Users\alice'; startedAt = 1; procStart = $ft; version = '2.1.323';
                     peerProtocol = 1; kind = 'interactive'; entrypoint = 'cli'; pidDomain = (Get-CredoPidDomain $Dir);
                     messagingSocketPath = $path; name = $SName; nameSource = 'user'; status = 'idle'; updatedAt = 1 }
    [IO.File]::WriteAllText((Join-Path $Dir (Get-CredoKeyFileName $PID $path)), ('{"peerToken":"' + $Token + '","procStartFt":"' + $ft + '","pidDomain":"x"}'))
    [IO.File]::WriteAllText((Join-Path $Dir ('{0}.json' -f $PID)), ($d | ConvertTo-Json -Compress))
    $deadline = [DateTime]::UtcNow.AddSeconds(150)
    while ([DateTime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath ($Out + '.stop'))) {
        if ($Deny) {
            # like the inbox of an elevated session seen from a non-elevated client:
            # this user may read the pipe but not write to it
            $sec = New-Object IO.Pipes.PipeSecurity
            $me2 = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $sec.AddAccessRule((New-Object IO.Pipes.PipeAccessRule($me2, [IO.Pipes.PipeAccessRights]'Read, CreateNewInstance, Synchronize', 'Allow')))
            $srv = New-Object IO.Pipes.NamedPipeServerStream($name, [IO.Pipes.PipeDirection]::InOut, -1, [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous, 65536, 65536, $sec)
        } else {
            $srv = New-Object IO.Pipes.NamedPipeServerStream($name, [IO.Pipes.PipeDirection]::InOut, -1, [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous, 65536, 65536)
        }
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
        if ($null -ne $o -and (Get-CredoProp $o 'sessionId') -eq $Key -and (Get-CredoProp $o $Marker) -eq $true) { $mpath = $o.messagingSocketPath; $mpid = $o.pid }
    }
    if (-not $mpath) { 'NOMIRROR'; exit 3 }
    $tok = if ($Token) { $Token } else { Find-CredoToken $Dir $mpid $mpath }
    $c = New-Object IO.Pipes.NamedPipeClientStream('.', (Get-CredoPipeName $mpath), [IO.Pipes.PipeDirection]::InOut)
    $c.Connect(5000)
    $msg = '{"msgV":1,"msg_id":"w1","type":"user","message":{"role":"user","content":"<cross-session-message from=\"uds:' + $FromPipe.Replace('\', '\\') + '\" from-name=\"acme-win\">\n' + $Body + '\n</cross-session-message>"},"priority":"next","from":"uds:' + $FromPipe.Replace('\', '\\') + '"}'
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
os.environ["CREDO_WIN_BRIDGE_ALIVE_FILE"] = WFW + "\\alive.json"   # never the real one
os.environ["WSLENV"] = "CREDO_WIN_SESSIONS_DIR:CREDO_WIN_BRIDGE_ALIVE_FILE"
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
    check("real PS: mirror describes the fake Windows session", m.get("sessionId") == "win-sess-1" and "`acme-win`+" in m.get("name", ""))
    check("real PS: WSL session mirrored on Windows", wait(lambda: "wsl-sess-1" in d.mirror_pipe))
    mp = d.mirror_pipe.get("wsl-sess-1", "")
    # session descriptors only (<pid>.json): the bridge alive file lives in this fixture dir too
    wm = [f for f in win_files() if f.endswith(".json") and f[:-5].isdigit()]
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

    # delivery confirmation (#196) with the real PowerShell half
    def claude_send(path, payload):
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.connect(path)
        c.sendall(payload); c.shutdown(socket.SHUT_WR); c.settimeout(5)
        try:
            return "ok" if c.recv(10) == b"" else "data"
        except ConnectionResetError:
            return "reset"
        except socket.timeout:
            return "timeout"
        finally:
            c.close()
    n0 = len(open(recv_l).read().split())
    frame["msg_id"] = "x3"
    check("real PS: confirmed send reports success to the sender",
          claude_send(m["messagingSocketPath"], json.dumps(frame).encode() + b"\n") == "ok")
    check("real PS: and it is in the inbox", wait(lambda: len(open(recv_l).read().split()) > n0, 10))

    # a WSL session's status change updates the Windows mirror descriptor in place
    # (File.Replace; failed with "path is not of a legal form" before #196)
    dpath = os.path.join(sd, "%d.json" % me)
    dd = json.load(open(dpath)); dd["status"] = "busy"; json.dump(dd, open(dpath, "w"))
    def win_mirror_status():
        for f in os.listdir(WFL):
            if f.endswith(".json"):
                try:
                    o3 = json.load(open(os.path.join(WFL, f), encoding="utf-8-sig"))
                except Exception:
                    continue
                if o3.get("credoWinBridge") and o3.get("sessionId") == "wsl-sess-1":
                    return o3.get("status")
    check("real PS: mirror descriptor updated on Windows", wait(lambda: win_mirror_status() == "busy", 20), win_mirror_status())
    check("real PS: no descriptor update failure logged", "descriptor update failed" not in open(wb.log_path()).read())

    # a session whose inbox pipe denies this user write access (as an elevated session's
    # pipe does for a non-elevated bridge): the sender gets a failure, the log the cause
    denied = subprocess.Popen(base + [WFW + "\\fakewin.ps1", "-Role", "Inbox", "-Dir", WFW, "-Token", TOK, "-Out", recv + ".d",
                                      "-Sid", "win-sess-2", "-SName", "acme-admin", "-Deny"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def mirror_of(sid):
        return next((x for x in mirrors() if x.get("sessionId") == sid), None)
    check("real PS: write-protected session mirrored", wait(lambda: mirror_of("win-sess-2") is not None))
    md = mirror_of("win-sess-2") or {}
    t0 = time.time()
    res = claude_send(md.get("messagingSocketPath", "/nonexistent"), json.dumps(frame).encode() + b"\n") if md else "none"
    check("real PS: denied send is a failure for the sender, inside its timeout", res == "reset" and time.time() - t0 < 4.9, (res, time.time() - t0))
    check("real PS: log names access denied, NOT delivered", wait(lambda: "NOT delivered" in open(wb.log_path()).read()
          and "access denied" in open(wb.log_path()).read(), 10), open(wb.log_path()).read()[-600:])
finally:
    d.stop_ev.set(); t.join(30)
    open(recv_l + ".stop", "w").close()
    open(recv_l + ".d.stop", "w").close()
    for f in [fake] + ([denied] if "denied" in globals() else []):
        try:
            f.wait(20)
        except Exception:
            f.kill()
left = [f for f in win_files() if f.endswith(".json") or f.endswith(".key")]
own = [f for f in left if json.load(open(os.path.join(WFL, f), encoding="utf-8-sig")).get("credoWinBridge")] if left else []
check("real PS: daemon stopped", not t.is_alive())
check("real PS: no Windows mirror files left", not own, left)
check("real PS: no WSL mirror left", not mirrors())
PY
    T_PS="$PS" T_WINFIX_W="$WINFIX_W" T_WINFIX="$WINFIX" run_py "real powershell bridge" "$TMP/t3.py"

    # a hard-killed PowerShell half: its watchdog removes the mirrors and the holder
    cat > "$TMP/t3b.py" <<'PY'
import json, os, subprocess, time
from wbt import wb, check
PS = os.environ["T_PS"]; WFW = os.environ["T_WINFIX_W"]; WFL = os.environ["T_WINFIX"]
penv = dict(os.environ, CREDO_WIN_SESSIONS_DIR=WFW, CREDO_WIN_BRIDGE_ALIVE_FILE=WFW + "\\alive.json",
            WSLENV="CREDO_WIN_SESSIONS_DIR:CREDO_WIN_BRIDGE_ALIVE_FILE")
script_w = subprocess.run(["wslpath", "-w", os.path.join(os.environ["CREDO_SCRIPTS"], "credo-win-bridge.ps1")],
                          capture_output=True, text=True).stdout.strip()
p = subprocess.Popen([PS, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script_w, "-Mode", "Bridge"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=penv)
ready = json.loads(p.stdout.readline())
p.stdin.write(b'{"op":"publish","sessions":[{"key":"wd-1","sessionId":"wd-1","name":"wd","status":"idle"}]}\n'); p.stdin.flush()
pub = json.loads(p.stdout.readline())
def ours():
    out = []
    for n in os.listdir(WFL):
        if n.endswith(".json") and n[:-5].isdigit():
            try:
                d = json.load(open(os.path.join(WFL, n), encoding="utf-8-sig"))
            except Exception:
                continue
            if d.get("credoWinBridge"):
                out.append(d)
    return out
check("watchdog: mirror exists before the kill", pub.get("op") == "published" and len(ours()) == 1)
holder = ours()[0]["pid"] if ours() else 0
subprocess.run([PS, "-NoProfile", "-NonInteractive", "-Command", "Stop-Process -Id %d -Force" % ready["pid"]],
               capture_output=True, timeout=60)
end = time.time() + 30
while time.time() < end and ours():
    time.sleep(0.5)
check("watchdog: mirror files removed after a hard kill", not ours(), ours())
check("watchdog: key file removed", not [n for n in os.listdir(WFL) if n.endswith(".key") and n.startswith("%d." % holder)])
alive = subprocess.run([PS, "-NoProfile", "-NonInteractive", "-Command", "[bool](Get-Process -Id %d -ErrorAction SilentlyContinue)" % holder],
                       capture_output=True, text=True, timeout=60).stdout.strip()
check("watchdog: holder process ended", alive == "False", alive)
try:
    p.kill()
except Exception:
    pass
PY
    T_PS="$PS" T_WINFIX_W="$WINFIX_W" T_WINFIX="$WINFIX" run_py "watchdog" "$TMP/t3b.py"

    # no Windows sessions dir (Claude Code never ran on Windows): no mirrors, no new dir
    cat > "$TMP/t3c.py" <<'PY'
import json, os, subprocess
from wbt import wb, check
PS = os.environ["T_PS"]; WFW = os.environ["T_WINFIX_W"]; WFL = os.environ["T_WINFIX"]
penv = dict(os.environ, CREDO_WIN_SESSIONS_DIR=WFW + "\\nosessions", CREDO_WIN_BRIDGE_ALIVE_FILE=WFW + "\\alive.json",
            WSLENV="CREDO_WIN_SESSIONS_DIR:CREDO_WIN_BRIDGE_ALIVE_FILE")
script_w = subprocess.run(["wslpath", "-w", os.path.join(os.environ["CREDO_SCRIPTS"], "credo-win-bridge.ps1")],
                          capture_output=True, text=True).stdout.strip()
r = subprocess.run([PS, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script_w, "-Mode", "Bridge"],
                   input=b'{"op":"list","id":1}\n{"op":"publish","sessions":[{"key":"n-1","sessionId":"n-1","name":"n"}]}\n'
                         b'{"op":"send","id":2,"pid":1,"pipe":"\\\\\\\\.\\\\pipe\\\\LOCAL\\\\cc-msg-00000000000000000000000000000000","data":"eA=="}\n',
                   capture_output=True, env=penv, timeout=60)
evs = [json.loads(l) for l in r.stdout.decode().splitlines() if l.strip()]
ops = [e.get("op") for e in evs]
check("no sessions dir: bridge answers list, publish and send", "list" in ops and "published" in ops and "sent" in ops, ops)
pub = [e for e in evs if e.get("op") == "published"]
check("no sessions dir: no mirror made", pub and pub[0].get("mirrors") == [], pub)
sent = [e for e in evs if e.get("op") == "sent"]
check("no sessions dir: send fails cleanly", sent and sent[0].get("ok") is False, sent)
check("no sessions dir: directory not created", not os.path.exists(os.path.join(WFL, "nosessions")))
PY
    T_PS="$PS" T_WINFIX_W="$WINFIX_W" T_WINFIX="$WINFIX" run_py "no sessions dir" "$TMP/t3c.py"

    # ----------------------------------------------------------------------------
    # 4. native Windows relay (credo-peer-lan-win.ps1) against the REAL Python LAN
    #    relay over loopback (Windows localhost reaches WSL): link without pairing,
    #    rosters both ways, a deliver in each direction, shared token, cleanup
    # ----------------------------------------------------------------------------
    WINFIX2_W="${WT}credo-wbtest-$$-$RANDOM-relay"
    WINFIX2="$(wslpath -u "$WINFIX2_W")"
    mkdir -p "$WINFIX2"
    cp "$SCRIPT_DIR/credo-win-common.ps1" "$SCRIPT_DIR/credo-peer-lan-win.ps1" "$WINFIX/fakewin.ps1" "$WINFIX2/"
    cat > "$TMP/t4.py" <<'PY'
import base64, json, os, socket, subprocess, sys, tempfile, threading, time
from wbt import wb, check, ns_domain
PS = os.environ["T_PS"]; WFW = os.environ["T_WINFIX_W"]; WFL = os.environ["T_WINFIX"]
TOKEN = "test-relay-token-1"     # fake shared relay token
WTOK = "d00dd00dd00dd00dd00dd00dd00dd00d"   # fake key token of the fake Windows session
root = os.path.abspath(tempfile.mkdtemp(dir="."))
def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p
P1, P2 = free_port(), free_port()
cfg = os.path.join(root, "home", ".claude"); sd = os.path.join(cfg, "sessions")
os.makedirs(sd); os.makedirs(os.path.join(cfg, "credo")); os.makedirs(os.path.join(root, "sock"))
json.dump({"this_machine": "box-a", "listen_host": "127.0.0.1", "listen_port": P1, "token": TOKEN,
           "roster_interval": 0.5, "machine_timeout": 60, "peers": ["127.0.0.1:%d" % P2]},
          open(os.path.join(cfg, "credo", "peer-lan.json"), "w"))
inbox = os.path.join(root, "lin.sock"); got = []
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
me = os.getpid()
json.dump({"pid": me, "sessionId": "lin-1", "procStart": wb.lan().proc_start(me), "pidDomain": ns_domain(),
           "messagingSocketPath": inbox, "name": "bugs", "nameSource": "user", "status": "idle"},
          open(os.path.join(sd, "%d.json" % me), "w"))
with open(os.path.join(WFL, "relay.json"), "w") as fh:
    json.dump({"this_machine": "laptop-1", "listen_port": P2, "peers": ["127.0.0.1:%d" % P1], "token": TOKEN,
               "listen": False, "roster_interval": 1, "networks": []}, fh)
env = dict(os.environ, HOME=os.path.join(root, "home"), CLAUDE_CONFIG_DIR=cfg,
           CREDO_PEER_LAN_CONFIG=os.path.join(cfg, "credo", "peer-lan.json"), CREDO_PEER_LAN_SOCKDIR=os.path.join(root, "sock"))
for k in ("CREDO_SESSION_MODES_DIR", "CREDO_SESSION_ROLES_DIR", "CREDO_SESSION_META_DIR"):
    env.pop(k, None)
py = subprocess.Popen([sys.executable, os.path.join(os.environ["CREDO_SCRIPTS"], "credo-peer-lan.py"), "daemon"], env=env,
                      stdout=open(os.path.join(root, "py.log"), "w"), stderr=subprocess.STDOUT)
base = [PS, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"]
recv = WFW + "\\recv.txt"; recv_l = os.path.join(WFL, "recv.txt")
fake = subprocess.Popen(base + [WFW + "\\fakewin.ps1", "-Role", "Inbox", "-Dir", WFW, "-Token", WTOK, "-Out", recv],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
renv = dict(os.environ, CREDO_WIN_SESSIONS_DIR=WFW, CREDO_WIN_STATE_DIR=WFW, CREDO_WIN_RELAY_MUTEX="credo-test-%d" % os.getpid(),
            WSLENV="CREDO_WIN_SESSIONS_DIR:CREDO_WIN_STATE_DIR:CREDO_WIN_RELAY_MUTEX")
relay = subprocess.Popen(base + [WFW + "\\credo-peer-lan-win.ps1", "-Action", "Run", "-ConfigPath", WFW + "\\relay.json"],
                         env=renv, stdout=open(os.path.join(root, "relay.out"), "w"), stderr=subprocess.STDOUT)
def wait(cond, secs=60):
    end = time.time() + secs
    while time.time() < end:
        if cond(): return True
        time.sleep(0.25)
    return False
def py_mirror():
    for p, d in wb.read_descriptors(sd):
        if d.get("credoPeerLan") and d.get("sessionId") == "win-sess-1":
            return d
def win_mirror():
    for n in os.listdir(WFL):
        if n.endswith(".json") and n[:-5].isdigit():
            try:
                d = json.load(open(os.path.join(WFL, n), encoding="utf-8-sig"))
            except Exception:
                continue
            if d.get("credoPeerLan") and d.get("sessionId") == "lin-1":
                return d
try:
    check("relay: Python relay mirrors the Windows session", wait(lambda: py_mirror() is not None))
    pm = py_mirror() or {}
    check("relay: mirror name from the Windows roster", "`laptop-1`" in pm.get("name", "") and "`acme-win`+" in pm.get("name", ""), pm.get("name"))
    check("relay: PowerShell relay mirrors the Linux session", wait(lambda: win_mirror() is not None))
    wm = win_mirror() or {}
    check("relay: Windows mirror name follows the LAN convention", "`box-a`" in wm.get("name", "") and "`bugs`+" in wm.get("name", ""), wm.get("name"))
    # Linux -> Windows: a Claude-style write into the Python mirror's proxy socket
    frame = {"type": "user", "from": "uds:" + inbox, "message": {"role": "user",
             "content": "<cross-session-message from=\"uds:%s\" from-name=\"bugs\">\nhello windows\n</cross-session-message>" % inbox}}
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(pm["messagingSocketPath"])
    s.sendall(json.dumps(frame).encode() + b"\n"); s.shutdown(socket.SHUT_WR); s.close()
    check("relay: deliver reached the Windows inbox", wait(lambda: os.path.exists(recv_l) and open(recv_l).read().strip(), 30))
    raw = base64.b64decode(open(recv_l).read().split()[0]) if os.path.exists(recv_l) else b""
    ok, rest = wb.check_auth(raw, WTOK)
    check("relay: auth line with the target's token", ok)
    o = json.loads(rest) if ok else {}
    c = o.get("message", {}).get("content", "")
    check("relay: envelope with the framing line and text", "External peer text." in c and "hello windows" in c and "from-mode" not in c, c)
    check("relay: reply address is the Windows mirror of the sender", o.get("from") == "uds:" + wm.get("messagingSocketPath", "?"), o.get("from"))
    # Windows -> Linux: a Windows sender writes into the PowerShell relay's mirror
    wpipe = None
    for n in os.listdir(WFL):
        if n.endswith(".json") and n[:-5].isdigit():
            d = json.load(open(os.path.join(WFL, n), encoding="utf-8-sig"))
            if d.get("sessionId") == "win-sess-1":
                wpipe = d["messagingSocketPath"]
    r = subprocess.run(base + [WFW + "\\fakewin.ps1", "-Role", "Send", "-Dir", WFW, "-Key", "lin-1", "-Body", "hello linux",
                               "-FromPipe", str(wpipe), "-Marker", "credoPeerLan"], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=60)
    check("relay: Windows sender wrote into the mirror", "SENT" in r.stdout, r.stdout + r.stderr)
    check("relay: deliver reached the Linux inbox", wait(lambda: any(b"hello linux" in g for g in got), 30))
    line = [g for g in got if b"hello linux" in g]
    o = json.loads(line[0]) if line else {}
    c = o.get("message", {}).get("content", "")
    check("relay: Linux envelope framed, no from-mode", "External peer text." in c and "from-mode" not in c, c)
    check("relay: reply address is the Python mirror of the Windows sender", o.get("from") == "uds:" + pm.get("messagingSocketPath", "?"), o.get("from"))
finally:
    lp = os.path.join(WFL, "peer-lan-win.log")
    if os.environ.get("VERBOSE") and os.path.exists(lp):
        print(open(lp, encoding="utf-8", errors="replace").read()[-3000:])
        print(open(os.path.join(root, "relay.out"), errors="replace").read()[-2000:])
    open(os.path.join(WFL, "peer-lan-win.stop"), "w").close()
    try:
        relay.wait(30)
    except Exception:
        relay.kill()
    open(recv_l + ".stop", "w").close()
    try:
        fake.wait(20)
    except Exception:
        fake.kill()
    py.terminate()
    try:
        py.wait(15)
    except Exception:
        py.kill()
left = [n for n in os.listdir(WFL) if n.endswith(".json") and n[:-5].isdigit()
        and json.load(open(os.path.join(WFL, n), encoding="utf-8-sig")).get("credoPeerLan")]
check("relay: PowerShell relay stopped", relay.poll() is not None)
check("relay: no Windows mirror files left", not left, left)
check("relay: no key file of a mirror left", len([n for n in os.listdir(WFL) if n.endswith(".key")]) <= 1, os.listdir(WFL))
PY
    T_PS="$PS" T_WINFIX_W="$WINFIX2_W" T_WINFIX="$WINFIX2" run_py "native windows relay" "$TMP/t4.py"
fi

echo "credo-win-bridge: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
