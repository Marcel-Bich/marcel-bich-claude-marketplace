#!/bin/bash
# Tests for credo-self-compact.py and the shared pane guard credo_pane_guard.py.
#
# NOTHING real is ever typed into: tmux is a FAKE binary first on a restricted PATH
# (it records every call and serves invented pane fixtures), every target is a FAKE
# process this test starts itself (argv[0] "claude"), every config dir is a temp dir,
# ntfy is off. No real tmux pane is ever addressed.
#
# It checks:
#   - pure detection on invented pane fixtures: idle empty, idle with typed text,
#     busy spinner (current and older style), compacting, Ask dialog, permission
#     prompt, slash menu, picker hints below an empty box, Ctrl-C-again, dimmed
#     placeholder (with and without the inverted cursor char), typed text in a gray
#     colour, a cursor on a single typed char, a dim paste reference, multi-row input,
#     no box at all, a labelled top rule, the old bordered box, transcript text that
#     only quotes dialog words far above the box, background shells / agents in the
#     footer under the box (not safe by default as self-restart uses it, safe with
#     block_on_background=False as self-compact uses it - background work survives
#     /compact; typed input or a dialog with that footer still blocks), assess() with an
#     expected input (pre-Enter check)
#   - input_content() and the two-probe wait_until_safe() (fake clock)
#   - check: no session id, not in tmux, no compact-plus breadcrumb, foreign pane
#     (pane process not this Claude), a nested Claude between the pane process and the
#     target, a stale breadcrumb (max age, configurable), OK plan with the own pane and
#     tmux socket, background work in the footer does not block (pane state idle)
#   - owner rule: run needs exactly one of --auto / --user-confirmed; --auto refused
#     unless this session's credo mode is autonomous; refusals start nothing; no background
#     rule for self-compact: run works without --no-background-work (the flag is still
#     accepted as a no-op) and types /compact while background agents / shells run
#   - worker: types '/compact ...' literally into the own pane only, verifies the
#     input, then Enter; waits while busy / typed / dialog / copy mode; gives up at the
#     timeout; no Enter when the input does not hold exactly the /compact line;
#     aborts when the target dies; the pre-Enter check is the full assess (dialog or
#     copy mode after typing -> no Enter); cancel and status are per session (another
#     session's cancel does not touch this session's pending self-compact)
#
# Usage: bash test-credo-self-compact.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/credo-self-compact.py"
GUARD="$SCRIPT_DIR/credo_pane_guard.py"
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "SKIP: python3 not found"; exit 0; fi
for f in "$HELPER" "$GUARD"; do [ -f "$f" ] || { echo "FAIL: $f missing"; exit 1; }; done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/csc.XXXXXX")"
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

# --- pure detection (module imported directly) -------------------------------------
cat > "$TMP/unit.py" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("g", sys.argv[1])
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
res = []
def t(name, cond):
    res.append(name if cond else "FAIL " + name)

R = "\x1b[38;5;244m" + "─" * 60 + "\x1b[39m"
RL = "─" * 48 + " demo-session ─"
P = "❯ "
STATUS = "  ⏵⏵ accept edits on (shift+tab to cycle) · ← for agents"
def pane(above, box, below=(STATUS,), top=R):
    return "\n".join(list(above) + [top] + list(box) + [R] + list(below)) + "\n"

DONE = ["● Done. The fixture report is written.", "", "✻ Worked for 2m 10s", ""]
F = {}
F["idle_empty"] = pane(DONE, [P])
F["idle_typed"] = pane(DONE, [P + "please also check the"])
F["busy_spinner"] = pane(["● Reading the fixture file.", "",
                          "✻ Brewing\u2026 (12s · ↓ 300 tokens)",
                          "  ⎿  Next: fixture step two", ""], [P])
F["busy_old"] = pane(["✶ Thinking\u2026 (5s · esc to interrupt)", ""], [P])
F["compacting"] = pane(["✢ Compacting conversation\u2026", ""], [P])
F["busy_far"] = pane(["✻ Working\u2026 (2m 1s · ↓ 9k tokens)"]
                     + ["     ◻ fixture task %d" % i for i in range(14)] + [""], [P])
F["ask_dialog"] = ("● Which variant should the fixture use?\n\n"
                   "❯ 1. Alpha\n  2. Beta\n  3. Type something.\n\n"
                   "Enter to select · ↑/↓ to navigate · Esc to cancel\n")
F["permission"] = (R + "\n Bash command\n\n   ls /tmp/fixture-dir\n\n Do you want to proceed?\n"
                   " ❯ 1. Yes\n   2. Yes, and don't ask again\n   3. No (esc)\n")
F["slash_menu"] = pane(DONE, [P + "/comp"], ["  /compact   Clear history but keep a summary",
                                             "  /config    Open config panel"])
F["picker_below"] = pane(DONE, [P], ["  ↑/↓ to navigate · Enter to select · Esc to close"])
F["ctrl_c_again"] = pane(DONE, [P], ["  Press Ctrl-C again to exit"])
F["placeholder"] = pane(DONE, [P + "\x1b[7mT\x1b[27m\x1b[2mry \"fix the fixture tests\"\x1b[22m"])
F["placeholder_nocursor"] = pane(DONE, [P + "\x1b[2mTry \"fix the fixture tests\"\x1b[22m"])
F["gray_typed"] = pane(DONE, [P + "\x1b[38;5;246mtyped in gray\x1b[39m"])
F["truecolor_typed"] = pane(DONE, [P + "\x1b[38;2;2;2;2mtyped\x1b[39m"])
F["cursor_on_char"] = pane(DONE, [P + "\x1b[7mx\x1b[27m"])
F["dim_paste"] = pane(DONE, [P + "\x1b[2m[Pasted text #1 +12 lines]\x1b[22m"])
F["multirow"] = pane(DONE, [P + "first row", "  second row"])
F["shell"] = "user@box-1:~$ \n"
F["labelled_rule"] = pane(DONE, [P], top=RL)
F["old_box_empty"] = ("● Done.\n\n╭" + "─" * 40 + "╮\n│ >" + " " * 38
                      + "│\n╰" + "─" * 40 + "╯\n  ? for shortcuts\n")
