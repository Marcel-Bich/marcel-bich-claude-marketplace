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
#   - owner-rule guard: run refuses (exit 3, target untouched) in interactive mode
#     without --user-confirmed, with a missing/unreadable mode, and in autonomous mode
#     with --announce below the minimum; allowed with --user-confirmed or autonomous +
#     announce; the announcement line and ntfy push (local stub server) carry the
#     reason and the cancel command; cancel (kill path and marker-only path) keeps the
#     fake target alive; status shows pending/cancelled with the scheduled time.
#     The 300 s minimum is scaled down via the TEST-ONLY CREDO_SELF_RESTART_MIN_ANNOUNCE.
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

# fake tmux: records argv; C-c -> SIGINT the fake target; display-message -> pane info;
# capture-pane -> before the first C-c to the current fake target the pre-stop pane
# ($FAKE_IDLE_PANE, the idle-guard fixture), afterwards the pane file (dialog watch)
cat > "$FT/tmux" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_TMUX_LOG"
[ "$1" = "-S" ] && shift 2
tp="$(cat "${FAKE_TARGET_PIDFILE:-/nonexistent}" 2>/dev/null)"
if [ "$1" = "send-keys" ] && [ "${4:-}" = "C-c" ] && [ -n "$tp" ]; then
    : > "$FAKE_TMUX_LOG.cc.$tp"
    kill -INT "$tp" 2>/dev/null
fi
if [ "$1" = "display-message" ]; then
    printf '%s\t%s\t0\t0\n' "$4" "${FAKE_PANE_PID:-${tp:-1}}"
fi
if [ "$1" = "capture-pane" ]; then
    if [ -n "${FAKE_IDLE_PANE:-}" ] && [ -n "$tp" ] && [ ! -e "$FAKE_TMUX_LOG.cc.$tp" ]; then
        cat "$FAKE_IDLE_PANE"; exit 0
    fi
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
# idle-guard fixtures (invented text): idle with an empty input, and busy
RULE="────────────────────────────────────────────────────────────"
ELL="$(printf '\xe2\x80\xa6')"  # the TUI ellipsis character, kept out of the source
printf '%s\n' "● Done, the fixture task is finished." "" "✻ Worked for 1m 5s" "" "$RULE" "❯ " "$RULE" \
    "  ⏵⏵ accept edits on (shift+tab to cycle)" > "$TMP/pane-idle.txt"
printf '%s\n' "● Working on the fixture task." "" "✻ Brewing$ELL (12s · ↓ 300 tokens)" "" "$RULE" "❯ " "$RULE" \
    > "$TMP/pane-busy.txt"
printf '%s\n' "● Done." "" "$RULE" "❯ half typed user prompt" "$RULE" > "$TMP/pane-typed.txt"
export FAKE_IDLE_PANE="$TMP/pane-idle.txt" CREDO_SELF_RESTART_IDLE_TIMEOUT=20 \
    CREDO_SELF_RESTART_IDLE_POLL=0.2 CREDO_SELF_RESTART_IDLE_RECHECK=0.2
unset CREDO_SESSION_MODES_DIR CREDO_SELF_RESTART_MIN_ANNOUNCE
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
# a dialog blocking the idle wait: one early push without the dialog text
_sent = []; _orig = (m.ntfy, m.log)
m.ntfy = lambda title, body, *a, **k: _sent.append((title, body)); m.log = lambda msg: None
m.blocked_notify({"config_dir": "/x", "config_explicit": False}, "%9",
                 "permission prompt open, waiting for the user: secret-cmd --flag")
m.ntfy, m.log = _orig
t("blocked notify: one push naming the pane", len(_sent) == 1
  and _sent[0][0] == "credo self-restart blocked" and "%9" in _sent[0][1])
t("blocked notify: dialog text not pushed", "secret-cmd" not in _sent[0][1])
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
# owner-rule guard (real 300 s minimum)
os.environ.pop("CREDO_SELF_RESTART_MIN_ANNOUNCE", None)
t("min announce is 300", m.min_announce() == 300)
A = {"session_id": SID, "credo_mode": "autonomous"}
t("guard autonomous default announce 300", m.owner_guard(A, False, None) == (300, None))
t("guard autonomous 300 ok", m.owner_guard(A, False, 300)[1] is None)
a, e = m.owner_guard(A, False, 299)
t("guard autonomous 299 refused", a is None and "at least 5 minutes" in e)
for mode in ("active", "passive", None):
    a, e = m.owner_guard({"session_id": SID, "credo_mode": mode}, False, 600)
    t("guard %s refused" % mode, a is None and "Ask tool" in e and "--user-confirmed" in e)
