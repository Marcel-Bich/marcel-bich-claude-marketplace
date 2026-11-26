#!/bin/bash
# credo-preset - resolve the active credo model preset and print what a subagent
# or the main agent needs: model id, Agent-tool alias, effort, the allowed pairs of
# the rung, the spawn limits, the prompt text to append and the next action after
# an attempt.
#
# Presets: built-in budget, balanced (default) and quality (templates/presets.default.yaml)
# plus custom presets under presets: in the global, profile or project config.
# Select one with preset: <name> (project overrides global). See the credo guide,
# "Model presets".
#
# Usage:
#   credo-preset.sh [--field <name>] stage <role> [attempt]
#                     role: explore | build | review | hard; attempt: 1-based, default 1
#   credo-preset.sh [--field <name>] mainagent
#   credo-preset.sh show [name]     readable dump of a preset (default: the active one)
#   credo-preset.sh json            machine-readable dump of the active preset (spawn guard)
#   credo-preset.sh list            preset names, one per line
#   credo-preset.sh active          the active preset name
#
# stage fields:    preset role attempt stage model alias effort allowed attempts action
#                  next next-model next-effort note min-allowed max-allowed forbidden
#                  prompt
# mainagent fields: preset model alias effort prompt
# Without --field: key: value lines, the prompt last (text on the following lines).
# With --field: only that value (for shell use).
#
# Rung fields: model and effort each take a fixed value, any, or {from: X, to: Y};
# model: any implies effort: any unless effort is given. allowed-pairs: a list of
# such model/effort entries, only these combinations (nothing in between). stage
# model/effort are the cheapest allowed pair of the rung that is not forbidden;
# allowed lists everything the rung allows.
#
# Spawn limits: default-spawn-limits (top level, every preset) and a preset's own
# spawn-limits: min-allowed (optional), max-allowed (built-in claude-opus-5-5/medium),
# forbidden-models (entries with model, optional effort, roles and action) and
# forbidden-action (warn | block, default block). A preset's own min-allowed and
# max-allowed replace the defaults, its forbidden-models entries are added. Cost
# order of a pair: model first (haiku < sonnet < opus), then effort. A rung that
# requests a pair above max-allowed, below min-allowed or a forbidden one warns; a
# rung with no pair inside the limits is served by the nearest limit pair.
#
# Inheritance: extends: <preset> names one base (built-in or custom, any layer; chains
# allowed). A role of the child replaces the base role whole; mainagent merges field-wise
# and universal-prompt is replaced when the child sets it; spawn-limits min-allowed,
# max-allowed and forbidden-action of the child win, its forbidden-models are appended.
# A cycle or an unknown base is an error (exit 1). show marks inherited parts
# "(from <base>)".
#
# action is spawn (run this attempt) or back-to-human (chain used up). next is what
# follows a failed attempt: retry (same stage), next-stage (next-model/next-effort)
# or back-to-human. until-done has no attempt cap (budget caps and the no-progress
# rule stop it).
#
# Validation: an invalid role (unknown model id, bad effort, bad range, bad attempts,
# until-done or back-to-human in a wrong position, a missing role) prints a warning
# on stderr and that role falls back to the built-in balanced definition. An unknown
# preset name warns and falls back to balanced. Missing prompt keys add nothing.
#
# Exit codes: 0 ok, 1 preset error (extends cycle or unknown base), 2 usage error
# (unknown role or command, bad attempt, bad --field).
# The helper is read-only: it never writes config or state.

# python3 by name is missing or only the Store alias stub on native Windows: resolve the
# interpreter once (../hooks/credo-python-lib.sh; unchanged python3 elsewhere).
# shellcheck source-path=SCRIPTDIR source=../hooks/credo-python-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../hooks/credo-python-lib.sh" 2>/dev/null && credo_python_cmd
: "${CREDO_PYTHON:=python3}"

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$SCRIPT_DIR/credo-config.sh"

usage() {
    echo "usage: credo-preset.sh [--field <name>] stage <role> [attempt] | mainagent | show [name] | json | list | active" >&2
}

FIELD=""
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --field)
            if [ $# -lt 2 ]; then echo "credo-preset: --field needs a name" >&2; exit 2; fi
            FIELD="$2"
            shift 2
            ;;
        --field=*)
            FIELD="${1#--field=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

if [ "${#ARGS[@]}" -eq 0 ]; then
    usage
    exit 2
fi

