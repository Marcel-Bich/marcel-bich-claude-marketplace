#!/usr/bin/env python3
"""credo-inline-guard.py - deny oversized inline interpreter code (PreToolUse, stdlib only).

Long inline code (python3 -c "...", node -e "...", a heredoc fed to an interpreter, a
long Playwright browser_run_code blob) cannot be reviewed by the permission layer and
often stalls an unattended run on a prompt. This guard denies such a call when the inline
code of ONE interpreter invocation is longer than the limit (default 1500 characters) and
names the alternative: Write the code to a script file, run it in a separate call with a
literal path (browser_run_code: the filename parameter).

Only the size counts. Short code, also multi-line, always passes. Never hit:
  - commands without interpreter code (git commit -m with a long message, long pipes)
  - heredocs into files or non-interpreters (cat > f <<EOF), heredocs fed to an
    interpreter that runs a script file (python3 tool.py <<EOF is data, not code)

Detected (per simple command, after env assignments and wrappers like sudo, env, nice,
timeout, taskset, nohup, time, command, exec):
  python*/py/pypy -c CODE    node/nodejs/bun -e|-p|--eval|--print CODE    deno eval CODE
  perl/ruby -e CODE (also clusters like -ne, -lpe)    php -r CODE
  bash/sh/zsh/dash -c STRING (also -lc)    powershell/pwsh -Command|-c TEXT (the rest of the
  line; -EncodedCommand and -File are not inline text). These strings are only measured,
  never parsed again.
  an interpreter reading its program from stdin (no script operand, or "-") with a
  heredoc (<<EOF) or here-string (<<<) body, also through "cat <<EOF | python3" and
  "echo/printf ... | python3"
  $(...) command substitutions are parsed the same way.

Limit: env CREDO_INLINE_CODE_MAX (non-empty) > credo config guards.inline_code_max
(credo-config.sh) > 1500. 0 or a negative value switches the guard off. The config is only
read for code over 1500 characters, so normal commands and short code cost no config read
(a config value below 1500 therefore only matters for code over 1500; the env override
applies at any size). browser_run_code with a non-empty filename is not checked.

Failure-safe: any parse error, unknown input, unreadable or invalid limit -> allow (exit 0,
no output). The guard never blocks because of its own error.

Usage: credo-inline-guard.py < hook-input.json       (PreToolUse hook)
       credo-inline-guard.py --measure < input.json  (prints the largest inline code size)
"""
import json
import os
import re
import subprocess
import sys

DEFAULT_LIMIT = 1500
MAX_INPUT = 4 * 1024 * 1024

SEPARATORS = {";", "&", "&&", "|", "||", "|&", "\n", "(", ")", ";;"}
# words that keep the next word in command position
PREFIX_WORDS = {"{", "}", "!", "then", "do", "else", "elif", "if", "while", "until", "time", "in"}
# wrapper command -> short options that take a value
WRAPPERS = {
    "sudo": {"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T"},
    "env": {"-u", "-C", "-S"},
    "nice": {"-n"},
    "ionice": {"-c", "-n", "-p"},
    "nohup": set(),
    "exec": {"-a"},
    "command": set(),
    "builtin": set(),
    "stdbuf": {"-i", "-o", "-e"},
    "timeout": {"-s", "-k"},
    "taskset": set(),
    "chrt": set(),
}
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=")
PYTHON_RE = re.compile(r"^(python(\d+(\.\d+)*)?[tw]?|py|pypy\d*)$")
PY_NOARG_FLAGS = set("bBdEhiIOPqRsSuvx")
SHELLS = {"bash", "sh", "zsh", "dash"}
# PowerShell parameters that take a value (lowercase, without the dash)
PS_VALUED = {"executionpolicy", "ep", "ex", "windowstyle", "w", "outputformat", "of", "o",
             "inputformat", "if", "i", "workingdirectory", "wd", "configurationname", "config",
             "settingsfile", "settings", "psconsolefile", "version", "v", "custompipename"}


