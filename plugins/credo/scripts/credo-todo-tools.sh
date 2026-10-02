#!/bin/bash
# credo-todo-tools - check / enable the Claude Code task-list tools opt-in.
#
# Newer Claude Code versions offer the task-list tools (TaskCreate, TaskGet,
# TaskUpdate, TaskList) by default only on older models; on newer models they are
# missing unless the variable CLAUDE_CODE_ENABLE_TODO_TOOLS is "1" (Claude Code
# >= 2.1.233). credo uses that list as its ephemeral coordination layer (items
# skill: [GO]/[HOLD]/[REMINDER] entries, the §cct_N refs, orchestration), and
# subagents only get the tools when the parent session has them.
#
# "On" (is-on, state=on) means: the process environment has
# CLAUDE_CODE_ENABLE_TODO_TOOLS=1, OR the "env" object of the ACTIVE profile settings
# file (${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json) sets it to the STRING "1"
# (a JSON number 1 or any other value does not count). "On" therefore means "opted in",
# not necessarily "available in the running session": a value just written to
# settings.json may only reach the session after a restart of Claude Code. The process
# environment is what this script inherited - run from inside a Claude Code session
# (Bash tool or hook) that is the session's environment. `status` reports both sides.
#
# Usage:
#   credo-todo-tools.sh status        key=value lines:
#                                       state=on|off        is-on result (process OR settings)
#                                       source=process|settings|none
#                                       in_process=on|off   this process env (the session)
#                                       in_settings=on|off  the profile settings.json
#                                       restart_needed=yes|no  settings on, session off
#                                       summary=...         e.g. "on (settings), session:
#                                                           off -> restart needed"
#                                       settings, declined, last_hint
#   credo-todo-tools.sh is-on         exit 0 when on, 1 when off
#   credo-todo-tools.sh enable        back up settings.json, then set the variable in
#                                     its "env" object (JSON-safe, every other key and
#                                     the key order kept; a symlinked settings.json is
#                                     edited at its target). The file is rewritten with
#                                     2-space indentation, so its formatting may change;
#                                     the backup keeps the original bytes. Prints
#                                     backup=<path>. Only run this after the user said yes.
#   credo-todo-tools.sh decline       never hint about it again (this profile)
#   credo-todo-tools.sh undecline     allow the periodic hint again
#   credo-todo-tools.sh hint-due      exit 0 when a session-start hint is due: off, not
#                                     declined, and no hint in the last N days (a
#                                     last-hint in the future counts as due)
#   credo-todo-tools.sh hinted [EPOCH]  record that the hint was shown (default: now)
#
# State (per profile): ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/todo-tools/
#   declined   present = "never ask again"
#   last-hint  epoch seconds of the last hint
#
# Env overrides (tests / custom config):
#   CREDO_TODO_TOOLS_DIR         state dir
#   CREDO_TODO_TOOLS_HINT_DAYS   days between hints (default 7)
#   CREDO_TODO_TOOLS_NOW         "now" as epoch seconds
#
# Exit codes: 0 ok, 1 bad arguments / off / not due, 2 settings.json not editable
# (invalid JSON, its "env" is not an object, or the backup / write failed, e.g. a
# read-only profile dir) - settings.json was not changed then.

set -uo pipefail

VAR="CLAUDE_CODE_ENABLE_TODO_TOOLS"
PROFILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$PROFILE/settings.json"
STATE_DIR="${CREDO_TODO_TOOLS_DIR:-$PROFILE/credo/todo-tools}"
DAYS="${CREDO_TODO_TOOLS_HINT_DAYS:-7}"
[[ "$DAYS" =~ ^[0-9]+$ ]] || DAYS=7

usage() {
    echo "usage: credo-todo-tools.sh {status|is-on|enable|decline|undecline|hint-due|hinted [EPOCH]}" >&2
    exit 1
}

now() {
    if [[ "${CREDO_TODO_TOOLS_NOW:-}" =~ ^[0-9]+$ ]]; then printf '%s\n' "$CREDO_TODO_TOOLS_NOW"; else date +%s; fi
}

# Prints the value from the settings file ("" when unset / unreadable). Non-string
# values are printed as "json:<value>" so a number 1 never compares equal to "1".
settings_value() {
    [ -f "$SETTINGS" ] || { printf '\n'; return 0; }
    python3 - "$SETTINGS" "$VAR" <<'PY' 2>/dev/null || printf '\n'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    block = d.get("env") if isinstance(d, dict) else None
    v = block.get(sys.argv[2], "") if isinstance(block, dict) else ""
    print(v if isinstance(v, str) else "json:" + json.dumps(v))
except Exception:
    print("")
PY
}

in_process() { [ "${CLAUDE_CODE_ENABLE_TODO_TOOLS:-}" = "1" ]; }
in_settings() { [ "$(settings_value)" = "1" ]; }

