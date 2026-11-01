#!/bin/bash
# Tests for credo-reminder.py and hooks/credo-reminder.sh: the periodic reminder prompt
# typed into the session's OWN tmux pane. Settings come from the credo config (key
# reminder, per credo mode); the test writes its own global config layer.
#
# NOTHING real is ever typed into: tmux is a FAKE binary first on a restricted PATH
# (it keeps the input box in a file, records every key and serves invented frames),
# every target is a FAKE process this test starts itself (argv[0] "claude"), config
# dirs are temp dirs, ntfy is off. No real tmux pane is ever addressed.
#
# It checks:
#   - pure: the per-mode triggers (turns, minutes, both), the prompt text, which prompts
#     count as a user turn, when a trigger is due
#   - hook wiring: UserPromptSubmit runs the turn counter, SessionStart the start
#   - off by default: the builtin config has every mode off -> no state file, no worker
#   - turn counting: the 10th real user turn arms the session for good; injected reminders,
#     bare ".", automated prompts and blank prompts do not count
#   - outside tmux a session never arms
#   - SessionStart start: a worker for an armed session, one worker per session
#   - injection when a trigger is due: idle + empty input -> the prompt is typed and
#     submitted; typed user text, a busy turn or a dialog -> nothing typed; one visible
#     character counts as empty, the reminder is then never submitted with it and the own
#     text is taken back again
#   - turns trigger: after the mode's turns since the last reminder, once idle; the
#     reminder itself is no user turn
#   - minutes trigger (shortened to 1.2 s): every interval, counted from the last reminder
#   - mode filter: a mode without a trigger, or no mode at all, gets no reminder
#   - text: reminder.text replaces the text after the marker
#   - the worker stops when the config turns the reminder off, and when the Claude process
#     of its session is gone
#
# Usage: bash test-credo-reminder.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/credo-reminder.py"
HOOK_SH="$SCRIPT_DIR/../hooks/credo-reminder.sh"
HOOKS_JSON="$SCRIPT_DIR/../hooks/hooks.json"
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "SKIP: python3 not found"; exit 0; fi
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
[ -f "$HELPER" ] || { echo "FAIL: $HELPER missing"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/crem.XXXXXX")"
PIDS=""
worker_pid_of() { sed -n 's/^  "worker_pid": \([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -1; }
cleanup() {
    for f in "${CFG:-$TMP/none}"/credo/reminder-*.json; do
        [ -f "$f" ] || continue
        p="$(worker_pid_of "$f")"
        [ -n "$p" ] && kill -TERM "$p" 2>/dev/null
    done
    for p in $PIDS; do kill -TERM "$p" 2>/dev/null || true; done
    sleep 0.3
    case "$TMP" in
        "${TMPDIR:-/tmp}"/crem.??????) rm -rf -- "$TMP" ;;
        *) echo "refusing to remove unexpected temp root: '$TMP'" >&2 ;;
    esac
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
wait_for() { # tries command...  (0.2 s apart)
    local n="$1"; shift
    for _ in $(seq 1 "$n"); do "$@" && return 0; sleep 0.2; done
    return 1
}

# --- pure: triggers, prompt text, turn classification, due check -----------------------
"$PY" - "$HELPER" <<'PYEOF'
import importlib.util, sys
s = importlib.util.spec_from_file_location("r", sys.argv[1])
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
assert m.parse_triggers(None) == {} and m.parse_triggers({}) == {}
assert m.parse_triggers({"active": {"turns": 10}, "passive": {"turns": "10"},
                         "autonomous": {"minutes": 60}, "text": ""}) == {
    "active": {"turns": 10, "minutes": None}, "passive": {"turns": 10, "minutes": None},
    "autonomous": {"turns": None, "minutes": 60.0}}
assert m.parse_triggers({"active": {}, "passive": {"turns": 0}, "autonomous": {"turns": True},
                         "bogus": {"turns": 2}}) == {}
assert m.parse_triggers({"autonomous": {"minutes": "nan"}}) == {}
assert m.parse_triggers({"active": {"turns": 3, "minutes": 5}}) == {
    "active": {"turns": 3, "minutes": 5.0}}
assert m.DEFAULT_TEXT == ("Check yourself against what we agreed: re-read the credo rules, the open "
    "items, the requirements logs and the handoff - did you keep every agreement so far, "
    "also those from before a compact or from earlier days, and did you declare a blocker "
    "or showstopper that our agreements say is none? A newer decision always overrides an "
    "older one on the same point (e.g. a limit raised from 3 to 6 means 6 now applies), so "
    "drop superseded agreements instead of carrying them along. Make sure every standing "
    "agreement is carried into the current handoff so it survives compacts and does not go "
    "stale in an old requirements file. Check the open-codes footer and drop every code that is "
    "answered, verified, superseded, moved into an item or moot. "
    "Keep credo's output format unless something speaks against it: every test, question and veto code carries its emoji wherever it asks something of the user (🧪 T5, ❓ Q4, ✋ V2 in headings, Ask text and mentions), and the reply ends with the open-codes footer. Clean up merged worktrees and branches with credo-worktree-cleanup.sh; a worktree that may still be needed goes to the owner as a question. If anything drifted, fix it now "
    "and continue as agreed.")
assert m.reminder_prompt(None) == "[credo-reminder] " + m.DEFAULT_TEXT
assert m.reminder_prompt("   ") == m.reminder_prompt(None)
assert m.reminder_prompt("Check the\n  rules now") == "[credo-reminder] Check the rules now"
for p in ("hello, please check", "please ignore [credo-reminder] stuff"):
    assert m.is_user_turn(p), p
for p in ("[credo-reminder] x", ".", " . ", "   ", "[CREDO-AUTONOMY-WAKE] standby",
          "<task-notification>x</task-notification>",
          '<cross-session-message from="x">hi</cross-session-message>',
          "[SYSTEM NOTIFICATION - NOT USER INPUT] x", "[Cross-session idle notice] x",
          "[Cross-session delivery notice] x"):
    assert not m.is_user_turn(p), p
turns = {"turns": 10, "minutes": None}
mins = {"turns": None, "minutes": 1.0}
both = {"turns": 3, "minutes": 1.0}
assert m.trigger_due(turns, 20, 10, 0, None) and not m.trigger_due(turns, 19, 10, 0, None)
assert m.trigger_due(mins, 0, 0, 1060.0, 1000.0) and not m.trigger_due(mins, 0, 0, 1059.9, 1000.0)
assert not m.trigger_due(mins, 0, 0, 5000.0, None)
assert m.trigger_due(both, 13, 10, 0, None) and m.trigger_due(both, 10, 10, 1060.0, 1000.0)
assert not m.trigger_due(both, 12, 10, 1030.0, 1000.0)
PYEOF
ok "pure: triggers, prompt text, turn classification, due check" "$?"

# --- hook wiring ---------------------------------------------------------------------
[ -x "$HOOK_SH" ]; ok "hook wrapper is executable" "$?"
jq -e '[.hooks.UserPromptSubmit[].hooks[].command] | any(. == "${CLAUDE_PLUGIN_ROOT}/hooks/credo-reminder.sh turn")' "$HOOKS_JSON" >/dev/null
ok "UserPromptSubmit runs the turn counter" "$?"
jq -e '[.hooks.SessionStart[].hooks[].command] | any(. == "${CLAUDE_PLUGIN_ROOT}/hooks/credo-reminder.sh start")' "$HOOKS_JSON" >/dev/null
ok "SessionStart starts the worker" "$?"

# --- fakes ---------------------------------------------------------------------------
BASE="$TMP/base"; FT="$TMP/ftmux"; mkdir -p "$BASE" "$FT"
for t in python3 bash dirname cat mkdir mv cp sleep env kill rm printf tr sed grep head seq date awk; do
    p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$BASE/$t"
done
# fake tmux: the input box is the file $FAKE_BUF (typed text, BSpace removes characters
# from its end, Enter submits it into $FAKE_SUBMITS and empties it); the lines above the
# box come from $FAKE_ABOVE; $FAKE_BUFLOG gets the box content after every key.
cat > "$FT/tmux" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_TMUX_LOG"
[ "$1" = "-S" ] && shift 2
R="────────────────────────────────────────────────────────────"
case "$1" in
    display-message)
        [ "$4" = "$FAKE_PANE_ID" ] || exit 1
        printf '%s\t%s\t0\t0\n' "$4" "$(cat "$FAKE_PANE_PIDFILE")" ;;
    capture-pane)
        cat "$FAKE_ABOVE"
        printf '%s\n' "$R" "❯ $(cat "$FAKE_BUF" 2>/dev/null)" "$R" "  ? for shortcuts" ;;
    send-keys)
        case "$4" in
            -l) printf '%s' "$5" >> "$FAKE_BUF" ;;
            End) ;;
            Enter)
                buf="$(cat "$FAKE_BUF" 2>/dev/null)"
                [ -n "$buf" ] && printf '%s\n' "$buf" >> "$FAKE_SUBMITS"
                : > "$FAKE_BUF" ;;
            *)
                buf="$(cat "$FAKE_BUF" 2>/dev/null)"
                for _ in "${@:4}"; do buf="${buf%?}"; done
                printf '%s' "$buf" > "$FAKE_BUF" ;;
        esac
        printf '%s\n' "$(cat "$FAKE_BUF" 2>/dev/null)" >> "$FAKE_BUFLOG" ;;