class Simple(object):
    """One simple command: words, heredoc bodies, here-strings, piped to the next one."""

    def __init__(self):
        self.words = []
        self.heredocs = []
        self.herestrings = []
        self.redirects = []     # (operator, target word) of file redirects, e.g. (">>", "/tmp/x")
        self.piped = False


COND_PREFIX = ("if", "elif", "while", "until", "then", "else", "do", "!", "{", "time")


def in_cond(words):
    """True while the words so far open a [[ ... ]] at command position (after keywords or !)."""
    k = 0
    while k < len(words) and words[k] in COND_PREFIX:
        k += 1
    return k < len(words) and words[k] == "[[" and "]]" not in words[k + 1:]


class Parser(object):
    """A small bash lexer: quotes, escapes, comments, $(...), backticks, heredocs."""

    def __init__(self, text):
        self.s = text
        self.n = len(text)
        self.commands = []      # all simple commands, nested substitutions included
        self.pending = []       # heredocs waiting for the next newline: (delimiter, strip_tabs, Simple)

    # --- driver -------------------------------------------------------------
    def parse(self, pos=0, closer=None):
        cur = Simple()
        word = None             # None: no word started; else the collected text
        expect_redirect = None  # "target", "heredoc" or "herestring": the next word is not an argument
        redir_op = [""]         # the operator of the pending "target" redirect
        i = pos

        def finish_word():
            nonlocal word, expect_redirect
            if word is None:
                return
            if expect_redirect == "heredoc":
                self.pending.append((word, strip_tabs[0], cur))
            elif expect_redirect == "herestring":
                cur.herestrings.append(word)
            elif expect_redirect == "target":
                cur.redirects.append((redir_op[0], word))
            else:
                cur.words.append(word)
            expect_redirect = None
            word = None

        def finish_command(piped=False):
            nonlocal cur
            finish_word()
            if cur.words or cur.heredocs or cur.herestrings or any(p[2] is cur for p in self.pending):
                cur.piped = piped
                self.commands.append(cur)
            cur = Simple()

        strip_tabs = [False]
        while i < self.n:
            c = self.s[i]
            if closer and c == closer:
                finish_command()
                return i + 1
            if c == "\\":
                if i + 1 < self.n and self.s[i + 1] == "\n":
                    i += 2
                    continue
                word = (word or "") + self.s[i + 1:i + 2]
                i += 2
                continue
            if c == "'":
                end = self.s.index("'", i + 1)
                word = (word or "") + self.s[i + 1:end]
                i = end + 1
                continue
            if c == "$" and self.s[i + 1:i + 2] == "'":
                end = self._ansi_end(i + 2)
                word = (word or "") + self.s[i + 2:end]
                i = end + 1
                continue
            if c == '"':
                text, i = self._double(i + 1)
                word = (word or "") + text
                continue
            if c == "$" and self.s[i + 1:i + 2] == "(":
                start = i
                if self.s[i + 2:i + 3] == "(":
                    i = self._skip_balanced(i + 3, "(", ")") + 1
                    i = i + 1 if self.s[i:i + 1] == ")" else i
                else:
                    i = self.parse(i + 2, ")")
                word = (word or "") + self.s[start:i]
                continue
            if c == "$" and self.s[i + 1:i + 2] == "{":
                end = self._skip_balanced(i + 2, "{", "}")
                word = (word or "") + self.s[i:end + 1]
                i = end + 1
                continue
            if c == "`":
                end = self._backtick_end(i + 1)
                word = (word or "") + self.s[i:end + 1]
                i = end + 1
                continue
            if c == "#" and word is None:
                nl = self.s.find("\n", i)
                i = self.n if nl < 0 else nl
                continue
            if c == "\n":
                finish_command()
                i = self._read_heredocs(i + 1)
                continue
            if c in " \t\r":
                finish_word()
                i += 1
                continue
            if c in "<>" and expect_redirect is None and word != "]]" and in_cond(cur.words) \
                    and not self.s.startswith(("<(", ">("), i):
                # inside [[ ... ]] a lone < or > is a string comparison, not a redirect
                finish_word()
                cur.words.append(c)
                i += 1
                continue
            if c in "<>":
                if word is not None and word.isdigit() and expect_redirect is None:
                    word = None  # fd number of the redirect
                finish_word()
                if self.s.startswith("<<<", i):
                    expect_redirect = "herestring"
                    i += 3
                elif self.s.startswith("<<", i):
                    strip_tabs[0] = self.s.startswith("<<-", i)
                    expect_redirect = "heredoc"
                    i += 3 if strip_tabs[0] else 2
                elif self.s.startswith("<(", i) or self.s.startswith(">(", i):
                    i = self.parse(i + 2, ")")
                else:
                    expect_redirect = "target"
                    start = i
                    i += 1
                    while i < self.n and self.s[i] in ">&|":
                        i += 1
                    redir_op[0] = self.s[start:i]
                continue
            if c in ";&|()":
                if c == "&" and self.s[i + 1:i + 2] == ">":
                    finish_word()
                    expect_redirect = "target"
                    start = i
                    i += 2
                    while i < self.n and self.s[i] in ">":
                        i += 1
                    redir_op[0] = self.s[start:i]
                    continue
                two = self.s[i:i + 2]
                op = two if two in ("&&", "||", "|&", ";;") else c
                if c == "(" and word is not None:
                    # function definition "name()" or an array: keep the text
                    word += c
                    i += 1
                    continue
                finish_command(piped=op in ("|", "|&"))
                if c == "(":
                    i = self.parse(i + 1, ")")
                    continue
                i += len(op)
                continue
            word = (word or "") + c
            i += 1
        finish_command()
        if closer:
            return self.n
        return i

    # --- helpers ------------------------------------------------------------
    def _ansi_end(self, i):
        while i < self.n:
            if self.s[i] == "\\":
                i += 2
                continue
            if self.s[i] == "'":
                return i
            i += 1
        raise ValueError("unterminated $'")

    def _double(self, i):
        out = []
        while i < self.n:
            c = self.s[i]
            if c == '"':
                return "".join(out), i + 1
            if c == "\\" and i + 1 < self.n:
                nxt = self.s[i + 1]
                out.append(nxt if nxt in '$`"\\\n' else c + nxt)
                i += 2
                continue
            if c == "$" and self.s[i + 1:i + 2] == "(":
                start = i
                if self.s[i + 2:i + 3] == "(":
                    i = self._skip_balanced(i + 3, "(", ")") + 1
                    i = i + 1 if self.s[i:i + 1] == ")" else i
                else:
                    i = self.parse(i + 2, ")")
                out.append(self.s[start:i])
                continue
            if c == "`":
                end = self._backtick_end(i + 1)
                out.append(self.s[i:end + 1])
                i = end + 1
                continue
            out.append(c)
            i += 1
        raise ValueError("unterminated double quote")

    def _backtick_end(self, i):
        while i < self.n:
            if self.s[i] == "\\":
                i += 2
                continue
            if self.s[i] == "`":
                return i
            i += 1
        raise ValueError("unterminated backtick")

    def _skip_balanced(self, i, opener, closer):
        depth = 1
        while i < self.n:
            c = self.s[i]
            if c == "\\":
                i += 2
                continue
            if c == "'":
                i = self.s.index("'", i + 1) + 1
                continue
            if c == opener:
                depth += 1
            elif c == closer:
                depth -= 1
                if depth == 0:
                    return i
            i += 1
        raise ValueError("unbalanced " + opener)

    def _read_heredocs(self, i):
        """Consume the bodies of the heredocs started on the line that just ended."""
        while self.pending:
            delim, strip, owner = self.pending.pop(0)
            lines = []
            while True:
                if i >= self.n:
                    owner.heredocs.append("\n".join(lines))
                    return i
                nl = self.s.find("\n", i)
                line = self.s[i:] if nl < 0 else self.s[i:nl]
                i = self.n if nl < 0 else nl + 1
                check = line.lstrip("\t") if strip else line
                if check.rstrip("\r") == delim:
                    break
                lines.append(line)
            owner.heredocs.append("\n".join(lines))
        return i


