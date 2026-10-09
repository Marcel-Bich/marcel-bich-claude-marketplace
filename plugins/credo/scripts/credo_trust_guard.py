#!/usr/bin/env python3
"""credo_trust_guard.py - decide whether a Bash command grants peer trust.

Used by hooks/credo-peer-message.sh (PreToolUse Bash). Reads the command text on
stdin and prints "ask" when the command is recognized as a trust grant, nothing
otherwise. Exit 0 in both cases; any other exit code means "no verdict" and the
hook falls back to its cautious text match.

A command counts as a trust grant when it:
  - runs credo-peer-lan.py (directly, through python3, a wrapper such as sudo or
    env, or through a variable command word such as "$P") with `trust` and later
    `add` among its arguments, or
  - writes, moves, links, truncates, removes or edits in place the trust file
    (basename peer-lan-trust.json, glob and brace forms included): redirection
    target, tee/cp/mv/install/ln/rsync/dd of= destination, sed -i, perl -i,
    truncate, rm, chmod and similar operands, or an operand of a command that is
    not known to be read-only, or
  - feeds interpreter code (python/node/perl/ruby/php -c/-e strings, heredoc
    bodies and here-strings fed to an interpreter) that names the trust file as a
    path literal or calls credo-peer-lan.py with "trust" and "add" arguments.

Mentions are not grants: read-only commands (cat, grep, jq, ls, ...), text in
commit messages, echo strings and heredoc bodies that feed a non-interpreter
(cat, git commit -F -, tee into another file) do not ask. When the command
cannot be parsed, a conservative text check runs on the lines outside heredoc
bodies.

--strict (the hook passes it in strict mode) also fails cautious on obfuscated
forms: arguments of credo-peer-lan.py from a variable, command substitution,
ANSI-C quoting ($'...'), brace expansion or globs; any eval; bash -c with
variable code; globs in a path under a credo dir; a trust file name built from
variables or (in interpreter code) from string pieces next to a write.

This is a best-effort reminder, not a security boundary: the boundary is that
only the user runs trust grants.
"""
import fnmatch
import os
import re
import sys

TRUST_FILE = "peer-lan-trust.json"
LAN_SCRIPT = "credo-peer-lan.py"
MAX_DEPTH = 6
MAX_BRACE_VARIANTS = 64

SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "busybox"}
INTERP_RE = re.compile(
    r"(python[0-9.]*|pypy[0-9.]*|node|nodejs|deno|bun|perl[0-9.]*|ruby[0-9.]*|php[0-9.]*)\Z")
# option that takes the inline code as next argument, per interpreter family
CODE_OPTS = {
    "python": ("-c",),
    "node": ("-e", "--eval", "-p", "--print"),
    "perl": ("-e", "-E"),
    "ruby": ("-e",),
    "php": ("-r",),
}
WRAPPERS = {"sudo", "doas", "env", "nohup", "nice", "ionice", "timeout", "exec",
            "command", "builtin", "time", "stdbuf", "xargs", "setsid", "chrt",
            "taskset", "unbuffer", "caffeinate", "flock"}
WRAPPER_ARG_OPTS = {
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U", "-R"},
    "doas": {"-u", "-C"},
    "env": {"-u", "-C", "-S", "--unset", "--chdir"},
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "-n", "-p", "-t"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "xargs": {"-a", "-d", "-E", "-I", "-L", "-n", "-P", "-s", "--arg-file",
              "--delimiter", "--max-args", "--max-procs", "--replace"},
    "stdbuf": {"-i", "-o", "-e"},
    "flock": {"-w", "-E", "--timeout", "--conflict-exit-code"},
}
RUNNERS = {"uv", "poetry", "pipenv", "pdm", "hatch", "rye", "pipx"}
RESERVED = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until",
            "!", "{", "}", "time", "function", "coproc"}
SKIP_COMMANDS = {"for", "select", "case", "esac", "in"}
READ_ONLY = {
    "cat", "tac", "less", "more", "head", "tail", "grep", "egrep", "fgrep", "rg",
    "ag", "ack", "jq", "yq", "ls", "ll", "stat", "file", "wc", "diff", "cmp",
    "colordiff", "md5sum", "sha1sum", "sha256sum", "sha512sum", "b2sum", "cksum",
    "realpath", "readlink", "basename", "dirname", "test", "[", "[[", "echo",
    "printf", "od", "xxd", "hexdump", "strings", "bat", "batcat", "nl", "sort",
    "uniq", "cut", "tr", "column", "fold", "du", "cd", "pushd", "type", "which",
    "whereis", "true", "false", "base64", "zcat", "view", "lsattr", "getfacl",
    "namei", "tree", "printenv", "fmt", "expand", "comm", "join", "paste", "look",
    "sed", "awk", "gawk", "mawk", "find", "git", "perl",
}
GIT_READ = {"diff", "log", "show", "status", "add", "grep", "blame", "ls-files",
            "check-ignore", "check-attr", "cat-file", "rev-parse", "commit"}
