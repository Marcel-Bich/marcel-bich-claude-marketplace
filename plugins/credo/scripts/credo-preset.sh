#!/bin/bash
# credo-preset - resolve the active credo model preset and print what a subagent
# or the main agent needs: model id, Agent-tool alias, effort, the prompt text to
# append and the next action after an attempt.
#
# Presets: built-in quality, balanced (default) and budget (templates/presets.default.yaml)
# plus custom presets under presets: in the global, profile or project config.
# Select one with preset: <name> (project overrides global). See the credo guide,
# "Model presets".
#
# Usage:
#   credo-preset.sh [--field <name>] stage <role> [attempt]
#                     role: explore | build | review | hard; attempt: 1-based, default 1
#   credo-preset.sh [--field <name>] mainagent
#   credo-preset.sh show [name]     readable dump of a preset (default: the active one)
#   credo-preset.sh list            preset names, one per line
#   credo-preset.sh active          the active preset name
#
# stage fields:    preset role attempt stage model alias effort attempts action next
#                  next-model next-effort note prompt
# mainagent fields: preset model alias effort prompt
# Without --field: key: value lines, the prompt last (text on the following lines).
# With --field: only that value (for shell use).
#
# action is spawn (run this attempt) or back-to-human (chain used up). next is what
# follows a failed attempt: retry (same stage), next-stage (next-model/next-effort)
# or back-to-human. until-done has no attempt cap (budget caps and the no-progress
# rule stop it).
#
# Validation: an invalid role (unknown model id, bad effort, bad attempts,
# until-done or back-to-human in a wrong position, a missing role) prints a warning
# on stderr and that role falls back to the built-in balanced definition. An unknown
# preset name warns and falls back to balanced. Missing prompt keys add nothing.
#
# Exit codes: 0 ok, 2 usage error (unknown role or command, bad attempt, bad --field).
# The helper is read-only: it never writes config or state.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$SCRIPT_DIR/credo-config.sh"

