#!/usr/bin/env bash
# credo-inline-guard.sh - credo plugin (PreToolUse hook, matcher Bash and *browser_run_code*).
#
# Purpose: long inline code (python3 -c "...", node -e "...", bash -c "...", powershell
# -Command "...", a heredoc fed to an interpreter) and long inline Playwright
# browser_run_code blobs are error-prone, often stopped by hooks or review prompts, and
# stall unattended runs (main agent and subagents alike;
# PreToolUse hooks also fire for tool calls made inside subagents). Above the size limit
# (guards.inline_code_max, default 1500 characters, 0 = off; env CREDO_INLINE_CODE_MAX
# overrides) the call is denied with the alternatives: split it into several smaller calls
# (allowed), or Write the code to a script file and run it in a separate call with a
# literal path (browser_run_code: the filename parameter).
# Only the size counts; short multi-line code passes. The analysis lives in
# scripts/credo-inline-guard.py (stdlib only).
#
# Cheap path: a call whose input names no interpreter is allowed here without starting
# Python, so ordinary commands cost one bash pattern match.
#
# I/O: documented PreToolUse contract. Deny -> stdout JSON hookSpecificOutput with
# permissionDecision "deny" and the reason, exit 0. Otherwise no output, exit 0.
#
# Failure-safe: no Python 3, unreadable input, any error -> allow (exit 0, no output).

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
GUARD="$HOOK_DIR/../scripts/credo-inline-guard.py"
[ -f "$GUARD" ] || exit 0

case "${CREDO_INLINE_CODE_MAX:-}" in
    0|-*) exit 0 ;;
esac

INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$INPUT" ] || exit 0

# Prefilter: an interpreter name or the Playwright tool must appear somewhere.
case "$INPUT" in
    *python*|*pypy*|*node*|*bun*|*deno*|*perl*|*ruby*|*php*|*bash*|*"sh -"*|*zsh*|*dash*|*owershell*|*OWERSHELL*|*wsh*|*browser_run_code*|*"py "*|*"py.exe"*) ;;
    *) exit 0 ;;
esac

# shellcheck source-path=SCRIPTDIR source=credo-python-lib.sh
. "$HOOK_DIR/credo-python-lib.sh" 2>/dev/null || exit 0
# Cheap on Linux, macOS, WSL (python3 on PATH); probes python/py -3 on native Windows. A
# missing interpreter makes the call below fail, which allows the tool call.
credo_python_cmd
command -v "$CREDO_PYTHON" >/dev/null 2>&1 || [ -x "$CREDO_PYTHON" ] || exit 0

out="$(printf '%s' "$INPUT" | "$CREDO_PYTHON" -I "$GUARD" 2>/dev/null)" || exit 0
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
