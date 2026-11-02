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
#   - pure: the per-mode triggers (turns, minutes, both), the off switches (enabled false,
#     a mode at 0 or "off"), the prompt text, which prompts count as a user turn, when a
#     trigger is due
#   - hook wiring: UserPromptSubmit runs the turn counter, SessionStart the start
#   - on by default: the builtin template holds the defaults (active and passive every 10
#     turns, autonomous every 60 minutes); with no user config the 10th real user turn arms
#     the session and the first reminder comes 10 turns later
#   - off switches: enabled false in the layer that decides (the shell hook exits before
#     python: nothing counted, credo-config not run); a project config the cascade does not
#     pick never switches the reminder off; a per-mode 0 switches only that mode off
#   - first-time notice: only the first sent reminder of a session carries the notice
#   - turn counting: the 10th real user turn arms the session for good; injected reminders,
#     bare ".", automated prompts and blank prompts do not count
#   - outside tmux a session never arms
#   - SessionStart start: a worker for an armed session, one worker per session
#   - injection when a trigger is due: idle + empty input -> the prompt is typed in one
#     burst, settled and submitted; typed user text, a busy turn or a dialog -> nothing
#     typed; one visible character counts as empty and is removed first
#   - one burst: the whole reminder in one send, Enter after the settle; both paste
#     placeholder forms are accepted as they are; a dialog after the burst -> no Enter; a
#     field that holds text -> skipped at once and left as it is; a failed send -> nothing
#     typed
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
    "Check every open veto code against its item: close it yourself, noted in the handoff, when the item is done or verified and nothing of the decision is still open, or when later work superseded it. Raise a veto only for a decision the owner notices in the product (behaviour, visible text, money, taste, data); internal process decisions go only into the log and the item History. "
    "Keep credo's output format unless something speaks against it: every test, question and veto code carries its emoji wherever it asks something of the user (🧪 T5, ❓ Q4, ✋ V2 in headings, Ask text and mentions), and the reply ends with the open-codes footer. Clean up merged worktrees and branches with credo-worktree-cleanup.sh; a worktree that may still be needed goes to the owner as a question. GO items never just wait on the owner, so classify each stalled one with credo-go-stall.sh and re-check handoff labels against the open DoD. Shortened questions repeat the full copyable command. If anything drifted, fix it now "
    "and continue as agreed.")
assert "close it yourself" in m.DEFAULT_TEXT and "is done or verified" in m.DEFAULT_TEXT
assert "the owner notices in the product" in m.DEFAULT_TEXT and "item History." in m.DEFAULT_TEXT
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
# off switches: enabled false (bool or string) turns everything off; a mode at 0 or "off"
# (or null) is off, the other modes keep their triggers
assert m.parse_triggers({"enabled": False, "active": {"turns": 10}}) == {}
assert m.parse_triggers({"enabled": "false", "autonomous": {"minutes": 60}}) == {}
assert m.parse_triggers({"enabled": True, "active": {"turns": 10}}) == {
    "active": {"turns": 10, "minutes": None}}
assert m.parse_triggers({"active": {"turns": 0, "minutes": 0}, "autonomous": {"minutes": 0},
                         "passive": {"turns": 10}}) == {
    "passive": {"turns": 10, "minutes": None}}
assert m.parse_triggers({"active": "off", "passive": {"turns": 10}}) == {
    "passive": {"turns": 10, "minutes": None}}
assert m.parse_triggers({"active": None, "autonomous": {"minutes": 60}}) == {
    "autonomous": {"turns": None, "minutes": 60.0}}
assert m.NOTICE.startswith("Note (first reminder of this session): the periodic reminder is on by default.")
assert "reminder.enabled: false" in m.NOTICE and "reminder.<mode>.turns: 0" in m.NOTICE
assert "reminder.<mode>.minutes: 0" in m.NOTICE
PYEOF
ok "pure: triggers, prompt text, turn classification, due check" "$?"

