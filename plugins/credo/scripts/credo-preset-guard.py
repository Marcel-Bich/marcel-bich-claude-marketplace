#!/usr/bin/env python3
"""credo-preset-guard.py - enforce the active model preset on Agent and Task spawns.

Called by hooks/credo-agent-spawn-check.sh (PreToolUse on Agent and Task) with the hook
input on stdin. Prints a hook decision JSON (or nothing) and always exits 0.

Rules:
- No preset configured (no `preset:` key in any config layer) -> no check.
- Deny only BELOW the preset (owner decision Q425). The hook cannot know the role or the
  attempt of a spawn, so a spawn passes when its (model, effort) is equal to or stronger
  than ANY rung of the ladders that fit its kind:
    subagent_type Explore or Plan -> the explore role only;
    any other type                -> the build, review and hard roles.
  Stronger = model rank haiku < sonnet < opus < fable and effort rank
  low < medium < high < xhigh < max, both >= the rung. An exact rung match gets a short
  "ok" context line; a stronger spawn passes with a visible line
  "stronger than preset: <model>/<effort> vs <rung>" (context + systemMessage) for the
  main agent to report.
- Missing model is a mismatch (the spawn would inherit the parent's model); missing effort
  is a mismatch (every rung defines one); an unknown model or effort cannot be ranked and
  is a mismatch. A mismatch or a weaker pair is denied with the minimum pairs and the lookup
  command `credo-preset.sh stage <role> <attempt>`.
- subagent_type "fork" inherits the parent's model and effort (a model on the call is
  ignored). It passes only when the parent's model (last assistant model in the parent
  transcript) is >= the model of a fitting rung; the inherited effort cannot be read and is
  not checked. Otherwise it is denied with the hint to spawn a regular subagent with model
  and effort.
- Exceptions add pairs that count like rungs (so they may allow a weaker pair), one per
  line, in this format:
      preset exception: <scope> -> <model>/<effort>[, <model>/<effort> ...]
  scope: all, or one or more roles (explore, build, review, hard) separated by commas.
  a) .credo/RULES.md: such a line anywhere outside code fences (bullet optional, text
     after a further `|` is ignored). Permanent until removed.
  b) The handoff section "## Rules (temporary)" of .credo/process/handoffs/HANDOFF.md:
     - preset exception: build -> opus/max | source: owner "<quote>" (<YYYY-MM-DD>) | until: <YYYY-MM-DD>
     valid only with an owner source with date and an until that starts with a date that
     is today or later (credo-handoff-rules.py check_rule finds no problem). Agent-decision
     rules and undated or expired untils never grant an exception.
  The .credo files are read from the main checkout (git common dir) of the hook's cwd,
  then from the cwd's own top level.
- Internal errors fail open: a warning goes to stderr and to the log file
  (CREDO_PRESET_GUARD_LOG, default <CLAUDE_CONFIG_DIR or ~/.claude>/credo/logs/preset-guard.log).

Test hooks: CREDO_PRESET_GUARD_TODAY=YYYY-MM-DD fixes today's date.
"""
import datetime
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PRESET_SH = os.path.join(HERE, "credo-preset.sh")
CONFIG_SH = os.path.join(HERE, "credo-config.sh")
HANDOFF_RULES_PY = os.path.join(HERE, "credo-handoff-rules.py")
ROLES = ("explore", "build", "review", "hard")
EXPLORE_TYPES = ("Explore", "Plan")
BUILD_ROLES = ("build", "review", "hard")
EFFORTS = ("low", "medium", "high", "xhigh", "max")  # ascending strength
MODEL_RANK = {"haiku": 1, "sonnet": 2, "opus": 3, "fable": 4}  # ascending strength
LOOKUP = "credo-preset.sh stage <role> <attempt>"
EXC_RE = re.compile(r"^\s*(?:[-*+]\s+)?`?preset\s+exception\s*:\s*(.+?)`?\s*$", re.I)
PAIR_RE = re.compile(r"^([A-Za-z0-9._-]+)\s*/\s*([a-z]+)$")


class GuardError(Exception):
    pass


