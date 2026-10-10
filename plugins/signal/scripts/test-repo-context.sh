#!/bin/bash
# test-repo-context.sh: tests for the toast title resolver and the client pane lookup
# (plugins/signal/scripts/repo-context.sh and the title paths of the hooks).
#
# Title order for every toast: user-set caption (session descriptor with nameSource user
# only, never the transcript) -> kitty label -> tmux label -> short session id; every name
# is cut to 20 chars. Fixtures are invented (alice, box-1, /home/myuser).
#
# Usage: bash plugins/signal/scripts/test-repo-context.sh

set -u

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sigctx.XXXXXX")" || exit 1
# kitty-tab.sh keeps its display file under /tmp, keyed by the window pid (= this shell)
KITTY_DISPLAY_FILE="/tmp/claude-mb-kitty-display-$$"
cleanup() {
    rm -f -- "$KITTY_DISPLAY_FILE"
    case "$TMP" in
        "${TMPDIR:-/tmp}"/sigctx.??????) rm -rf -- "$TMP" ;;
        *) echo "refusing to remove unexpected temp root: '$TMP'" >&2 ;;
    esac
}
trap cleanup EXIT

pass=0
fail=0
check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$name" "$want" "$got"
    fi
}

# --- fixtures -------------------------------------------------------------------

SID="a1b2c3d4-e5f6-7890-8bcd-0123456789d8"
SID_SHORT="a-e-7-8-08"

CFG="$TMP/cfg"
mkdir -p "$CFG/sessions"
export CLAUDE_CONFIG_DIR="$CFG"

# Fake tmux and no-op sound/powershell helpers first in PATH
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/tmux" <<'EOF'
#!/bin/bash
echo "TMUX=${TMUX:-} args=$*" >> "$FAKE_TMUX_LOG"
case "$*" in
    "display-message -p -t %5 #S") echo "box-1-session" ;;
    "display-message -p -t %7 #S") echo "kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk" ;;
esac
exit 0
EOF
for n in powershell.exe paplay pw-play ffplay pactl kitty; do
    printf '#!/bin/bash\nexit 0\n' > "$BIN/$n"
done
# Fake ps: the test shell sits right below a "kitty" process (pid 7000001), so the real
# kitty_tab_get_clean_title finds its window pid ($$) without a kitty running
cat > "$BIN/ps" <<'EOF'
#!/bin/bash
case "$*" in
    "-p $FAKE_PS_PID -o ppid=") echo 7000001 ;;
    "-p 7000001 -o comm=") echo kitty ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$BIN"/*
export FAKE_PS_PID=$$
export PATH="$BIN:$PATH"
export FAKE_TMUX_LOG="$TMP/tmux.log"
: > "$FAKE_TMUX_LOG"

# write_desc <pid> <sessionId> <name> <nameSource>
write_desc() {
    printf '{"pid": %s, "sessionId": "%s", "name": "%s", "nameSource": "%s"}\n' \
        "$1" "$2" "$3" "$4" > "$CFG/sessions/$1.json"
}

# mkproc <root> <pid> <ppid> <argv-with-US-separator> [environ items...]
# argv is one string, tokens separated by "|"
mkproc() {
    local root="$1" pid="$2" ppid="$3" argv="$4"
    shift 4
    mkdir -p "$root/$pid"
    printf '%s (proc) S %s 0 0 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 1000 0 0\n' "$pid" "$ppid" > "$root/$pid/stat"
    local IFS='|' tok
    : > "$root/$pid/cmdline"
    for tok in $argv; do printf '%s\0' "$tok" >> "$root/$pid/cmdline"; done
    : > "$root/$pid/environ"
    for tok in "$@"; do printf '%s\0' "$tok" >> "$root/$pid/environ"; done
}

