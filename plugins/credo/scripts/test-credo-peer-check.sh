#!/bin/bash
# Tests for credo-peer-check.py - the read-only multi-channel peer check.
#
# Everything runs against a throwaway HOME, fake socket dirs, a fake CODEX_HOME,
# a fake LAN relay config and a fake tmux binary in a temp tree. No real session
# is touched, no message is sent, nothing is installed, no daemon is started.
#
# Covered:
#   - Claude peers from the profile registry are listed as kind claude, reachable
#     via SendMessage; dead descriptors are not listed
#   - live sockets in BOTH candidate socket dirs -> split-world warning with the
#     XDG_RUNTIME_DIR fix; one dir only -> no warning
#   - a live socket without any registry descriptor -> listed, NOT SendMessage
#   - credoPeerLan mirrors: a Codex mirror is kind codex via SendMessage, another
#     mirror is kind lan
#   - Codex relay state: sessions listed as kind codex; node dead -> a2a not
#     available, warning that the Codex relay is down; node alive -> a2a
#   - LAN relay config with a loopback peer whose port is not listening -> warning
#   - tmux sessions: a Codex pane is kind codex reachable via tmux, a pane without
#     a known session is tmux-only, a pane running a registered Claude session is
#     merged into that Claude row (no tmux-only duplicate)
#   - --json output parses and carries kind / reachable_by / last_seen per row
#   - per-peer metadata (mode / role / model / effort / credo / project / status):
#     read from the local credo state for local peers and from the validated relay
#     field of a LAN mirror; invalid values and unknown keys are never shown; the
#     sender subcommand resolves a socket address to that metadata
#   - hint mode: own socket dir differs from where most peers live -> one hint
#     line; same dir or no data -> silent
#   - the SessionStart hook wrapper emits additionalContext only on a split
#   - the script never writes into the fake profile / socket dirs (read-only)
#
# Usage: bash test-credo-peer-check.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/credo-peer-check.py"
HOOK="$SCRIPT_DIR/../hooks/credo-peer-split-hint.sh"
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "SKIP: python3 not found"; exit 0; fi
if [ ! -f "$CHECK" ]; then echo "FAIL: $CHECK missing"; exit 1; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cpc.XXXXXX")"
PIDS=""
cleanup() {
    for p in $PIDS; do kill -KILL "$p" 2>/dev/null || true; done
    for p in $PIDS; do wait "$p" 2>/dev/null || true; done
    rm -rf -- "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() { # name cond(0=pass)
    if [ "$2" = "0" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; fi
}
has() { # haystack needle -> 0 when found
    case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac
}

HOME_DIR="$TMP/home"
CFG="$HOME_DIR/.claude"
SOCK_RUN="$TMP/run/cc-socks"
SOCK_TMP="$TMP/tmp/cc-socks"
CODEX="$TMP/codex"
mkdir -p "$CFG/sessions" "$CFG/credo" "$SOCK_RUN" "$SOCK_TMP" "$CODEX/credo/peer-lan/sessions" "$TMP/bin"

# live processes standing in for sessions
sleep 600 & P_A=$!; PIDS="$PIDS $P_A"      # claude A, socket in run dir
sleep 600 & P_B=$!; PIDS="$PIDS $P_B"      # claude B, socket in tmp dir
sleep 600 & P_C=$!; PIDS="$PIDS $P_C"      # claude C, socket in tmp dir
sleep 600 & P_ORPHAN=$!; PIDS="$PIDS $P_ORPHAN"  # socket, no descriptor
sleep 600 & P_MIRROR=$!; PIDS="$PIDS $P_MIRROR"  # LAN holder for a Codex session
sleep 600 & P_LAN=$!; PIDS="$PIDS $P_LAN"        # LAN holder for a remote Claude
# pids guaranteed dead: spawned and reaped children
dead_pid() { sleep 0 & local p=$!; wait "$p" 2>/dev/null; echo "$p"; }
DEAD_PID="$(dead_pid)"
DEAD_PID2="$(dead_pid)"

mksock() { # path
    "$PY" -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$1"
}
desc() { # file pid sid name sockpath [extra-json]
    "$PY" - "$@" <<'PYEOF'
import json, sys
path, pid, sid, name, sock = sys.argv[1:6]
extra = json.loads(sys.argv[6]) if len(sys.argv) > 6 else {}
d = {"pid": int(pid), "sessionId": sid, "name": name, "messagingSocketPath": sock,
     "status": "idle", "updatedAt": 1700000000000, "kind": "interactive"}
d.update(extra)
json.dump(d, open(path, "w"))
PYEOF
}

# live sockets stay bound by one holder process (listed in /proc/net/unix); a socket
# made by mksock is left behind unbound, like the socket of a crashed session
"$PY" - "$SOCK_RUN/$P_A.sock" "$SOCK_TMP/$P_B.sock" "$SOCK_TMP/$P_C.sock" "$SOCK_TMP/$P_ORPHAN.sock" <<'PYEOF' &
import os, socket, sys, time
keep = []
for path in sys.argv[1:]:
    s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(1); keep.append(s)
time.sleep(600)
PYEOF
HOLDER=$!; PIDS="$PIDS $HOLDER"
for _ in $(seq 1 50); do [ -S "$SOCK_TMP/$P_ORPHAN.sock" ] && break; sleep 0.1; done
mksock "$SOCK_TMP/$DEAD_PID.sock"
desc "$CFG/sessions/$P_A.json" "$P_A" sid-a alpha-session "$SOCK_RUN/$P_A.sock" \
    '{"cwd": "/home/myuser/work/proj-alpha", "status": "busy"}'
desc "$CFG/sessions/$P_B.json" "$P_B" sid-b bravo-session "$SOCK_TMP/$P_B.sock"
desc "$CFG/sessions/$P_C.json" "$P_C" sid-c charlie-session "$SOCK_TMP/$P_C.sock"
desc "$CFG/sessions/$DEAD_PID.json" "$DEAD_PID" sid-dead dead-session "$SOCK_TMP/$DEAD_PID.sock"
desc "$CFG/sessions/$P_MIRROR.json" "$P_MIRROR" sid-codex-1 '`Codex`--`Home`--`box-1`--`alice`--`.codex`--`work-codex`+0-1' \
    "$CFG/credo/peer-lan-sock/pl-aaa.sock" '{"credoPeerLan": true, "credoPeerLanFrom": "box-1"}'
desc "$CFG/sessions/$P_LAN.json" "$P_LAN" sid-remote '`Claude Code`--`Home`--`box-2`--`alice`--`.claude`--`remote work`+r-2' \
    "$CFG/credo/peer-lan-sock/pl-bbb.sock" '{"credoPeerLan": true, "credoPeerLanFrom": "box-2", "credoPeerMeta": {"mode": "passive", "role": "plan", "model": "claude-test-1", "effort": "max", "bogus": "x", "project": "../etc", "credo": "maybe"}}'

# per-session metadata (mode / role / model / effort / credo) of the local peers;
# bravo carries invalid values that must never be shown
mkdir -p "$CFG/credo/session-modes" "$CFG/credo/session-roles" "$CFG/credo/session-meta"
printf 'autonomous\n' > "$CFG/credo/session-modes/sid-a"
printf 'task\n' > "$CFG/credo/session-roles/sid-a"
printf '{"model": "claude-test-5[1m]", "effort": "high", "credo": "on"}\n' > "$CFG/credo/session-meta/sid-a.json"
printf 'rm -rf /\n' > "$CFG/credo/session-modes/sid-b"
printf 'plan\n' > "$CFG/credo/session-roles/sid-b"
printf '{"model": "evil model<x>", "effort": "ultra", "credo": "yes"}\n' > "$CFG/credo/session-meta/sid-b.json"

# Codex relay state: config, a dead node, two sessions
"$PY" - "$CODEX/credo/peer-lan" "$DEAD_PID" <<'PYEOF'
import json, os, sys
root, dead = sys.argv[1], int(sys.argv[2])
json.dump({"listen_host": "127.0.0.1", "listen_port": 1, "peers": ["127.0.0.1:2"]},
          open(os.path.join(root, "config.json"), "w"))
json.dump({"pid": dead, "procStart": "1", "socket": "/nonexistent/control.sock"},
          open(os.path.join(root, "node.json"), "w"))
for sid, name, active in (("sid-codex-1", "Codex task", True), ("sid-codex-2", "Codex idle", False)):
    json.dump({"sessionId": sid, "name": name, "active": active, "status": "idle",
               "lastSeen": 1700000000}, open(os.path.join(root, "sessions", sid + ".json"), "w"))
open(os.path.join(root, "peer-lan.log"), "w").write("codex-peer: started\ncodex-peer: [Errno 2] No such file or directory: '/run/user/4242'\n")
PYEOF

# LAN relay config: one loopback peer on a port nobody listens on
"$PY" - "$CFG/credo/peer-lan.json" <<'PYEOF'
import json, socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); free = s.getsockname()[1]; s.close()
json.dump({"peers": ["192.0.2.10", "127.0.0.1:%d" % free], "listen_port": 1}, open(sys.argv[1], "w"))
PYEOF