t("guard user-confirmed default announce 0", m.owner_guard({"credo_mode": None}, True, None) == (0, None))
t("guard user-confirmed keeps announce", m.owner_guard({"credo_mode": "active"}, True, 30) == (30, None))
t("guard negative announce refused", m.owner_guard(A, True, -1)[1] is not None)
d2 = tempfile.mkdtemp()
os.makedirs(os.path.join(d2, "credo", "session-modes"))
open(os.path.join(d2, "credo", "session-modes", SID), "w").write("autonomous\n")
t("read credo mode", m.read_credo_mode(d2, SID) == "autonomous")
t("read credo mode missing", m.read_credo_mode(d2, "other") is None)
t("read credo mode bad sid", m.read_credo_mode(d2, "../x") is None)
t("duration format", m.fmt_duration(300) == "5 minutes" and m.fmt_duration(60) == "1 minute"
  and m.fmt_duration(2) == "2 seconds" and m.fmt_duration(1) == "1 second")
print("\n".join(res))
PYEOF
while IFS= read -r line; do
    case "$line" in
        FAIL*) FAIL=$((FAIL + 1)); echo "$line" ;;
        "") ;;
        *) PASS=$((PASS + 1)) ;;
    esac
done < <(PATH="$BASE" TMPDIR="$TMP" "$PY" "$TMP/unit.py" "$HELPER" 2>&1)   # unit mkdtemp() dirs stay under $TMP

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
check "method tmux first (session socket)" 'tmux|{"pane": "%7", "socket": "/tmp/t"}|["tmux", "-S", "/tmp/t", "send-keys", "-t", "%7", "clear; bash '"'"'/c/l.sh'"'"'", "Enter"]' "$out"
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
out="$(env -u WSL_DISTRO_NAME CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T2 PATH="$FC:$BASE" "$PY" "$HELPER" run --no-background-work --user-confirmed 2>&1)"; rc=$?
check "run refuses on failed validation" "1" "$rc"
sleep 0.5
ok "refused run leaves target alive" "$(kill -0 "$T2" 2>/dev/null && echo 0 || echo 1)"
kill -TERM "$T2" 2>/dev/null

# alias-expanded argv: no bypass flag in cmdline -> none gained; recorded plan restored
mkdir -p "$CFGA/credo/session-mode"; echo plan > "$CFGA/credo/session-mode/$SID"
start_target "$TMP/t3.pid" "$CFGA" TMUX=/tmp/t,1,2 TMUX_PANE=%9 -- --model opus
T3="$(cat "$TMP/t3.pid")"
out="$(CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T3 FAKE_TARGET_PIDFILE="$TMP/t3.pid" PATH="$FT:$FC:$BASE" "$PY" "$HELPER" check 2>&1)"; rc=$?
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
out="$(CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T3 FAKE_TARGET_PIDFILE="$TMP/t3.pid" PATH="$FT:$FC:$BASE" "$PY" "$HELPER" check 2>&1)"; rc=$?
check "check second holder -> rc 1" "1" "$rc"
case "$out" in *"also appears held by pid(s) $SLP"*) ok "check second holder message" 0 ;; *) ok "check second holder message" 1 ;; esac
rm -f "$CFGA/sessions/$SLP.json"
# pane ownership (same check as self-compact): the pane's process is a foreign process
out="$(CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T3 FAKE_PANE_PID=$SLP PATH="$FT:$FC:$BASE" "$PY" "$HELPER" check 2>&1)"; rc=$?
check "check foreign pane -> rc 1" "1" "$rc"
case "$out" in *"tmux pane %9 belongs to pid $SLP, which is not this Claude process"*) ok "check foreign pane message" 0 ;; *) ok "check foreign pane message ($out)" 1 ;; esac
grep -q -- "-S /tmp/t display-message -p -t %9" "$FAKE_TMUX_LOG"; ok "ownership check uses the session socket" "$?"
: > "$FAKE_TMUX_LOG"
out="$(CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T3 FAKE_TARGET_PIDFILE="$TMP/t3.pid" FAKE_PANE_PID=$SLP PATH="$FT:$FC:$BASE" "$PY" "$HELPER" run --no-background-work --user-confirmed --delay 0.2 2>&1)"; rc=$?
check "run foreign pane -> rc 1" "1" "$rc"
check "run foreign pane sends no keys" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"
ok "run foreign pane leaves the target alive" "$(kill -0 "$T3" 2>/dev/null && echo 0 || echo 1)"
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
    "$PY" "$HELPER" run --no-background-work --user-confirmed --update --reason "test run" --delay 0.2 2>&1)"; rc=$?