esac
exit 0
EOF
chmod +x "$FT/tmux"
cat > "$TMP/fake_target.py" <<'PYEOF'
import time
for _ in range(3000):
    time.sleep(0.1)
PYEOF
start_target() { # pidfile extra-env...   (a fake Claude process in its own env)
    local pidfile="$1"; shift
    (exec env -u TMUX -u TMUX_PANE CLAUDE_CONFIG_DIR="$CFG" "$@" bash -c 'exec -a claude "$0" "$@"' "$PY" "$TMP/fake_target.py") &
    local p=$!
    PIDS="$PIDS $p"
    echo "$p" > "$pidfile"
    sleep 0.3
}

R="────────────────────────────────────────────────────────────"
DEF="[credo-reminder] Check yourself against what we agreed: re-read the credo rules, the open items, the requirements logs and the handoff - did you keep every agreement so far, also those from before a compact or from earlier days, and did you declare a blocker or showstopper that our agreements say is none? A newer decision always overrides an older one on the same point (e.g. a limit raised from 3 to 6 means 6 now applies), so drop superseded agreements instead of carrying them along. Make sure every standing agreement is carried into the current handoff so it survives compacts and does not go stale in an old requirements file. Check the open-codes footer and drop every code that is answered, verified, superseded, moved into an item or moot. Keep credo's output format unless something speaks against it: every test, question and veto code carries its emoji wherever it asks something of the user (🧪 T5, ❓ Q4, ✋ V2 in headings, Ask text and mentions), and the reply ends with the open-codes footer. Clean up merged worktrees and branches with credo-worktree-cleanup.sh; a worktree that may still be needed goes to the owner as a question. If anything drifted, fix it now and continue as agreed."
printf '%s\n' "● Done, fixture finished." "" > "$TMP/above_idle.txt"
printf '%s\n' "● Working on the fixture." "" "✻ Brewing... (3s · ↓ 10 tokens)" "" > "$TMP/above_busy.txt"
printf '%s\n' "● Done." "" "Do you want to proceed?" "❯ 1. Yes" "  2. No" "" > "$TMP/above_dialog.txt"
export FAKE_TMUX_LOG="$TMP/tmux.log" FAKE_ABOVE="$TMP/above.txt" FAKE_BUF="$TMP/buf.txt" \
    FAKE_SUBMITS="$TMP/submits.txt" FAKE_BUFLOG="$TMP/buflog.txt" FAKE_PANE_ID=%5
