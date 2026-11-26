#!/usr/bin/env python3
"""credo-preset-guard.py - enforce the active model preset on Agent and Task spawns.

Called by hooks/credo-agent-spawn-check.sh (PreToolUse on Agent and Task) with the hook
input on stdin. Prints a hook decision JSON (or nothing) and always exits 0.

Rules:
- No preset configured (no `preset:` key in any config layer) -> no check.
- The preset comes from `credo-preset.sh json`: per role a chain of rungs, each with the
  set of allowed pairs (model/effort fixed, any, from-to ranges or allowed-pairs), plus the
  spawn limits min-allowed, max-allowed and forbidden-models (action warn or block).
- Role and attempt travel in a tag in the description or prompt:
  [credo-role: <role>#<attempt>] (e.g. [credo-role: review#3]).
    tag with attempt              -> exactly the rung that serves this attempt of the role
                                     (same mapping as credo-preset.sh stage <role> <attempt>);
                                     an attempt past the last rung is back-to-human -> deny, the
                                     owner decides now, UNLESS an owner rule allows continuing:
                                     a preset exception for the role or a preset continue line
                                     for the role (then the LAST real rung counts); both pass
                                     with a visible "continuing per owner rule" line; a
                                     non-numeric or 0 attempt -> deny;
    tag without attempt           -> a role with one rung: that rung (the attempt is
                                     optional); more than one rung -> deny with the
                                     attempt -> rung map and an example tag;
    read-only types (Explore, Plan, web-fetch, claude-code-guide, *:cavecrew-investigator)
    without a tag                 -> explore, attempt 1;
    any other type without a tag  -> ANY rung of the build, review and hard roles (the role
                                     is unknown; the ok line asks for the tag).
- A pair in the rung's allowed set passes with a short "ok" context line. A pair above
  every pair of the rung (cost order: model first, haiku < sonnet < opus < fable, then
  effort, low < medium < high < xhigh < max) passes with a visible line "stronger than
  preset: <model>/<effort> vs <rung>" (context + systemMessage) for the main agent to
  report (owner decision Q425a). A pair below the rung or between its allowed pairs is
  denied (allowed-pairs allow nothing in between).
- Spawn limits (#216) are hard and win over everything, also over preset exception and
  continue rules: a pair above max-allowed or below min-allowed is denied; a pair matching
  a forbidden-models entry for the role is denied (action block) or passes with a visible
  "forbidden model (warn)" line (action warn). Exception pairs outside the limits or
  blocked grant nothing.
- A deny names role, attempt, expected rung, chosen pair, the spawn limits, the cheapest
  allowed pair and the exact fix (model, effort, tag), the lookup command (absolute path of
  credo-preset.sh) and how to declare the role.
- Missing model is a mismatch (the agent definition's or the parent's model cannot be
  checked); missing effort is a mismatch; an unknown model or effort cannot be ranked and is
  a mismatch. Model ids are normalised (context suffix like [1m], Bedrock/Vertex prefixes
  like us.anthropic., version suffixes like -v1:0, full ids claude-<name>-x-y).
- subagent_type "fork" inherits the parent's model and effort (a model on the call is
  ignored). Owner decision Q429 B: denied when the parent's model (last assistant model in
  the parent transcript) is above the max-allowed model, or below every rung model, or
  blocked for every effort by forbidden-models; the same model as max-allowed passes with a
  visible note "fork effort not checkable" (the inherited effort cannot be read).
- Exceptions add pairs that count like rungs (so they may allow a cheaper pair), one per
  line, in this format:
      preset exception: <scope> -> <model>/<effort>[, <model>/<effort> ...]
  scope: all, or one or more roles (explore, build, review, hard) separated by commas.
  A second line form allows continuing past back-to-human on the last real rung:
      preset continue: <scope>
  Both forms are read from the same two places with the same rules:
  a) .credo/RULES.md: such a line anywhere outside code fences (bullet optional, text
     after a further `|` is ignored; a line in inline backticks is an example and is
     ignored). Permanent until removed.
  b) The handoff section "## Rules (temporary)" of .credo/process/handoffs/HANDOFF.md:
     - preset exception: build -> opus/max | source: owner "<quote>" (<YYYY-MM-DD>) | until: <YYYY-MM-DD>
     valid only with an owner source with date and an until that starts with a date that
     is today or later (credo-handoff-rules.py check_rule finds no problem). Agent-decision
     rules and undated or expired untils never grant an exception.
  The .credo files are read from the main checkout (git common dir) of the hook's cwd,
  then from the cwd's own top level.
- The preset helpers run with CREDO_SESSION_ID = the hook's session_id and the hook's cwd,
  so a session pin or a hub resolves the same preset as the main agent.
- Internal errors fail open: a warning goes to stderr and to the log file
  (CREDO_PRESET_GUARD_LOG, default <CLAUDE_CONFIG_DIR or ~/.claude>/credo/logs/preset-guard.log).
  All subprocesses share a time budget of 8 s (below the 10 s hook timeout); running out
  counts as an internal error. If the harness aborts the hook at its timeout, the call
  proceeds too (a timed-out hook is non-blocking): abort = allow.

Test hooks: CREDO_PRESET_GUARD_TODAY=YYYY-MM-DD fixes today's date; CREDO_PRESET_GUARD_BUDGET=<s> shortens the time budget.
"""
import datetime
import importlib.util
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PRESET_SH = os.path.join(HERE, "credo-preset.sh")
CONFIG_SH = os.path.join(HERE, "credo-config.sh")
HANDOFF_RULES_PY = os.path.join(HERE, "credo-handoff-rules.py")
ROLES = ("explore", "build", "review", "hard")
# read-only subagent types that default to the explore role (exact names or plugin suffixes)
EXPLORE_TYPES = ("Explore", "Plan", "web-fetch", "claude-code-guide")
EXPLORE_SUFFIXES = (":cavecrew-investigator", "cavecrew-investigator")
BUILD_ROLES = ("build", "review", "hard")
EFFORTS = ("low", "medium", "high", "xhigh", "max")  # ascending cost
MODEL_RANK = {"haiku": 1, "sonnet": 2, "opus": 3, "fable": 4}  # ascending cost
DEFAULT_MAX = ("opus", "medium")  # when the preset dump has no max (built-in default)
ORDER = ("Cost order of a pair: model first (haiku < sonnet < opus < fable), then effort (low "
         "< medium < high < xhigh < max)")