def alias_of(model):
    m = (model or "").strip().lower()
    for name in ("haiku", "opus", "sonnet", "fable"):
        if m == name or m.startswith("claude-%s-" % name):
            return name
    return m


def log_warning(msg):
    line = "credo-preset-guard: warning: %s" % msg
    sys.stderr.write(line + "\n")
    path = os.environ.get("CREDO_PRESET_GUARD_LOG") or os.path.join(
        os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
        "credo", "logs", "preset-guard.log")
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (datetime.datetime.now().isoformat(timespec="seconds"), line))
    except OSError:
        pass


def run(cmd):
    env = dict(os.environ, CREDO_SKIP_ENSURE="1")
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=8, env=env)
    if res.returncode != 0:
        raise GuardError("%s exited %d" % (os.path.basename(cmd[1]), res.returncode))
    return res.stdout


def preset_configured():
    if not os.path.isfile(CONFIG_SH):
        raise GuardError("credo-config.sh missing")
    return run(["bash", CONFIG_SH, "get", "preset"]).strip() != ""


def read_ladder():
    """{'name': str, 'roles': {role: [(alias, effort, attempts), ...]}, 'back': {role: bool}}"""
    if not os.path.isfile(PRESET_SH):
        raise GuardError("credo-preset.sh missing")
    out = run(["bash", PRESET_SH, "show"])
    name, role = "", None
    roles = {r: [] for r in ROLES}
    back = {r: False for r in ROLES}
    for line in out.splitlines():
        if line.startswith("preset: "):
            name = line.split()[1]
            continue
        if line.rstrip(":") in ROLES and line.endswith(":"):
            role = line[:-1]
            continue
        m = re.match(r"^  \d+\. (claude-\S+) / (\w+), attempts (\S+)$", line)
        if m and role:
            roles[role].append((alias_of(m.group(1)), m.group(2), m.group(3)))
        elif role and re.match(r"^  \d+\. back-to-human$", line):
            back[role] = True
    if not name or not any(roles.values()):
        raise GuardError("cannot parse the preset (credo-preset.sh show)")
    return {"name": name, "roles": roles, "back": back}


def ladder_text(ladder, roles):
    parts = []
    for role in roles:
        segs, start, open_chain = [], 1, True
        for alias, effort, attempts in ladder["roles"][role]:
            if not open_chain:
                break
            if attempts == "until-done":
                segs.append("%d+ %s/%s" % (start, alias, effort))
                open_chain = False
            else:
                n = int(attempts)
                rng = str(start) if n == 1 else "%d-%d" % (start, start + n - 1)
                segs.append("%s %s/%s" % (rng, alias, effort))
                start += n
        if ladder["back"][role] and open_chain:
            segs.append("attempt %d back-to-human" % start)
        if segs:
            parts.append("%s: %s" % (role, ", ".join(segs)))
    return "; ".join(parts)


def parse_exception(text):
    """'<scope> -> pairs [| ...]' -> (set of roles, set of (alias, effort)) or None."""
    body = text.split("|", 1)[0].replace("`", "").strip()
    if "->" not in body:
        return None
    scope_raw, pairs_raw = body.split("->", 1)
    scope = set()
    for s in re.split(r"[,\s]+", scope_raw.strip().lower()):
        if not s:
            continue
        if s == "all":
            scope.update(ROLES)
        elif s in ROLES:
            scope.add(s)
        else:
            return None
    pairs = set()
    for p in re.split(r"[,\s]+", pairs_raw.strip()):
        if not p:
            continue
        m = PAIR_RE.match(p)
        if not m or m.group(2).lower() not in EFFORTS:
            return None
        pairs.add((alias_of(m.group(1)), m.group(2).lower()))
    if not scope or not pairs:
        return None
    return scope, pairs


def unfenced(lines):
    fence = None
    for line in lines:
        lead = line.lstrip()
        if fence is None and lead.startswith(("```", "~~~")):
            fence = lead[:3]
            continue
        if fence is not None:
            if lead.startswith(fence):
                fence = None
            continue
        yield line