F["old_box_typed"] = F["old_box_empty"].replace("│ >  ", "│ > hi")
F["quoted_far_above"] = pane(["● The doc says: Enter to select, Esc to cancel."] + [""] * 8 + DONE, [P])
F["ellipsis_message"] = pane(["● I checked the fixture logs\u2026 all fine.", ""], [P])
F["bg_shell_status"] = pane(DONE, [P], [STATUS + " · 1 shell"])
F["bg_shells_line"] = pane(DONE, [P], [STATUS, "  3 shells"])
F["bg_agents"] = pane(DONE, [P], [STATUS, "  ◯ general-purpose  Audit the fixture report  1m 3s",
                                  "  ◯ Explore  Search the fixture tree"])
F["shell_quoted_above"] = pane(["● Started 1 shell for the fixture build.", ""] + DONE, [P])

expect = {"idle_empty": True, "idle_typed": False, "busy_spinner": False, "busy_old": False,
          "compacting": False, "busy_far": False, "ask_dialog": False, "permission": False,
          "slash_menu": False, "picker_below": False, "ctrl_c_again": False,
          "placeholder": True, "placeholder_nocursor": True, "gray_typed": False,
          "truecolor_typed": False, "cursor_on_char": False, "dim_paste": False,
          "multirow": False, "shell": False, "labelled_rule": True, "old_box_empty": True,
          "old_box_typed": False, "quoted_far_above": True, "ellipsis_message": True,
          "bg_shell_status": False, "bg_shells_line": False, "bg_agents": False,
          "shell_quoted_above": True}
for k, want in sorted(expect.items()):
    safe, reason = g.assess(F[k])
    t("assess %s -> %s (%s)" % (k, want, reason), safe is want)
t("reason busy", g.assess(F["busy_spinner"])[1].startswith("busy:"))
t("reason typed", "not empty" in g.assess(F["idle_typed"])[1])
t("reason dialog", "dialog" in g.assess(F["picker_below"])[1])
for k in ("bg_shell_status", "bg_shells_line", "bg_agents"):
    t("reason background %s" % k, g.assess(F[k])[1].startswith("background work running"))
# assess with an expected input (the pre-Enter check)
TYPED = "please also check the"
t("expect: exact text -> safe", g.assess(F["idle_typed"], expect=TYPED)[0])
t("expect: other text -> not safe", not g.assess(F["idle_typed"], expect="other text")[0])
t("expect: empty box -> not safe", not g.assess(F["idle_empty"], expect=TYPED)[0])
t("expect: wrapped rows joined", g.assess(F["multirow"], expect="first row second row")[0])
t("expect: dialog below -> not safe",
  not g.assess(pane(DONE, [P + TYPED], ["  Enter to confirm · Esc to cancel"]), expect=TYPED)[0])
t("expect: busy -> not safe",
  not g.assess(pane(["✻ Brewing\u2026 (3s · ↓ 9 tokens)", ""], [P + TYPED]), expect=TYPED)[0])
t("expect: background -> not safe",
  not g.assess(pane(DONE, [P + TYPED], [STATUS + " · 2 shells"]), expect=TYPED)[0])
# self-compact: background work in the footer never blocks (it survives /compact)
for k in ("bg_shell_status", "bg_shells_line", "bg_agents"):
    t("no-bg-block %s -> safe" % k, g.assess(F[k], block_on_background=False)
      == (True, "idle, input empty"))
t("no-bg-block: default still blocks",
  g.assess(F["bg_agents"], block_on_background=True)[1].startswith("background work running"))
BGFOOT = [STATUS + " · 2 shells", "  ◯ general-purpose  Audit the fixture report  1m 3s",
          "  ◯ Explore  Search the fixture tree", "  ◯ monitor  Watch the fixture log"]
t("no-bg-block: typed input with bg footer -> not safe",
  not g.assess(pane(DONE, [P + TYPED], BGFOOT), block_on_background=False)[0])
t("no-bg-block: placeholder with bg footer -> safe",
  g.assess(pane(DONE, [P + "\x1b[2mTry \"fix\"\x1b[22m"], BGFOOT), block_on_background=False)[0])
t("no-bg-block: busy with bg footer -> not safe",
  not g.assess(pane(["✻ Brewing\u2026 (3s · ↓ 9 tokens)", ""], [P], BGFOOT),
               block_on_background=False)[0])
t("no-bg-block: dialog with bg footer -> not safe",
  not g.assess(pane(DONE, [P], BGFOOT + ["  Enter to confirm · Esc to cancel"]),
               block_on_background=False)[0])
t("no-bg-block: expect with bg footer -> safe",
  g.assess(pane(DONE, [P + TYPED], BGFOOT), expect=TYPED, block_on_background=False)[0])
t("no-bg-block: content with bg footer is empty",
  g.input_content(pane(DONE, [P], BGFOOT)) == "")
# input_content
t("content empty", g.input_content(F["idle_empty"]) == "")
t("content placeholder is empty", g.input_content(F["placeholder"]) == "")
t("content typed", g.input_content(F["idle_typed"]) == "please also check the")
t("content wrapped rows joined", g.input_content(F["multirow"]) == "first row second row")
t("content no box -> None", g.input_content(F["ask_dialog"]) is None)
t("rule with label", g.is_rule(RL) and not g.is_rule("● text ──"))
t("sgr 38;2 never dim", all(not d for _, d, _ in g.styled_chars("\x1b[38;2;2;2;2mab")))
t("sgr 2 dim, 22 undim", [d for _, d, _ in g.styled_chars("\x1b[2ma\x1b[22mb")] == [True, False])
t("socket from TMUX", g.socket_from_tmux_env("/tmp/s-1/default,77,0") == "/tmp/s-1/default"
  and g.socket_from_tmux_env("") is None and g.socket_from_tmux_env("rel,1,2") is None)

# wait_until_safe with a fake clock
class Clock(object):
    def __init__(self): self.t = 0.0
    def now(self): return self.t
    def sleep(self, s): self.t += s
def run(seq, timeout=10, stop=None):
    c = Clock(); calls = []
    def probe():
        v = seq[min(len(calls), len(seq) - 1)]; calls.append(v)
        return v, "safe" if v else "busy"
    r = g.wait_until_safe(probe, timeout, poll=1, recheck=1, sleep=c.sleep, clock=c.now,
                          should_stop=stop)
    return r, calls
r, calls = run([True, True])
t("wait: two safe probes -> ok", r[0] and len(calls) == 2)
r, calls = run([True, False, True, True])
t("wait: safe, unsafe, safe, safe -> ok after 4", r[0] and len(calls) == 4)
r, calls = run([True, False, True, False, True, True])
t("wait: never one probe alone", r[0] and calls[-2:] == [True, True])
r, calls = run([False], timeout=5)
t("wait: never safe -> timeout", not r[0] and r[1].startswith("timeout after 5s"))
r, calls = run([True, True], stop=lambda: True)
t("wait: stop -> cancelled, no probe", r == (False, "cancelled") and calls == [])
print("\n".join(res))
PYEOF
while IFS= read -r line; do
    case "$line" in
        FAIL*) FAIL=$((FAIL + 1)); echo "$line" ;;
        "") ;;
        *) PASS=$((PASS + 1)) ;;
    esac
