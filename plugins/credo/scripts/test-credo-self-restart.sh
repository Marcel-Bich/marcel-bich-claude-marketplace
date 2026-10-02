#!/bin/bash
# Tests for credo-self-restart.py - the session self-restart helper.
#
# NOTHING real is ever stopped or restarted. Every target is a FAKE process this
# test starts itself (a python process whose argv[0] is "claude"); tmux, wt.exe, the
# terminal emulator and the `claude` plugin CLI are FAKE binaries first on a
# restricted PATH that record their calls; every config dir is a temp dir; ntfy is
# off. `run` is only ever executed with CREDO_SELF_RESTART_TARGET_PID pointing at a
# fake target.
#
# It checks:
#   - argv rebuild: drops resume/continue/print/session-id/positional prompts, keeps
#     value flags with their values (incl. variadic), keeps
#     --dangerously-skip-permissions, never gains it, always ends with
#     --resume <id> <wake prompt>
#   - recorded permission mode restore (bypass, other modes, missing, never escalate)
#   - slug computation and transcript lookup (exact, unique glob, 0 and >1 fail)
#   - profile isolation: a transcript only under ANOTHER config dir is not found
#   - relaunch method selection + exact invocation with fake tmux / wt.exe / x11,
#     new-window guard via tmux new-session, pty guard without tmux
#   - plugin update: allowlist filtering, default allowlist, env stripping, version
#     before -> after summary and "no plugin updates"
#   - the permission-mode record hook
#   - relaunch-pty answers the resume-from-summary dialog with Escape exactly once
#   - check fails cleanly with no session id / no target / no relaunch method, walks
#     the parent chain to a fake claude, prints the peer template with the 1-minute wait
#   - end-to-end run against a fake target: stop via fake tmux C-c, fake updates,
#     relaunch via fake tmux, dialog answered with Escape, marker written
#
# Usage: bash test-credo-self-restart.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/credo-self-restart.py"
HOOK="$SCRIPT_DIR/../hooks/credo-permission-mode-record.sh"
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "SKIP: python3 not found"; exit 0; fi
if [ ! -f "$HELPER" ]; then echo "FAIL: $HELPER missing"; exit 1; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/csr.XXXXXX")"
PIDS=""
cleanup() {
    for p in $PIDS; do kill -TERM "$p" 2>/dev/null || true; done
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

# --- restricted PATH: only the tools we need, fakes added per test ----------------
BASE="$TMP/base"; mkdir -p "$BASE"
for t in python3 bash dirname cat mkdir mv cp sleep env kill find jq rm printf tr sed grep head; do
    p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$BASE/$t"
done
FT="$TMP/ftmux"; FW="$TMP/fwt"; FX="$TMP/fx"; FC="$TMP/fclaude"
mkdir -p "$FT" "$FW" "$FX" "$FC"

# fake tmux: records argv; C-c -> SIGINT the fake target; capture-pane -> pane file
cat > "$FT/tmux" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_TMUX_LOG"
if [ "$1" = "send-keys" ] && [ "${4:-}" = "C-c" ] && [ -f "${FAKE_TARGET_PIDFILE:-/nonexistent}" ]; then
    kill -INT "$(cat "$FAKE_TARGET_PIDFILE")" 2>/dev/null
fi
if [ "$1" = "capture-pane" ]; then
    [ -f "${FAKE_PANE_FILE:-/nonexistent}" ] || exit 1
    cat "$FAKE_PANE_FILE"
fi
exit 0
EOF
cat > "$FW/wt.exe" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_WT_LOG"
EOF
cat > "$FX/x-terminal-emulator" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_X_LOG"
EOF
# fake claude CLI: records argv + env facts; plugin list/update on a state file
cat > "$FC/claude" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
envbad = "CLAUDECODE" in os.environ or any(k.startswith("CLAUDE_CODE_") for k in os.environ)
rec = {"argv": a, "stripped": not envbad, "cfg": os.environ.get("CLAUDE_CONFIG_DIR"),
       }
with open(os.environ["FAKE_CLAUDE_LOG"], "a") as fh:
    fh.write(json.dumps(rec) + "\n")
state = os.environ.get("FAKE_PLUGIN_STATE")
if a[:2] == ["plugin", "list"]:
    print(open(state).read())
elif a[:2] == ["plugin", "update"]:
    d = json.load(open(state))
    bumps = json.loads(os.environ.get("FAKE_BUMPS", "{}"))
    for p in d:
        if p["id"] == a[2] and a[2] in bumps:
            p["version"] = bumps[a[2]]
    json.dump(d, open(state, "w"))
EOF
chmod +x "$FT/tmux" "$FW/wt.exe" "$FX/x-terminal-emulator" "$FC/claude"
export FAKE_TMUX_LOG="$TMP/tmux.log" FAKE_WT_LOG="$TMP/wt.log" FAKE_X_LOG="$TMP/x.log" FAKE_CLAUDE_LOG="$TMP/claude.log"
export CREDO_SELF_RESTART_NTFY_URL=off CREDO_SKIP_ENSURE=1
export CREDO_GLOBAL="$TMP/global.yaml" CREDO_PROFILE="$TMP/none-profile" CREDO_PROJECT="$TMP/none-project"
: > "$CREDO_GLOBAL"

# --- unit tests (module imported directly) -------------------------------------
cat > "$TMP/unit.py" <<'PYEOF'
import importlib.util, json, os, sys, tempfile
spec = importlib.util.spec_from_file_location("csr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
res = []
def t(name, cond):
    res.append(name if cond else "FAIL " + name)

SID = "11111111-2222-3333-4444-555555555555"
P = "PROMPT"
# argv rebuild
a = ["claude", "--dangerously-skip-permissions", "--resume", "old-name", "--model", "opus",
     "--settings", "/s.json", "--mcp-config", "a.json", "b.json", "--plugin-dir", "/pd",
     "--add-dir", "/x", "--fallback-model", "sonnet", "-c", "-p", "hello prompt",
     "--system-prompt-snapshot", "on", "--verbose"]
r = m.rebuild_argv(a, 0, SID, P)
t("rebuild keeps exe", r[0] == "claude")
t("rebuild keeps --dangerously-skip-permissions", "--dangerously-skip-permissions" in r)
t("rebuild drops old resume value", "old-name" not in r and r.count("--resume") == 1)
t("rebuild drops -c/-p", "-c" not in r and "-p" not in r)
t("rebuild drops positional prompt", "hello prompt" not in r)
t("rebuild keeps value flags", r[r.index("--model") + 1] == "opus"
  and r[r.index("--settings") + 1] == "/s.json" and r[r.index("--plugin-dir") + 1] == "/pd"
  and r[r.index("--fallback-model") + 1] == "sonnet"
  and r[r.index("--system-prompt-snapshot") + 1] == "on")
t("rebuild keeps variadic values", r[r.index("--mcp-config") + 1:r.index("--mcp-config") + 3] == ["a.json", "b.json"])
t("rebuild keeps unknown bool flag", "--verbose" in r)
t("rebuild ends with --resume id prompt", r[-3:] == ["--resume", SID, P])
r = m.rebuild_argv(["node", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js", "-r", "--model=opus", "x"], 1, SID, P)
t("rebuild node form", r == ["node", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js", "--model=opus", "--resume", SID, P])
r = m.rebuild_argv(["claude", "--session-id", "abc", "--fork-session", "--", "p1"], 0, SID, P)
t("rebuild drops --session-id/--fork-session/after --", r == ["claude", "--resume", SID, P])
r = m.rebuild_argv(["claude", "--model", "opus"], 0, SID, P)
t("no bypass in argv -> none gained", "--dangerously-skip-permissions" not in r and "bypassPermissions" not in r)
t("prompt never omitted", m.rebuild_argv(["claude"], 0, SID, "wake")[-3:] == ["--resume", SID, "wake"])
# exe identification
t("exe: native claude", m.claude_exe_end(["claude", "-r"]) == 0)
t("exe: versions path", m.claude_exe_end(["x"], "/h/.local/share/claude/versions/2.1.294") == 0)
t("exe: node script", m.claude_exe_end(["node", "/a/@anthropic-ai/claude-code/cli.js"]) == 1)
t("exe: not claude", m.claude_exe_end(["python3", "credo-self-restart.py"]) is None)
# permission mode restore
B = ["claude", "--model", "opus"]
r, n = m.rebuild_argv_note(B, 0, SID, P, "bypassPermissions")
t("mode bypass restored", r[-5:-3] == ["--permission-mode", "bypassPermissions"] and "restored" in n)
r, n = m.rebuild_argv_note(["claude", "--dangerously-skip-permissions"], 0, SID, P, "bypassPermissions")
t("mode bypass already in argv", r == ["claude", "--dangerously-skip-permissions", "--resume", SID, P])
r, n = m.rebuild_argv_note(["claude", "--permission-mode", "plan"], 0, SID, P, "bypassPermissions")
t("mode bypass replaces other --permission-mode", r[:3] == ["claude", "--permission-mode", "bypassPermissions"] and r.count("--permission-mode") == 1)
D = ["claude", "--dangerously-skip-permissions", "--model", "opus"]
r, n = m.rebuild_argv_note(D, 0, SID, P, "acceptEdits")
t("dangerously + acceptEdits -> allow-dangerously + mode", r == ["claude", "--model", "opus", "--allow-dangerously-skip-permissions", "--permission-mode", "acceptEdits", "--resume", SID, P] and "allow-dangerously" in n)
r, n = m.rebuild_argv_note(["claude", "--dangerously-skip-permissions", "--permission-mode", "plan"], 0, SID, P, "acceptEdits")
t("dangerously + existing mode replaced", r == ["claude", "--allow-dangerously-skip-permissions", "--permission-mode", "acceptEdits", "--resume", SID, P])
r, n = m.rebuild_argv_note(D, 0, SID, P, "default")
t("dangerously + default -> allow-dangerously only", r == ["claude", "--model", "opus", "--allow-dangerously-skip-permissions", "--resume", SID, P])
for PB in (["claude", "--permission-mode", "bypassPermissions", "--model", "opus"],
           ["claude", "--permission-mode=bypassPermissions", "--model", "opus"]):
    tag = "=" if "=" in PB[1] else "space"
    r, n = m.rebuild_argv_note(PB, 0, SID, P, "acceptEdits")
    t("pm bypass (%s) + acceptEdits -> allow + mode" % tag, r == ["claude", "--model", "opus", "--allow-dangerously-skip-permissions", "--permission-mode", "acceptEdits", "--resume", SID, P])
    r, n = m.rebuild_argv_note(PB, 0, SID, P, "default")
    t("pm bypass (%s) + default -> allow only" % tag, r == ["claude", "--model", "opus", "--allow-dangerously-skip-permissions", "--resume", SID, P])
    r, n = m.rebuild_argv_note(PB, 0, SID, P, "bypassPermissions")
    t("pm bypass (%s) + bypass -> unchanged" % tag, r == PB + ["--resume", SID, P])
    r, n = m.rebuild_argv_note(PB, 0, SID, P, None)
    t("pm bypass (%s) + no record -> unchanged" % tag, r == PB + ["--resume", SID, P])
r, n = m.rebuild_argv_note(["claude", "--allow-dangerously-skip-permissions", "--dangerously-skip-permissions"], 0, SID, P, "plan")
t("allow flag never duplicated", r.count("--allow-dangerously-skip-permissions") == 1 and "--dangerously-skip-permissions" not in r)
r, n = m.rebuild_argv_note(D, 0, SID, P, "bypassPermissions")
t("dangerously + bypass -> unchanged", r == D + ["--resume", SID, P])
r, n = m.rebuild_argv_note(D, 0, SID, P, None)
t("dangerously + no record -> unchanged", r == D + ["--resume", SID, P])
r, n = m.rebuild_argv_note(B, 0, SID, P, "acceptEdits")
t("mode acceptEdits restored", r[-5:-3] == ["--permission-mode", "acceptEdits"])
r, n = m.rebuild_argv_note(["claude", "--permission-mode", "plan"], 0, SID, P, "acceptEdits")
t("mode other kept when argv sets one", r == ["claude", "--permission-mode", "plan", "--resume", SID, P])
r, n = m.rebuild_argv_note(B, 0, SID, P, None)
t("mode missing -> argv as-is", r == B + ["--resume", SID, P])
for rec in ("acceptEdits", "plan", "default", "dontAsk", None):
    r, _ = m.rebuild_argv_note(B, 0, SID, P, rec)
    t("never escalate (%s)" % rec, "bypassPermissions" not in r and "--dangerously-skip-permissions" not in r)
# slug + transcript lookup
t("slug", m.slug("/home/u/my.proj_x") == "-home-u-my-proj-x")
t("slug truncates >200", len(m.slug("/" + "a" * 300)) == 200)
d = tempfile.mkdtemp()
A, Bc = os.path.join(d, "cfgA"), os.path.join(d, "cfgB")
os.makedirs(os.path.join(A, "projects", m.slug("/w/p")))
open(os.path.join(A, "projects", m.slug("/w/p"), SID + ".jsonl"), "w").close()
p, e = m.find_transcript(A, "/w/p", SID)
t("transcript exact", p and p.endswith(SID + ".jsonl") and e is None)
p, e = m.find_transcript(A, "/other/cwd", SID)
t("transcript unique glob fallback", p is not None and e is None)
os.makedirs(os.path.join(Bc, "projects", "zzz"))
open(os.path.join(Bc, "projects", "zzz", "only-b.jsonl"), "w").close()
p, e = m.find_transcript(A, "/w/p", "only-b")
t("profile isolation: other config dir not found", p is None and "not found" in e)
os.makedirs(os.path.join(A, "projects", "dup2"))
open(os.path.join(A, "projects", "dup2", SID + ".jsonl"), "w").close()
p, e = m.find_transcript(A, "/nowhere", SID)
t("transcript >1 matches fail", p is None and "ambiguous" in e)
p, e = m.find_transcript(A, "/nowhere", "nope")
t("transcript 0 matches fail", p is None and "not found" in e)
# allowlist + filtering
pl = [{"id": "credo@mkt-a"}, {"id": "dogma@mkt-a"}, {"id": "keep1@mkt-b"},
      {"id": "other@mkt-b"}, {"id": "x@mkt-c"}, {"id": "credo@mkt-a"}]
al, e = m.parse_allowlist(json.dumps({"mkt-a": "*", "mkt-b": ["keep1"]}))
t("allowlist parse", e is None and al == {"mkt-a": "*", "mkt-b": ["keep1"]})
t("allowlist filter", m.plugins_to_update(pl, al) == ["credo@mkt-a", "dogma@mkt-a", "keep1@mkt-b"])
os.environ["CREDO_SELF_RESTART_OWN_MARKETPLACE"] = "own-mkt"
t("allowlist default = own marketplace", m.parse_allowlist(None)[0] == {"own-mkt": "*"})
t("allowlist bad type", m.parse_allowlist('{"m": 5}')[1] is not None)
t("version summary changed", m.version_summary(["credo@a", "dogma@a"], {"credo@a": "0.69.0", "dogma@a": "1"}, {"credo@a": "0.70.0", "dogma@a": "1"}) == "updated: credo 0.69.0 -> 0.70.0; unchanged: dogma")
t("version summary none", m.version_summary(["credo@a"], {"credo@a": "1"}, {"credo@a": "1"}) == "no plugin updates")
# peer template must carry the 1-minute wait instruction
t("peer template has 1-minute wait", "WAIT ABOUT 1 MINUTE" in m.PEER_TEMPLATE)
# dialog constants
t("dialog answer is Escape", m.DIALOG_ANSWER_TMUX_KEYS == ["Escape"] and m.DIALOG_ANSWER_PTY_BYTES == b"\x1b")
t("dialog pattern", m.DIALOG_RE.search("Resuming the full session will consume a substantial portion of") is not None
  and m.DIALOG_RE.search("Resume full session as-is") is not None and m.DIALOG_RE.search("Resumed after a self-restart") is None)
# launcher
lt = m.launcher_text("/w/p", "/c fg", True, ["claude", "--resume", SID, "it's"])
t("launcher exports config dir", "export CLAUDE_CONFIG_DIR='/c fg'" in lt)
t("launcher sets no resume thresholds", "RESUME_THRESHOLD" not in lt and "TOKEN_THRESHOLD" not in lt)
t("launcher default profile unsets", "unset CLAUDE_CONFIG_DIR" in m.launcher_text("/w", "/h/.claude", False, ["claude"]))
t("launcher pty wrap", "relaunch-pty -- claude" in m.launcher_text("/w", "/c", True, ["claude"], pty_wrap=True))
print("\n".join(res))
PYEOF
while IFS= read -r line; do
    case "$line" in
        FAIL*) FAIL=$((FAIL + 1)); echo "$line" ;;
        "") ;;
        *) PASS=$((PASS + 1)) ;;
    esac
done < <(PATH="$BASE" "$PY" "$TMP/unit.py" "$HELPER" 2>&1)

# --- method selection + invocation ----------------------------------------------
cat > "$TMP/method.py" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("csr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
tenv = json.loads(sys.argv[2])
meth, det, err = m.choose_method(tenv, None, "credo-test")
if err:
    print("ERR " + err)
else:
    print(meth + "|" + json.dumps(det, sort_keys=True) + "|" + json.dumps(m.invocation(meth, det, "/c/l.sh", "/w/p")))
PYEOF
TENV_ALL='{"TMUX":"/tmp/t,1,2","TMUX_PANE":"%7","WSL_DISTRO_NAME":"Ubuntu","DISPLAY":":0"}'
out="$(PATH="$FT:$FW:$FX:$BASE" "$PY" "$TMP/method.py" "$HELPER" "$TENV_ALL")"
check "method tmux first" 'tmux|{"pane": "%7"}|["tmux", "send-keys", "-t", "%7", "clear; bash '"'"'/c/l.sh'"'"'", "Enter"]' "$out"
out="$(PATH="$FT:$FW:$FX:$BASE" "$PY" "$TMP/method.py" "$HELPER" '{"WSL_DISTRO_NAME":"Ubuntu","DISPLAY":":0"}')"
check "method wt with tmux guard" 'wt|{"distro": "Ubuntu", "tmux_session": "credo-test"}|["wt.exe", "-w", "0", "new-tab", "wsl.exe", "-d", "Ubuntu", "--cd", "/w/p", "--", "tmux", "new-session", "-s", "credo-test", "bash", "/c/l.sh"]' "$out"
out="$(PATH="$FW:$FX:$BASE" "$PY" "$TMP/method.py" "$HELPER" '{"WSL_DISTRO_NAME":"Ubuntu"}')"
check "method wt without tmux -> pty" 'wt|{"distro": "Ubuntu", "pty": true}|["wt.exe", "-w", "0", "new-tab", "wsl.exe", "-d", "Ubuntu", "--cd", "/w/p", "--", "bash", "/c/l.sh"]' "$out"
out="$(env -u WSL_DISTRO_NAME PATH="$FX:$BASE" "$PY" "$TMP/method.py" "$HELPER" '{"DISPLAY":":0"}')"
check "method x11" 'x11|{"pty": true, "terminal": "x-terminal-emulator"}|["x-terminal-emulator", "-e", "bash", "/c/l.sh"]' "$out"
out="$(env -u WSL_DISTRO_NAME PATH="$FT:$BASE" "$PY" "$TMP/method.py" "$HELPER" '{}')"
case "$out" in "ERR no way to bring the session back"*) ok "method none -> fail" 0 ;; *) ok "method none -> fail ($out)" 1 ;; esac

# --- relaunch-pty dialog injection ------------------------------------------------
cat > "$TMP/dialog.py" <<'PYEOF'
import os, sys, tty
tty.setraw(0)
sys.stdout.write("Resume from summary (recommended)\r\nResuming the full session will consume a substantial portion of your usage\r\n")
sys.stdout.flush()
c = os.read(0, 1)
sys.stdout.write("GOT:%s\r\n" % c.hex()); sys.stdout.flush()
sys.exit(3)
PYEOF
out="$(CREDO_SELF_RESTART_DIALOG_WATCH=10 timeout 20 "$PY" "$HELPER" relaunch-pty -- "$PY" "$TMP/dialog.py" < /dev/null)"; rc=$?
check "pty: child exit code passed through" "3" "$rc"
case "$out" in *"GOT:1b"*) ok "pty: dialog answered with Escape" 0 ;; *) ok "pty: dialog answered with Escape ($out)" 1 ;; esac
out="$(timeout 20 "$PY" "$HELPER" relaunch-pty -- "$PY" -c 'print("hello")' < /dev/null)"; rc=$?
check "pty: plain passthrough rc" "0" "$rc"
case "$out" in *hello*) ok "pty: plain passthrough output" 0 ;; *) ok "pty: plain passthrough output" 1 ;; esac

