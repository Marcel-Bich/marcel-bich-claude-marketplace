#!/bin/bash
# Dogma: Update Notices (SessionStart Hook)
#
# After a plugin update that adds something the user should act on, tell Claude
# ONCE per repo via hookSpecificOutput.additionalContext; Claude then asks the
# user (Run / Later / Never). The notice list and the per-repo relevance check
# live in scripts/notices-pending.sh. Nothing in the repo is ever changed here.
#
# Silent (no output) when nothing is pending; always exits 0.
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch
# ENV: CLAUDE_MB_DOGMA_NOTICES=true (default) | false

trap 'exit 0' ERR

if [ "${CLAUDE_MB_DOGMA_DEBUG:-false}" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    echo "=== notices-inject.sh START $(date) ===" >&2
fi

[ "${CLAUDE_MB_DOGMA_ENABLED:-true}" = "true" ] || exit 0
[ "${CLAUDE_MB_DOGMA_NOTICES:-true}" = "true" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$PLUGIN_ROOT/scripts/notices-pending.sh"
[ -x "$SCRIPT" ] || exit 0

# hook stdin carries the session cwd; fall back to $PWD
INPUT="$(cat 2>/dev/null || true)"
CWD="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("cwd") or "")
except Exception:
    print("")
' 2>/dev/null)"
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD="$PWD"

PENDING="$("$SCRIPT" --json "$CWD" 2>/dev/null)" || exit 0
[ -n "$PENDING" ] || exit 0

printf '%s' "$PENDING" | SCRIPT="$SCRIPT" CWD="$CWD" python3 -c '
import json, os, shlex, sys

data = json.load(sys.stdin)
notices = data.get("notices") or []
if not notices:
    sys.exit(0)
mark = shlex.quote(os.environ["SCRIPT"]) + " mark"
repo = shlex.quote(data.get("repo") or os.environ["CWD"])

lines = [
    "[dogma] Update notice(s) for this repo ({} pending). A dogma update added something the user may want to act on:".format(len(notices)),
]
for n in notices:
    lines.append("- {id}: {text} Action: {action}".format(**n))
lines += [
    "",
    "How to handle them (do not change anything in the repo on your own):",
    "- Do not interrupt urgent work; raise this at the first natural pause.",
    "- If a human is present: ask via your Ask tool (AskUserQuestion), one question per notice, options \"Run <action>\", \"Later\", \"Never\". Without an Ask tool, ask the same in plain text.",
    "- Run: run the action; only after it completed, mark the notice seen: {} <id> {}".format(mark, repo),
    "- Never: mark the notice seen with the same command (it will not come back for this repo).",
    "- Later: do nothing; it is shown again next session.",
    "- If running unattended/autonomously (no human present): do NOT ask and do not run the action; leave the notice pending.",
]
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "\n".join(lines),
    }
}))
' 2>/dev/null

exit 0
