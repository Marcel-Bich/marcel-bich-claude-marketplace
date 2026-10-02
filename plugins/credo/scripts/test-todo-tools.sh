#!/bin/bash
# Tests for scripts/credo-todo-tools.sh and hooks/credo-todo-tools-hint.sh.
# Uses a fake CLAUDE_CONFIG_DIR in a temp dir (removed on exit); never touches a
# real settings.json. Usage: bash test-todo-tools.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$SCRIPT_DIR/credo-todo-tools.sh"
HOOK="$SCRIPT_DIR/../hooks/credo-todo-tools-hint.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-todo-tools-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
contains() { # name needle haystack
    case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing: %s\n  in:      %s\n' "$1" "$2" "$3" ;; esac
}
jget() { # file python-expression-on-d
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

export CLAUDE_CONFIG_DIR="$TMP/profile"
export CREDO_SESSION_MODES_DIR="$TMP/modes" CREDO_SESSION_DECISIONS_DIR="$TMP/decisions"
export CREDO_DIR_DECISIONS_DIR="$TMP/dirdec" CREDO_AUTONOMY_DIR="$TMP/autonomy"
unset CLAUDE_CODE_ENABLE_TODO_TOOLS CREDO_TODO_TOOLS_DIR CREDO_TODO_TOOLS_HINT CREDO_TODO_TOOLS_HINT_DAYS
mkdir -p "$CLAUDE_CONFIG_DIR" "$CREDO_SESSION_MODES_DIR" "$CREDO_SESSION_DECISIONS_DIR"
SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
NOW=1000000000
export CREDO_TODO_TOOLS_NOW="$NOW"

# --- status: no settings file -> off --------------------------------------
"$TOOL" is-on; check "no settings -> is-on fails" 1 "$?"
contains "status off" "state=off" "$("$TOOL" status)"
contains "status names the settings path" "settings=$SETTINGS" "$("$TOOL" status)"

# --- process env wins ------------------------------------------------------
CLAUDE_CODE_ENABLE_TODO_TOOLS=1 "$TOOL" is-on; check "process env 1 -> on" 0 "$?"
contains "process source" "source=process" "$(CLAUDE_CODE_ENABLE_TODO_TOOLS=1 "$TOOL" status)"
CLAUDE_CODE_ENABLE_TODO_TOOLS=0 "$TOOL" is-on; check "process env 0 -> off" 1 "$?"

# --- settings: other content, value missing -> off --------------------------
cat > "$SETTINGS" <<'EOF'
{
  "model": "x",
  "env": {
    "FOO": "bar"
  },
  "permissions": {"allow": ["Bash(ls)"]}
}
EOF
chmod 640 "$SETTINGS"
"$TOOL" is-on; check "env without key -> off" 1 "$?"

# --- enable: backup + JSON-safe write --------------------------------------
out="$("$TOOL" enable)"; rc=$?
check "enable exit" 0 "$rc"
contains "enable reports backup" "backup=" "$out"
check "key written" "1" "$(jget "$SETTINGS" 'd["env"]["CLAUDE_CODE_ENABLE_TODO_TOOLS"]')"
check "other env kept" "bar" "$(jget "$SETTINGS" 'd["env"]["FOO"]')"
check "other top-level kept" "x" "$(jget "$SETTINGS" 'd["model"]')"
check "nested kept" "Bash(ls)" "$(jget "$SETTINGS" 'd["permissions"]["allow"][0]')"
check "key order kept" "['model', 'env', 'permissions']" "$(jget "$SETTINGS" 'list(d)')"
check "file mode kept" "640" "$(stat -c %a "$SETTINGS")"
bak="$(printf '%s\n' "$out" | sed -n 's/^backup=//p')"
[ -f "$bak" ]; check "backup exists" 0 "$?"
check "backup holds old content" "None" "$(jget "$bak" 'd["env"].get("CLAUDE_CODE_ENABLE_TODO_TOOLS")')"
"$TOOL" is-on; check "after enable -> on" 0 "$?"
contains "settings source" "source=settings" "$("$TOOL" status)"
# status separates the settings file from the running process (session)
st="$("$TOOL" status)"
contains "status in_settings on" "in_settings=on" "$st"
contains "status in_process off" "in_process=off" "$st"
contains "status restart needed" "restart_needed=yes" "$st"
contains "status summary" "summary=on (settings), session: off -> restart needed" "$st"
st="$(CLAUDE_CODE_ENABLE_TODO_TOOLS=1 "$TOOL" status)"
contains "status both on" "in_process=on" "$st"
contains "status both on no restart" "restart_needed=no" "$st"
contains "status summary both" "summary=on (settings), session: on" "$st"

# --- enable again: idempotent, no new backup --------------------------------
n_before="$(find "$CLAUDE_CONFIG_DIR" -maxdepth 1 -name '*credo-bak*' | wc -l)"
out="$("$TOOL" enable)"; rc=$?
check "enable again exit" 0 "$rc"
contains "enable again says already" "already" "$out"
check "no second backup" "$n_before" "$(find "$CLAUDE_CONFIG_DIR" -maxdepth 1 -name '*credo-bak*' | wc -l)"

# --- enable with no env block / missing file --------------------------------
printf '{"theme":"dark"}\n' > "$SETTINGS"
"$TOOL" enable >/dev/null; check "no env block -> enable ok" 0 "$?"
check "env block created" "1" "$(jget "$SETTINGS" 'd["env"]["CLAUDE_CODE_ENABLE_TODO_TOOLS"]')"
check "theme kept" "dark" "$(jget "$SETTINGS" 'd["theme"]')"
P2="$TMP/profile2"; mkdir -p "$P2"
CLAUDE_CONFIG_DIR="$P2" "$TOOL" enable >/dev/null; check "missing file -> enable ok" 0 "$?"
check "missing file created" "1" "$(jget "$P2/settings.json" 'd["env"]["CLAUDE_CODE_ENABLE_TODO_TOOLS"]')"

# --- invalid JSON / wrong env type: refuse, file untouched -------------------
printf '{"broken": \n' > "$SETTINGS"
"$TOOL" enable >/dev/null 2>&1; check "invalid json -> exit 2" 2 "$?"
check "invalid json untouched" '{"broken": ' "$(cat "$SETTINGS")"
printf '{"env": "nope"}\n' > "$SETTINGS"
"$TOOL" enable >/dev/null 2>&1; check "env not an object -> exit 2" 2 "$?"
check "wrong env untouched" '{"env": "nope"}' "$(cat "$SETTINGS")"

# --- number 1 is not "1": off, and enable rewrites it as the string ---------
printf '{"env":{"CLAUDE_CODE_ENABLE_TODO_TOOLS":1}}\n' > "$SETTINGS"
"$TOOL" is-on; check "number 1 -> off" 1 "$?"
contains "number 1 -> in_settings off" "in_settings=off" "$("$TOOL" status)"
"$TOOL" enable >/dev/null; check "number 1 -> enable ok" 0 "$?"
check "number 1 -> string 1" "'1'" "$(jget "$SETTINGS" 'repr(d["env"]["CLAUDE_CODE_ENABLE_TODO_TOOLS"])')"
check "written with 2-space indent" '  "env": {' "$(sed -n 2p "$SETTINGS")"

# --- unwritable profile dir: exit 2, no traceback, file unchanged -------------
if [ "$(id -u)" != 0 ]; then
    printf '{"env":{}}\n' > "$SETTINGS"
    n_bak="$(find "$CLAUDE_CONFIG_DIR" -maxdepth 1 -name '*credo-bak*' | wc -l)"
    chmod 555 "$CLAUDE_CONFIG_DIR"
    err="$("$TOOL" enable 2>&1 >/dev/null)"; rc=$?
    chmod 755 "$CLAUDE_CONFIG_DIR"
    check "read-only dir -> exit 2" 2 "$rc"
    case "$err" in *Traceback*) check "read-only dir -> no traceback" "no traceback" "$err" ;; *) check "read-only dir -> no traceback" x x ;; esac
    contains "read-only dir -> says nothing changed" "nothing changed" "$err"
    check "read-only dir -> file unchanged" '{"env":{}}' "$(cat "$SETTINGS")"
    check "read-only dir -> no new backup" "$n_bak" "$(find "$CLAUDE_CONFIG_DIR" -maxdepth 1 -name '*credo-bak*' | wc -l)"
    check "read-only dir -> no temp file" "0" "$(find "$CLAUDE_CONFIG_DIR" -maxdepth 1 -name '.settings.*' | wc -l)"
