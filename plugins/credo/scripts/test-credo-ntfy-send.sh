#!/usr/bin/env bash
# Tests for scripts/credo-ntfy-send.sh and scripts/credo_ntfy_relay.py: relay URL
# validation, relay vs direct choice, the relay contract (JSON fields, no topic),
# no direct fallback while a relay is set, no redirects, no proxies, fail-loud exit codes, the read-only probe and the relay path of the
# self-* helpers (credo_pane_wake.ntfy).
#
# NOTHING real is sent: every config layer is a temp file, and both the "relay" and
# the "ntfy server" are fake HTTP servers on 127.0.0.1 started by this test.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/credo-ntfy-send.sh"
RELAY_PY="$HERE/credo_ntfy_relay.py"
PY="$(command -v python3)"

pass=0
fail=0
TMP="$(mktemp -d)"
PIDS=""
cleanup() {
    for p in $PIDS; do kill "$p" 2>/dev/null; done
    rm -rf -- "$TMP"
}
trap cleanup EXIT

export CREDO_GLOBAL="$TMP/global-config"
export CREDO_PROFILE="$TMP/profile-config"   # absent
export CREDO_PROJECT="$TMP/project-config"   # absent
export CREDO_SKIP_ENSURE=1
export CREDO_CONFIG_STDLIB_YAML=1
unset CREDO_NTFY_TITLE CREDO_NTFY_PRIORITY CREDO_NTFY_TAGS

check() { # name, want, got
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $1 (want $2, got $3)"
    fi
}
has() { # name, needle, haystack
    case "$3" in *"$2"*) pass=$((pass + 1)) ;; *) fail=$((fail + 1)); echo "FAIL: $1 (missing '$2' in: $3)" ;; esac
}
lacks() { # name, needle, haystack
    case "$3" in *"$2"*) fail=$((fail + 1)); echo "FAIL: $1 (unexpected '$2' in: $3)" ;; *) pass=$((pass + 1)) ;; esac
}

# --- fake HTTP server: records each POST (path, headers, body) as one JSON line ---
cat > "$TMP/fake_server.py" <<'PYEOF'
import http.server, json, sys
out, portfile, code = sys.argv[1], sys.argv[2], int(sys.argv[3])
location = sys.argv[4] if len(sys.argv) > 4 else ""
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode("utf-8")
        with open(out, "a") as fh:
            fh.write(json.dumps({"path": self.path, "ctype": self.headers.get("Content-Type"),
                                 "title": self.headers.get("Title"),
                                 "priority": self.headers.get("Priority"),
                                 "tags": self.headers.get("Tags"), "body": body}) + "\n")
        self.send_response(code)
        if location:
            self.send_header("Location", location)
        self.end_headers(); self.wfile.write(b"ok")
    do_GET = do_POST  # a followed redirect may arrive as GET, so record it too
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
start_server() { # name, http code [, Location] -> sets <name>_PORT, records to $TMP/<name>.jsonl
    : > "$TMP/$1.jsonl"
    "$PY" "$TMP/fake_server.py" "$TMP/$1.jsonl" "$TMP/$1.port" "$2" "${3:-}" &
    PIDS="$PIDS $!"
    for _ in $(seq 1 50); do [ -s "$TMP/$1.port" ] && break; sleep 0.1; done
    eval "$1_PORT=$(cat "$TMP/$1.port")"
}
start_server relay 200
start_server relaybad 500
start_server ntfysrv 200
start_server proxy 200
start_server redirector 302 "http://127.0.0.1:$ntfysrv_PORT/redirected"
# a free port with no listener
DEAD_PORT="$("$PY" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
RELAY_URL="http://127.0.0.1:$relay_PORT/send"
TOPIC="acme-topic-x1"

config() { # relay, topic, server
    {
        echo "personal:"
        echo "  ntfy_relay: \"$1\""
        echo "  ntfy_topic: \"$2\""
        echo "  ntfy_server: \"$3\""
    } > "$CREDO_GLOBAL"
}
lines() { wc -l < "$TMP/$1.jsonl" | tr -d ' '; }
field() { # file, line no, key
    "$PY" -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[int(sys.argv[2])-1])[sys.argv[3]])' "$TMP/$1.jsonl" "$2" "$3"
}

