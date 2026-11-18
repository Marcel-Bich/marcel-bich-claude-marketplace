#!/usr/bin/env bash
# credo-py.sh - credo plugin: run a credo Python hook script with a working Python 3.
#
# Usage (hooks.json): credo-py.sh <script.py> [args...]
#
# python3 is a requirement of credo. A plain shebang (#!/usr/bin/env python3) fails visibly
# on native Windows when python3 is only the Microsoft Store alias stub ("Python was not
# found ...", exit 49). This launcher probes python3, then python (credo-python-lib.sh) and
# execs the script with the first one that really is Python 3; stdin (the hook input) and the
# exit code pass through unchanged.
#
# Without a working Python 3 the script is not run. Instead the user gets ONE clear message
# per session (systemMessage; at SessionStart also a line for the agent) naming the install
# command for this platform. The sessions that saw it are kept in
# ${XDG_STATE_HOME:-~/.local/state}/credo/python-missing-shown (the last 50 session ids).
# This path always exits 0, so it never blocks a tool call or a session start.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
# shellcheck source-path=SCRIPTDIR source=credo-python-lib.sh
. "$HOOK_DIR/credo-python-lib.sh" 2>/dev/null || exit 0

script="${1:-}"
[ -n "$script" ] && [ -f "$script" ] || exit 0
shift

if credo_find_python; then
    exec "$CREDO_PYTHON" "$script" "$@"
fi

# --- no working Python 3: one message per session -----------------------------------------
trap 'exit 0' ERR
input="$(cat 2>/dev/null || true)"
field() { # name -> value of a top-level "name": "value" string in the hook input
    printf '%s' "$input" | tr -d '\n' | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}
sid="$(field session_id | tr -cd 'A-Za-z0-9._-')"
event="$(field hook_event_name | tr -cd 'A-Za-z')"
[ -n "$sid" ] || sid="ppid-${PPID:-0}"

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/credo"
flag="$state_dir/python-missing-shown"
if [ -f "$flag" ] && grep -qxF "$sid" "$flag" 2>/dev/null; then
    exit 0
fi
if mkdir -p "$state_dir" 2>/dev/null; then
    { tail -n 49 "$flag" 2>/dev/null; printf '%s\n' "$sid"; } > "$flag.$$" 2>/dev/null \
        && mv -f "$flag.$$" "$flag" 2>/dev/null
fi

what="python3 is missing"
credo_python_is_stub && what="python3 and python are only the Microsoft Store alias stub (WindowsApps)"
hint="$(credo_python_install_hint)"
# Plain text only: no double quotes or backslashes, so the JSON below needs no escaping.
MESSAGE="credo needs python3, but no working Python 3 was found: ${what}. credo hooks that need Python are skipped until it is installed. Install: ${hint}."
if [ "$event" = "SessionStart" ]; then
    CONTEXT="[credo] python3 is a requirement of credo and no working Python 3 was found on this machine (${what}). credo hooks that need Python (provenance ledger, session registry, reminders, peer features) are skipped. Tell the user once, prominently, and name the install command: ${hint}. Never install anything yourself without the user's explicit yes (/credo:setup offers it)."
    printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$MESSAGE" "$CONTEXT"
else
    printf '{"systemMessage":"%s"}\n' "$MESSAGE"
fi
exit 0