# --- permission-mode record hook ----------------------------------------------------
HC="$TMP/cfgH"
printf '{"session_id":"s-1","permission_mode":"bypassPermissions","hook_event_name":"UserPromptSubmit"}' | CLAUDE_CONFIG_DIR="$HC" bash "$HOOK"; rc=$?
check "hook exit 0" "0" "$rc"
check "hook records mode" "bypassPermissions" "$(cat "$HC/credo/session-mode/s-1" 2>/dev/null)"
printf '{"session_id":"s-1","permission_mode":"plan","hook_event_name":"SessionStart"}' | CLAUDE_CONFIG_DIR="$HC" bash "$HOOK"
check "hook updates mode" "plan" "$(cat "$HC/credo/session-mode/s-1" 2>/dev/null)"
printf '{"session_id":"../x","permission_mode":"plan"}' | CLAUDE_CONFIG_DIR="$HC" bash "$HOOK"; rc=$?
check "hook bad sid exit 0" "0" "$rc"
ok "hook bad sid writes nothing" "$([ ! -e "$HC/credo/x" ] && [ ! -e "$HC/credo/session-mode/../x" ] && echo 0 || echo 1)"
printf 'not json' | CLAUDE_CONFIG_DIR="$HC" bash "$HOOK"; check "hook garbage exit 0" "0" "$?"

