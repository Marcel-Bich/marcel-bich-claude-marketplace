#!/usr/bin/env python3
"""credo-preset-guard.py - enforce the active model preset on Agent and Task spawns.

Called by hooks/credo-agent-spawn-check.sh (PreToolUse on Agent and Task) with the hook
input on stdin. Prints a hook decision JSON (or nothing) and always exits 0.

Rules:
- No preset configured (no `preset:` key in any config layer) -> no check.
- Deny only BELOW the preset (owner decision Q425). Role and attempt travel in a tag in the
  description or prompt: [credo-role: <role>#<attempt>] (e.g. [credo-role: review#3]).
    tag with attempt              -> exactly the rung that serves this attempt of the role
                                     (same mapping as credo-preset.sh stage <role> <attempt>);
                                     an attempt past the last rung is back-to-human -> deny, the
                                     owner decides now, UNLESS an owner rule allows continuing:
                                     a preset exception for the role (pair >= that pair) or a
                                     preset continue line for the role (pair >= the LAST real
                                     rung); both pass with a visible "continuing per owner rule"
                                     line; a non-numeric or 0 attempt -> deny;
    tag without attempt           -> a role with one rung: that rung (the attempt is
                                     optional); more than one rung -> deny with the
                                     attempt -> rung map and an example tag;
    read-only types (Explore, Plan, web-fetch, claude-code-guide, *:cavecrew-investigator)
    without a tag                 -> explore, attempt 1;
    any other type without a tag  -> ANY rung of the build, review and hard roles (the role
                                     is unknown; the ok line asks for the tag).
  Stronger = model rank haiku < sonnet < opus < fable and effort rank
  low < medium < high < xhigh < max, both >= the rung. An exact rung match gets a short
  "ok" context line naming role, attempt, expected rung and chosen pair; a stronger spawn
  passes with a visible line "stronger than preset: <model>/<effort> vs <rung>"
  (context + systemMessage) for the main agent to report. A deny names role, attempt,
  expected rung, chosen pair and the exact fix (model, effort, tag).
- Missing model is a mismatch (the agent definition's or the parent's model cannot be
  checked); missing effort is a mismatch (every rung defines one); an unknown model or
  effort cannot be ranked and is a mismatch. Model ids are normalised (context suffix like
  [1m], Bedrock/Vertex prefixes like us.anthropic., version suffixes like -v1:0, full ids
  claude-<name>-x-y). A mismatch or a weaker pair is denied with the minimum pairs, the
  lookup command (absolute path of credo-preset.sh) and how to declare the role.
- subagent_type "fork" inherits the parent's model and effort (a model on the call is
  ignored). It passes only when the parent's model (last assistant model in the parent
  transcript) is >= the model of a fitting rung; the inherited effort cannot be read and is
  not checked. Otherwise it is denied with the hint to spawn a regular subagent with model
  and effort.
- Exceptions add pairs that count like rungs (so they may allow a weaker pair), one per
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
EFFORTS = ("low", "medium", "high", "xhigh", "max")  # ascending strength
MODEL_RANK = {"haiku": 1, "sonnet": 2, "opus": 3, "fable": 4}  # ascending strength
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
    return ", ".join("%s/%s" % p for p in sorted(pairs))


def at_least(pair, rung):
    """True when pair (alias, effort) is equal to or stronger than rung in model AND effort."""
    if pair[0] not in MODEL_RANK or rung[0] not in MODEL_RANK:
        return False
    if pair[1] not in EFFORTS or rung[1] not in EFFORTS:
        return False
    return (MODEL_RANK[pair[0]] >= MODEL_RANK[rung[0]]
            and EFFORTS.index(pair[1]) >= EFFORTS.index(rung[1]))


def mixed(pair, rung):
    """True when one dimension of pair beats the rung and the other falls short."""
    dm = MODEL_RANK[pair[0]] - MODEL_RANK.get(rung[0], 0)
    de = EFFORTS.index(pair[1]) - (EFFORTS.index(rung[1]) if rung[1] in EFFORTS else 0)
    return (dm > 0 > de) or (de > 0 > dm)


def spawn_kind(sub, ti):
    """What the spawn is checked against:
    {'roles': roles for exceptions and the untagged minimum, 'role': one role or None,
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
    """(alias, effort) of the rung that serves attempt n of role, or None when attempt n is
    past the last rung (back-to-human: the chain is used up). Mirrors credo-preset.sh stage."""
    cum = 0
    for alias, effort, attempts in ladder["roles"][role]:
        if attempts == "until-done" or n <= cum + int(attempts):
            return (alias, effort)
        cum += int(attempts)
    return None


def tag_of(role, attempt):
    return "[credo-role: %s#%s]" % (role, attempt)


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
    pname = ladder["name"]
    btoh = ""  # back-to-human warning, prepended to the allow line (visible)
    if role and not ladder["roles"][role]:
        raise GuardError("role %s has no rungs in preset %s" % (role, pname))

    if role:
        role_line = ladder_text(ladder, (role,))
        first = ladder["roles"][role][0]
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
        if rkind == "exception" and scope & set(kind["roles"]):
            for p in pairs:
                granted.setdefault(p, source)
    if role:
        expected = rung_at(ladder, role, attempt or 1)
        allowed = {expected} if expected else set()
        if expected is None:
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
                last = ladder["roles"][role][-1]
                expected = (last[0], last[1])
                allowed = {expected}
            sources = cont or sorted(set(granted.values()))
            btoh = ("[credo-preset] attempt %d is back-to-human in preset %s, continuing per "
                    "owner rule %s - report it to the owner." % (attempt, pname, ", ".join(sources)))
    else:
        expected = None
        allowed = set()
        for r in kind["roles"]:
            allowed.update((a, e) for a, e, _n in ladder["roles"][r])
    every = allowed | set(granted)
    ladder_line = ladder_text(ladder, ROLES)
    if role and not expected:  # back-to-human, only exception pairs allow continuing
        fix = ("Fix: pass one of the exception pairs %s and keep the tag %s."
               % (fmt_pairs(granted), tag_of(role, attempt)))
        what = "Role %s, attempt %d is back-to-human; only the exception pairs allow continuing" % (
            role, attempt)
    elif expected:
        shown_tag = tag_of(role, attempt) if attempt is not None else "[credo-role: %s]" % role
        fix = ("Fix: pass model: %s, effort: %s, tag %s (an equal or stronger model and effort "
               "passes)%s." % (expected[0], expected[1], shown_tag,
                               "; or an exception pair: %s" % fmt_pairs(granted) if granted else ""))
        what = "Role %s, attempt %s expects %s/%s%s" % (
            role, attempt if attempt is not None else "not given (single rung)",
            expected[0], expected[1],
            " (attempt is back-to-human, continuing on the last rung)" if btoh else "")
    else:
        fix = ("Fix: tag the spawn with [credo-role: <role>#<attempt>] and pass the model and effort "
               "of that rung (%s)." % ladder_text(ladder, BUILD_ROLES))
        what = "Untagged %s spawn, role unknown" % (sub or "default")
    tail = ("%s Minimum for the %s: one of %s. Look up a rung: %s. Active ladder: %s. %s A weaker "
            "pair only via a valid owner rule with an until date in the handoff \"## Rules "
            "(temporary)\" or a line in .credo/RULES.md (format: preset exception: "
            "<all|role,...> -> <model>/<effort>). %s."
            % (fix, label, fmt_pairs(every) or "none", LOOKUP, ladder_line, GROWS, ROLE_TAG_HINT))

    if sub == "fork":
        parent = alias_of(parent_model(data))
        if parent in MODEL_RANK and any(MODEL_RANK[parent] >= MODEL_RANK.get(a, 99)
                                        for a, _e in every):
            line = ("[credo-preset] fork ok: parent model %s is >= a rung model of the %s "
                    "(preset %s); the inherited effort is not checked." % (parent, label, pname))
            emit("allow", (btoh + " " + line) if btoh else line, visible=bool(btoh))
            return
        emit("deny", "[credo-preset] Spawn denied (preset %s): %s; a fork inherits the parent's "
             "model (%s), which is below every rung model of the %s. Spawn a regular subagent "
             "(e.g. general-purpose) with model and effort instead. %s"
             % (pname, what, parent or "unknown", label, tail))
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
    covered = [] if reasons else sorted(p for p in every if at_least(pair, p))
    if not reasons and not covered:
        if expected:
            reasons.append("chosen %s/%s is weaker than the expected rung %s/%s"
                           % (pair[0], pair[1], expected[0], expected[1]))
        else:
            reasons.append("%s/%s is below every rung of the %s (weaker model or lower effort)"
                           % (pair[0], pair[1], label))
        if any(mixed(pair, p) for p in every):
            reasons.append("model and effort must both reach the rung - a stronger model does "
                           "not make up for a lower effort, nor the other way round")
    if reasons:
        emit("deny", "[credo-preset] Spawn denied (preset %s): %s; %s. %s"
             % (pname, what, "; ".join(reasons), tail))
        return
    visible = False
    if pair in allowed and expected:
        line = ("[credo-preset] ok: role %s, attempt %s, expected rung %s/%s, chosen %s/%s "
                "(preset %s)." % (role, attempt if attempt is not None else "not given (single rung)",
                                  expected[0], expected[1], pair[0], pair[1], pname))
    elif pair in allowed:
        line = ("[credo-preset] ok: %s/%s is a rung of the %s (preset %s); the role is "
                "unknown, so tag [credo-role: <role>#<attempt>] to have the exact rung checked."
                % (pair[0], pair[1], label, pname))
    elif pair in granted:
        line = ("[credo-preset] ok by preset exception (%s): %s/%s for the %s (preset %s)%s."
                % (granted[pair], pair[0], pair[1], label, pname,
                   ", expected rung without it: %s/%s" % expected if expected else ""))
    else:
        line = ("[credo-preset] stronger than preset: %s/%s vs %s (%s, preset %s) - report it."
                % (pair[0], pair[1], " or ".join("%s/%s" % p for p in covered), label, pname))
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
