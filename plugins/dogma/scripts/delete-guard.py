#!/usr/bin/env python3
"""dogma delete-guard core: decide whether a Bash command may destroy protected data.

Reads the PreToolUse JSON on stdin and prints a deny reason (one line) when the
command must be blocked; prints nothing when it may run. Never executes anything.

Protected (never deletable, moved away or symlinked onto):
  - /, every first-level directory, /tmp itself
  - /home, /home/X, /home/X/Y          (depth 0-2 below /home)
  - $HOME, its parent, $HOME/X         (depth 0-1 below the home)
  - every other absolute path outside /tmp/X+ and /var/tmp/X+
Every target is RESOLVED before the check: ~ and $HOME are expanded, relative paths
are joined to the working directory (including a preceding `cd`), symlinks are
followed (realpath), and for a glob the directory before the first wildcard is
resolved. A target that cannot be resolved for sure (command substitution, an unset
or re-assigned variable, eval, xargs) is blocked: deletion errs on the strict side.
Variables assigned from mktemp in the same command are known-safe.
"""

import json
import os
import re
import shlex
import sys

DELETE_VERBS = {"rm", "unlink", "shred", "rmdir"}
SHELLS = {"sh", "bash", "zsh", "dash"}
WRAPPERS = {"sudo", "command", "nice", "nohup", "time", "env"}
GLOB_RE = re.compile(r"[*?\[]")
VAR_RE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")
ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
MKTEMP_RE = re.compile(r"^[\"']?\$\(\s*mktemp\b[^)]*\)[\"']?$")
CRIT = r"/(home|root|etc|usr|bin|sbin|lib|lib64|boot|opt|srv|dev|proc|sys|mnt|media|run|snap|var)\b"
HOME_REF = r"(~|\$HOME|\$\{HOME\}|expanduser|Path\.home|os\.homedir|Dir\.home)"


class Deny(Exception):
    pass


def home():
    return os.path.realpath(os.environ.get("HOME") or "/nonexistent-home")


def depth(rel):
    rel = rel.strip("/")
    return 0 if not rel else rel.count("/") + 1


def is_dangerous(p):
    """True when the absolute, normalized path p must never be deleted."""
    p = os.path.normpath(p)
    if p == "/":
        return True
    h = home()
    if p == h or p == os.path.dirname(h) or os.path.dirname(p) == h:
        return True
    if p == "/home" or p.startswith("/home/"):
        return depth(p[len("/home"):]) <= 2
    if p.startswith("/tmp/") or p.startswith("/var/tmp/"):
        return False
    return True


def is_protected_link_target(p):
    """Symlink targets that would turn a later delete into a wipe."""
    p = os.path.normpath(p)
    if p == "/" or depth(p) == 1:
        return True
    h = home()
    if p == h or os.path.dirname(p) == h or p == os.path.dirname(h):
        return True
    if p.startswith("/home/"):
        return depth(p[len("/home"):]) <= 2
    return False


def split_segments(cmd):
    """Split on unquoted ; && || | & and newlines, keeping $( ) and backticks whole."""
    segs, cur, i, n = [], [], 0, len(cmd)
    quote, paren = None, 0
    while i < n:
        c = cmd[i]
        if quote:
            cur.append(c)
            if c == "\\" and quote == '"' and i + 1 < n:
                cur.append(cmd[i + 1])
                i += 1
            elif c == quote:
                quote = None
        elif c in "'\"`":
            quote = c
            cur.append(c)
        elif c == "\\" and i + 1 < n:
            cur.append(c + cmd[i + 1])
            i += 1
        elif cmd.startswith("$(", i):
            paren += 1
            cur.append("$(")
            i += 1
        elif c == ")" and paren:
            paren -= 1
            cur.append(c)
        elif not paren and (c in ";\n|&"):
            segs.append("".join(cur))
            cur = []
            if cmd.startswith("&&", i) or cmd.startswith("||", i):
                i += 1
        else:
            cur.append(c)
        i += 1
    segs.append("".join(cur))
    return [s.strip() for s in segs if s.strip()]