# --- URL validation --------------------------------------------------------------
for u in "http://127.0.0.1:8765/send" "http://localhost:8765/send" "http://[::1]:8765/send" \
         "http://127.0.0.1/send" "http://localhost:1"; do
    "$PY" "$RELAY_PY" validate "$u" 2>/dev/null; check "valid: $u" 0 "$?"
done
for u in "https://127.0.0.1:8765/send" "http://example.com/send" "http://127.0.0.2/send" \
         "http://user@127.0.0.1/send" "http://127.0.0.1@example.com/send" "http://::1/send" \
         "http://127.0.0.1:8765/send?x=1" "http://127.0.0.1:8765/send#a" "ftp://127.0.0.1/send" \
         "http://127.0.0.1:99999/send" "http://127.0.0.1.example.com/send" "127.0.0.1:8765" \
         "http://localhost.:80/" " http://127.0.0.1/send" ""; do
    "$PY" "$RELAY_PY" validate "$u" 2>/dev/null; check "invalid: '$u'" 2 "$?"
done

# --- not configured -> silent no-op ------------------------------------------------
config "" "" ""
out="$("$SUT" "hello" 2>&1)"; rc=$?
check "not configured: rc 0" 0 "$rc"
check "not configured: no output" "" "$out"

# --- usage ----------------------------------------------------------------------------
"$SUT" >/dev/null 2>&1; check "no message: rc 1" 1 "$?"

# --- relay only: JSON contract, no topic --------------------------------------------
config "$RELAY_URL" "" ""
out="$("$SUT" -t "Build done" -p high --tags "warning,ci" "Grüße: #7 fertig" 2>&1)"; rc=$?
check "relay: rc 0" 0 "$rc"
check "relay: no output" "" "$out"
check "relay: one request" 1 "$(lines relay)"
check "relay: path" "/send" "$(field relay 1 path)"
has "relay: JSON content type" "application/json" "$(field relay 1 ctype)"
body="$(field relay 1 body)"
check "relay: payload fields" "Build done|Grüße: #7 fertig|high|warning,ci|title,body,priority,tags" \
    "$("$PY" -c 'import json,sys; d=json.loads(sys.argv[1]); print("|".join([d["title"],d["body"],d["priority"],d["tags"],",".join(d)]))' "$body")"
# defaults: title "credo", priority "default", tags empty; env vars feed the fields
"$SUT" "plain" 2>/dev/null
check "relay defaults" "credo|default|" \
    "$("$PY" -c 'import json,sys; d=json.loads(sys.argv[1]); print("|".join([d["title"],d["priority"],d["tags"]]))' "$(field relay 2 body)")"
CREDO_NTFY_PRIORITY=max CREDO_NTFY_TITLE="T env" "$SUT" "env" 2>/dev/null
check "relay env vars" "T env|max" \
    "$("$PY" -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["title"]+"|"+d["priority"])' "$(field relay 3 body)")"
long="$(printf 'x%.0s' $(seq 1 80))"
"$SUT" -t "$long" "long title" 2>/dev/null
check "relay title cut to 50" 50 "$("$PY" -c 'import json,sys; print(len(json.loads(sys.argv[1])["title"]))' "$(field relay 4 body)")"

# relay set AND topic set: the relay wins, the topic never reaches it, no direct send
config "$RELAY_URL" "$TOPIC" "http://127.0.0.1:$ntfysrv_PORT"
: > "$TMP/relay.jsonl"
"$SUT" "both" 2>/dev/null; check "relay+topic: rc 0" 0 "$?"
check "relay+topic: relay used" 1 "$(lines relay)"
check "relay+topic: no direct send" 0 "$(lines ntfysrv)"
lacks "relay+topic: topic not sent to relay" "$TOPIC" "$(cat "$TMP/relay.jsonl")"

# invalid priority / tags for the relay -> exit 2, nothing sent
config "$RELAY_URL" "" ""
: > "$TMP/relay.jsonl"
out="$("$SUT" -p urgent "x" 2>&1)"; rc=$?
check "bad priority: rc 2" 2 "$rc"
has "bad priority: reason" "invalid priority" "$out"
out="$("$SUT" --tags "a b" "x" 2>&1)"; rc=$?
check "bad tags: rc 2" 2 "$rc"
check "bad input: nothing sent" 0 "$(lines relay)"