# a fake "codex" process (argv0 codex) for the work-codex pane, a plain shell for spare-shell
cp "$(command -v sleep)" "$TMP/bin/codex"
"$TMP/bin/codex" 600 & P_ORPHAN_TMUX=$!; PIDS="$PIDS $P_ORPHAN_TMUX"
"$TMP/bin/codex" 600 & P_LONE=$!; PIDS="$PIDS $P_LONE"
sleep 600 & P_SHELL=$!; PIDS="$PIDS $P_SHELL"
# fake tmux: session list + pane pids
cat > "$TMP/bin/tmux" <<EOF
#!/bin/bash
case "\$*" in
  *list-panes*) printf '%s\t%s\n' work-codex $P_ORPHAN_TMUX lone-codex $P_LONE work-alpha $P_A spare-shell $P_SHELL ;;
  *list-sessions*) printf '%s\t%s\n' work-codex 1700000100 lone-codex 1700000150 work-alpha 1700000200 spare-shell 1700000300 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/tmux"

# fake credo-peer-lan.py: status = not running, check = LAN disabled with a reason
cat > "$TMP/bin/fake-lan.py" <<'PYEOF'
import sys
if sys.argv[1] == "status":
    print("relay not running"); sys.exit(1)
if sys.argv[1] == "check":
    print("LAN relay: DISABLED - network detection failed (unknown network)")