fi

# --- symlinked settings.json: the target is edited, the link stays ----------
mkdir -p "$TMP/dotfiles"
printf '{"env":{}}\n' > "$TMP/dotfiles/settings.json"
rm -f -- "$SETTINGS"
ln -s "$TMP/dotfiles/settings.json" "$SETTINGS"
"$TOOL" enable >/dev/null; check "symlink -> enable ok" 0 "$?"
[ -L "$SETTINGS" ]; check "symlink kept" 0 "$?"
check "symlink target edited" "1" "$(jget "$TMP/dotfiles/settings.json" 'd["env"]["CLAUDE_CODE_ENABLE_TODO_TOOLS"]')"
rm -f -- "$SETTINGS"
printf '{"env":{"CLAUDE_CODE_ENABLE_TODO_TOOLS":"0"}}\n' > "$SETTINGS"

# --- hint-due / hinted / decline -------------------------------------------
"$TOOL" hint-due; check "off, never hinted -> due" 0 "$?"
"$TOOL" hinted >/dev/null
"$TOOL" hint-due; check "just hinted -> not due" 1 "$?"
CREDO_TODO_TOOLS_NOW=$((NOW + 6 * 86400)) "$TOOL" hint-due; check "6 days later -> not due" 1 "$?"
CREDO_TODO_TOOLS_NOW=$((NOW + 7 * 86400)) "$TOOL" hint-due; check "7 days later -> due" 0 "$?"
CREDO_TODO_TOOLS_HINT_DAYS=2 CREDO_TODO_TOOLS_NOW=$((NOW + 2 * 86400)) "$TOOL" hint-due; check "custom days" 0 "$?"
CLAUDE_CODE_ENABLE_TODO_TOOLS=1 CREDO_TODO_TOOLS_NOW=$((NOW + 30 * 86400)) "$TOOL" hint-due; check "on -> never due" 1 "$?"
"$TOOL" hinted $((NOW + 5 * 86400)) >/dev/null
"$TOOL" hint-due; check "future last-hint -> due (clamped)" 0 "$?"
"$TOOL" hinted "$NOW" >/dev/null
"$TOOL" decline >/dev/null
contains "status shows declined" "declined=yes" "$("$TOOL" status)"
CREDO_TODO_TOOLS_NOW=$((NOW + 30 * 86400)) "$TOOL" hint-due; check "declined -> never due" 1 "$?"
"$TOOL" undecline >/dev/null
CREDO_TODO_TOOLS_NOW=$((NOW + 30 * 86400)) "$TOOL" hint-due; check "undecline -> due again" 0 "$?"
"$TOOL" bogus >/dev/null 2>&1; check "bad command -> exit 1" 1 "$?"