LOOKUP = "bash %s stage <role> <attempt>" % PRESET_SH
# [credo-role: <role>] or [credo-role: <role>#<attempt>]; group 2 is the raw attempt (validated later)
ROLE_TAG_RE = re.compile(r"\[credo-role:\s*(explore|build|review|hard)\s*(?:#\s*([^\]\s]*)\s*)?\]", re.I)
ROLE_TAG_HINT = ("Declare role and attempt with [credo-role: <role>#<attempt>] (roles explore, build, "
                 "review, hard) in the description or prompt; the attempt is 1 for the first try of "
                 "that role on the item and grows by one per failed try")
GROWS = "The attempt is 1 for the first try of a role on the item and grows by one per failed try."
# a real exception line starts (after an optional bullet) with the bare words; a line in
# inline backticks is a documentation example and is ignored
EXC_RE = re.compile(r"^\s*(?:[-*+]\s+)?preset\s+(exception|continue)\s*:\s*(.+?)\s*$", re.I)
RULE_FORMS = ("preset exception: <all|role,...> -> <model>/<effort> (allows that pair) or "
              "preset continue: <all|role,...> (allows continuing past back-to-human on the last "
              "rung), as a line in .credo/RULES.md or as an owner rule with an until date in the "
              "handoff \"## Rules (temporary)\"")