check "run returns 0 immediately" "0" "$rc"
MARK="$CFGA/credo/self-restart.json"
for _ in $(seq 1 100); do grep -q '"dialog_guard"' "$MARK" 2>/dev/null && break; sleep 0.2; done
gone() { local st; st="$(cat /proc/"$1"/stat 2>/dev/null)" || return 0; st="${st##*) }"; [ "${st%% *}" = "Z" ]; }
gone "$T5"; ok "fake target stopped" "$?"
check "tmux C-c sent twice" "2" "$(grep -c '^-S /tmp/t send-keys -t %9 C-c$' "$FAKE_TMUX_LOG")"
LAUNCHER="$CFGA/credo/self-restart-launch.sh"
grep -qxF -- "-S /tmp/t send-keys -t %9 clear; bash '$LAUNCHER' Enter" "$FAKE_TMUX_LOG"; ok "relaunch typed into the same pane" "$?"
grep -qxF -- "-S /tmp/t send-keys -t %9 Escape" "$FAKE_TMUX_LOG"; ok "dialog answered with Escape" "$?"
ok "dialog never answered with Enter" "$(grep -qxF -- '-S /tmp/t send-keys -t %9 Enter' "$FAKE_TMUX_LOG" && echo 1 || echo 0)"
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
    PATH="$FT:$FC:$BASE" "$PY" "$HELPER" run --no-background-work --user-confirmed --update --delay 0.2 >/dev/null 2>&1
for _ in $(seq 1 100); do grep -q '"dialog_guard"' "$MARK" 2>/dev/null && break; sleep 0.2; done
grep -q '"update": "no plugin updates"' "$MARK"; ok "no changes -> 'no plugin updates'" "$?"
grep -q "plugin update: no plugin updates" "$LAUNCHER"; ok "wake prompt says no plugin updates" "$?"
out="$(CREDO_SELF_RESTART_TARGET_PID=$$ CLAUDE_CONFIG_DIR="$CFGA" PATH="$FT:$BASE" "$PY" "$HELPER" status 2>&1)"
case "$out" in *'"status": "relaunched"'*"--- log tail ---"*) ok "status prints marker and log tail" 0 ;; *) ok "status prints marker and log tail" 1 ;; esac