# Layered presets (builtin < global < profile < project), plus the builtin ones alone
# (the fallback target), the raw preset selector and the layered default spawn limits.
# Read-only: no ensure-global.
export CREDO_SKIP_ENSURE=1
CREDO_PRESETS_JSON="$("$CFG" get presets 2>/dev/null)" || CREDO_PRESETS_JSON="{}"
CREDO_ACTIVE_RAW="$("$CFG" get preset 2>/dev/null)" || CREDO_ACTIVE_RAW=""
CREDO_BUILTIN_PRESETS_JSON="$(CREDO_GLOBAL=/nonexistent CREDO_PROFILE=/nonexistent CREDO_PROJECT=/nonexistent \
    "$CFG" get presets 2>/dev/null)" || CREDO_BUILTIN_PRESETS_JSON="{}"
CREDO_SPAWN_LIMITS_JSON="$("$CFG" get default-spawn-limits 2>/dev/null)" || CREDO_SPAWN_LIMITS_JSON="{}"
export CREDO_PRESETS_JSON CREDO_ACTIVE_RAW CREDO_BUILTIN_PRESETS_JSON CREDO_SPAWN_LIMITS_JSON

exec "$CREDO_PYTHON" -I - "$FIELD" "${ARGS[@]}" <<'PY'
import json
import os
import sys

ROLES = ("explore", "build", "review", "hard")
PRESET_KEYS = ("extends", "universal-prompt", "mainagent", "spawn-limits") + ROLES
EFFORTS = ("low", "medium", "high", "xhigh", "max")
# known model ids in cost order (haiku < sonnet < opus)
MODEL_IDS = ("claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5")
MODELS = {"claude-haiku-5-5": "haiku", "claude-opus-5-5": "opus", "claude-sonnet-5-5": "sonnet"}
ANY = "any"
STAGE_KEYS = ("model", "effort", "allowed-pairs", "attempts", "subagent-prompt")
LIMIT_KEYS = ("min-allowed", "max-allowed", "forbidden-models", "forbidden-action")
FORBIDDEN_KEYS = ("model", "effort", "roles", "action")
ACTIONS = ("warn", "block")
# fallback when no layer sets a valid max-allowed (same as templates/presets.default.yaml)
DEFAULT_MAX = ("claude-opus-5-5", "medium")
UNTIL = "until-done"
DEFAULT = "balanced"
STAGE_FIELDS = ("preset", "role", "attempt", "stage", "model", "alias", "effort", "allowed",
                "attempts", "action", "next", "next-model", "next-effort", "note",
                "min-allowed", "max-allowed", "forbidden", "prompt")
MAIN_FIELDS = ("preset", "model", "alias", "effort", "prompt")

WARNED = set()


class RoleError(Exception):
    pass


class PresetError(Exception):
    """An extends chain that cannot be resolved (cycle, unknown base, bad value)."""


def warn(msg):
    if msg not in WARNED:
        WARNED.add(msg)
        sys.stderr.write("credo-preset: warning: %s\n" % msg)


def die(msg, code=2):
    sys.stderr.write("credo-preset: %s\n" % msg)
    sys.exit(code)


def load_json(env_name):
    raw = os.environ.get(env_name, "")
    try:
        data = json.loads(raw) if raw.strip() else {}
    except ValueError:
        data = {}
    return data if isinstance(data, dict) else {}


def join_prompt(*parts):
    return "\n\n".join(p for p in parts if p)


def cost(pair):
    """Cost order of a pair: model first (haiku < sonnet < opus), then effort."""
    return (MODEL_IDS.index(pair[0]), EFFORTS.index(pair[1]))


def check_model(model, where):
    if model is None or model == "":
        raise RoleError("missing model in %s" % where)
    if not isinstance(model, str) or model not in MODELS:
        raise RoleError("unknown model id '%s' in %s (known: %s)"
                        % (model, where, ", ".join(sorted(MODELS))))


def check_effort(effort, where):
    if effort not in EFFORTS:
        raise RoleError("invalid effort '%s' in %s (use low, medium, high, xhigh or max)"
                        % (effort, where))


def check_prompt(value, where):
    if value is None:
        return ""
    if not isinstance(value, str):
        raise RoleError("%s must be text" % where)
    return value