usage() {
    echo "usage: credo-preset.sh [--field <name>] stage <role> [attempt] | mainagent | show [name] | list | active" >&2
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
# (the fallback target) and the raw preset selector. Read-only: no ensure-global.
export CREDO_SKIP_ENSURE=1
CREDO_PRESETS_JSON="$("$CFG" get presets 2>/dev/null)" || CREDO_PRESETS_JSON="{}"
CREDO_ACTIVE_RAW="$("$CFG" get preset 2>/dev/null)" || CREDO_ACTIVE_RAW=""
CREDO_BUILTIN_PRESETS_JSON="$(CREDO_GLOBAL=/nonexistent CREDO_PROFILE=/nonexistent CREDO_PROJECT=/nonexistent \
    "$CFG" get presets 2>/dev/null)" || CREDO_BUILTIN_PRESETS_JSON="{}"
export CREDO_PRESETS_JSON CREDO_ACTIVE_RAW CREDO_BUILTIN_PRESETS_JSON

exec python3 -I - "$FIELD" "${ARGS[@]}" <<'PY'
import json
import os
import sys

ROLES = ("explore", "build", "review", "hard")
PRESET_KEYS = ("universal-prompt", "mainagent") + ROLES
EFFORTS = ("low", "medium", "high", "xhigh", "max")
MODELS = {"claude-haiku-5-5": "haiku", "claude-opus-5-5": "opus", "claude-sonnet-5-5": "sonnet"}
STAGE_KEYS = ("model", "effort", "attempts", "subagent-prompt")
UNTIL = "until-done"
DEFAULT = "balanced"
STAGE_FIELDS = ("preset", "role", "attempt", "stage", "model", "alias", "effort", "attempts",
                "action", "next", "next-model", "next-effort", "note", "prompt")
MAIN_FIELDS = ("preset", "model", "alias", "effort", "prompt")

WARNED = set()


class RoleError(Exception):
    pass


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


def check_model(model, where):
    if model is None or model == "":
        raise RoleError("missing model in %s" % where)
    if not isinstance(model, str):
        raise RoleError("unknown model id '%s' in %s (known: %s)"
                        % (model, where, ", ".join(sorted(MODELS))))
    if model not in MODELS:
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


def is_back(item):
    return isinstance(item, str) and item == "back-to-human"


def parse_stage(item, role, pname):
    where = "role %s" % role
    if not isinstance(item, dict):
        raise RoleError("%s: a stage must be a mapping with model and effort" % where)
    for key in item:
        if key not in STAGE_KEYS:
            warn("unknown key '%s' in %s of preset '%s' - ignored" % (key, where, pname))
    check_model(item.get("model"), where)
    check_effort(item.get("effort"), where)
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
    return {"model": item["model"], "effort": item["effort"], "attempts": attempts,
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


def builtin_base(builtin):
    balanced = builtin.get(DEFAULT)
    if not isinstance(balanced, dict):
        die("built-in preset '%s' is missing (templates/presets.default.yaml)" % DEFAULT, 1)
    roles = {}
    for role in ROLES:
        roles[role] = parse_role(balanced.get(role), role, DEFAULT)
    return {"universal": check_prompt(balanced.get("universal-prompt"), "universal-prompt"),
            "main": parse_main(balanced.get("mainagent"), DEFAULT), "roles": roles}


def resolve(name, pdef, base):
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
    return {"name": name, "universal": universal, "main": main, "roles": roles}


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
    return resolve(name, presets[name], base), presets, builtin


def locate(stages, n):
    cum = 0
    for index, stage in enumerate(stages):
        if stage["attempts"] == UNTIL:
            return index, n - cum
        if n <= cum + stage["attempts"]:
            return index, n - cum
        cum += stage["attempts"]
    return None, None


def stage_values(eff, role, n):
    stages = eff["roles"][role]["stages"]
    index, k = locate(stages, n)
    values = {"preset": eff["name"], "role": role, "attempt": str(n), "model": "", "alias": "",
              "effort": "", "attempts": "", "next": "back-to-human", "next-model": "",
              "next-effort": "", "note": "", "prompt": ""}
    if index is None:
        values.update({"stage": "exhausted", "action": "back-to-human",
                       "note": "the chain has no attempt left - hand the item back to the human"})
        return values
    stage = stages[index]
    values.update({"stage": "%d of %d" % (index + 1, len(stages)), "action": "spawn",
                   "model": stage["model"], "alias": MODELS[stage["model"]],
                   "effort": stage["effort"],
                   "attempts": stage["attempts"] if stage["attempts"] == UNTIL else str(stage["attempts"]),
                   "prompt": join_prompt(eff["universal"], stage["subagent"])})
    if stage["attempts"] == UNTIL:
        values["next"] = "retry"
        values["note"] = ("until-done: no attempt cap; budget caps stop it, the same failure "
                          "twice without progress goes back to the human")
    elif k < stage["attempts"]:
        values["next"] = "retry"
    elif index + 1 < len(stages):
        nxt = stages[index + 1]
        values.update({"next": "next-stage", "next-model": nxt["model"], "next-effort": nxt["effort"]})
    else:
        values["note"] = "last attempt of the chain - a failure hands the item back to the human"
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


def show(name_arg):
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
    eff = resolve(name, presets[name], builtin_base(builtin))
    origin = "built-in" if name in builtin and builtin.get(name) == presets.get(name) else "custom"
    out = ["preset: %s (%s)" % (name, origin)]
    out.append("universal-prompt: %s" % (eff["universal"] or "(none)"))
    main = eff["main"]
    out.append("mainagent: %s / %s (recommendation only)" % (main["model"], main["effort"]))
    if main["prompt"]:
        out.append("  mainagent-prompt: %s" % main["prompt"])
    for role in ROLES:
        out.append("%s:" % role)
        for index, stage in enumerate(eff["roles"][role]["stages"]):
            attempts = "until-done" if stage["attempts"] == UNTIL else "%d" % stage["attempts"]
            out.append("  %d. %s / %s, attempts %s" % (index + 1, stage["model"], stage["effort"], attempts))
            if stage["subagent"]:
                out.append("     subagent-prompt: %s" % stage["subagent"])
        if eff["roles"][role]["terminal"]:
            out.append("  %d. back-to-human" % (len(eff["roles"][role]["stages"]) + 1))
    sys.stdout.write("\n".join(out) + "\n")


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
    elif cmd == "list":
        presets = load_json("CREDO_PRESETS_JSON")
        for name in sorted(presets):
            sys.stdout.write("%s\n" % name)
    elif cmd == "active":
        eff, _, _ = effective()
        sys.stdout.write("%s\n" % eff["name"])
    else:
        die("unknown command '%s' (use stage, mainagent, show, list or active)" % cmd)


main()
PY