# --- owner-rule guard, announce, cancel ----------------------------------------------
# local ntfy stub: records every POST (Title header + body) as one JSON line
cat > "$TMP/ntfy_stub.py" <<'PYEOF'
import http.server, json, sys
out, portfile = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        with open(out, "a") as fh:
            fh.write(json.dumps({"title": self.headers.get("Title"), "body": body}) + "\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
NTFY_OUT="$TMP/ntfy.jsonl"; : > "$NTFY_OUT"
"$PY" "$TMP/ntfy_stub.py" "$NTFY_OUT" "$TMP/ntfy.port" & NTFY_PID=$!; PIDS="$PIDS $NTFY_PID"
for _ in $(seq 1 50); do [ -s "$TMP/ntfy.port" ] && break; sleep 0.1; done
NTFY_URL="http://127.0.0.1:$(cat "$TMP/ntfy.port")/topic"
MODES="$CFGA/credo/session-modes"; mkdir -p "$MODES"
LOGF="$CFGA/credo/self-restart.log"
: > "$FAKE_TMUX_LOG"
start_target "$TMP/t7.pid" "$CFGA" TMUX=/tmp/t,1,2 TMUX_PANE=%21 -- --model opus
T7="$(cat "$TMP/t7.pid")"
G=(env CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T7 FAKE_TARGET_PIDFILE="$TMP/t7.pid"
   CREDO_SELF_RESTART_NTFY_URL="$NTFY_URL" CREDO_SELF_RESTART_SIGNAL_PAUSE=0.3 CREDO_SELF_RESTART_STOP_TIMEOUT=10
   CREDO_SELF_RESTART_DIALOG_WATCH=1 PATH="$FT:$FC:$BASE")
rm -f "$MARK" "$MODES/$SID"
# missing mode -> refused
out="$("${G[@]}" "$PY" "$HELPER" run --delay 0.2 2>&1)"; rc=$?
check "guard: missing mode -> rc 3" "3" "$rc"
case "$out" in *"REFUSED: refused by the owner rule"*"is not set, not autonomous"*"Ask tool"*"Nothing was started."*) ok "guard: missing mode message" 0 ;; *) ok "guard: missing mode message ($out)" 1 ;; esac
# interactive (active) mode without --user-confirmed -> refused, even with a long announce
echo active > "$MODES/$SID"
out="$("${G[@]}" "$PY" "$HELPER" run --announce 600 --delay 0.2 2>&1)"; rc=$?
check "guard: active mode without --user-confirmed -> rc 3" "3" "$rc"
case "$out" in *"is 'active', not autonomous"*"--user-confirmed"*) ok "guard: active mode message" 0 ;; *) ok "guard: active mode message ($out)" 1 ;; esac
# unreadable mode (a directory instead of a file) -> not autonomous
rm -f "$MODES/$SID"; mkdir -p "$MODES/$SID"
out="$("${G[@]}" "$PY" "$HELPER" run --delay 0.2 2>&1)"; rc=$?
check "guard: unreadable mode -> rc 3" "3" "$rc"
rmdir "$MODES/$SID"
# autonomous with announce below the (scaled) minimum -> refused
echo autonomous > "$MODES/$SID"
out="$("${G[@]}" CREDO_SELF_RESTART_MIN_ANNOUNCE=5 "$PY" "$HELPER" run --announce 2 --delay 0.2 2>&1)"; rc=$?
check "guard: autonomous announce < minimum -> rc 3" "3" "$rc"
case "$out" in *"announced at least 5 seconds ahead (--announce 5 or more, got 2)"*) ok "guard: short announce message" 0 ;; *) ok "guard: short announce message ($out)" 1 ;; esac
# CREDO_SESSION_MODES_DIR override is honored (same as the mode hooks)
mkdir -p "$TMP/modes-alt"; echo autonomous > "$TMP/modes-alt/$SID"; rm -f "$MODES/$SID"
out="$("${G[@]}" CREDO_SESSION_MODES_DIR="$TMP/modes-alt" "$PY" "$HELPER" check 2>&1)"
case "$out" in *"owner rule:   credo mode autonomous"*) ok "check shows owner rule (modes dir override)" 0 ;; *) ok "check shows owner rule ($out)" 1 ;; esac
sleep 0.5
# background rule: without --no-background-work every run is refused, even confirmed
out="$("${G[@]}" "$PY" "$HELPER" run --user-confirmed --delay 0.2 2>&1)"; rc=$?
check "guard: no --no-background-work -> rc 3" "3" "$rc"
case "$out" in *"refused by the background rule: pass --no-background-work"*"never stop them"*"Nothing was started."*) ok "guard: background refusal message" 0 ;; *) ok "guard: background refusal message ($out)" 1 ;; esac
echo autonomous > "$MODES/$SID"
out="$("${G[@]}" CREDO_SELF_RESTART_MIN_ANNOUNCE=1 "$PY" "$HELPER" run --announce 1 --delay 0.2 2>&1)"; rc=$?
check "guard: autonomous without --no-background-work -> rc 3" "3" "$rc"
rm -f "$MODES/$SID"
ok "guard refusals leave the target alive" "$(kill -0 "$T7" 2>/dev/null && echo 0 || echo 1)"
ok "guard refusals start no worker / write no marker" "$([ ! -e "$MARK" ] && echo 0 || echo 1)"
check "guard refusals send no C-c" "0" "$(grep -c 'C-c' "$FAKE_TMUX_LOG")"
check "guard refusals send no ntfy" "0" "$(wc -l < "$NTFY_OUT" | tr -d ' ')"