cp "$TMP/above_idle.txt" "$FAKE_ABOVE"
: > "$FAKE_SUBMITS"; : > "$FAKE_BUF"; : > "$FAKE_TMUX_LOG"; : > "$FAKE_BUFLOG"
unset CREDO_SESSION_MODES_DIR CREDO_CONFIG_SCRIPT
export CREDO_GLOBAL="$TMP/global.yaml" CREDO_PROFILE="$TMP/none-profile" CREDO_PROJECT="$TMP/none-project" \
    CREDO_SKIP_ENSURE=1 CREDO_REMINDER_NTFY_URL=off CREDO_REMINDER_POLL=0.2 CREDO_REMINDER_RECHECK=0.2 \
    CREDO_REMINDER_KEY_PAUSE=0.1 CREDO_REMINDER_CONFIRM_WAIT=0.5 CREDO_REMINDER_BLOCKED_NOTIFY=0.5 \
    CREDO_REMINDER_REFRESH=1
: > "$CREDO_GLOBAL"

SID="aaaaaaaa-1111-2222-3333-cccccccccccc"
SID_D="aaaaaaaa-1111-2222-3333-dddddddddddd"
SID_P="aaaaaaaa-1111-2222-3333-pppppppppppp"
SID_T="aaaaaaaa-1111-2222-3333-tttttttttttt"
SID_H="aaaaaaaa-1111-2222-3333-hhhhhhhhhhhh"
SID_O="aaaaaaaa-1111-2222-3333-oooooooooooo"
SID_E="aaaaaaaa-1111-2222-3333-eeeeeeeeeeee"
SID_X="aaaaaaaa-1111-2222-3333-xxxxxxxxxxxx"
CFG="$TMP/cfg"; MODES="$CFG/credo/session-modes"; mkdir -p "$MODES"
TGT=""