def parse_values(raw, field, where):
    """model or effort value: fixed, any or {from: X, to: Y} -> (values, desc).
    desc is ('fixed', v), ('any',) or ('range', from, to)."""
    universe = MODEL_IDS if field == "model" else EFFORTS
    check = check_model if field == "model" else check_effort
    if isinstance(raw, str) and raw == ANY:
        return list(universe), (ANY,)
    if isinstance(raw, dict):
        for key in raw:
            if key not in ("from", "to"):
                raise RoleError("unknown key '%s' in the %s range of %s (use from and to)"
                                % (key, field, where))
        if "from" not in raw or "to" not in raw:
            raise RoleError("the %s range of %s needs from and to" % (field, where))
        check(raw["from"], where)
        check(raw["to"], where)
        lo, hi = universe.index(raw["from"]), universe.index(raw["to"])
        if lo > hi:
            raise RoleError("the %s range of %s goes from %s to %s - from must not lie above to"
                            % (field, where, raw["from"], raw["to"]))
        return list(universe[lo:hi + 1]), ("range", raw["from"], raw["to"])
    check(raw, where)
    return [raw], ("fixed", raw)


def desc_text(desc, alias=False):
    def name(v):
        return MODELS.get(v, v) if alias else v
    if desc[0] == ANY:
        return ANY
    if desc[0] == "range":
        return ("%s..%s" if alias else "from %s to %s") % (name(desc[1]), name(desc[2]))
    return name(desc[1])


def parse_entry(item, where, effort_default_any=False):
    """One model/effort entry -> {'pairs': set, 'text': str, 'alias': str, 'any': bool}."""
    if not isinstance(item, dict):
        raise RoleError("%s: an entry must be a mapping with model and effort" % where)
    models, mdesc = parse_values(item.get("model"), "model", where)
    if "effort" in item:
        efforts, edesc = parse_values(item.get("effort"), "effort", where)
    elif mdesc[0] == ANY or effort_default_any:
        efforts, edesc = list(EFFORTS), (ANY,)
    else:
        check_effort(None, where)
    pairs = {(m, e) for m in models for e in efforts}
    return {"pairs": pairs, "any": ANY in (mdesc[0], edesc[0]),
            "text": "%s / %s" % (desc_text(mdesc), desc_text(edesc)),
            "alias": "%s/%s" % (desc_text(mdesc, True), desc_text(edesc, True))}


def is_back(item):
    return isinstance(item, str) and item == "back-to-human"


def parse_stage(item, role, pname):
    where = "role %s" % role
    if not isinstance(item, dict):
        raise RoleError("%s: a stage must be a mapping with model and effort or allowed-pairs"
                        % where)
    for key in item:
        if key not in STAGE_KEYS:
            warn("unknown key '%s' in %s of preset '%s' - ignored" % (key, where, pname))
    if "allowed-pairs" in item:
        if "model" in item or "effort" in item:
            raise RoleError("%s: use either model/effort or allowed-pairs in a stage, not both"
                            % where)
        raw = item["allowed-pairs"]
        if not isinstance(raw, list) or not raw:
            raise RoleError("%s: allowed-pairs must be a non-empty list of model/effort entries"
                            % where)
        entries = [parse_entry(x, where) for x in raw]
    else:
        entries = [parse_entry(item, where)]
    if "attempts" not in item:
        attempts = UNTIL
    else:
        raw = item["attempts"]
        if raw == UNTIL:
            attempts = UNTIL
        elif isinstance(raw, int) and not isinstance(raw, bool) and raw >= 1:
            attempts = raw
        else:
            raise RoleError("invalid attempts '%s' in %s (a positive integer or until-done)"
                            % (raw, where))
    pairs = set()
    for entry in entries:
        pairs |= entry["pairs"]
    return {"entries": entries, "pairs": pairs, "attempts": attempts,
            "text": " or ".join(e["text"] for e in entries),
            "alias": " or ".join(e["alias"] for e in entries),
            "subagent": check_prompt(item.get("subagent-prompt"), "subagent-prompt in " + where)}


def parse_role(value, role, pname):
    if isinstance(value, dict):
        items = [value]
    elif isinstance(value, list):
        items = value
    else:
        raise RoleError("role %s must be a stage mapping or a list of stages" % role)
    if not items:
        raise RoleError("role %s has no stages" % role)
    stages = []
    terminal = False
    for index, item in enumerate(items):
        if is_back(item):
            if index != len(items) - 1:
                raise RoleError("back-to-human must be the last stage (role %s)" % role)
            terminal = True
            continue
        stage = parse_stage(item, role, pname)
        later = items[index + 1:]
        if stage["attempts"] == UNTIL and any(not is_back(x) for x in later):
            raise RoleError("until-done must be the last stage (role %s)" % role)
        stages.append(stage)
    if not stages:
        raise RoleError("role %s has no stage before back-to-human" % role)
    return {"stages": stages, "terminal": terminal}