PAIR_RE = re.compile(r"^([A-Za-z0-9._-]+)\s*/\s*([a-z]+)$")
# total time budget, below the 10 s hook timeout in hooks.json; a hook the harness aborts is
# non-blocking, so an abort also means allow
BUDGET_S = float(os.environ.get("CREDO_PRESET_GUARD_BUDGET") or 8.0)  # tests may shorten it
CTX = {"deadline": 0.0, "session": "", "cwd": ""}


class GuardError(Exception):
    pass


def alias_of(model):
    """Model id or alias -> haiku/sonnet/opus/fable; unknown -> the normalised id.
    Strips a context suffix ([1m]), Bedrock/Vertex prefixes (us.anthropic.) and version
    suffixes (-v1:0, @20250101)."""
    m = (model or "").strip().lower()
    m = re.sub(r"\[[^\]]*\]$", "", m)
    m = m.rsplit(".", 1)[-1] if "anthropic." in m else m
    m = re.sub(r"(-v\d+(:\d+)?|@[\w-]+)$", "", m)
    if m in MODEL_RANK:
        return m
    if m.startswith("claude-"):
        for part in m.split("-")[1:]:
            if part in MODEL_RANK:
                return part
    return m


def remaining():
    left = CTX["deadline"] - time.monotonic()
    if left <= 0.2:
        raise GuardError("time budget of %.0f s used up" % BUDGET_S)
    return left - 0.1


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
    """Run a credo helper with the session id and cwd of the hook input, so a session pin
    or a hub resolves the same preset as the main agent."""
    env = dict(os.environ, CREDO_SKIP_ENSURE="1")
    if CTX["session"]:
        env["CREDO_SESSION_ID"] = CTX["session"]
    cwd = CTX["cwd"] if CTX["cwd"] and os.path.isdir(CTX["cwd"]) else None
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=remaining(), env=env, cwd=cwd)
    if res.returncode != 0:
        raise GuardError("%s exited %d" % (os.path.basename(cmd[1]), res.returncode))
    return res.stdout


def preset_configured():
    if not os.path.isfile(CONFIG_SH):
        raise GuardError("credo-config.sh missing")
    return run(["bash", CONFIG_SH, "get", "preset"]).strip() != ""


def valid(pair):
    return pair[0] in MODEL_RANK and pair[1] in EFFORTS


def cost(pair):
    """Cost order of a pair: model first, then effort."""
    return (MODEL_RANK[pair[0]], EFFORTS.index(pair[1]))


def as_pair(raw):
    if not isinstance(raw, list) or len(raw) != 2:
        raise GuardError("bad pair %r in the preset dump" % (raw,))
    pair = (alias_of(str(raw[0])), str(raw[1]))
    if not valid(pair):
        raise GuardError("unknown pair %s/%s in the preset dump" % pair)
    return pair


def read_ladder():
    """The active preset from credo-preset.sh json:
    {'name', 'roles': {role: [{'pairs': set, 'label': str, 'attempts': str}, ...]},
     'back': {role: bool}, 'max': pair, 'min': pair or None,
     'forbidden': [{'pairs': set, 'roles': tuple, 'action': str, 'label': str}]}"""
    if not os.path.isfile(PRESET_SH):
        raise GuardError("credo-preset.sh missing")
    try:
        data = json.loads(run(["bash", PRESET_SH, "json"]))
        roles, back = {}, {}
        for role in ROLES:
            spec = data["roles"][role]
            roles[role] = [{"pairs": {as_pair(p) for p in rung["pairs"]}, "label": str(rung["label"]),
                            "attempts": str(rung["attempts"])} for rung in spec["rungs"]]
            back[role] = bool(spec.get("terminal"))
        forbidden = [{"pairs": {as_pair(p) for p in f["pairs"]}, "roles": tuple(f["roles"]),
                      "action": "warn" if f.get("action") == "warn" else "block",
                      "label": str(f.get("label") or "")} for f in data.get("forbidden") or []]
        ladder = {"name": str(data["name"]), "roles": roles, "back": back, "forbidden": forbidden,
                  "max": as_pair(data["max"]) if data.get("max") else DEFAULT_MAX,
                  "min": as_pair(data["min"]) if data.get("min") else None}
    except (ValueError, KeyError, TypeError, AttributeError) as exc:
        raise GuardError("cannot parse the preset (credo-preset.sh json): %s" % exc)
    if not ladder["name"] or not any(ladder["roles"].values()):
        raise GuardError("cannot parse the preset (credo-preset.sh json)")
    return ladder


