#!/bin/bash
# notices-pending - list the dogma update notices that apply to a repo and are not
# marked seen there yet; mark one seen. Read-only towards the repo.
#
# Notices live in <plugin root>/notices.json, an array of
#   {"id", "since", "text", "action", "applies"}
# The plugin author only adds an entry for changes the user should act on; its
# "applies" script (path relative to the plugin root, run with the repo dir as cwd,
# exit 0 = applies) decides whether it fits a given repo. Repos where it does not
# apply never see it.
#
# Usage:
#   notices-pending.sh [--json] [dir]     pending notices of the repo at dir (default $PWD)
#       kv:   one block per notice (id=..., action=..., text=...), blank line between
#       json: {"repo": "<toplevel>", "notices": [{"id", "text", "action"}]}
#   notices-pending.sh mark <id> [dir]    mark a notice seen for that repo
#
# Seen state (per profile, per repo):
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dogma/notices-seen/<key>/<id>   (empty files)
#   key = first 16 hex chars of sha256(absolute git toplevel)
#
# Exit codes: listing 0 = notices printed, 4 = none pending, not a git repo, or any
# error (silent, fail safe). mark: 0 = marked, 1 = bad argument / unknown id,
# 4 = not a git repo or state not writable.
# Needs python3 or jq.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTICES_FILE="$PLUGIN_ROOT/notices.json"
SEEN_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dogma/notices-seen"

# --- helpers ---

valid_id() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*|.*) return 1 ;;
    esac
    return 0
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

# TSV lines (id, action, text) on stdin -> JSON object on stdout
emit_json() {
    local repo="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
out = []
for line in sys.stdin.read().splitlines():
    parts = line.split("\t", 2)
    if len(parts) == 3:
        out.append({"id": parts[0], "text": parts[2], "action": parts[1]})
print(json.dumps({"repo": sys.argv[1], "notices": out}))
' "$repo"
    else
        jq -R -s -c --arg repo "$repo" '
            split("\n") | map(select(length > 0) | split("\t")
                | {id: .[0], text: (.[2:] | join("\t")), action: .[1]})
            | {repo: $repo, notices: .}'
    fi
}

# --- arguments ---

CMD="list"
MODE="kv"
MARK_ID=""
if [ "${1:-}" = "mark" ]; then
    CMD="mark"
    MARK_ID="${2:-}"
    shift 2 2>/dev/null || shift
    valid_id "$MARK_ID" || { echo "notices-pending: mark needs a valid notice id" >&2; exit 1; }
elif [ "${1:-}" = "--json" ]; then
    MODE="json"
    shift
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
    KNOWN="$(parse_notices 2>/dev/null | cut -f1)" || KNOWN=""
    if ! printf '%s\n' "$KNOWN" | grep -qxF -- "$MARK_ID"; then
        echo "notices-pending: unknown notice id: $MARK_ID" >&2
        exit 1
    fi
    mkdir -p "$SEEN_DIR" 2>/dev/null && : > "$SEEN_DIR/$MARK_ID" 2>/dev/null || exit 4
    exit 0
fi

# --- list ---

ENTRIES="$(parse_notices 2>/dev/null)" || exit 4
PENDING=""
while IFS=$'\t' read -r id action applies text; do
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
    PENDING+="${id}"$'\t'"${action}"$'\t'"${text}"$'\n'
done <<< "$ENTRIES"

[ -n "$PENDING" ] || exit 4

if [ "$MODE" = "json" ]; then
    printf '%s' "$PENDING" | emit_json "$TOPLEVEL" || exit 4
else
    first=1
    while IFS=$'\t' read -r id action text; do
        [ -n "$id" ] || continue
        [ "$first" -eq 1 ] || echo ""
        first=0
        printf 'id=%s\naction=%s\ntext=%s\n' "$id" "$action" "$text"
    done <<< "$PENDING"
fi
exit 0