REDIR_RE = re.compile(r"(?<![\w$])\d*(?:&?>>?|<)&?\s*(?:'[^']*'|\"[^\"]*\"|\S+)")


def tokens(seg):
    seg = REDIR_RE.sub(" ", seg)
    try:
        return shlex.split(seg, posix=True)
    except ValueError:
        raise Deny("unparseable quoting in a destructive command")


class Ctx:
    def __init__(self, cwd):
        self.cwd = cwd          # None = unknown
        self.safe_vars = set()  # assigned from mktemp in this command
        self.unsafe_vars = set()  # assigned to anything else in this command


def expand(arg, ctx):
    """Expand ~ / variables in one argument; raise Deny when not resolvable."""
    if "$(" in arg or "`" in arg:
        raise Deny("target uses command substitution: %s" % arg)
    if re.search(r"\$\{[^}]*[^A-Za-z0-9_}][^}]*\}?", arg):
        raise Deny("target uses a parameter expansion: %s" % arg)
    if arg == "~" or arg.startswith("~/"):
        arg = home() + arg[1:]
    elif arg.startswith("~"):
        raise Deny("target names another user's home: %s" % arg)
    safe = False

    def sub(m):
        nonlocal safe
        name = m.group(1)
        if name in ctx.safe_vars:
            safe = True
            return "/tmp/dogma-mktemp-placeholder"
        if name in ctx.unsafe_vars:
            raise Deny("target uses a variable re-assigned in the command: $%s" % name)
        if name == "HOME":
            return home()
        if name == "PWD":
            if ctx.cwd is None:
                raise Deny("target uses $PWD with an unknown working directory")
            return ctx.cwd
        if name == "OLDPWD":
            raise Deny("target uses $OLDPWD")
        val = os.environ.get(name)
        if val is None or val == "":
            raise Deny("target uses an unset variable: $%s" % name)
        return val

    out = VAR_RE.sub(sub, arg)
    if "$" in out:
        raise Deny("target cannot be resolved: %s" % arg)
    return out, safe


def resolve(arg, ctx, dot_ok=False):
    """Absolute, symlink-resolved path for a target (glob -> its base directory + child)."""
    path, safe = expand(arg, ctx)
    if safe:
        return None  # inside a fresh mktemp directory
    if path in (".", "./") and not dot_ok:
        raise Deny("target is the current directory")
    glob = GLOB_RE.search(path)
    child = False
    if glob:
        base = path[: glob.start()]
        base = base[: base.rfind("/") + 1] if "/" in base else ""
        path, child = (base or "."), True
    if not path.startswith("/"):
        if ctx.cwd is None:
            raise Deny("relative target with an unknown working directory: %s" % arg)
        path = os.path.join(ctx.cwd, path)
    real = os.path.realpath(path)
    return os.path.join(real, "x") if child else real


def check_targets(args, ctx, label, dot_ok=False):
    for a in args:
        lit = a
        r = resolve(a, ctx, dot_ok)
        if r is None:
            continue
        if is_dangerous(r):
            raise Deny("%s of a protected path: %s -> %s" % (label, lit, r))


def nonopts(args):
    out, end = [], False
    for a in args:
        if end:
            out.append(a)
        elif a == "--":
            end = True
        elif a.startswith("-") and a != "-":
            continue
        else:
            out.append(a)
    return out


def strip_prefix(tok, ctx):
    """Drop wrappers and leading VAR=value assignments; record assignments."""
    i = 0
    while i < len(tok):
        m = ASSIGN_RE.match(tok[i])
        if m:
            i += 1
            continue
        if tok[i] in WRAPPERS:
            i += 1
            while i < len(tok) and tok[i].startswith("-"):
                i += 1
            continue
        break
    return tok[i:]