# Daemon-hosted chain: hook 500 -> agent 400 -> pty-host 300 -> daemon 200 -> client 100
PROC="$TMP/proc-daemon"
mkproc "$PROC" 500 400 "bash|hook-notify.sh"
mkproc "$PROC" 400 300 "claude|--session-id|$SID" "TMUX_PANE=%9" "TMUX=/tmp/stray,1,0"
mkproc "$PROC" 300 200 "claude bg-pty-host|--bg-pty-host|/tmp/x.sock"
mkproc "$PROC" 200 100 "claude|daemon|run|--spawned-by|{\"pid\": 100}"
mkproc "$PROC" 100 50 "claude|--resume|alice-task" "HOME=/home/myuser" "TMUX=/tmp/tmux-1000/default,123,0" "TMUX_PANE=%5"
mkproc "$PROC" 50 1 "bash"

# Same, but the daemon was reparented to pid 1 (client only reachable via --spawned-by)
PROC_RP="$TMP/proc-reparent"
mkproc "$PROC_RP" 500 400 "bash|hook-notify.sh"
mkproc "$PROC_RP" 400 300 "claude|--session-id|$SID"
mkproc "$PROC_RP" 300 200 "claude bg-pty-host|--bg-pty-host|/tmp/x.sock"
mkproc "$PROC_RP" 200 1 "claude|daemon|run|--spawned-by|{\"pid\": 100}"
mkproc "$PROC_RP" 100 50 "claude|--resume|alice-task" "TMUX=/tmp/tmux-1000/default,123,0" "TMUX_PANE=%5"
mkproc "$PROC_RP" 50 1 "bash"

# Same, but --spawned-by names a process that is not a Claude client
PROC_BAD="$TMP/proc-badclient"
mkproc "$PROC_BAD" 500 400 "bash|hook-notify.sh"
mkproc "$PROC_BAD" 400 300 "claude|--session-id|$SID" "TMUX_PANE=%9" "TMUX=/tmp/stray,1,0"
mkproc "$PROC_BAD" 300 200 "claude bg-pty-host|--bg-pty-host|/tmp/x.sock"
mkproc "$PROC_BAD" 200 1 "claude|daemon|run|--spawned-by|{\"pid\": 100}"
mkproc "$PROC_BAD" 100 50 "vim|notes.txt" "TMUX=/tmp/tmux-1000/default,123,0" "TMUX_PANE=%5"
mkproc "$PROC_BAD" 50 1 "bash"

# Plain session without TMUX_PANE in the hook env, but in the Claude process env
PROC_PLAIN="$TMP/proc-plain"
mkproc "$PROC_PLAIN" 500 400 "bash|hook-notify.sh"
mkproc "$PROC_PLAIN" 400 50 "node|/opt/claude-code/cli.js" "TMUX=/tmp/tmux-1000/default,123,0" "TMUX_PANE=%5"
mkproc "$PROC_PLAIN" 50 1 "bash"

# Plain session, invalid pane value
PROC_INVALID="$TMP/proc-invalid"
mkproc "$PROC_INVALID" 500 400 "bash|hook-notify.sh"
PWNED="$TMP/pwned-sentinel"
mkproc "$PROC_INVALID" 400 50 "claude|--resume|x" "TMUX=/tmp/tmux-1000/default,123,0" "TMUX_PANE=%5;touch $PWNED"
mkproc "$PROC_INVALID" 50 1 "bash"

# Plain session, invalid TMUX value
PROC_INVALID_TMUX="$TMP/proc-invalid-tmux"
mkproc "$PROC_INVALID_TMUX" 500 400 "bash|hook-notify.sh"
mkproc "$PROC_INVALID_TMUX" 400 50 "claude|--resume|x" "TMUX=/tmp/t,1,0;touch $PWNED" "TMUX_PANE=%5"
mkproc "$PROC_INVALID_TMUX" 50 1 "bash"

# --- unit tests (sourced) ---------------------------------------------------------

unset TMUX TMUX_PANE SIGNAL_PROC_ROOT SIGNAL_START_PID
# shellcheck disable=SC1091
source "$SRC_DIR/repo-context.sh"