# --- hook -------------------------------------------------------------------
STATE_DIR="$CLAUDE_CONFIG_DIR/credo/todo-tools"
reset_hint() { rm -f -- "$STATE_DIR/last-hint"; }
SID="sess-1"
hook() { # source [session]
    printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"%s"}' "${2:-$SID}" "$1" | "$HOOK"
}
mkdir -p "$TMP/work"
cd "$TMP/work" || exit 1
reset_hint

check "credo not active -> silent" "" "$(hook startup)"
check "credo not active -> not marked" "" "$(cat "$STATE_DIR/last-hint" 2>/dev/null)"
"$SCRIPT_DIR/credo-dir-decision.sh" set accepted >/dev/null
out="$(hook startup)"
contains "active startup -> hint" "CLAUDE_CODE_ENABLE_TODO_TOOLS" "$out"
contains "hint names enable" "credo-todo-tools.sh\\\" enable" "$out"
contains "hint names decline" "credo-todo-tools.sh\\\" decline" "$out"
contains "hint is additionalContext" "additionalContext" "$out"
check "hint marked" "$NOW" "$(cat "$STATE_DIR/last-hint" 2>/dev/null)"
check "second start same week -> silent" "" "$(hook startup)"
check "resume -> silent" "" "$(CREDO_TODO_TOOLS_NOW=$((NOW + 8 * 86400)) hook resume)"
contains "8 days later -> hint again" "CLAUDE_CODE_ENABLE_TODO_TOOLS" "$(CREDO_TODO_TOOLS_NOW=$((NOW + 8 * 86400)) hook clear)"

