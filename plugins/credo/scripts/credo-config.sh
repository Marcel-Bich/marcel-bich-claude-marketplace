#!/bin/bash
# credo-config - read the cascading credo config and manage the global layer.
#
# Cascade precedence (lowest to highest):
#   builtin (plugin templates/config.default.yaml)
#     < global (~/.claude/credo/config)
#       < project (.credo/config)
#
# The global layer is auto-created from the builtin template on first need
# (universal defaults; personal fields stay empty). YAML is parsed with PyYAML
# when available and with a bundled stdlib subset parser otherwise, so no
# package needs to be installed.
#
# Usage:
#   credo-config.sh get <dotted.key>   print merged value (exit 3 if absent)
#   credo-config.sh backend            print resolved task backend (fail-safe)
#   credo-config.sh ensure-global      create global config if missing
#   credo-config.sh paths              print the three layer paths + existence
#
# Env overrides (mainly for testing):
#   CLAUDE_PLUGIN_ROOT  plugin root (locates the builtin template)
#   CREDO_GLOBAL        path to the global config file
#   CREDO_PROJECT       path to the project config file
#   CREDO_DIR           project .credo dir (project config = $CREDO_DIR/config)
#   CREDO_SKIP_ENSURE   if set to 1, "get" does not auto-create the global layer
#
# Exit codes: 0 ok, 1 hard error, 3 key not found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- resolve the three layer paths ------------------------------------------
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    BUILTIN="$CLAUDE_PLUGIN_ROOT/templates/config.default.yaml"
else
    BUILTIN="$SCRIPT_DIR/../templates/config.default.yaml"
fi

GLOBAL="${CREDO_GLOBAL:-$HOME/.claude/credo/config}"

if [ -n "${CREDO_PROJECT:-}" ]; then
    PROJECT="$CREDO_PROJECT"
elif [ -n "${CREDO_DIR:-}" ]; then
    PROJECT="$CREDO_DIR/config"
elif REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    PROJECT="$REPO_ROOT/.credo/config"
else
    PROJECT="$(pwd)/.credo/config"
fi

# --- create the global layer from the builtin template (atomic) --------------
ensure_global() {
    if [ -f "$GLOBAL" ]; then
        return 0
    fi
    if [ ! -f "$BUILTIN" ]; then
        echo "credo-config: builtin template not found: $BUILTIN" >&2
        return 1
    fi
    mkdir -p "$(dirname "$GLOBAL")"
    local tmp="$GLOBAL.tmp.$$"
    cp "$BUILTIN" "$tmp"
    mv -f "$tmp" "$GLOBAL"
}

CMD="${1:-}"

case "$CMD" in
    backend)
        # Resolve the task backend. Fail-safe: always prints a value, never exits
        # non-zero for a missing key. Precedence:
        #   1. env CREDO_TASK_BACKEND set AND non-empty -> use it (override)
        #   2. merged config task_backend (via the cascade)
        #   3. credo (default)
        if [ -n "${CREDO_TASK_BACKEND:-}" ]; then
            printf '%s\n' "$CREDO_TASK_BACKEND"
            exit 0
        fi
        val="$("${BASH_SOURCE[0]}" get task_backend 2>/dev/null)" || val=""
        if [ -n "$val" ]; then
            printf '%s\n' "$val"
        else
            printf '%s\n' "credo"
        fi
        exit 0
        ;;
    ensure-global)
        ensure_global && echo "$GLOBAL"
        ;;
    paths)
        printf 'builtin: %s (%s)\n' "$BUILTIN" "$([ -f "$BUILTIN" ] && echo present || echo missing)"
        printf 'global:  %s (%s)\n' "$GLOBAL" "$([ -f "$GLOBAL" ] && echo present || echo missing)"
        printf 'project: %s (%s)\n' "$PROJECT" "$([ -f "$PROJECT" ] && echo present || echo missing)"
        ;;
    get)
        KEY="${2:-}"
        if [ -z "$KEY" ]; then
            echo "credo-config: get requires a key" >&2
            exit 1
        fi
        if [ "${CREDO_SKIP_ENSURE:-}" != "1" ]; then
            ensure_global || true
        fi
        CREDO_BUILTIN="$BUILTIN" CREDO_GLOBAL_F="$GLOBAL" CREDO_PROJECT_F="$PROJECT" \
            python3 - "$KEY" <<'PY'
import os, sys, json

key = sys.argv[1]

def load_yaml(path):
    if not path or not os.path.isfile(path):
        return {}
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    try:
        import yaml  # PyYAML if available
        data = yaml.safe_load(text)
        return data if isinstance(data, dict) else {}
    except Exception:
        pass
    return _fallback_parse(text)