# --- fake target helpers ------------------------------------------------------------
SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
PROJ="$TMP/proj dir"; mkdir -p "$PROJ"
CFGA="$TMP/cfgA"; CFGB="$TMP/cfgB"
SLUG="$("$PY" -c 'import re,sys; print(re.sub(r"[^A-Za-z0-9]","-",sys.argv[1]))' "$PROJ")"
mkdir -p "$CFGA/projects/$SLUG" "$CFGB/projects/$SLUG"
cat > "$TMP/fake_target.py" <<'PYEOF'
import os, signal, subprocess, sys, time
hits = []
def onint(*_):
    hits.append(1)
    if len(hits) >= 2:
        sys.exit(0)
signal.signal(signal.SIGINT, onint)
run = os.environ.get("FAKE_RUN_OUT")
if run:
    with open(run, "w") as fh:
        # argv[0] is "claude", so sys.executable would resolve to the fake CLI
        subprocess.run([os.readlink("/proc/self/exe"),os.environ["FAKE_HELPER"], "check"], stdout=fh, stderr=fh)
for _ in range(600):
    time.sleep(0.1)
PYEOF
start_target() { # pidfile cfgdir extra-env... -- args...
    local pidfile="$1" cfg="$2"; shift 2
    local envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    (cd "$PROJ" && exec env -u TMUX -u TMUX_PANE -u DISPLAY -u WAYLAND_DISPLAY -u WSL_DISTRO_NAME \
        CLAUDE_CONFIG_DIR="$cfg" "${envs[@]}" bash -c 'exec -a claude "$0" "$@"' "$PY" "$TMP/fake_target.py" "$@") &
    local p=$!
    PIDS="$PIDS $p"
    echo "$p" > "$pidfile"
    sleep 0.4
}