FIND_WRITE = {"-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint",
              "-fprint0", "-fprintf", "-fls"}
COPY_LIKE = {"cp", "install", "rsync", "scp", "ditto", "gcp"}
ANY_OPERAND = {"mv", "ln", "rm", "unlink", "shred", "truncate", "chmod", "chown",
               "chgrp", "touch", "chattr", "setfacl", "tee", "sponge", "srm",
               "trash", "trash-put", "gio", "link", "patch", "mkfifo"}
WRITE_REDIRS = {">", ">>", ">|", "&>", "&>>", "<>", ">&"}

REDIR_RE = re.compile(r"(\d*|\{\w+\})(<<<|<<-|<<|&>>|&>|>>|>\||>&|<&|<>|>|<)")
SIMPLE_EXP_RE = re.compile(r"\$(?:[A-Za-z_]\w*|\{[^}]*\}|\(.*\)|[0-9@*#?$!-])\Z|`.*`\Z", re.S)
VAR_REF_RE = re.compile(r"\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))")
ASSIGN_RE = re.compile(r"([A-Za-z_]\w*)(\+?=)(.*)\Z", re.S)


class ParseError(Exception):
    pass


class Word(object):
    __slots__ = ("raw", "value", "subs", "quoted", "ansi")

    def __init__(self):
        self.raw = ""
        self.value = ""
        self.subs = []
        self.quoted = False
        self.ansi = False

    def is_expansion(self):
        return bool(SIMPLE_EXP_RE.match(self.value))


class Heredoc(object):
    __slots__ = ("delim", "strip", "quoted", "body")

    def __init__(self, delim, strip, quoted):
        self.delim = delim
        self.strip = strip
        self.quoted = quoted
        self.body = None


def find_close(s, i, open_ch="(", close_ch=")"):
    """Index of the bracket that closes the one opened just before i."""
    depth = 1
    n = len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            j = s.find("'", i + 1)
            if j < 0:
                raise ParseError("quote")
            i = j + 1
            continue
        if c == '"':
            i = skip_dquote(s, i + 1)
            continue
        if c == "`":
            j = find_backtick(s, i + 1)
            i = j + 1
            continue
        if c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ParseError("unbalanced")


def skip_dquote(s, i):
    n = len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == '"':
            return i + 1
        if c == "$" and s.startswith("$(", i):
            i = find_close(s, i + 2) + 1
            continue
        if c == "`":
            i = find_backtick(s, i + 1) + 1
            continue
        i += 1
    raise ParseError("dquote")


def find_backtick(s, i):
    n = len(s)
    while i < n:
        if s[i] == "\\":
            i += 2
            continue
        if s[i] == "`":
            return i
        i += 1
    raise ParseError("backtick")


ANSI_ESC = {"n": "\n", "t": "\t", "r": "\r", "a": "", "b": "", "e": "", "E": "",
            "f": "", "v": "", "\\": "\\", "'": "'", '"': '"', "?": "?"}


def ansi_c(text):
    out = []
    i = 0
    while i < len(text):
        c = text[i]
        if c == "\\" and i + 1 < len(text):
            d = text[i + 1]
            if d in ANSI_ESC:
                out.append(ANSI_ESC[d])
                i += 2
                continue
            m = re.match(r"x([0-9A-Fa-f]{1,2})", text[i + 1:])
            if m:
                out.append(chr(int(m.group(1), 16)))
                i += 1 + len(m.group(0))
                continue
            m = re.match(r"([0-7]{1,3})", text[i + 1:])
            if m:
                out.append(chr(int(m.group(1), 8) & 0xFF))
                i += 1 + len(m.group(0))
                continue
            out.append(d)
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