# --- relay failures: fail loud ----------------------------------------------------
config "http://127.0.0.1:$DEAD_PORT/send" "" ""
out="$("$SUT" "x" 2>&1)"; rc=$?
check "relay down, no topic: rc 3" 3 "$rc"
has "relay down: reason" "relay not reachable" "$out"
has "relay down: says not sent" "NOT sent" "$out"

config "http://127.0.0.1:$relaybad_PORT/send" "" ""
out="$("$SUT" "x" 2>&1)"; rc=$?
check "relay HTTP 500: rc 3" 3 "$rc"
has "relay HTTP 500: reason" "HTTP 500" "$out"

config "http://example.com/send" "" ""
out="$("$SUT" "x" 2>&1)"; rc=$?
check "remote relay URL, no topic: rc 2" 2 "$rc"
has "remote relay URL: reason" "relay host must be" "$out"

# --- relay fails, topic set -> NO direct fallback, fail loud -------------------------
config "http://127.0.0.1:$DEAD_PORT/send" "$TOPIC" "http://127.0.0.1:$ntfysrv_PORT"
: > "$TMP/ntfysrv.jsonl"
out="$("$SUT" -t "NoFallback" "relay only" 2>&1)"; rc=$?
check "relay down + topic: rc 3" 3 "$rc"
has "relay down + topic: says no fallback" "no direct fallback" "$out"
check "relay down + topic: no direct request" 0 "$(lines ntfysrv)"
lacks "relay down + topic: topic never printed" "$TOPIC" "$out"
config "http://example.com/send" "$TOPIC" "http://127.0.0.1:$ntfysrv_PORT"
"$SUT" "x" >/dev/null 2>&1; rc=$?
check "invalid relay + topic: rc 2" 2 "$rc"
check "invalid relay + topic: no direct request" 0 "$(lines ntfysrv)"

# --- a relay redirect is never followed --------------------------------------------------
config "http://127.0.0.1:$redirector_PORT/send" "" ""
: > "$TMP/ntfysrv.jsonl"
out="$("$SUT" "x" 2>&1)"; rc=$?
check "redirect: rc 3" 3 "$rc"
has "redirect: reason" "HTTP 302" "$out"
check "redirect: target never contacted" 0 "$(lines ntfysrv)"

# --- proxy variables are ignored for the relay -------------------------------------
config "$RELAY_URL" "" ""
: > "$TMP/relay.jsonl"; : > "$TMP/proxy.jsonl"
PX="http://127.0.0.1:$proxy_PORT"
http_proxy="$PX" HTTP_PROXY="$PX" all_proxy="$PX" ALL_PROXY="$PX" no_proxy="" NO_PROXY="" \
    "$SUT" "via relay, not proxy" 2>/dev/null; rc=$?
check "proxy env: rc 0" 0 "$rc"
check "proxy env: relay got it" 1 "$(lines relay)"
check "proxy env: proxy got nothing" 0 "$(lines proxy)"

# --- tags with a trailing newline are rejected (fullmatch) ---------------------------
"$SUT" --tags "ci
" "x" >/dev/null 2>&1; check "tags trailing newline: rc 2" 2 "$?"
check "tags newline: python check" "False" \
    "$("$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); import credo_ntfy_relay as r; print(r.build_payload("t", "b", None, "ci\n")[0] is not None)' "$HERE")"

# --- direct only (no relay): unchanged behaviour, headers --------------------------
config "" "$TOPIC" "http://127.0.0.1:$ntfysrv_PORT/"
: > "$TMP/ntfysrv.jsonl"
"$SUT" -t "Direct" -p high --tags ci "direct msg" 2>/dev/null; check "direct: rc 0" 0 "$?"
check "direct: headers" "Direct|high|ci|/$TOPIC" \
    "$(field ntfysrv 1 title)|$(field ntfysrv 1 priority)|$(field ntfysrv 1 tags)|$(field ntfysrv 1 path)"

# direct server down -> rc 3, topic not printed
config "" "$TOPIC" "http://127.0.0.1:$DEAD_PORT"
out="$("$SUT" "x" 2>&1)"; rc=$?
check "direct down: rc 3" 3 "$rc"
has "direct down: reason" "curl exit" "$out"
lacks "direct down: topic never printed" "$TOPIC" "$out"