def parse_main(value, pname):
    if not isinstance(value, dict):
        raise RoleError("mainagent must be a mapping with model and effort")
    check_model(value.get("model"), "mainagent")
    check_effort(value.get("effort"), "mainagent")
    return {"model": value["model"], "effort": value["effort"],
            "prompt": check_prompt(value.get("mainagent-prompt"), "mainagent-prompt")}


# --- spawn limits ------------------------------------------------------------------

def parse_limit_pair(raw, where):
    if not isinstance(raw, dict):
        raise RoleError("%s must be a mapping with model and effort" % where)
    check_model(raw.get("model"), where)
    check_effort(raw.get("effort"), where)
    return (raw["model"], raw["effort"])


def parse_forbidden(raw, where, action):
    """forbidden-models list -> [{'pairs', 'roles', 'action', 'text', 'alias'}]; an invalid
    entry warns and is skipped."""
    if raw is None:
        return []
    if not isinstance(raw, list):
        warn("%s must be a list of entries - ignored" % where)
        return []
    out = []
    for index, item in enumerate(raw):
        here = "%s entry %d" % (where, index + 1)
        try:
            if not isinstance(item, dict):
                raise RoleError("%s must be a mapping with model" % here)
            for key in item:
                if key not in FORBIDDEN_KEYS:
                    warn("unknown key '%s' in %s - ignored" % (key, here))
            entry = parse_entry(item, here, effort_default_any=True)
            roles = item.get("roles")
            if roles is None:
                roles = list(ROLES)
            elif not isinstance(roles, list) or not roles or any(r not in ROLES for r in roles):
                raise RoleError("roles in %s must be a list of explore, build, review, hard" % here)
            own = item.get("action")
            if own is not None and own not in ACTIONS:
                raise RoleError("action '%s' in %s must be warn or block" % (own, here))
        except RoleError as exc:
            warn("%s - entry ignored" % exc)
            continue
        entry.update({"roles": [r for r in ROLES if r in roles], "action": own or action, "index": index})
        out.append(entry)
    return out


def resolve_limits(name, pdef, sources=None):
    """{'min': pair or None, 'max': pair, 'forbidden': [...], 'action': str}. A preset's own
    spawn-limits replace min-allowed/max-allowed/forbidden-action of default-spawn-limits and
    add their forbidden-models entries. max-allowed can never be removed: missing or invalid
    falls back to the built-in default."""
    defaults = load_json("CREDO_SPAWN_LIMITS_JSON")
    own = pdef.get("spawn-limits")
    if own is None:
        own = {}
    elif not isinstance(own, dict):
        warn("spawn-limits of preset '%s' must be a mapping - ignored" % name)
        own = {}
    for src, label in ((defaults, "default-spawn-limits"), (own, "spawn-limits of preset '%s'" % name)):
        for key in src:
            if key not in LIMIT_KEYS:
                warn("unknown key '%s' in %s - ignored" % (key, label))

    def pick(key):
        if key in own:
            return own[key], "%s in spawn-limits of preset '%s'" % (key, name)
        return defaults.get(key), "%s in default-spawn-limits" % key

    out = {}
    for key in ("min-allowed", "max-allowed"):
        raw, where = pick(key)
        pair = None
        if raw is not None and raw != "" and raw != "none":
            try:
                pair = parse_limit_pair(raw, where)
            except RoleError as exc:
                warn("%s - %s" % (exc, "using the built-in max-allowed %s/%s" % DEFAULT_MAX
                                  if key == "max-allowed" else "no min-allowed used"))
        out[key] = pair
    out["max"] = out.pop("max-allowed") or DEFAULT_MAX
    out["min"] = out.pop("min-allowed")
    if out["min"] and cost(out["min"]) > cost(out["max"]):
        warn("min-allowed %s/%s of preset '%s' lies above its max-allowed %s/%s - no min-allowed used"
             % (out["min"] + (name,) + out["max"]))
        out["min"] = None
    action, where = pick("forbidden-action")
    if action is None:
        action = "block"
    elif action not in ACTIONS:
        warn("%s is '%s' - use warn or block; using block" % (where, action))
        action = "block"
    out["action"] = action
    sources = sources or {}
    origins = sources.get("spawn-limits.forbidden-models") or []
    preset_entries = parse_forbidden(own.get("forbidden-models"),
                                     "forbidden-models in spawn-limits of preset '%s'" % name, action)
    for entry in preset_entries:
        entry["origin"] = origins[entry["index"]] if entry["index"] < len(origins) else name
    out["forbidden"] = (parse_forbidden(defaults.get("forbidden-models"),
                                        "forbidden-models in default-spawn-limits", action)
                        + preset_entries)
    return out