# the pieces the text is typed in join back to it, none is over TYPE_CHUNK_CHARS, a piece
# may start with a dash (sent after the end-of-options separator), empty text gives no piece
SCRIPT_DIR="$SCRIPT_DIR" "$PY" - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["SCRIPT_DIR"])
import credo_pane_wake as w
t = "[credo-reminder] " + "x" * 183 + "-" + "é\U0001f9ea" * 150
p = w.type_chunks(t)
assert "".join(p) == t and len(p) > 1, p
assert all(0 < len(x) <= w.TYPE_CHUNK_CHARS for x in p), [len(x) for x in p]
assert p[1].startswith("-"), p[1][:5]
assert w.type_chunks("") == [] and w.type_chunks("short") == ["short"]
PYEOF
ok "pieces join back to the text, at most TYPE_CHUNK_CHARS each" "$?"

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
# Two behaviors of the real tmux and Claude Code are modelled (both seen in a real pane):
#   - tmux reads a literal argument that starts with a dash as an option unless the
#     end-of-options separator comes first (otherwise "unknown option"), and that send fails
#   - Claude Code's input box collapses one burst of more than PASTE_LIMIT characters into
#     the placeholder "[Pasted text #1]": $FAKE_PASTE holds the number of pasted characters,
#     $FAKE_BUF keeps the whole text (Enter submits it), one BSpace removes the placeholder
# Every literal send is logged to $FAKE_TYPE_LOG as "<epoch ns> <characters>"; with
# $FAKE_FAIL_AT = N the literal send number N (counted from 0) fails and types nothing.
cat > "$FT/tmux" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_TMUX_LOG"
[ "$1" = "-S" ] && shift 2
R="────────────────────────────────────────────────────────────"
PASTE_LIMIT=800
show() { # the input box as Claude Code shows it
    local buf n ph="[Pasted text #1]"
    buf="$(cat "$FAKE_BUF" 2>/dev/null)"
    n="$(cat "$FAKE_PASTE" 2>/dev/null)"
    # the second placeholder form (a burst with newlines), as measured on the real pane
    [ "$FAKE_PASTE_FORM" = lines ] && ph="[Pasted text #1 +${FAKE_PASTE_LINES:-11} lines]"
    if [ -n "$n" ] && [ -n "$buf" ]; then
        printf '%s%s' "$ph" "${buf:$n}"
    else
        printf '%s' "$buf"
    fi
}
literal_send() { # send-keys -t <pane> -l [--] <text>
    local txt="$5" n
    if [ "$txt" = "--" ]; then
        txt="$6"
    else
        case "$txt" in -*) echo "tmux: unknown option -- ${txt:1:1}" >&2; return 1 ;; esac
    fi
    n="$(grep -c '' "$FAKE_TYPE_LOG" 2>/dev/null)"
    if [ -n "$FAKE_FAIL_AT" ] && [ "$n" = "$FAKE_FAIL_AT" ]; then return 1; fi
    printf '%s %s\n' "$(date +%s%N)" "${#txt}" >> "$FAKE_TYPE_LOG"
    if [ -n "$(cat "$FAKE_PASTE" 2>/dev/null)" ] && [ -s "$FAKE_BUF" ]; then
        printf '%s' "$txt" >> "$FAKE_BUF"
    elif [ "${#txt}" -gt "$PASTE_LIMIT" ] && [ ! -s "$FAKE_BUF" ]; then
        printf '%s' "$txt" > "$FAKE_BUF"; printf '%s' "${#txt}" > "$FAKE_PASTE"
    else
        printf '%s' "$txt" >> "$FAKE_BUF"
    fi
    # FAKE_NOBOX_ON_TYPE: a dialog covers the input box right after this send (the box is gone)
    if [ -n "$FAKE_NOBOX_ON_TYPE" ]; then : > "$FAKE_NOBOX_FLAG"; fi
}
bspace_one() { # a placeholder goes as a whole, else one character
    local buf n
    buf="$(cat "$FAKE_BUF" 2>/dev/null)"
    n="$(cat "$FAKE_PASTE" 2>/dev/null)"
    if [ -n "$n" ] && [ -n "$buf" ]; then
        if [ "${#buf}" -le "$n" ]; then
            : > "$FAKE_BUF"; rm -f "$FAKE_PASTE"; return 0
        fi
    fi
    printf '%s' "${buf%?}" > "$FAKE_BUF"
}
case "$1" in
    display-message)
        [ "$4" = "$FAKE_PANE_ID" ] || exit 1
        printf '%s\t%s\t0\t0\n' "$4" "$(cat "$FAKE_PANE_PIDFILE")" ;;
    capture-pane)
        if [ -n "$FAKE_NOBOX_FLAG" ] && [ -f "$FAKE_NOBOX_FLAG" ]; then
            cat "$FAKE_NOBOX_VIEW"; exit 0
        fi
        cat "$FAKE_ABOVE"
        printf '%s\n' "$R" "❯ $(show)" "$R" "  ? for shortcuts" ;;
    send-keys)
        case "$4" in
            -l) literal_send "$@" || exit 1 ;;
            End) ;;
            Enter)
                printf '%s\n' "$(date +%s%N)" >> "$FAKE_ENTER_LOG"
                buf="$(cat "$FAKE_BUF" 2>/dev/null)"
                [ -n "$buf" ] && printf '%s\n' "$buf" >> "$FAKE_SUBMITS"
                : > "$FAKE_BUF"; rm -f "$FAKE_PASTE" ;;
            *)
                for _ in "${@:4}"; do bspace_one; done ;;
        esac
        printf '%s\n' "$(show)" >> "$FAKE_BUFLOG" ;;
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
DEF="[credo-reminder] Check yourself against what we agreed: re-read the credo rules, the open items, the requirements logs and the handoff - did you keep every agreement so far, also those from before a compact or from earlier days, and did you declare a blocker or showstopper that our agreements say is none? A newer decision always overrides an older one on the same point (e.g. a limit raised from 3 to 6 means 6 now applies), so drop superseded agreements instead of carrying them along. Make sure every standing agreement is carried into the current handoff so it survives compacts and does not go stale in an old requirements file. Check the open-codes footer and drop every code that is answered, verified, superseded, moved into an item or moot. Check every open veto code against its item: close it yourself, noted in the handoff, when the item is done or verified and nothing of the decision is still open, or when later work superseded it. Raise a veto only for a decision the owner notices in the product (behaviour, visible text, money, taste, data); internal process decisions go only into the log and the item History. Keep credo's output format unless something speaks against it: every test, question and veto code carries its emoji wherever it asks something of the user (🧪 T5, ❓ Q4, ✋ V2 in headings, Ask text and mentions), and the reply ends with the open-codes footer. Clean up merged worktrees and branches with credo-worktree-cleanup.sh; a worktree that may still be needed goes to the owner as a question. GO items never just wait on the owner, so classify each stalled one with credo-go-stall.sh and re-check handoff labels against the open DoD. Shortened questions repeat the full copyable command. If anything drifted, fix it now and continue as agreed."
NOTICE="Note (first reminder of this session): the periodic reminder is on by default. To switch it off, set reminder.enabled: false in your credo config, or set reminder.<mode>.turns: 0 and reminder.<mode>.minutes: 0 for one mode (mode: active, passive or autonomous). Mention this to the user in one line."
printf '%s\n' "● Done, fixture finished." "" > "$TMP/above_idle.txt"
printf '%s\n' "● Working on the fixture." "" "✻ Brewing... (3s · ↓ 10 tokens)" "" > "$TMP/above_busy.txt"
printf '%s\n' "● Done." "" "Do you want to proceed?" "❯ 1. Yes" "  2. No" "" > "$TMP/above_dialog.txt"
export FAKE_TMUX_LOG="$TMP/tmux.log" FAKE_ABOVE="$TMP/above.txt" FAKE_BUF="$TMP/buf.txt" \
    FAKE_SUBMITS="$TMP/submits.txt" FAKE_BUFLOG="$TMP/buflog.txt" FAKE_PANE_ID=%5 \
    FAKE_TYPE_LOG="$TMP/type.log" FAKE_PASTE="$TMP/paste.txt" FAKE_ENTER_LOG="$TMP/enter.log" \
    FAKE_NOBOX_FLAG="$TMP/nobox.flag" FAKE_NOBOX_VIEW="$TMP/nobox_view.txt"
