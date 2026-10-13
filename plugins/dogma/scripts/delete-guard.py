#!/usr/bin/env python3
"""dogma delete-guard core: decide whether a Bash command may destroy protected data.

Reads the PreToolUse JSON on stdin and prints a deny reason (one line) when the
command must be blocked; prints nothing when it may run. Never executes anything.

The HARD LIST (on_hard_list) is denied whatever DOGMA-PERMISSIONS.md says:
  - /, the home, its parent and its first level (~, ~/X, /home/X)
  - every absolute path of depth <= 3 outside the temp roots (/usr/local, /home/X/.ssh, /opt/a/b)
  - /mnt and /media, whatever the filesystem (Windows drive, network share, USB stick): depth <= 4
    (/mnt/nas/share/folder), a Windows user profile root and its first level (/mnt/c/Users/X/Pictures),
    Windows system/persistence/profile paths and declared mounts (whole subtree)
  - a whole repository or worktree root (bash-guard.py), the working directory and its parents
Deeper paths are NOT hard: they follow the delete setting (file-protection.sh, DOGMA-PERMISSIONS.md).
Temp roots (/tmp/X+, /var/tmp/X+, $TMPDIR/X+, the Windows temp folders) are never hard.

Every target is RESOLVED before the check: ~ and $HOME are expanded, relative paths are joined to the
working directory (including a preceding `cd`), symlinks are followed (realpath), and for a glob the
directory before the first wildcard is resolved. A plain literal assignment earlier in the same command
(bash-guard.py substitutes it) is resolved as well. A variable target that bash-guard.py cannot pin to one
value is judged by its candidate values: every one of them that is on the hard list denies, here or in
bash-guard.py. A target that cannot be resolved for sure (command substitution, an unset or re-assigned
variable without a certain value, a parameter expansion, eval text, xargs, an unknown working directory) is
UNSURE: it raises Unsure, which is not a denial. bash-guard.py records the target as a delete finding, so
the delete setting decides. Only the hard list (and the non-delete rules of bash-guard.py) deny.
Variables assigned from mktemp in the same command are known-safe.
"""

import codecs
import importlib.util
import json
import os
import re
import copy
import shlex
import sys
import time


