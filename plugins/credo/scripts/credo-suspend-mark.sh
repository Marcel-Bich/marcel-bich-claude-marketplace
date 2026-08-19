#!/usr/bin/env bash
# credo-suspend-mark.sh <write|elapsed|clear>
#
# Track a PENDING power-down (suspend or hibernate) so an autonomous run can tell
# afterwards whether the machine actually slept, instead of re-firing the sleep or
# scoring it as a failure. The autonomous session skill (session-autonomous) writes
# the marker BEFORE the first power-down attempt, then on the next turn/wakeup asks
# for the elapsed time and compares it against sleep.success_gap_min: a jump larger
# than that gap means the machine really slept (success) - the marker is cleared and
# the intent dropped. Applies to both power-down modes (suspend and hibernate).
#
# Subcommands:
#   write     record now as the pending-suspend timestamp (atomic overwrite)
#   elapsed   print whole seconds since the marker was written; if no marker exists,
#             print nothing and exit 3 (so the caller can distinguish "no pending
#             suspend" from "0 seconds elapsed")
#   clear     remove the marker (no-op if already absent)
#
# State:
#   marker : ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo-pending-suspend
#            holds a single line with the absolute Unix timestamp of the last write.
#            Path override: CREDO_PENDING_SUSPEND (mainly for tests).
set -eu

MARKER="${CREDO_PENDING_SUSPEND:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo-pending-suspend}"

cmd="${1:-}"
case "$cmd" in
    write)
        mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
        now="$(date +%s)"
        tmp="$(mktemp "${MARKER}.XXXXXX")" || { echo "credo-suspend-mark: mktemp failed" >&2; exit 1; }
        printf '%s\n' "$now" > "$tmp"
        mv -f "$tmp" "$MARKER"
        echo "pending suspend marked at $now"
        ;;
    elapsed)
        if [ ! -f "$MARKER" ]; then
            exit 3
        fi
        marked="$(sed -n '1p' "$MARKER" 2>/dev/null | tr -d '\r')"
        case "$marked" in
            ''|*[!0-9]*)
                echo "credo-suspend-mark: marker is corrupt (not a timestamp)" >&2
                exit 1
                ;;
        esac
        now="$(date +%s)"
        elapsed="$((now - marked))"
        [ "$elapsed" -lt 0 ] && elapsed=0
        echo "$elapsed"
        ;;
    clear)
        rm -f "$MARKER" 2>/dev/null || true
        ;;
    ""|-h|--help|help)
        echo "usage: credo-suspend-mark.sh {write|elapsed|clear}" >&2
        [ -z "$cmd" ] && exit 1 || exit 0
        ;;
    *)
        echo "credo-suspend-mark: unknown command: $cmd" >&2
        exit 1
        ;;
esac