def basename(word):
    name = word.replace("\\", "/").rsplit("/", 1)[-1]
    lower = name.lower()
    if lower.endswith(".exe"):
        name = name[:-4]
    return name


def strip_prefix(words):
    """Drop env assignments, structural words and wrappers in front of the command word."""
    i = 0
    while i < len(words):
        w = words[i]
        if ASSIGN_RE.match(w) or w in PREFIX_WORDS:
            i += 1
            continue
        name = basename(w)
        if name in WRAPPERS:
            valued = WRAPPERS[name]
            i += 1
            positional = 1 if name in ("timeout", "chrt") else 0
            if name == "taskset":
                positional = 1
            while i < len(words):
                a = words[i]
                if a == "--":
                    i += 1
                    break
                if name == "taskset" and a in ("-c", "--cpu-list"):
                    positional = 1
                    i += 1
                    continue
                if a.startswith("-") and len(a) > 1:
                    i += 2 if a in valued else 1
                    continue
                if ASSIGN_RE.match(a) and name in ("env", "sudo"):
                    i += 1
                    continue
                if positional:
                    positional -= 1
                    i += 1
                    continue
                break
            continue
        break
    return words[i:]


def shell_code(args):
    """The command string of bash/sh/zsh/dash -c (also clusters like -lc), else None.

    Only its size is measured; the string is not parsed again."""
    has_c = False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            i += 1
            break
        if a in ("-o", "+o", "-O", "+O"):
            i += 2
            continue
        if a.startswith("--"):
            i += 1
            continue
        if len(a) > 1 and a[0] in "-+":
            if a[0] == "-" and "c" in a[1:]:
                has_c = True
            i += 1
            continue
        break
    if not has_c or i >= len(args):
        return None
    return args[i]