class Lexer(object):
    """Tokens: ("word", Word), ("op", text), ("redir", op, Word|Heredoc)."""

    def __init__(self, s):
        self.s = s
        self.i = 0
        self.tokens = []
        self.pending = []

    def run(self):
        s = self.s
        n = len(s)
        while self.i < n:
            c = s[self.i]
            if c in " \t":
                self.i += 1
                continue
            if c == "\\" and s.startswith("\\\n", self.i):
                self.i += 2
                continue
            if c == "#":
                j = s.find("\n", self.i)
                self.i = n if j < 0 else j
                continue
            if c == "\n":
                self.tokens.append(("op", "\n"))
                self.i += 1
                self.read_heredocs()
                continue
            if s.startswith("<(", self.i) or s.startswith(">(", self.i):
                w = Word()
                j = find_close(s, self.i + 2)
                w.subs.append(s[self.i + 2:j])
                w.raw = w.value = s[self.i:j + 1]
                self.i = j + 1
                self.tokens.append(("word", w))
                continue
            m = REDIR_RE.match(s, self.i)
            if m and self.redir_start(m):
                self.i = m.end()
                op = m.group(2)
                if op in ("<<", "<<-"):
                    self.skip_blanks()
                    w = self.read_word()
                    if w is None:
                        raise ParseError("heredoc delimiter")
                    h = Heredoc(w.value, op == "<<-", w.quoted)
                    self.pending.append(h)
                    self.tokens.append(("redir", op, h))
                else:
                    self.skip_blanks()
                    w = self.read_word()
                    if w is None:
                        raise ParseError("redirection target")
                    self.tokens.append(("redir", op, w))
                continue
            for op in ("&&", "||", ";;&", ";;", ";&", "|&", ";", "&", "|", "(", ")"):
                if s.startswith(op, self.i):
                    self.tokens.append(("op", op))
                    self.i += len(op)
                    break
            else:
                w = self.read_word()
                if w is None:
                    raise ParseError("word")
                self.tokens.append(("word", w))
        if self.pending:
            # unterminated heredoc: bash reads up to end of input
            for h in self.pending:
                if h.body is None:
                    h.body = ""
            self.pending = []
        return self.tokens

    def redir_start(self, m):
        # digits only count as an fd when they start a token
        if m.group(1) and self.i > 0 and self.s[self.i - 1] not in " \t\n;&|()":
            return False
        return True

    def skip_blanks(self):
        while self.i < len(self.s) and self.s[self.i] in " \t":
            self.i += 1

    def read_heredocs(self):
        s = self.s
        for h in self.pending:
            lines = []
            while True:
                if self.i >= len(s):
                    break
                j = s.find("\n", self.i)
                line = s[self.i:] if j < 0 else s[self.i:j]
                self.i = len(s) if j < 0 else j + 1
                check = line.lstrip("\t") if h.strip else line
                if check == h.delim:
                    break
                lines.append(line)
            h.body = "\n".join(lines)
        self.pending = []

    def read_word(self):
        s = self.s
        n = len(s)
        w = Word()
        start = self.i
        val = []
        while self.i < n:
            c = s[self.i]
            if c in " \t\n;&|()<>":
                break
            if c == "\\":
                if self.i + 1 < n:
                    if s[self.i + 1] != "\n":
                        val.append(s[self.i + 1])
                    self.i += 2
                else:
                    self.i += 1
                continue
            if c == "'":
                j = s.find("'", self.i + 1)
                if j < 0:
                    raise ParseError("squote")
                val.append(s[self.i + 1:j])
                w.quoted = True
                self.i = j + 1
                continue
            if c == "$" and s.startswith("$'", self.i):
                j = self.i + 2
                while j < n and s[j] != "'":
                    j += 2 if s[j] == "\\" else 1
                if j >= n:
                    raise ParseError("ansi quote")
                val.append(ansi_c(s[self.i + 2:j]))
                w.quoted = True
                w.ansi = True
                self.i = j + 1
                continue
            if c == '"':
                w.quoted = True
                self.i += 1
                val.append(self.read_dquote(w))
                continue
            if c == "$" and s.startswith("$((", self.i):
                k = s.find("))", self.i + 3)
                if k < 0:
                    raise ParseError("arith")
                val.append(s[self.i:k + 2])
                self.i = k + 2
                continue
            if c == "$" and s.startswith("$(", self.i):
                j = find_close(s, self.i + 2)
                w.subs.append(s[self.i + 2:j])
                val.append(s[self.i:j + 1])
                self.i = j + 1
                continue
            if c == "$" and s.startswith("${", self.i):
                j = find_close(s, self.i + 2, "{", "}")
                val.append(s[self.i:j + 1])
                self.i = j + 1
                continue
            if c == "`":
                j = find_backtick(s, self.i + 1)
                w.subs.append(s[self.i + 1:j].replace("\\`", "`"))
                val.append(s[self.i:j + 1])
                self.i = j + 1
                continue
            val.append(c)
            self.i += 1
        if self.i == start:
            return None
        w.raw = s[start:self.i]
        w.value = "".join(val)
        return w

    def read_dquote(self, w):
        s = self.s
        n = len(s)
        out = []
        while self.i < n:
            c = s[self.i]
            if c == '"':
                self.i += 1
                return "".join(out)
            if c == "\\" and self.i + 1 < n:
                d = s[self.i + 1]
                if d == "\n":
                    pass
                elif d in '$`"\\':
                    out.append(d)
                else:
                    out.append(c + d)
                self.i += 2
                continue
            if c == "$" and s.startswith("$((", self.i):
                k = s.find("))", self.i + 3)
                if k < 0:
                    raise ParseError("arith")
                out.append(s[self.i:k + 2])
                self.i = k + 2
                continue
            if c == "$" and s.startswith("$(", self.i):
                j = find_close(s, self.i + 2)
                w.subs.append(s[self.i + 2:j])
                out.append(s[self.i:j + 1])
                self.i = j + 1
                continue
            if c == "$" and s.startswith("${", self.i):
                j = find_close(s, self.i + 2, "{", "}")
                out.append(s[self.i:j + 1])
                self.i = j + 1
                continue
            if c == "`":
                j = find_backtick(s, self.i + 1)
                w.subs.append(s[self.i + 1:j].replace("\\`", "`"))
                out.append(s[self.i:j + 1])
                self.i = j + 1
                continue
            out.append(c)
            self.i += 1
        raise ParseError("dquote")


