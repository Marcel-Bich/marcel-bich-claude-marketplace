#!/bin/bash
# notices-pending - list the dogma update notices that apply to a repo and are not
# marked seen there yet; mark one seen. Read-only towards the repo.
#
# Two kinds of notices, listed together:
#   plugin  <plugin root>/notices.json, an array of {"id", "since", "text", "action", "applies"}.
#           The plugin author only adds an entry for changes the user should act on; its
#           "applies" script (path relative to the plugin root, run with the repo dir as
#           cwd, exit 0 = applies) decides whether it fits a given repo.
#   source  broadcasts of the user's dogma source (CLAUDE_MB_DOGMA_SOURCE): the
#           hand-written NOTICES.md at the source root, read through
#           scripts/source-cache.sh (cached clone, refreshed at most once a day,
#           entries older than CLAUDE_MB_DOGMA_NOTICES_MAX_AGE_DAYS skipped). Their ids
#           are prefixed "src:" (src:n001). Only contexts that use dogma get them
#           (see "Context" below), never the source repo itself.
#
# Context (which dogma setup the notices concern):
#   start   the git toplevel of dir; else the credo pinned project (listing only,
#           lib-permissions.sh dogma_pinned_dir); else dir itself (also a non-git
#           folder)
#   file    the effective DOGMA-PERMISSIONS.md for it, resolved exactly like the
#           permission hooks do (lib-permissions.sh dogma_resolve: own file upward
#           or in the main worktree, else the inherited session-folder file;
#           session folder = DOGMA_SESSION_DIR, else the session folder recorded
#           by hooks/session-dir-record.sh, else dir)
#   uses dogma = such a file resolves, or the git toplevel has a CLAUDE/ dir
#   repo    the directory the notices refer to and are keyed by: the git toplevel
#           when the file lies inside it (or the toplevel only has CLAUDE/), else
#           the directory of the effective file (e.g. the session folder's file
#           inherited by a pinned project without its own file, or a non-git
#           folder). `mark` takes that directory and never consults the pin.
#
# Usage:
#   notices-pending.sh [--json] [--hint] [dir]   pending notices of the repo at dir (default $PWD)
#       kv:   one block per notice (id=..., kind=..., action=..., text=...), blank line between
#       json: {"repo": "<repo dir>", "notices": [{"id", "kind", "text", "action"}]}
#       --hint: also report, at most once a day, that the dogma source is not
#               reachable (kv: hint=..., json: "hint"); consumes the daily hint, so
#               only the SessionStart hook passes it
#   notices-pending.sh mark <id> [dir]           mark a notice seen for that repo
#                                                (pass the "repo" dir of the listing)
#
# Seen state (per profile, per repo):
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dogma/notices-seen/<key>/<id>        plugin notices
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dogma/notices-seen/<key>/.src/<id>   source notices
#   key = first 16 hex chars of sha256(absolute repo dir); empty files
#
# Exit codes: listing 0 = notices (or a hint) printed, 4 = none pending, no dogma
# context, or any error (silent, fail safe). mark: 0 = marked, 1 = bad argument /
# unknown id, 4 = no dogma context or state not writable.
# Needs python3 or jq (source notices need python3).

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTICES_FILE="$PLUGIN_ROOT/notices.json"
SOURCE_CACHE="$PLUGIN_ROOT/scripts/source-cache.sh"
SEEN_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dogma/notices-seen"

# --- helpers ---

valid_id() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*|.*) return 1 ;;
    esac
    return 0
}

# plugin id or src:<id>
valid_notice_id() {
    case "$1" in
        src:*) valid_id "${1#src:}" ;;
        *) valid_id "$1" ;;
    esac
}

sha256_hex() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | cut -c1-64
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | cut -c1-64
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
    else
        return 1
    fi
}