def within(pair, ladder):
    return cost(pair) <= cost(ladder["max"]) and not (ladder["min"] and cost(pair) < cost(ladder["min"]))


def forbidden_hits(pair, ladder, roles):
    return [f for f in ladder["forbidden"] if pair in f["pairs"] and set(f["roles"]) & set(roles)]


def limits_text(ladder, roles):
    parts = []
    if ladder["min"]:
        parts.append("min-allowed %s/%s" % ladder["min"])
    parts.append("max-allowed %s/%s" % ladder["max"])
    forb = ["%s (%s)" % (f["label"], f["action"]) for f in ladder["forbidden"]
            if set(f["roles"]) & set(roles)]
    if forb:
        parts.append("forbidden-models %s" % ", ".join(forb))
    return ", ".join(parts)


def ladder_text(ladder, roles):
    parts = []
    for role in roles:
        segs, start, open_chain = [], 1, True
        for rung in ladder["roles"][role]:
            if not open_chain:
                break
            if rung["attempts"] == "until-done":
                segs.append("%d+ %s" % (start, rung["label"]))
                open_chain = False
            else:
                n = int(rung["attempts"])
                rng = str(start) if n == 1 else "%d-%d" % (start, start + n - 1)
                segs.append("%s %s" % (rng, rung["label"]))
                start += n
        if ladder["back"][role] and open_chain:
            segs.append("attempt %d back-to-human" % start)
        if segs:
            parts.append("%s: %s" % (role, ", ".join(segs)))
    return "; ".join(parts)


def parse_scope(raw):
    """'all' or 'role, role' -> set of roles, or None for an unknown word or an empty scope."""
    scope = set()
    for s in re.split(r"[,\s]+", raw.strip().lower()):
        if not s:
            continue
        if s == "all":
            scope.update(ROLES)
        elif s in ROLES:
            scope.add(s)
        else:
            return None
    return scope or None


def parse_rule(kind, text):
    """One rule body -> (scope, pairs) or None.
    exception: '<scope> -> pairs [| ...]' -> (roles, {(alias, effort), ...});
    continue:  '<scope> [| ...]'          -> (roles, empty set)."""
    body = text.split("|", 1)[0].replace("`", "").strip()
    if kind == "continue":
        scope = parse_scope(body)
        return (scope, set()) if scope else None
    if "->" not in body:
        return None
    scope_raw, pairs_raw = body.split("->", 1)
    scope = parse_scope(scope_raw)
    if not scope:
        return None
    pairs = set()
    for p in re.split(r"[,\s]+", pairs_raw.strip()):
        if not p:
            continue
        m = PAIR_RE.match(p)
        if not m or m.group(2).lower() not in EFFORTS:
            return None
        pairs.add((alias_of(m.group(1)), m.group(2).lower()))
    if not pairs:
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


def rules_md_rules(path):
    """[(kind, scope, pairs, source), ...] of the preset exception/continue lines."""
    out = []
    if not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8") as fh:
        for line in unfenced(fh.read().splitlines()):
            m = EXC_RE.match(line)
            if m:
                rule = parse_rule(m.group(1).lower(), m.group(2))
                if rule:
                    out.append((m.group(1).lower(),) + rule + ("RULES.md",))
    return out