# short session id
check "sid_short normal" "$SID_SHORT" "$(signal_sid_short "$SID")"
check "sid_short no dash" "ac" "$(signal_sid_short "abc")"
check "sid_short empty" "??" "$(signal_sid_short "")"
check "sid_short bad chars" "ac" "$(signal_sid_short 'a;b$c')"

# user caption
# plain: the descriptor of an ancestor pid ($$ is the test shell, an ancestor of the subshell)
write_desc "$$" "$SID" "alice-task" "user"
check "caption user name" "alice-task" "$(signal_user_caption "$SID")"
write_desc "$$" "$SID" "derived name here" "derived"
check "caption derived ignored" "" "$(signal_user_caption "$SID")"
printf '{"pid": %s, "sessionId": "%s", "name": "no-source"}\n' "$$" "$SID" > "$CFG/sessions/$$.json"
check "caption without nameSource ignored" "" "$(signal_user_caption "$SID")"
write_desc "$$" "$SID" "abcdefghijklmnopqrstuvwxyz" "user"
check "caption cut to 20" "abcdefghijklmnopqrst" "$(signal_user_caption "$SID")"
printf '{"pid": %s, "sessionId": "%s", "name": "al\\nice\\u0007-x", "nameSource": "user"}\n' "$$" "$SID" > "$CFG/sessions/$$.json"
check "caption control chars removed" "alice-x" "$(signal_user_caption "$SID")"
write_desc "$$" "ffffffff-0000-1111-2222-333333333333" "other-session" "user"
check "caption other session ignored" "" "$(signal_user_caption "$SID")"
check "caption without sid accepts descriptor" "other-session" "$(signal_user_caption "")"
printf '{"pid": %s, "name": "no-sid-name", "nameSource": "user"}\n' "$$" > "$CFG/sessions/$$.json"
check "caption descriptor without sessionId skipped when sid known" "" "$(signal_user_caption "$SID")"
check "caption descriptor without sessionId accepted without sid" "no-sid-name" "$(signal_user_caption "")"
printf '{"pid": %s, "sessionId": "%s", "name": 42, "nameSource": "user"}\n' "$$" "$SID" > "$CFG/sessions/$$.json"
check "caption non-string name ignored" "" "$(signal_user_caption "$SID")"
# symlinked descriptor is never followed
write_desc "9999991" "$SID" "linked-name" "user"
rm -f "$CFG/sessions/$$.json"
ln -s "$CFG/sessions/9999991.json" "$CFG/sessions/$$.json"
check "caption symlink not followed" "" "$(signal_user_caption "$SID")"
rm -f "$CFG/sessions/$$.json" "$CFG/sessions/9999991.json"
check "caption no descriptor" "" "$(signal_user_caption "$SID")"
# a descriptor larger than the read cap is cut mid-JSON and ignored
{ printf '{"pid": %s, "sessionId": "%s", "nameSource": "user", "pad": "' "$$" "$SID"; head -c 300000 /dev/zero | tr '\0' x; printf '", "name": "late-name"}\n'; } > "$CFG/sessions/$$.json"
check "caption oversize descriptor ignored" "" "$(signal_user_caption "$SID")"
rm -f "$CFG/sessions/$$.json"
# daemon agent descriptor found through the fake process tree (pid 400)
write_desc 400 "$SID" "alice-agent" "user"
check "caption via ancestor pid" "alice-agent" "$(SIGNAL_PROC_ROOT="$PROC" SIGNAL_START_PID=500 signal_user_caption "$SID")"
rm -f "$CFG/sessions/400.json"

# a /rename title in the transcript (custom-title) is NOT a caption source
TR="$TMP/transcript.jsonl"
rm -f "$CFG/sessions/$$.json"
{ printf '{"type":"user","message":"hi"}\n'
  printf '{"type":"custom-title","customTitle":"alice-renamed-session-title","sessionId":"%s"}\n' "$SID"; } > "$TR"