# cancel during the announce period (kill path): target is NOT stopped
echo autonomous > "$MODES/$SID"
out="$("${G[@]}" CREDO_SELF_RESTART_MIN_ANNOUNCE=3 "$PY" "$HELPER" run --no-background-work --reason "cc-up test" --delay 0.2 2>&1)"; rc=$?
check "autonomous run with default (scaled) announce -> rc 0" "0" "$rc"
case "$out" in *"Self-restart scheduled in 3 seconds (reason: cc-up test). Cancel: python3 "*"credo-self-restart.py cancel"*) ok "announce message in transcript" 0 ;; *) ok "announce message in transcript ($out)" 1 ;; esac
"$PY" - "$NTFY_OUT" "$SID" <<'PYEOF'
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
assert len(r) == 1, r
assert r[0]["title"] == "credo self-restart in 3 seconds", r
assert "reason: cc-up test" in r[0]["body"] and "credo-self-restart.py cancel" in r[0]["body"] and sys.argv[2] in r[0]["body"], r
PYEOF
ok "announce ntfy: title, reason, cancel command" "$?"
out="$(CREDO_SELF_RESTART_TARGET_PID=$$ CLAUDE_CONFIG_DIR="$CFGA" PATH="$FT:$BASE" "$PY" "$HELPER" status 2>&1)"
case "$out" in "state: pending; scheduled: 20"*"reason: cc-up test"*) ok "status shows pending with scheduled time" 0 ;; *) ok "status shows pending ($out)" 1 ;; esac
WPID="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["worker_pid"])' "$MARK")"
out="$("${G[@]}" CREDO_SELF_RESTART_MIN_ANNOUNCE=3 "$PY" "$HELPER" run --no-background-work --delay 0.2 2>&1)"; rc=$?
check "second run while pending -> rc 1" "1" "$rc"
case "$out" in *"already pending (worker $WPID)"*) ok "second run names the pending worker" 0 ;; *) ok "second run names the pending worker ($out)" 1 ;; esac
out="$(CREDO_SELF_RESTART_TARGET_PID=$$ CLAUDE_CONFIG_DIR="$CFGA" CREDO_SELF_RESTART_NTFY_URL="$NTFY_URL" PATH="$FT:$BASE" "$PY" "$HELPER" cancel 2>&1)"; rc=$?
check "cancel -> rc 0" "0" "$rc"
case "$out" in *"cancelled (session $SID, was scheduled for 20"*"worker $WPID terminated"*) ok "cancel message" 0 ;; *) ok "cancel message ($out)" 1 ;; esac
sleep 4.5
ok "cancelled: worker gone" "$(gone "$WPID" && echo 0 || echo 1)"
ok "cancelled: fake target NOT stopped" "$(kill -0 "$T7" 2>/dev/null && ! gone "$T7" && echo 0 || echo 1)"
check "cancelled: no C-c sent" "0" "$(grep -c 'C-c' "$FAKE_TMUX_LOG")"
grep -q '"status": "cancelled"' "$MARK"; ok "cancelled: marker status" "$?"
grep -q "self-restart cancelled before stopping the target" "$LOGF"; ok "cancelled: worker logged it" "$?"
grep -q '"title": "credo self-restart cancelled"' "$NTFY_OUT"; ok "cancelled: ntfy sent" "$?"
out="$(CREDO_SELF_RESTART_TARGET_PID=$$ CLAUDE_CONFIG_DIR="$CFGA" PATH="$FT:$BASE" "$PY" "$HELPER" status 2>&1)"
case "$out" in "state: cancelled; scheduled: 20"*) ok "status shows cancelled" 0 ;; *) ok "status shows cancelled ($out)" 1 ;; esac
out="$(CREDO_SELF_RESTART_TARGET_PID=$$ CLAUDE_CONFIG_DIR="$CFGA" PATH="$FT:$BASE" "$PY" "$HELPER" cancel 2>&1)"; rc=$?
check "cancel with nothing pending -> rc 1" "1" "$rc"
case "$out" in *"nothing to cancel (self-restart status: cancelled)"*) ok "cancel nothing-pending message" 0 ;; *) ok "cancel nothing-pending message ($out)" 1 ;; esac