# the credo config layer of the test (printf %b: \n is a newline)
cfg() { printf '%b' "$1" > "$CREDO_GLOBAL"; }
mode_of() { printf '%s\n' "$2" > "$MODES/$1"; }
# one hook call: $1 turn|start, $2 session id, $3 prompt (turn) or source (start);
# the caller's env is kept, the Claude process is $TGT
hook() { # from a directory outside any git repo, without a project dir of the caller
    local ev="$1" sid="$2" arg="$3"
    (
        cd "$TMP" || exit 0
        if [ "$ev" = turn ]; then
            jq -n --arg s "$sid" --arg p "$arg" '{session_id: $s, prompt: $p, hook_event_name: "UserPromptSubmit"}'
        else
            jq -n --arg s "$sid" --arg src "$arg" '{session_id: $s, source: $src, hook_event_name: "SessionStart"}'
        fi | env -u CLAUDE_PROJECT_DIR PATH="$FT:$BASE" CLAUDE_CONFIG_DIR="$CFG" \
            CREDO_REMINDER_TARGET_PID="$TGT" bash "$HOOK_SH" "$ev" >/dev/null 2>&1
    )
}
state_of() { jq -r --arg k "$2" 'if has($k) then .[$k] | tostring else "" end' "$CFG/credo/reminder-$1.json" 2>/dev/null; }
set_state() { # session id: armed with 10 turns, reference point now and at turn 10
    printf '{"session_id": "%s", "turns": 10, "armed": true, "last_reminder_turn": 10, "last_reminder": %s}\n' \
        "$1" "$(date +%s)" > "$CFG/credo/reminder-$1.json"
}
pid_gone() { # exited, or a zombie (kill -0 would still succeed)
    local st; st="$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)"
    [ -z "$st" ] || [ "$st" = Z ] || [ "$st" = X ]
}
alive_worker() { # session id -> 0 when its recorded worker runs
    local p; p="$(worker_pid_of "$CFG/credo/reminder-$1.json")"
    [ -n "$p" ] && ! pid_gone "$p" && grep -q "_worker" "/proc/$p/cmdline" 2>/dev/null
}
stop_worker() { # session id
    local p; p="$(worker_pid_of "$CFG/credo/reminder-$1.json")"
    [ -n "$p" ] || return 0
    kill -TERM "$p" 2>/dev/null; wait_for 40 pid_gone "$p"
}
n_typed() { grep -c 'send-keys -t %5 -l' "$FAKE_TMUX_LOG" 2>/dev/null || true; }
n_submits() { grep -c . "$FAKE_SUBMITS" 2>/dev/null || true; }
subs_ge() { [ "$(n_submits)" -ge "$1" ]; }
subs_gt() { [ "$(n_submits)" -gt "$1" ]; }
submits_have() { grep -qxF -- "$1" "$FAKE_SUBMITS"; }
state_eq() { [ "$(state_of "$1" "$2")" = "$3" ]; }