def within(pair, limits):
    return (cost(pair) <= cost(limits["max"])
            and not (limits["min"] and cost(pair) < cost(limits["min"])))


def forbidden_for(pair, role, limits):
    return [f for f in limits["forbidden"] if role in f["roles"] and pair in f["pairs"]]


def apply_limits(roles, limits, name):
    """Restrict every rung to the pairs inside min-allowed..max-allowed. A rung that requests
    a pair outside the limits or a forbidden pair warns (pairs that only come from an `any`
    are not reported); a rung without any pair inside the limits is served by the nearest
    limit pair and marked capped."""
    out = {}
    for role in ROLES:
        stages = []
        for index, stage in enumerate(roles[role]["stages"]):
            where = "role %s stage %d of preset '%s' (%s)" % (role, index + 1, name, stage["text"])
            explicit = set()
            for entry in stage["entries"]:
                if not entry["any"]:
                    explicit |= entry["pairs"]
            above = sorted((p for p in explicit if cost(p) > cost(limits["max"])), key=cost)
            below = sorted((p for p in explicit if limits["min"] and cost(p) < cost(limits["min"])),
                           key=cost)
            if above:
                warn("%s requests %s above the max-allowed %s/%s"
                     % ((where, ", ".join("%s/%s" % p for p in above)) + limits["max"]))
            if below:
                warn("%s requests %s below the min-allowed %s/%s"
                     % ((where, ", ".join("%s/%s" % p for p in below)) + limits["min"]))
            bad = sorted((p for p in explicit if forbidden_for(p, role, limits)), key=cost)
            if bad:
                warn("%s requests forbidden %s (forbidden-models)"
                     % (where, ", ".join("%s/%s" % p for p in bad)))
            requested = stage["pairs"]
            pairs = {p for p in requested if within(p, limits)}
            stage = dict(stage, pairs=pairs)
            if not pairs:
                bound = limits["max"] if all(cost(p) > cost(limits["max"]) for p in requested) \
                    else limits["min"]
                stage.update(pairs={bound}, capped="%s/%s" % bound)
            stages.append(stage)
        out[role] = {"stages": stages, "terminal": roles[role]["terminal"]}
    return out


def own_sources(name, pdef):
    """Source map of a preset's own keys: top-level keys plus mainagent.<field>,
    spawn-limits.<key> and spawn-limits.forbidden-models as a list (one name per entry)."""
    src = {}
    for key, value in pdef.items():
        if key == "extends":
            continue
        src[key] = name
        if key == "mainagent" and isinstance(value, dict):
            for field in value:
                src["mainagent." + field] = name
        if key == "spawn-limits" and isinstance(value, dict):
            for field, fvalue in value.items():
                src["spawn-limits." + field] = name
            if isinstance(value.get("forbidden-models"), list):
                src["spawn-limits.forbidden-models"] = [name] * len(value["forbidden-models"])
    return src


def flatten(name, presets, chain=()):
    """Resolve `extends: <preset>` (single base, chains allowed) -> (flat definition, sources).
    A role of the child replaces the base role whole; mainagent merges field-wise (child wins);
    universal-prompt: child wins; spawn-limits: min-allowed, max-allowed and forbidden-action of
    the child win, forbidden-models are appended to the base's."""
    if name in chain:
        raise PresetError("preset inheritance cycle: %s" % " -> ".join(chain + (name,)))
    pdef = presets.get(name)
    if not isinstance(pdef, dict):
        raise PresetError("preset '%s' extends unknown preset '%s' (known: %s)"
                          % (chain[-1], name, ", ".join(sorted(presets))))
    base_name = pdef.get("extends")
    if base_name is None:
        return {k: v for k, v in pdef.items() if k != "extends"}, own_sources(name, pdef)
    if not isinstance(base_name, str) or not base_name.strip():
        raise PresetError("extends in preset '%s' must be the name of one preset" % name)
    base, src = flatten(base_name.strip(), presets, chain + (name,))
    flat, src = dict(base), dict(src)
    own = own_sources(name, pdef)
    for key, value in pdef.items():
        if key == "extends":
            continue
        old = base.get(key)
        if key == "mainagent" and isinstance(value, dict) and isinstance(old, dict):
            flat[key] = dict(old, **value)
            src.update((k, v) for k, v in own.items() if k.startswith("mainagent."))
        elif key == "spawn-limits" and isinstance(value, dict) and isinstance(old, dict):
            merged = dict(old, **{k: v for k, v in value.items() if k != "forbidden-models"})
            src.update((k, v) for k, v in own.items()
                       if k.startswith("spawn-limits.") and k != "spawn-limits.forbidden-models")
            if "forbidden-models" in value:
                base_list = old.get("forbidden-models") if isinstance(old.get("forbidden-models"), list) else []
                own_list = value["forbidden-models"] if isinstance(value["forbidden-models"], list) else []
                merged["forbidden-models"] = base_list + own_list
                src["spawn-limits.forbidden-models"] = (
                    list(src.get("spawn-limits.forbidden-models") or [])[:len(base_list)]
                    + [name] * len(own_list))
            flat[key] = merged
        else:
            flat[key] = value
            src.update((k, v) for k, v in own.items() if k == key or k.startswith(key + "."))
    return flat, src