def record_assignments(seg, ctx):
    raw = seg.strip()
    for part in re.findall(r"(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)=((?:\"[^\"]*\"|'[^']*'|\$\([^)]*\)|\S)*)", raw):
        name, val = part
        if MKTEMP_RE.match(val):
            ctx.safe_vars.add(name)
            ctx.unsafe_vars.discard(name)
        else:
            ctx.unsafe_vars.add(name)
            ctx.safe_vars.discard(name)


def check_segment(seg, ctx, nest=0):
    if nest > 3:
        raise Deny("too deeply nested shell")
    # subshell / brace group / negation wrappers: "(cd ~", "{ rm ...", "rm ...)", "}"
    # (only unbalanced parentheses, so "$(mktemp -d)" stays intact)
    seg = seg.strip().lstrip("{! \t").rstrip("} \t")
    while seg.startswith("(") and seg.count("(") > seg.count(")"):
        seg = seg[1:].lstrip("{! \t")
    while seg.endswith(")") and seg.count(")") > seg.count("("):
        seg = seg[:-1].rstrip("} \t")
    if not seg:
        return
    raw_tok = tokens(seg) if re.search(r"\b(rm|unlink|shred|rmdir|find|mv|ln|cp|cd|pushd|git|eval|xargs|sh|bash|zsh|dash)\b", seg) else []
    record_assignments(seg, ctx)
    tok = strip_prefix(raw_tok, ctx)
    if not tok:
        return
    verb = os.path.basename(tok[0])
    args = tok[1:]
    if verb in ("cd", "pushd"):
        dest = (nonopts(args) or ["~"])[0]
        try:
            d, safe = expand(dest, ctx)
            if not d.startswith("/"):
                d = os.path.join(ctx.cwd, d) if ctx.cwd else None
            ctx.cwd = os.path.realpath(d) if d else None
        except Deny:
            ctx.cwd = None
        return
    if verb == "git" and args[:1] == ["rm"]:
        verb, args = "rm", [a for a in args[1:]]
        if "--cached" in args:
            return
    if verb == "git" and "clean" in args:
        # git clean deletes untracked files below the working directory
        check_targets(["."], ctx, "git clean", dot_ok=True)
        return
    if verb in SHELLS:
        for i, a in enumerate(args):
            if re.match(r"^-[a-zA-Z]*c[a-zA-Z]*$", a):
                inner = args[i + 1] if i + 1 < len(args) else ""
                check_command(inner, Ctx(ctx.cwd), nest + 1)
                return
        return
    if verb == "eval":
        if re.search(r"\b(rm|unlink|shred|rmdir|find|mv|ln)\b", " ".join(args)):
            raise Deny("eval around a destructive command")
        return
    if verb == "xargs":
        rest = strip_prefix(nonopts(args), ctx)
        if rest and os.path.basename(rest[0]) in DELETE_VERBS | {"mv", "shred"}:
            raise Deny("xargs feeds unknown targets to %s" % rest[0])
        return
    if verb in DELETE_VERBS:
        check_targets(nonopts(args), ctx, "deletion")
        return
    if verb == "find":
        paths = []
        for a in args:
            if a in ("-H", "-L", "-P"):
                continue
            if a.startswith("-") or a in ("(", "!", ")"):
                break
            paths.append(a)
        joined = " ".join(args)
        destructive = "-delete" in args or re.search(r"-(exec|execdir|ok|okdir)\s+\S*\b(rm|unlink|shred|rmdir)\b", joined)
        if destructive:
            if "-L" in args or "-follow" in args:
                raise Deny("find follows symlinks while deleting")
            check_targets(paths or ["."], ctx, "find deletion", dot_ok=True)
        return
    if verb == "mv":
        srcs = nonopts(args)
        if "-t" in args or any(a.startswith("--target-directory") for a in args):
            pass
        elif len(srcs) > 1:
            srcs = srcs[:-1]
        else:
            srcs = []
        check_targets(srcs, ctx, "move")
        return
    if verb == "ln" or (verb == "cp" and any(a in ("-s", "--symbolic-link") or (re.match(r"^-[a-zA-Z]*s", a) and not a.startswith("--")) for a in args)):
        if verb == "ln" and not any(a == "--symbolic" or (re.match(r"^-[a-zA-Z]*s", a) and not a.startswith("--")) for a in args):
            return
        targets = nonopts(args)
        if not targets:
            return
        src = targets[0]
        p, safe = expand(src, ctx)
        if safe:
            return
        if not p.startswith("/"):
            p = os.path.join(ctx.cwd or "/", p)
        if is_protected_link_target(os.path.realpath(p)):
            raise Deny("symlink onto a protected path: %s" % src)
        return