check "caption transcript title not used" "" "$(signal_user_caption "$SID" "$TR")"
write_desc "$$" "$SID" "alice-desc" "user"
check "caption descriptor with transcript present" "alice-desc" "$(signal_user_caption "$SID" "$TR")"
write_desc "$$" "$SID" "derived name" "derived"
check "caption derived descriptor, transcript title not used" "" "$(signal_user_caption "$SID" "$TR")"
rm -f "$CFG/sessions/$$.json"

# client pane lookup
adopt() {
    local root="$1"
    ( unset TMUX TMUX_PANE
      SIGNAL_PROC_ROOT="$root" SIGNAL_START_PID=500 signal_adopt_client_tmux
      printf '%s|%s' "${TMUX:-}" "${TMUX_PANE:-}" )
}
check "adopt daemon client" "/tmp/tmux-1000/default,123,0|%5" "$(adopt "$PROC")"
check "adopt reparented daemon via spawned-by" "/tmp/tmux-1000/default,123,0|%5" "$(adopt "$PROC_RP")"
check "adopt refuses non-claude spawned-by client" "|" "$(adopt "$PROC_BAD")"
check "adopt plain claude env" "/tmp/tmux-1000/default,123,0|%5" "$(adopt "$PROC_PLAIN")"
check "adopt invalid pane refused" "|" "$(adopt "$PROC_INVALID")"
check "adopt invalid TMUX value refused" "|" "$(adopt "$PROC_INVALID_TMUX")"
check "no injected command ran" "absent" "$([ -e "$PWNED" ] && echo present || echo absent)"
check "adopt keeps existing pane" "/tmp/mine,1,0|%2" "$(
    export TMUX=/tmp/mine,1,0 TMUX_PANE=%2; SIGNAL_PROC_ROOT="$PROC" SIGNAL_START_PID=500 signal_adopt_client_tmux
    printf '%s|%s' "$TMUX" "$TMUX_PANE")"

# session label (body) in a daemon-hosted session
kitty_tab_get_clean_title() { printf '%s' "${FAKE_KITTY:-}"; }
FAKE_KITTY=""
check "session label tmux only (daemon)" "tmux: box-1-session" \
    "$(unset TMUX TMUX_PANE; SIGNAL_PROC_ROOT="$PROC" SIGNAL_START_PID=500 signal_session_label)"
FAKE_KITTY="tab-1"
check "session label tmux and kitty (daemon)" "tmux: box-1-session | kitty: tab-1" \
    "$(unset TMUX TMUX_PANE; SIGNAL_PROC_ROOT="$PROC" SIGNAL_START_PID=500 signal_session_label)"
check "session label without any pane" "kitty: tab-1" \
    "$(unset TMUX TMUX_PANE; SIGNAL_PROC_ROOT="$PROC_BAD" SIGNAL_START_PID=500 signal_session_label)"

# toast name order: caption -> kitty -> tmux -> short id
NOPROC="$TMP/proc-none"
mkproc "$NOPROC" 500 1 "bash"
name() { ( unset TMUX TMUX_PANE; SIGNAL_PROC_ROOT="${1:-$NOPROC}" SIGNAL_START_PID=500 signal_toast_name "$SID" ); }
FAKE_KITTY="tab-1"
write_desc 500 "$SID" "alice-task" "user"
check "name: caption first" "alice-task" "$(name)"
write_desc 500 "$SID" "alice-task" "derived"
check "name: derived caption skipped, kitty next" "tab-1" "$(name)"
FAKE_KITTY=""
check "name: tmux next (daemon client pane)" "box-1-session" "$(name "$PROC")"
check "name: short id last" "$SID_SHORT" "$(name)"
rm -f "$CFG/sessions/500.json"
check "name: no sid falls back to Claude Code" "Claude Code" \
    "$( unset TMUX TMUX_PANE; SIGNAL_PROC_ROOT="$NOPROC" SIGNAL_START_PID=500 signal_toast_name "" )"