printf '%s\n' "● Done." "" "Do you want to proceed?" "❯ 1. Yes" "  2. No" "" > "$FAKE_NOBOX_VIEW"
cp "$TMP/above_idle.txt" "$FAKE_ABOVE"
: > "$FAKE_SUBMITS"; : > "$FAKE_BUF"; : > "$FAKE_TMUX_LOG"; : > "$FAKE_BUFLOG"; : > "$FAKE_TYPE_LOG"
: > "$FAKE_ENTER_LOG"; rm -f "$FAKE_NOBOX_FLAG"
rm -f "$FAKE_PASTE"
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
submits_contain() { grep -qF -- "$1" "$FAKE_SUBMITS"; }
state_eq() { [ "$(state_of "$1" "$2")" = "$3" ]; }

# --- on by default: no user config -> the builtin template's defaults apply -----------
# (the global layer is empty here, so the builtin template is the only layer)
DEF_JSON="$(bash "$SCRIPT_DIR/credo-config.sh" get reminder)"
printf '%s' "$DEF_JSON" | jq -e '.enabled == true and .active.turns == 10 and .passive.turns == 10 and .autonomous.minutes == 60' >/dev/null
ok "builtin defaults: enabled, active and passive every 10 turns, autonomous every 60 minutes" "$?"
SID_B="aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb"
start_target "$TMP/t1.pid" TMUX=/tmp/fake-sock,1,0 TMUX_PANE=%5
TGT="$(cat "$TMP/t1.pid")"; export FAKE_PANE_PIDFILE="$TMP/t1.pid"
mode_of "$SID_B" active
for i in $(seq 1 9); do hook turn "$SID_B" "user message $i"; done
check "default on: 9 turns counted" "9" "$(state_of "$SID_B" turns)"
check "default on: 9 turns not armed" "" "$(state_of "$SID_B" armed | sed 's/false//')"
hook turn "$SID_B" "the tenth real message"
check "default on: the 10th turn arms the session" "true" "$(state_of "$SID_B" armed)"
wait_for 25 alive_worker "$SID_B"; ok "default on: worker running after arming" "$?"
check "default on: nothing typed right after arming" "0" "$(n_typed)"
for i in $(seq 11 20); do hook turn "$SID_B" "user message $i"; done
wait_for 40 subs_ge 1; ok "default on: first reminder 10 turns after arming" "$?"
ok "default on: first reminder is the default prompt plus the notice" "$([ "$(head -1 "$FAKE_SUBMITS")" = "$DEF $NOTICE" ] && echo 0 || echo 1)"
stop_worker "$SID_B"
reset_fake() { : > "$FAKE_SUBMITS"; : > "$FAKE_BUF"; : > "$FAKE_TMUX_LOG"; : > "$FAKE_BUFLOG"; }
reset_fake
# a turn with CLAUDE_PROJECT_DIR set (the project dir the session runs in)
hook_projdir() { # project dir, session id, prompt
    jq -n --arg s "$2" --arg p "$3" '{session_id: $s, prompt: $p, hook_event_name: "UserPromptSubmit"}' \
        | (cd "$TMP" && env PATH="$FT:$BASE" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PROJECT_DIR="$1" \
            CREDO_REMINDER_TARGET_PID="$TGT" bash "$HOOK_SH" turn >/dev/null 2>&1)
}