# --- check: failures ----------------------------------------------------------------
out="$(env -u CLAUDE_CODE_SESSION_ID -u CREDO_SELF_RESTART_SESSION_ID CREDO_SELF_RESTART_TARGET_PID=$$ PATH="$FT:$BASE" "$PY" "$HELPER" check 2>&1)"; rc=$?
check "check no session id -> rc 1" "1" "$rc"
case "$out" in *"FAIL: no session id"*) ok "check no session id message" 0 ;; *) ok "check no session id message" 1 ;; esac
sleep 300 & SLP=$!; PIDS="$PIDS $SLP"
out="$(CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$SLP PATH="$FT:$BASE" "$PY" "$HELPER" check 2>&1)"; rc=$?
check "check no target -> rc 1" "1" "$rc"
case "$out" in *"FAIL: no Claude Code process found"*) ok "check no target message" 0 ;; *) ok "check no target message" 1 ;; esac

# profile isolation end-to-end: transcript only under cfgB, target uses cfgA
: > "$CFGB/projects/$SLUG/$SID.jsonl"
start_target "$TMP/t1.pid" "$CFGA" TMUX=/tmp/t,1,2 TMUX_PANE=%9 -- --dangerously-skip-permissions
T1="$(cat "$TMP/t1.pid")"
out="$(CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T1 PATH="$FT:$FC:$BASE" "$PY" "$HELPER" check 2>&1)"; rc=$?
check "check other-profile transcript -> rc 1" "1" "$rc"
case "$out" in *"FAIL: transcript $SID.jsonl not found under $CFGA/projects"*) ok "check profile isolation message" 0 ;; *) ok "check profile isolation message" 1; echo "$out" ;; esac
kill -TERM "$T1" 2>/dev/null

