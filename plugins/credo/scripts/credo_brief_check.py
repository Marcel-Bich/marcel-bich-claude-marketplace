#!/usr/bin/env python3
"""credo_brief_check.py - warn when a build/review brief asks the subagent for the full check.

Entry point of hooks/credo-agent-spawn-check.sh (PreToolUse on Agent and Task), hook input
on stdin. It runs the preset guard (credo-preset-guard.py) in the same process, then adds
the brief check to the guard's decision, so the hook stays one Python process.

Rule (credo orchestration, "Full check only in the main agent"): a builder or reviewer
never runs the project's full suite; it runs the tests of its touched modules plus the
project's fast check and reports. The main agent runs one full check per merged batch.

The brief check:
- applies to spawns of the build, review and hard roles: a [credo-role: <role>#<n>] tag in
  the description or prompt, else the subagent_type rules of the preset guard (read-only
  types such as Explore and Plan count as explore and are skipped; any other untagged type
  counts as a builder);
- looks in the description and prompt for the project's `all` stage command (dogma
  DOGMA-PERMISSIONS.md "Test Commands", read-only, same line format as dogma's
  scripts/test-commands.sh; skipped when it equals the `relevant` command or when the
  command is followed by a path or flag that narrows the run), for commands in backticks on
  .credo/RULES.md lines about the full check, and for the markers `--full`, "full suite",
  "full check", "full test suite", "all tests";
- ignores a match whose clause (text since the last sentence dot, ; ! ? or line break) negates it
  ("never", "not", "no", "don't", "without", "instead of", "avoid", "skip", "except",
  "main agent"), or whose whole clause names the main agent (or says "main-only"), so a
  brief that forbids the full check or leaves it to the main agent stays silent; "all tests
  of/in <module>" is a narrowed run and no marker; a marker inside quotes ("...", '...' or
  backticks) names a feature or quotes a message and is no marker either (the project's own
  commands still count inside backticks); a report of a past run ("the full check was
  green", "full suite passed", "ran the full check") is no order and no marker;
- on a match prints a warning (additionalContext + systemMessage) naming the rule and the
  fix. It never denies. A guard deny keeps its decision; the warning is appended.

Everything fails open: a brief-check error leaves the guard output untouched, a guard load
error leaves the brief check alone. Kill switch for the brief check only:
CREDO_BRIEF_CHECK=0 (CREDO_AGENT_SPAWN_CHECK=0 in the wrapper switches off both).
"""
import contextlib
import importlib.util
import io
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD_PY = os.path.join(HERE, "credo-preset-guard.py")
CHECK_ROLES = ("build", "review", "hard")
# local fallback when the guard module cannot be loaded (mirrors its spawn_kind)
TAG_RE = re.compile(r"\[credo-role:\s*(explore|build|review|hard)\s*(?:#[^\]]*)?\]", re.I)
EXPLORE_TYPES = ("Explore", "Plan", "web-fetch", "claude-code-guide")
MARKERS = (
    (re.compile(r"(?<![\w-])--full(?![\w-])"), "--full"),
    (re.compile(r"\bfull\s+(?:test\s+)?suite\b", re.I), "full suite"),
    (re.compile(r"\bfull\s+check\b", re.I), "full check"),
    # "all tests of/in <module>" names a narrowed run, not the full suite
    (re.compile(r"\ball\s+(?:the\s+)?tests\b(?!\s+(?:of|in|for|under|touching|that|which)\b)",
                re.I), "all tests"),
)
NEGATION_RE = re.compile(
    r"\b(?:never|not|no|nor|don'?t|doesn'?t|without|instead\s+of|avoid|skip|except|"
    r"main\s+agent)\b|n't\b", re.I)
MAIN_AGENT_RE = re.compile(r"\bmain\s+agent\b|\bmain[\s-]only\b", re.I)
# quoted text names a feature or quotes a message ("...", '...', `...`), it asks for nothing;
# a single quote counts only when it is no apostrophe inside a word (don't, it's)
# a report of a past run is no order: "the full check was green", "ran the full suite"
REPORT_AFTER_RE = re.compile(
    r"\s*(?:was|were|had|passed|failed|succeeded|went|stayed|came\s+back|"
    r"(?:has|have)\s+(?:been|passed|failed|run|succeeded)|is\s+(?:green|red|done))\b", re.I)
REPORT_BEFORE_RE = re.compile(r"\b(?:ran|(?:has|have|had|was|were)\s+run)\b", re.I)
QUOTED_RE = re.compile(r"\"[^\"\n]*\"|“[^”\n]*”|(?<!\w)'[^'\n]*'(?!\w)|`[^`\n]*`")
CLAUSE_END_RE = re.compile(r"[;!?\n]|\.(?=\s|$)")  # a dot inside ./path or a.b is no clause end
TEST_HEAD_ID = re.compile(r"^#{2,}\s+.*\(§ly5v\)")
TEST_HEAD_TEXT = re.compile(r"^###\s+test\s+commands\s*(?:\(§[0-9a-z]{4}\)\s*)?$", re.I)
STAGE_RE = re.compile(r"^-\s*([A-Za-z]+)\s*(?:\[[^\]]*\])?\s*:\s*(.*)$")
FULL_RULE_RE = re.compile(r"full\s+(?:test\s+)?(?:check|suite)|all\s+tests", re.I)
MAX_READ = 256 * 1024