def rules_md_exceptions(path):
    out = []
    if not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8") as fh:
        for line in unfenced(fh.read().splitlines()):
            m = EXC_RE.match(line)
            if m:
                exc = parse_exception(m.group(1))
                if exc:
                    out.append(exc + ("RULES.md",))
    return out


def load_handoff_rules():
    spec = importlib.util.spec_from_file_location("credo_handoff_rules", HANDOFF_RULES_PY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def handoff_exceptions(path, today):
    out = []
    if not os.path.isfile(path):
        return out
    hr = load_handoff_rules()
    rules_level = None  # level of the open "Rules (temporary)" heading; subsections belong to it
    for level, title, _start, body in hr.sections(hr.read(path)):
        if rules_level is None or level <= rules_level:
            rules_level = level if title.strip().lower() == hr.SECTION.lower() else None
        if rules_level is None:
            continue
        for _no, text in hr.rule_lines(body):
            m = EXC_RE.match(text)
            if not m or hr.check_rule(text, today):
                continue
            fields = hr.fields_of(text)
            src = fields.get("source", "")
            until = hr.DATE_RE.match(fields.get("until", ""))
            if not src.lower().startswith("owner") or not until:
                continue
            exc = parse_exception(m.group(1))
            if exc:
                out.append(exc + ("handoff until %s" % until.group(1),))
    return out


def credo_roots(cwd):
    roots = []
    if not cwd or not os.path.isdir(cwd):
        return roots
    for args in (["rev-parse", "--path-format=absolute", "--git-common-dir"],
                 ["rev-parse", "--show-toplevel"]):
        try:
            res = subprocess.run(["git", "-C", cwd] + args, capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            continue
        if res.returncode != 0 or not res.stdout.strip():
            continue
        p = res.stdout.strip()
        if args[-1] == "--git-common-dir":
            p = os.path.dirname(p) if os.path.basename(p) == ".git" else ""
        if p and p not in roots:
            roots.append(p)
    if not roots:
        roots.append(cwd)
    return roots


def exceptions_for(cwd, today):
    out = []
    for root in credo_roots(cwd):
        credo = os.path.join(root, ".credo")
        if not os.path.isdir(credo):
            continue
        out += rules_md_exceptions(os.path.join(credo, "RULES.md"))
        out += handoff_exceptions(os.path.join(credo, "process", "handoffs", "HANDOFF.md"), today)
        break
    return out


def parent_model(data):
    path = data.get("transcript_path") or ""
    agent_id = data.get("agent_id") or ""
    if agent_id and path:
        sub = os.path.join(os.path.splitext(path)[0], "subagents", "agent-%s.jsonl" % agent_id)
        if os.path.isfile(sub):
            path = sub
        else:
            return ""
    if not path or not os.path.isfile(path):
        return ""
    with open(path, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        size = fh.tell()
        fh.seek(max(0, size - 512 * 1024))
        tail = fh.read().decode("utf-8", "replace").splitlines()
    for line in reversed(tail):
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if isinstance(rec, dict) and rec.get("type") == "assistant":
            model = (rec.get("message") or {}).get("model") or ""
            if model.startswith("claude-"):
                return model
    return ""


def emit(decision, text, visible=False):
    out = {"hookEventName": "PreToolUse"}
    if decision == "deny":
        out["permissionDecision"] = "deny"
        out["permissionDecisionReason"] = text
    else:
        out["additionalContext"] = text
    res = {"hookSpecificOutput": out, "suppressOutput": True}
    if visible:
        res["systemMessage"] = text
    print(json.dumps(res))


def fmt_pairs(pairs):
    return ", ".join("%s/%s" % p for p in sorted(pairs))


def at_least(pair, rung):
    """True when pair (alias, effort) is equal to or stronger than rung in model AND effort."""
    if pair[0] not in MODEL_RANK or rung[0] not in MODEL_RANK:
        return False
    if pair[1] not in EFFORTS or rung[1] not in EFFORTS:
        return False
    return (MODEL_RANK[pair[0]] >= MODEL_RANK[rung[0]]
            and EFFORTS.index(pair[1]) >= EFFORTS.index(rung[1]))


def decide(data, today):
    if data.get("tool_name") not in ("Agent", "Task"):
        return
    ti = data.get("tool_input") or {}
    if not isinstance(ti, dict):
        return
    if not preset_configured():
        return
    ladder = read_ladder()
    sub = str(ti.get("subagent_type") or "")
    kind_roles = ("explore",) if sub in EXPLORE_TYPES else BUILD_ROLES
    kind = "explore role (%s)" % sub if sub in EXPLORE_TYPES else "build/review/hard roles"
    allowed = set()
    for role in kind_roles:
        allowed.update((a, e) for a, e, _n in ladder["roles"][role])
    granted = {}
    for scope, pairs, source in exceptions_for(data.get("cwd") or os.getcwd(), today):
        if scope & set(kind_roles):
            for p in pairs:
                granted.setdefault(p, source)
    every = allowed | set(granted)
    pname = ladder["name"]
    ladder_line = ladder_text(ladder, ROLES)
    tail = ("Minimum for the %s: one of %s (an equal or stronger model and effort passes). "
            "Pick the rung of this role and attempt with %s and pass its alias as model and its "
            "effort as effort. Active ladder: %s. A weaker pair only via a valid owner rule with "
            "an until date in the handoff \"## Rules (temporary)\" or a line in .credo/RULES.md "
            "(format: preset exception: <all|role,...> -> <model>/<effort>)."
            % (kind, fmt_pairs(every), LOOKUP, ladder_line))

    if sub == "fork":
        parent = alias_of(parent_model(data))
        if parent in MODEL_RANK and any(MODEL_RANK[parent] >= MODEL_RANK.get(a, 99)
                                        for a, _e in every):
            emit("allow", "[credo-preset] fork ok: parent model %s is >= a rung model of the %s "
                 "ladder; the inherited effort is not checked." % (parent, pname))
            return
        emit("deny", "[credo-preset] Spawn denied (preset %s): a fork inherits the parent's "
             "model (%s), which is below every rung model of the %s. Spawn a regular subagent "
             "(e.g. general-purpose) with model and effort instead. %s"
             % (pname, parent or "unknown", kind, tail))
        return

    model = str(ti.get("model") or "").strip()
    effort = str(ti.get("effort") or "").strip().lower()
    reasons = []
    if not model:
        reasons.append("no model (it would inherit the parent's model)")
    elif alias_of(model) not in MODEL_RANK:
        reasons.append("unknown model %s" % model)
    if not effort:
        reasons.append("no effort")
    elif effort not in EFFORTS:
        reasons.append("unknown effort %s" % effort)
    pair = (alias_of(model), effort)
    covered = [] if reasons else sorted(p for p in every if at_least(pair, p))
    if not reasons and not covered:
        reasons.append("%s/%s is below every rung of the %s (weaker model or lower effort)"
                       % (pair[0], pair[1], kind))
    if reasons:
        emit("deny", "[credo-preset] Spawn denied (preset %s): %s. %s"
             % (pname, "; ".join(reasons), tail))
        return
    if pair in allowed:
        emit("allow", "[credo-preset] ok: %s/%s is a rung of the %s (preset %s); make sure it "
             "is the rung of this role and attempt." % (pair[0], pair[1], kind, pname))
    elif pair in granted:
        emit("allow", "[credo-preset] ok by preset exception (%s): %s/%s for the %s (preset %s)."
             % (granted[pair], pair[0], pair[1], kind, pname))
    else:
        line = ("[credo-preset] stronger than preset: %s/%s vs %s (%s, preset %s) - report it."
                % (pair[0], pair[1], " or ".join("%s/%s" % p for p in covered), kind, pname))
        emit("allow", line, visible=True)


def main():
    raw_today = os.environ.get("CREDO_PRESET_GUARD_TODAY", "")
    try:
        today = datetime.date.fromisoformat(raw_today) if raw_today else datetime.date.today()
        raw = sys.stdin.read()
        if not raw.strip():
            return 0
        try:
            data = json.loads(raw)
        except ValueError:
            return 0
        if isinstance(data, dict):
            decide(data, today)
    except Exception as exc:  # fail open on any internal error
        log_warning("%s: %s - spawn allowed unchecked" % (type(exc).__name__, exc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