# marker-only cancel (worker not signalled): the final re-check before stopping aborts
out="$("${G[@]}" CREDO_SELF_RESTART_MIN_ANNOUNCE=2 "$PY" "$HELPER" run --no-background-work --delay 0.2 2>&1)"; rc=$?
check "autonomous run (marker-cancel case) -> rc 0" "0" "$rc"
"$PY" - "$MARK" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1])); d["status"] = "cancelled"
json.dump(d, open(sys.argv[1], "w"))
PYEOF
sleep 3.5
ok "marker-cancel: fake target NOT stopped" "$(kill -0 "$T7" 2>/dev/null && ! gone "$T7" && echo 0 || echo 1)"
check "marker-cancel: no C-c sent" "0" "$(grep -c 'C-c' "$FAKE_TMUX_LOG")"
check "marker-cancel: worker logged the abort" "2" "$(grep -c 'self-restart cancelled before stopping the target' "$LOGF")"

# autonomous + announce >= minimum: the restart goes through after the announcement
: > "$NTFY_OUT"
out="$("${G[@]}" CREDO_SELF_RESTART_MIN_ANNOUNCE=1 "$PY" "$HELPER" run --no-background-work --announce 1 --reason "auto" --delay 0.2 2>&1)"; rc=$?
check "autonomous + announce >= minimum -> rc 0" "0" "$rc"
for _ in $(seq 1 100); do grep -q '"dialog_guard"' "$MARK" 2>/dev/null && break; sleep 0.2; done
gone "$T7"; ok "autonomous: fake target stopped after the announcement" "$?"
grep -q '"status": "relaunched"' "$MARK"; ok "autonomous: marker relaunched" "$?"
grep -q '"title": "credo self-restart in 1 second"' "$NTFY_OUT"; ok "autonomous: announce ntfy sent" "$?"
grep -qxF -- "-S /tmp/t send-keys -t %21 clear; bash '$LAUNCHER' Enter" "$FAKE_TMUX_LOG"; ok "autonomous: relaunched into the same pane" "$?"

# --user-confirmed without autonomous mode: no announce, existing short delay
rm -f "$MODES/$SID"; : > "$NTFY_OUT"
start_target "$TMP/t8.pid" "$CFGA" TMUX=/tmp/t,1,2 TMUX_PANE=%22 -- --model opus
T8="$(cat "$TMP/t8.pid")"
out="$(CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T8 FAKE_TARGET_PIDFILE="$TMP/t8.pid" \
    CREDO_SELF_RESTART_NTFY_URL="$NTFY_URL" CREDO_SELF_RESTART_SIGNAL_PAUSE=0.3 CREDO_SELF_RESTART_STOP_TIMEOUT=10 \
    CREDO_SELF_RESTART_DIALOG_WATCH=1 PATH="$FT:$FC:$BASE" "$PY" "$HELPER" run --no-background-work --user-confirmed --delay 0.2 2>&1)"; rc=$?
check "user-confirmed (no mode) -> rc 0" "0" "$rc"
case "$out" in *"Self-restart scheduled"*) ok "user-confirmed: no announcement" 1 ;; *"End your turn now."*) ok "user-confirmed: no announcement" 0 ;; *) ok "user-confirmed: no announcement ($out)" 1 ;; esac
for _ in $(seq 1 100); do grep -q '"dialog_guard"' "$MARK" 2>/dev/null && break; sleep 0.2; done
gone "$T8"; ok "user-confirmed: fake target stopped" "$?"
grep -q '"user_confirmed": true' "$MARK"; ok "user-confirmed: recorded in marker" "$?"
check "user-confirmed: no announce ntfy" "0" "$(wc -l < "$NTFY_OUT" | tr -d ' ')"

# --- idle guard: never stop while the user is typing or the session is busy ---------
# typed text in the input -> the worker waits and gives up at the timeout, nothing stopped
cp "$TMP/pane-typed.txt" "$TMP/pane-t9.txt"; : > "$FAKE_TMUX_LOG"
start_target "$TMP/t9.pid" "$CFGA" TMUX=/tmp/t,1,2 TMUX_PANE=%23 -- --model opus
T9="$(cat "$TMP/t9.pid")"
out="$(CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T9 FAKE_TARGET_PIDFILE="$TMP/t9.pid" \
    FAKE_IDLE_PANE="$TMP/pane-t9.txt" CREDO_SELF_RESTART_IDLE_TIMEOUT=1.5 CREDO_SELF_RESTART_SIGNAL_PAUSE=0.3 \
    CREDO_SELF_RESTART_STOP_TIMEOUT=10 PATH="$FT:$FC:$BASE" "$PY" "$HELPER" run --no-background-work --user-confirmed --delay 0.2 2>&1)"; rc=$?