done < <("$PY" "$TMP/unit.py" "$GUARD" 2>&1)

# --- fakes ---------------------------------------------------------------------------
BASE="$TMP/base"; FT="$TMP/ftmux"; mkdir -p "$BASE" "$FT"
for t in python3 bash dirname cat mkdir mv cp sleep env kill rm printf tr sed grep head jq find date; do
    p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$BASE/$t"
done
# fake tmux: records argv; -S <socket> accepted; display-message answers only for
# $FAKE_PANE_ID with the pid in $FAKE_PANE_PIDFILE (copy mode from $FAKE_STATE.mode when
# present, else $FAKE_IN_MODE); capture-pane serves the pane file named in $FAKE_STATE;
# send-keys -l renders the typed text into the input box (plus $FAKE_TYPE_BELOW and the
# lines of $FAKE_TYPE_BELOW_FILE under it,
# and $FAKE_MODE_AFTER_TYPE as the new copy-mode flag), Enter switches to $FAKE_AFTER_PANE.
# Enter of the /compact line with $FAKE_COMPACT_HOOK set runs that real SessionStart hook
# with source "compact" (the compaction finished) and switches to $FAKE_IDLE_AFTER_COMPACT.
# Enter of a "." records whether the wake file existed and, from the $FAKE_DOT_CLEARS_AT-th
# "." on, consumes it (what the UserPromptSubmit hook does when the turn starts).
cat > "$FT/tmux" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_TMUX_LOG"
[ "$1" = "-S" ] && shift 2
R="────────────────────────────────────────────────────────────"
case "$1" in
    display-message)
        [ "$4" = "$FAKE_PANE_ID" ] || exit 1
        mode="${FAKE_IN_MODE:-0}"; [ -f "$FAKE_STATE.mode" ] && mode="$(cat "$FAKE_STATE.mode")"
        printf '%s\t%s\t%s\t0\n' "$4" "$(cat "$FAKE_PANE_PIDFILE")" "$mode" ;;
    capture-pane)
        cat "$(cat "$FAKE_STATE")" ;;
    send-keys)
        if [ "$4" = "-l" ]; then
            printf '%s\n' "● Done." "" "$R" "❯ ${FAKE_TYPE_PREFIX:-}$5" "$R" ${FAKE_TYPE_BELOW:+"$FAKE_TYPE_BELOW"} > "$FAKE_STATE.typed"
            [ -n "${FAKE_TYPE_BELOW_FILE:-}" ] && cat "$FAKE_TYPE_BELOW_FILE" >> "$FAKE_STATE.typed"
            echo "$FAKE_STATE.typed" > "$FAKE_STATE"
            [ -n "${FAKE_MODE_AFTER_TYPE:-}" ] && echo "$FAKE_MODE_AFTER_TYPE" > "$FAKE_STATE.mode"
            printf '%s' "$5" > "$FAKE_STATE.last"
        elif [ "$4" = "Enter" ]; then
            last="$(cat "$FAKE_STATE.last" 2>/dev/null)"
            case "$last" in
                /compact*)
                    echo "$FAKE_AFTER_PANE" > "$FAKE_STATE"
                    if [ -n "${FAKE_COMPACT_HOOK:-}" ]; then
                        # the compaction finishes: Claude Code fires SessionStart "compact"
                        printf '{"session_id": "%s", "source": "compact", "cwd": "/"}' "$FAKE_SID" \
                            | CLAUDE_CONFIG_DIR="$FAKE_CFG" bash "$FAKE_COMPACT_HOOK" >/dev/null 2>&1
                        echo "$FAKE_IDLE_AFTER_COMPACT" > "$FAKE_STATE"
                    fi ;;
                .)
                    n=$(( $(cat "$FAKE_STATE.dots" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_STATE.dots"
                    if [ -e "$FAKE_WAKE_FILE" ]; then echo "wake-present" >> "$FAKE_TMUX_LOG.wake"; else echo "wake-missing" >> "$FAKE_TMUX_LOG.wake"; fi; [ -e "$FAKE_WAKE_FILE" ] && cp "$FAKE_WAKE_FILE" "$FAKE_TMUX_LOG.wakecopy"
                    if [ -n "${FAKE_DOT_CLEARS_AT:-}" ] && [ "$n" -ge "$FAKE_DOT_CLEARS_AT" ]; then rm -f "$FAKE_WAKE_FILE"; fi
                    echo "$FAKE_IDLE_AFTER_COMPACT" > "$FAKE_STATE" ;;
                *) echo "$FAKE_AFTER_PANE" > "$FAKE_STATE" ;;
            esac
        fi ;;
esac
exit 0
EOF
chmod +x "$FT/tmux"
export FAKE_TMUX_LOG="$TMP/tmux.log" CREDO_SELF_COMPACT_NTFY_URL=off CREDO_SKIP_ENSURE=1
export CREDO_SELF_COMPACT_POLL=0.2 CREDO_SELF_COMPACT_RECHECK=0.2 CREDO_SELF_COMPACT_KEY_PAUSE=0.1 \
    CREDO_SELF_COMPACT_CONFIRM_WAIT=2 CREDO_SELF_COMPACT_DONE_TIMEOUT=3
export CREDO_GLOBAL="$TMP/global.yaml" CREDO_PROFILE="$TMP/none-profile" CREDO_PROJECT="$TMP/none-project"
unset CREDO_SESSION_MODES_DIR CREDO_REHYDRATE_DIR
: > "$CREDO_GLOBAL"
R="────────────────────────────────────────────────────────────"
ELL="$(printf '\xe2\x80\xa6')"  # the TUI ellipsis character, kept out of the source
printf '%s\n' "● Done, fixture finished." "" "✻ Worked for 1m 5s" "" "$R" "❯ " "$R" "  ? for shortcuts" > "$TMP/idle.txt"
printf '%s\n' "● Working." "" "✻ Brewing$ELL (3s · ↓ 10 tokens)" "" "$R" "❯ " "$R" > "$TMP/busy.txt"
printf '%s\n' "● Done." "" "$R" "❯ a half typed user prompt" "$R" > "$TMP/typed.txt"
printf '%s\n' "● Pick one?" "" "❯ 1. Alpha" "  2. Beta" "" "Enter to select · Esc to cancel" > "$TMP/dialog.txt"
printf '%s\n' "● Done." "" "✢ Compacting conversation$ELL" "" "$R" "❯ " "$R" > "$TMP/after.txt"
printf '%s\n' "● Done." "" "$R" "❯ " "$R" "  ? for shortcuts · 2 shells" "  ◯ general-purpose  Fixture audit" > "$TMP/bg.txt"
export FAKE_AFTER_PANE="$TMP/after.txt" FAKE_STATE="$TMP/state" FAKE_PANE_ID=%5
export FAKE_COMPACT_HOOK="$SCRIPT_DIR/../hooks/credo-session-dir-record.sh" FAKE_IDLE_AFTER_COMPACT="$TMP/idle.txt" \
    FAKE_DOT_CLEARS_AT=1

SID="aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb"
CFG="$TMP/cfg"; mkdir -p "$CFG/credo/rehydrate" "$CFG/credo/session-modes"
export FAKE_SID="$SID" FAKE_CFG="$CFG" FAKE_WAKE_FILE="$CFG/credo/self-wake-$SID"
MODES="$CFG/credo/session-modes"; MARK="$CFG/credo/self-compact-$SID.json"; LOGF="$CFG/credo/self-compact-$SID.log"
cat > "$TMP/fake_target.py" <<'PYEOF'
import time
for _ in range(3000):
    time.sleep(0.1)
PYEOF
start_target() { # pidfile extra-env...
    local pidfile="$1"; shift
    (exec env -u TMUX -u TMUX_PANE CLAUDE_CONFIG_DIR="$CFG" "$@" bash -c 'exec -a claude "$0" "$@"' "$PY" "$TMP/fake_target.py") &
    local p=$!
    PIDS="$PIDS $p"
    echo "$p" > "$pidfile"
    sleep 0.3
}
gone() { local st; st="$(cat /proc/"$1"/stat 2>/dev/null)" || return 0; st="${st##*) }"; [ "${st%% *}" = "Z" ]; }
wait_status() { # pattern
    for _ in $(seq 1 75); do grep -q "$1" "$MARK" 2>/dev/null && return 0; sleep 0.2; done
    return 1
}
H() { # run the helper against target $TGT
    env CREDO_SELF_COMPACT_SESSION_ID=$SID CREDO_SELF_COMPACT_TARGET_PID="$TGT" PATH="$FT:$BASE" "$PY" "$HELPER" "$@" 2>&1
}

# --- check -------------------------------------------------------------------------
start_target "$TMP/t1.pid" TMUX=/tmp/fake-sock,1,0 TMUX_PANE=%5
TGT="$(cat "$TMP/t1.pid")"; export FAKE_PANE_PIDFILE="$TMP/t1.pid"
echo "$TMP/idle.txt" > "$FAKE_STATE"
out="$(env -u CLAUDE_CODE_SESSION_ID CREDO_SELF_COMPACT_TARGET_PID="$TGT" PATH="$FT:$BASE" "$PY" "$HELPER" check 2>&1)"; rc=$?
check "check no session id -> rc 1" "1" "$rc"
case "$out" in *"FAIL: no session id"*) ok "check no session id message" 0 ;; *) ok "check no session id message" 1 ;; esac
out="$(H check)"; rc=$?
check "check without breadcrumb -> rc 1" "1" "$rc"
case "$out" in *"no compact-plus breadcrumb for session $SID"*) ok "check breadcrumb message" 0 ;; *) ok "check breadcrumb message ($out)" 1 ;; esac
echo ".credo/process/handoffs/HANDOFF.md" > "$CFG/credo/rehydrate/$SID"
: > "$FAKE_TMUX_LOG"
out="$(H check)"; rc=$?
check "check ok -> rc 0" "0" "$rc"
case "$out" in *"own pane:     %5 (tmux socket /tmp/fake-sock)"*) ok "check names own pane + socket" 0 ;; *) ok "check names own pane ($out)" 1 ;; esac
case "$out" in *"typed text:   /compact Afterwards reload .credo/process/handoffs/HANDOFF.md (secured by compact-plus) and continue from it."*) ok "check shows typed text" 0 ;; *) ok "check shows typed text ($out)" 1 ;; esac
case "$out" in *"owner rule:   interactive -> ask once via the Ask tool"*) ok "check shows interactive owner rule" 0 ;; *) ok "check owner rule ($out)" 1 ;; esac
case "$out" in *"pane now:     idle, input empty"*) ok "check shows live pane state" 0 ;; *) ok "check live pane state ($out)" 1 ;; esac
grep -q -- "-S /tmp/fake-sock display-message -p -t %5" "$FAKE_TMUX_LOG"; ok "check uses the session's tmux socket" "$?"
check "check sends no keys" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"
# background shells / agents in the footer do not block self-compact -> idle
echo "$TMP/bg.txt" > "$FAKE_STATE"
out="$(H check)"
case "$out" in *"pane now:     idle, input empty"*) ok "check: background work does not block" 0 ;; *) ok "check: background work does not block ($out)" 1 ;; esac
case "$out" in *"no-background-work"*) ok "check: no --no-background-work hint" 1 ;; *) ok "check: no --no-background-work hint" 0 ;; esac
echo "$TMP/idle.txt" > "$FAKE_STATE"
# stale breadcrumb (older than the max age) -> refused; the max age is configurable
touch -d '3 hours ago' "$CFG/credo/rehydrate/$SID"
out="$(H check)"; rc=$?
check "check stale breadcrumb -> rc 1" "1" "$rc"
case "$out" in *"compact-plus breadcrumb for session $SID is older than 2h"*) ok "check stale breadcrumb message" 0 ;; *) ok "check stale breadcrumb message ($out)" 1 ;; esac
out="$(CREDO_SELF_COMPACT_BREADCRUMB_MAX_AGE=86400 H check)"; rc=$?
check "check stale breadcrumb, max age raised by env -> rc 0" "0" "$rc"
out="$(H check --max-breadcrumb-age 86400)"; rc=$?
check "check stale breadcrumb, max age raised by flag -> rc 0" "0" "$rc"
: > "$FAKE_TMUX_LOG"
out="$(H run --user-confirmed --delay 0.1)"; rc=$?
check "run stale breadcrumb -> rc 1" "1" "$rc"
check "run stale breadcrumb sends no keys" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"
# --handoff only replaces the typed path; it never skips the breadcrumb presence / age check
out="$(H check --handoff docs/fixture-handoff.md)"; rc=$?
check "check --handoff, stale breadcrumb -> rc 1" "1" "$rc"
case "$out" in *"compact-plus breadcrumb for session $SID is older than 2h"*) ok "check --handoff stale message" 0 ;; *) ok "check --handoff stale message ($out)" 1 ;; esac
out="$(H run --user-confirmed --handoff docs/fixture-handoff.md --delay 0.1)"; rc=$?
check "run --handoff, stale breadcrumb -> rc 1" "1" "$rc"
SID3="eeeeeeee-7777-8888-9999-ffffffffffff"
H3() { # like H, for session $SID3 (no breadcrumb)
    CREDO_SELF_COMPACT_SESSION_ID=$SID3 CREDO_SELF_COMPACT_TARGET_PID="$TGT" PATH="$FT:$BASE" "$PY" "$HELPER" "$@" 2>&1
}
out="$(H3 check --handoff docs/fixture-handoff.md)"; rc=$?
check "check --handoff, no breadcrumb -> rc 1" "1" "$rc"
case "$out" in *"no compact-plus breadcrumb for session $SID3"*) ok "check --handoff no-breadcrumb message" 0 ;; *) ok "check --handoff no-breadcrumb message ($out)" 1 ;; esac
out="$(H3 run --user-confirmed --handoff docs/fixture-handoff.md --delay 0.1)"; rc=$?
check "run --handoff, no breadcrumb -> rc 1" "1" "$rc"
check "--handoff refusals send no keys" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"
ok "--handoff refusals write no marker" "$([ ! -e "$CFG/credo/self-compact-$SID3.json" ] && [ ! -e "$MARK" ] && echo 0 || echo 1)"
touch "$CFG/credo/rehydrate/$SID"
out="$(H check --handoff docs/fixture-handoff.md)"; rc=$?
check "check --handoff, fresh breadcrumb -> rc 0" "0" "$rc"
case "$out" in *"typed text:   /compact Afterwards reload docs/fixture-handoff.md (secured"*) ok "check --handoff replaces the typed path" 0 ;; *) ok "check --handoff typed path ($out)" 1 ;; esac
# not in tmux
start_target "$TMP/t2.pid"
out="$(TGT="$(cat "$TMP/t2.pid")" H check)"; rc=$?
check "check not in tmux -> rc 1" "1" "$rc"
case "$out" in *"FAIL: not running inside tmux"*) ok "check not-in-tmux message" 0 ;; *) ok "check not-in-tmux message ($out)" 1 ;; esac
# foreign pane: the pane's process is an unrelated process
sleep 300 & SLP=$!; PIDS="$PIDS $SLP"; echo "$SLP" > "$TMP/foreign.pid"
out="$(FAKE_PANE_PIDFILE="$TMP/foreign.pid" H check)"; rc=$?
check "check foreign pane -> rc 1" "1" "$rc"
case "$out" in *"belongs to pid $SLP, which is not this Claude process"*) ok "check foreign pane message" 0 ;; *) ok "check foreign pane message ($out)" 1 ;; esac
: > "$FAKE_TMUX_LOG"
out="$(FAKE_PANE_PIDFILE="$TMP/foreign.pid" H run --user-confirmed --delay 0.1)"; rc=$?
check "run foreign pane -> rc 1" "1" "$rc"
check "run foreign pane sends no keys" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"
# pane whose process is an ancestor (the shell the pane started) is accepted
echo "$$" > "$TMP/self.pid"
start_target "$TMP/t3.pid" TMUX=/tmp/fake-sock,1,0 TMUX_PANE=%5
out="$(FAKE_PANE_PIDFILE="$TMP/self.pid" TGT="$(cat "$TMP/t3.pid")" H check)"; rc=$?
check "check pane pid = ancestor shell -> rc 0" "0" "$rc"
# a nested Claude: the pane's shell -> outer claude -> inner claude (the target). The pane
# shows the OUTER session, so the inner one must never type into it.
cat > "$TMP/fake_outer.py" <<'PYEOF'
import os, subprocess, sys
p = subprocess.Popen(["bash", "-c", 'exec -a claude "$0" "$1"', os.readlink("/proc/self/exe"),
                      sys.argv[1]])