def builtin_base(builtin):
    balanced = builtin.get(DEFAULT)
    if not isinstance(balanced, dict):
        die("built-in preset '%s' is missing (templates/presets.default.yaml)" % DEFAULT, 1)
    roles = {}
    for role in ROLES:
        roles[role] = parse_role(balanced.get(role), role, DEFAULT)
    return {"universal": check_prompt(balanced.get("universal-prompt"), "universal-prompt"),
            "main": parse_main(balanced.get("mainagent"), DEFAULT), "roles": roles}


def resolve(name, pdef, base, presets=None):
    sources = own_sources(name, pdef)
    if presets is not None:
        try:
            pdef, sources = flatten(name, dict(presets, **{name: pdef}))
        except PresetError as exc:
            die(str(exc), 1)
    universal = ""
    if "universal-prompt" in pdef:
        try:
            universal = check_prompt(pdef.get("universal-prompt"), "universal-prompt in preset '%s'" % name)
        except RoleError as exc:
            warn("%s - no universal prompt used" % exc)
    for key in pdef:
        if key not in PRESET_KEYS:
            warn("unknown role or key '%s' in preset '%s' (expected explore, build, review, hard) - ignored"
                 % (key, name))
    if "mainagent" in pdef:
        try:
            main = parse_main(pdef["mainagent"], name)
        except RoleError as exc:
            warn("%s - using balanced for mainagent" % exc)
            main = base["main"]
    else:
        warn("mainagent not set in preset '%s' - using balanced" % name)
        main = base["main"]
    roles = {}
    for role in ROLES:
        if role not in pdef:
            warn("role '%s' not set in preset '%s' - using balanced" % (role, name))
            roles[role] = base["roles"][role]
            continue
        try:
            roles[role] = parse_role(pdef[role], role, name)
        except RoleError as exc:
            warn("%s - using balanced for %s" % (exc, role))
            roles[role] = base["roles"][role]
    limits = resolve_limits(name, pdef, sources)
    return {"name": name, "universal": universal, "main": main,
            "roles": apply_limits(roles, limits, name), "limits": limits, "sources": sources}


def effective():
    presets = load_json("CREDO_PRESETS_JSON")
    builtin = load_json("CREDO_BUILTIN_PRESETS_JSON")
    base = builtin_base(builtin)
    name = os.environ.get("CREDO_ACTIVE_RAW", "").strip() or DEFAULT
    if name not in presets or not isinstance(presets.get(name), dict):
        if name in presets:
            warn("preset '%s' is not a mapping - using balanced" % name)
        else:
            warn("unknown preset '%s' (known: %s) - using balanced"
                 % (name, ", ".join(sorted(presets))))
        name = DEFAULT
        presets = dict(presets)
        presets[DEFAULT] = builtin.get(DEFAULT, {})
    return resolve(name, presets[name], base, presets), presets, builtin


def locate(stages, n):
    cum = 0
    for index, stage in enumerate(stages):
        if stage["attempts"] == UNTIL:
            return index, n - cum
        if n <= cum + stage["attempts"]:
            return index, n - cum
        cum += stage["attempts"]
    return None, None


def pick_pair(stage, role, limits):
    """The cheapest allowed pair of a rung that no forbidden-models entry matches (else the
    cheapest allowed pair)."""
    ordered = sorted(stage["pairs"], key=cost)
    for pair in ordered:
        if not forbidden_for(pair, role, limits):
            return pair
    return ordered[0]


def limit_values(limits, role):
    return {"min-allowed": "%s/%s" % limits["min"] if limits["min"] else "",
            "max-allowed": "%s/%s" % limits["max"],
            "forbidden": "; ".join("%s (%s)" % (f["text"], f["action"])
                                   for f in limits["forbidden"] if role in f["roles"])}