# Prints "process", "settings" or "none".
source_of_on() {
    if in_process; then echo process; return; fi
    if in_settings; then echo settings; return; fi
    echo none
}

is_on() { [ "$(source_of_on)" != "none" ]; }
is_declined() { [ -f "$STATE_DIR/declined" ]; }

write_state() { # name value
    mkdir -p "$STATE_DIR" || return 1
    local tmp
    tmp="$(mktemp "$STATE_DIR/.$1.XXXXXX")" || return 1
    printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$STATE_DIR/$1"
}

[ $# -ge 1 ] || usage
CMD="$1"
shift

case "$CMD" in
    status)
        src="$(source_of_on)"
        state=on
        [ "$src" = none ] && state=off
        proc=off; in_process && proc=on
        sett=off; in_settings && sett=on
        restart=no
        [ "$sett" = on ] && [ "$proc" = off ] && restart=yes
        if [ "$sett" = on ]; then summary="on (settings), session: $proc"
        elif [ "$proc" = on ]; then summary="on (process only), settings: off"
        else summary="off (settings and session)"; fi
        [ "$restart" = yes ] && summary="$summary -> restart needed"
        declined=no
        is_declined && declined=yes
        printf 'state=%s\nsource=%s\nin_process=%s\nin_settings=%s\nrestart_needed=%s\nsummary=%s\nsettings=%s\ndeclined=%s\nlast_hint=%s\n' \
            "$state" "$src" "$proc" "$sett" "$restart" "$summary" "$SETTINGS" "$declined" \
            "$(head -n1 "$STATE_DIR/last-hint" 2>/dev/null | tr -d '[:space:]')"
        ;;
    is-on)
        is_on
        ;;
    enable)
        command -v python3 >/dev/null 2>&1 || { echo "credo-todo-tools: python3 is required" >&2; exit 2; }
        mkdir -p "$PROFILE" || exit 2
        python3 - "$SETTINGS" "$VAR" "$(now)" <<'PY'
import json, os, shutil, sys, tempfile

path, var, stamp = sys.argv[1], sys.argv[2], sys.argv[3]
real = os.path.realpath(path)
data = {}
if os.path.exists(real):
    try:
        with open(real, encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"credo-todo-tools: {path} is not valid JSON ({e}); nothing changed", file=sys.stderr)
        sys.exit(2)
    if not isinstance(data, dict):
        print(f"credo-todo-tools: {path} is not a JSON object; nothing changed", file=sys.stderr)
        sys.exit(2)
block = data.get("env")
if block is None:
    block = {}
if not isinstance(block, dict):
    print(f"credo-todo-tools: \"env\" in {path} is not an object; nothing changed", file=sys.stderr)
    sys.exit(2)
if block.get(var) == "1":
    print(f"already enabled in {path}")
    sys.exit(0)

block[var] = "1"
data["env"] = block
backup = ""
tmp = ""
try:
    if os.path.exists(real):
        candidate = f"{real}.credo-bak.{stamp}"
        n = 1
        while os.path.exists(candidate):
            candidate = f"{real}.credo-bak.{stamp}.{n}"
            n += 1
        shutil.copy2(real, candidate)
        backup = candidate
    fd, tmp = tempfile.mkstemp(prefix=".settings.", dir=os.path.dirname(real))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    if os.path.exists(real):
        shutil.copymode(real, tmp)
    else:
        os.chmod(tmp, 0o644)
    os.replace(tmp, real)
except Exception as e:
    # Roll back only what this run created; settings.json itself was never touched
    # (os.replace is the last step and atomic).
    for leftover in (tmp, backup):
        if leftover:
            try:
                os.unlink(leftover)
            except OSError:
                pass
    print(f"credo-todo-tools: write failed ({e}); nothing changed", file=sys.stderr)
    sys.exit(2)
print(f"enabled {var}=1 in {path}")
if backup:
    print(f"backup={backup}")
PY
        ;;
    decline)
        write_state declined "$(now)" || exit 1
        echo "credo-todo-tools: hint declined for this profile (undo: credo-todo-tools.sh undecline)"
        ;;
    undecline)
        rm -f -- "$STATE_DIR/declined"
        echo "credo-todo-tools: periodic hint allowed again"
        ;;
    hint-due)
        is_on && exit 1
        is_declined && exit 1
        last="$(head -n1 "$STATE_DIR/last-hint" 2>/dev/null | tr -d '[:space:]')"
        [[ "$last" =~ ^[0-9]+$ ]] || exit 0
        t="$(now)"
        [ "$last" -gt "$t" ] && exit 0 # future stamp (clock skew, bad value): due
        [ $(( t - last )) -ge $(( DAYS * 86400 )) ]
        ;;
    hinted)
        v="${1:-$(now)}"
        [[ "$v" =~ ^[0-9]+$ ]] || usage
        write_state last-hint "$v" || exit 1
        ;;
    *)
        usage
        ;;
esac