def load_handoff_rules():
    spec = importlib.util.spec_from_file_location("credo_handoff_rules", HANDOFF_RULES_PY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def handoff_rules(path, today):
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
            rule = parse_rule(m.group(1).lower(), m.group(2))
            if rule:
                out.append((m.group(1).lower(),) + rule + ("handoff until %s" % until.group(1),))
    return out


def credo_roots(cwd):
    roots = []
    if not cwd or not os.path.isdir(cwd):
        return roots
    for args in (["rev-parse", "--path-format=absolute", "--git-common-dir"],
                 ["rev-parse", "--show-toplevel"]):
        try:
            res = subprocess.run(["git", "-C", cwd] + args, capture_output=True, text=True,
                                 timeout=min(3.0, remaining()))
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


def rules_for(cwd, today):
    """All valid preset exception/continue rules: [(kind, scope, pairs, source), ...]."""
    out = []
    for root in credo_roots(cwd):
        credo = os.path.join(root, ".credo")
        if not os.path.isdir(credo):
            continue
        out += rules_md_rules(os.path.join(credo, "RULES.md"))
        out += handoff_rules(os.path.join(credo, "process", "handoffs", "HANDOFF.md"), today)
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
    return ", ".join("%s/%s" % p for p in sorted(pairs, key=cost))


def cheapest(pairs, ladder, roles):
    """The cheapest pair that no forbidden-models entry matches, else the cheapest pair."""
    ordered = sorted(pairs, key=cost)
    for pair in ordered:
        if not forbidden_hits(pair, ladder, roles):
            return pair
    return ordered[0] if ordered else None


def spawn_kind(sub, ti):
    """What the spawn is checked against:
    {'roles': roles for exceptions and the untagged case, 'role': one role or None,
     'attempt': int or None, 'raw': raw attempt text or None, 'label': text}.
    An explicit [credo-role: <role>[#<attempt>]] tag in the description or the prompt wins;
    else read-only types count as explore attempt 1, everything else as build/review/hard
    (any rung, the role is unknown)."""
    for key in ("description", "prompt"):
        m = ROLE_TAG_RE.search(str(ti.get(key) or ""))
        if m:
            role, raw = m.group(1).lower(), m.group(2)
            attempt = int(raw) if raw is not None and raw.isdigit() and int(raw) > 0 else None
            label = "%s role (tagged)" % role if raw is None else \
                "%s role, attempt %s (tagged)" % (role, raw)
            return {"roles": (role,), "role": role, "attempt": attempt, "raw": raw, "label": label}
    if sub in EXPLORE_TYPES or sub.endswith(EXPLORE_SUFFIXES):
        return {"roles": ("explore",), "role": "explore", "attempt": 1, "raw": "1",
                "label": "explore role, attempt 1 (%s, untagged)" % sub}
    return {"roles": BUILD_ROLES, "role": None, "attempt": None, "raw": None,
            "label": "build/review/hard roles (untagged)"}


def rung_at(ladder, role, n):
    """The rung that serves attempt n of role, or None when attempt n is past the last rung
    (back-to-human: the chain is used up). Mirrors credo-preset.sh stage."""
    cum = 0
    for rung in ladder["roles"][role]:
        if rung["attempts"] == "until-done" or n <= cum + int(rung["attempts"]):
            return rung
        cum += int(rung["attempts"])
    return None


def tag_of(role, attempt):
    return "[credo-role: %s#%s]" % (role, attempt)


def check_fork(data, ladder, ctx):
    """Owner decision Q429 B: the fork's inherited effort cannot be read."""
    pname, what, label, tail, btoh = ctx["pname"], ctx["what"], ctx["label"], ctx["tail"], ctx["btoh"]
    parent = alias_of(parent_model(data))
    mx = "%s/%s" % ladder["max"]
    issue, note = "", ""
    if parent not in MODEL_RANK:
        issue = "which cannot be read, so it cannot be checked"
    elif MODEL_RANK[parent] > MODEL_RANK[ladder["max"][0]]:
        issue = "which is above the max-allowed %s" % mx
    elif not any(MODEL_RANK[parent] >= MODEL_RANK[a] for c in ctx["candidates"] for a, _e in c["pairs"]):
        issue = "which is below every rung model of the %s" % label
    else:
        efforts = set(EFFORTS)
        for f in ladder["forbidden"]:
            if set(f["roles"]) & set(ctx["roles"]) and efforts <= {e for a, e in f["pairs"] if a == parent}:
                if f["action"] == "block":
                    issue = "which forbidden-models blocks at every effort (%s)" % f["label"]
                    break
                note = ("[credo-preset] forbidden model (warn): the fork inherits %s, which "
                        "forbidden-models lists (%s, action warn) - report it." % (parent, f["label"]))
    if issue:
        emit("deny", "[credo-preset] Spawn denied (preset %s): %s; a fork inherits the parent's "
             "model (%s), %s. Spawn a regular subagent (e.g. general-purpose) with model and "
             "effort instead. %s" % (pname, what, parent or "unknown", issue, tail))
        return
    visible = bool(btoh or note)
    if MODEL_RANK[parent] == MODEL_RANK[ladder["max"][0]]:
        line = ("[credo-preset] fork ok, fork effort not checkable: the parent model %s is the "
                "max-allowed model (max-allowed %s, preset %s); the inherited effort cannot be "
                "read - keep the parent's effort within %s." % (parent, mx, pname, mx))
        visible = True
    else:
        line = ("[credo-preset] fork ok: parent model %s is >= a rung model of the %s and below "
                "the max-allowed %s (preset %s); the inherited effort is not checked."
                % (parent, label, mx, pname))
    emit("allow", " ".join(x for x in (btoh, note, line) if x), visible=visible)


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
    kind = spawn_kind(sub, ti)
    role, attempt, label = kind["role"], kind["attempt"], kind["label"]
    scope_roles = kind["roles"]
    pname = ladder["name"]
    mx = "%s/%s" % ladder["max"]
    btoh = ""  # back-to-human warning, prepended to the allow line (visible)
    if role and not ladder["roles"][role]:
        raise GuardError("role %s has no rungs in preset %s" % (role, pname))

    if role:
        role_line = ladder_text(ladder, (role,))
        first = cheapest(ladder["roles"][role][0]["pairs"], ladder, (role,))
        example = ("first try of %s: pass model: %s, effort: %s, tag %s"
                   % (role, first[0], first[1], tag_of(role, 1)))
        if kind["raw"] is not None and attempt is None:
            emit("deny", "[credo-preset] Spawn denied (preset %s): the attempt '%s' in the role tag "
                 "is not a positive whole number. Ladder %s. %s Example: %s."
                 % (pname, kind["raw"], role_line, GROWS, example))
            return
        if attempt is None and len(ladder["roles"][role]) > 1:
            emit("deny", "[credo-preset] Spawn denied (preset %s): role %s has more than one rung, "
                 "so the role tag needs the attempt: [credo-role: %s#<attempt>]. Attempt -> rung: "
                 "%s. %s Example: %s." % (pname, role, role, role_line, GROWS, example))
            return
    rules = rules_for(data.get("cwd") or os.getcwd(), today)
    granted = {}
    for rkind, scope, pairs, source in rules:
        if rkind == "exception" and scope & set(scope_roles):
            for p in pairs:
                # the spawn limits are hard: an exception pair outside them, or a blocked one,
                # grants nothing
                if valid(p) and within(p, ladder) and not any(
                        f["action"] == "block" for f in forbidden_hits(p, ladder, scope_roles)):
                    granted.setdefault(p, source)
    if role:
        rung = rung_at(ladder, role, attempt or 1)
        if rung is None:
            # back-to-human: the owner decides; only an owner rule lets the spawn continue
            cont = [src for rkind, scope, _p, src in rules if rkind == "continue" and role in scope]
            if not cont and not granted:
                emit("deny", "[credo-preset] Spawn denied (preset %s): role %s, attempt %d is "
                     "back-to-human - the ladder of this role is used up and the owner decides "
                     "now. Do not spawn again; hand the item back to the owner with what failed "
                     "and what was tried. Only the owner can allow continuing, with %s. Ladder %s."
                     % (pname, role, attempt, RULE_FORMS, role_line))
                return
            if cont:
                rung = ladder["roles"][role][-1]
            sources = cont or sorted(set(granted.values()))
            btoh = ("[credo-preset] attempt %d is back-to-human in preset %s, continuing per "
                    "owner rule %s - report it to the owner." % (attempt, pname, ", ".join(sources)))
        rungs = [rung] if rung else []
    else:
        rungs = [r for rl in scope_roles for r in ladder["roles"][rl]]
    expected = rung if role else None
    candidates = rungs + [{"pairs": {p}, "label": "%s/%s" % p, "source": src}
                          for p, src in granted.items()]
    every = set()
    for c in candidates:
        every |= c["pairs"]
    low = cheapest(every, ladder, scope_roles)
    cheap = ("the cheapest allowed pair here is %s/%s" % low) if low else "no pair is allowed here"
    ladder_line = ladder_text(ladder, ROLES)
    if role and not expected:  # back-to-human, only exception pairs allow continuing
        fix = ("Fix: pass one of the exception pairs %s and keep the tag %s."
               % (fmt_pairs(granted), tag_of(role, attempt)))
        what = "Role %s, attempt %d is back-to-human; only the exception pairs allow continuing" % (
            role, attempt)
    elif expected:
        shown_tag = tag_of(role, attempt) if attempt is not None else "[credo-role: %s]" % role
        pick = cheapest(expected["pairs"], ladder, (role,))
        fix = ("Fix: pass model: %s, effort: %s, tag %s (allowed for this rung: %s; a pair above "
               "every pair of the rung passes too, up to the max-allowed %s, and is reported)%s."
               % (pick[0], pick[1], shown_tag, expected["label"], mx,
                  "; or an exception pair: %s" % fmt_pairs(granted) if granted else ""))
        what = "Role %s, attempt %s expects %s%s" % (
            role, attempt if attempt is not None else "not given (single rung)", expected["label"],
            " (attempt is back-to-human, continuing on the last rung)" if btoh else "")
    else:
        fix = ("Fix: tag the spawn with [credo-role: <role>#<attempt>] and pass a pair of that "
               "rung (%s)." % ladder_text(ladder, BUILD_ROLES))
        what = "Untagged %s spawn, role unknown" % (sub or "default")
    tail = ("%s Allowed for the %s: %s. Spawn limits of preset %s: %s (hard: no preset exception "
            "or continue rule lifts them). %s. Look up a rung: %s. Active ladder: %s. %s A cheaper "
            "pair (still within the spawn limits) only via a valid owner rule with an until date "
            "in the handoff \"## Rules (temporary)\" or a line in .credo/RULES.md (format: preset "
            "exception: <all|role,...> -> <model>/<effort>). %s."
            % (fix, label, " or ".join(dict.fromkeys(c["label"] for c in candidates)) or "none", pname,
               limits_text(ladder, scope_roles), ORDER, LOOKUP, ladder_line, GROWS, ROLE_TAG_HINT))

    if sub == "fork":
        check_fork(data, ladder, {"pname": pname, "what": what, "label": label, "tail": tail,
                                  "btoh": btoh, "candidates": candidates, "roles": scope_roles})
        return

    model = str(ti.get("model") or "").strip()
    effort = str(ti.get("effort") or "").strip().lower()
    reasons = []
    if not model:
        reasons.append("no model given - the agent definition's or the parent's model cannot "
                       "be checked; pass model and effort explicitly")
    elif alias_of(model) not in MODEL_RANK:
        reasons.append("unknown model %s" % model)
    if not effort:
        reasons.append("no effort")
    elif effort not in EFFORTS:
        reasons.append("unknown effort %s" % effort)
    pair = (alias_of(model), effort)
    hits = [] if reasons else forbidden_hits(pair, ladder, scope_roles)
    exact, stronger = [], []
    if reasons:
        pass
    elif cost(pair) > cost(ladder["max"]):
        reasons.append("chosen %s/%s is above the max-allowed %s of preset %s - a hard limit, no "
                       "preset exception or continue rule lifts it; %s" % (pair + (mx, pname, cheap)))
    elif ladder["min"] and cost(pair) < cost(ladder["min"]):
        reasons.append("chosen %s/%s is below the min-allowed %s/%s of preset %s - a hard limit, "
                       "no preset exception lifts it; %s" % (pair + ladder["min"] + (pname, cheap)))
    elif any(f["action"] == "block" for f in hits):
        reasons.append("chosen %s/%s is forbidden in preset %s (forbidden-models %s, action block) "
                       "- a hard limit, no preset exception lifts it; %s"
                       % (pair + (pname, ", ".join(f["label"] for f in hits if f["action"] == "block"),
                                  cheap)))
    else:
        exact = [c for c in candidates if pair in c["pairs"]]
        stronger = [c for c in candidates if c["pairs"] and cost(pair) > max(cost(p) for p in c["pairs"])]
        if not exact and not stronger:
            if expected and cost(pair) < min(cost(p) for p in expected["pairs"]):
                reasons.append("chosen %s/%s is cheaper than the expected rung %s (%s)"
                               % (pair + (expected["label"], cheap)))
            elif expected:
                reasons.append("chosen %s/%s is not one of the pairs of the expected rung %s - "
                               "nothing in between is allowed (%s)" % (pair + (expected["label"], cheap)))
            else:
                reasons.append("%s/%s is not allowed by any rung of the %s (%s)"
                               % (pair + (label, cheap)))
    if reasons:
        emit("deny", "[credo-preset] Spawn denied (preset %s): %s; %s. %s"
             % (pname, what, "; ".join(reasons), tail))
        return
    visible = False
    rung_hit = [c for c in exact if "source" not in c]
    exc_hit = [c for c in exact if "source" in c]
    if rung_hit and expected:
        line = ("[credo-preset] ok: role %s, attempt %s, expected rung %s, chosen %s/%s "
                "(preset %s)." % (role, attempt if attempt is not None else "not given (single rung)",
                                  expected["label"], pair[0], pair[1], pname))
    elif rung_hit:
        line = ("[credo-preset] ok: %s/%s is allowed by a rung of the %s (preset %s); the role is "
                "unknown, so tag [credo-role: <role>#<attempt>] to have the exact rung checked."
                % (pair[0], pair[1], label, pname))
    elif exc_hit:
        line = ("[credo-preset] ok by preset exception (%s): %s/%s for the %s (preset %s)%s."
                % (exc_hit[0]["source"], pair[0], pair[1], label, pname,
                   ", expected rung without it: %s" % expected["label"] if expected else ""))
    else:
        line = ("[credo-preset] stronger than preset: %s/%s vs %s (%s, preset %s; within the "
                "max-allowed %s) - report it." % (pair[0], pair[1], " or ".join(dict.fromkeys(
                    c["label"] for c in stronger)), label, pname, mx))
        visible = True
    warn_hits = [f for f in hits if f["action"] == "warn"]
    if warn_hits:
        line = ("[credo-preset] forbidden model (warn): %s/%s matches forbidden-models %s of preset "
                "%s - allowed because the action is warn; report it. %s"
                % (pair + (", ".join(f["label"] for f in warn_hits), pname, line)))
        visible = True
    if btoh:
        line, visible = btoh + " " + line, True
    emit("allow", line, visible=visible)


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
            CTX["deadline"] = time.monotonic() + BUDGET_S
            CTX["session"] = str(data.get("session_id") or "")
            CTX["cwd"] = str(data.get("cwd") or "")
            decide(data, today)
    except Exception as exc:  # fail open on any internal error
        log_warning("%s: %s - spawn allowed unchecked" % (type(exc).__name__, exc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