open(sys.argv[2], "w").write(str(p.pid))
p.wait()
PYEOF
(exec env CLAUDE_CONFIG_DIR="$CFG" TMUX=/tmp/fake-sock,1,0 TMUX_PANE=%5 bash -c 'exec -a claude "$0" "$@"' "$PY" "$TMP/fake_outer.py" "$TMP/fake_target.py" "$TMP/inner.pid") &
OUTER=$!; PIDS="$PIDS $OUTER"
for _ in $(seq 1 50); do [ -s "$TMP/inner.pid" ] && break; sleep 0.1; done
INNER="$(cat "$TMP/inner.pid")"; PIDS="$PIDS $INNER"; sleep 0.2
out="$(FAKE_PANE_PIDFILE="$TMP/self.pid" TGT="$INNER" H check)"; rc=$?
check "check nested claude -> rc 1" "1" "$rc"
case "$out" in *"another Claude process (pid $OUTER) runs between"*) ok "check nested claude message" 0 ;; *) ok "check nested claude message ($out)" 1 ;; esac
: > "$FAKE_TMUX_LOG"
out="$(FAKE_PANE_PIDFILE="$TMP/self.pid" TGT="$INNER" H run --user-confirmed --delay 0.1)"; rc=$?
check "run nested claude -> rc 1" "1" "$rc"
check "run nested claude sends no keys" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"
kill -TERM "$INNER" "$OUTER" 2>/dev/null
# unknown pane id on the server
out="$(FAKE_PANE_ID=%99 H check)"; rc=$?
check "check pane missing on server -> rc 1" "1" "$rc"