def _load_getopt():
    """GNU option parsing shared with bash-guard.py (dogma_getopt.py next to this file)."""
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "dogma_getopt.py")
    spec = importlib.util.spec_from_file_location("dogma_getopt", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


getopt = _load_getopt()

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
    """A hard denial: the command is blocked whatever the delete setting says."""


class Unsure(Exception):
    """A delete target that cannot be resolved for sure. Not a denial: the target is skipped here and
    bash-guard.py records it as a delete finding, which file-protection.sh decides by the delete setting."""


# absolute depth (/ is 0) of a hard path outside the temp roots: /usr/local, /home/X/.ssh, /opt/a/b
HARD_DEPTH = 3
# absolute depth of a hard path below /mnt and /media: /mnt/nas/share/folder
MOUNT_HARD_DEPTH = 4


# monotonic time after which the check denies (fail closed); bash-guard.py sets it so the
# whole hook stays below the hook timeout. None = no limit (standalone use).
DEADLINE_AT = [None]


def check_time():
    if DEADLINE_AT[0] is not None and time.monotonic() > DEADLINE_AT[0]:
        raise Deny("check ran out of time, command blocked (fail closed)")


def home():
    return os.path.realpath(os.environ.get("HOME") or "/nonexistent-home")


def depth(rel):
    rel = rel.strip("/")
    return 0 if not rel else rel.count("/") + 1


WINDOWS_TEMP_RE = re.compile(r"^/mnt/[A-Za-z]/(?:Users/[^/]+/AppData/Local/Temp|Windows/Temp)(?=/)")
UNRESOLVED_RE = re.compile(r"[$`~*?\[\]{}()\\]")
TEMP_LABELS = ("rm", "unlink", "shred", "rmdir", "find -delete")


def temp_roots():
    """/tmp, /var/tmp and $TMPDIR (unless it is / or contains the home)."""
    roots = ["/tmp", "/var/tmp"]
    tmpdir = os.environ.get("TMPDIR") or ""
    if tmpdir.startswith("/"):
        real, h = os.path.realpath(tmpdir), home()
        if real != "/" and not (h == real or h.startswith(real + "/")):
            roots.append(real)
    return roots


def temp_root_of(path):
    """The temporary root that a resolved absolute path lies strictly inside, else None.

    The home and everything below it is never temporary (a test home may sit below /tmp).
    The Windows temp folders of WSL drives (Users/<name>/AppData/Local/Temp, Windows/Temp)
    count as well."""
    h = home()
    if path == h or path.startswith(h.rstrip("/") + "/"):
        return None
    match = WINDOWS_TEMP_RE.match(path)
    if match and path != match.group(0):
        return match.group(0)
    for root in temp_roots():
        if path.startswith(root.rstrip("/") + "/"):
            return root
    return None


def mount_path_dangerous(p):
    """True when a path below /mnt or /media (WSL drives, shares, removable media) is on the hard list.

    The same rule for every filesystem type: hard are the paths down to MOUNT_HARD_DEPTH (/mnt/d/data,
    /mnt/nas/share/folder, /media/usb/folder), a Windows user profile root and its first level
    (/mnt/c/Users/<name>[/<x>]), the Windows system, persistence and profile paths (windows_critical) and
    anything inside a declared mount. Deeper files are not hard: the delete setting decides."""
    parts = p.split("/")[1:]
    if len(parts) <= MOUNT_HARD_DEPTH or declared_mount(p):
        return True
    if parts[0] != "mnt":
        return False
    return (parts[2].lower() == "users" and len(parts) <= 5) or windows_critical(parts, False)


def on_hard_list(p):
    """True when the absolute, normalized path p is on the hard list (see the module docstring).

    Never deleted, moved away or overwritten by a delete-type command, whatever the delete setting says.
    The temp roots are never hard; everything that is not on the list follows DOGMA-PERMISSIONS.md."""
    p = os.path.normpath(p)
    if p == "/":
        return True
    h = home()
    if p == h or p == os.path.dirname(h) or os.path.dirname(p) == h:
        return True
    if temp_root_of(p):
        return False
    if p.startswith(("/mnt/", "/media/")) and not p.startswith(h.rstrip("/") + "/"):
        return mount_path_dangerous(p)
    if p.startswith(h.rstrip("/") + "/") and any(h.startswith(root.rstrip("/") + "/") for root in temp_roots()):
        # a home below a temp root (test setups): only its first level is hard
        return depth(p[len(h):]) <= 1
    return depth(p) <= HARD_DEPTH


def _temp_resolved(path, label):
    """True when path (joined to its base) resolves, symlinks followed, strictly inside a temp root.

    The directories between the temp root and the target must exist: a link that the same command
    creates there could redirect the rest of the path. The target itself may be missing, because
    rm, unlink and find -delete remove a link without following it; a trailing slash or shred
    follows it, so there the target must exist as well."""
    if ".." in path.split("/") and missing_before_dotdot(path):
        return False
    real = os.path.realpath(path)
    root = temp_root_of(real)
    if root is None:
        return False
    parent = os.path.dirname(real)
    if parent != root and not os.path.isdir(parent):
        return False
    return os.path.exists(real) or not (path.endswith("/") or label == "shred")


def temp_only(findings, cwd):
    """True when every recorded delete is a plain rm, unlink, shred, rmdir or find -delete and every
    target resolves strictly inside a temp root. Anything unsure returns False (normal rules)."""
    deletes = findings.get("deletes") or []
    if not deletes:
        return False
    tmpdir = os.environ.get("TMPDIR") or ""
    for entry in deletes:
        label, target, dirs = entry.get("label"), entry.get("target") or "", entry.get("dirs") or []
        if tmpdir.startswith("/"):
            target = re.sub(r"\$\{TMPDIR\}|\$TMPDIR(?![A-Za-z0-9_])", lambda _match: tmpdir, target)
        if label not in TEMP_LABELS or not target or not dirs or UNRESOLVED_RE.search(target):
            return False
        for directory in dirs:
            base = directory or cwd
            if not base:
                return False
            path = target if target.startswith("/") else os.path.join(base, target)
            if not _temp_resolved(path, label):
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
    """Expand ~ / variables in one argument; raise Unsure when not resolvable for sure."""
    if "$(" in arg or "`" in arg:
        raise Unsure("target uses command substitution: %s" % arg)
    if re.search(r"\$\{[^}]*[^A-Za-z0-9_}][^}]*\}?", arg):
        raise Unsure("target uses a parameter expansion: %s" % arg)
    if arg == "~" or arg.startswith("~/"):
        arg = home() + arg[1:]
    elif arg == "~+" or arg.startswith("~+/"):
        if ctx.cwd is None:
            raise Unsure("target uses ~+ with an unknown working directory: %s" % arg)
        arg = ctx.cwd + arg[2:]
    elif arg.startswith("~"):
        raise Unsure("target names another user's home: %s" % arg)
    safe = False

    def sub(m):
        nonlocal safe
        name = m.group(1)
        if name in ctx.safe_vars:
            safe = True
            return "/tmp/dogma-mktemp-placeholder"
        if name in ctx.unsafe_vars:
            raise Unsure("target uses a variable re-assigned in the command: $%s" % name)
        if name == "HOME":
            return home()
        if name == "PWD":
            if ctx.cwd is None:
                raise Unsure("target uses $PWD with an unknown working directory")
            return ctx.cwd
        if name == "OLDPWD":
            raise Unsure("target uses $OLDPWD")
        val = os.environ.get(name)
        if val is None or val == "":
            raise Unsure("target uses an unset variable: $%s" % name)
        return val

    out = VAR_RE.sub(sub, arg)
    if "$" in out:
        raise Unsure("target cannot be resolved: %s" % arg)
    return out, safe


def missing_before_dotdot(path):
    """The first path prefix before a ".." that does not exist (or is a dangling link), else None.

    The kernel resolves ".." against what that prefix is at run time (it may be a symlink
    created earlier in the same command); realpath can only collapse it textually."""
    parts = path.split("/")
    for index, part in enumerate(parts):
        if part == ".." and index:
            prefix = "/".join(parts[:index]) or "/"
            if not os.path.exists(prefix):
                return prefix
    return None


def resolve(arg, ctx, dot_ok=False, follow=True):
    """Absolute, symlink-resolved path for a target (glob -> its base directory + child).

    follow=False (rm, unlink, rmdir, mv sources): a symlink named as the last component is
    the target itself (only the link is removed or moved), so only its directory is
    resolved; a trailing slash still follows it."""
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
            raise Unsure("relative target with an unknown working directory: %s" % arg)
        path = os.path.join(ctx.cwd, path)
    missing = missing_before_dotdot(path)
    if missing:
        raise Unsure("target %s cannot be checked: %s does not exist yet, so where the following \"..\" "
                     "leads is unknown" % (arg, missing))
    if not follow and not child and not path.endswith("/"):
        # the kernel resolves a symlink before a following "..": the parent is resolved
        # physically and only the final component stays unresolved (never normpath here)
        name = os.path.basename(path)
        if name not in ("", ".", ".."):
            return os.path.join(os.path.realpath(os.path.dirname(path)), name)
    real = os.path.realpath(path)
    return os.path.join(real, "x") if child else real


def check_targets(args, ctx, label, dot_ok=False, follow=True):
    for a in args:
        try:
            r = resolve(a, ctx, dot_ok, follow)
        except Unsure:
            continue  # the delete setting decides (bash-guard.py records the target)
        if r is None:
            continue
        if on_hard_list(r):
            raise Deny("%s of a protected path: %s -> %s" % (label, a, r))


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


def strip_wrapper(verb, args, ctx):
    """env, sudo, doas by the shared option parser: the wrapped command's words.

    env -C/sudo -D change ctx.cwd (callers pass a copy: it only applies to this command);
    an unknown option or sudo --chroot make it unknown, so relative targets fail closed.
    env -S splits its string and goes on parsing options from the words."""
    options, rest, split = getopt.scan_wrapper(verb, args)
    for _ in range(9):
        if split is None:
            break
        try:
            words = getopt.env_split(split)  # GNU env -S rules (\_, \c, #, ${NAME})
        except ValueError as error:
            raise Deny("env -S string cannot be checked (%s)" % error)
        more, rest, split = getopt.scan_wrapper(verb, words + rest)
        options += more
    else:
        raise Deny("env -S nesting is too deep")
    for name, value in options:
        if name.startswith("?") or verb == "sudo" and name in ("-R", "--chroot", "-i", "--login"):
            ctx.cwd = None  # unknown option, another root, or a login shell in the target home
        elif (verb, name) in (("env", "-C"), ("env", "--chdir"), ("sudo", "-D"), ("sudo", "--chdir")):
            if value is None or ctx.cwd is None and not value.startswith("/"):
                ctx.cwd = None
                continue
            path = os.path.join(ctx.cwd or "/", value)
            ctx.cwd = None if missing_before_dotdot(path) else os.path.realpath(path)
    if verb == "doas" and getopt.has(options, "-C"):
        return []  # only checks a configuration file
    if verb == "env" and rest[:1] == ["-"]:
        rest = rest[1:]
    return rest


def strip_prefix(tok, ctx):
    """Drop wrappers and leading VAR=value assignments; record assignments."""
    i = 0
    while i < len(tok):
        m = ASSIGN_RE.match(tok[i])
        if m:
            i += 1
            continue
        if tok[i] in getopt.WRAPPERS:
            tok, i = strip_wrapper(tok[i], tok[i + 1:], ctx), 0
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


# a delete command in an argument string (linear: one-character lookbehind, no leading path pattern)
OPAQUE_DELETE_RE = re.compile(r"(?<![^\s;&|({/])(?:rm|unlink|shred|rmdir)\s+\S")


def check_opaque(seg, ctx, nest):
    """A command word chosen at run time ($CMD, $(...)): its string arguments are what runs,
    so one that contains a delete command is checked with an unknown working directory and a
    relative target fails closed (bash-guard.py does the full analysis). Plain arguments of
    an ordinary program (commit messages, test filters) are not shell text and stay unchecked."""
    m = re.match(r"^(?:\s*[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*\\?(\S+)", seg)
    if not m or "$" not in m.group(1) and "`" not in m.group(1) or nest > 3:
        return
    if not OPAQUE_DELETE_RE.search(seg):
        return
    try:
        raw_tok = tokens(seg)
    except Deny:
        raise Deny("unparseable quoting around a delete command")
    for arg in raw_tok[1:]:
        if re.search(r"\s", arg) and OPAQUE_DELETE_RE.search(arg):
            check_command(arg, Ctx(None), nest + 1)


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
    record_assignments(seg, ctx)
    # only a segment whose COMMAND word is relevant is tokenized; a verb that merely
    # appears in an argument (a file named CLAUDE.git.md, a grep pattern) is not
    m = re.match(r"^(?:\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*|sudo|command|nice|nohup|time|env)(?:\s+-\S+)*\s+)*\\?(\S+)", seg)
    first = os.path.basename(m.group(1)) if m else ""
    # env, sudo and doas options may take values (env -C DIR rm ...): always tokenized
    m = re.match(r"^(?:\s*[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*\\?(\S+)", seg)
    if m and os.path.basename(m.group(1)) in getopt.WRAPPERS:
        first = os.path.basename(m.group(1))
    relevant = DELETE_VERBS | {"find", "mv", "ln", "cp", "cd", "pushd", "git", "eval", "xargs"} | SHELLS | \
        set(getopt.WRAPPERS)
    if first not in relevant:
        check_opaque(seg, ctx, nest)
        return
    try:
        raw_tok = tokens(seg)
    except Deny:
        # unparseable quoting only blocks a segment that can itself destroy data
        if first in DELETE_VERBS | {"find", "mv", "ln", "eval", "xargs"} | SHELLS | set(getopt.WRAPPERS):
            raise
        return
    # a wrapper's working directory (env -C, sudo -D) only applies to this command
    outer, ctx = ctx, copy.copy(ctx)
    tok = strip_prefix(raw_tok, ctx)
    if not tok:
        return
    verb = os.path.basename(tok[0])
    args = tok[1:]
    if verb in ("cd", "pushd"):
        ctx = outer  # the shell's own working directory changes
        dest = (nonopts(args) or ["~"])[0]
        try:
            d, safe = expand(dest, ctx)
            if not d.startswith("/"):
                d = os.path.join(ctx.cwd, d) if ctx.cwd else None
            ctx.cwd = os.path.realpath(d) if d else None
        except Unsure:
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
        return  # the text of eval is walked by bash-guard.py: literal text is checked there, run-time text is unsure
    if verb == "xargs":
        rest = strip_prefix(nonopts(args), ctx)
        if rest and os.path.basename(rest[0]) in DELETE_VERBS | {"mv", "shred"}:
            raise Unsure("xargs feeds unknown targets to %s" % rest[0])
        return
    if verb in DELETE_VERBS:
        # GNU and POSIXLY_CORRECT readings; rm, unlink and rmdir remove a symlink itself,
        # shred writes through it
        for _options, targets in getopt.parse_modes(verb, args) or [(None, nonopts(args))]:
            check_targets(targets, ctx, "deletion", follow=verb == "shred")
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
            # with -L the links below the start points are followed: those files are unsure (the start
            # points themselves are checked, bash-guard.py records the find for the delete setting)
            check_targets(paths or ["."], ctx, "find deletion", dot_ok=True)
        return
    if verb == "mv":
        # sources by GNU option parsing (bundles, -t/--target-directory in every spelling)
        # both the GNU and the POSIXLY_CORRECT reading are checked
        for options, sources, destination, into, _no_target in getopt.copy_layouts("mv", args):
            check_targets(sources if destination is not None else [], ctx, "move", follow=False)
        return
    if verb in ("ln", "cp"):
        for options, sources, destination, into, _no_target in getopt.copy_layouts(verb, args):
            if not getopt.has(options, "-s", "--symbolic" if verb == "ln" else "--symbolic-link"):
                continue
            if verb == "ln" and destination is None:
                sources = sources[:1]
            for src in sources:
                try:
                    p, safe = expand(src, ctx)
                except Unsure:
                    continue
                if safe:
                    continue
                if not p.startswith("/"):
                    p = os.path.join(ctx.cwd or "/", p)
                if is_protected_link_target(os.path.realpath(p)):
                    raise Deny("symlink onto a protected path: %s" % src)
        return


PY_OS_DELETES = r"(?:remove|unlink|rmdir|removedirs)"
PY_OS_MOVES = r"(?:rename|renames|replace)"
PY_ALL_CALLS = r"(?:remove|unlink|rmdir|removedirs|rename|renames|replace|rmtree|move)"
# the same functions without "replace": the name of a method reached by attrgetter/methodcaller
PY_REFLECT_CALLS = r"(?:remove|unlink|rmdir|removedirs|rename|renames|rmtree|move)"
# modules that carry the file functions of os (posix and nt ARE os); shutil is the other one
PY_FS_MODULES = "os|posix|nt"
PY_DELETE_RE = re.compile(
    r"\brmtree\b|\bsend2trash\b|\.(?:unlink|rmdir)\s*\(|"
    r"\bfrom\s+(?:os|posix|nt|shutil)\s+import\b[^\n;]*\b%s\b|"
    r"\bfrom\s+(?:os|posix|nt|shutil)\s+import\s*\([^)]*\b%s\b|"
    r"\bgetattr\s*\(\s*\(*\s*(?:os|posix|nt|shutil)\b|"
    # a module that is imported with an argument that is not a plain literal cannot be followed
    r"\b(?:import_module|__import__)\s*\(\s*(?![\"'][\w.]+[\"']\s*[,)])" % (PY_ALL_CALLS, PY_ALL_CALLS))
# `from os import *` brings every deleting function into the namespace unnamed
PY_STAR_IMPORT_RE = re.compile(r"\bfrom\s+(?:os|posix|nt|shutil)\s+import\s*\(?\s*\*")
# string literals of python code (triple-quoted too), at most this many are looked at
PY_STRING_RE = re.compile(r"\"\"\"(.*?)\"\"\"|'''(.*?)'''|\"((?:[^\"\\\n]|\\.)*)\"|'((?:[^'\\\n]|\\.)*)'", re.S)
PY_MAX_LITERALS = 256
PY_MAX_NESTING = 3


def py_dynamic_module(modules):
    """Regex source of an expression that yields the module (modules: alternation of names)
    without an import statement: import_module('os'), __import__('os'), sys.modules['os']."""
    name = r"['\"](?:%s)['\"]" % modules
    return (r"(?:(?:importlib\s*\.\s*)?import_module|__import__)\s*\(\s*%s\s*\)|"
            r"\bsys\s*\.\s*modules\s*(?:\[\s*%s\s*\]|\.\s*get\s*\(\s*%s[^)]*\))" % (name, name, name))


# a module import whose argument is not a plain literal (import_module(name), __import__("o" + "s")):
# which module it is cannot be told, so a deleting call on the result is taken as os
PY_UNKNOWN_IMPORT = (r"(?:(?:importlib\s*\.\s*)?import_module|__import__)\s*"
                     r"\((?!\s*['\"][\w.]+['\"]\s*[,)])(?:[^()]|\([^()]*\))*\)")


def py_module_target(names, modules):
    """Regex source of a reference to a module: one of its bound names or a dynamic lookup."""
    bound = "|".join(re.escape(name) for name in sorted(names))
    return r"(?:(?<!\w)(?:%s)\b|%s)" % (bound, py_dynamic_module(modules))


def python_module_names(cmd):
    """({names bound to os}, {names bound to shutil}, {names bound to an unknown module}) in a
    piece of python code.

    os (with posix and nt, the same module) and shutil themselves, `import os as o` (also in a
    list `import sys, os as o`), plain assignments of such a name (`o = os`) and of a dynamic
    lookup (`m = importlib.import_module('os')`, `m = sys.modules['os']`), followed to a fixed
    point. An unknown module is the result of an import whose argument is no plain literal
    (`m = importlib.import_module(name)`)."""
    names = {"os": set(PY_FS_MODULES.split("|")), "shutil": {"shutil"}, "unknown": set()}
    for m in re.finditer(r"\bimport\s+([^\n;]+)", cmd):
        for part in m.group(1).split(","):
            alias = re.match(r"\s*(os|posix|nt|shutil)\s+as\s+([A-Za-z_]\w*)", part)
            if alias:
                names["shutil" if alias.group(1) == "shutil" else "os"].add(alias.group(2))
    for group, modules in (("os", PY_FS_MODULES), ("shutil", "shutil")):
        for m in re.finditer(r"(?<![\w.])([A-Za-z_]\w*)\s*=\s*\(*\s*(?:%s)" % py_dynamic_module(modules), cmd):
            names[group].add(m.group(1))
    for m in re.finditer(r"(?<![\w.])([A-Za-z_]\w*)\s*=\s*\(*\s*%s" % PY_UNKNOWN_IMPORT, cmd):
        names["unknown"].add(m.group(1))
    for _ in range(4):
        grew = False
        for m in re.finditer(r"(?<![\w.])([A-Za-z_]\w*)\s*=\s*\(*\s*([A-Za-z_]\w*)\s*\)*\s*(?=$|[;\n,)])", cmd, re.M):
            for module, bound in names.items():
                if m.group(2) in bound and m.group(1) not in bound:
                    bound.add(m.group(1))
                    grew = True
        if not grew:
            break
    return names["os"], names["shutil"], names["unknown"]


def python_literals(code):
    """The string literals of python code, escapes resolved (also the pieces of "a" + "b")."""
    joined = re.sub(r"([\"'])\s*\+\s*\1", "", code)
    found = []
    for text in dict.fromkeys((code, joined)):
        for m in PY_STRING_RE.finditer(text):
            raw = next(group for group in m.groups() if group is not None)
            try:
                raw = codecs.decode(raw.encode("latin-1", "backslashreplace"), "unicode_escape")
            except (UnicodeError, ValueError):
                pass
            found.append(raw)
            if len(found) >= PY_MAX_LITERALS:
                return found
    return found


def python_nested_calls(code, nesting=0):
    """(deletes, moves) of python code that is a string literal handed to exec, eval or compile.

    The literals are read as code of their own (all of them: the code may be built in a variable
    first); this stops at a few levels."""
    if nesting >= PY_MAX_NESTING or not re.search(r"\b(?:exec|eval|compile)\s*\(", code):
        return False, False
    deletes = moves = False
    for literal in python_literals(code):
        inner_deletes, inner_moves = python_calls(literal, nesting + 1)
        deletes = deletes or inner_deletes or bool(PY_DELETE_RE.search(literal))
        moves = moves or inner_moves
    return deletes, moves


def python_calls(code, nesting=0, nested=True):
    """(deletes, moves) of python code: calls of deleting and of moving or renaming functions.

    Not the bare words (str.replace, shutil.copy and text that merely says "remove" or
    "unlink" are no deletion). The module may be imported under another name or reached
    indirectly: `import os as o; o.remove(...)`, `from os import remove` or `from os import *`,
    posix and nt (the same module as os), `(os).remove`, `getattr(o, 'remove')`, `vars(os)` and
    `os.__dict__`, `importlib.import_module('posix')`, `sys.modules['os']`; strings handed to
    exec, eval or compile count as code of their own (nested=False leaves them to the caller,
    which has the literals in their original form). bash-guard.py uses this for inline code too
    (the legacy text check does not see heredoc bodies)."""
    # a backslash-newline is a line continuation (os.\<newline>remove(...) is os.remove(...))
    code = re.sub(r"\\\r?\n", "", code)
    # the code with "a" + "b" joined to "ab" as well: __import__("o" + "s")
    joined = re.sub(r"([\"'])\s*\+\s*\1", "", code)
    deletes = moves = False
    for text in dict.fromkeys((code, joined)):
        direct_deletes, direct_moves = python_direct_calls(text)
        deletes, moves = deletes or direct_deletes, moves or direct_moves
    if nested:
        inner_deletes, inner_moves = python_nested_calls(code, nesting)
        deletes, moves = deletes or inner_deletes, moves or inner_moves
    return deletes, moves


def python_direct_calls(code):
    """(deletes, moves) of one text of python code, without the strings handed to exec and the like."""
    os_names, shutil_names, unknown_names = python_module_names(code)
    os_target = py_module_target(os_names, PY_FS_MODULES)
    shutil_target = py_module_target(shutil_names, "shutil")

    def called(target, calls):
        return bool(re.search(target + r"\s*\)*\s*\.\s*%s\b" % calls, code))

    def imported(calls):
        return bool(re.search(r"\bfrom\s+(?:os|posix|nt|shutil)\s+import\b[^\n;]*\b%s\b|"
                              r"\bfrom\s+(?:os|posix|nt|shutil)\s+import\s*\([^)]*\b%s\b" % (calls, calls), code))

    deletes = called(os_target, PY_OS_DELETES) or called(shutil_target, "rmtree") or \
        imported(r"(?:%s|rmtree)" % PY_OS_DELETES) or bool(PY_STAR_IMPORT_RE.search(code))
    moves = called(os_target, PY_OS_MOVES) or called(shutil_target, "move") or \
        imported(r"(?:%s|move)" % PY_OS_MOVES)
    # a module that is imported by a computed name: a deleting call on it is taken as os
    unknown = [PY_UNKNOWN_IMPORT]
    if unknown_names:
        unknown.append(py_module_target(unknown_names, "os"))
    if any(called(target, r"(?:%s|rmtree)" % PY_OS_DELETES) for target in unknown):
        deletes = True
    # a function looked up by name instead of written out: nothing says which one it is
    module = "(?:%s|%s)" % (os_target, shutil_target)
    if re.search(r"\bgetattr\s*\(\s*\(*\s*%s|\bvars\s*\(\s*\(*\s*%s\s*\)|%s\s*\)*\s*\.\s*(?:__dict__|"
                 r"__getattribute__)\b|\b(?:attrgetter|methodcaller)\s*\(\s*['\"]%s['\"]" % (
                     module, module, module, PY_REFLECT_CALLS), code):
        deletes = True
    return deletes, moves


def python_deletes(code):
    """True when python code deletes something (see python_calls) or reaches a deleting
    function through a lookup that cannot be followed (a module imported under a name that is
    not a plain literal)."""
    return bool(PY_DELETE_RE.search(code)) or python_calls(code)[0]


# a home lookup whose result is not a visible path (the literal "~/x" of expanduser is a path)
PY_HOME_LOOKUP_RE = re.compile(r"Path\.home|homedir|environ\s*\[\s*[\"']HOME|environ\.get\(\s*[\"']HOME|"
                               r"getenv\(\s*[\"']HOME|getpwuid|pw_dir|getpwnam|chr\(\s*126\s*\)|\\x7e|\\176|"
                               r"expanduser\s*\(\s*(?![\"'])")


def python_moves_critical(code):
    """True when python code that only moves or renames (no delete: python_deletes) names a path
    that critical_redirect protects, or looks up the home so that the path is hidden. Moving or
    renaming below a project (os.replace(p + '.tmp', p), the atomic write) is no problem."""
    if python_deletes(code) or not python_calls(code)[1]:
        return False
    if PY_HOME_LOOKUP_RE.search(code):
        return True
    for m in re.finditer(r"(?:^|[\s'\"(=,\[])(~[^\s'\"`;)]*|/[^\s'\"`;)]+)", code):
        if critical_redirect(m.group(1)):
            return True
    return False


# "truncate" as a command: at the start of a simple command, after a wrapper (sudo, env, xargs, nice, ...) with
# its options and VAR=value words, after find -exec. The word in a search pattern or an argument (grep -n truncate
# a.py) is no truncation.
TRUNCATE_RE = (
    r"(?:^|[;&|(){`\n]|\b(?:then|do|else|elif|if|while|until)\b|!|\s-(?:exec|execdir|ok|okdir)\b)\s*"
    r"(?:\w+=\S*\s+)*"
    r"(?:(?:sudo|doas|env|nohup|time|command|exec|nice|ionice|setsid|stdbuf|timeout|xargs|builtin)\b"
    r"(?:\s+(?:-\S+(?:\s+[\w.@:/+={}-]+)?|\w+=\S*|\d+[smhd]?))*\s+)*"
    r"(?:\w+=\S*\s+)*(?:\S*/)?truncate\b")
# the rules whose text trigger counts only outside quotes: the word in a commit message or a search pattern
# ("fix: python os.remove(~/x)") is no command. What a quoted string runs is checked by bash-guard.py
# (nested shells, substitutions, inline code), which hands every simple command over on its own.
QUOTE_GATED = ("python", "perl", "node", "ruby", "interpreter symlink", "truncate")

LEGACY = [
    (r"(^|\s|;|&&|\|\|)(sudo\s+)?(mkfs|wipefs|dd\s+if=/dev/(zero|urandom|random))", None,
     "destructive disk operation (mkfs/wipefs/dd)"),
    (r"(sudo\s+)?(python[23]?|python3\.[0-9]+)\b", python_deletes, "python deletion targeting a critical path"),
    (r"(sudo\s+)?(python[23]?|python3\.[0-9]+)\b", python_moves_critical, "python move onto or from a critical path"),
    (r"(sudo\s+)?perl\b", r"\b(rmtree|unlink|remove_tree)\b", "perl deletion targeting a critical path"),
    (r"(sudo\s+)?node\b", r"\b(rmSync|unlinkSync|rmdirSync|rimraf)\b", "node deletion targeting a critical path"),
    (r"(sudo\s+)?ruby\b", r"\b(rm_rf|rm_r|delete|remove_entry)\b", "ruby deletion targeting a critical path"),
    (r"(python[23]?|python3\.[0-9]+|perl|node|ruby)\b",
     r"\b(symlink|symlinkSync|make_symlink|symlink_to)\s*(\(|[\"'$@])|\bimport\b[^\n;]*\bsymlink\b|"
     r"\bln_s\b|\bFile\.symlink\b",
     "interpreter symlink onto a critical path"),
    (TRUNCATE_RE, None, "truncate targeting a critical path"),
    (r"cp\s+/dev/(null|zero)\b", None, "overwriting a critical path with /dev/null or /dev/zero"),
    (r"rsync\b.*--delete", None, "rsync --delete targeting a critical path"),
    (r"tar\b.*--remove-files", None, "tar --remove-files targeting a critical path"),
    (r"(sudo\s+)?(chmod|chown)\s.*-R", None, "recursive permission change on a critical path"),
]


# a path word of a command: an absolute path, ~ or $HOME (a quote, = or ( in front of it is no part of it)
PATH_WORD_RE = re.compile(r"""(?:^|[\s'"=(,\[])((?:~|\$\{?HOME\}?|/)[^\s'"`;|&()<>,\[\]]*)""")
# delete rules judged by the resolved path words of the command (hard list), not by the critical names of
# the text: a project folder below /mnt/c or /home is no hard target, the delete setting decides
LITERAL_RULES = ("python deletion", "perl deletion", "node deletion", "ruby deletion", "rsync --delete",
                 "tar --remove-files")


def hard_word_in(text):
    """True when a path word of text is on the hard list (on_hard_list after ~ and $HOME are expanded).

    A word that names another user's home is hard (its path is not known here)."""
    user_home = home()
    for match in PATH_WORD_RE.finditer(text):
        word = match.group(1)
        if word == "~" or word.startswith("~/"):
            word = user_home + word[1:]
        elif word.startswith("~"):
            return True
        elif word.startswith("$"):
            word = re.sub(r"^\$\{?HOME\}?", user_home, word)
        if word.startswith("/") and on_hard_list(os.path.normpath(word)):
            return True
    return False


def check_legacy(cmd):
    crit = re.compile(r"(%s|%s/|%s\b)" % (CRIT, r"~", r"\$\{?HOME\}?"))
    mask = quote_mask(cmd)
    for trigger, extra, reason in LEGACY:
        if reason.startswith(QUOTE_GATED):
            # the verb of the trigger ends it for "truncate" (a prefix comes before), else it starts it
            starts = [m.end() - len("truncate") if reason.startswith("truncate") else m.start()
                      for m in re.finditer(trigger, cmd)]
            if all(mask[start] for start in starts):
                continue
        elif not re.search(trigger, cmd):
            continue
        if extra and not (extra(cmd) if callable(extra) else re.search(extra, cmd)):
            continue
        if reason.startswith("destructive disk") and not any(
                not mask[m.start(3)] for m in re.finditer(trigger, cmd)):
            # a disk tool named inside quoted text (printf '... mkfs ...', echo "dd ...") is text, not a command
            # word; a substitution or a bash -c string is judged by bash-guard.py
            continue
        if reason.startswith(("destructive disk", "python move")):
            raise Deny(reason)
        if "interpreter symlink" in reason:
            if re.search(r"(%s|%s)" % (CRIT, HOME_REF), cmd):
                raise Deny(reason)
            continue
        if reason.startswith(LITERAL_RULES):
            judged = hard_word_in(cmd)
        else:
            judged = crit.search(cmd)
        if judged or re.search(r"(chmod|chown|rsync)\b.*\s/\s*$", cmd):
            raise Deny(reason)
    # a truncating redirect (">", ">|", "&>") onto a critical path; a new file in an ordinary
    # folder (a log below a project) is fine. An append (">>") destroys no content, but onto
    # a shell startup or persistence file or a system tree (~/.bashrc, ~/.config/..., /etc/...)
    # it plants code: the same targets, without the plain files of the home. A ">" inside a quoted
    # string (a commit message, a grep pattern) is text, no redirect.
    for m in re.finditer(r"(?<!>)(>>?)(?!>)\|?\s*(\S+)", cmd):
        if mask[m.start(1)]:
            continue
        # the word ends at the first blank outside quotes ("/mnt/c/Program Files/x"); quotes and
        # escapes inside it are shell syntax, not part of the path ("$HOME"/.bashrc, ~/".bashrc",
        # ~/'.bashrc', $'/etc/hosts'); an unquoted ; | & ( ) < > ends it too ("2>/dev/null; echo")
        end = m.start(2)
        while end < len(cmd) and (mask[end] or not (cmd[end].isspace() or cmd[end] in ";|&()<>")):
            end += 1
        tgt = shell_word(cmd[m.start(2):end])
        if critical_redirect(tgt, append=m.group(1) == ">>"):
            raise Deny("destructive redirect targeting a critical path")


HEREDOC_OP_RE = re.compile(r"<<(-?)[ \t]*(?:'([^'\n]*)'|\"([^\"\n]*)\"|\\?([A-Za-z0-9_.-]+))")
MASK_STOP_RE = re.compile(r"[\\'\"$#<\n()]")


def quote_mask(cmd):
    """A bytearray the length of cmd: 1 for every character that is quoted text or escaped (inside
    '...', "..." with its $(...) and backticks, $'...', $((...)), after a backslash, in a comment), else 0.
    Heredoc bodies are skipped while the quotes are read (an apostrophe in a body opens no quote) and
    are not masked: bash-guard.py already took the data bodies out of the command, what is left is text
    that reaches a shell. A command that cannot be read (an open quote, an unknown heredoc word) gets no
    mask at all: everything counts as unquoted (fail safe)."""
    size = len(cmd)
    mask = bytearray(size)
    pending = []

    class Unbalanced(Exception):
        pass

    def mark(start, end):
        mask[start:end] = b"\x01" * (min(end, size) - start)

    def bodies(i):
        for delimiter, strip in pending:
            while i < size:
                end = cmd.find("\n", i)
                line = cmd[i:] if end < 0 else cmd[i:end]
                i = size if end < 0 else end + 1
                if (line.lstrip("\t") if strip else line) == delimiter:
                    break
        pending.clear()
        return i

    def double(i):
        j = i + 1
        while j < size:
            ch = cmd[j]
            if ch == "\\":
                j += 2
            elif ch == '"':
                mark(i, j + 1)
                return j + 1
            elif cmd.startswith("$((", j):
                k = cmd.find("))", j + 3)
                if k < 0:
                    raise Unbalanced
                j = k + 2
            elif cmd.startswith("$(", j):
                j = code(j + 2, True)
            elif ch == "`":
                k = cmd.find("`", j + 1)
                if k < 0:
                    raise Unbalanced
                j = k + 1
            else:
                j += 1
        raise Unbalanced

    def brace(i):
        """Index after the "}" of the ${...} that starts at i. A parameter expansion is one unit: a "#" or
        a quote inside it is no comment and no quote of the surrounding line (${x// #/y}, ${x%% #*})."""
        j = i + 2
        while j < size:
            ch = cmd[j]
            if ch == "\\":
                mark(j, j + 2)
                j += 2
            elif ch == "'":
                end = cmd.find("'", j + 1)
                if end < 0:
                    raise Unbalanced
                mark(j, end + 1)
                j = end + 1
            elif ch == '"':
                j = double(j)
            elif cmd.startswith("${", j):
                j = brace(j)
            elif cmd.startswith("$((", j):
                end = cmd.find("))", j + 3)
                if end < 0:
                    raise Unbalanced
                mark(j, end + 2)
                j = end + 2
            elif cmd.startswith("$(", j):
                j = code(j + 2, True)
            elif ch == "`":
                end = cmd.find("`", j + 1)
                if end < 0:
                    raise Unbalanced
                j = end + 1
            elif ch == "}":
                return j + 1
            else:
                j += 1
        raise Unbalanced

    def code(i, nested):
        depth = 0
        while i < size:
            found = MASK_STOP_RE.search(cmd, i)
            if not found:
                break
            i = found.start()
            ch = cmd[i]
            if ch == "\\":
                mark(i, i + 2)
                i += 2
            elif ch == "'":
                end = cmd.find("'", i + 1)
                if end < 0:
                    raise Unbalanced
                mark(i, end + 1)
                i = end + 1
            elif ch == '"':
                i = double(i)
            elif cmd.startswith("$'", i):
                end = i + 2
                while end < size and cmd[end] != "'":
                    end += 2 if cmd[end] == "\\" else 1
                if end >= size:
                    raise Unbalanced
                mark(i, end + 1)
                i = end + 1
            elif cmd.startswith("$((", i):
                end = cmd.find("))", i + 3)
                if end < 0:
                    raise Unbalanced
                mark(i, end + 2)
                i = end + 2
            elif cmd.startswith("${", i):
                i = brace(i)
            elif ch == "#":
                if i == 0 or cmd[i - 1] in " \t\n;&|(":
                    end = cmd.find("\n", i)
                    end = size if end < 0 else end
                    mark(i, end)
                    i = end
                else:
                    i += 1
            elif cmd.startswith("<<", i):
                if cmd.startswith("<<<", i):
                    i += 3
                    continue
                op = HEREDOC_OP_RE.match(cmd, i)
                if not op:
                    raise Unbalanced
                word = next(group for group in op.groups()[1:] if group is not None)
                pending.append((word, bool(op.group(1))))
                i = op.end()
            elif ch == "\n":
                i = bodies(i + 1) if pending else i + 1
            elif ch == "(":
                depth += 1
                i += 1
            elif ch == ")":
                if nested and depth == 0:
                    return i + 1
                depth = max(depth - 1, 0)
                i += 1
            else:
                i += 1
        if nested:
            raise Unbalanced
        return size

    try:
        code(0, False)
    except Unbalanced:
        return bytearray(size)
    return mask


# system trees whose files are never truncated (relative to /)
SYSTEM_TREES = {"etc", "usr", "bin", "sbin", "lib", "lib32", "lib64", "libx32", "boot", "opt", "srv", "sys", "proc",
                "snap", "var", "root", "run"}

# what an appended line can hijack inside a home (relative to it): the startup files of the shells and
# of the desktop session, ssh and gpg, autostart and systemd units, scripts on the PATH
HOME_RC_NAMES = (".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".bash_aliases", ".profile", ".zshrc",
                 ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".inputrc", ".xprofile", ".xinitrc", ".xsession",
                 ".pam_environment")
HOME_PERSISTENCE_RE = re.compile(
    r"^(?:%s|\.ssh|\.gnupg|\.config/(?:fish|autostart|systemd|environment\.d)|\.local/bin)(?:/|$)"
    % "|".join(re.escape(name) for name in HOME_RC_NAMES))
# the standard streams are no files; bash-guard.py does not resolve them (realpath leads to /proc/<pid>/fd/...)
STREAM_RE = re.compile(r"^/dev/(?:stdin|stdout|stderr|fd/\d+)$")


def ansi_c(raw):
    """The text of an ANSI-C quoted word ($'...') with its escapes resolved."""
    try:
        return codecs.decode(raw.encode("latin-1", "backslashreplace"), "unicode_escape")
    except (UnicodeError, ValueError):
        return raw


def shell_word(word):
    """A redirect word the way the shell reads it: $'...' decoded, $"..." read as "...", quotes and
    escapes removed ("$HOME"/.bashrc, ~/".bashrc", ~/'.bashrc', $'/etc/hosts')."""
    word = re.sub(r"\$'((?:[^'\\]|\\.)*)'", lambda m: ansi_c(m.group(1)).replace("'", "").replace('"', ""), word)
    return re.sub(r"[\\'\"]", "", word.replace('$"', '"'))


# WSL drives (/mnt/c): what Windows runs or reads at start-up or for every user, below the first levels
WIN_SYSTEM_DIRS = ("windows", "programdata", "program files", "program files (x86)", "programfiles",
                   "system volume information", "$recycle.bin", "recovery")
WIN_POWERSHELL_DIRS = ("powershell", "windowspowershell")
# the folder of the documents (localized for the OneDrive redirect) that holds the PowerShell profile scripts
WIN_DOCUMENTS_DIRS = ("documents", "dokumente")
# an 8.3 short name (PROGRA~1, WINDOW~1): Windows opens the real folder through it
SHORT_NAME_RE = re.compile(r"~\d+(?:\.[^/]*)?$")


def windows_critical(parts, append):
    """True when the path parts of /mnt/<drive>/... name a Windows system, persistence or profile path:
    Windows, ProgramData and Program Files*, below a user AppData (the Startup folder), Start Menu,
    NTUSER.DAT*, Documents/PowerShell and Documents/WindowsPowerShell (the profile scripts, also below
    OneDrive and as Dokumente), and the dot entries of the user (truncating; appending: the startup files of
    HOME_PERSISTENCE_RE). A name in 8.3 short form (PROGRA~1, WINDOW~1) at one of these levels (below the drive,
    below the user, below Documents) counts as critical: it may be the short name of any of them.
    Files below a project (/mnt/c/Users/<name>/workspace/proj/x) are ordinary."""
    names = [part.lower() for part in parts]
    if len(names) > 2 and (names[2] in WIN_SYSTEM_DIRS or names[2].startswith("program files")
                           or SHORT_NAME_RE.search(names[2])):
        return True
    if len(names) < 5 or names[2] != "users":
        return False
    entry = names[4]
    if entry in ("appdata", "start menu") or entry.startswith("ntuser") or SHORT_NAME_RE.search(entry):
        return True
    if any(names[i] in WIN_DOCUMENTS_DIRS and (names[i + 1] in WIN_POWERSHELL_DIRS
                                               or SHORT_NAME_RE.search(names[i + 1]))
           for i in range(4, len(names) - 1)):
        return True
    return bool(HOME_PERSISTENCE_RE.match("/".join(parts[4:]))) if append else parts[4].startswith(".")


def declared_mounts():
    """The mounts the user declares in CLAUDE_MB_DOGMA_PROTECTED_MOUNTS (colon separated), as written
    and resolved. A Windows drive (/mnt/c) is left out: it is covered by windows_critical, so files below
    a project on it stay ordinary."""
    mounts = []
    for point in (os.environ.get("CLAUDE_MB_DOGMA_PROTECTED_MOUNTS") or "").split(":"):
        if not point.startswith("/") or re.fullmatch(r"/mnt/[A-Za-z]/*", point):
            continue
        point = os.path.normpath(point)
        mounts += [point, os.path.realpath(point)]
    return mounts


def declared_mount(path):
    """True when path is a declared protected mount or lies inside one (any depth)."""
    return any(path == mount or path.startswith(mount.rstrip("/") + "/") for mount in declared_mounts())


def critical_redirect(target, append=False, unknown=False):
    """True when truncating target (a literal redirect word) could destroy data that matters.

    append=True (">>"): nothing is destroyed, so only what an appended line could hijack counts:
    the startup and persistence files of a home (HOME_PERSISTENCE_RE: ~/.bashrc, ~/.profile,
    ~/.ssh/..., ~/.config/autostart/...), the system trees (the cron and at spools are below
    /var), devices, /mnt and /media (as below). Everything else passes: plain files of the home,
    /home/X/Y and the other dot folders (~/.cache/x.log, ~/.local/state/..., ~/.claude/...).

    Truncating, critical: / and every first-level directory, the system trees (except /var/tmp),
    the home and its parent, every direct child of the home (~/.bashrc, ~/Documents), everything
    inside a dot folder of a home (~/.config/..., ~/.ssh/..., /home/X/.local/...), /home/X/Y,
    devices (except the harmless ones), /mnt and /media with the drive and the first level below
    it (/mnt, /mnt/c, /mnt/c/Users) and the dot entries of a Windows home
    (/mnt/c/Users/<name>/.ssh/...). Not critical: deeper files in ordinary folders
    (/home/X/project/logs/run.log, /mnt/c/work/project/out.log), /tmp, /var/tmp, files inside the
    Windows user temp folder (/mnt/c/Users/<name>/AppData/Local/Temp/x), the standard
    streams and relative or unresolved words (bash-guard.py resolves those).

    The Windows system and persistence paths below a drive stay critical, truncating and appending
    (windows_critical: /mnt/c/Windows, ProgramData, Program Files*, Users/<name>/AppData, Start Menu,
    NTUSER.DAT, Documents/PowerShell). A mount that the user declares (CLAUDE_MB_DOGMA_PROTECTED_MOUNTS)
    is critical at any depth, truncating and appending (declared_mount; a Windows drive excepted).

    A word with an unresolved variable or substitution is judged by its literal part before the
    first "$": a file name that starts there could be any name, a dot name too (~/$X, ~/.$X,
    /etc/$X); a word that starts with the variable is unknown."""
    m = re.match(r"^(~|\$HOME|\$\{HOME\})(/.*)?$", target)
    if m:
        target = home() + (m.group(2) or "")
    elif target.startswith("~"):
        return True  # another user's home
    unresolved = [position for position in (target.find("$"), target.find("`")) if position >= 0]
    if unresolved:
        literal = target[:min(unresolved)]
        if not literal.startswith("/"):
            return False
        if re.search(r"(^|/)\.\.(/|$)", target[min(unresolved):]):
            return True  # a ".." after the unknown part can climb out of the literal directory
        probes = [literal + "x"] + ([literal + ".x"] if literal.endswith("/") else [])
        if append:
            # the name may still become a startup file (~/.$X, ~/.bash$X, ~/$X)
            partial = literal.rpartition("/")[2]
            probes += [literal[:len(literal) - len(partial)] + name for name in HOME_RC_NAMES
                       if name.startswith(partial)]
        return any(critical_redirect(probe, append, unknown=True) for probe in probes)
    if not target.startswith("/"):
        return False
    path = os.path.normpath(target)
    if STREAM_RE.match(path) or re.match(r"^/dev/(null|tty|zero|random|urandom|pts/\d+)$", path):
        return False
    if path == "/" or depth(path) == 1 or path.startswith("/dev/"):
        return True
    if declared_mount(path):
        return True
    first = path.split("/")[1]
    if first in SYSTEM_TREES and not path.startswith("/var/tmp/"):
        return True
    h = home()
    if path in (h, os.path.dirname(h)) or os.path.dirname(path) == h:
        return not append or path == os.path.dirname(h) or bool(HOME_PERSISTENCE_RE.match(os.path.basename(path)))
    if path.startswith(h + "/"):
        inside = path[len(h) + 1:]
        if append:
            return bool(HOME_PERSISTENCE_RE.match(inside))
        if inside.startswith("."):
            return True
    if path.startswith("/home/"):
        rest = path[len("/home/"):].split("/")
        if append:
            return len(rest) > 1 and bool(HOME_PERSISTENCE_RE.match("/".join(rest[1:])))
        return bool(len(rest) <= 2 or rest[1:2] and rest[1].startswith("."))
    if first in ("mnt", "media"):
        # mounted drives and shares (WSL: /mnt/c): the mount point, the drive and the first level
        # below it, like bash-guard.py; files deeper inside a project there are ordinary files
        parts = path.split("/")[1:]
        if len(parts) <= 3:
            return True
        if not unknown and (temp_root_of(path) or "").endswith("/AppData/Local/Temp"):
            return False  # inside the Windows user temp folder: scratch space (Windows/Temp stays critical)
        if first == "mnt" and windows_critical(parts, append):
            return True
    return False


def check_command(cmd, ctx, nest=0):
    check_time()
    for seg in split_segments(cmd):
        check_time()
        try:
            check_segment(seg, ctx, nest)
        except Unsure:
            pass  # this segment is unsure; the others are still checked (the delete setting decides)


def main():
    if sys.argv[1:2] == ["--temp-only"]:
        # file-protection.sh: findings JSON on stdin, the command's working directory as argument;
        # prints "temp" only when every delete is inside a temp root (see temp_only)
        try:
            if temp_only(json.load(sys.stdin), sys.argv[2] if len(sys.argv) > 2 else ""):
                print("temp")
        except Exception:
            return
        return
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