PYEOF

snapshot() { find "$CFG" "$SOCK_RUN" "$SOCK_TMP" "$CODEX" ! -type d -printf '%p %s %T@\n' 2>/dev/null | sort; }
BEFORE="$(snapshot)"

run_check() { # args...
    env -u XDG_RUNTIME_DIR HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$CFG" CODEX_HOME="$CODEX" \
        CREDO_PEER_LAN_CONFIG="$CFG/credo/peer-lan.json" \
        CREDO_PEER_CHECK_SOCK_DIRS="$SOCK_RUN:$SOCK_TMP" \
        CREDO_PEER_CHECK_TMUX="$TMP/bin/tmux" \
        CREDO_PEER_CHECK_LAN_SCRIPT="$TMP/bin/fake-lan.py" CREDO_PEER_CHECK_CODEX_PEER="" \
        "$PY" "$CHECK" "$@"
}

OUT="$(run_check 2>&1)"; RC=$?
ok "list exits 0" "$RC"
has "$OUT" "alpha-session"; ok "claude A listed" "$?"
has "$OUT" "bravo-session"; ok "claude B listed" "$?"
has "$OUT" "dead-session"; R=$?; [ "$R" -ne 0 ]; ok "dead descriptor not listed" "$?"
has "$OUT" "split"; ok "split-world warning present" "$?"
has "$OUT" "XDG_RUNTIME_DIR"; ok "split warning names XDG_RUNTIME_DIR fix" "$?"
has "$OUT" "not running"; ok "Codex relay down is reported" "$?"
has "$OUT" "/run/user/4242"; ok "Codex relay last log line is shown" "$?"
has "$OUT" "not listening"; ok "loopback LAN peer not listening is reported" "$?"
has "$OUT" "relay LAN disabled: LAN relay: DISABLED - network detection failed"; ok "LAN disabled reason shown prominently" "$?"
has "$OUT" "daemon is not running"; ok "LAN relay daemon down is reported" "$?"
has "$OUT" "absent from ListAgents"; ok "output says absent from ListAgents is not down" "$?"