class Command(object):
    __slots__ = ("words", "redirs")

    def __init__(self):
        self.words = []
        self.redirs = []


def parse(tokens):
    """List of pipelines, each a list of Command."""
    pipelines = []
    pipe = []
    cmd = Command()

    def end_cmd():
        if cmd.words or cmd.redirs:
            pipe.append(cmd)

    for tok in tokens:
        if tok[0] == "word":
            cmd.words.append(tok[1])
        elif tok[0] == "redir":
            cmd.redirs.append((tok[1], tok[2]))
        else:
            op = tok[1]
            end_cmd()
            cmd = Command()
            if op not in ("|", "|&"):
                if pipe:
                    pipelines.append(pipe)
                pipe = []
    end_cmd()
    if pipe:
        pipelines.append(pipe)
    return pipelines


def brace_expand(text, limit=MAX_BRACE_VARIANTS):
    out = [text]
    for _ in range(8):
        nxt = []
        changed = False
        for t in out:
            m = re.search(r"\{([^{}]*,[^{}]*)\}", t)
            if not m:
                nxt.append(t)
                continue
            changed = True
            for alt in m.group(1).split(","):
                nxt.append(t[:m.start()] + alt + t[m.end():])
        out = nxt[:limit]
        if not changed:
            break
    return out


# Strict mode (the user asked to confirm every grant): fail cautious on obfuscated
# forms that the exact checks cannot resolve. The default quiet mode never asks, so
# the extra caution costs nothing there. Set by decide().
STRICT = False
GLOB_CHARS = "*?["


def unresolved(value):
    return "$" in value or "`" in value


def path_is_trust(value):
    if not value:
        return False
    for v in brace_expand(value):
        v = v.rstrip("/")
        base = v.rsplit("/", 1)[-1]
        dirname = v[:-len(base)]
        if base == TRUST_FILE:
            return True
        if any(ch in base for ch in GLOB_CHARS) and fnmatch.fnmatchcase(TRUST_FILE, base):
            if "tru" in base or "peer" in base or "credo" in dirname:
                return True
        if STRICT:
            # a glob anywhere in a path under the credo state dir, or a name built
            # from a variable next to peer-lan / trust / a credo dir
            if "credo" in dirname and any(ch in v for ch in GLOB_CHARS):
                return True
            if unresolved(v) and ("peer-lan" in v or "trust" in v or "credo" in v):
                return True
    return False


def obfuscated(word):
    """Strict mode: a word whose final value the guard cannot know or that hides its
    text (variable, command substitution, ANSI-C quoting, brace expansion, glob)."""
    v = word.value
    return (word.ansi or unresolved(v) or any(ch in v for ch in GLOB_CHARS)
            or bool(re.search(r"\{[^{}]*,[^{}]*\}", v)))


