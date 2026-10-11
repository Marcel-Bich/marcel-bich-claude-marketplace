#!/usr/bin/env python3
# hydra worktree guard - PreToolUse logic, called by hooks/worktree-guard.sh.
#
# While hydra is installed and the "use Hydra for 2+ independent tasks" checkbox of the
# "### Hydra" subsection of DOGMA-PERMISSIONS.md is on (a missing checkbox or file counts
# as on), every worktree goes through hydra's create flow. Denied:
#   - Agent / Task tool calls with tool_input.isolation == "worktree"
#   - EnterWorktree calls without a path (they create a worktree under .claude/worktrees/;
#     with a path they enter an existing worktree and create nothing)
#   - Bash `git worktree add` in command position whose destination is not
#     <repo-parent>/<repo>-worktrees/<name> next to the main checkout. The destination is
#     resolved the way git resolves it: from the directory the command runs in (cd and git -C
#     are followed). Comments, heredoc bodies and quoted text are not commands and are skipped.
# Checkbox "[?]" (ask), "[ ]" and "[0]" (off) allow every call.
#
# Reads the hook JSON on stdin. Prints a PreToolUse deny decision as one JSON line, or
# nothing (allow). Fails open: any internal error allows the tool call. No network.

import json
import os
import re
import shlex
import subprocess
import sys

SETUP = os.path.join(os.path.dirname(os.path.realpath(__file__)), "worktree-setup.sh")
PERM_FILE = "DOGMA-PERMISSIONS.md"
HYDRA_ID = "xw1i"
HYDRA_TEXT = r"use Hydra for 2\+ independent tasks"
HYDRA_HEADING = re.compile(r"^###\s+Hydra\s*(?:\(§[0-9a-z]{4}\)\s*)?$", re.I)
CHECKBOX = re.compile(r"^-\s*\[(.)\]\s*(.*)$")
STATES = {"x": "auto", "?": "ask", " ": "deny", "0": "deny", "1": "one", "a": "all"}
ON_STATES = ("auto", "missing")

SEPARATORS = {"&&", "||", ";", ";;", "|", "|&", "&", "\n"}
STOP = SEPARATORS | {"(", ")"}
CMD_START = SEPARATORS | {"(", "{", "then", "do", "else", "!", "if", "elif", "while", "until"}
WRAPPERS = {"command", "exec", "env", "sudo", "nohup", "time"}
REDIRECTS = {">", ">>", "<", "<<", "<<<", ">&", "<&", "&>", "&>>", ">|", "<>"}
GIT_VALUE_OPTS = {"-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix"}
NON_LITERAL = re.compile(r"[$`*?\[\]{}]")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
COMMENT_START = " \t\n;&|()"

PREFIX = ("hydra: every worktree goes through hydra while hydra is installed and the Hydra "
          "checkbox in DOGMA-PERMISSIONS.md is on (default). ")
HOW = ("Create it with /hydra:create <name>, or run from the repo root: "
       "git worktree add -b hydra/<name> ../<repo>-worktrees/<name>, then "
       + SETUP + " ../<repo>-worktrees/<name>. "
       "Write the path literally, without shell variables.")
REASON_AGENT = (PREFIX + "Agent with isolation worktree is blocked. " + HOW
                + " Then start the agent in that worktree path without the isolation parameter.")
REASON_ENTER = (PREFIX + "EnterWorktree without a path is blocked (it creates a worktree outside the "
                "hydra flow). "
                + HOW + " To work in an existing hydra worktree, cd into its path or use /hydra:spawn.")
REASON_NON_LITERAL = (PREFIX + "git worktree add with a destination that uses shell variables, globs "
                      "or expansions cannot be checked. " + HOW)
REASON_UNKNOWN_DIR = (PREFIX + "git worktree add runs in a directory that cannot be resolved literally "
                      "(cd or git -C with a variable). Run it from the repo root without variables. " + HOW)


def deny(reason):
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                   "permissionDecision": "deny",
                                   "permissionDecisionReason": reason}}


def read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read().splitlines()


def permission_block(lines):
    block, inside = [], False
    for line in lines:
        if "<permissions>" in line:
            inside = True
        if inside:
            block.append(line)
        if "</permissions>" in line:
            inside = False
    return block


def by_id(lines):
    tag = "(§" + HYDRA_ID + ")"
    for line in lines:
        m = CHECKBOX.match(line.strip())
        if m and tag in m.group(2):
            return STATES.get(m.group(1), "missing")
    return None


def by_text(lines):
    inside = False
    for line in lines:
        s = line.strip()
        if s.startswith("#") or s.startswith("</permissions>"):
            inside = bool(HYDRA_HEADING.match(s))
            continue
        m = CHECKBOX.match(s)
        if inside and m and m.group(1) in STATES and re.search(HYDRA_TEXT, m.group(2), re.I):
            return STATES[m.group(1)]
    return None