# --- off switches and cost: the layer that decides says enabled false -> the shell hook
# exits before python and credo-config: nothing is counted, nothing is started
cat > "$TMP/config-spy.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/configcalls.log"
exec bash "$SCRIPT_DIR/credo-config.sh" "\$@"
EOF
chmod +x "$TMP/config-spy.sh"
export CREDO_CONFIG_SCRIPT="$TMP/config-spy.sh"
SID_Y="aaaaaaaa-1111-2222-3333-yyyyyyyyyyyy"
SID_Z="aaaaaaaa-1111-2222-3333-zzzzzzzzzzzz"
SID_Q="aaaaaaaa-1111-2222-3333-qqqqqqqqqqqq"
SID_K="aaaaaaaa-1111-2222-3333-kkkkkkkkkkkk"
SID_V="aaaaaaaa-1111-2222-3333-vvvvvvvvvvvv"
SID_F="aaaaaaaa-1111-2222-3333-ffffffffffff"
SID_Q2="aaaaaaaa-1111-2222-3333-rrrrrrrrrrrr"
cfg "reminder:\n  enabled: false\n"
: > "$TMP/configcalls.log"
hook turn "$SID_Y" "a message"
ok "enabled false (global): credo-config is not run" "$([ -s "$TMP/configcalls.log" ] && echo 1 || echo 0)"
ok "enabled false (global): nothing counted" "$([ -e "$CFG/credo/reminder-$SID_Y.json" ] && echo 1 || echo 0)"
set_state "$SID_F"; mode_of "$SID_F" autonomous
hook start "$SID_F" startup
sleep 1
ok "enabled false (global): SessionStart starts no worker" "$(alive_worker "$SID_F" && echo 1 || echo 0)"
cfg 'reminder:\n  enabled: "false"\n'
hook turn "$SID_Q" "a message"
ok "enabled \"false\" (quoted string): nothing counted" "$([ -e "$CFG/credo/reminder-$SID_Q.json" ] && echo 1 || echo 0)"
cfg 'reminder: {enabled: false, text: ""}\n'
hook turn "$SID_Q2" "a message"
ok "enabled false in a flow map: nothing counted" "$([ -e "$CFG/credo/reminder-$SID_Q2.json" ] && echo 1 || echo 0)"
cfg ""
printf 'reminder:\n  enabled: false\n' > "$TMP/project-off.yaml"
: > "$TMP/configcalls.log"
CREDO_PROJECT="$TMP/project-off.yaml" hook turn "$SID_Z" "a message"
ok "enabled false (project layer): credo-config is not run" "$([ -s "$TMP/configcalls.log" ] && echo 1 || echo 0)"
ok "enabled false (project layer): nothing counted" "$([ -e "$CFG/credo/reminder-$SID_Z.json" ] && echo 1 || echo 0)"
# the project config the cascade picks is the one that counts: a file that is not picked
# (here the session's project dir) never switches the reminder off
mkdir -p "$TMP/pdir/.credo"
printf 'reminder:\n  enabled: false\n' > "$TMP/pdir/.credo/config"
printf 'hello: world\n' > "$TMP/project-nokey.yaml"
CREDO_PROJECT="$TMP/project-nokey.yaml" hook_projdir "$TMP/pdir" "$SID_K" "a message"
check "a project config the cascade does not pick: the reminder is still on and counted" "1" "$(state_of "$SID_K" turns)"
# a project layer that sets enabled true beats enabled false in the global layer
cfg "reminder:\n  enabled: false\n"
printf 'reminder:\n  enabled: true\n' > "$TMP/project-on.yaml"
CREDO_PROJECT="$TMP/project-on.yaml" hook turn "$SID_V" "a message"
check "project enabled true beats global enabled false: counted" "1" "$(state_of "$SID_V" turns)"
cfg ""
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
cfg "reminder:\n  active: {turns: 2}\n  passive: {turns: 0}\n  autonomous: {minutes: 0.02}\n"
rm -f "$MODES/$SID_D"
set_state "$SID_D"
hook start "$SID_D" startup
wait_for 25 alive_worker "$SID_D"; ok "injection session: worker running" "$?"
sleep 3
check "no credo mode set: nothing typed" "0" "$(n_typed)"
mode_of "$SID_D" autonomous
wait_for 40 subs_ge 1; ok "autonomous: first reminder submitted" "$?"
ok "first reminder is the default prompt plus the notice" "$([ "$(head -1 "$FAKE_SUBMITS")" = "$DEF $NOTICE" ] && echo 0 || echo 1)"
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
ok "later reminders are the default prompt only" "$([ "$(tail -n +2 "$FAKE_SUBMITS" | grep -cvxF -- "$DEF")" = 0 ] && echo 0 || echo 1)"
stop_worker "$SID_D"