def _scalar(v):
    v = v.strip()
    if v == "" or v == "~" or v == "null":
        return None
    if (v[0], v[-1]) in (('"', '"'), ("'", "'")) and len(v) >= 2:
        return v[1:-1]
    if v.startswith("[") and v.endswith("]"):
        inner = v[1:-1].strip()
        if inner == "":
            return []
        return [_scalar(x) for x in inner.split(",")]
    low = v.lower()
    if low == "true":
        return True
    if low == "false":
        return False
    try:
        return int(v)
    except ValueError:
        pass
    try:
        return float(v)
    except ValueError:
        pass
    return v

def _fallback_parse(text):
    # Subset YAML parser: nested maps, block sequences (of scalars and of
    # maps), inline flow lists, scalars. Sufficient for the credo config.
    lines = []
    for raw in text.splitlines():
        stripped = raw.split("#", 1)[0].rstrip() if not _in_quote(raw) else raw.rstrip()
        if stripped.strip() == "":
            continue
        indent = len(stripped) - len(stripped.lstrip(" "))
        lines.append((indent, stripped.strip()))

    pos = [0]

    def parse_node(indent):
        if pos[0] >= len(lines):
            return None
        _, text0 = lines[pos[0]]
        if text0.startswith("- "):
            return parse_seq(indent)
        return parse_map(indent)

    def parse_map(indent):
        d = {}
        while pos[0] < len(lines):
            ind, text0 = lines[pos[0]]
            if ind != indent or text0.startswith("- "):
                break
            k, _, v = text0.partition(":")
            k = k.strip()
            v = v.strip()
            pos[0] += 1
            if v == "":
                if pos[0] < len(lines) and lines[pos[0]][0] > indent:
                    d[k] = parse_node(lines[pos[0]][0])
                else:
                    d[k] = None
            else:
                d[k] = _scalar(v)
        return d

    def parse_seq(indent):
        lst = []
        while pos[0] < len(lines):
            ind, text0 = lines[pos[0]]
            if ind != indent or not text0.startswith("- "):
                break
            item = text0[2:].strip()
            pos[0] += 1
            if item == "":
                if pos[0] < len(lines) and lines[pos[0]][0] > indent:
                    lst.append(parse_node(lines[pos[0]][0]))
                else:
                    lst.append(None)
            elif (":" in item) and not item.startswith("["):
                m = {}
                k, _, v = item.partition(":")
                k = k.strip()
                v = v.strip()
                if v == "":
                    if pos[0] < len(lines) and lines[pos[0]][0] > indent:
                        m[k] = parse_node(lines[pos[0]][0])
                    else:
                        m[k] = None
                else:
                    m[k] = _scalar(v)
                while (pos[0] < len(lines) and lines[pos[0]][0] > indent
                       and not lines[pos[0]][1].startswith("- ")):
                    cind, ctext = lines[pos[0]]
                    ck, _, cv = ctext.partition(":")
                    ck = ck.strip()
                    cv = cv.strip()
                    pos[0] += 1
                    if cv == "":
                        if pos[0] < len(lines) and lines[pos[0]][0] > cind:
                            m[ck] = parse_node(lines[pos[0]][0])
                        else:
                            m[ck] = None
                    else:
                        m[ck] = _scalar(cv)
                lst.append(m)
            else:
                lst.append(_scalar(item))
        return lst

    result = parse_node(lines[0][0]) if lines else {}
    return result if isinstance(result, dict) else {}

def _in_quote(raw):
    # Conservative: keep the line intact if it contains a quoted value so a
    # "#" inside quotes is not treated as a comment. Our config has none, but
    # this avoids corrupting such values.
    return ('"' in raw) or ("'" in raw)

def deep_merge(base, over):
    if not isinstance(base, dict) or not isinstance(over, dict):
        return over
    out = dict(base)
    for k, v in over.items():
        if k in out and isinstance(out[k], dict) and isinstance(v, dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out

merged = {}
for p in (os.environ.get("CREDO_BUILTIN"),
          os.environ.get("CREDO_GLOBAL_F"),
          os.environ.get("CREDO_PROJECT_F")):
    layer = load_yaml(p)
    if layer:
        merged = deep_merge(merged, layer)

node = merged
for part in key.split("."):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        sys.exit(3)

if isinstance(node, (dict,)) or (isinstance(node, list) and any(isinstance(x, (dict, list)) for x in node)):
    print(json.dumps(node, ensure_ascii=False))
elif isinstance(node, list):
    for x in node:
        print("" if x is None else x)
elif node is None:
    print("")
else:
    print(node)
PY
        ;;
    ""|-h|--help|help)
        echo "usage: credo-config.sh {get <key>|backend|ensure-global|paths}" >&2
        [ -z "$CMD" ] && exit 1 || exit 0
        ;;
    *)
        echo "credo-config: unknown command: $CMD" >&2
        exit 1
        ;;
esac