# curl missing on the direct path -> rc 3 (PATH without curl, python3 still reachable)
NOCURL="$TMP/nocurl"; mkdir -p "$NOCURL"
for t in bash python3 dirname cat env tr sed grep head awk; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOCURL/$t"
done
config "" "$TOPIC" "http://127.0.0.1:$ntfysrv_PORT"
out="$(PATH="$NOCURL" "$SUT" "x" 2>&1)"; rc=$?
check "no curl: rc 3" 3 "$rc"
has "no curl: reason" "curl is missing" "$out"

# --- probe (read-only: TCP connect, nothing sent) ---------------------------------
: > "$TMP/relay.jsonl"
out="$("$PY" "$RELAY_PY" probe "$RELAY_URL" 2>&1)"; rc=$?
check "probe listening: rc 0" 0 "$rc"
has "probe listening: output" "listening" "$out"
check "probe sends nothing" 0 "$(lines relay)"
"$PY" "$RELAY_PY" probe "http://127.0.0.1:$DEAD_PORT/send" 2>/dev/null; check "probe no listener: rc 1" 1 "$?"
"$PY" "$RELAY_PY" probe "http://example.com/send" 2>/dev/null; check "probe remote URL: rc 2" 2 "$?"

# --- self-* helpers: credo_pane_wake.ntfy uses the relay first ----------------------
: > "$TMP/relay.jsonl"; : > "$TMP/ntfysrv.jsonl"
res="$(cd "$TMP" && PYTHONPATH="$HERE" "$PY" - "$RELAY_URL" "$TOPIC" "http://127.0.0.1:$ntfysrv_PORT" \
       "http://127.0.0.1:$DEAD_PORT/send" <<'PYEOF'
import sys, credo_pane_wake as w
relay, topic, server, dead = sys.argv[1:5]
logs = []
def cfg(values):
    return lambda key: values.get(key, "")
r1 = w.ntfy("T1", "b1", "CREDO_TEST_NTFY_URL_UNSET",
            cfg({"personal.ntfy_relay": relay, "personal.ntfy_topic": topic,
                 "personal.ntfy_server": server}), logs.append)
r2 = w.ntfy("T2", "b2", "CREDO_TEST_NTFY_URL_UNSET",
            cfg({"personal.ntfy_topic": topic, "personal.ntfy_server": server}), logs.append)
r4 = w.ntfy("T4", "b4", "CREDO_TEST_NTFY_URL_UNSET",
            cfg({"personal.ntfy_relay": dead, "personal.ntfy_topic": topic,
                 "personal.ntfy_server": server}), logs.append)
# a missing relay module must not crash the push
import builtins
real_import = builtins.__import__
def no_relay(name, *a, **k):
    if name == "credo_ntfy_relay":
        raise ImportError(name)
    return real_import(name, *a, **k)
sys.modules.pop("credo_ntfy_relay", None)
builtins.__import__ = no_relay
try:
    r5 = w.ntfy("T5", "b5", "CREDO_TEST_NTFY_URL_UNSET",
                cfg({"personal.ntfy_relay": relay, "personal.ntfy_topic": topic,
                     "personal.ntfy_server": server}), logs.append)
except Exception as exc:
    r5 = "crash:" + type(exc).__name__
builtins.__import__ = real_import
r3 = w.ntfy("T3", "b3", "CREDO_TEST_NTFY_URL_UNSET",
            cfg({"personal.ntfy_relay": dead}), logs.append)
print("%s %s %s %s %s" % (r1, r2, r3, r4, r5))
print(" || ".join(logs))
PYEOF
)"
check "pane_wake: results relay/direct/fail/no-fallback/no-module" "True True False False False" \
    "$(printf '%s\n' "$res" | head -1)"
has "pane_wake: missing module logged" "relay helper unavailable (ImportError)" "$res"
has "pane_wake: relay log" "ntfy sent via relay: T1" "$res"
has "pane_wake: relay failure logged" "ntfy relay failed (no direct fallback): relay not reachable" "$res"
lacks "pane_wake: topic never logged" "$TOPIC" "$res"
check "pane_wake: relay got T1 only" 1 "$(lines relay)"
check "pane_wake: relay priority high" "high" \
    "$("$PY" -c 'import json,sys; print(json.loads(sys.argv[1])["priority"])' "$(field relay 1 body)")"
check "pane_wake: direct got T2 only (no fallback for T4/T5)" "T2|1" "$(field ntfysrv 1 title)|$(lines ntfysrv)"

echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]