def hydra_mode(block):
    mode = by_id(block)
    if mode is None:
        mode = by_text(block)
    return mode or "missing"


def existing_dir(path):
    d = os.path.abspath(path)
    while not os.path.isdir(d):
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent
    return d


def find_up(start):
    d = existing_dir(start)
    while d is not None:
        candidate = os.path.join(d, PERM_FILE)
        if os.path.isfile(candidate):
            return candidate
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


def git(directory, *args):
    try:
        done = subprocess.run(["git", "-C", directory, *args], capture_output=True,
                              text=True, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    return done.stdout if done.returncode == 0 else None


def main_root(directory):
    out = git(directory, "worktree", "list", "--porcelain")
    if not out:
        return None
    first = out.splitlines()[0]
    if not first.startswith("worktree "):
        return None
    return os.path.realpath(first[len("worktree "):])


def hydra_on(start, root=None):
    perm = find_up(start)
    if perm is None:
        if root is None:
            root = main_root(start)
        if root is not None and os.path.isfile(os.path.join(root, PERM_FILE)):
            perm = os.path.join(root, PERM_FILE)
    if perm is None:
        return True
    try:
        lines = read_lines(perm)
    except OSError:
        return False
    return hydra_mode(permission_block(lines)) in ON_STATES


def resolve(base, arg):
    """Absolute path git would use for arg, or None when it is not literal or base is unknown."""
    if NON_LITERAL.search(arg):
        return None
    path = os.path.expanduser(arg)
    if os.path.isabs(path):
        return os.path.normpath(path)
    if base is None:
        return None
    return os.path.normpath(os.path.join(base, path))


def heredoc_word(text, i):
    """Delimiter of a heredoc whose operator ends at i, quotes removed."""
    while i < len(text) and text[i] in " \t":
        i += 1
    word, quote = [], None
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == quote:
                quote = None
            else:
                word.append(ch)
        elif ch in "'\"":
            quote = ch
        elif ch == "\\" and i + 1 < len(text):
            i += 1
            word.append(text[i])
        elif ch.isspace() or ch in ";&|()<>":
            break
        else:
            word.append(ch)
        i += 1
    return "".join(word)


def body_end(text, i, word, strip_tabs):
    """Index after the terminator line of a heredoc body starting at i, None if unterminated."""
    while i < len(text):
        end = text.find("\n", i)
        end = len(text) if end < 0 else end
        line = text[i:end]
        i = end + 1
        if (line.lstrip("\t") if strip_tabs else line) == word:
            return min(i, len(text))
    return None


def skip_bodies(text, start, pending):
    """Index after all heredoc bodies starting at start; start itself if one is unterminated."""
    i = start
    for word, strip_tabs in pending:
        i = body_end(text, i, word, strip_tabs)
        if i is None:
            return start
    return i


def strip_code(command):
    """The command without comments and heredoc bodies. Quotes and escapes are kept as typed."""
    out, pending, quote, i = [], [], None, 0
    while i < len(command):
        ch = command[i]
        if ch == "\\" and quote != "'":
            out.append(command[i:i + 2])
            i += 2
            continue
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "#" and (i == 0 or command[i - 1] in COMMENT_START):
            end = command.find("\n", i)
            i = len(command) if end < 0 else end
            continue
        elif command.startswith("<<<", i):
            out.append("<<<")
            i += 3
            continue
        elif command.startswith("<<", i):
            k = i + 2
            strip_tabs = command[k:k + 1] == "-"
            k += 1 if strip_tabs else 0
            pending.append((heredoc_word(command, k), strip_tabs))
            out.append(command[i:k])
            i = k
            continue
        elif ch == "\n" and pending:
            out.append(ch)
            i = skip_bodies(command, i + 1, pending)
            pending = []
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def tokenize(command):
    text = command.replace("\\\n", " ").replace("\n", " ; ")
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""  # comments are already removed by strip_code
    return list(lexer)


def take_args(tokens, i):
    out = []
    while i < len(tokens) and tokens[i] not in STOP:
        out.append(tokens[i])
        i += 1
    return out


def apply_cd(tokens, i, cur):
    while i < len(tokens) and tokens[i] in ("-P", "-L", "-e", "--"):
        i += 1
    if i >= len(tokens) or tokens[i] in STOP:
        return resolve(cur, "~"), i
    if tokens[i] == "-":
        return None, i + 1
    return resolve(cur, tokens[i]), i + 1


def git_add(tokens, i, cur):
    d = cur
    while i < len(tokens):
        tok = tokens[i]
        if tok == "-C":
            d = resolve(d, tokens[i + 1]) if i + 1 < len(tokens) else d
            i += 2
        elif tok in GIT_VALUE_OPTS:
            i += 2
        elif tok.startswith("-"):
            i += 1
        else:
            break
    if tokens[i:i + 2] != ["worktree", "add"]:
        return []
    return [(d, take_args(tokens, i + 2))]


def command_start(tokens, i):
    """True when tokens[i] starts a simple command: after a separator or an opening word, with
    NAME=value assignments and wrapper words (env, sudo, ...) skipped. Wrapper options are not
    skipped, so `sudo -u x git` is not seen."""
    j = i - 1
    while j >= 0 and (ASSIGN.match(tokens[j]) or tokens[j] in WRAPPERS):
        j -= 1
    return j < 0 or tokens[j] in CMD_START


def scan(tokens, cwd):
    """Every git worktree add as (destination dir or None, argument tokens)."""
    found, stack, cur, i = [], [], cwd, 0
    while i < len(tokens):
        tok = tokens[i]
        if tok == "(":
            stack.append(cur)
        elif tok == ")":
            if stack:
                cur = stack.pop()
        elif tok == "cd" and command_start(tokens, i):
            cur, i = apply_cd(tokens, i + 1, cur)
            continue
        elif tok == "git" and command_start(tokens, i):
            found.extend(git_add(tokens, i + 1, cur))
        i += 1
    return found


def add_path(args):
    """Destination token of `git worktree add` arguments, or None."""
    positionals, has_branch, orphan, opts_done, k = [], False, False, False, 0
    while k < len(args):
        tok = args[k]
        if tok.isdigit() and k + 1 < len(args) and args[k + 1] in REDIRECTS:
            k += 1  # fd number of a redirect (2>/dev/null), the redirect itself is skipped next
            continue
        if tok in REDIRECTS:
            k += 2
            continue
        if not opts_done and tok == "--":
            opts_done = True
        elif not opts_done and tok.startswith("-") and tok != "-":
            if tok in ("-b", "-B"):
                has_branch = True
                k += 2
                continue
            if len(tok) > 2 and tok[:2] in ("-b", "-B") and not tok.startswith("--"):
                has_branch = True
            elif tok == "--orphan":
                orphan = True
            elif tok == "--reason":
                k += 2
                continue
        else:
            positionals.append(tok)
        k += 1
    if orphan and not has_branch and positionals:
        positionals = positionals[1:]
    return positionals[0] if positionals else None


def hydra_dir_of(root):
    return os.path.join(os.path.dirname(root), os.path.basename(root) + "-worktrees")


def inside_hydra(target, root):
    hydra = os.path.realpath(hydra_dir_of(root))
    real = os.path.join(os.path.realpath(os.path.dirname(target)), os.path.basename(target))
    rel = os.path.relpath(real, hydra)
    return rel not in (".", "..") and not rel.startswith(".." + os.sep) and not os.path.isabs(rel)


def check_bash(command, cwd):
    code = strip_code(command)
    try:
        tokens = tokenize(code)
    except ValueError:
        return None  # fail open: bash refuses an unterminated quote as well
    for dest, args in scan(tokens, cwd):
        path = add_path(args)
        if path is None:
            continue
        base = dest if dest is not None else cwd
        root = main_root(base)
        if not hydra_on(base, root):
            continue
        if dest is None:
            return deny(REASON_UNKNOWN_DIR)
        if NON_LITERAL.search(path):
            return deny(REASON_NON_LITERAL)
        if root is None:
            continue
        target = resolve(dest, path)
        if not inside_hydra(target, root):
            hydra = hydra_dir_of(root)
            return deny(PREFIX + "git worktree add would create " + target + ", outside the hydra "
                        "folder " + hydra + "/<name>. " + HOW)
    return None


def decide(payload):
    tool = payload.get("tool_name")
    tin = payload.get("tool_input")
    if not isinstance(tin, dict):
        tin = {}
    cwd = payload.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        cwd = os.getcwd()
    if tool in ("Agent", "Task"):
        if tin.get("isolation") != "worktree" or not hydra_on(cwd):
            return None
        return deny(REASON_AGENT)
    if tool == "EnterWorktree":
        path = tin.get("path")
        has_path = isinstance(path, str) and path.strip() != ""
        return None if has_path or not hydra_on(cwd) else deny(REASON_ENTER)
    if tool == "Bash":
        command = tin.get("command")
        if isinstance(command, str) and "worktree" in command:
            return check_bash(command, cwd)
    return None


def main():
    try:
        payload = json.loads(sys.stdin.read())
        result = decide(payload) if isinstance(payload, dict) else None
    except Exception:
        return 0
    if result is not None:
        sys.stdout.write(json.dumps(result) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