# no relaunch method: target without TMUX/DISPLAY, no tmux/wt on PATH
: > "$CFGA/projects/$SLUG/$SID.jsonl"
start_target "$TMP/t2.pid" "$CFGA" -- --model opus
T2="$(cat "$TMP/t2.pid")"
out="$(env -u WSL_DISTRO_NAME CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T2 PATH="$FC:$BASE" "$PY" "$HELPER" check 2>&1)"; rc=$?
check "check no relaunch method -> rc 1" "1" "$rc"
case "$out" in *"FAIL: no way to bring the session back; not restarting"*) ok "check no method message" 0 ;; *) ok "check no method message" 1 ;; esac
# run refuses too, and the fake target is untouched
out="$(env -u WSL_DISTRO_NAME CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T2 PATH="$FC:$BASE" "$PY" "$HELPER" run 2>&1)"; rc=$?
check "run refuses on failed validation" "1" "$rc"
sleep 0.5
ok "refused run leaves target alive" "$(kill -0 "$T2" 2>/dev/null && echo 0 || echo 1)"
kill -TERM "$T2" 2>/dev/null

# alias-expanded argv: no bypass flag in cmdline -> none gained; recorded plan restored
mkdir -p "$CFGA/credo/session-mode"; echo plan > "$CFGA/credo/session-mode/$SID"
start_target "$TMP/t3.pid" "$CFGA" TMUX=/tmp/t,1,2 TMUX_PANE=%9 -- --model opus
T3="$(cat "$TMP/t3.pid")"
out="$(CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T3 PATH="$FT:$FC:$BASE" "$PY" "$HELPER" check 2>&1)"; rc=$?
check "check ok rc 0" "0" "$rc"
rl="$(printf '%s\n' "$out" | grep '^  relaunch:')"
case "$rl" in *dangerously*|*bypassPermissions*) ok "no bypass gained without it in cmdline" 1 ;; *) ok "no bypass gained without it in cmdline" 0 ;; esac
case "$rl" in *"--model opus --permission-mode plan --resume $SID '<wake prompt>'") ok "recorded plan mode restored" 0 ;; *) ok "recorded plan mode restored ($rl)" 1 ;; esac
case "$rl" in *fake_target.py*) ok "positional dropped from real cmdline" 1 ;; *) ok "positional dropped from real cmdline" 0 ;; esac
case "$out" in *"permission:   plan (restored)"*) ok "check shows restored mode" 0 ;; *) ok "check shows restored mode" 1 ;; esac
case "$out" in *"WAIT ABOUT 1 MINUTE"*) ok "check prints peer template with 1-minute wait" 0 ;; *) ok "check prints peer template with 1-minute wait" 1 ;; esac
case "$out" in *"dialog guard: tmux pane %9"*) ok "check shows dialog guard" 0 ;; *) ok "check shows dialog guard" 1 ;; esac
# another live process holding the same session -> fail
mkdir -p "$CFGA/sessions"
printf '{"pid": %d, "sessionId": "%s"}' "$SLP" "$SID" > "$CFGA/sessions/$SLP.json"
out="$(CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T3 PATH="$FT:$FC:$BASE" "$PY" "$HELPER" check 2>&1)"; rc=$?
check "check second holder -> rc 1" "1" "$rc"
case "$out" in *"also appears held by pid(s) $SLP"*) ok "check second holder message" 0 ;; *) ok "check second holder message" 1 ;; esac
rm -f "$CFGA/sessions/$SLP.json"
kill -TERM "$T3" 2>/dev/null
rm -f "$CFGA/credo/session-mode/$SID"