# --- first-time notice: only the first sent reminder of a session carries the notice -----
SID_N="aaaaaaaa-1111-2222-3333-nnnnnnnnnnnn"
cfg "reminder:\n  autonomous: {minutes: 0.02}\n"
set_state "$SID_N"; mode_of "$SID_N" autonomous
S0="$(n_submits)"
hook start "$SID_N" startup
wait_for 40 subs_gt "$S0"; ok "notice: first reminder submitted" "$?"
ok "notice: the first reminder of the session carries the notice" "$([ "$(sed -n "$((S0 + 1))p" "$FAKE_SUBMITS")" = "$DEF $NOTICE" ] && echo 0 || echo 1)"
wait_for 40 subs_gt "$((S0 + 1))"; ok "notice: second reminder submitted" "$?"
ok "notice: the second reminder is the default prompt only" "$([ "$(sed -n "$((S0 + 2))p" "$FAKE_SUBMITS")" = "$DEF" ] && echo 0 || echo 1)"
wait_for 20 state_eq "$SID_N" notice_sent true; ok "notice: the state records that it was sent" "$?"
stop_worker "$SID_N"
S0="$(n_submits)"
hook start "$SID_N" resume
wait_for 40 subs_gt "$S0"; ok "notice: a resumed session (same id) gets a reminder again" "$?"
ok "notice: the resumed session's reminder is the default prompt only" "$([ "$(sed -n "$((S0 + 1))p" "$FAKE_SUBMITS")" = "$DEF" ] && echo 0 || echo 1)"
stop_worker "$SID_N"
SID_N2="aaaaaaaa-1111-2222-3333-mmmmmmmmmmmm"
set_state "$SID_N2"; mode_of "$SID_N2" autonomous
S0="$(n_submits)"
hook start "$SID_N2" startup
wait_for 40 subs_gt "$S0"; ok "notice: a new session gets its own first reminder" "$?"
ok "notice: a new session's first reminder carries the notice" "$([ "$(sed -n "$((S0 + 1))p" "$FAKE_SUBMITS")" = "$DEF $NOTICE" ] && echo 0 || echo 1)"
stop_worker "$SID_N2"