# --- off by default: the builtin config has every mode off ---------------------------
start_target "$TMP/t1.pid" TMUX=/tmp/fake-sock,1,0 TMUX_PANE=%5
TGT="$(cat "$TMP/t1.pid")"; export FAKE_PANE_PIDFILE="$TMP/t1.pid"
mode_of "$SID" active
for i in $(seq 1 12); do hook turn "$SID" "user message $i"; done
ok "builtin config (all modes off): no state file" "$([ -e "$CFG/credo/reminder-$SID.json" ] && echo 1 || echo 0)"
hook start "$SID" resume
ok "builtin config (all modes off): start does nothing" "$([ -e "$CFG/credo/reminder-$SID.json" ] && echo 1 || echo 0)"

# --- cost when off: with no user config layer holding an active mode, credo-config is not run
SID_Y="aaaaaaaa-1111-2222-3333-yyyyyyyyyyyy"
cat > "$TMP/config-spy.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/configcalls.log"
exec bash "$SCRIPT_DIR/credo-config.sh" "\$@"
EOF
chmod +x "$TMP/config-spy.sh"
export CREDO_CONFIG_SCRIPT="$TMP/config-spy.sh"
cp "$SCRIPT_DIR/../templates/config.default.yaml" "$CREDO_GLOBAL"   # the layer credo-config creates
: > "$TMP/configcalls.log"
hook turn "$SID_Y" "a message"
ok "builtin template as the global layer: credo-config is not run" "$([ -s "$TMP/configcalls.log" ] && echo 1 || echo 0)"
ok "builtin template as the global layer: nothing counted" "$([ -e "$CFG/credo/reminder-$SID_Y.json" ] && echo 1 || echo 0)"
cfg "reminder:\n  active: {turns: 10}\n"
hook turn "$SID_Y" "a message"
ok "a mode key in the global layer: credo-config is run" "$([ -s "$TMP/configcalls.log" ] && echo 0 || echo 1)"
cfg ""
printf 'reminder:\n  autonomous: {minutes: 60}\n' > "$TMP/project.yaml"
: > "$TMP/configcalls.log"
CREDO_PROJECT="$TMP/project.yaml" hook turn "$SID_Y" "a message"
ok "a mode key in the project layer: credo-config is run" "$([ -s "$TMP/configcalls.log" ] && echo 0 || echo 1)"
unset CREDO_CONFIG_SCRIPT

# --- turn counting and arming (active: every 10 turns; fake Claude process in tmux) ---
cfg "reminder:\n  active: {turns: 10}\n"
for i in $(seq 1 9); do hook turn "$SID" "user message $i"; done
check "9 user turns: counted" "9" "$(state_of "$SID" turns)"
check "9 user turns: not armed" "" "$(state_of "$SID" armed | sed 's/false//')"
for p in "[credo-reminder] $DEF" "." "[CREDO-AUTONOMY-WAKE] standby check" \
         "<task-notification>done</task-notification>" "[Cross-session idle notice] disk is idle" \
         "[SYSTEM NOTIFICATION - NOT USER INPUT] tick" "   "; do
    hook turn "$SID" "$p"
done
check "injected, bare dot, automated and blank prompts do not count" "9" "$(state_of "$SID" turns)"
hook turn "$SID" "the tenth real message"
check "10th user turn counted" "10" "$(state_of "$SID" turns)"
check "10th user turn arms the session" "true" "$(state_of "$SID" armed)"
wait_for 25 alive_worker "$SID"; ok "arming starts the worker" "$?"
W1="$(worker_pid_of "$CFG/credo/reminder-$SID.json")"
hook turn "$SID" "an eleventh message"
check "11th turn: still the same worker" "$W1" "$(worker_pid_of "$CFG/credo/reminder-$SID.json")"
hook start "$SID" resume
check "SessionStart for an armed session keeps the one worker" "$W1" "$(worker_pid_of "$CFG/credo/reminder-$SID.json")"
kill -TERM "$W1" 2>/dev/null; wait_for 25 pid_gone "$W1"; ok "test: worker stopped for the restart check" "$?"
hook start "$SID" compact
wait_for 25 alive_worker "$SID"; ok "SessionStart after the worker died starts a new worker" "$?"
W2="$(worker_pid_of "$CFG/credo/reminder-$SID.json")"
ok "new worker is another process" "$([ "$W2" != "$W1" ] && echo 0 || echo 1)"
stop_worker "$SID"