class Ctx(object):
    def __init__(self):
        self.vars = {}


def substitute(value, ctx):
    def rep(m):
        name = m.group(1) or m.group(2)
        return ctx.vars.get(name, m.group(0))
    return VAR_REF_RE.sub(rep, value)


def word_is_trust(word, ctx):
    value = word if isinstance(word, str) else word.value
    cands = [value, substitute(value, ctx)]
    for v in list(cands):
        if "=" in v:
            cands.append(v.split("=", 1)[1])
    return any(path_is_trust(v) for v in cands)


def has_trust_add(values):
    seen_trust = False
    # split quoted words too ("trust add" as one argument): cautious on purpose
    for v in [part for value in values for part in value.split()]:
        if v == "trust":
            seen_trust = True
        elif seen_trust and v == "add":
            return True
    return False


def is_lan_word(word, ctx):
    v = word.value
    if v.endswith(LAN_SCRIPT) or substitute(v, ctx).endswith(LAN_SCRIPT):
        return True
    if STRICT:
        for cand in brace_expand(v):
            base = cand.rsplit("/", 1)[-1]
            if base == LAN_SCRIPT or (any(ch in base for ch in GLOB_CHARS)
                                      and fnmatch.fnmatchcase(LAN_SCRIPT, base)):
                return True
        if unresolved(v) and "peer" in v:
            return True
    return word.is_expansion() and not (word.quoted and word.raw.startswith("'"))


def interp_family(name):
    m = INTERP_RE.match(name)
    if not m:
        return None
    for fam in ("python", "pypy", "node", "deno", "bun", "perl", "ruby", "php"):
        if name.startswith(fam):
            return {"pypy": "python", "deno": "node", "bun": "node"}.get(fam, fam)
    return None


def strip_wrappers(words):
    """Index of the effective command word after assignments and wrappers."""
    i = 0
    n = len(words)
    while i < n:
        v = words[i].value
        if ASSIGN_RE.match(v) and not words[i].raw.startswith(("'", '"')):
            i += 1
            continue
        base = os.path.basename(v)
        if base in RESERVED:
            i += 1
            continue
        if base in RUNNERS and i + 1 < n and words[i + 1].value in ("run", "exec"):
            i += 2
            while i < n and words[i].value.startswith("-"):
                i += 1
            continue
        if base in WRAPPERS:
            argopts = WRAPPER_ARG_OPTS.get(base, set())
            i += 1
            positional_skip = 1 if base == "timeout" else 0
            while i < n:
                wv = words[i].value
                if wv == "--":
                    i += 1
                    break
                if wv in argopts:
                    i += 2
                    continue
                if wv.startswith("-") and len(wv) > 1:
                    i += 1
                    continue
                if base == "env" and ASSIGN_RE.match(wv):
                    i += 1
                    continue
                if positional_skip:
                    positional_skip -= 1
                    i += 1
                    continue
                if base in ("nice", "ionice", "taskset", "chrt") and re.match(r"[0-9,x-]+\Z", wv):
                    i += 1
                    continue
                if base == "flock" and i + 1 < n:
                    i += 1  # the lock file
                break
            if base == "command" and i < n and words[i - 1].value in ("-v", "-V"):
                return n
            continue
        return i
    return n