def powershell_code(args):
    """The text after -Command/-c of powershell or pwsh (the rest of the line), else None.

    -EncodedCommand and -File are not inline text here; only the size is measured."""
    i = 0
    while i < len(args):
        a = args[i]
        if not a or a[0] not in "-/":
            return None
        bare = a.lstrip("-/").lower()
        if bare == "c" or len(bare) >= 3 and "command".startswith(bare):
            rest = args[i + 1:]
            if not rest or rest == ["-"]:
                return None
            return " ".join(rest)
        if bare in PS_VALUED:
            i += 2
            continue
        if bare in ("file", "f", "encodedcommand", "e", "ec", "enc"):
            return None
        i += 1
    return None


def inline_code(words):
    """(code or None, reads_stdin_program) for one command word list (prefix stripped)."""
    if not words:
        return None, False
    name = basename(words[0])
    args = words[1:]
    if PYTHON_RE.match(name):
        i = 0
        while i < len(args):
            a = args[i]
            if a == "-":
                return None, True
            if a == "--" or not a.startswith("-"):
                return None, False
            if a in ("-m",) or a.startswith("-m"):
                return None, False
            if a in ("-W", "-X"):
                i += 2
                continue
            if a.startswith("--"):
                i += 1
                continue
            body = a[1:]
            pos = body.find("c")
            if pos >= 0 and all(ch in PY_NOARG_FLAGS for ch in body[:pos]):
                rest = body[pos + 1:]
                if rest:
                    return rest, False
                return (args[i + 1] if i + 1 < len(args) else None), False
            i += 1
        return None, True
    if name in ("node", "nodejs", "bun"):
        i = 0
        while i < len(args):
            a = args[i]
            if name == "bun" and a in ("run", "x", "install", "add", "test", "build"):
                return None, False
            if a in ("-e", "--eval", "-p", "--print", "-pe"):
                return (args[i + 1] if i + 1 < len(args) else None), False
            for flag in ("--eval=", "--print="):
                if a.startswith(flag):
                    return a[len(flag):], False
            if a == "-":
                return None, True
            if a == "--" or not a.startswith("-"):
                return None, False
            if a in ("-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions"):
                i += 2
                continue
            i += 1
        return None, name != "bun"
    if name == "deno":
        if args[:1] == ["eval"]:
            rest = [a for a in args[1:] if not a.startswith("-")]
            return (rest[0] if rest else None), False
        return None, False
    if name in ("perl", "ruby"):
        i = 0
        while i < len(args):
            a = args[i]
            if a == "-":
                return None, True
            if a == "--" or not a.startswith("-"):
                return None, False
            if re.match(r"^-[A-Za-z0-9]*[eE]$", a):
                return (args[i + 1] if i + 1 < len(args) else None), False
            i += 1
        return None, True
    if name in SHELLS:
        return shell_code(args), False
    if name.lower() in ("powershell", "pwsh"):
        return powershell_code(args), False
    if name == "php":
        i = 0
        while i < len(args):
            a = args[i]
            if a == "-r":
                return (args[i + 1] if i + 1 < len(args) else None), False
            if a.startswith("-r") and len(a) > 2:
                return a[2:], False
            if a == "--" or not a.startswith("-"):
                return None, False
            i += 1
        return None, True
    return None, False


