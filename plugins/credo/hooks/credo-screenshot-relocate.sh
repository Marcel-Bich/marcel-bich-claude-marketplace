#!/usr/bin/env bash
# credo-screenshot-relocate.sh - credo plugin (PostToolUse hook).
#
# Purpose: Playwright MCP screenshots land in the wrong place. The screenshot
# tool (mcp__..._browser_take_screenshot) is SANDBOXED to the tool's cwd: the
# only writable roots are the cwd (often a launch hub) and cwd/.playwright-mcp.
# An absolute path into <pinned-project>/.credo/screenshots/ is rejected
# ("File access denied ... outside allowed roots"), and a bare filename lands as
# <cwd>/<name>. So no path INSTRUCTION can make the tool write into the pinned
# project. This hook fixes it after the fact: it locates the file the tool just
# wrote and MOVES it into the session-resolved <pinned-project>/.credo/screenshots/.
#
# It fires for every browser_take_screenshot PostToolUse, main agent and subagents
# alike (subagent screenshots must be filed too, so there is NO agent_id filter).
#
# Fully defensive: this hook must NEVER block or slow a tool call. Every path
# exits 0. It only ever `mv`s the one file the tool just produced; it never
# deletes or overwrites an existing target (no-clobber, suffix on collision).
#
# Resolution of the target project reuses `credo-config.sh resolve-project` (the
# same PROJECT layer as credo-init / item-move): CREDO_DIR > session pin > cwd.
# Exit 4 (hub / no project) -> leave the file where it is, exit 0 (fail-safe).
set +e
set -u

# jq is required to read the hook stdin. Missing -> no-op.
command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$INPUT" ] || exit 0

tool_name="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || tool_name=""
[ "$tool_name" = "null" ] && tool_name=""
# Only act on the screenshot tool (name ends with / contains browser_take_screenshot).
case "$tool_name" in
    *browser_take_screenshot*) : ;;
    *) exit 0 ;;
esac

cwd="$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)" || cwd=""
[ "$cwd" = "null" ] && cwd=""
[ -n "$cwd" ] || exit 0
[ -d "$cwd" ] || exit 0

session_id="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || session_id=""
[ "$session_id" = "null" ] && session_id=""

# --- determine the source file name -----------------------------------------
# Prefer the explicit filename the tool was given; otherwise parse the path from
# the Markdown link in the tool response, e.g. "...(./page-2026-...png)".
src_name="$(printf '%s' "$INPUT" | jq -r '.tool_input.filename // ""' 2>/dev/null)" || src_name=""
[ "$src_name" = "null" ] && src_name=""

if [ -z "$src_name" ]; then
    # tool_response may be a string or a structured object; flatten to text.
    resp="$(printf '%s' "$INPUT" | jq -r '.tool_response | if type=="string" then . else tostring end' 2>/dev/null)" || resp=""
    [ "$resp" = "null" ] && resp=""
    # First "(....png|jpeg|jpg|webp)" occurrence -> strip the surrounding parens.
    match="$(printf '%s' "$resp" | grep -oE '\([^()]*\.(png|jpe?g|webp)\)' 2>/dev/null | head -n1)" || match=""
    if [ -n "$match" ]; then
        src_name="${match#\(}"
        src_name="${src_name%\)}"
    fi
fi

[ -n "$src_name" ] || exit 0
# Strip a leading "./" if present.
src_name="${src_name#./}"

# --- resolve the source absolute path ---------------------------------------
case "$src_name" in
    /*) src_abs="$src_name" ;;
    *)  src_abs="$cwd/$src_name" ;;
esac
[ -f "$src_abs" ] || exit 0

# --- resolve the target project via credo-config.sh resolve-project ----------
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || HOOK_DIR=""
CONFIG_SCRIPT=""
if [ -n "$HOOK_DIR" ] && [ -x "$HOOK_DIR/../scripts/credo-config.sh" ]; then
    CONFIG_SCRIPT="$HOOK_DIR/../scripts/credo-config.sh"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" ]; then
    CONFIG_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh"
fi
[ -n "$CONFIG_SCRIPT" ] || exit 0

# Feed the session id through both variables the resolver honours, and resolve
# layer 3 (cwd) from the tool's cwd so a non-hub project resolves to <cwd>/.credo.
credo_dir="$(cd "$cwd" 2>/dev/null && CLAUDE_CODE_SESSION_ID="$session_id" CREDO_SESSION_ID="$session_id" "$CONFIG_SCRIPT" resolve-project 2>/dev/null)"
rc=$?
# Exit != 0 (e.g. 4 = hub / no project) or empty -> leave the file where it is.
[ "$rc" -eq 0 ] 2>/dev/null || exit 0
[ -n "$credo_dir" ] || exit 0

dest_dir="$credo_dir/screenshots"
mkdir -p "$dest_dir" 2>/dev/null || exit 0

# Base name only for the destination (never carry a path into the target dir).
base_name="$(basename "$src_name")"
dest="$dest_dir/$base_name"

# Already in place (source is the destination) -> nothing to do.
[ "$src_abs" = "$dest" ] && exit 0

# --- move without ever clobbering an existing target -------------------------
if [ ! -e "$dest" ]; then
    mv -n "$src_abs" "$dest" 2>/dev/null
else
    # Collision: keep the existing file, give the new one a numeric suffix.
    stem="${base_name%.*}"
    ext="${base_name##*.}"
    if [ "$stem" = "$base_name" ]; then
        ext=""
    fi
    i=1
    while [ "$i" -le 999 ]; do
        if [ -n "$ext" ]; then
            cand="$dest_dir/${stem}-${i}.${ext}"
        else
            cand="$dest_dir/${base_name}-${i}"
        fi
        if [ ! -e "$cand" ]; then
            mv -n "$src_abs" "$cand" 2>/dev/null
            break
        fi
        i=$((i + 1))
    done
fi

exit 0
