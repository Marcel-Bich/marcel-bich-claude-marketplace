#!/usr/bin/env python3
"""credo-handoff-rules.py - check the temporary rules a credo handoff carries.

A handoff (.credo/process/handoffs/HANDOFF.md) may hold rules only in one section,
"## Rules (temporary)", one rule per line:

    - <rule> | source: owner "<verbatim quote>" (<YYYY-MM-DD>) | until: <goal, date or event>
    - <rule> | source: agent decision | until: <goal, date or event>

Precedence: the owner's current words > owner rules in the handoff (temporary) >
.credo/RULES.md > agent-decision rules in the handoff (they only fill gaps). On a conflict
with RULES.md a valid owner rule (owner quote with date, until not yet reached) wins while it
lasts; RULES.md wins over agent decisions and invalid handoff rules (missing or invalid source
or until, expired). Every conflict is reported aloud. A rule without `until:` does not apply.

Usage:
    credo-handoff-rules.py check <HANDOFF.md> [RULES.md] [--today YYYY-MM-DD]
        Print one finding per bad rule line (missing source, missing until, open-ended
        until such as "further notice" or "dauerhaft", expired or invalid dates, source
        neither an owner quote with date nor "agent decision"), rule collections outside
        "Rules (temporary)" (its ### subsections belong to it; indented sub-bullets are
        details of the rule above), and the RULES.md headings to compare against. Exit 0 = no finding, 1 = findings, 2 = usage or unreadable file.
    credo-handoff-rules.py rehydrate <HANDOFF.md> [RULES.md] [--today YYYY-MM-DD]
        The post-compact instruction text (precedence + compare + check result) for the
        SessionStart hook. Always exits 0.
    credo-handoff-rules.py text
        Print the precedence and format text (the single wording source).

Read-only: never writes any file.
"""
import datetime
import os
import re
import sys

SECTION = "Rules (temporary)"
FORMAT = ('- <rule> | source: owner "<verbatim quote>" (<YYYY-MM-DD>) | until: <goal, date or event>'
          ' (or: | source: agent decision | until: ...)')
PRECEDENCE = (
    "Precedence: the owner's current words > owner rules in the handoff section "
    "\"## Rules (temporary)\" > .credo/RULES.md > agent-decision rules in the handoff (these only "
    "fill gaps, never beat RULES.md, and are never presented as owner orders). Every handoff "
    "rule needs a source and an until: " + FORMAT + ". A handoff rule without until does NOT "
    "apply: say so aloud to the owner instead of following it. Compare the handoff rules with "
    ".credo/RULES.md; report every conflict aloud (in autonomous runs also via ntfy), keep "
    "working. On a conflict a valid owner rule from the handoff (owner quote with date, until not "
    "yet reached) beats RULES.md while it lasts; RULES.md wins over agent decisions and over "
    "invalid handoff rules (missing or invalid source or until, expired). "
    "An owner rule without an expiry goes to the right place: permanent -> propose the exact "
    "RULES.md entry and write it after the owner's OK; temporary -> ask the owner for the until; "
    "if the owner leaves it open, say aloud that it will not be honoured reliably and will get "
    "lost over time and context.")

HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
# headings of rule collections outside "## Rules (temporary)" (English and German); a heading
# that only mentions rules ("Work on rules skill") is no rule collection
LEGACY_RE = re.compile(
    r"standing\s+(rules|orders|agreements)|owner\s+(orders|rules)"
    r"|(rules|orders|agreements)\s+(still\s+)?in\s+force"
    r"|^(rules|orders|agreements)\s*(\(.*\))?$"
    r"|stehende\s+\w+|\b(regeln|absprachen|vorgaben)\b", re.I)
FIELD_MARK_RE = re.compile(r"\|\s*(source|until)\s*:", re.I)
# greedy: the quote may itself hold straight quotes or pipes, it ends at the trailing (date)
OWNER_SRC_RE = re.compile(r'^owner\s+".*"\s*\(\s*\d{4}-\d{1,2}-\d{1,2}[^)]*\)$', re.I | re.S)
OWNER_DATE_RE = re.compile(r"\(\s*(\d{4}-\d{1,2}-\d{1,2})[^)]*\)$")
DATE_RE = re.compile(r"^(?:by\s+|on\s+)?(\d{4}-\d{1,2}-\d{1,2})\b", re.I)
PLACEHOLDER_RE = re.compile(r"^\(?(none|-|n/?a|tbd|\?|open|unknown)\)?$", re.I)
# open-ended: no real expiry, the rule is permanent and belongs in RULES.md
OPEN_RE = re.compile(
    r"^(until\s+|bis\s+)?(further\s+notice|notice|never|always|forever|indefinitely|"
    r"permanent(ly)?|no\s+end|ongoing|auf\s+weiteres|weiteres|dauerhaft|immer|nie|niemals|"
    r"unbefristet|für\s+immer|ewig)[.!]?$", re.I)
FENCES = ("```", "~~~")


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().splitlines()


def sections(lines):
    """Return [heading level, heading text, line number, [(lineno, line)]] per heading;
    lines inside ``` or ~~~ fences are skipped."""
    out = []
    cur = None
    fence = None
    for i, line in enumerate(lines, 1):
        lead = line.lstrip()
        if fence is None and lead.startswith(FENCES):
            fence = lead[:3]
            continue
        if fence is not None:
            if lead.startswith(fence):
                fence = None
            continue
        m = HEADING_RE.match(line)
        if m:
            cur = [len(m.group(1)), m.group(2), i, []]
            out.append(cur)
        elif cur is not None:
            cur[3].append((i, line))
    return out