def stage_values(eff, role, n):
    stages = eff["roles"][role]["stages"]
    limits = eff["limits"]
    index, k = locate(stages, n)
    values = {"preset": eff["name"], "role": role, "attempt": str(n), "model": "", "alias": "",
              "effort": "", "allowed": "", "attempts": "", "next": "back-to-human",
              "next-model": "", "next-effort": "", "note": "", "prompt": ""}
    values.update(limit_values(limits, role))
    if index is None:
        values.update({"stage": "exhausted", "action": "back-to-human",
                       "note": "the chain has no attempt left - hand the item back to the human"})
        return values
    stage = stages[index]
    model, effort = pick_pair(stage, role, limits)
    allowed = stage["text"] if not stage.get("capped") else stage["capped"]
    values.update({"stage": "%d of %d" % (index + 1, len(stages)), "action": "spawn",
                   "model": model, "alias": MODELS[model], "effort": effort,
                   "allowed": allowed,
                   "attempts": stage["attempts"] if stage["attempts"] == UNTIL else str(stage["attempts"]),
                   "prompt": join_prompt(eff["universal"], stage["subagent"])})
    if stage["attempts"] == UNTIL:
        values["next"] = "retry"
        values["note"] = ("until-done: no attempt cap; budget caps stop it. By default the same "
                          "failure twice without progress is an early hand-back; a repo's "
                          ".credo/RULES.md can switch that default off")
    elif k < stage["attempts"]:
        values["next"] = "retry"
    elif index + 1 < len(stages):
        nxt_model, nxt_effort = pick_pair(stages[index + 1], role, limits)
        values.update({"next": "next-stage", "next-model": nxt_model, "next-effort": nxt_effort})
    else:
        values["note"] = "last attempt of the chain - a failure hands the item back to the human"
    if stage.get("capped"):
        values["note"] = "; ".join(x for x in (
            "the preset rung %s lies outside the spawn limits - this rung uses %s"
            % (stage["text"], stage["capped"]), values["note"]) if x)
    return values


def main_values(eff):
    main = eff["main"]
    return {"preset": eff["name"], "model": main["model"], "alias": MODELS[main["model"]],
            "effort": main["effort"], "prompt": join_prompt(eff["universal"], main["prompt"])}


def emit(values, keys, field, prompt_key="prompt"):
    if field:
        if field not in keys:
            die("unknown field '%s' (use: %s)" % (field, ", ".join(keys)))
        sys.stdout.write("%s\n" % values[field])
        return
    for key in keys:
        if key == prompt_key:
            sys.stdout.write("prompt:\n")
            if values[key]:
                sys.stdout.write("%s\n" % values[key])
        elif values.get(key, ""):
            sys.stdout.write("%s: %s\n" % (key, values[key]))


def resolve_named(name_arg):
    presets = load_json("CREDO_PRESETS_JSON")
    builtin = load_json("CREDO_BUILTIN_PRESETS_JSON")
    if name_arg and isinstance(presets.get(name_arg), dict):
        name = name_arg
    elif name_arg:
        warn("unknown preset '%s' (known: %s) - showing balanced"
             % (name_arg, ", ".join(sorted(presets))))
        name = DEFAULT
    else:
        name = effective()[0]["name"]
    if name == DEFAULT and not isinstance(presets.get(DEFAULT), dict):
        presets = dict(presets, **{DEFAULT: builtin.get(DEFAULT, {})})
    eff = resolve(name, presets[name], builtin_base(builtin), presets)
    origin = "built-in" if name in builtin and builtin.get(name) == presets.get(name) else "custom"
    return eff, origin