# --- owner rule ---------------------------------------------------------------------
: > "$FAKE_TMUX_LOG"; rm -f "$MARK" "$MODES/$SID"
out="$(H run)"; rc=$?
check "run without flag -> rc 3" "3" "$rc"
case "$out" in *"exactly one of --auto or --user-confirmed"*"Nothing was started."*) ok "run without flag message" 0 ;; *) ok "run without flag message ($out)" 1 ;; esac
out="$(H run --auto --user-confirmed)"; rc=$?
check "run with both flags -> rc 3" "3" "$rc"
out="$(H run --auto)"; rc=$?
check "run --auto, mode not set -> rc 3" "3" "$rc"
case "$out" in *"only allowed when the credo session mode of this session is autonomous (it is not set)"*"--user-confirmed"*) ok "run --auto refusal message" 0 ;; *) ok "run --auto refusal message ($out)" 1 ;; esac
for m in active passive; do
    echo "$m" > "$MODES/$SID"
    out="$(H run --auto)"; rc=$?
    check "run --auto in $m mode -> rc 3" "3" "$rc"
done
rm -f "$MODES/$SID"
ok "refusals write no marker" "$([ ! -e "$MARK" ] && echo 0 || echo 1)"
check "refusals send no keys" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"

# --- worker: autonomous, idle -> types into the own pane, verifies, Enter -------------
echo autonomous > "$MODES/$SID"; echo "$TMP/idle.txt" > "$FAKE_STATE"; : > "$FAKE_TMUX_LOG"
out="$(H run --auto --delay 0.1)"; rc=$?
check "run --auto autonomous (no --no-background-work) -> rc 0" "0" "$rc"
case "$out" in *"End your turn now."*) ok "run tells the agent to end the turn" 0 ;; *) ok "run end-turn line ($out)" 1 ;; esac
wait_status '"status": "woken"'; ok "auto: marker woken (compact done, '.' sent)" "$?"
TEXT="/compact Afterwards reload .credo/process/handoffs/HANDOFF.md (secured by compact-plus) and continue from it."
grep -qxF -- "-S /tmp/fake-sock send-keys -t %5 -l $TEXT" "$FAKE_TMUX_LOG"; ok "auto: typed /compact literally into %5" "$?"
grep -qxF -- "-S /tmp/fake-sock send-keys -t %5 Enter" "$FAKE_TMUX_LOG"; ok "auto: Enter sent to %5" "$?"
check "auto: exactly four send-keys (/compact, Enter, '.', Enter)" "4" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"
grep -qxF -- "-S /tmp/fake-sock send-keys -t %5 -l ." "$FAKE_TMUX_LOG"; ok "auto: '.' typed after the compact" "$?"
check "auto: wake file existed before the '.' Enter" "wake-present" "$(cat "$FAKE_TMUX_LOG.wake")"
check "auto: every tmux call targets %5 only" "0" "$(grep -- '-t ' "$FAKE_TMUX_LOG" | grep -vc -- '-t %5')"
check "auto: every tmux call uses the session socket" "0" "$(grep -vc '^-S /tmp/fake-sock ' "$FAKE_TMUX_LOG")"
"$PY" - "$FAKE_TMUX_LOG" <<'PYEOF'
import sys
lines = open(sys.argv[1]).read().splitlines()
typed = [i for i, l in enumerate(lines) if " send-keys -t %5 -l " in l][0]
enter = [i for i, l in enumerate(lines) if l.endswith("send-keys -t %5 Enter")][0]
caps = [i for i, l in enumerate(lines) if "capture-pane" in l]
assert sum(1 for i in caps if i < typed) >= 2, "two idle probes before typing"
assert any(typed < i < enter for i in caps), "input verified between typing and Enter"
PYEOF
ok "auto: two probes before typing, verification before Enter" "$?"
grep -q '"mode": "auto"' "$MARK"; ok "auto: marker records mode" "$?"