def rule_lines(body):
    """Top-level bullet lines of a section. Indented lines, sub-bullets included, are folded
    into the bullet above them: they are details of that rule, not rules of their own."""
    rules = []
    for no, line in body:
        s = line.strip()
        indented = line[:1] in (" ", "\t")
        if not indented and re.match(r"^[-*+]\s+", s):
            rules.append([no, re.sub(r"^[-*+]\s+", "", s)])
        elif s and rules and indented:
            rules[-1][1] += " " + s
    return rules


def fields_of(text):
    """{'source': value, 'until': value} split only at '| source:' and '| until:'."""
    marks = list(FIELD_MARK_RE.finditer(text))
    fields = {}
    for n, m in enumerate(marks):
        end = marks[n + 1].start() if n + 1 < len(marks) else len(text)
        fields.setdefault(m.group(1).lower(), text[m.end():end].strip())
    return fields


def parse_date(value):
    try:
        return datetime.datetime.strptime(value, "%Y-%m-%d").date()
    except ValueError:
        return None


def check_rule(text, today):
    """Return the list of problems of one rule line (empty = fine)."""
    fields = fields_of(text)
    probs = []
    src = fields.get("source")
    if not src:
        probs.append("no source: (owner \"<quote>\" (<date>) or agent decision)")
    elif src.lower() == "agent decision":
        pass
    elif not OWNER_SRC_RE.match(src):
        probs.append("source is neither owner \"<quote>\" (<date>) nor agent decision")
    elif parse_date(OWNER_DATE_RE.search(src).group(1)) is None:
        probs.append("source date %s is not a valid date" % OWNER_DATE_RE.search(src).group(1))
    until = fields.get("until")
    if not until or PLACEHOLDER_RE.match(until):
        probs.append("no until: (goal, date or event) - this rule does NOT apply")
    elif OPEN_RE.match(until):
        probs.append("no real expiry (until %s): belongs in RULES.md (propose the entry) or "
                     "needs a real until" % until)
    else:
        m = DATE_RE.match(until)
        if m:
            d = parse_date(m.group(1))
            if d is None:
                probs.append("until date %s is not a valid date" % m.group(1))
            elif d < today:
                probs.append("expired (until %s) - drop it" % m.group(1))
    return probs


def check(handoff, rules_md, today):
    lines = read(handoff)
    findings = []
    found = False
    rules_level = None  # level of the open "Rules (temporary)" heading, its subsections belong to it
    for level, title, start, body in sections(lines):
        if rules_level is not None and level > rules_level:
            in_rules = True
        else:
            rules_level = None
            in_rules = title.strip().lower() == SECTION.lower()
            if in_rules:
                rules_level = level
                found = True
        if in_rules:
            for no, text in rule_lines(body):
                for p in check_rule(text, today):
                    findings.append("line %d: %s: %s" % (no, p, text[:120]))
        elif LEGACY_RE.search(title.strip()) and rule_lines(body):
            findings.append("line %d: section \"%s\" holds rule-like lines outside \"## %s\" - "
                            "they do not apply; move each into \"## %s\" with source and until, "
                            "or drop it" % (start, title, SECTION, SECTION))
    notes = []
    if not found:
        notes.append("no \"## %s\" section: the handoff carries no temporary rules" % SECTION)
    compare = []
    if rules_md and os.path.isfile(rules_md):
        for level, title, start, body in sections(read(rules_md)):
            if level >= 2:
                compare.append(title)
    return findings, notes, compare


def parse_args(argv):
    """Split off --today YYYY-MM-DD; ValueError when its value is missing or invalid."""
    today = datetime.date.today()
    rest = []
    i = 0
    while i < len(argv):
        if argv[i] == "--today":
            if i + 1 >= len(argv):
                raise ValueError("--today needs a value")
            today = datetime.date.fromisoformat(argv[i + 1])
            i += 2
            continue
        rest.append(argv[i])
        i += 1
    return rest, today


def report(handoff, rules_md, today):
    findings, notes, compare = check(handoff, rules_md, today)
    out = []
    for f in findings:
        out.append("FLAG " + f)
    for n in notes:
        out.append("NOTE " + n)
    if compare:
        out.append("COMPARE against %s: %s" % (rules_md, "; ".join(compare)))
    return findings, out


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if argv else 2
    cmd, args = argv[0], argv[1:]
    if cmd == "text":
        print(PRECEDENCE)
        return 0
    try:
        args, today = parse_args(args)
    except ValueError:
        print("credo-handoff-rules: --today needs YYYY-MM-DD", file=sys.stderr)
        return 2
    if cmd not in ("check", "rehydrate") or not args or len(args) > 2:
        print("usage: credo-handoff-rules.py check|rehydrate <HANDOFF.md> [RULES.md]", file=sys.stderr)
        return 2
    handoff = args[0]
    rules_md = args[1] if len(args) > 1 else ""
    if cmd == "rehydrate":
        msg = "[credo] Handoff rules: " + PRECEDENCE
        try:
            findings, out = report(handoff, rules_md, today)
        except (OSError, UnicodeDecodeError):
            print(msg)
            return 0
        if findings:
            msg += (" The script check found handoff rules that do not apply as written - "
                    "report them aloud to the owner now:\n" + "\n".join(out))
        elif out:
            msg += "\n" + "\n".join(out)
        print(msg)
        return 0
    try:
        findings, out = report(handoff, rules_md, today)
    except (OSError, UnicodeDecodeError) as exc:
        print("credo-handoff-rules: cannot read: %s" % exc, file=sys.stderr)
        return 2
    for line in out:
        print(line)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
