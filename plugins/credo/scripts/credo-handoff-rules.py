#!/usr/bin/env python3
"""credo-handoff-rules.py - check the temporary rules a credo handoff carries.

A handoff (.credo/process/handoffs/HANDOFF.md) may hold rules only in one section,
"## Rules (temporary)", one rule per line:

    - <rule> | source: owner "<verbatim quote>" (<YYYY-MM-DD>) | until: <goal, date or event>
    - <rule> | source: agent decision | until: <goal, date or event>

Precedence: the owner's current words > owner rules in the handoff (temporary) >
.credo/RULES.md > agent-decision rules in the handoff (they only fill gaps). A conflict
between a handoff rule and RULES.md is reported aloud and RULES.md applies until the owner
settles it. A rule without `until:` does not apply.

Usage:
    credo-handoff-rules.py check <HANDOFF.md> [RULES.md] [--today YYYY-MM-DD]
        Print one finding per bad rule line (missing source, missing until, expired
        until-date, source neither an owner quote with date nor "agent decision"),
        legacy rule sections outside "Rules (temporary)", and the RULES.md headings to
        compare against. Exit 0 = no finding, 1 = findings, 2 = usage or unreadable file.
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
    "working, and let RULES.md win over the conflicting handoff rule until the owner settles it. "
    "An owner rule without an expiry goes to the right place: permanent -> propose the exact "
    "RULES.md entry and write it after the owner's OK; temporary -> ask the owner for the until; "
    "if the owner leaves it open, say aloud that it will not be honoured reliably and will get "
    "lost over time and context.")

HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
LEGACY_RE = re.compile(r"\b(rules?|standing|agreements?|owner orders?|orders in force)\b", re.I)
FIELD_RE = re.compile(r"^\s*(source|until)\s*:\s*(.*?)\s*$", re.I)
OWNER_SRC_RE = re.compile(r'^owner\s+"[^"]+"\s*\(\s*\d{4}-\d{2}-\d{2}[^)]*\)', re.I)
DATE_RE = re.compile(r"^(?:by\s+|on\s+)?(\d{4}-\d{2}-\d{2})\b", re.I)
PLACEHOLDER_RE = re.compile(r"^\(?(none|-|n/?a|tbd|\?|open|unknown|forever|permanent)\)?$", re.I)


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().splitlines()


def sections(lines):
    """Yield (heading level, heading text, start index, [(lineno, line)]) per heading."""
    out = []
    cur = None
    fence = False
    for i, line in enumerate(lines, 1):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if fence:
            continue
        m = HEADING_RE.match(line)
        if m:
            cur = [len(m.group(1)), m.group(2), i, []]
            out.append(cur)
        elif cur is not None:
            cur[3].append((i, line))
    return out


def rule_lines(body):
    """Bullet lines of a section; continuation lines are folded into their bullet."""
    rules = []
    for no, line in body:
        s = line.strip()
        if re.match(r"^[-*+]\s+", s):
            rules.append([no, re.sub(r"^[-*+]\s+", "", s)])
        elif s and rules and line[:1] in (" ", "\t"):
            rules[-1][1] += " " + s
    return rules


def check_rule(text, today):
    """Return the list of problems of one rule line (empty = fine)."""
    parts = [p.strip() for p in text.split("|")]
    fields = {}
    for p in parts[1:]:
        m = FIELD_RE.match(p)
        if m:
            fields[m.group(1).lower()] = m.group(2)
    probs = []
    src = fields.get("source")
    if src is None or not src:
        probs.append("no source: (owner \"<quote>\" (<date>) or agent decision)")
    elif not (OWNER_SRC_RE.match(src) or src.lower() == "agent decision"):
        probs.append("source is neither owner \"<quote>\" (<date>) nor agent decision")
    until = fields.get("until")
    if until is None or not until or PLACEHOLDER_RE.match(until):
        probs.append("no until: (goal, date or event) - this rule does NOT apply")
    else:
        m = DATE_RE.match(until)
        if m:
            try:
                d = datetime.date.fromisoformat(m.group(1))
            except ValueError:
                d = None
            if d is not None and d < today:
                probs.append("expired (until %s) - drop it" % m.group(1))
    return probs


def check(handoff, rules_md, today):
    lines = read(handoff)
    findings = []
    found = False
    for level, title, start, body in sections(lines):
        if title.strip().lower() == SECTION.lower():
            found = True
            for no, text in rule_lines(body):
                for p in check_rule(text, today):
                    findings.append("line %d: %s: %s" % (no, p, text[:120]))
        elif LEGACY_RE.search(title):
            if rule_lines(body):
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
    today = datetime.date.today()
    rest = []
    i = 0
    while i < len(argv):
        if argv[i] == "--today" and i + 1 < len(argv):
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