check "idle guard (typed): run returns 0" "0" "$rc"
for _ in $(seq 1 50); do grep -q '"status": "failed: session not idle"' "$MARK" 2>/dev/null && break; sleep 0.2; done
grep -q '"status": "failed: session not idle"' "$MARK"; ok "idle guard (typed): marker failed: session not idle" "$?"
check "idle guard (typed): no C-c sent" "0" "$(grep -c 'C-c' "$FAKE_TMUX_LOG")"
ok "idle guard (typed): fake target NOT stopped" "$(kill -0 "$T9" 2>/dev/null && ! gone "$T9" && echo 0 || echo 1)"
grep -q "pane %23: input not empty" "$LOGF"; ok "idle guard (typed): reason logged" "$?"
grep -q -- "-S /tmp/t capture-pane -p -e -t %23" "$FAKE_TMUX_LOG"; ok "idle guard captures the target pane on the session socket" "$?"
check "idle guard: every tmux call uses the session socket" "0" "$(grep -vc '^-S /tmp/t ' "$FAKE_TMUX_LOG")"
# busy first, idle later -> waits, then stops; no C-c while busy
cp "$TMP/pane-busy.txt" "$TMP/pane-t9.txt"; : > "$FAKE_TMUX_LOG"
out="$(CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T9 FAKE_TARGET_PIDFILE="$TMP/t9.pid" \
    FAKE_IDLE_PANE="$TMP/pane-t9.txt" CREDO_SELF_RESTART_SIGNAL_PAUSE=0.3 CREDO_SELF_RESTART_DIALOG_WATCH=1 \
    CREDO_SELF_RESTART_STOP_TIMEOUT=10 PATH="$FT:$FC:$BASE" "$PY" "$HELPER" run --no-background-work --user-confirmed --delay 0.2 2>&1)"; rc=$?
check "idle guard (busy): run returns 0" "0" "$rc"
sleep 1.5
check "idle guard (busy): no C-c while busy" "0" "$(grep -c 'C-c' "$FAKE_TMUX_LOG")"
ok "idle guard (busy): target alive while busy" "$(kill -0 "$T9" 2>/dev/null && ! gone "$T9" && echo 0 || echo 1)"
cp "$TMP/pane-idle.txt" "$TMP/pane-t9.txt"
for _ in $(seq 1 100); do grep -q '"dialog_guard"' "$MARK" 2>/dev/null && break; sleep 0.2; done
gone "$T9"; ok "idle guard (busy -> idle): target stopped once idle" "$?"
grep -q "pane %23: busy: ✻ Brewing" "$LOGF"; ok "idle guard (busy): busy state logged" "$?"


# --- target exits by itself while the worker waits for idle -> abort, no relaunch ------
cp "$TMP/pane-busy.txt" "$TMP/pane-t10.txt"; : > "$FAKE_TMUX_LOG"; rm -f "$MARK"
start_target "$TMP/t10.pid" "$CFGA" TMUX=/tmp/t,1,2 TMUX_PANE=%24 -- --model opus
T10="$(cat "$TMP/t10.pid")"
out="$(CREDO_SELF_RESTART_SESSION_ID=$SID CREDO_SELF_RESTART_TARGET_PID=$T10 FAKE_TARGET_PIDFILE="$TMP/t10.pid" \
    FAKE_IDLE_PANE="$TMP/pane-t10.txt" CREDO_SELF_RESTART_SIGNAL_PAUSE=0.3 CREDO_SELF_RESTART_STOP_TIMEOUT=10 \
    PATH="$FT:$FC:$BASE" "$PY" "$HELPER" run --no-background-work --user-confirmed --delay 0.2 2>&1)"; rc=$?
check "target gone: run returns 0" "0" "$rc"
sleep 1
kill -TERM "$T10" 2>/dev/null
for _ in $(seq 1 50); do grep -q '"status": "failed: target gone"' "$MARK" 2>/dev/null && break; sleep 0.2; done
grep -q '"status": "failed: target gone"' "$MARK"; ok "target gone: marker failed: target gone" "$?"
check "target gone: no C-c sent" "0" "$(grep -c 'C-c' "$FAKE_TMUX_LOG")"
check "target gone: nothing relaunched" "0" "$(grep -c 'clear; bash' "$FAKE_TMUX_LOG")"
grep -q "target gone while waiting for idle" "$LOGF"; ok "target gone: logged" "$?"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