LEGACY = [
    (r"(^|\s|;|&&|\|\|)(sudo\s+)?(mkfs|wipefs|dd\s+if=/dev/(zero|urandom|random))", None,
     "destructive disk operation (mkfs/wipefs/dd)"),
    (r"(sudo\s+)?(python[23]?|python3\.[0-9]+)\b", r"\b(rmtree|remove|unlink|rmdir|shutil)\b",
     "python deletion targeting a critical path"),
    (r"(sudo\s+)?perl\b", r"\b(rmtree|unlink|remove_tree)\b", "perl deletion targeting a critical path"),
    (r"(sudo\s+)?node\b", r"\b(rmSync|unlinkSync|rmdirSync|rimraf)\b", "node deletion targeting a critical path"),
    (r"(sudo\s+)?ruby\b", r"\b(rm_rf|rm_r|delete|remove_entry)\b", "ruby deletion targeting a critical path"),
    (r"(python[23]?|python3\.[0-9]+|perl|node|ruby)\b", r"\b(symlink|symlinkSync|make_symlink)\b",
     "interpreter symlink onto a critical path"),
    (r"(sudo\s+)?truncate\b", None, "truncate targeting a critical path"),
    (r"cp\s+/dev/(null|zero)\b", None, "overwriting a critical path with /dev/null or /dev/zero"),
    (r"rsync\b.*--delete", None, "rsync --delete targeting a critical path"),
    (r"tar\b.*--remove-files", None, "tar --remove-files targeting a critical path"),
    (r"(sudo\s+)?(chmod|chown)\s.*-R", None, "recursive permission change on a critical path"),
]


def check_legacy(cmd):
    crit = re.compile(r"(%s|%s/|%s\b)" % (CRIT, r"~", r"\$\{?HOME\}?"))
    for trigger, extra, reason in LEGACY:
        if not re.search(trigger, cmd):
            continue
        if extra and not re.search(extra, cmd):
            continue
        if reason.startswith("destructive disk"):
            raise Deny(reason)
        if "interpreter symlink" in reason:
            if re.search(r"(%s|%s)" % (CRIT, HOME_REF), cmd):
                raise Deny(reason)
            continue
        if crit.search(cmd) or re.search(r"(chmod|chown|rsync)\b.*\s/\s*$", cmd):
            raise Deny(reason)
    harmless = r"/dev/(null|stdout|stderr|tty|fd/\d+)\b"
    for m in re.finditer(r">\|?\s*(\S+)", cmd):
        tgt = m.group(1).strip("'\"")
        if re.match(harmless, tgt):
            continue
        if re.match(r"(%s|~/|\$HOME)" % CRIT, tgt):
            raise Deny("destructive redirect targeting a critical path")


def check_command(cmd, ctx, nest=0):
    for seg in split_segments(cmd):
        check_segment(seg, ctx, nest)


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    if (data.get("tool_name") or "Bash") != "Bash":
        return
    cmd = ((data.get("tool_input") or {}).get("command") or "")
    if not cmd.strip():
        return
    cwd = data.get("cwd") or os.getcwd()
    try:
        check_legacy(cmd)
        check_command(cmd, Ctx(os.path.realpath(cwd)))
    except Deny as d:
        print(str(d))


if __name__ == "__main__":
    main()