# --- a per-mode 0 switches only that mode off (active turns 0; autonomous still on) --------
SID_M="aaaaaaaa-1111-2222-3333-mmmmmmmmmmmz"
cfg "reminder:\n  active: {turns: 0}\n  autonomous: {minutes: 0.02}\n"
set_state "$SID_M"; mode_of "$SID_M" active
hook start "$SID_M" startup
wait_for 25 alive_worker "$SID_M"; ok "per-mode 0: worker runs for the other modes" "$?"
S0="$(n_submits)"
for i in 1 2 3; do hook turn "$SID_M" "active message $i"; done
sleep 3
check "per-mode 0: no reminder in the active mode, however many turns" "$S0" "$(n_submits)"
mode_of "$SID_M" autonomous
wait_for 40 subs_gt "$S0"; ok "per-mode 0: autonomous mode still gets its reminder" "$?"
stop_worker "$SID_M"

# --- mode filter: passive has no trigger in this config -------------------------------
cfg "reminder:\n  active: {turns: 2}\n  passive: {turns: 0}\n  autonomous: {minutes: 0.02}\n"
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
cfg "reminder:\n  active: {turns: 2}\n  passive: {turns: 0}\n  autonomous: {minutes: 0.02}\n"
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
wait_for 40 submits_contain "[credo-reminder] Check the rules now"; ok "custom text submitted after the marker" "$?"
stop_worker "$SID_H"