# --- a session outside tmux never arms -------------------------------------------------
start_target "$TMP/t2.pid"
TGT="$(cat "$TMP/t2.pid")"
for i in $(seq 1 10); do hook turn "$SID_X" "message $i"; done
check "outside tmux: turns counted" "10" "$(state_of "$SID_X" turns)"
check "outside tmux: not armed" "" "$(state_of "$SID_X" armed | sed 's/false//')"
ok "outside tmux: no worker" "$(alive_worker "$SID_X" && echo 1 || echo 0)"
TGT="$(cat "$TMP/t1.pid")"

# --- injection: autonomous every 0.02 min (1.2 s), active every 2 turns ----------------
cfg "reminder:\n  active: {turns: 2}\n  autonomous: {minutes: 0.02}\n"
rm -f "$MODES/$SID_D"
set_state "$SID_D"
hook start "$SID_D" startup
wait_for 25 alive_worker "$SID_D"; ok "injection session: worker running" "$?"
sleep 3
check "no credo mode set: nothing typed" "0" "$(n_typed)"
mode_of "$SID_D" autonomous
wait_for 40 subs_ge 1; ok "autonomous: first reminder submitted" "$?"
check "reminder text is the default prompt" "0" "$(grep -cvxF -- "$DEF" "$FAKE_SUBMITS")"
S0="$(n_submits)"
wait_for 40 subs_gt "$S0"; ok "next reminder one interval later" "$?"

# user text in the input field: never touched
printf '%s' "please check" > "$FAKE_BUF"
T0="$(n_typed)"; S0="$(n_submits)"; sleep 3
check "user text in the box: nothing typed" "$T0" "$(n_typed)"
check "user text in the box: nothing submitted" "$S0" "$(n_submits)"
check "user text in the box: left as it was" "please check" "$(cat "$FAKE_BUF")"
: > "$FAKE_BUF"

# busy turn: nothing typed while the spinner runs
cp "$TMP/above_busy.txt" "$FAKE_ABOVE"; sleep 2
T0="$(n_typed)"; sleep 3
check "busy turn: nothing typed" "$T0" "$(n_typed)"
cp "$TMP/above_idle.txt" "$FAKE_ABOVE"
S0="$(n_submits)"
wait_for 40 subs_gt "$S0"; ok "idle again: reminder resumes" "$?"

# dialog open: nothing typed, the user is notified once after BLOCKED_NOTIFY
cp "$TMP/above_dialog.txt" "$FAKE_ABOVE"; sleep 2
T0="$(n_typed)"; sleep 3
check "dialog open: nothing typed" "$T0" "$(n_typed)"
ok "dialog open: blocked wait logged" "$(grep -q "pane blocked by a dialog" "$CFG/credo/reminder-$SID_D.log" && echo 0 || echo 1)"
cp "$TMP/above_idle.txt" "$FAKE_ABOVE"
S0="$(n_submits)"
wait_for 40 subs_gt "$S0"; ok "dialog closed: reminder resumes" "$?"

# one visible character is a leftover: removed (End, BSpace) before the reminder is typed,
# so the reminder is submitted on its own
printf '%s' "x" > "$FAKE_BUF"; : > "$FAKE_BUFLOG"
S0="$(n_submits)"
wait_for 40 subs_gt "$S0"; ok "one visible char: removed, reminder submitted" "$?"
ok "one visible char: the submitted line is the reminder only" "$([ "$(tail -1 "$FAKE_SUBMITS")" = "$DEF" ] && echo 0 || echo 1)"
ok "one visible char: the box was emptied before typing" "$(grep -qx '' "$FAKE_BUFLOG" && echo 0 || echo 1)"
ok "all submitted reminders are the default prompt" "$([ "$(grep -cvxF -- "$DEF" "$FAKE_SUBMITS")" = 0 ] && echo 0 || echo 1)"
stop_worker "$SID_D"