FAKE_KITTY=$'tab\r\none\t\a'
check "name: kitty label sanitized (all control chars)" "tabone" "$(name)"
FAKE_KITTY="$(printf 'k%.0s' $(seq 1 70))"
K20="$(printf 'k%.0s' $(seq 1 20))"
check "name: long kitty label cut to 20" "$K20" "$(name)"
FAKE_KITTY=""
check "name: long tmux label cut to 20" "$K20" \
    "$(unset TMUX; TMUX_PANE=%7 SIGNAL_PROC_ROOT="$NOPROC" SIGNAL_START_PID=500 signal_toast_name "$SID")"
printf '{"type":"custom-title","customTitle":"alice-renamed"}\n' > "$TR"
FAKE_KITTY="tab-1"
check "name: transcript title not used, kitty wins" "tab-1" \
    "$( unset TMUX TMUX_PANE; SIGNAL_PROC_ROOT="$NOPROC" SIGNAL_START_PID=500 signal_toast_name "$SID" "$TR" )"
unset -f kitty_tab_get_clean_title

# real kitty_tab_get_clean_title (kitty-tab.sh) with the stub ps: display-file path
# (the "kitty @ ls" socket path needs a live kitty and is not covered here)
printf 'real-tab\n' > "$KITTY_DISPLAY_FILE"
real_name() {
    ( unset TMUX TMUX_PANE
      export CLAUDE_MB_KITTY_TAB=true
      # shellcheck disable=SC1091
      source "$SRC_DIR/kitty-tab.sh"
      SIGNAL_PROC_ROOT="$NOPROC" SIGNAL_START_PID=500 signal_toast_name "$SID" )
}
check "name: real kitty_tab_get_clean_title (display file)" "real-tab" "$(real_name)"
printf '%s\n' "$(printf 'r%.0s' $(seq 1 40))" > "$KITTY_DISPLAY_FILE"
check "name: real kitty title cut to 20" "$(printf 'r%.0s' $(seq 1 20))" "$(real_name)"
rm -f "$KITTY_DISPLAY_FILE"

# --- end-to-end: the hooks hand the resolved title to notify-replace.sh -------------

PLUGIN="$TMP/plugin"
mkdir -p "$PLUGIN"
cp -r "$SRC_DIR" "$PLUGIN/scripts"
cat > "$PLUGIN/scripts/notify-replace.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$2" > "$NOTIFY_OUT.title"
printf '%s\n' "$3" > "$NOTIFY_OUT.body"
EOF
chmod +x "$PLUGIN/scripts/notify-replace.sh"

WORK="$TMP/work/sigctx-proj-$$"
mkdir -p "$WORK"
export CLAUDE_MB_NOTIFY_SOUND_COMPLETE=0 CLAUDE_MB_NOTIFY_SOUND_ATTENTION=0 CLAUDE_MB_KITTY_TAB=false

# run_hook <script+args> <json> -> sets TITLE_OUT / BODY_OUT
run_hook() {
    local -a words
    read -r -a words <<< "$1"
    local json="$2"
    export NOTIFY_OUT="$TMP/out"
    rm -f "$NOTIFY_OUT.title" "$NOTIFY_OUT.body"
    rm -f "/tmp/claude-mb-notify-$(basename "$WORK")"
    ( cd "$WORK" && unset TMUX TMUX_PANE \
        && SIGNAL_PROC_ROOT="${E2E_PROC:-$NOPROC}" SIGNAL_START_PID=500 \
           bash "$PLUGIN/scripts/${words[0]}" "${words[@]:1}" <<< "$json" >/dev/null 2>>"$TMP/hook-err.log" )
    TITLE_OUT="$(cat "$NOTIFY_OUT.title" 2>/dev/null)"
    BODY_OUT="$(cat "$NOTIFY_OUT.body" 2>/dev/null)"
}

