#!/bin/bash
# Dogma: jq Check (SessionStart Hook)
#
# jq is a requirement of the dogma plugin, but nothing enforced it. Without jq the protection
# hooks print no decision: the delete guard (its deny output is built with jq), git permissions
# and dependency verification are OFF, so Claude Code's own permission rules decide, and other
# marketplace plugins degrade. This hook warns at every session start: a systemMessage for the
# user and hookSpecificOutput.additionalContext for the agent, which is told to pass the warning
# on prominently and to ask before installing anything. It blocks nothing and changes nothing in
# the repo. It reads no stdin and needs neither jq nor python3, so it works exactly where jq is
# missing.
#
# Silent when jq is on PATH. Always exits 0.
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch (silent when false)

trap 'exit 0' ERR

[ "${CLAUDE_MB_DOGMA_ENABLED:-true}" = "true" ] || exit 0
command -v jq >/dev/null 2>&1 && exit 0

case "$(uname -s 2>/dev/null)" in
    Darwin) INSTALL="brew install jq" ;;
    MINGW*|MSYS*|CYGWIN*) INSTALL="winget install jqlang.jq" ;;
    *) INSTALL="sudo apt install jq" ;;
esac

# Plain text only: no double quotes or backslashes, so the JSON below needs no escaping.
MESSAGE="!!! dogma WARNING: jq is NOT installed. dogma protection hooks are OFF without it: the delete guard, git permissions and dependency verification do not decide, so Claude Code's own permission rules apply, and other marketplace plugins degrade. Install jq now: ${INSTALL} (or your package manager)."
CONTEXT="[dogma] WARNING: jq is NOT installed on this machine. dogma protection hooks (delete guard, git permissions, dependency verification) are OFF without it, and other marketplace plugins degrade. Tell the user this prominently at the very top of your next reply, before anything else, and urge them to install jq now (${INSTALL}, or the package manager of their system). Do not install jq yourself, ask first. Until jq is installed, do not claim that dogma's guards are active. In an unattended run, put this warning into your final report instead."

printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$MESSAGE" "$CONTEXT"
exit 0