J="$(run_check --json 2>/dev/null)"
"$PY" - "$J" "$P_ORPHAN" <<'PYEOF'
import json, sys
data = json.loads(sys.argv[1]); orphan = int(sys.argv[2])
rows = data["peers"]
def find(**kw):
    return [r for r in rows if all(r.get(k) == v for k, v in kw.items())]
errs = []
for r in rows:
    for k in ("name", "kind", "reachable_by", "last_seen"):
        if k not in r:
            errs.append("row lacks %s: %r" % (k, r))
a = find(name="alpha-session")
if not a or a[0]["kind"] != "claude" or a[0]["reachable_by"] != "SendMessage":
    errs.append("alpha row wrong: %r" % a)
if a and a[0].get("tmux") != "work-alpha":
    errs.append("alpha not merged with its tmux session: %r" % a)
if find(name="work-alpha"):
    errs.append("tmux duplicate row for a registered Claude session")
o = [r for r in rows if r.get("pid") == orphan]
if not o or o[0]["kind"] != "claude" or o[0]["reachable_by"] == "SendMessage":
    errs.append("orphan socket row wrong: %r" % o)
m = find(session_id="sid-codex-1")
if not m or any(r["kind"] != "codex" for r in m) or not any(r["reachable_by"] == "SendMessage" for r in m):
    errs.append("codex mirror row wrong: %r" % m)
c2 = find(session_id="sid-codex-2")
if not c2 or c2[0]["kind"] != "codex" or c2[0]["reachable_by"] == "a2a":
    errs.append("codex-2 should not be a2a while the node is dead: %r" % c2)
l = find(session_id="sid-remote")
if not l or l[0]["kind"] != "lan":
    errs.append("lan mirror row wrong: %r" % l)
t = find(name="lone-codex")
if not t or t[0]["kind"] != "codex" or t[0]["reachable_by"] != "tmux only":
    errs.append("tmux codex row wrong: %r" % t)
if find(name="work-codex") or not (m and m[0].get("tmux") == "work-codex"):
    errs.append("codex mirror not merged with its tmux session: %r" % m)
s = find(name="spare-shell")
if not s or s[0]["kind"] != "tmux-only":
    errs.append("tmux-only row wrong: %r" % s)
if not data.get("split_world"):
    errs.append("split_world flag missing")
if errs:
    print("\n".join(errs)); sys.exit(1)
PYEOF
ok "json rows carry kind / reachable_by / last_seen and classify correctly" "$?"

# --- per-peer metadata: mode / role / model / effort / credo / project / status ----
has "$OUT" "mode=autonomous role=task model=claude-test-5[1m] effort=high credo=on project=proj-alpha status=busy"
ok "text row shows the metadata of a local peer" "$?"
has "$OUT" "mode=passive role=plan model=claude-test-1 effort=max credo=- project=-"
ok "text row shows the validated relay metadata of a LAN mirror" "$?"
"$PY" - "$J" <<'PYEOF'
import json, sys
rows = json.loads(sys.argv[1])["peers"]
def one(**kw):
    r = [x for x in rows if all(x.get(k) == v for k, v in kw.items())]
    return r[0] if r else None
errs = []
for r in rows:
    if not isinstance(r.get("meta"), dict):
        errs.append("row lacks a meta dict: %r" % r)
a = one(session_id="sid-a")
if not a or a["meta"] != {"mode": "autonomous", "role": "task", "model": "claude-test-5[1m]",
                          "effort": "high", "credo": "on", "project": "proj-alpha", "status": "busy"}:
    errs.append("alpha meta wrong: %r" % (a and a.get("meta")))