# parent-chain walk: the fake claude runs check as its own child (no TARGET_PID)
start_target "$TMP/t4.pid" "$CFGA" TMUX=/tmp/t,1,2 TMUX_PANE=%9 FAKE_RUN_OUT="$TMP/walk.out" FAKE_HELPER="$HELPER" \
    CREDO_SELF_RESTART_SESSION_ID=$SID PATH="$FT:$FC:$BASE" -- --dangerously-skip-permissions
T4="$(cat "$TMP/t4.pid")"
for _ in $(seq 1 30); do grep -q "^OK\|^FAIL" "$TMP/walk.out" 2>/dev/null && break; sleep 0.2; done
check "walk finds fake claude parent" "  target pid:   $T4" "$(grep '^  target pid:' "$TMP/walk.out")"
grep -q "^  config dir:   $CFGA\$" "$TMP/walk.out"; ok "walk reads target CLAUDE_CONFIG_DIR" "$?"
kill -TERM "$T4" 2>/dev/null

# --- end-to-end run against a fake target --------------------------------------------
cat > "$CREDO_GLOBAL" <<'EOF'
self_update:
  marketplaces:
    mkt-a: "*"
    mkt-b: [keep1]
EOF
export FAKE_PLUGIN_STATE="$TMP/plugins.json"
cat > "$FAKE_PLUGIN_STATE" <<'EOF'
[{"id": "credo@mkt-a", "version": "0.69.0"}, {"id": "dogma@mkt-a", "version": "1.0.0"},
 {"id": "keep1@mkt-b", "version": "2.0.0"}, {"id": "other@mkt-b", "version": "3.0.0"},
 {"id": "x@mkt-c", "version": "1.0.0"}]