# --- one burst: the whole reminder (over ~800 characters) is typed by ONE send, it settles,
# then Enter. Claude Code shows the burst as a paste placeholder, which is accepted as it is ---
SID_L="aaaaaaaa-1111-2222-3333-llllllllllll"
cfg "reminder:\n  autonomous: {minutes: 0.02}\n"
set_state "$SID_L"; mode_of "$SID_L" autonomous
S0="$(n_submits)"; TL0="$(grep -c '' "$FAKE_TYPE_LOG")"; EN0="$(grep -c '' "$FAKE_ENTER_LOG")"
: > "$FAKE_BUFLOG"
hook start "$SID_L" startup
wait_for 60 subs_gt "$S0"; ok "one burst: the reminder is submitted" "$?"
stop_worker "$SID_L"
ok "one burst: the submitted line is the reminder plus the notice" "$([ "$(sed -n "$((S0 + 1))p" "$FAKE_SUBMITS")" = "$DEF $NOTICE" ] && echo 0 || echo 1)"
PIECES="$TMP/pieces.txt"; tail -n +"$((TL0 + 1))" "$FAKE_TYPE_LOG" > "$PIECES"
check "one burst: one send for the whole reminder" "1" "$(grep -c '' "$PIECES")"
check "one burst: the send holds the whole line" "$((${#DEF} + 1 + ${#NOTICE}))" "$(awk '{ print $2 }' "$PIECES")"
ok "one burst: the box showed the paste placeholder (form 1)" "$(grep -qxF '[Pasted text #1]' "$FAKE_BUFLOG" && echo 0 || echo 1)"
ok "one burst: one Enter, after the settle" "$([ "$(( $(grep -c '' "$FAKE_ENTER_LOG") - EN0 ))" = 1 ] && [ $(( ($(sed -n "$((EN0 + 1))p" "$FAKE_ENTER_LOG") - $(awk 'NR == 1 { print $1 }' "$PIECES")) / 1000000 )) -ge 90 ] && echo 0 || echo 1)"

# the second placeholder form Claude Code shows (measured on the real pane): one burst, then
# "[Pasted text #1 +11 lines]" in the box; the reminder is submitted as before
SID_P2="aaaaaaaa-1111-2222-3333-pppppppppp2"
set_state "$SID_P2"; mode_of "$SID_P2" autonomous
S0="$(n_submits)"; : > "$FAKE_BUFLOG"
export FAKE_PASTE_FORM=lines
hook start "$SID_P2" startup
wait_for 60 subs_gt "$S0"; ok "placeholder form 2: the reminder is submitted" "$?"
stop_worker "$SID_P2"
unset FAKE_PASTE_FORM
ok "placeholder form 2: the box showed [Pasted text #1 +11 lines]" "$(grep -qxF '[Pasted text #1 +11 lines]' "$FAKE_BUFLOG" && echo 0 || echo 1)"
ok "placeholder form 2: the submitted line is the reminder plus the notice" "$([ "$(sed -n "$((S0 + 1))p" "$FAKE_SUBMITS")" = "$DEF $NOTICE" ] && echo 0 || echo 1)"

# a dialog covers the input box right after the burst: no Enter, nothing submitted, the typed
# burst is left as it is (never deleted or submitted later by this worker)
SID_D2="aaaaaaaa-1111-2222-3333-dddddddddd22"
cfg "reminder:\n  autonomous: {minutes: 0.02}\n"
set_state "$SID_D2"; mode_of "$SID_D2" autonomous
S0="$(n_submits)"; EN0="$(grep -c '' "$FAKE_ENTER_LOG")"; rm -f "$FAKE_NOBOX_FLAG"
export FAKE_NOBOX_ON_TYPE=1
hook start "$SID_D2" startup
wait_for 60 grep -q "no input box after the burst" "$CFG/credo/reminder-$SID_D2.log"; ok "dialog after the burst: the reminder is skipped" "$?"
stop_worker "$SID_D2"
unset FAKE_NOBOX_ON_TYPE; rm -f "$FAKE_NOBOX_FLAG"
check "dialog after the burst: no Enter sent" "$EN0" "$(grep -c '' "$FAKE_ENTER_LOG")"
check "dialog after the burst: nothing submitted" "$S0" "$(n_submits)"
ok "dialog after the burst: the burst is left in the field" "$([ -s "$FAKE_BUF" ] && echo 0 || echo 1)"
: > "$FAKE_BUF"; rm -f "$FAKE_PASTE"

# a field that holds text when the reminder is due: skipped at once (logged), the text is left
SID_K2="aaaaaaaa-1111-2222-3333-kkkkkkkkkk22"
cfg "reminder:\n  autonomous: {minutes: 0.02}\n"
printf '%s' "please check the handoff" > "$FAKE_BUF"
set_state "$SID_K2"; mode_of "$SID_K2" autonomous
T0="$(n_typed)"; S0="$(n_submits)"
hook start "$SID_K2" startup
wait_for 40 grep -q "the input field holds text, left as it is" "$CFG/credo/reminder-$SID_K2.log"; ok "field with text: the reminder is skipped at once" "$?"
stop_worker "$SID_K2"
check "field with text: nothing typed" "$T0" "$(n_typed)"
check "field with text: nothing submitted" "$S0" "$(n_submits)"
check "field with text: left as it was" "please check the handoff" "$(cat "$FAKE_BUF")"
: > "$FAKE_BUF"