def interpreter_name(words):
    if not words:
        return ""
    return basename(words[0])


def measure_bash(command):
    """Largest inline code size and the interpreter it belongs to."""
    parser = Parser(command)
    parser.parse()
    best = (0, "")
    cmds = parser.commands
    for idx, cmd in enumerate(cmds):
        words = strip_prefix(cmd.words)
        code, stdin_program = inline_code(words)
        name = interpreter_name(words)
        sizes = []
        if code is not None:
            sizes.append(len(code))
        elif stdin_program:
            sizes.extend(len(body) for body in cmd.heredocs)
            sizes.extend(len(body) for body in cmd.herestrings)
            # the program arrives through a pipe: the previous command's heredoc or echo text
            prev = cmds[idx - 1] if idx > 0 else None
            if prev is not None and prev.piped:
                pwords = strip_prefix(prev.words)
                feeder = interpreter_name(pwords)
                if feeder == "cat" and len(pwords) == 1:
                    sizes.extend(len(body) for body in prev.heredocs)
                    sizes.extend(len(body) for body in prev.herestrings)
                elif feeder in ("echo", "printf"):
                    text = [w for w in pwords[1:] if not w.startswith("-")]
                    sizes.append(len(" ".join(text)))
        for size in sizes:
            if size > best[0]:
                best = (size, name)
    return best


def is_run_code(tool_name):
    return tool_name.endswith("browser_run_code") or tool_name.endswith("browser_run_code_unsafe")


def resolve_limit(session_id, size):
    """The limit that applies to code of this size, or None (allow: guard off, limit unusable,
    or code within the default floor). The config is read only for code over the default
    limit (credo-config.sh costs about 100 ms), so a config value below 1500 takes effect only
    for code over 1500; the env override applies at any size."""
    raw = os.environ.get("CREDO_INLINE_CODE_MAX", "")
    if raw.strip() == "":
        if size <= DEFAULT_LIMIT:
            return None
        raw = config_limit(session_id)
    if raw is None:
        return DEFAULT_LIMIT
    try:
        value = int(str(raw).strip())
    except ValueError:
        return None
    return value if value > 0 else None