EOF
export FAKE_BUMPS='{"credo@mkt-a": "0.70.0"}'
echo "Resuming the full session will consume a substantial portion of your usage" > "$TMP/pane.txt"
: > "$FAKE_TMUX_LOG"; : > "$FAKE_CLAUDE_LOG"
start_target "$TMP/t5.pid" "$CFGA" TMUX=/tmp/t,1,2 TMUX_PANE=%9 -- --dangerously-skip-permissions --resume old-name --model opus "hello prompt"
T5="$(cat "$TMP/t5.pid")"
out="$(CLAUDECODE=1 CLAUDE_CODE_FOO=bar CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T5 \
    FAKE_TARGET_PIDFILE="$TMP/t5.pid" FAKE_PANE_FILE="$TMP/pane.txt" CREDO_SELF_RESTART_SIGNAL_PAUSE=0.3 \
    CREDO_SELF_RESTART_STOP_TIMEOUT=10 CREDO_SELF_RESTART_DIALOG_WATCH=3 PATH="$FT:$FC:$BASE" \
    "$PY" "$HELPER" run --update --reason "test run" --delay 0.2 2>&1)"; rc=$?
check "run returns 0 immediately" "0" "$rc"
MARK="$CFGA/credo/self-restart.json"
for _ in $(seq 1 100); do grep -q '"dialog_guard"' "$MARK" 2>/dev/null && break; sleep 0.2; done
gone() { local st; st="$(cat /proc/"$1"/stat 2>/dev/null)" || return 0; st="${st##*) }"; [ "${st%% *}" = "Z" ]; }
gone "$T5"; ok "fake target stopped" "$?"
check "tmux C-c sent twice" "2" "$(grep -c '^send-keys -t %9 C-c$' "$FAKE_TMUX_LOG")"
LAUNCHER="$CFGA/credo/self-restart-launch.sh"
grep -qxF "send-keys -t %9 clear; bash '$LAUNCHER' Enter" "$FAKE_TMUX_LOG"; ok "relaunch typed into the same pane" "$?"
grep -qxF "send-keys -t %9 Escape" "$FAKE_TMUX_LOG"; ok "dialog answered with Escape" "$?"
ok "dialog never answered with Enter" "$(grep -qxF 'send-keys -t %9 Enter' "$FAKE_TMUX_LOG" && echo 1 || echo 0)"
"$PY" - "$MARK" "$SID" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["session_id"] == sys.argv[2], d
assert d["status"] == "relaunched", d
assert d["reason"] == "test run", d
assert d["versions"]["credo@mkt-a"] == {"before": "0.69.0", "after": "0.70.0"}, d
assert d["versions"]["dogma@mkt-a"] == {"before": "1.0.0", "after": "1.0.0"}, d
assert d["update"] == "updated: credo 0.69.0 -> 0.70.0; unchanged: dogma, keep1", d
assert d["dialog_guard"] == "answered", d
PYEOF
ok "marker: relaunched, versions before -> after, guard answered" "$?"
"$PY" - "$FAKE_CLAUDE_LOG" "$CFGA" <<'PYEOF'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1])]
cmds = [" ".join(r["argv"]) for r in recs]
assert cmds.count("plugin list --json") == 2, cmds
assert "plugin marketplace update mkt-a" in cmds and "plugin marketplace update mkt-b" in cmds, cmds
assert not any("mkt-c" in c for c in cmds if "marketplace" in c), cmds
ups = sorted(c for c in cmds if c.startswith("plugin update"))
assert ups == ["plugin update credo@mkt-a -y", "plugin update dogma@mkt-a -y", "plugin update keep1@mkt-b -y"], ups
assert all(r["stripped"] for r in recs), "session env not stripped"
assert all(r["cfg"] == sys.argv[2] for r in recs), "CLAUDE_CONFIG_DIR missing"
PYEOF
ok "update: allowlist only, env stripped, CLAUDE_CONFIG_DIR kept" "$?"
grep -q "version credo@mkt-a: 0.69.0 -> 0.70.0" "$CFGA/credo/self-restart.log"; ok "log records version before -> after" "$?"
# execute the generated launcher: the fake claude must get the exact relaunch argv
: > "$FAKE_CLAUDE_LOG"
CLAUDECODE=1 CLAUDE_CODE_FOO=bar PATH="$FC:$BASE" bash "$LAUNCHER"
"$PY" - "$FAKE_CLAUDE_LOG" "$CFGA" "$SID" "$PROJ" <<'PYEOF'
import json, sys
r = json.loads(open(sys.argv[1]).readline())
a = r["argv"]
assert a[:3] == ["--dangerously-skip-permissions", "--model", "opus"], a
assert a[3:5] == ["--resume", sys.argv[3]] and len(a) == 6, a
assert a[5].startswith("[credo-self-restart] Resumed after a self-restart (reason: test run; plugin update: updated: credo 0.69.0 -> 0.70.0"), a
assert "old-name" not in a and "hello prompt" not in a, a
assert r["stripped"] and r["cfg"] == sys.argv[2], r
PYEOF
ok "launcher execs claude --resume <id> <wake prompt> in the target profile" "$?"

