#!/usr/bin/env bash
# credo-autonomy-off.sh [--after-suspend|--override|--mode-switch] [session_id]
#
# End the full-autonomy keep-alive mode. Removes the active flag plus the wake
# marker and sets a hard paused opt-out so the Stop keep-alive hook stays inert
# until credo-autonomy-on.sh is explicitly called again.
#
# This stays a PURE, fail-safe flag flip: no ntfy, no Ask, no presence check, and
# it does NOT delete the durable suspend-on-idle directive
# (credo-suspend-directive.sh). The directive persists until an explicit
# revocation, so an end-of-run autonomy-off must never drop it - otherwise it
# would be lost on every run (the reported bug). The attended "ask before suspend"
# branch lives in the session-autonomous SKILL, not in this hook.
#
# RIEGEL (directive gate). A bare autonomy-off must NOT become a standalone exit
# that bypasses a standing suspend-on-idle order. When a suspend directive is set
# for THIS session and NONE of the bypass flags below is given, this hook REFUSES
# to flip the flag (fail-loud, exit 1): the keep-alive stays armed so the run
# cannot just stop. The clean exit is the SKILL power-down sequence, which calls
# back here with --after-suspend as its final step. Bypass flags:
#   --after-suspend the caller (SKILL power-down sequence) JUST ran the power-down
#                   (sleep.command executed) -> the normal flag flip is allowed.
#   --override      explicit user override ("leave it on") -> allowed (a deliberate
#                   decision to end without suspending).
#   --mode-switch   invoked by session-mode-set.sh on an active/passive/clear mode
#                   switch (a legitimate user mode change) -> gate not applicable.
#
# session_id (needed only to read the directive) resolves like
# credo-suspend-directive.sh: the positional arg, else $CREDO_SESSION_ID, else
# $CLAUDE_CODE_SESSION_ID (Claude Code sets the latter for tool bash calls, so a
# normal invocation from the agent has it). FAIL-SAFE: if the session_id cannot be
# determined, or the directive helper is missing / errors, we do NOT block (no
# false lockout) - the flag flip proceeds as before. The gate only ever engages on
# a POSITIVELY read "directive is set".
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || SCRIPT_DIR=""
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
FLAG="$CONFIG_DIR/credo-autonomy-active"
WAKE="$CONFIG_DIR/credo-wake-scheduled"

# --- parse args: bypass flags in any order, first non-flag = session_id --------
bypass=""
arg_session_id=""
for a in "$@"; do
    case "$a" in
        --after-suspend|--override|--mode-switch) bypass="$a" ;;
        --*) : ;;  # unknown flag -> ignore (fail-safe, never block on it)
        *) [ -z "$arg_session_id" ] && arg_session_id="$a" ;;
    esac
done

do_flag_flip() {
    mkdir -p "$(dirname "$FLAG")" 2>/dev/null || true
    rm -f "$FLAG" "$WAKE" 2>/dev/null || true
    : > "$CONFIG_DIR/credo-autonomy-paused" 2>/dev/null || true
    echo "credo-autonomy OFF (paused: Stop hook guaranteed inert until credo-autonomy-on)"
}

# --- directive gate ------------------------------------------------------------
# A bypass flag skips the gate entirely (mode switch, user override, or the
# power-down sequence reporting it is done).
if [ -n "$bypass" ]; then
    do_flag_flip
    exit 0
fi

# No bypass: determine whether a suspend directive is set. Fail-safe throughout -
# any inability to read it POSITIVELY means "no gate" (flip proceeds).
directive_set=false
DIRECTIVE_SCRIPT=""
if [ -n "$SCRIPT_DIR" ] && [ -x "$SCRIPT_DIR/../scripts/credo-suspend-directive.sh" ]; then
    DIRECTIVE_SCRIPT="$SCRIPT_DIR/../scripts/credo-suspend-directive.sh"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "${CLAUDE_PLUGIN_ROOT}/scripts/credo-suspend-directive.sh" ]; then
    DIRECTIVE_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/credo-suspend-directive.sh"
fi

session_id="${arg_session_id:-${CREDO_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"

if [ -n "$DIRECTIVE_SCRIPT" ] && [ -n "$session_id" ]; then
    # get: prints "on" + exit 0 when set; exits 3 (no output) when not set.
    dval="$("$DIRECTIVE_SCRIPT" get "$session_id" 2>/dev/null || true)"
    dval="$(printf '%s' "$dval" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [ "$dval" = "on" ] && directive_set=true
fi

if [ "$directive_set" = true ]; then
    {
        echo "credo-autonomy-off REFUSED: a suspend-on-idle directive is IN FORCE for this session."
        echo ""
        echo "A bare autonomy-off is NOT a clean exit while a suspend order stands - it would"
        echo "silently skip the power-down the user ordered. The keep-alive stays armed."
        echo ""
        echo "Default end-of-run suspend conditions (autonomous mode): drive GO items as far as"
        echo "they are BUILDABLE to done, send the end-of-run ntfy, open the ~20 min veto window,"
        echo "then power down via the session-autonomous SKILL power-down sequence."
        echo ""
        echo "'GO is not empty' does NOT block this. Blocked or decision-gated leftovers in"
        echo "2_go are NOT buildable and do NOT prevent the suspend - end-of-run still holds when"
        echo "nothing can actually be built further right now. A self-declared context showstopper"
        echo "or 'I was not finished' is likewise no reason to bypass a standing directive."
        echo ""
        echo "Options:"
        echo "  1. Run the SKILL power-down sequence; its FINAL step calls back here as"
        echo "       credo-autonomy-off.sh --after-suspend"
        echo "     (only after sleep.command actually ran)."
        echo "  2. Explicit user override to leave the machine on:"
        echo "       credo-autonomy-off.sh --override"
        echo ""
        echo "The directive is NOT cleared by this refusal; it persists until an explicit"
        echo "revocation (see the session-autonomous skill)."
    } >&2
    exit 1
fi

# No directive set (or not determinable) -> historical behavior: pure flag flip.
do_flag_flip
exit 0
