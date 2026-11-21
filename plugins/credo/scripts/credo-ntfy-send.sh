#!/usr/bin/env bash
# credo-ntfy-send.sh "message text" [-t title] [-p priority] [--tags tags]
#
# The single, discoverable way to send an ntfy push in credo. It hides where the
# topic, server and relay actually live: all are resolved from the config cascade
# via credo-config.sh (builtin < global < profile < project), NOT from any file in
# the plugin/repo folder. The shipped template holds only EMPTY placeholders, so
# grepping the repo for the real topic is pointless and misleading - always go
# through this helper (or credo-config.sh get) instead.
#
# Two send paths:
#   relay   personal.ntfy_relay set (e.g. http://127.0.0.1:8765/send): POST a JSON
#           {title, body, priority, tags} to that local relay, which owns the topic.
#           Only http URLs on 127.0.0.1, localhost or [::1] are accepted. The topic is
#           never sent to the relay. Contract: scripts/credo_ntfy_relay.py.
#   direct  only when NO relay is configured: POST the message to
#           <personal.ntfy_server>/<personal.ntfy_topic> (server empty ->
#           https://ntfy.sh), exactly as before the relay existed.
# A failed relay never falls back to the direct path, even with a topic set. The
# relay exists because direct sends are not wanted on this machine.
#
# Not configured (no relay, empty topic) is a silent no-op that exits 0: a missing
# notification path must never break the caller. A CONFIGURED push that cannot be
# delivered fails loud: non-zero exit and the reason on stderr, so the caller knows
# the push did not go out. The topic is a secret.
# It is NEVER written to stdout/stderr and never logged (curl's own error text is
# discarded for that reason, only its exit code is reported).
#
# Usage:
#   credo-ntfy-send.sh "message text"
#   credo-ntfy-send.sh -t "Title" "message text"
#   credo-ntfy-send.sh "message text" -t "Title" -p high --tags warning
# The title may also come from CREDO_NTFY_TITLE, the priority from
# CREDO_NTFY_PRIORITY (min|low|default|high|max), the tags from CREDO_NTFY_TAGS;
# the flags win.
#
# Exit codes:
#   0  message sent, OR nothing to do (no relay and empty topic)
#   1  usage error (no message given)
#   2  personal.ntfy_relay is invalid (not a loopback http URL), or invalid
#      priority/tags for the relay
#   3  send failed (e.g. relay down or refusing, curl or python3 missing, server
#      unreachable)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SH="$SCRIPT_DIR/credo-config.sh"

# --- parse args: one message (required) plus optional -t/--title ---------------
title="${CREDO_NTFY_TITLE:-}"
priority="${CREDO_NTFY_PRIORITY:-}"
tags="${CREDO_NTFY_TAGS:-}"
message=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -t|--title)
            shift
            [ "$#" -gt 0 ] || { echo "credo-ntfy-send: -t requires a title" >&2; exit 1; }
            title="$1"
            ;;
        -p|--priority)
            shift
            [ "$#" -gt 0 ] || { echo "credo-ntfy-send: -p requires a priority" >&2; exit 1; }
            priority="$1"
            ;;
        --tags)
            shift
            [ "$#" -gt 0 ] || { echo "credo-ntfy-send: --tags requires a value" >&2; exit 1; }
            tags="$1"
            ;;
        -h|--help)
            echo 'usage: credo-ntfy-send.sh "message text" [-t title] [-p priority] [--tags tags]' >&2
            exit 0
            ;;
        *)
            if [ -z "$message" ]; then
                message="$1"
            else
                # Allow additional words to append to the message.
                message="$message $1"
            fi
            ;;
    esac
    shift
done

if [ -z "$message" ]; then
    echo 'usage: credo-ntfy-send.sh "message text" [-t title] [-p priority] [--tags tags]' >&2
    exit 1
fi

# --- resolve relay + topic + server from the config cascade --------------------
# credo-config.sh get exits 3 when the key is absent; treat absent as empty.
cfg() {
    if [ -x "$CONFIG_SH" ]; then
        "$CONFIG_SH" get "$1" 2>/dev/null || true
    fi
}
relay="$(cfg personal.ntfy_relay)"
topic="$(cfg personal.ntfy_topic)"

# Not configured at all -> silent no-op (no error, no output).
if [ -z "$relay" ] && [ -z "$topic" ]; then
    exit 0
fi

# --- relay path ---------------------------------------------------------------
fail_code=3
if [ -n "$relay" ]; then
    if ! command -v python3 >/dev/null 2>&1; then
        echo "credo-ntfy-send: relay set but python3 is missing" >&2
    else
        rc=0
        printf '%s' "$message" | python3 "$SCRIPT_DIR/credo_ntfy_relay.py" send "$relay" \
            --title "$title" --priority "$priority" --tags "$tags" || rc=$?
        [ "$rc" -eq 0 ] && exit 0
        # The helper already printed the reason; exit 2 = config or input error.
        [ "$rc" -eq 2 ] && fail_code=2
    fi
    # No direct fallback. A configured relay is the only allowed path.
    echo "credo-ntfy-send: push NOT sent (relay failed; no direct fallback while personal.ntfy_relay is set)" >&2
    exit "$fail_code"
fi

# --- direct path ----------------------------------------------------------------
server="$(cfg personal.ntfy_server)"
[ -n "$server" ] || server="https://ntfy.sh"
# Trim a trailing slash so "<server>/<topic>" is well-formed.
server="${server%/}"

if ! command -v curl >/dev/null 2>&1; then
    echo "credo-ntfy-send: push NOT sent (curl is missing for the direct ntfy path)" >&2
    exit 3
fi

# The topic is a secret: never echo it. Build the header args conditionally so an
# empty title/priority/tags adds no header. --data-binary keeps the message verbatim.
set --
[ -n "$title" ] && set -- "$@" -H "Title: $title"
[ -n "$priority" ] && set -- "$@" -H "Priority: $priority"
[ -n "$tags" ] && set -- "$@" -H "Tags: $tags"

rc=0
curl -fsS -m 15 "$@" --data-binary "$message" "$server/$topic" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
    # curl's own message may contain the URL (and so the topic): report the code only.
    echo "credo-ntfy-send: push NOT sent (direct send to the ntfy server failed, curl exit $rc)" >&2
    exit 3
fi
exit 0