# second run with nothing to update -> "no plugin updates"
export FAKE_BUMPS='{}'
start_target "$TMP/t6.pid" "$CFGA" TMUX=/tmp/t,1,2 TMUX_PANE=%9 -- --dangerously-skip-permissions
T6="$(cat "$TMP/t6.pid")"
rm -f "$MARK"
CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T6 FAKE_TARGET_PIDFILE="$TMP/t6.pid" \
    CREDO_SELF_RESTART_SIGNAL_PAUSE=0.3 CREDO_SELF_RESTART_STOP_TIMEOUT=10 CREDO_SELF_RESTART_DIALOG_WATCH=1 \
    PATH="$FT:$FC:$BASE" "$PY" "$HELPER" run --update --delay 0.2 >/dev/null 2>&1
for _ in $(seq 1 100); do grep -q '"dialog_guard"' "$MARK" 2>/dev/null && break; sleep 0.2; done
grep -q '"update": "no plugin updates"' "$MARK"; ok "no changes -> 'no plugin updates'" "$?"
grep -q "plugin update: no plugin updates" "$LAUNCHER"; ok "wake prompt says no plugin updates" "$?"
out="$(CREDO_SELF_RESTART_TARGET_PID=$$ CLAUDE_CONFIG_DIR="$CFGA" PATH="$FT:$BASE" "$PY" "$HELPER" status 2>&1)"
case "$out" in *'"status": "relaunched"'*"--- log tail ---"*) ok "status prints marker and log tail" 0 ;; *) ok "status prints marker and log tail" 1 ;; esac

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