SHORT_CWD=".../work/$(basename "$WORK")"
# Done marker of the stop toast (U+2728 sparkles) as bytes, the stand-in for an event word
DONE_MARK=$(printf '\342\234\250')
E2E_PROC="$PROC"
write_desc 400 "$SID" "alice-task" "user"

STOP_JSON="{\"session_id\": \"$SID\", \"cwd\": \"$WORK\"}"
run_hook "stop-notify.sh" "$STOP_JSON"
check "stop title uses caption (done marker kept)" "$DONE_MARK alice-task | cwd: $SHORT_CWD" "$TITLE_OUT"
check "stop body keeps tmux line" "Task completed - check terminal for details"$'\n\n'"tmux: box-1-session" "$BODY_OUT"

NOTIF_JSON="{\"session_id\": \"$SID\", \"cwd\": \"$WORK\", \"notification_type\": \"permission_prompt\"}"
run_hook "hook-notify.sh notification" "$NOTIF_JSON"
check "notification title uses caption" "alice-task | cwd: $SHORT_CWD" "$TITLE_OUT"
check "notification body" "Permission required"$'\n\n'"tmux: box-1-session" "$BODY_OUT"

TOOL_JSON="{\"session_id\": \"$SID\", \"cwd\": \"$WORK\", \"tool_name\": \"Bash\", \"tool_input\": {\"command\": \"ls\"}}"
run_hook "hook-notify.sh PreToolUse" "$TOOL_JSON"
check "tool waiting title uses caption" "alice-task | cwd: $SHORT_CWD" "$TITLE_OUT"
check "tool waiting body" "Bash: ls"$'\n\n'"tmux: box-1-session" "$BODY_OUT"

run_hook "hook-notify.sh other" "{\"session_id\": \"$SID\", \"cwd\": \"$WORK\"}"
check "other hook title uses caption" "alice-task | cwd: $SHORT_CWD" "$TITLE_OUT"

# a transcript /rename title is ignored when the descriptor has no user name
write_desc 400 "$SID" "derived name" "derived"
E2E_TR="$TMP/$SID.jsonl"
printf '{"type":"custom-title","customTitle":"alice-renamed"}\n' > "$E2E_TR"
run_hook "hook-notify.sh notification" "{\"session_id\": \"$SID\", \"cwd\": \"$WORK\", \"transcript_path\": \"$E2E_TR\", \"notification_type\": \"permission_prompt\"}"
check "notification title ignores transcript title" "box-1-session | cwd: $SHORT_CWD" "$TITLE_OUT"
run_hook "stop-notify.sh" "{\"session_id\": \"$SID\", \"cwd\": \"$WORK\", \"transcript_path\": \"$E2E_TR\"}"
check "stop title ignores transcript title" "$DONE_MARK box-1-session | cwd: $SHORT_CWD" "$TITLE_OUT"

# derived caption and no transcript title: falls through to the tmux label of the client pane
run_hook "stop-notify.sh" "$STOP_JSON"
check "stop title tmux fallback" "$DONE_MARK box-1-session | cwd: $SHORT_CWD" "$TITLE_OUT"

# nothing but the session id
rm -f "$CFG/sessions/400.json"
E2E_PROC="$NOPROC"
run_hook "stop-notify.sh" "$STOP_JSON"
check "stop title short id fallback" "$DONE_MARK $SID_SHORT | cwd: $SHORT_CWD" "$TITLE_OUT"
check "stop body without session line" "Task completed - check terminal for details" "$BODY_OUT"
run_hook "hook-notify.sh PreToolUse" "$TOOL_JSON"
check "tool waiting title short id fallback" "$SID_SHORT | cwd: $SHORT_CWD" "$TITLE_OUT"

rm -f "/tmp/claude-mb-notify-$(basename "$WORK")"

if [ "$fail" -gt 0 ] && [ -s "$TMP/hook-err.log" ]; then
    echo "--- hook stderr ---"
    tail -n 20 "$TMP/hook-err.log"
fi
echo "test-repo-context: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