def config_limit(session_id):
    """guards.inline_code_max from credo-config.sh; None when absent or unreadable."""
    here = os.path.dirname(os.path.abspath(__file__))
    script = os.path.join(here, "credo-config.sh")
    if not os.path.isfile(script):
        return None
    try:
        sys.path.insert(0, here)
        from credo_platform import bash_exe
        bash = bash_exe()
    except Exception:
        bash = "bash"
    env = dict(os.environ)
    if session_id and re.match(r"^[A-Za-z0-9._-]+$", session_id):
        env["CREDO_SESSION_ID"] = session_id
    env["CREDO_SKIP_ENSURE"] = "1"
    try:
        res = subprocess.run([bash, script, "get", "guards.inline_code_max"], capture_output=True,
                             text=True, timeout=8, env=env, stdin=subprocess.DEVNULL)
    except Exception:
        return None
    if res.returncode != 0:
        return None
    out = res.stdout.strip()
    return out if out else None


def deny(reason):
    sys.stdout.write(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny",
        "permissionDecisionReason": reason}}) + "\n")


def main():
    measure_only = "--measure" in sys.argv[1:]
    raw = sys.stdin.read(MAX_INPUT + 1)
    if not raw or len(raw) > MAX_INPUT:
        return
    event = json.loads(raw)
    if not isinstance(event, dict):
        return
    tool = event.get("tool_name") or ""
    tool_input = event.get("tool_input")
    if not isinstance(tool, str) or not isinstance(tool_input, dict):
        return
    if tool == "Bash":
        command = tool_input.get("command")
        if not isinstance(command, str) or not command:
            return
        size, name = measure_bash(command)
        kind = "bash"
    elif is_run_code(tool):
        code = tool_input.get("code")
        filename = tool_input.get("filename")
        if not isinstance(code, str) or isinstance(filename, str) and filename.strip():
            return  # with a filename Playwright runs the file and ignores code
        size, name, kind = len(code), "browser_run_code", "playwright"
    else:
        return
    if measure_only:
        sys.stdout.write("%d %s\n" % (size, name))
        return
    if size <= 0:
        return
    session_id = event.get("session_id") if isinstance(event.get("session_id"), str) else ""
    limit = resolve_limit(session_id, size)
    if limit is None or size <= limit:
        return
    if kind == "playwright":
        deny("credo: this browser_run_code call carries %d characters of inline code, over the limit of %d "
             "(guards.inline_code_max). Not a ban on the work, only on the oversized call: huge inline code is "
             "error-prone and often stopped by hooks. Either split it into several smaller browser_run_code "
             "calls (allowed), or Write the code to a .js file in the session TMPDIR/scratchpad and pass its "
             "path in the filename parameter instead of code.%s" % (size, limit, cleanup_hint()))
        return
    deny("credo: this command carries %d characters of inline %s code, over the limit of %d "
         "(guards.inline_code_max). Not a ban on the work, only on the oversized command: huge inline code is "
         "error-prone and often stopped by hooks. Do the same work one of these ways: (a) split it into several "
         "smaller commands (allowed); (b) Write the code to a script file (.py/.sh/.js/.ps1) in the session "
         "TMPDIR (or scratchpad) with the Write tool, then run it in a SEPARATE call with a literal path (for example "
         "python3 /path/to/scratchpad/check.py; PowerShell from WSL: powershell.exe -File \"$(wslpath -w "
         "/path/to/scratchpad/check.ps1)\"). Do not write and run the file in the same command, and do not call "
         "it through a variable.%s" % (size, name or "interpreter", limit, cleanup_hint()))


def cleanup_hint():
    """The own-rm line for throwaway scripts, with the literal helper path."""
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "credo-cleanup.py")
    return (" Put throwaway scripts into the session TMPDIR ($TMPDIR, normally /tmp/credo-tmp-<uid>/<session "
            "id>/) and delete each one once it is no longer needed with: python3 %s own-rm <literal path> "
            "(no prompt for files of this session, a file changed in the last 2 minutes is only reported and "
            "the done-gate purge takes it later)." % helper)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
