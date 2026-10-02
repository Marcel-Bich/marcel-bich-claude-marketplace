#!/bin/bash
# credo-item-list - list work items per status folder (read-only).
#
# Companion to credo-item-counts.sh: same project resolution, same status
# folders and keys. Per status it prints the total item count plus the newest
# N items (by file mtime) as id + title, so any renderer (a terminal, a Claude
# Code mod, another harness) can show item lists without knowing the folder
# layout or parsing item files itself. The title is the frontmatter `title:`
# (surrounding quotes removed), falling back to the file slug.
#
# Usage:
#   credo-item-list.sh [--json] [--per N]
#     (no flag)  text: one "<key> <total>" line per status, then one
#                "  #<id> <title>" line per listed item
#     --json     {"credo_dir":"...","statuses":[{"key":"clarify",
#                 "folder":"1_todo/1_clarify","total":13,
#                 "items":[{"id":"57","title":"..."}]}, ...]}
#     --per N    newest items listed per status (default 15, 0 = counts only)
#
# The project is CREDO_DIR when set, otherwise credo-config.sh resolve-project
# (session pin, hub-aware). Keys in order: clarify go blocked done verified
# archived hold future.
#
# Exit codes: 0 list printed, 4 no credo project resolved (prints nothing),
# 1 bad argument.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="text"
PER=15
while [ $# -gt 0 ]; do
    case "$1" in
        --json) MODE="json" ;;
        --per)
            [ $# -ge 2 ] || { echo "credo-item-list: --per needs a number" >&2; exit 1; }
            PER="$2"
            shift
            ;;
        *) echo "credo-item-list: unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done
case "$PER" in
    ""|*[!0-9]*) echo "credo-item-list: --per needs a number" >&2; exit 1 ;;
esac

if [ -n "${CREDO_DIR:-}" ]; then
    DIR="$CREDO_DIR"
else
    DIR="$("$SCRIPT_DIR/credo-config.sh" resolve-project 2>/dev/null)" || exit 4
fi
[ -d "$DIR/items" ] || exit 4

KEYS=(clarify go blocked "done" verified archived hold future)
PATHS=(1_todo/1_clarify 1_todo/2_go 1_todo/3_blocked 2_done 3_verified 4_archived parked/hold parked/future)

# item file names of one folder, newest first (one per line)
newest_first() {
    local d="$DIR/items/$1"
    [ -d "$d" ] || return 0
    local files=("$d"/[0-9]*-*.md)
    [ -e "${files[0]}" ] || return 0
    # shellcheck disable=SC2012 # item names are <id>-<slug>.md, no newlines
    ls -1t -- "${files[@]}" 2>/dev/null | sed 's#.*/##' || true
}

# frontmatter title of one item file, falling back to its slug
item_title() {
    local file="$1" name="$2" t
    t="$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit }
              NR > 1 && /^title:[[:space:]]*/ { sub(/^title:[[:space:]]*/, ""); print; exit }' "$file" 2>/dev/null | tr -d '\r')"
    t="${t%"${t##*[![:space:]]}"}"
    case "$t" in
        \"*\") t="${t#\"}"; t="${t%\"}"; t="${t//\\\"/\"}" ;;
        \'*\') t="${t#\'}"; t="${t%\'}" ;;
    esac
    if [ -z "$t" ]; then
        t="${name#*-}"
        t="${t%.md}"
    fi
    printf '%s' "$t"
}

json_escape() {
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/ }"
    printf '%s' "$s"
}

out=""
[ "$MODE" = "json" ] && out="{\"credo_dir\":\"$(json_escape "$DIR")\",\"statuses\":["
for i in "${!KEYS[@]}"; do
    key="${KEYS[$i]}"
    folder="${PATHS[$i]}"
    names=()
    while IFS= read -r name; do names+=("$name"); done < <(newest_first "$folder")
    total="${#names[@]}"
    if [ "$MODE" = "json" ]; then
        [ "$i" -gt 0 ] && out="$out,"
        out="$out{\"key\":\"$key\",\"folder\":\"$folder\",\"total\":$total,\"items\":["
    else
        out="$out$key $total"$'\n'
    fi
    n=0
    for name in ${names[@]+"${names[@]}"}; do
        [ "$n" -lt "$PER" ] || break
        id="${name%%-*}"
        title="$(item_title "$DIR/items/$folder/$name" "$name")"
        if [ "$MODE" = "json" ]; then
            [ "$n" -gt 0 ] && out="$out,"
            out="$out{\"id\":\"$id\",\"title\":\"$(json_escape "$title")\"}"
        else
            out="$out  #$id $title"$'\n'
        fi
        n=$((n + 1))
    done
    [ "$MODE" = "json" ] && out="$out]}"
done
if [ "$MODE" = "json" ]; then
    printf '%s]}\n' "$out"
else
    printf '%s' "$out"
fi