reset_hint
printf 'autonomous\n' > "$CREDO_SESSION_MODES_DIR/$SID"
check "autonomous mode -> silent" "" "$(hook startup)"
check "autonomous -> not marked" "" "$(cat "$STATE_DIR/last-hint" 2>/dev/null)"
rm -f -- "$CREDO_SESSION_MODES_DIR/$SID"
mkdir -p "$CREDO_AUTONOMY_DIR/$SID"; : > "$CREDO_AUTONOMY_DIR/$SID/active"
check "autonomy running -> silent" "" "$(hook startup)"
rm -f -- "$CREDO_AUTONOMY_DIR/$SID/active"

CLAUDE_CODE_ENABLE_TODO_TOOLS=1 hook startup >"$TMP/o" ; check "on -> silent" "" "$(cat "$TMP/o")"
"$TOOL" decline >/dev/null
check "declined -> silent" "" "$(hook startup)"
"$TOOL" undecline >/dev/null
check "toggle off -> silent" "" "$(CREDO_TODO_TOOLS_HINT=false hook startup)"
"$SCRIPT_DIR/credo-dir-decision.sh" set declined >/dev/null
check "credo declined here -> silent" "" "$(hook startup)"
"$SCRIPT_DIR/credo-dir-decision.sh" set accepted >/dev/null

# the hint text puts the autonomous rule first (mode may not be set yet at start)
reset_hint
out="$(hook startup)"
first="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | head -n1)"
contains "autonomous rule leads the hint" "autonomous" "$first"
contains "autonomous rule says never ask" "do NOT ask" "$first"

# --- one credo opt-in question per start: optimize hook asks first -----------
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
printf '[user]\n\tname = Test\n\temail = test@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
export CREDO_OPTIMIZE_DIR="$TMP/optstore" CREDO_GLOBAL="$TMP/no-global" CREDO_PROFILE="$TMP/no-profile" CREDO_TASK_BACKEND=credo
OSTATE="$SCRIPT_DIR/credo-optimize-state.sh"
R="$TMP/repo"; git init -q "$R"; cd "$R" || exit 1
"$SCRIPT_DIR/credo-dir-decision.sh" set accepted >/dev/null
reset_hint
check "optimize opt-in open -> todo hint silent" "" "$(hook startup)"
check "optimize opt-in open -> slot not consumed" "" "$(cat "$STATE_DIR/last-hint" 2>/dev/null)"
check "optimize hook off -> (control) todo hint shows" "x" "$(CREDO_OPTIMIZE_HOOK=false hook startup | grep -q CLAUDE_CODE_ENABLE_TODO_TOOLS && echo x)"
reset_hint
"$OSTATE" optin no >/dev/null
contains "optimize opt-in answered no -> todo hint" "CLAUDE_CODE_ENABLE_TODO_TOOLS" "$(hook startup)"
reset_hint
"$OSTATE" optin yes >/dev/null
"$OSTATE" pending >/dev/null
check "optimize offer pending -> todo hint silent" "" "$(hook startup)"
check "optimize pending -> slot not consumed" "" "$(cat "$STATE_DIR/last-hint" 2>/dev/null)"
"$OSTATE" offered >/dev/null
"$OSTATE" seen >/dev/null
contains "optin yes, not idle, nothing pending -> todo hint" "CLAUDE_CODE_ENABLE_TODO_TOOLS" "$(hook startup)"
reset_hint
# idle repo with optin yes: the optimize hook would detect a returner now
OLD="$(date -d @$(( $(date +%s) - 30 * 86400 )) +%Y%m%d%H%M.%S)"
"$OSTATE" seen $(( $(date +%s) - 30 * 86400 )) >/dev/null
for f in "$R/.git/index" "$R/.git/logs/HEAD"; do [ -e "$f" ] && touch -t "$OLD" "$f"; done
check "optimize returner idle -> todo hint silent" "" "$(hook startup)"
check "optimize gsd backend -> todo hint shows" "x" "$(CREDO_TASK_BACKEND=gsd hook startup | grep -q CLAUDE_CODE_ENABLE_TODO_TOOLS && echo x)"
cd "$TMP/work" || exit 1
reset_hint

out="$(printf 'not json' | "$HOOK")"; rc=$?
check "garbage stdin exit" 0 "$rc"
check "garbage stdin silent" "" "$out"
contains "valid start after all -> hint" "CLAUDE_CODE_ENABLE_TODO_TOOLS" "$(hook startup)"

printf 'test-todo-tools: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