# --- mode filter: passive has no trigger in this config -------------------------------
mode_of "$SID_P" passive
set_state "$SID_P"
hook start "$SID_P" startup
wait_for 25 alive_worker "$SID_P"; ok "passive session: worker running" "$?"
T0="$(n_typed)"
for i in 1 2 3; do hook turn "$SID_P" "passive message $i"; done
sleep 3
check "passive without a trigger: turns counted, nothing typed" "$T0" "$(n_typed)"
check "passive without a trigger: 13 turns" "13" "$(state_of "$SID_P" turns)"
stop_worker "$SID_P"

# --- turns trigger (active: every 2 turns since the last reminder) --------------------
mode_of "$SID_T" active
set_state "$SID_T"
hook start "$SID_T" startup
wait_for 25 alive_worker "$SID_T"; ok "turns trigger: worker running" "$?"
S0="$(n_submits)"
hook turn "$SID_T" "first message"
sleep 2
check "one turn of two: no reminder yet" "$S0" "$(n_submits)"
hook turn "$SID_T" "second message"
wait_for 40 subs_gt "$S0"; ok "second turn: reminder submitted once idle" "$?"
wait_for 40 state_eq "$SID_T" last_reminder_turn 12; ok "reminder moves the reference turn to 12" "$?"
check "the reminder is no user turn: still 12 turns" "12" "$(state_of "$SID_T" turns)"
stop_worker "$SID_T"

# --- text: reminder text replaces the built-in text after the marker ------------------
cfg "reminder:\n  autonomous: {minutes: 0.02}\n  text: \"Check the rules now\"\n"
set_state "$SID_H"
mode_of "$SID_H" autonomous
hook start "$SID_H" startup
wait_for 40 submits_have "[credo-reminder] Check the rules now"; ok "custom text submitted after the marker" "$?"
stop_worker "$SID_H"

# --- the config turns the reminder off: the worker stops -----------------------------
cfg "reminder:\n  autonomous: {minutes: 60}\n"
set_state "$SID_O"
mode_of "$SID_O" autonomous
hook start "$SID_O" startup
wait_for 25 alive_worker "$SID_O"; ok "off switch: worker running" "$?"
O_W="$(worker_pid_of "$CFG/credo/reminder-$SID_O.json")"
cfg "reminder:\n  text: \"\"\n"
wait_for 60 pid_gone "$O_W"; ok "off switch: worker stops after the config is read" "$?"
case "$(state_of "$SID_O" status)" in stopped*) ok "off switch: state says stopped" 0 ;; *) ok "off switch: state says stopped ($(state_of "$SID_O" status))" 1 ;; esac

# --- the worker exits when the Claude process of its session is gone -------------------
cfg "reminder:\n  autonomous: {minutes: 60}\n"
start_target "$TMP/t4.pid" TMUX=/tmp/fake-sock,1,0 TMUX_PANE=%5
TGT="$(cat "$TMP/t4.pid")"; export FAKE_PANE_PIDFILE="$TMP/t4.pid"
set_state "$SID_E"
mode_of "$SID_E" autonomous
hook start "$SID_E" startup
wait_for 25 alive_worker "$SID_E"; ok "pane check: worker running" "$?"
E_W="$(worker_pid_of "$CFG/credo/reminder-$SID_E.json")"
kill -TERM "$TGT" 2>/dev/null
wait_for 60 pid_gone "$E_W"; ok "Claude process gone: worker exits" "$?"
case "$(state_of "$SID_E" status)" in stopped*) ok "Claude process gone: state says stopped" 0 ;; *) ok "Claude process gone: state says stopped" 1 ;; esac
TGT="$(cat "$TMP/t1.pid")"; export FAKE_PANE_PIDFILE="$TMP/t1.pid"

# --- status -----------------------------------------------------------------------------
out="$(env -u CREDO_REMINDER_TARGET_PID CLAUDE_CODE_SESSION_ID="$SID_T" CLAUDE_CONFIG_DIR="$CFG" "$PY" "$HELPER" status 2>&1)"; rc=$?
check "status: rc 0" "0" "$rc"
case "$out" in *'"armed": true'*) ok "status shows the armed state" 0 ;; *) ok "status shows the armed state ($out)" 1 ;; esac

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