class Guard(object):
    def __init__(self):
        self.ctx = Ctx()

    # --- shell ------------------------------------------------------------
    def shell(self, text, depth=0):
        if not text.strip():
            return False
        if depth > MAX_DEPTH:
            return fallback(text)  # too deep to follow: cautious text check
        pipelines = parse(Lexer(text).run())
        for pipe in pipelines:
            for cmd in pipe:
                self.collect_assignments(cmd)
        for pipe in pipelines:
            if self.pipeline(pipe, depth):
                return True
        return False

    def collect_assignments(self, cmd):
        words = cmd.words
        i = 0
        if words and words[0].value in ("export", "declare", "local", "readonly", "typeset"):
            i = 1
        for w in words[i:]:
            m = ASSIGN_RE.match(w.value)
            if m and not w.raw.startswith(("'", '"')):
                self.ctx.vars[m.group(1)] = substitute(m.group(3), self.ctx)
            elif i == 0:
                break

    def pipeline(self, pipe, depth):
        consumer = None
        for cmd in pipe:
            verdict, kind = self.command(cmd, depth)
            if verdict:
                return True
            if kind and consumer is None:
                consumer = kind
        if consumer:
            # data written into a shell or an interpreter on stdin is code
            for cmd in pipe:
                for text in self.stdin_texts(cmd):
                    if self.code(text, consumer, depth + 1):
                        return True
                idx = strip_wrappers(cmd.words)
                if idx < len(cmd.words) and cmd.words[idx].value in ("echo", "printf"):
                    joined = " ".join(w.value for w in cmd.words[idx + 1:])
                    if self.code(joined, consumer, depth + 1):
                        return True
        return False

    def stdin_texts(self, cmd):
        out = []
        for op, target in cmd.redirs:
            if isinstance(target, Heredoc):
                out.append(target.body or "")
            elif op == "<<<":
                out.append(target.value)
        return out

    def code(self, text, kind, depth):
        if kind == "shell":
            try:
                return self.shell(text, depth)
            except ParseError:
                return fallback(text)
        return interp_code(text, self, depth)

    def subs(self, cmd, depth):
        for w in cmd.words:
            for sub in w.subs:
                if self.shell(sub, depth + 1):
                    return True
        for op, target in cmd.redirs:
            if isinstance(target, Heredoc):
                if not target.quoted and target.body:
                    for sub in expansion_subs(target.body):
                        if self.shell(sub, depth + 1):
                            return True
            else:
                for sub in target.subs:
                    if self.shell(sub, depth + 1):
                        return True
        return False

    def command(self, cmd, depth):
        """(asks, stdin_consumer_kind)."""
        if self.subs(cmd, depth):
            return True, None
        for op, target in cmd.redirs:
            if op in WRAPPER_SAFE_DUP and isinstance(target, Word) and re.match(r"[0-9]+-?\Z|-\Z", target.value):
                continue
            if op in WRITE_REDIRS and isinstance(target, Word) and word_is_trust(target, self.ctx):
                return True, None
        words = cmd.words
        idx = strip_wrappers(words)
        if idx >= len(words):
            return False, None
        head = words[idx]
        name = os.path.basename(head.value)
        rest = words[idx + 1:]
        values = [w.value for w in rest]
        if name in SKIP_COMMANDS:
            return False, None

        # credo-peer-lan.py (or a variable command word) with trust ... add
        if is_lan_word(head, self.ctx) and has_trust_add(values):
            return True, None
        if STRICT and is_lan_word(head, self.ctx) and any(obfuscated(w) for w in rest):
            return True, None

        if name == "eval":
            if STRICT:
                return True, None
            text = " ".join(values)
            try:
                return self.shell(text, depth + 1), None
            except ParseError:
                return fallback(text), None

        if name in SHELLS:
            return self.shell_cmd(rest, depth)

        fam = interp_family(name)
        if fam:
            return self.interp_cmd(fam, rest, depth)

        return self.operands(name, rest), None

    def shell_cmd(self, rest, depth):
        i = 0
        while i < len(rest):
            v = rest[i].value
            if v == "-c" or (v.startswith("-") and not v.startswith("--") and "c" in v[1:]):
                if i + 1 < len(rest):
                    text = rest[i + 1].value
                    if STRICT and (rest[i + 1].ansi or unresolved(text)):
                        return True, None
                    try:
                        return self.shell(text, depth + 1), None
                    except ParseError:
                        return fallback(text), None
                return False, None
            if v in ("-s", "-"):
                return False, "shell"
            if v.startswith("-") or v.startswith("+"):
                i += 1
                continue
            # a script file operand: the script runs, its operands are data
            if any(word_is_trust(w, self.ctx) for w in rest[i:]):
                return True, None
            return False, None
        return False, "shell"

    def interp_cmd(self, fam, rest, depth):
        opts = CODE_OPTS.get(fam, ())
        i = 0
        in_place = False
        while i < len(rest):
            v = rest[i].value
            if fam == "perl" and re.match(r"-[a-zA-Z]*i", v):
                in_place = True
            code_opt = None
            if v in opts:
                code_opt = rest[i + 1].value if i + 1 < len(rest) else ""
                i += 2
            elif fam == "python" and v.startswith("-c") and len(v) > 2:
                code_opt = v[2:]
                i += 1
            elif fam == "perl" and re.match(r"-[a-zA-Z]*[eE]\Z", v):
                code_opt = rest[i + 1].value if i + 1 < len(rest) else ""
                i += 2
            if code_opt is not None:
                if STRICT and unresolved(code_opt) and re.match(r"\s*[\"']?\$", code_opt):
                    return True, None
                if interp_code(code_opt, self, depth + 1):
                    return True, None
                # code given inline: remaining words are its argv
                if any(word_is_trust(w, self.ctx) for w in rest[i:]) and (in_place or fam != "perl"):
                    return True, None
                return False, None
            if v == "-m" and fam == "python":
                # python -m module args: args may name files the module writes
                return any(word_is_trust(w, self.ctx) for w in rest[i + 1:]), None
            if v == "-":
                return False, fam
            if v.startswith("-"):
                i += 1
                continue
            script = rest[i]
            args = [w.value for w in rest[i + 1:]]
            if is_lan_word(script, self.ctx) and has_trust_add(args):
                return True, None
            if STRICT and is_lan_word(script, self.ctx) and any(obfuscated(w) for w in rest[i + 1:]):
                return True, None
            if any(word_is_trust(w, self.ctx) for w in rest[i + 1:]):
                return True, None
            return False, None
        return False, fam

    def operands(self, name, rest):
        values = [w.value for w in rest]
        ops = [w for w in rest if not (w.value.startswith("-") and len(w.value) > 1)]
        if name == "dd":
            return any(v.startswith("of=") and path_is_trust(substitute(v[3:], self.ctx))
                       for v in values)
        if name in COPY_LIKE:
            target_dir = None
            for j, v in enumerate(values):
                if v in ("-t", "--target-directory") and j + 1 < len(values):
                    target_dir = values[j + 1]
                elif v.startswith("--target-directory="):
                    target_dir = v.split("=", 1)[1]
            if not ops:
                return False
            dest = target_dir if target_dir is not None else ops[-1].value
            srcs = ops if target_dir is not None else ops[:-1]
            if word_is_trust(dest, self.ctx):
                return True
            dest_s = substitute(dest, self.ctx)
            dir_like = (target_dir is not None or dest_s.endswith("/") or dest_s in (".", "..", "~")
                        or "." not in dest_s.rsplit("/", 1)[-1])
            return dir_like and any(word_is_trust(w, self.ctx) for w in srcs)
        if name in ANY_OPERAND:
            return any(word_is_trust(w, self.ctx) for w in rest)
        if name == "sed":
            if any(v == "-i" or v.startswith("--in-place") or re.match(r"-[a-zA-Z]*i", v)
                   for v in values if v.startswith("-") and not v.startswith("--e")):
                return any(word_is_trust(w, self.ctx) for w in rest)
            return False
        if name == "perl":
            return False
        if name in ("awk", "gawk", "mawk"):
            prog = next((w.value for w in rest if not w.value.startswith("-")), "")
            if ">" in prog or "system" in prog or "-i" in values:
                return any(word_is_trust(w, self.ctx) for w in rest)
            return False
        if name == "find":
            if any(v in FIND_WRITE for v in values):
                return any(word_is_trust(w, self.ctx) for w in rest)
            return False
        if name == "git":
            sub = next((v for v in values if not v.startswith("-")), "")
            if sub in GIT_READ:
                return False
            return any(word_is_trust(w, self.ctx) for w in rest)
        if name in READ_ONLY:
            return False
        # unknown command: an operand that names the trust file may be written
        return any(word_is_trust(w, self.ctx) for w in rest)


