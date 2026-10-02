#!/bin/bash
# Dogma: Update Notices (SessionStart Hook)
#
# After a plugin update that adds something the user should act on, or when the
# user's dogma source (CLAUDE_MB_DOGMA_SOURCE) broadcasts an entry in its
# NOTICES.md, tell Claude ONCE per repo via hookSpecificOutput.additionalContext;
# Claude then asks the user (Run / Later / Never). The notice list, the per-repo
# relevance check and the seen state live in scripts/notices-pending.sh (context:
# the git toplevel of the session cwd, else the credo pinned project, else the cwd
# itself when a DOGMA-PERMISSIONS.md applies there, also outside git; the "repo" is
# the directory of the effective DOGMA-PERMISSIONS.md the notices concern; source
# broadcasts via scripts/source-cache.sh, whose fetch runs in the background and
# never delays the session). Nothing in the repo is ever changed here.
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
# session id for the credo pin lookup (a session started in a folder outside any repo
# gets the notices of its credo pinned project, see notices-pending.sh)
DOGMA_SESSION_ID="$(printf '%s' "$INPUT" | python3 -c '
import json, re, sys
try:
    sid = json.load(sys.stdin).get("session_id") or ""
except Exception:
    sid = ""
print(sid if re.fullmatch(r"[A-Za-z0-9._-]+", sid) else "")
' 2>/dev/null)"
export DOGMA_SESSION_ID

PENDING="$("$SCRIPT" --json --hint "$CWD" 2>/dev/null)" || exit 0
[ -n "$PENDING" ] || exit 0

printf '%s' "$PENDING" | SCRIPT="$SCRIPT" CWD="$CWD" python3 -c '
import json, os, shlex, sys

data = json.load(sys.stdin)
notices = data.get("notices") or []
hint = data.get("hint") or ""
if not notices and not hint:
    sys.exit(0)
mark = shlex.quote(os.environ["SCRIPT"]) + " mark"
repo_dir = data.get("repo") or os.environ["CWD"]
repo = shlex.quote(repo_dir)

lines = []
if notices:
    lines.append("[dogma] Update notice(s) for {} ({} pending). A dogma plugin update or the user\x27s dogma source announced something the user may want to act on:".format(repo_dir, len(notices)))
    for n in notices:
        origin = "from the user\x27s dogma source (NOTICES.md)" if n.get("kind") == "source" else "from the dogma plugin"
        action = n.get("action") or "none (information only)"
        lines.append("- {} [{}]: {} Action: {}".format(n.get("id", ""), origin, n.get("text", ""), action))
    lines += [
        "",
        "They concern the dogma setup (DOGMA-PERMISSIONS.md / synced rules) in {}: run every action with that directory as the target (e.g. cd there first), not in another folder.".format(repo_dir),
        "How to handle them (do not change anything in the repo on your own):",
        "- Do not interrupt urgent work; raise this at the first natural pause.",
        "- If a human is present: ask via your Ask tool (AskUserQuestion), one question per notice, options \"Run <action>\", \"Later\", \"Never\" (a notice without an action: \"Got it\" = mark seen, \"Later\"). Without an Ask tool, ask the same in plain text.",
        "- Run: run the action; only after it completed, mark the notice seen: {} <id> {}".format(mark, repo),
        "- Never / Got it: mark the notice seen with the same command (it will not come back for this repo).",
        "- Later: do nothing; it is shown again next session.",
        "- If running unattended/autonomously (no human present): do NOT ask and do not run the action; leave the notice pending.",
    ]
if hint:
    if lines:
        lines.append("")
    lines += [
        "[dogma] Source not reachable: " + hint,
        "Mention this once, briefly, at a natural pause (not in autonomous mode); nothing else to do now.",
    ]
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "\n".join(lines),
    }
}))
' 2>/dev/null

exit 0