def show(name_arg):
    eff, origin = resolve_named(name_arg)
    limits = eff["limits"]
    src = eff["sources"]

    def mark(*keys):
        """' (from <base>)' when every given key comes from another preset (extends)."""
        names = {src.get(k) for k in keys if src.get(k)}
        names.discard(eff["name"])
        return " (from %s)" % ", ".join(sorted(names)) if names else ""

    out = ["preset: %s (%s)" % (eff["name"], origin)]
    out.append("universal-prompt: %s%s" % (eff["universal"] or "(none)", mark("universal-prompt")))
    main = eff["main"]
    out.append("mainagent: %s / %s (recommendation only)%s"
               % (main["model"], main["effort"], mark("mainagent.model", "mainagent.effort")))
    if main["prompt"]:
        out.append("  mainagent-prompt: %s%s" % (main["prompt"], mark("mainagent.mainagent-prompt")))
    out.append("spawn-limits (hard for every spawn):")
    if limits["min"]:
        out.append("  min-allowed: %s / %s" % limits["min"] + mark("spawn-limits.min-allowed"))
    out.append("  max-allowed: %s / %s" % limits["max"] + mark("spawn-limits.max-allowed"))
    if limits["forbidden"]:
        out.append("  forbidden-models:")
        for f in limits["forbidden"]:
            scope = "all roles" if len(f["roles"]) == len(ROLES) else "roles " + ", ".join(f["roles"])
            came = f.get("origin")
            out.append("    - %s, %s, %s%s" % (f["text"], scope, f["action"],
                                               " (from %s)" % came if came and came != eff["name"] else ""))
    out.append("  forbidden-action: %s" % limits["action"] + mark("spawn-limits.forbidden-action"))
    for role in ROLES:
        out.append("%s:%s" % (role, mark(role)))
        for index, stage in enumerate(eff["roles"][role]["stages"]):
            attempts = "until-done" if stage["attempts"] == UNTIL else "%d" % stage["attempts"]
            out.append("  %d. %s, attempts %s" % (index + 1, stage["text"], attempts))
            if stage.get("capped"):
                out.append("     capped: outside the spawn limits, this rung uses %s" % stage["capped"])
            if stage["subagent"]:
                out.append("     subagent-prompt: %s" % stage["subagent"])
        if eff["roles"][role]["terminal"]:
            out.append("  %d. back-to-human" % (len(eff["roles"][role]["stages"]) + 1))
    sys.stdout.write("\n".join(out) + "\n")


def alias_pairs(pairs):
    return sorted(([MODELS[m], e] for m, e in pairs), key=lambda p: (
        ("haiku", "sonnet", "opus").index(p[0]), EFFORTS.index(p[1])))


def dump_json():
    """The active preset for the spawn guard: aliases instead of model ids."""
    eff = effective()[0]
    limits = eff["limits"]
    roles = {}
    for role in ROLES:
        rungs = []
        for stage in eff["roles"][role]["stages"]:
            label = stage["alias"] if not stage.get("capped") else \
                "%s/%s" % (MODELS[next(iter(stage["pairs"]))[0]], next(iter(stage["pairs"]))[1])
            rungs.append({"pairs": alias_pairs(stage["pairs"]), "label": label,
                          "attempts": UNTIL if stage["attempts"] == UNTIL else str(stage["attempts"])})
        roles[role] = {"rungs": rungs, "terminal": eff["roles"][role]["terminal"]}
    data = {"name": eff["name"], "roles": roles,
            "min": [MODELS[limits["min"][0]], limits["min"][1]] if limits["min"] else None,
            "max": [MODELS[limits["max"][0]], limits["max"][1]],
            "forbidden": [{"pairs": alias_pairs(f["pairs"]), "roles": f["roles"],
                           "action": f["action"], "label": f["alias"]} for f in limits["forbidden"]]}
    sys.stdout.write(json.dumps(data) + "\n")


def main():
    field = sys.argv[1]
    args = sys.argv[2:]
    cmd = args[0]
    if cmd == "stage":
        if len(args) < 2 or len(args) > 3:
            die("usage: stage <role> [attempt]")
        role = args[1]
        if role not in ROLES:
            die("unknown role '%s' (use explore, build, review or hard)" % role)
        raw = args[2] if len(args) == 3 else "1"
        if not raw.isdigit() or int(raw) < 1:
            die("attempt must be a positive integer, got '%s'" % raw)
        eff, _, _ = effective()
        emit(stage_values(eff, role, int(raw)), STAGE_FIELDS, field)
    elif cmd == "mainagent":
        if len(args) != 1:
            die("usage: mainagent")
        eff, _, _ = effective()
        emit(main_values(eff), MAIN_FIELDS, field)
    elif cmd == "show":
        if len(args) > 2:
            die("usage: show [name]")
        show(args[1] if len(args) == 2 else "")
    elif cmd == "json":
        if len(args) != 1:
            die("usage: json")
        dump_json()
    elif cmd == "list":
        presets = load_json("CREDO_PRESETS_JSON")
        for name in sorted(presets):
            sys.stdout.write("%s\n" % name)
    elif cmd == "active":
        eff, _, _ = effective()
        sys.stdout.write("%s\n" % eff["name"])
    else:
        die("unknown command '%s' (use stage, mainagent, show, json, list or active)" % cmd)


main()
PY