# --- worker: typed user text -> waits, gives up, nothing typed ------------------------
rm -f "$MODES/$SID"; echo "$TMP/typed.txt" > "$FAKE_STATE"; : > "$FAKE_TMUX_LOG"
out="$(H run --user-confirmed --delay 0.1 --timeout 1.5)"; rc=$?
check "typed: run --user-confirmed -> rc 0" "0" "$rc"
wait_status '"status": "failed: not idle"'; ok "typed: marker failed: not idle" "$?"
check "typed: no keys sent" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"
grep -q "pane state: input not empty" "$LOGF"; ok "typed: reason logged" "$?"
grep -q '"mode": "user-confirmed"' "$MARK"; ok "typed: marker records user-confirmed" "$?"

# --- worker: copy mode -> never safe -------------------------------------------------
echo "$TMP/idle.txt" > "$FAKE_STATE"; : > "$FAKE_TMUX_LOG"
out="$(FAKE_IN_MODE=1 H run --user-confirmed --delay 0.1 --timeout 1.2)"
wait_status '"status": "failed: not idle"'; ok "copy mode: gives up" "$?"
check "copy mode: no keys sent" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"

# --- worker: dialog open -> waits; cancel stops it ------------------------------------
echo "$TMP/dialog.txt" > "$FAKE_STATE"; : > "$FAKE_TMUX_LOG"
out="$(H run --user-confirmed --delay 0.1 --timeout 60)"
sleep 1
out="$(H run --user-confirmed --delay 0.1)"; rc=$?
check "second run while pending -> rc 1" "1" "$rc"
out="$(TGT="$TGT" H status)"
case "$out" in "state: pending; pane: %5"*) ok "status shows pending" 0 ;; *) ok "status shows pending ($out)" 1 ;; esac
WPID="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["worker_pid"])' "$MARK")"
SID2="cccccccc-4444-5555-6666-dddddddddddd"
out="$(env CREDO_SELF_COMPACT_SESSION_ID=$SID2 CREDO_SELF_COMPACT_TARGET_PID="$TGT" PATH="$FT:$BASE" "$PY" "$HELPER" cancel 2>&1)"; rc=$?
check "cancel from another session -> rc 1" "1" "$rc"
case "$out" in *"nothing to cancel"*) ok "cancel from another session: nothing to cancel" 0 ;; *) ok "cancel from another session message ($out)" 1 ;; esac
ok "cancel from another session: worker still running" "$(gone "$WPID" && echo 1 || echo 0)"
grep -q '"status": "pending"' "$MARK"; ok "cancel from another session: marker still pending" "$?"
out="$(H cancel)"; rc=$?
check "cancel -> rc 0" "0" "$rc"
case "$out" in *"worker $WPID terminated"*) ok "cancel terminates the worker" 0 ;; *) ok "cancel message ($out)" 1 ;; esac
sleep 0.5
ok "cancel: worker gone" "$(gone "$WPID" && echo 0 || echo 1)"
check "dialog: no keys sent" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"
out="$(H cancel)"; rc=$?
check "cancel with nothing pending -> rc 1" "1" "$rc"

