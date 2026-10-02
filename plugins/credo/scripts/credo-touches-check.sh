#!/bin/bash
# credo-touches-check - report likely file conflicts between work items (read-only).
#
# Reads the optional `touches:` frontmatter field of the given items (a list of
# paths or globs the item will likely edit) and prints every pair of items whose
# entries overlap, so the main agent can decide which code tracks may run in
# parallel (overlap -> run them sequentially). Items without `touches:` are
# listed as "unknown" - the main agent classifies those itself (credo
# orchestration skill). `touches:` is guidance, not a contract.
#
# Overlap rules (deliberately conservative - a false "overlap" only costs
# parallelism, a missed one costs a merge conflict):
#   - entries are normalized (leading "./" and duplicate "/" removed; a trailing
#     "/" means the whole directory, i.e. "dir/**")
#   - path vs path: equal, or one is a parent directory of the other
#   - glob vs path: the path matches the glob (fnmatch, "*" also crosses "/"),
#     or the path is a directory that contains the glob's fixed prefix
#   - glob vs glob: the fixed prefixes (up to the first wildcard) are
#     compatible (one starts with the other) AND the fixed suffixes (after the
#     last wildcard) are compatible (one ends with the other)
#
# Usage:
#   credo-touches-check.sh [--json] <id> [<id> ...]
#     text:   "overlap <a> <b>: <entryA> ~ <entryB>[, ...]" per overlapping pair,
#             "unknown <id> [<id> ...]" for items without touches,
#             "ok" when no overlap was found
#     --json: {"credo_dir":"...","items":[{"id":"12","touches":[...]}],
#              "overlaps":[{"a":"12","b":"13","pairs":[["x","y"]]}],
#              "unknown":["14"]}
#
# Items are looked up by id in every status folder of the resolved project
# (CREDO_DIR when set, otherwise credo-config.sh resolve-project, hub-aware).
#
# Exit codes: 0 no overlap, 3 overlap found, 4 no credo project resolved,
# 1 bad arguments (no id, non-numeric id, or an id with no item file).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="text"
IDS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --json) MODE="json" ;;
        -*) echo "credo-touches-check: unknown argument: $1" >&2; exit 1 ;;
        *)
            case "$1" in
                ""|*[!0-9]*) echo "credo-touches-check: not an item id: $1" >&2; exit 1 ;;
            esac
            IDS+=("$1")
            ;;
    esac
    shift
done
[ "${#IDS[@]}" -gt 0 ] || { echo "usage: credo-touches-check.sh [--json] <id> [<id> ...]" >&2; exit 1; }

if [ -n "${CREDO_DIR:-}" ]; then
    DIR="$CREDO_DIR"
else
    DIR="$("$SCRIPT_DIR/credo-config.sh" resolve-project 2>/dev/null)" || exit 4
fi
[ -d "$DIR/items" ] || exit 4

# id -> item file (first match across all status folders)
FILES=()
for id in "${IDS[@]}"; do
    f="$(find "$DIR/items" -maxdepth 3 -type f -name "${id}-*.md" -print -quit 2>/dev/null || true)"
    if [ -z "$f" ]; then
        echo "credo-touches-check: no item file for id $id" >&2
        exit 1
    fi
    FILES+=("$id=$f")
done

python3 - "$MODE" "$DIR" "${FILES[@]}" <<'PY'
import fnmatch, json, re, sys

mode, credo_dir = sys.argv[1], sys.argv[2]
WILD = re.compile(r"[*?\[\]]")

def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v

def read_touches(path):
    """Return the touches list, or None when the field is absent/empty."""
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return None
    if not lines or lines[0].strip() != "---":
        return None
    fm = []
    for line in lines[1:]:
        if line.strip() == "---":
            break
        fm.append(line)
    out, in_block = None, False
    for line in fm:
        if in_block:
            m = re.match(r"^\s*-\s*(.*)$", line)
            if m:
                val = unquote(m.group(1).split(" #", 1)[0])
                if val:
                    out.append(val)
                continue
            if line.strip() == "" or line.lstrip().startswith("#"):
                continue
            break
        m = re.match(r"^touches:\s*(.*)$", line)
        if not m:
            continue
        rest = m.group(1).split(" #", 1)[0].strip()
        if rest.startswith("[") and rest.endswith("]"):
            out = [unquote(x) for x in rest[1:-1].split(",") if unquote(x)]
        elif rest:
            out = [unquote(rest)]
        else:
            out, in_block = [], True
    return out or None

def norm(p):
    p = p.strip()
    while p.startswith("./"):
        p = p[2:]
    p = re.sub(r"/{2,}", "/", p)
    if p.endswith("/") and p != "/":
        p = p.rstrip("/") + "/**"
    return p

def is_glob(p):
    return bool(WILD.search(p))

def fixed_prefix(g):
    m = WILD.search(g)
    return g[:m.start()] if m else g

def fixed_suffix(g):
    idx = max(g.rfind(c) for c in "*?]")
    return g[idx + 1:] if idx >= 0 else g

def is_parent(a, b):
    return b.startswith(a.rstrip("/") + "/")

def overlap(a, b):
    ga, gb = is_glob(a), is_glob(b)
    if not ga and not gb:
        return a == b or is_parent(a, b) or is_parent(b, a)
    if ga and gb:
        pa, pb = fixed_prefix(a), fixed_prefix(b)
        sa, sb = fixed_suffix(a), fixed_suffix(b)
        return (pa.startswith(pb) or pb.startswith(pa)) and (sa.endswith(sb) or sb.endswith(sa))
    lit, glob = (a, b) if gb else (b, a)
    return fnmatch.fnmatchcase(lit, glob) or is_parent(lit, fixed_prefix(glob)) \
        or fixed_prefix(glob).rstrip("/") == lit

items, seen = [], set()
for arg in sys.argv[3:]:
    iid, path = arg.split("=", 1)
    if iid in seen:
        continue
    seen.add(iid)
    t = read_touches(path)
    items.append({"id": iid, "touches": [norm(x) for x in t] if t else None})

overlaps, unknown = [], [it["id"] for it in items if it["touches"] is None]
known = [it for it in items if it["touches"] is not None]
for i in range(len(known)):
    for j in range(i + 1, len(known)):
        a, b = known[i], known[j]
        pairs = [[x, y] for x in a["touches"] for y in b["touches"] if overlap(x, y)]
        if pairs:
            overlaps.append({"a": a["id"], "b": b["id"], "pairs": pairs})

if mode == "json":
    print(json.dumps({"credo_dir": credo_dir,
                      "items": [{"id": it["id"], "touches": it["touches"] or []} for it in items],
                      "overlaps": overlaps, "unknown": unknown}))
else:
    for o in overlaps:
        print("overlap %s %s: %s" % (o["a"], o["b"], ", ".join("%s ~ %s" % (x, y) for x, y in o["pairs"])))
    if unknown:
        print("unknown " + " ".join(unknown))
    if not overlaps:
        print("ok")
sys.exit(3 if overlaps else 0)
PY
