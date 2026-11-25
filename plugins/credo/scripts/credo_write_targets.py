"""credo_write_targets.py - literal file write targets of a Bash command (#212, stdlib only).

Shared by the provenance ledger (credo-ledger.py: which targets did not exist before the call,
the new-file guard for /tmp and /var/tmp) and the cleanup library (the transcript check of
own-rm). The command is parsed with the small bash lexer of credo-inline-guard.py (quotes,
escapes, heredoc bodies, $(...) and backticks), so a heredoc body or a quoted ">" is never a
target.

A write target is, per simple command (after env assignments and wrappers like sudo, nice,
taskset, timeout):
  > / >> / >| / &> / &>> / <> FILE (fd numbers in front included; >&N and >&- are fd copies)
  tee [-a ...] FILE...
  cp / mv / install ... DEST   (the last operand; not with -t/--target-directory or -T forms
                                that name a directory, not with fewer than two operands)
  dd ... of=FILE

mv targets count for the new-file guard only (write_targets), never as own-rm evidence
(evidence_targets): a cross-filesystem mv copies and then deletes the source, so its target is
a new inode born during the call that holds the only copy of someone else's file.

Conservative on purpose: only absolute literal paths count. A word with a variable, command
substitution, glob or brace character ($ ` * ? [ ] { }), a ~ path, a relative path or a path
ending in / never counts. Commands inside bash -c "..." strings are not parsed. Any parse error
returns no targets.
"""
import importlib.util
import os
import re

_HERE = os.path.dirname(os.path.abspath(__file__))
_GUARD = None

COPY_CMDS = {"cp", "mv", "install"}
UNSAFE_CHARS = set("$`*?[]{}")


def _guard():
    global _GUARD
    if _GUARD is None:
        spec = importlib.util.spec_from_file_location(
            "credo_inline_guard_parser", os.path.join(_HERE, "credo-inline-guard.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _GUARD = mod
    return _GUARD


def literal_path(word):
    """The normalized absolute path of a literal word, else None."""
    if not isinstance(word, str) or not word.startswith("/") or word.endswith("/"):
        return None
    if any(c in UNSAFE_CHARS for c in word) or "\n" in word or "\0" in word:
        return None
    return os.path.normpath(word)


def _copy_dest(name, args):
    """The destination operand of cp/mv/install, or None (directory forms, too few operands)."""
    operands, i, opts_done = [], 0, False
    valued = {"-m", "-o", "-g", "-S", "--mode", "--owner", "--group", "--suffix"} if name == "install" \
        else {"-S", "--suffix"}
    while i < len(args):
        a = args[i]
        if not opts_done and a == "--":
            opts_done = True
        elif not opts_done and a.startswith("-") and len(a) > 1:
            if a in ("-t", "--target-directory") or a.startswith("--target-directory=") \
                    or (re.match(r"^-[A-Za-z]*t", a) and not a.startswith("--")):
                return None
            if a in ("-d", "-D") and name == "install":
                return None  # install -d creates directories
            if a in valued:
                i += 1
        else:
            operands.append(a)
        i += 1
    if len(operands) < 2:
        return None
    return operands[-1]


def _targets_of(words, redirects, moves=True):
    out = []
    for op, word in redirects:
        if "<" in op and ">" not in op:
            continue  # input redirect
        if op.endswith("&") and (word.isdigit() or word == "-"):
            continue  # >&2, >&- : fd copy or close
        out.append(word)
    g = _guard()
    words = g.strip_prefix(words)
    if not words:
        return out
    name = g.basename(words[0])
    args = words[1:]
    if name == "tee":
        opts_done = False
        for a in args:
            if not opts_done and a == "--":
                opts_done = True
            elif not opts_done and a.startswith("-") and len(a) > 1:
                continue
            else:
                out.append(a)
    elif name in COPY_CMDS and (moves or name != "mv"):
        dest = _copy_dest(name, args)
        if dest is not None:
            out.append(dest)
    elif name == "dd":
        out.extend(a[3:] for a in args if a.startswith("of="))
    return out


_LAST = [None, None]  # (command, parsed simple commands): the ledger pre hook asks twice


def _commands(command):
    if _LAST[0] != command:
        try:
            parser = _guard().Parser(command)
            parser.parse()
            cmds = parser.commands
        except Exception:  # noqa: BLE001 - unparsable: no evidence, no guard decision
            cmds = []
        _LAST[0], _LAST[1] = command, cmds
    return _LAST[1]


def write_targets(command, moves=True):
    """Sorted list of the absolute literal paths the command writes as a file target (moves=False:
    without mv destinations)."""
    if not isinstance(command, str) or not command:
        return []
    found = set()
    for cmd in _commands(command):
        for word in _targets_of(cmd.words, cmd.redirects, moves):
            p = literal_path(word)
            if p:
                found.add(p)
    return sorted(found)


def evidence_targets(command):
    """The write targets that may count as own-rm evidence: write_targets without mv (see above)."""
    return write_targets(command, moves=False)


def uses_mktemp(command):
    """True when the command calls mktemp (its output is unknown before the call)."""
    return isinstance(command, str) and re.search(r"(^|[^A-Za-z0-9_.-])mktemp\b", command) is not None