# --- worker: busy first, idle later -> types only after idle ---------------------------
echo "$TMP/busy.txt" > "$FAKE_STATE"; : > "$FAKE_TMUX_LOG"
out="$(H run --user-confirmed --delay 0.1 --timeout 30)"
sleep 1.2
check "busy: no keys while busy" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"
echo "$TMP/idle.txt" > "$FAKE_STATE"
wait_status '"status": "woken"'; ok "busy -> idle: sent and woken" "$?"
grep -q "pane state: busy: ✻ Brewing" "$LOGF"; ok "busy: state logged" "$?"

# --- worker: input changed between typing and Enter -> NO Enter -----------------------
echo "$TMP/idle.txt" > "$FAKE_STATE"; : > "$FAKE_TMUX_LOG"
out="$(FAKE_TYPE_PREFIX="user words " H run --user-confirmed --delay 0.1)"
wait_status '"status": "failed: typed text not confirmed"'; ok "mismatch: marker failed" "$?"
check "mismatch: no Enter sent" "0" "$(grep -c 'send-keys -t %5 Enter' "$FAKE_TMUX_LOG")"
check "mismatch: user text never taken back" "0" "$(grep -c BSpace "$FAKE_TMUX_LOG")"

# --- worker: dialog or copy mode right after typing -> the full assess says no Enter ----
echo "$TMP/idle.txt" > "$FAKE_STATE"; : > "$FAKE_TMUX_LOG"
out="$(FAKE_TYPE_BELOW="  Enter to confirm · Esc to cancel" H run --user-confirmed --delay 0.1)"
wait_status '"status": "failed: typed text not confirmed"'; ok "dialog after typing: marker failed" "$?"
check "dialog after typing: no Enter sent" "0" "$(grep -c 'send-keys -t %5 Enter' "$FAKE_TMUX_LOG")"
check "dialog after typing: nothing taken back (keys would hit the dialog)" "0" "$(grep -c BSpace "$FAKE_TMUX_LOG")"
grep -q "dialog or menu open" "$LOGF"; ok "dialog after typing: reason logged" "$?"
echo "$TMP/idle.txt" > "$FAKE_STATE"; : > "$FAKE_TMUX_LOG"
out="$(FAKE_MODE_AFTER_TYPE=1 H run --user-confirmed --delay 0.1)"
wait_status '"status": "failed: typed text not confirmed"'; ok "copy mode after typing: marker failed" "$?"
check "copy mode after typing: no Enter sent" "0" "$(grep -c 'send-keys -t %5 Enter' "$FAKE_TMUX_LOG")"
check "copy mode after typing: nothing taken back (keys would hit copy mode)" "0" "$(grep -c BSpace "$FAKE_TMUX_LOG")"
rm -f "$FAKE_STATE.mode"

# --- worker: background agents / shells in the footer -> still types and sends --------
# (they survive /compact; self-compact never waits for them). The old flag is accepted.
echo "$TMP/bg.txt" > "$FAKE_STATE"; : > "$FAKE_TMUX_LOG"
export FAKE_TYPE_BELOW_FILE="$TMP/bgfoot.txt"
printf '%s\n' "  ? for shortcuts · 2 shells" "  ◯ general-purpose  Fixture audit" "  ◯ monitor  Fixture log" > "$FAKE_TYPE_BELOW_FILE"
out="$(H run --user-confirmed --no-background-work --delay 0.1)"; rc=$?
check "background: run (old flag accepted) -> rc 0" "0" "$rc"
wait_status '"status": "woken"'; ok "background: marker woken" "$?"
grep -qxF -- "-S /tmp/fake-sock send-keys -t %5 Enter" "$FAKE_TMUX_LOG"; ok "background: Enter sent" "$?"
grep -q "background work running" "$LOGF"; ok "background: never logged as blocking" "$([ $? -eq 0 ] && echo 1 || echo 0)"
unset FAKE_TYPE_BELOW_FILE

# --- cancel checks the session id inside the marker -----------------------------------
printf '{"status": "pending", "session_id": "%s", "started": "x"}' "$SID2" > "$MARK"
out="$(H cancel)"; rc=$?
check "cancel: marker of another session id -> rc 1" "1" "$rc"
grep -q '"status": "pending"' "$MARK"; ok "cancel: foreign marker untouched" "$?"
rm -f "$MARK"

# --- worker: target dies while waiting -> abort, nothing typed ------------------------
start_target "$TMP/t4.pid" TMUX=/tmp/fake-sock,1,0 TMUX_PANE=%5
T4="$(cat "$TMP/t4.pid")"
echo "$TMP/busy.txt" > "$FAKE_STATE"; : > "$FAKE_TMUX_LOG"
out="$(FAKE_PANE_PIDFILE="$TMP/t4.pid" TGT="$T4" H run --user-confirmed --delay 0.1 --timeout 30)"
sleep 0.6; kill -TERM "$T4" 2>/dev/null; echo "$TMP/idle.txt" > "$FAKE_STATE"
wait_status '"status": "failed: pane ownership"'; ok "target gone: marker failed: pane ownership" "$?"
check "target gone: no keys sent" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"

# --- SessionStart "compact" hook: compact-done only for a pending self-compact ---------
HOOKSS="$SCRIPT_DIR/../hooks/credo-session-dir-record.sh"
SIDH="ffffffff-0000-1111-2222-333333333333"; MH="$CFG/credo/self-compact-$SIDH.json"; DH="$CFG/credo/self-compact-done-$SIDH"
ss() { printf '{"session_id": "%s", "source": "%s", "cwd": "/"}' "$SIDH" "$1" | CLAUDE_CONFIG_DIR="$CFG" PATH="$BASE" bash "$HOOKSS" >/dev/null 2>&1; }
ss compact
ok "hook: no marker -> no compact-done" "$([ ! -e "$DH" ] && echo 0 || echo 1)"
printf '{"status": "typing", "session_id": "%s"}' "$SIDH" > "$MH"
ss startup
ok "hook: source startup -> no compact-done" "$([ ! -e "$DH" ] && echo 0 || echo 1)"
for st in cancelled "failed: not idle" woken; do
    printf '{"status": "%s", "session_id": "%s"}' "$st" "$SIDH" > "$MH"; ss compact
    ok "hook: marker '$st' -> no compact-done" "$([ ! -e "$DH" ] && echo 0 || echo 1)"
done
for st in typing sent "sent (unconfirmed)"; do
    printf '{"status": "%s", "session_id": "%s"}' "$st" "$SIDH" > "$MH"; ss compact
    ok "hook: marker '$st' + compact -> compact-done" "$([ -s "$DH" ] && echo 0 || echo 1)"
    rm -f "$DH"
