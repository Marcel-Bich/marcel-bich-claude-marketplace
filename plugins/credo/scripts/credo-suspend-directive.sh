#!/usr/bin/env bash
# credo-suspend-directive.sh {set|get|clear} [session_id]
#
# Record a DURABLE, per-session "suspend-on-idle was ordered" directive. This is
# NOT the in-flight power-down marker (that is credo-suspend-mark.sh, which only
# tracks "a suspend is happening right now"). This directive remembers, for the
# whole session, that the user ordered a suspend at the end of the autonomous run.
# It must survive re-invokes of /credo:session-autonomous AND context compaction,
# so it is stored on disk keyed by session_id and re-injected on every prompt by
# the session-mode inject hook.
#
# Semantics (the caller enforces these; this script only stores/reads):
#   - The directive is only meaningful in autonomous mode and only gates the
#     end-of-run power-down together with the existing sleep gate: suspend when
#     (directive set OR sleep.enabled) AND sleep.command is present. An explicit
#     directive therefore OVERRIDES sleep.enabled:false (the server-safe default),
#     but never a missing sleep.command (that stays the misconfig path).
#   - The directive persists until an EXPLICIT revocation (natural-language "no
#     suspend / leave it on", or the attended autonomy-off Ask answered "no").
#     User presence alone does NOT clear it - see the session-autonomous skill.
#
# Subcommands:
#   set     write the directive for this session (atomic overwrite). An optional
#           reason can be passed via CREDO_SUSPEND_DIRECTIVE_REASON (recorded for
#           auditing). Prints "suspend-directive set (session <id>)".
#   get     print the directive value ("on") if set; if not set, print nothing and
#           exit 3 (so the caller can distinguish "no directive" from an empty one).
#   clear   remove the directive for this session (no-op if already absent).
#
# session_id resolution order:
#   1. the positional argument (if given)
#   2. $CREDO_SESSION_ID          (test / manual override)
#   3. $CLAUDE_CODE_SESSION_ID    (set by Claude Code for tool bash calls)
# Without a session_id the directive cannot be keyed -> hard error (no write/read).
#
# State: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/suspend-directives/<session_id>
#   Dir override: CREDO_SUSPEND_DIRECTIVES_DIR (mainly for tests).
#   File content: first line "on", then optional "set_at:" and "reason:" lines.
#
# Fail-safe: this is a state helper, not a hook. It never powers anything down and
# never blocks a prompt. Missing state on get -> exit 3 with no output.
set -u

cmd="${1:-}"
case "$cmd" in
    set|get|clear) ;;
    ""|-h|--help|help)
        echo "usage: credo-suspend-directive.sh {set|get|clear} [session_id]" >&2
        [ -z "$cmd" ] && exit 1 || exit 0
        ;;
    *)
        echo "credo-suspend-directive: unknown command: $cmd" >&2
        exit 1
        ;;
esac

session_id="${2:-${CREDO_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"
if [ -z "$session_id" ]; then
    echo "credo-suspend-directive: cannot determine session_id (pass it as arg 2 or set CLAUDE_CODE_SESSION_ID)" >&2
    exit 1
fi
case "$session_id" in
    *[!A-Za-z0-9._-]*|.|*..*)
        echo "credo-suspend-directive: invalid session_id (unexpected characters or path traversal)" >&2
        exit 1
        ;;
esac

STATE_DIR="${CREDO_SUSPEND_DIRECTIVES_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/suspend-directives}"
state_file="$STATE_DIR/$session_id"

case "$cmd" in
    set)
        mkdir -p "$STATE_DIR" || { echo "credo-suspend-directive: cannot create state dir $STATE_DIR" >&2; exit 1; }
        ts="$(date '+%Y-%m-%d %H:%M:%S %z')"
        reason="${CREDO_SUSPEND_DIRECTIVE_REASON:-}"
        tmp="$(mktemp "${state_file}.XXXXXX")" || { echo "credo-suspend-directive: mktemp failed" >&2; exit 1; }
        {
            echo "on"
            echo "set_at: $ts"
            if [ -n "$reason" ]; then echo "reason: $reason"; fi
        } > "$tmp"
        mv -f "$tmp" "$state_file"
        echo "suspend-directive set (session $session_id)"
        ;;
    get)
        if [ ! -f "$state_file" ]; then
            exit 3
        fi
        value="$(sed -n '1p' "$state_file" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
        if [ -z "$value" ]; then
            # Empty / corrupt file -> treat as no directive (fail-safe).
            exit 3
        fi
        echo "$value"
        ;;
    clear)
        rm -f "$state_file" 2>/dev/null || true
        echo "suspend-directive cleared (session $session_id)"
        ;;
esac
