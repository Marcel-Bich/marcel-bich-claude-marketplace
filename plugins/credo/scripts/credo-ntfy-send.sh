#!/usr/bin/env bash
# credo-ntfy-send.sh "message text" [-t title]
#
# The single, discoverable way to send an ntfy push in credo. It hides where the
# topic and server actually live: both are resolved from the config cascade via
# credo-config.sh (builtin < global < profile < project), NOT from any file in the
# plugin/repo folder. The shipped template holds only an EMPTY topic placeholder,
# so grepping the repo for the real topic is pointless and misleading - always go
# through this helper (or credo-config.sh get) instead.
#
# Fail-safe by design: if ntfy is simply not configured (empty topic) or curl is
# unavailable, this is a no-op that exits 0 with no output. A missing notification
# path must never break the caller.
#
# Resolution:
#   topic  <- credo-config.sh get personal.ntfy_topic   (empty -> silent exit 0)
#   server <- credo-config.sh get personal.ntfy_server   (empty -> https://ntfy.sh)
# The message is POSTed to <server>/<topic>. The topic is treated as a secret:
# it is NEVER written to stdout/stderr and never logged.
#
# Usage:
#   credo-ntfy-send.sh "message text"
#   credo-ntfy-send.sh -t "Title" "message text"
#   credo-ntfy-send.sh "message text" -t "Title"
# The title may also come from the CREDO_NTFY_TITLE env var; the -t flag wins.
# Priority may be set via the CREDO_NTFY_PRIORITY env var (e.g. default|high|max).
#
# Exit codes:
#   0  message sent, OR nothing to do (topic empty, or curl missing) - fail-safe
#   1  usage error (no message given)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SH="$SCRIPT_DIR/credo-config.sh"

# --- parse args: one message (required) plus optional -t/--title ---------------
title="${CREDO_NTFY_TITLE:-}"
message=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -t|--title)
            shift
            [ "$#" -gt 0 ] || { echo "credo-ntfy-send: -t requires a title" >&2; exit 1; }
            title="$1"
            ;;
        -h|--help)
            echo 'usage: credo-ntfy-send.sh "message text" [-t title]' >&2
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
    echo 'usage: credo-ntfy-send.sh "message text" [-t title]' >&2
    exit 1
fi

# --- resolve topic + server from the config cascade ---------------------------
# credo-config.sh get exits 3 when the key is absent; treat absent as empty.
topic=""
if [ -x "$CONFIG_SH" ]; then
    topic="$("$CONFIG_SH" get personal.ntfy_topic 2>/dev/null || true)"
fi

# Fail-safe: ntfy not configured -> silent no-op (no error, no output).
if [ -z "$topic" ]; then
    exit 0
fi

server=""
if [ -x "$CONFIG_SH" ]; then
    server="$("$CONFIG_SH" get personal.ntfy_server 2>/dev/null || true)"
fi
[ -n "$server" ] || server="https://ntfy.sh"
# Trim a trailing slash so "<server>/<topic>" is well-formed.
server="${server%/}"

# curl absent -> silent no-op rather than a hard failure.
if ! command -v curl >/dev/null 2>&1; then
    exit 0
fi

# --- send ---------------------------------------------------------------------
# The topic is a secret: never echo it. Build the header args conditionally so an
# empty title/priority adds no header. --data-binary keeps the message verbatim.
set --
[ -n "$title" ] && set -- "$@" -H "Title: $title"
[ -n "${CREDO_NTFY_PRIORITY:-}" ] && set -- "$@" -H "Priority: $CREDO_NTFY_PRIORITY"

curl -fsS -m 15 "$@" --data-binary "$message" "$server/$topic" >/dev/null 2>&1 || true

exit 0
