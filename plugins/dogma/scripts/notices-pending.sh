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
#           are prefixed "src:" (src:n001). Only repos that use dogma (a
#           DOGMA-PERMISSIONS.md or a CLAUDE/ dir at the git toplevel) get them, and
#           never the source repo itself.
#
# Usage:
#   notices-pending.sh [--json] [--hint] [dir]   pending notices of the repo at dir (default $PWD)
#       kv:   one block per notice (id=..., kind=..., action=..., text=...), blank line between
#       json: {"repo": "<toplevel>", "notices": [{"id", "kind", "text", "action"}]}
#       --hint: also report, at most once a day, that the dogma source is not
#               reachable (kv: hint=..., json: "hint"); consumes the daily hint, so
#               only the SessionStart hook passes it
#   notices-pending.sh mark <id> [dir]           mark a notice seen for that repo
#
# Seen state (per profile, per repo):
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dogma/notices-seen/<key>/<id>        plugin notices
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dogma/notices-seen/<key>/.src/<id>   source notices
#   key = first 16 hex chars of sha256(absolute git toplevel); empty files
#
# Exit codes: listing 0 = notices (or a hint) printed, 4 = none pending, not a git
# repo, or any error (silent, fail safe). mark: 0 = marked, 1 = bad argument /
# unknown id, 4 = not a git repo or state not writable.
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

# does the repo at $1 use dogma (synced rules or permissions file at the toplevel)?
uses_dogma() {
    [ -f "$1/DOGMA-PERMISSIONS.md" ] || [ -d "$1/CLAUDE" ]
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

# source notices (TSV id, action, date, text) applicable to the repo at $1
source_entries() {
    [ -n "${CLAUDE_MB_DOGMA_SOURCE:-}" ] || return 1
    [ -x "$SOURCE_CACHE" ] || return 1
    uses_dogma "$1" || return 1
    is_source_repo "$1" && return 1
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

TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 4
[ -n "$TOPLEVEL" ] || exit 4
HASH="$(sha256_hex "$TOPLEVEL")" || exit 4
KEY="${HASH:0:16}"
[ ${#KEY} -eq 16 ] || exit 4
SEEN_DIR="$SEEN_ROOT/$KEY"

# --- mark ---

if [ "$CMD" = "mark" ]; then
    case "$MARK_ID" in
        src:*)
            # only ids of the current NOTICES.md; never fetch here
            KNOWN="$(CLAUDE_MB_DOGMA_SOURCE_FETCH=off source_entries "$TOPLEVEL" | cut -f1)" || KNOWN=""
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
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 "$PLUGIN_ROOT/$applies" </dev/null >/dev/null 2>&1 || continue
    else
        "$PLUGIN_ROOT/$applies" </dev/null >/dev/null 2>&1 || continue
    fi
    PENDING+="${id}"$'\t'"${action}"$'\t'"plugin"$'\t'"${text}"$'\n'
done <<< "$(printf '%s' "$ENTRIES" | tr '\t' '\037')"

SRC_ENTRIES="$(source_entries "$TOPLEVEL")" || SRC_ENTRIES=""
while IFS=$'\037' read -r id action _date text; do
    valid_id "$id" || continue
    [ -e "$SEEN_DIR/.src/$id" ] && continue
    PENDING+="src:${id}"$'\t'"${action}"$'\t'"source"$'\t'"${text}"$'\n'
done <<< "$(printf '%s' "$SRC_ENTRIES" | tr '\t' '\037')"

HINT=""
if [ "$WANT_HINT" -eq 1 ] && [ -n "${CLAUDE_MB_DOGMA_SOURCE:-}" ] && [ -x "$SOURCE_CACHE" ] \
    && uses_dogma "$TOPLEVEL" && ! is_source_repo "$TOPLEVEL"; then
    HINT="$("$SOURCE_CACHE" hint 2>/dev/null | tr '\t\n' '  ')" || HINT=""
    HINT="${HINT% }"
fi

[ -n "$PENDING" ] || [ -n "$HINT" ] || exit 4

if [ "$MODE" = "json" ]; then
    printf '%s' "$PENDING" | emit_json "$TOPLEVEL" "$HINT" || exit 4
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