WRAPPER_SAFE_DUP = {">&", "<&"}


def expansion_subs(text):
    """$(...) and `...` bodies inside an unquoted-delimiter heredoc body."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        try:
            if text.startswith("$((", i):
                k = text.find("))", i + 3)
                i = n if k < 0 else k + 2
                continue
            if text.startswith("$(", i):
                j = find_close(text, i + 2)
                out.append(text[i + 2:j])
                i = j + 1
                continue
            if c == "`":
                j = find_backtick(text, i + 1)
                out.append(text[i + 1:j])
                i = j + 1
                continue
        except ParseError:
            return out
        i += 1
    return out


# --- interpreter code -------------------------------------------------------
PATH_LITERAL_RE = re.compile(
    r"/" + re.escape(TRUST_FILE) + r"(?![\w.-])|([\"'`])" + re.escape(TRUST_FILE) + r"\1")
# list-form argv: "trust", <options or names>, "add"
LIST_GRANT_RE = re.compile(
    r"([\"'])trust\1(?:\s*,\s*(?:\"[^\"\n]{0,80}\"|'[^'\n]{0,80}'|[\w.\[\]()]{1,80})){0,8}?"
    r"\s*,\s*([\"'])add\2")
STRING_LIT_RE = re.compile(r"\"\"\"(.*?)\"\"\"|'''(.*?)'''|\"((?:\\.|[^\"\\\n])*)\"|'((?:\\.|[^'\\\n])*)'|`([^`]*)`",
                           re.S)
SHELL_GRANT_RE = re.compile(
    r"\A\s*(?:\S*(?:python|pypy)[0-9.]*\s+(?:-\S+\s+)*)?(?:\S*" + re.escape(LAN_SCRIPT)
    + r"|[\"']?\$\{?\w+\}?[\"']?)\s+(?:\S+\s+)*?trust\s+(?:\S+\s+)*?add(?:\s|\Z)")


WRITE_HINT_RE = re.compile(
    r"([\"'])(?:w|a|x|wb|ab|xb|w\+|a\+|r\+)\1|\.write\b|write_text|write_bytes|writeFile"
    r"|appendFile|createWriteStream|os\.(?:replace|rename|remove|unlink|open)|shutil\."
    r"|\bunlink\b|\brename\b|O_WRONLY|O_RDWR|O_CREAT|truncate|open\s*\(?[^)\n]*[\"']\s*\+?>")
EXEC_HINT_RE = re.compile(r"subprocess|os\.system|\bsystem\s*\(|\bexec\w*\s*\(|spawn|popen|Popen|`")


def interp_code(code, guard=None, depth=0):
    if PATH_LITERAL_RE.search(code):
        return True
    if LIST_GRANT_RE.search(code):
        return True
    for m in STRING_LIT_RE.finditer(code):
        lit = next(g for g in m.groups() if g is not None)
        if LAN_SCRIPT in lit or "$" in lit:
            if SHELL_GRANT_RE.search(lit):
                return True
    if STRICT:
        # the trust file name built from pieces ('peer-lan-' + 'tru' 'st.json') next
        # to a write: the full name never appears, so the literal check cannot see it
        if "peer-lan" in code and TRUST_FILE not in code and WRITE_HINT_RE.search(code):
            return True
        # credo-peer-lan.py run from code with an "add" argument and trust split up
        if ("peer-lan" in code and EXEC_HINT_RE.search(code)
                and re.search(r"([\"'])add\1", code) and "trust" not in code):
            return True
    return False


# --- fallback for unparsable input --------------------------------------------
HEREDOC_START_RE = re.compile(r"<<-?\s*(?:'([^']+)'|\"([^\"]+)\"|\\?([A-Za-z_][\w-]*))")
LINE_GRANT_RE = re.compile(
    r"(?:" + re.escape(LAN_SCRIPT) + r"|\$\{?\w+\}?)\S*\s+(?:\S+\s+)*?trust\s+(?:\S+\s+)*?add(?:\s|\Z)")


def strip_heredoc_bodies(text):
    out = []
    lines = text.split("\n")
    pending = []
    for line in lines:
        if pending:
            delim, strip = pending[0]
            if (line.lstrip("\t") if strip else line) == delim:
                pending.pop(0)
            continue
        out.append(line)
        for m in HEREDOC_START_RE.finditer(line):
            delim = m.group(1) or m.group(2) or m.group(3)
            pending.append((delim, m.group(0).startswith("<<-")))
    return out


def fallback(text):
    for line in strip_heredoc_bodies(text):
        if PATH_LITERAL_RE.search(line):
            return True
        if re.search(r"(?:^|[\s=<>])(?:\S*/)?" + re.escape(TRUST_FILE) + r"(?![\w.-])", line) \
                and re.search(r">|\b(cp|mv|tee|install|ln|rsync|dd|sed|perl|truncate|rm|chmod)\b", line):
            return True
        flat = re.sub(r"[\"'\\]", "", line)
        if LINE_GRANT_RE.search(flat):
            return True
    return False


def decide(text, strict=False):
    global STRICT
    STRICT = bool(strict)
    try:
        return Guard().shell(text)
    except ParseError:
        return fallback(text)
    except RecursionError:
        return fallback(text)


def main():
    data = sys.stdin.read()
    try:
        ask = decide(data, strict="--strict" in sys.argv[1:])
    except Exception:  # never crash into "no ask" silently: let the hook fall back
        return 3
    if ask:
        sys.stdout.write("ask\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