def load_guard():
    spec = importlib.util.spec_from_file_location("credo_preset_guard", GUARD_PY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run_guard(guard, raw):
    """Run the guard's main() on raw with stdin/stdout swapped; returns its stdout."""
    buf = io.StringIO()
    old_stdin = sys.stdin
    try:
        sys.stdin = io.StringIO(raw)
        with contextlib.redirect_stdout(buf):
            guard.main()
    finally:
        sys.stdin = old_stdin
    return buf.getvalue().strip()


def spawn_roles(guard, sub, ti):
    if guard is not None:
        try:
            return tuple(guard.spawn_kind(sub, ti)["roles"])
        except Exception:  # fall back to the local parser
            pass
    for key in ("description", "prompt"):
        m = TAG_RE.search(str(ti.get(key) or ""))
        if m:
            return (m.group(1).lower(),)
    if sub in EXPLORE_TYPES or sub.endswith("cavecrew-investigator"):
        return ("explore",)
    return CHECK_ROLES


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read(MAX_READ)
    except OSError:
        return ""


def repo_roots(cwd):
    """[main checkout, worktree top level, cwd ancestors] without spawning git."""
    if not cwd or not os.path.isdir(cwd):
        return []
    walk, top, d = [], "", os.path.abspath(cwd)
    while True:
        walk.append(d)
        if os.path.exists(os.path.join(d, ".git")):
            top = d
            break
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    roots = []
    git = os.path.join(top, ".git") if top else ""
    if git and os.path.isfile(git):  # linked worktree: .git file -> gitdir -> commondir
        m = re.match(r"gitdir:\s*(.+)", read_text(git).strip())
        if m:
            gitdir = os.path.join(top, m.group(1).strip())
            common = read_text(os.path.join(gitdir, "commondir")).strip()
            if common:
                common = os.path.normpath(os.path.join(gitdir, common))
                if os.path.basename(common) == ".git":
                    roots.append(os.path.dirname(common))
    for p in walk:
        if p not in roots:
            roots.append(p)
    return roots


def test_commands(text):
    """{stage: command} from the DOGMA-PERMISSIONS.md Test Commands section."""
    lines = text.splitlines()
    head = TEST_HEAD_ID if any(TEST_HEAD_ID.match(l.strip()) for l in lines) else TEST_HEAD_TEXT
    stages, inside = {}, False
    for line in lines:
        s = line.strip()
        if head.match(s):
            inside = True
            continue
        if not inside:
            continue
        if s.startswith("##") or s.startswith("</permissions>"):
            inside = False
            continue
        m = STAGE_RE.match(s)
        code = re.search(r"`([^`]+)`", m.group(2)) if m else None
        if m and code and code.group(1).strip():
            stages.setdefault(m.group(1).lower(), code.group(1).strip())
    return stages


def project_facts(cwd):
    """(all command, relevant command, [(rules line, [commands])]) - empty when unknown."""
    all_cmd = relevant = ""
    rules = []
    roots = repo_roots(cwd)
    for root in roots:
        perms = os.path.join(root, "DOGMA-PERMISSIONS.md")
        if os.path.isfile(perms):
            st = test_commands(read_text(perms))
            all_cmd, relevant = st.get("all", ""), st.get("relevant", "")
            break
    for root in roots:
        path = os.path.join(root, ".credo", "RULES.md")
        if not os.path.isfile(path):
            continue
        for line in read_text(path).splitlines():
            if FULL_RULE_RE.search(line) and not line.lstrip().startswith("#"):
                cmds = [c.strip() for c in re.findall(r"`([^`]+)`", line) if " " in c.strip()]
                rules.append((line.strip().lstrip("-*+ ").strip()[:240], cmds))
        break
    return all_cmd, relevant, rules


def negated(text, start):
    """True when the clause before start negates the match, or the clause names the main
    agent anywhere (the main agent's own full check is the rule, not a breach)."""
    clause_start = 0
    for m in CLAUSE_END_RE.finditer(text, 0, start):
        clause_start = m.end()
    end = CLAUSE_END_RE.search(text, start)
    clause_end = end.start() if end else len(text)
    return bool(NEGATION_RE.search(text[clause_start:start])
                or MAIN_AGENT_RE.search(text[clause_start:clause_end]))


def reported(text, m):
    """True when the clause reports a past run of the match instead of ordering one."""
    clause_start = 0
    for e in CLAUSE_END_RE.finditer(text, 0, m.start()):
        clause_start = e.end()
    return bool(REPORT_AFTER_RE.match(text, m.end())
                or REPORT_BEFORE_RE.search(text[clause_start:m.start()]))


def narrowed(text, end):
    """True when the command at text[:end] is followed by a flag or path argument."""
    m = re.match(r"[ \t]+(\S+)", text[end:])
    if not m:
        return False
    arg = m.group(1).strip("`'\"),;")
    return arg.startswith("-") or "/" in arg or "." in arg


def find_command(text, cmd):
    pat = re.compile(r"(?<![\w./-])" + r"\s+".join(re.escape(p) for p in cmd.split()) + r"(?![\w-])")
    for m in pat.finditer(text):
        if not negated(text, m.start()) and not narrowed(text, m.end()):
            return m
    return None


def snippet(text, m):
    a, b = max(0, m.start() - 40), min(len(text), m.end() + 40)
    return " ".join(text[a:b].split())


def find_full_check(text, all_cmd, relevant, rules):
    """(what matched, snippet) or None."""
    cmds = []
    if all_cmd and all_cmd != relevant:
        cmds.append(("the project's `all` stage command `%s`" % all_cmd, all_cmd))
    for _, rcmds in rules:
        for c in rcmds:
            if c != relevant:
                cmds.append(("the full-check command `%s` from .credo/RULES.md" % c, c))
    for label, cmd in cmds:
        m = find_command(text, cmd)
        if m:
            return label, snippet(text, m)
    quoted = [q.span() for q in QUOTED_RE.finditer(text)]
    for rx, label in MARKERS:
        for m in rx.finditer(text):
            if any(a < m.start() < b for a, b in quoted) or reported(text, m):
                continue
            if not negated(text, m.start()):
                return "the full-check marker \"%s\"" % label, snippet(text, m)
    return None


def brief_warning(data, guard):
    if data.get("tool_name") not in ("Agent", "Task"):
        return ""
    ti = data.get("tool_input") or {}
    if not isinstance(ti, dict):
        return ""
    roles = [r for r in spawn_roles(guard, str(ti.get("subagent_type") or ""), ti)
             if r in CHECK_ROLES]
    if not roles:
        return ""
    text = "%s\n%s" % (ti.get("description") or "", ti.get("prompt") or "")
    all_cmd, relevant, rules = project_facts(str(data.get("cwd") or ""))
    hit = find_full_check(text, all_cmd, relevant, rules)
    if not hit:
        return ""
    what, snip = hit
    fast = "the dogma `relevant` command `%s`" % relevant if relevant else "the project's fast check"
    rule_line = rules[0][0] if rules else ""
    return ("[credo-brief] warning: this %s brief asks the subagent to run the full check (%s: "
            "\"%s\"). Rule (credo orchestration, \"Full check only in the main agent\"%s): a "
            "builder or reviewer runs only the tests of its touched modules plus %s and reports; "
            "the main agent runs one full check per merged batch - parallel full checks queue "
            "behind each other on a shared lock. Fix: replace that line in the brief with the "
            "touched-module tests plus the fast check, and run the full check yourself once "
            "after merging the batch. Warning only; the spawn proceeds."
            % ("/".join(roles), what, snip,
               "; .credo/RULES.md: \"%s\"" % rule_line if rule_line else "", fast))


def merge(guard_out, warning):
    """The guard's JSON with the warning added (context + systemMessage), or a new one."""
    if not warning:
        return guard_out
    res = None
    if guard_out:
        try:
            res = json.loads(guard_out)
        except ValueError:
            return guard_out
        if not isinstance(res, dict):
            return guard_out
    if res is None:
        res = {"hookSpecificOutput": {"hookEventName": "PreToolUse"}, "suppressOutput": True}
    hso = res.setdefault("hookSpecificOutput", {"hookEventName": "PreToolUse"})
    key = "permissionDecisionReason" if hso.get("permissionDecision") == "deny" else "additionalContext"
    hso[key] = (hso[key] + "\n" + warning) if hso.get(key) else warning
    res["systemMessage"] = (res["systemMessage"] + "\n" + warning) if res.get("systemMessage") else warning
    return json.dumps(res)


def main():
    raw = sys.stdin.read()
    guard = None
    guard_out = ""
    try:
        guard = load_guard()
        guard_out = run_guard(guard, raw)
    except Exception as exc:  # fail open: the brief check still runs
        print("credo-brief-check: warning: preset guard failed: %s: %s" % (type(exc).__name__, exc),
              file=sys.stderr)
    out = guard_out
    if os.environ.get("CREDO_BRIEF_CHECK", "1").lower() not in ("0", "false", "no", "off"):
        try:
            data = json.loads(raw) if raw.strip() else None
            if isinstance(data, dict):
                out = merge(guard_out, brief_warning(data, guard))
        except Exception as exc:  # fail open: keep the guard decision
            print("credo-brief-check: warning: %s: %s - brief unchecked" % (type(exc).__name__, exc),
                  file=sys.stderr)
            out = guard_out
    if out:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