done
# without jq the done signal still works (grep/sed fallback)
NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
for t in bash cat grep sed head date mv find mkdir printf; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOJQ/$t"
done
ssnj() { printf '{"session_id": "%s", "source": "%s", "cwd": "/"}' "$SIDH" "$1" | CLAUDE_CONFIG_DIR="$CFG" PATH="$NOJQ" bash "$HOOKSS" >/dev/null 2>&1; }
printf '{"status": "sent", "session_id": "%s"}' "$SIDH" > "$MH"; ssnj compact
ok "hook without jq: marker 'sent' + compact -> compact-done" "$([ -s "$DH" ] && echo 0 || echo 1)"
rm -f "$DH"
printf '{"status": "cancelled", "session_id": "%s"}' "$SIDH" > "$MH"; ssnj compact
ok "hook without jq: marker 'cancelled' -> no compact-done" "$([ ! -e "$DH" ] && echo 0 || echo 1)"
printf '{"status": "typing", "session_id": "%s"}' "$SIDH" > "$MH"; ssnj startup
ok "hook without jq: source startup -> no compact-done" "$([ ! -e "$DH" ] && echo 0 || echo 1)"
rm -f "$MH"

# --- wake after the compact -----------------------------------------------------------
wreset() { # pane file
    echo "$1" > "$FAKE_STATE"; : > "$FAKE_TMUX_LOG"
    rm -f "$FAKE_TMUX_LOG.wake" "$FAKE_TMUX_LOG.wakecopy" "$FAKE_STATE.dots" "$FAKE_STATE.last" "$FAKE_WAKE_FILE" "$MARK"
}
dots() { grep -cxF -- "-S /tmp/fake-sock send-keys -t %5 -l ." "$FAKE_TMUX_LOG"; }
touch "$CFG/credo/rehydrate/$SID"; rm -f "$MODES/$SID"
# happy path: the wake file says compact + compact_done, the turn started -> woken
wreset "$TMP/idle.txt"
out="$(H run --user-confirmed --delay 0.1)"
wait_status '"status": "woken"'; ok "wake: woken" "$?"
grep -q '"kind": "compact"' "$FAKE_TMUX_LOG.wakecopy"; ok "wake: wake file kind compact" "$?"
grep -q '"compact_done": true' "$FAKE_TMUX_LOG.wakecopy"; ok "wake: wake file records compact_done" "$?"
check "wake: exactly one '.'" "1" "$(dots)"
# fallback: the first "." does not start a turn -> re-sent after the nudge wait
wreset "$TMP/idle.txt"
out="$(FAKE_DOT_CLEARS_AT=2 H run --user-confirmed --delay 0.1 --nudge-wait 0.8)"
wait_status '"status": "woken"'; ok "wake fallback: woken" "$?"
check "wake fallback: two '.'" "2" "$(dots)"
# a turn already started after the compact (e.g. a task notification): no "." at all
wreset "$TMP/idle.txt"
out="$(FAKE_IDLE_AFTER_COMPACT="$TMP/busy.txt" H run --user-confirmed --delay 0.1)"
for _ in $(seq 1 50); do [ -e "$FAKE_WAKE_FILE" ] && break; sleep 0.2; done
ok "turn started: wake file written while busy" "$([ -e "$FAKE_WAKE_FILE" ] && echo 0 || echo 1)"
rm -f "$FAKE_WAKE_FILE"; sleep 0.5; echo "$TMP/idle.txt" > "$FAKE_STATE"
wait_status '"status": "woken"'; ok "turn started: woken" "$?"
sleep 1
check "turn started: no '.' typed" "0" "$(dots)"
# no compact-done signal in time, pane idle -> "." anyway (the agent checks the compact)
wreset "$TMP/idle.txt"
out="$(FAKE_COMPACT_HOOK= FAKE_AFTER_PANE="$TMP/idle.txt" H run --user-confirmed --delay 0.1)"
wait_status '"status": "woken"'; ok "no signal, idle: woken" "$?"
check "no signal, idle: one '.'" "1" "$(dots)"
grep -q '"compact_done": false' "$FAKE_TMUX_LOG.wakecopy"; ok "no signal, idle: wake file says compact_done false" "$?"
grep -q "no compact-done signal" "$LOGF"; ok "no signal, idle: logged" "$?"
# no compact-done signal, pane NOT idle -> nothing typed, failure + ntfy
wreset "$TMP/idle.txt"
out="$(FAKE_COMPACT_HOOK= H run --user-confirmed --delay 0.1)"
wait_status '"status": "failed: compact not confirmed'; ok "no signal, busy: failed" "$?"
check "no signal, busy: no '.'" "0" "$(dots)"
grep -q "ntfy disabled: credo: self-compact wake failed" "$LOGF"; ok "no signal, busy: ntfy path used" "$?"
ok "no signal, busy: no wake file" "$([ ! -e "$FAKE_WAKE_FILE" ] && echo 0 || echo 1)"
# cancel while waking removes the wake file
wreset "$TMP/idle.txt"
out="$(FAKE_DOT_CLEARS_AT=99 H run --user-confirmed --delay 0.1 --nudge-wait 30)"
for _ in $(seq 1 75); do [ -e "$FAKE_WAKE_FILE" ] && grep -q '"status": "waking"' "$MARK" && break; sleep 0.2; done
out="$(H cancel)"; rc=$?
check "cancel while waking -> rc 0" "0" "$rc"
ok "cancel removes the wake file" "$([ ! -e "$FAKE_WAKE_FILE" ] && echo 0 || echo 1)"
# a pending self-reload of this session blocks a self-compact (same pane, same wake file)
RMARK="$CFG/credo/self-reload-$SID.json"
"$PY" -c 'import time; time.sleep(30)' _worker /fixture/credo-self-reload.py &
RW=$!; PIDS="$PIDS $RW"; sleep 0.2
printf '{"status": "waking", "session_id": "%s", "worker_pid": %s}' "$SID" "$RW" > "$RMARK"
wreset "$TMP/idle.txt"
out="$(H run --user-confirmed --delay 0.1)"; rc=$?
check "pending self-reload -> self-compact refused" "1" "$rc"
case "$out" in *"self-reload"*"pending"*) ok "refusal names the self-reload" 0 ;; *) ok "refusal names the self-reload ($out)" 1 ;; esac
check "refused: no keys" "0" "$(grep -c 'send-keys' "$FAKE_TMUX_LOG")"
kill "$RW" 2>/dev/null; rm -f "$RMARK"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