# notices.json -> one TSV line per entry: id, action, applies, text
# (tabs and newlines inside values become spaces)
parse_notices() {
    [ -f "$NOTICES_FILE" ] || return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
def clean(v):
    return " ".join(str(v if v is not None else "").split())
for n in json.load(open(sys.argv[1], encoding="utf-8")):
    if isinstance(n, dict):
        print("\t".join(clean(n.get(k)) for k in ("id", "action", "applies", "text")))
' "$NOTICES_FILE"
    elif command -v jq >/dev/null 2>&1; then
        jq -r '.[] | select(type == "object")
            | [.id, .action, .applies, .text]
            | map((. // "") | tostring | gsub("[\\t\\n\\r]+"; " "))
            | @tsv' "$NOTICES_FILE"
    else
        return 1
    fi
}

# TSV lines (id, action, kind, text) on stdin -> JSON object on stdout
emit_json() {
    local repo="$1" hint="$2"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
out = []
for line in sys.stdin.read().splitlines():
    parts = line.split("\t", 3)
    if len(parts) == 4:
        out.append({"id": parts[0], "kind": parts[2], "text": parts[3], "action": parts[1]})
d = {"repo": sys.argv[1], "notices": out}
if sys.argv[2]:
    d["hint"] = sys.argv[2]
print(json.dumps(d))
' "$repo" "$hint"
    else
        jq -R -s -c --arg repo "$repo" --arg hint "$hint" '
            split("\n") | map(select(length > 0) | split("\t")
                | {id: .[0], kind: .[2], text: (.[3:] | join("\t")), action: .[1]})
            | {repo: $repo, notices: .} + (if $hint == "" then {} else {hint: $hint} end)'
    fi
}

# does the context use dogma? (an effective permissions file, or synced rules at the
# git toplevel; set by the context resolution below)
uses_dogma() {
    [ -n "$EFF_FILE" ] || { [ -n "$CTX_TOP" ] && [ -d "$CTX_TOP/CLAUDE" ]; }
}

# is the repo at $1 the local dogma source itself? (its owner is not nagged)
is_source_repo() {
    local src="${CLAUDE_MB_DOGMA_SOURCE:-}"
    case "$src" in
        \~) src="$HOME" ;;
        \~/*) src="$HOME/${src#\~/}" ;;
        /*) ;;
        *) return 1 ;;
    esac
    [ -d "$src" ] || return 1
    [ "$(cd "$src" && pwd -P)" = "$(cd "$1" && pwd -P)" ]
}

# is the context (repo dir or git toplevel) the dogma source itself?
ctx_is_source() {
    is_source_repo "$REPO" && return 0
    [ -n "$CTX_TOP" ] && is_source_repo "$CTX_TOP"
}

# source notices (TSV id, action, date, text) applicable to the context
source_entries() {
    [ -n "${CLAUDE_MB_DOGMA_SOURCE:-}" ] || return 1
    [ -x "$SOURCE_CACHE" ] || return 1
    uses_dogma || return 1
    ctx_is_source && return 1
    "$SOURCE_CACHE" notices 2>/dev/null
}

# --- arguments ---

CMD="list"
MODE="kv"
WANT_HINT=0
MARK_ID=""
if [ "${1:-}" = "mark" ]; then
    CMD="mark"
    MARK_ID="${2:-}"
    shift 2 2>/dev/null || shift
    valid_notice_id "$MARK_ID" || { echo "notices-pending: mark needs a valid notice id" >&2; exit 1; }
else
    while :; do
        case "${1:-}" in
            --json) MODE="json"; shift ;;
            --hint) WANT_HINT=1; shift ;;
            *) break ;;
        esac
    done
fi
case "${1:-}" in
    -*)
        [ "$CMD" = "mark" ] && { echo "notices-pending: unknown argument: $1" >&2; exit 1; }
        exit 4
        ;;
esac
DIR="${1:-$PWD}"
if ! cd "$DIR" 2>/dev/null; then
    [ "$CMD" = "mark" ] && { echo "notices-pending: no such dir: $DIR" >&2; exit 1; }
    exit 4
fi

DIR="$(pwd -P)"
# shellcheck source=lib-permissions.sh
. "$PLUGIN_ROOT/scripts/lib-permissions.sh" 2>/dev/null || exit 4
# the session folder whose file a context without its own file inherits (the recorded
# one survives a cwd that drifted before a compact / clear or a `mark` from elsewhere)
if [ -z "${DOGMA_SESSION_DIR:-}" ]; then
    DOGMA_SESSION_DIR="$(dogma_recorded_session_dir)" || DOGMA_SESSION_DIR="$DIR"
fi
export DOGMA_SESSION_DIR

# --- context: start dir, effective file, repo dir (see header) ---

START="$DIR"
CTX_TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || CTX_TOP=""
if [ -z "$CTX_TOP" ] && [ "$CMD" = "list" ] && PINNED="$(dogma_pinned_dir)" && [ -d "$PINNED" ]; then
    # session folder outside any repo (a parent / workspace folder): the credo pinned
    # project is where the work happens (skipped when credo is not installed)
    START="$PINNED"
    CTX_TOP="$(git -C "$PINNED" rev-parse --show-toplevel 2>/dev/null)" || CTX_TOP=""
fi
dogma_resolve "$START"
EFF_FILE="${DOGMA_RESOLVED_FILE:-}"
REPO=""
if [ -n "$EFF_FILE" ]; then
    EFF_DIR="$(cd "$(dirname "$EFF_FILE")" 2>/dev/null && pwd -P)" || exit 4
    case "$EFF_DIR/" in
        "$CTX_TOP"/*) [ -n "$CTX_TOP" ] && REPO="$CTX_TOP" ;;
    esac
    [ -n "$REPO" ] || REPO="$EFF_DIR"
elif [ -n "$CTX_TOP" ]; then
    # no permissions file: plugin notices may still apply (their own check decides),
    # source notices only with synced rules (CLAUDE/)
    REPO="$CTX_TOP"
fi
[ -n "$REPO" ] || exit 4
HASH="$(sha256_hex "$REPO")" || exit 4
KEY="${HASH:0:16}"
[ ${#KEY} -eq 16 ] || exit 4
SEEN_DIR="$SEEN_ROOT/$KEY"

# --- mark ---

if [ "$CMD" = "mark" ]; then
    case "$MARK_ID" in
        src:*)
            # only ids of the current NOTICES.md; never fetch here
            KNOWN="$(CLAUDE_MB_DOGMA_SOURCE_FETCH=off source_entries | cut -f1)" || KNOWN=""
            MARK_FILE="$SEEN_DIR/.src/${MARK_ID#src:}"
            MARK_CMP="${MARK_ID#src:}"
            ;;
        *)
            KNOWN="$(parse_notices 2>/dev/null | cut -f1)" || KNOWN=""
            MARK_FILE="$SEEN_DIR/$MARK_ID"
            MARK_CMP="$MARK_ID"
            ;;
    esac
    if ! printf '%s\n' "$KNOWN" | grep -qxF -- "$MARK_CMP"; then
        echo "notices-pending: unknown notice id: $MARK_ID" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$MARK_FILE")" 2>/dev/null && : > "$MARK_FILE" 2>/dev/null || exit 4
    exit 0
fi

# --- list ---

ENTRIES="$(parse_notices 2>/dev/null)" || ENTRIES=""
PENDING=""
# fields are read split on \037: tab is IFS whitespace, so empty fields would collapse
while IFS=$'\037' read -r id action applies text; do
    valid_id "$id" || continue
    [ -e "$SEEN_DIR/$id" ] && continue
    # applies: a relative path inside the plugin root, never upward
    case "$applies" in
        ''|/*|*..*) continue ;;
    esac
    [ -x "$PLUGIN_ROOT/$applies" ] || continue
    # run from the context's start dir: its resolution (with DOGMA_SESSION_DIR) yields
    # the same effective file as above
    if command -v timeout >/dev/null 2>&1; then
        (cd "$START" && timeout 5 "$PLUGIN_ROOT/$applies" </dev/null >/dev/null 2>&1) || continue
    else
        (cd "$START" && "$PLUGIN_ROOT/$applies" </dev/null >/dev/null 2>&1) || continue
    fi
    PENDING+="${id}"$'\t'"${action}"$'\t'"plugin"$'\t'"${text}"$'\n'
done <<< "$(printf '%s' "$ENTRIES" | tr '\t' '\037')"

SRC_ENTRIES="$(cd "$START" && source_entries)" || SRC_ENTRIES=""
while IFS=$'\037' read -r id action _date text; do
    valid_id "$id" || continue
    [ -e "$SEEN_DIR/.src/$id" ] && continue
    PENDING+="src:${id}"$'\t'"${action}"$'\t'"source"$'\t'"${text}"$'\n'
done <<< "$(printf '%s' "$SRC_ENTRIES" | tr '\t' '\037')"

HINT=""
if [ "$WANT_HINT" -eq 1 ] && [ -n "${CLAUDE_MB_DOGMA_SOURCE:-}" ] && [ -x "$SOURCE_CACHE" ] \
    && uses_dogma && ! ctx_is_source; then
    HINT="$(cd "$START" && "$SOURCE_CACHE" hint 2>/dev/null | tr '\t\n' '  ')" || HINT=""
    HINT="${HINT% }"
fi

[ -n "$PENDING" ] || [ -n "$HINT" ] || exit 4

if [ "$MODE" = "json" ]; then
    printf '%s' "$PENDING" | emit_json "$REPO" "$HINT" || exit 4
else
    first=1
    while IFS=$'\037' read -r id action kind text; do
        [ -n "$id" ] || continue
        [ "$first" -eq 1 ] || echo ""
        first=0
        printf 'id=%s\nkind=%s\naction=%s\ntext=%s\n' "$id" "$kind" "$action" "$text"
    done <<< "$(printf '%s' "$PENDING" | tr '\t' '\037')"
    if [ -n "$HINT" ]; then
        [ "$first" -eq 1 ] || echo ""
        printf 'hint=%s\n' "$HINT"
    fi
fi
exit 0