# a dash inside the burst: the burst is sent after the end-of-options separator (a literal
# argument that starts with a dash would be read as an option by tmux)
DASH_BODY="$(printf 'x%.0s' $(seq 1 183))-$(printf 'y%.0s' $(seq 1 80))"
SID_G="aaaaaaaa-1111-2222-3333-gggggggggggg"
cfg "reminder:\n  autonomous: {minutes: 0.02}\n  text: \"$DASH_BODY\"\n"
set_state "$SID_G"; mode_of "$SID_G" autonomous
S0="$(n_submits)"
hook start "$SID_G" startup
wait_for 60 subs_gt "$S0"; ok "dash in the burst: the reminder is submitted" "$?"
stop_worker "$SID_G"
ok "dash in the burst: the submitted line is the text plus the notice" "$([ "$(sed -n "$((S0 + 1))p" "$FAKE_SUBMITS")" = "[credo-reminder] $DASH_BODY $NOTICE" ] && echo 0 || echo 1)"

# a paste placeholder the worker did not make (the user pasted) is never typed over, submitted
# or removed
SID_U="aaaaaaaa-1111-2222-3333-uuuuuuuuuuuu"
cfg "reminder:\n  autonomous: {minutes: 0.02}\n"
printf '%s' "$(printf 'p%.0s' $(seq 1 900))" > "$FAKE_BUF"; printf '%s' 900 > "$FAKE_PASTE"
set_state "$SID_U"; mode_of "$SID_U" autonomous
T0="$(n_typed)"; S0="$(n_submits)"
hook start "$SID_U" startup
wait_for 25 alive_worker "$SID_U"; ok "user paste: worker running" "$?"
sleep 3
check "user paste in the box: nothing typed" "$T0" "$(n_typed)"
check "user paste in the box: nothing submitted" "$S0" "$(n_submits)"
U_TEXT="$(cat "$FAKE_BUF")"
check "user paste in the box: left as it was" "900" "${#U_TEXT}"
stop_worker "$SID_U"
: > "$FAKE_BUF"; rm -f "$FAKE_PASTE"

# a send that fails: nothing is typed, no Enter, the field stays empty
SID_F="aaaaaaaa-1111-2222-3333-ffffffffffff"
cfg "reminder:\n  autonomous: {minutes: 0.02}\n"
set_state "$SID_F"; mode_of "$SID_F" autonomous
TL0="$(grep -c '' "$FAKE_TYPE_LOG")"; S0="$(n_submits)"; EN0="$(grep -c '' "$FAKE_ENTER_LOG")"
export FAKE_FAIL_AT="$TL0"
hook start "$SID_F" startup
wait_for 40 grep -q "typing the reminder failed" "$CFG/credo/reminder-$SID_F.log"; ok "failed send: the reminder is skipped" "$?"
stop_worker "$SID_F"
unset FAKE_FAIL_AT
ok "failed send: the input box is empty" "$([ ! -s "$FAKE_BUF" ] && echo 0 || echo 1)"
check "failed send: no Enter" "$EN0" "$(grep -c '' "$FAKE_ENTER_LOG")"
check "failed send: nothing submitted" "$S0" "$(n_submits)"
rm -f "$FAKE_PASTE"

# --- enabled false: the running worker stops after the config is read -----------------
cfg "reminder:\n  autonomous: {minutes: 60}\n"
set_state "$SID_O"
mode_of "$SID_O" autonomous
hook start "$SID_O" startup
wait_for 25 alive_worker "$SID_O"; ok "off switch: worker running" "$?"
O_W="$(worker_pid_of "$CFG/credo/reminder-$SID_O.json")"
cfg "reminder:\n  enabled: false\n"
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