b = one(session_id="sid-b")
if not b or b["meta"].get("role") != "plan" or any(k in b["meta"] for k in ("mode", "model", "effort", "credo")):
    errs.append("bravo meta must keep only the valid role: %r" % (b and b.get("meta")))
l = one(session_id="sid-remote")
if not l or l["meta"] != {"mode": "passive", "role": "plan", "model": "claude-test-1", "effort": "max",
                          "status": "idle"}:
    errs.append("lan mirror meta wrong (enum whitelist, no free text): %r" % (l and l.get("meta")))
c = one(session_id="sid-codex-2")
if not c or any(k in c["meta"] for k in ("mode", "role")):
    errs.append("codex relay session must carry no mode/role: %r" % (c and c.get("meta")))
if errs:
    print("\n".join(errs)); sys.exit(1)
PYEOF
ok "json rows carry a validated meta dict per peer" "$?"

# sender lookup (used by the peer-message hook): socket -> peer metadata
S="$(run_check sender --from "uds:$SOCK_RUN/$P_A.sock" 2>&1)"
[ "$S" = "mode=autonomous role=task model=claude-test-5[1m] effort=high credo=on project=proj-alpha status=busy" ]
ok "sender prints the metadata of a local peer by its socket (got: $S)" "$?"
S="$(run_check sender --from "uds:$CFG/credo/peer-lan-sock/pl-bbb.sock" 2>&1)"
has "$S" "mode=passive role=plan"; ok "sender resolves a LAN mirror proxy socket" "$?"
S="$(run_check sender --from "uds:$SOCK_TMP/nobody.sock" 2>&1)"
[ -z "$S" ]; ok "sender silent for an unknown socket" "$?"
S="$(run_check sender --from 'mode=autonomous' 2>&1)"
[ -z "$S" ]; ok "sender silent for a malformed address" "$?"
S="$(run_check sender --from "uds:$SOCK_TMP/$DEAD_PID.sock" 2>&1)"
[ -z "$S" ]; ok "sender silent for a dead descriptor" "$?"

# unit: the metadata reader rejects path tricks and keeps only whitelisted values
"$PY" - "$SCRIPT_DIR" "$CFG" <<'PYEOF'
import os, sys
sys.path.insert(0, sys.argv[1])
import credo_peer_meta as m
cfg = sys.argv[2]
errs = []
for bad in ("../sid-a", "..", ".", "a/b", "", None, 5, "x" * 300):
    if m.local_meta(bad, [cfg]):
        errs.append("bad sid %r returned meta" % (bad,))
if m.local_meta("sid-a", [cfg]).get("mode") != "autonomous":
    errs.append("sid-a mode not read")
cl = m.clean({"mode": "autonomous ", "role": "TASK", "model": "a" * 65, "effort": "low",
              "credo": "off", "project": "my proj", "status": "busy", "x": "y"})
if cl != {"effort": "low", "credo": "off", "status": "busy"}:
    errs.append("clean wrong: %r" % cl)
if m.clean({"model": "x[urgent]", "status": "hacked"}) != {} or m.clean({"model": "a[1m]x"}) != {}:
    errs.append("marker-like model brackets or an unknown status must be dropped")
if m.clean({"model": "claude-test-5[1m]", "status": "waiting"}) != {"model": "claude-test-5[1m]", "status": "waiting"}:
    errs.append("context suffix and known status must be kept")
if m.clean("not a dict") != {} or m.clean({"mode": ["autonomous"]}) != {}:
    errs.append("clean must tolerate garbage")
if m.fmt({}) != "mode=- role=- model=- effort=- credo=- project=- status=-":
    errs.append("fmt empty wrong: %r" % m.fmt({}))
if errs:
    print("\n".join(errs)); sys.exit(1)
PYEOF
ok "metadata reader: path tricks rejected, enum/charset whitelist enforced" "$?"

# Codex node alive -> a2a for Codex sessions without a mirror
"$PY" - "$CODEX/credo/peer-lan/node.json" "$P_SHELL" <<'PYEOF'
import json, sys
json.dump({"pid": int(sys.argv[2])}, open(sys.argv[1], "w"))
PYEOF
J2="$(run_check --json 2>/dev/null)"
"$PY" - "$J2" <<'PYEOF'
import json, sys
rows = json.loads(sys.argv[1])["peers"]
c2 = [r for r in rows if r.get("session_id") == "sid-codex-2"]
sys.exit(0 if c2 and c2[0]["reachable_by"] == "a2a" else 1)
PYEOF
ok "codex session reachable via a2a while the Codex node is alive" "$?"
BEFORE="$(snapshot)"

# hint: own session A lives in the run dir, most live peers are in the tmp dir
H="$(run_check hint --session-id sid-a 2>&1)"
has "$H" "XDG_RUNTIME_DIR"; ok "hint fires when own socket dir is in the minority" "$?"
# a stale pre-crash descriptor of session B (same id, dead pid, the other socket dir)
desc "$CFG/sessions/$DEAD_PID2.json" "$DEAD_PID2" sid-b bravo-session "$SOCK_RUN/$DEAD_PID2.sock"
H2="$(run_check hint --session-id sid-b 2>&1)"
[ -z "$H2" ]; ok "hint silent when own dir holds the majority (stale same-id descriptor ignored)" "$?"
rm -f "$CFG/sessions/$DEAD_PID2.json"
H3="$(run_check hint --session-id sid-unknown 2>&1)"
[ -z "$H3" ]; ok "hint silent when own descriptor is unknown" "$?"

# hook wrapper
if [ -f "$HOOK" ]; then
    HJ="$(printf '{"session_id":"sid-a","source":"startup"}' | env -u XDG_RUNTIME_DIR HOME="$HOME_DIR" \
        CLAUDE_CONFIG_DIR="$CFG" CODEX_HOME="$CODEX" CREDO_PEER_CHECK_SOCK_DIRS="$SOCK_RUN:$SOCK_TMP" \
        CREDO_PEER_CHECK_TMUX="" bash "$HOOK")"
    "$PY" -c 'import json,sys; d=json.loads(sys.argv[1]); assert "XDG_RUNTIME_DIR" in d["hookSpecificOutput"]["additionalContext"]' "$HJ" 2>/dev/null
    ok "hook emits additionalContext on a split" "$?"
    HJ2="$(printf '{"session_id":"sid-b","source":"startup"}' | env -u XDG_RUNTIME_DIR HOME="$HOME_DIR" \
        CLAUDE_CONFIG_DIR="$CFG" CODEX_HOME="$CODEX" CREDO_PEER_CHECK_SOCK_DIRS="$SOCK_RUN:$SOCK_TMP" \
        CREDO_PEER_CHECK_TMUX="" bash "$HOOK")"
    [ -z "$HJ2" ]; ok "hook silent without a minority split" "$?"
    HJ3="$(printf '{"session_id":"sid-a"}' | CREDO_PEER_SPLIT_HINT=0 bash "$HOOK")"
    [ -z "$HJ3" ]; ok "hook disabled by CREDO_PEER_SPLIT_HINT=0" "$?"
    printf 'not json' | bash "$HOOK" >/dev/null 2>&1; ok "hook exits 0 on bad input" "$?"
else
    ok "hook wrapper exists" 1
fi

# one dir only -> no split warning
mv "$SOCK_RUN/$P_A.sock" "$TMP/moved.sock"
# a stale (unbound) socket file of a LIVE pid in the run dir must not count as a peer
mksock "$SOCK_RUN/$P_SHELL.sock"
OUT2="$(run_check 2>&1)"
has "$OUT2" "split"; R=$?; [ "$R" -ne 0 ]; ok "no split warning with a single live socket dir (stale socket of a live pid ignored)" "$?"
mv "$TMP/moved.sock" "$SOCK_RUN/$P_A.sock"
rm -f "$SOCK_RUN/$P_SHELL.sock"

AFTER="$(snapshot)"
[ "$BEFORE" = "$AFTER" ]; ok "read-only: fake profile, socket and codex dirs unchanged" "$?"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
