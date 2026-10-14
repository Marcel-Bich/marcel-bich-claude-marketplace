#!/usr/bin/env python3
"""dogma bash-guard: shell-aware analysis of a Bash command for the dogma guard hooks.

Never executes anything. The command text is normalised like a shell would see it:
split into simple commands (pipes, lists, subshells, groups, nested shells, eval,
command and process substitutions, heredocs and here-strings), wrappers removed
(sudo, env, nice, timeout, xargs, busybox and similar), quoting, ANSI-C strings,
braces, variables assigned in the same command and cd/pushd tracked. Every simple
command is checked on its own.

Modes:
  bash-guard.py              hook mode (called by delete-guard.sh, always on): prints a
                             one-line deny reason, or nothing when the command may run.
  bash-guard.py --findings   prints JSON with the permission-dependent findings
                             (deletes, installs, git add/commit/push, git evasions) for
                             file-protection.sh, dependency-verification.sh and
                             git-permissions.sh, which apply DOGMA-PERMISSIONS.md.

Hook mode denies, independent of any setting (the hard list, see delete-guard.py):
  - deleting, moving away or emptying hard paths: /, the home and its first level,
    every path of depth <= 3 outside the temp roots, mount points (and their first
    level), depth <= 4 below /mnt and /media, Windows profile and system paths, the
    working directory and its parents, whole repositories (also through archive/sync
    source deletion, find, git rm/clean and data-destroying git commands with a
    redirected work tree or git dir);
  - a protected overwrite (redirects, truncation) and the non-delete protections
    (secrets, git hooks and config, DOGMA-PERMISSIONS.md, hook bypass, disk tools);
  - filesystem and disk wipe tools, unmount/mount, Windows-side deletion from WSL;
  - inline interpreter code (python -c, perl -e, node -e and similar) that deletes or
    runs commands near hard paths (heuristic scan).
Targets that cannot be resolved for sure (unset or re-assigned variables, command
substitution, parameter expansion, xargs, run-time command words, inline code deletes
without a literal hard path) are NOT denied here: they are recorded as delete findings
and the delete setting of DOGMA-PERMISSIONS.md decides (file-protection.sh). A variable
in a delete target is judged by its candidate values (variable_values): the environment
value (empty when unset, unless a certain literal assignment governs the use) and every
literal value the command gives to the name (its ~ and $-references expanded once); any
candidate on the hard list denies, and more than CANDIDATE_LIMIT candidates deny as well.
Afterwards every normalised simple command goes through delete-guard.py.
Hook mode also applies the setting-independent rules of the other guards, each behind
its own switch: token protection (credential paths, environment dumps, token
variables, remote URLs), git add protection (git add -f, secret files, skipped git
hooks) and dependency verification (scripts built or downloaded at run time).

ENV: CLAUDE_MB_DOGMA_TOKEN_PROTECTION, CLAUDE_MB_DOGMA_FILE_PROTECTION,
     CLAUDE_MB_DOGMA_GIT_PERMISSIONS, CLAUDE_MB_DOGMA_GIT_ADD_PROTECTION,
     CLAUDE_MB_DOGMA_DEPENDENCY_VERIFICATION (default true each);
     CLAUDE_MB_DOGMA_PROTECTED_MOUNTS (extra mount points, colon separated; they are
     added to the mounts found in /proc/self/mounts and can only widen protection).
"""

import codecs
import fnmatch
import glob
import importlib.util
import itertools
import json
import os
import re
import shlex
import sys
import time
from pathlib import Path


PERMISSION_FILE = "DOGMA-PERMISSIONS.md"
FEATURES = ("token_protection", "file_protection", "git_permissions", "git_add_protection", "dependency_verification")
# Claude Code treats a timed-out hook (5 s) as a non-blocking error, so the analysis stops
# (and denies) well before the hook timeout, and the delete-guard phase after it gets the
# rest of one overall budget (it denies as well when that runs out).
DEADLINE = 2.5
HOOK_BUDGET = 4.0
STARTED = [time.monotonic()]


def _load_sibling(name, filename):
    path = Path(__file__).resolve().parent / filename
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# GNU option parsing shared with delete-guard.py
getopt = _load_sibling("dogma_getopt", "dogma_getopt.py")
FOLLOWING_DELETERS = {"shred", "srm", "wipe"}  # they write through a symlink; rm/unlink/rmdir remove the link
HARMLESS_DEVICES = {"/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty", "/dev/zero", "/dev/random",
                    "/dev/urandom", "/dev/full"}
LIST_VERBS = {"ls", "stat", "du", "tree", "test", "[", "[[", "exa", "eza", "file", "realpath", "readlink",
              "basename", "dirname", "lsattr", "getfacl"}
READ_VERBS = {"cat", "head", "tail", "less", "more", "grep", "egrep", "fgrep", "rg", "ag", "ack", "wc", "sort",
              "uniq", "diff", "cmp", "jq", "yq", "gojq", "md5sum", "sha1sum", "sha256sum", "sha512sum", "strings",
              "od", "xxd", "hexdump", "base64", "nl", "tac", "cut", "awk", "gawk", "mawk", "sed", "find", "echo",
              "printf", "git", "gh", "source", ".", "column", "fold", "fmt", "expand", "iconv", "bat", "view",
              "sqlite3", "zcat", "zgrep", "unzip", "tr", "paste", "join", "comm", "look", "vimdiff", "colordiff"}
SAFE_VERBS = LIST_VERBS | {"cat", "head", "tail", "less", "more", "grep", "egrep", "fgrep", "rg", "ag", "ack",
                           "wc", "sort", "uniq", "diff", "cmp", "touch", "mkdir", "git", "gh", "glab", "hub",
                           "tee", "cut", "tr", "column", "date", "true", "false", ":", "sleep", "kill", "pwd",
                           "which", "type", "sed", "cp", "mv", "ln", "chmod", "chown", "chgrp", "tar", "zip",
                           "unzip", "gzip", "gunzip", "curl", "wget", "pip", "pip3", "npm", "pnpm", "yarn",
                           "cargo", "go", "echo", "printf", "base64", "xxd", "od", "strings", "md5sum",
                           "sha256sum", "export", "declare", "typeset", "local", "readonly", "set", "unset",
                           "shopt", "read", "wait", "jobs", "fg", "bg", "exit", "return", "codex-peer"}
EXEC_VERBS = {"rm", "unlink", "rmdir", "shred", "srm", "wipe", "find", "mv", "truncate", "dd", "git", "xargs",
              "eval", "chmod", "chown", "rsync", "tar", "ln", "cp", "install", "sh", "bash", "zsh", "dash",
              "ksh", "fish", "sudo", "doas", "env", "busybox", "mkfs", "wipefs", "sed"}
EXEC_WORD_RE = re.compile(r"\b(rm|unlink|rmdir|shred|find|mv|truncate|dd|git|chmod|chown|rsync|sh|bash|eval|"
                          r"python[0-9.]*|perl|node)\b")
PRIVATE_SECRET = {"auth.json", ".credentials.json"}
EXEC_ENV_ALWAYS = {"BASH_ENV", "ENV", "LD_PRELOAD", "LD_AUDIT", "PROMPT_COMMAND", "PERL5OPT", "RUBYOPT",
                   "PYTHONSTARTUP", "GIT_EXEC_PATH", "GIT_TEMPLATE_DIR"}
EXEC_ENV_COMMAND = {"GIT_PAGER", "GIT_EXTERNAL_DIFF", "GIT_SSH_COMMAND", "GIT_SSH", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR",
                    "GIT_ASKPASS", "SSH_ASKPASS", "PAGER", "MANPAGER", "EDITOR", "VISUAL", "GIT_PROXY_COMMAND",
                    "SYSTEMD_PAGER", "BROWSER"}
CODE_VERBS = {"lua": ("-e",), "luajit": ("-e",), "julia": ("-e", "--eval"), "Rscript": ("-e",), "R": ("-e",),
              "emacs": ("--eval", "-eval", "--execute", "-x"), "emacsclient": ("--eval", "-e"), "osascript": ("-e",),
              "tclsh": (), "wish": (), "jshell": (), "groovy": ("-e",), "scala": ("-e",)}
EXEC_PRIM_RE = re.compile(r"\b(system|exec|execSync|spawn|spawnSync|popen|Popen|run|call|check_output|"
                          r"shell_exec|passthru|proc_open|execute|IO\.popen|Command|ProcessBuilder|eval)\s*[\(\[{ \"']"
                          r"|`[^`]+`|%x\{|\bos\.execute\b")
CODE_INSTALL_RE = re.compile(r"install\.packages|remotes::install|devtools::install|pip\.main|ensurepip|"
                             r"(urlopen|urlretrieve|requests\.get|http\.get|fetch|LWP|open-uri|Net::HTTP)"
                             r"[\s\S]*\b(exec|eval|system|load|loadstring|require)\b")
RAW_DESTRUCT_RE = re.compile(r"(?i)\b(rm|rmdir|unlink|shred|mkfs\S*|dd|truncate|wipefs|remove-item|rd|del)\b")
RAW_PROTECTED_RE = re.compile(r"(^|[\s'\"=(,_:])(~|\$HOME|\$\{HOME|/home\b|/root\b|/mnt\b|/(?=[\s'\"]|$)|\.\.)")
# a string handed to a program whose semantics are not (fully) known is parsed as shell text
# when a command word the analyser cares about stands in command position, or it expands
# (linear: a one-character lookbehind instead of a leading path pattern, bounded repeats only;
# the word may follow a "/" of a path such as /bin/rm)
OPAQUE_RE = re.compile(r"(?<![^\s;&|({`'\"!=@/])(?:rm|unlink|rmdir|shred|srm|wipe|del|rd|find|mv|truncate|dd|"
                       r"mkfs[\w.-]{0,32}|wipefs|git|chmod|chown|rsync|sh|bash|zsh|dash|ksh|mksh|ash|fish|eval|exec|"
                       r"xargs|sudo|doas|su|runuser|env|tmux|wsl(?:\.exe)?|cd|pushd|source|python[0-9.]{0,8}|perl|"
                       r"node|ruby|systemd-run|nsenter|unshare|chroot|bwrap|proot|start-stop-daemon)"
                       r"(?=$|[\s;&|)}`'\"])"
                       r"|(?<![^\s;&|({`'\"!])\$[\w{][^\s$]{0,256}\s+\S|\$\(|`")
# fallback when such a string cannot be parsed: a delete-capable verb with any operand
FALLBACK_RE = re.compile(r"(?<![^\s;&|({`'\"!=@/])(?:rm|unlink|rmdir|shred|srm|wipe|del|rd|truncate|dd|"
                         r"mkfs[\w.-]{0,32}|wipefs|find|mv|rsync)\s+\S")
# appended to every refusal of a git hook bypass
HOOK_HINT = " Make a normal commit (a WIP commit is fine); if a hook fails, fix the cause or report it."
# appended to refusals of remote URL output: the owner/repo scope without the URL
SCOPE_HINT = " For the owner/repo scope check run: bash %s [dir]" % (
    Path(__file__).resolve().parent / "git-scope.sh")
OPAQUE_MAX = 65536  # longer text is not parsed; it is refused when the fallback pattern matches
# tmux commands (name: alias) for the unique-prefix lookup of tmux's cmd_find
TMUX_COMMANDS = {
    "attach-session": "attach", "bind-key": "bind", "break-pane": "breakp", "capture-pane": "capturep",
    "choose-buffer": None, "choose-client": None, "choose-tree": None, "clear-history": "clearhist",
    "clear-prompt-history": "clearphist", "clock-mode": None, "command-prompt": None, "confirm-before": "confirm",
    "copy-mode": None, "customize-mode": None, "delete-buffer": "deleteb", "detach-client": "detach",
    "display-menu": "menu", "display-message": "display", "display-panes": "displayp", "display-popup": "popup",
    "find-window": "findw", "has-session": "has", "if-shell": "if", "join-pane": "joinp", "kill-pane": "killp",
    "kill-server": None, "kill-session": None, "kill-window": "killw", "last-pane": "lastp", "last-window": "last",
    "link-window": "linkw", "list-buffers": "lsb", "list-clients": "lsc", "list-commands": "lscm",
    "list-keys": "lsk", "list-panes": "lsp", "list-sessions": "ls", "list-windows": "lsw", "load-buffer": "loadb",
    "lock-client": "lockc", "lock-server": "lock", "lock-session": "locks", "move-pane": "movep",
    "move-window": "movew", "new-session": "new", "new-window": "neww", "next-layout": "nextl",
    "next-window": "next", "paste-buffer": "pasteb", "pipe-pane": "pipep", "previous-layout": "prevl",
    "previous-window": "prev", "refresh-client": "refresh", "rename-session": "rename", "rename-window": "renamew",
    "resize-pane": "resizep", "resize-window": "resizew", "respawn-pane": "respawnp", "respawn-window": "respawnw",
    "rotate-window": "rotatew", "run-shell": "run", "save-buffer": "saveb", "select-layout": "selectl",
    "select-pane": "selectp", "select-window": "selectw", "send-keys": "send", "send-prefix": None,
    "server-access": None, "set-buffer": "setb", "set-environment": "setenv", "set-hook": None,
    "set-option": "set", "set-window-option": "setw", "show-buffer": "showb", "show-environment": "showenv",
    "show-hooks": None, "show-messages": "showmsgs", "show-options": "show", "show-prompt-history": "showphist",
    "show-window-options": "showw", "source-file": "source", "split-window": "splitw", "start-server": "start",
    "suspend-client": "suspendc", "swap-pane": "swapp", "swap-window": "swapw", "switch-client": "switchc",
    "unbind-key": "unbind", "unlink-window": "unlinkw", "wait-for": "wait"}
# tmux commands that run something: (option letters taking a value, kind of the remaining arguments)
TMUX_RUN = {
    "new-session": ("cefnstxyFX", "shell"), "new-window": ("cenFt", "shell"), "split-window": ("celtFp", "shell"),
    "respawn-pane": ("cet", "shell"), "respawn-window": ("cet", "shell"), "run-shell": ("cdt", "shell"),
    "display-popup": ("bcdehsStTwxy", "shell"), "pipe-pane": ("t", "shell"), "if-shell": ("t", "if"),
    "confirm-before": ("cpt", "tmux"), "command-prompt": ("IptT", "tmux"), "display-menu": ("bcCHsStTxy", "tmux"),
    "choose-tree": ("FfKOt", "tmux"), "choose-client": ("FfKOt", "tmux"), "choose-buffer": ("FfKOt", "tmux"),
    "display-panes": ("dt", "tmux"), "bind-key": ("TN", "argv"), "set-hook": ("t", "hook"),
    "send-keys": ("cNt", "keys"), "set-option": ("t", "opaque"), "set-window-option": ("t", "opaque"),
    "set-environment": ("t", "opaque"), "set-buffer": ("bnt", "opaque")}
TMUX_KEYS = {"enter": "\n", "kpenter": "\n", "c-m": "\n", "c-j": "\n", "^m": "\n", "^j": "\n", "space": " ",
             "tab": "\t", "c-i": "\t", "^i": "\t"}
TMUX_KEY_NAME_RE = re.compile(r"(?i)((c|m|s)-|\^).+|f\d{1,2}|up|down|left|right|home|end|npage|pagedown|pgdn|ppage|"
                              r"pageup|pgup|ic|insert|dc|delete|bspace|btab|escape|kp\w+|any|mouse\w*|wheel\w*|"
                              r"double\w*|triple\w*|secondclick\w*|paste\w*|focus\w*|user\d+")
def private_blocked(path, root):
    """True when path inside the private config home root must not be read: the root itself (a recursive read
    reaches the logins), a glob in the first component and the login files."""
    relative = os.path.relpath(path, root)
    first = relative.split("/")[0]
    return path == root or bool(GLOB_RE.search(first)) or first in PRIVATE_SECRET
CODE_HOME_RE = re.compile(r"expanduser|Path\.home|homedir\s*\(|\$ENV\{\s*HOME|ENV\[\s*[\"']HOME|"
                          r"environ\s*\[\s*[\"']HOME|environ\.get\(\s*[\"']HOME|getenv\(\s*[\"']HOME|"
                          r"\$HOME\b|[\"']~[\"'/]|File\.expand_path|Dir\.home")
# a home lookup whose result is not a visible path (the literal "~/x" of expanduser is checked as a path)
MOVE_HOME_RE = re.compile(r"Path\.home|homedir|\$ENV\{\s*HOME|ENV\[\s*[\"']HOME|environ\s*\[\s*[\"']HOME|"
                          r"environ\.get\(\s*[\"']HOME|getenv\(\s*[\"']HOME|\$HOME\b|File\.expand_path|Dir\.home|"
                          r"getpwuid|pw_dir|getpwnam|chr\(\s*126\s*\)|\\x7e|\\176|Sys\.getenv|"
                          r"expanduser\s*\(\s*(?![\"'])")
CODE_FRAGMENT_RE = re.compile(r"auth\.json|\.credentials|credentials\.json|\.codex\b|\.ssh\b|"
                              r"\.gnupg|\.netrc|\.git-credentials|\bid_(rsa|ed25519|ecdsa|dsa)\b|/environ\b|"
                              r"hosts\.yml|dogma/config|DOGMA-PERMISSIONS|\.env\b(?!\.(example|sample|template))")

MKTEMP_RE = re.compile(r"^\s*mktemp(\s+[-\w.%/]+)*\s*$")
SUB_RE = re.compile(r"__DOGMA_SUB_(\d+)__")
HEREDOC_RE = re.compile(r"__DOGMA_HEREDOC_(\d+)__")
CONT_RE = re.compile(r"\\\r?\n")  # a line continuation: backslash, newline
# the standard streams are no files: a redirect onto them is not resolved (realpath leads to /proc/<pid>/fd/...)
STREAM_TARGET_RE = re.compile(r"^/dev/(?:stdin|stdout|stderr|fd/\d+)$")
# text that can redefine cat, tee or an interpreter in the running shell: a function, an alias, hash, enable,
# builtin, a changed PATH, a sourced file (a heredoc body is data only when these words are the real ones)
SHADOW_RE = re.compile(
    r"[\w.:+@%-]\s*\(\s*\)|"
    r"(?:^|[\s;&|({`'\"])function\s|"
    r"(?:^|[;&|(){}\n`'\"])\s*(?:(?:builtin|command|exec|sudo|env|time|nohup)\s+)*"
    r"(?:alias|unalias|hash|enable|builtin|source|\.)(?=\s|$)|"
    r"(?:^|[\s;&|({`'\"])PATH\+?=")
# the symlink calls of inline code (python, perl, ruby, node): their first argument is the link target
CODE_SYMLINK_RE = re.compile(r"\b(?:symlink|symlinkSync|make_symlink|symlink_to|ln_sfn?|ln_s)\s*(?:\(|[\"'$@])|"
                             r"\bimport\b[^\n;]*\bsymlink\b|\bFile\.symlink\b")
# inline code that truncates a file by path (os.truncate(path, 0), fs.truncateSync(path), File.truncate): a call whose
# first argument is no bare number (f.truncate(0) acts on an open file)
CODE_TRUNCATE_RE = re.compile(r"\btruncate(?:Sync)?\s*\(\s*(?![-+]?\d+\s*[,)]|\))")
# inline code that opens a literal path for writing: open(path, 'w'|'a'|'x'|'r+'), Path(path).write_text(...),
# fs.writeFileSync(path, ...); the keyword form open(file='...', mode='a') in either order; also with
# os.path.expanduser('~/...') around the literal. The path is group 2, 4, 6, 8 or 10.
CODE_WRITE_RE = re.compile(
    r"\bopen\s*\(\s*(?:(?:os\s*\.\s*)?path\s*\.\s*expanduser\s*\(\s*)?([\"'])([^\"'\s]+)\1\s*\)?\s*,\s*"
    r"(?:mode\s*=\s*)?[\"'](?:[wax]|r\+)[^\"']*[\"']|"
    r"\bPath\s*\(\s*(?:(?:os\s*\.\s*)?path\s*\.\s*expanduser\s*\(\s*)?([\"'])([^\"'\s]+)\3\s*\)*"
    r"(?:\s*\.\s*expanduser\s*\(\s*\))?\s*\.\s*(?:write_text|write_bytes)\s*\(|"
    r"\b(?:writeFile|appendFile)(?:Sync)?\s*\(\s*([\"'])([^\"'\s]+)\5|"
    r"\bopen\s*\(\s*file\s*=\s*([\"'])([^\"'\s]+)\7\s*,\s*mode\s*=\s*[\"'](?:[wax]|r\+)[^\"']*[\"']|"
    r"\bopen\s*\(\s*mode\s*=\s*[\"'](?:[wax]|r\+)[^\"']*[\"']\s*,\s*file\s*=\s*([\"'])([^\"'\s]+)\9")
ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\+?=(.*)$", re.S)
VAR_RE = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))")
SHELL_VAR_RE = re.compile(r"\$\{?!?#?([A-Za-z_][A-Za-z0-9_]*)")
GLOB_RE = re.compile(r"[*?\[]")
HEREDOC_OP_RE = re.compile(r"<<(-?)[ \t]*")
WORD_END = " \t\n;&|()<>"

SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "fish"}
INTERPRETER_RE = re.compile(r"^(?:python[0-9.]*|pypy[0-9.]*|perl[0-9.]*|ruby[0-9.]*|node|nodejs|bun|deno|php[0-9.]*)$")
DELETE_VERBS = {"rm", "unlink", "rmdir", "shred", "del", "srm", "wipe"}
# the words of a text that run-time code (eval) may delete or move with: such text is unsure, not a denial
DELETE_TEXT_RE = re.compile(r"\b(?:rm|unlink|shred|rmdir|srm|wipe|truncate|dd|mv)\b")
DEVICE_TOOLS = {"wipefs", "mkswap", "blkdiscard", "fdisk", "sfdisk", "parted", "sgdisk", "mke2fs", "mkdosfs",
                "mkntfs", "cryptsetup", "badblocks", "e2fsck", "tune2fs", "zpool", "lvremove", "vgremove", "pvremove",
                "diskpart", "format"}
TEXT_COMMANDS = {":", "true", "false", "test", "[", "[[", "let", "local", "readonly", "alias",
                 "unalias", "shopt", "trap", "return", "exit", "break", "continue", "wait", "sleep", "type",
                 "which", "hash", "read", "export", "declare", "typeset", "set", "unset"}
SEARCH_COMMANDS = {"rg", "grep", "egrep", "fgrep", "ag", "ack", "git-grep"}
KEYWORDS = {"{", "}", "!", "if", "then", "else", "elif", "fi", "do", "done", "while", "until", "esac", "in",
            "function", "coproc", "[[", "]]"}
GROUP_OPEN = {"{", "if", "while", "until", "for", "select", "case"}
GROUP_CLOSE = {"}", "fi", "done", "esac"}
GUARD_RELEVANT = DELETE_VERBS | {"find", "mv", "ln", "cp", "cd", "pushd", "git", "eval", "xargs"} | SHELLS
GIT_KNOWN = set("""
add am annotate apply archive bisect blame branch bugreport bundle cat-file check-attr check-ignore
check-mailmap check-ref-format checkout checkout-index cherry cherry-pick citool clean clone column commit
commit-graph commit-tree config count-objects credential credential-cache credential-store daemon describe
diagnose diff diff-files diff-index diff-tree difftool fast-export fast-import fetch fetch-pack filter-branch
fmt-merge-msg for-each-ref for-each-repo format-patch fsck fsck-objects gc get-tar-commit-id grep gui
hash-object help hook http-push index-pack init init-db instaweb interpret-trailers log ls-files ls-remote
ls-tree mailinfo mailsplit maintenance merge merge-base merge-file merge-index merge-one-file merge-tree
mergetool mktag mktree multi-pack-index mv name-rev notes pack-objects pack-redundant pack-refs patch-id
prune prune-packed pull push range-diff read-tree rebase reflog remote repack replace replay request-pull
rerere reset restore rev-list rev-parse revert rm scalar send-email send-pack shortlog show show-branch
show-index show-ref sparse-checkout stage stash status stripspace submodule switch symbolic-ref tag
unpack-file unpack-objects update-index update-ref update-server-info var verify-commit verify-pack
verify-tag version whatchanged worktree write-tree
""".split())
GIT_OP = {"add": "add", "stage": "add", "commit": "commit", "commit-tree": "commit", "update-ref": "commit",
          "push": "push", "send-pack": "push", "http-push": "push"}
GIT_MESSAGE_OPTIONS = {"-m", "--message", "--grep", "--format", "--pretty", "-S", "-G", "--author", "--trailer",
                       "--date", "--since", "--until", "--committer"}
GIT_NO_VERIFY = {"commit", "push", "merge", "am", "rebase", "cherry-pick", "pull", "revert"}
GIT_COMMAND_CONFIG = re.compile(r"^(core\.(pager|editor|sshcommand|fsmonitor|askpass|hookspath|gitproxy)|"
                                r"sequence\.editor|gpg\.(.*\.)?program|web\.browser|browser\..*\.cmd|man\..*\.cmd|"
                                r"merge\..*\.driver|uploadpack\.packobjectshook|include\.path|includeif\..*|"
                                r"diff\.external|pager\..*|credential\..*|.*\.(cmd|command|textconv|process|clean|smudge|tool))$")
CODE_EXTENSIONS = {"sh", "bash", "zsh", "fish", "py", "pyi", "js", "mjs", "cjs", "ts", "tsx", "jsx", "rb", "go",
                   "rs", "java", "php", "pl", "pm", "c", "cc", "cpp", "h", "hpp", "cs", "swift", "kt", "scala",
                   "vue", "svelte", "md", "rst", "html", "css", "scss", "less", "lua", "ex", "exs", "dart", "r",
                   "ipynb", "bats"}
SAFE_ENV_SUFFIXES = {"example", "sample", "template"}
SENSITIVE_DIRS = {".ssh", ".gnupg", ".password-store", "secrets", ".secrets", "credentials", ".credentials"}
SENSITIVE_NAMES = {".netrc", "_netrc", ".git-credentials", ".npmrc", ".pypirc", ".smbcredentials", ".htpasswd",
                   ".pgpass", ".my.cnf", "kubeconfig", ".dockercfg", ".vault-token", ".histfile", "auth.json"}
GLOB_SENSITIVE = (".codex", ".claude", ".ssh", ".gnupg", ".env", ".env.local", "auth.json", ".credentials.json",
                  ".netrc", ".git-credentials", ".npmrc", ".pypirc", ".smbcredentials", "id_rsa", "id_ed25519",
                  "id_ecdsa", "environ", ".bash_history", ".zsh_history", "fish_history")
SENSITIVE_SUFFIXES = (".pem", ".key", ".p12", ".pfx", ".keystore", ".jks", ".ppk", "_history")
SENSITIVE_SEQUENCES = ((".config", "rclone"), (".local", "share", "keyrings"), (".codex", "auth.json"), (".config", "gh", "hosts.yml"), (".docker", "config.json"),
                       (".kube", "config"), (".config", "gcloud"), (".azure",), (".git", "config"),
                       (".aws", "credentials"), (".config", "hub"), (".git", "fetch_head"))
SENSITIVE_VAR_PARTS = {"TOKEN", "TOKENS", "SECRET", "SECRETS", "PASSWORD", "PASSWD", "APIKEY", "CREDENTIAL",
                       "CREDENTIALS", "PAT"}
SENSITIVE_VAR_PAIRS = ("API_KEY", "PRIVATE_KEY", "ACCESS_KEY", "SECRET_KEY", "AUTH_KEY", "SESSION_KEY")
SECRET_PATTERNS = (
    re.compile(r"(?<![A-Za-z0-9_-])sk-(?:proj-|svcacct-|admin-|ant-[a-z0-9]+-)?[A-Za-z0-9_-]{20,}"),
    re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}"),
    re.compile(r"\bxox[abposr]-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)+"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}"),
    re.compile(r"x-access-token:[A-Za-z0-9_-]+@"),
    re.compile(r"(?i)\b(?:password|passwd|aws_secret_access_key|secret_key|api_key|apikey|access_token)\s*[=:]\s*"
               r"(?:['\"][^'\"\s]{12,}['\"]|(?=[^\s'\"]*\d)[A-Za-z0-9+/=_-]{16,})"),
)
CODE_DELETE_RE = re.compile(
    r"\b(?:os\.(?:remove|unlink|rmdir|removedirs)|shutil\.rmtree|rmtree|remove_tree|send2trash|unlink|rmdir|"
    r"unlinkSync|rmSync|rmdirSync|rimraf|rm_rf|rm_r|rm_f|remove_entry(?:_secure)?|remove_dir|"
    r"File\.delete|Dir\.delete|FileUtils\.rm)\b|\bfs(?:\.promises)?\.(?:rm|unlink|rmdir)\b|\.unlink\(|\.rmdir\(|"
    r"from\s+os\s+import\s+[^\n;]*\b(?:remove|unlink)\b")
# a deleting function reached through a module named by a string literal; the literal is read from the
# code with its literals kept (calls), not from the words (see Analysis.code)
IMPORT_DELETE_RE = re.compile(r"__import__\(\s*['\"]os['\"]\s*\)\.(?:remove|unlink|rmdir|removedirs)")
CODE_ENV_DUMP_RE = re.compile(
    r"from\s+os\s+import\s+[^\n;]*\benviron\b|\[\s*[\"']env[\"']\s*\]|"
    r"os\.environb?(?!\s*(?:\.get\b|\[|\.setdefault\b|\.pop\b|\.update\b|\.copy\b|\.__getitem__))|"
    r"process\.env(?!\s*[.\[])|%ENV\b|\bENV(?!\s*(?:\[|\.fetch\b|\.key\?|\.include\?|\.delete\b))\b(?![A-Za-z_])|"
    r"getenv\(\s*\)|\$_(?:ENV|SERVER)\b(?!\s*\[)")
CODE_STRING_RE = re.compile(r"\"((?:[^\"\\\n]|\\.)*)\"|'((?:[^'\\\n]|\\.)*)'")
# a plain string literal (optional prefix, either quote kind) and a run of them joined by implicit concatenation
# or by an operator; the quote kinds of a run may differ: 'a' + "b" and 'a'"b" are one name. A run that a comma
# joins too (ARG_RUN_RE) is an extra reading: the arguments of one call, os.path.join('a', "b"). Its last argument
# can be a mode, so the name is also read without the comma (STRING_RUN_RE).
STRING_TOKEN = r"[rRbBfFuU]{0,2}(?:\"(?:[^\"\\\n]|\\.)*\"|'(?:[^'\\\n]|\\.)*')"
STRING_RUN_RE = re.compile(STRING_TOKEN + r"(?:\s*(?:(?:\+|\.|<>)\s*)?" + STRING_TOKEN + r")+")
ARG_RUN_RE = re.compile(STRING_TOKEN + r"(?:\s*(?:(?:\+|\.|<>|,)\s*)?" + STRING_TOKEN + r")+")


def join_runs(code, run_re):
    """(text, names): the code with each run of joined string literals replaced by one single-quoted literal of
    their joined content, and the list of those contents. The names are candidates for the path checks only;
    the literals as written are checked as well."""
    names = []

    def join(match):
        content = "".join(m.group(1) if m.group(1) is not None else m.group(2)
                          for m in CODE_STRING_RE.finditer(match.group(0)))
        names.append(content)
        return "'" + re.sub(r"\\.|'", lambda m: m.group(0) if len(m.group(0)) == 2 else "\\'", content) + "'"

    return run_re.sub(join, code), names


CODE_NAME_RE = re.compile(r"\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b")
INSTALL_RULES = {
    "npm": ({"install", "i", "add", "isntall", "in"}, True),
    "pnpm": ({"add", "install", "i"}, True),
    "yarn": ({"add"}, True),
    "bun": ({"add", "install", "i"}, True),
    "cargo": ({"add", "install"}, True),
    "gem": ({"install"}, True),
    "go": ({"install", "get"}, True),
    "pipx": ({"install", "inject", "run"}, True),
    "poetry": ({"add"}, True),
    "pdm": ({"add"}, True),
    "conda": ({"install"}, True),
    "mamba": ({"install"}, True),
    "micromamba": ({"install"}, True),
    "apt": ({"install", "reinstall"}, True),
    "apt-get": ({"install", "reinstall"}, True),
    "aptitude": ({"install"}, True),
    "dnf": ({"install"}, True),
    "yum": ({"install"}, True),
    "zypper": ({"install", "in"}, True),
    "apk": ({"add"}, True),
    "snap": ({"install"}, True),
    "brew": ({"install", "reinstall"}, True),
    "flatpak": ({"install"}, True),
    "composer": ({"require"}, True),
    "dotnet": ({"add"}, True),
    "deno": ({"install", "add"}, True),
}
PIP_VALUE_OPTIONS = {"-r", "--requirement", "-c", "--constraint", "-e", "--editable", "-i", "--index-url",
                     "--extra-index-url", "-t", "--target", "--prefix", "--root", "-f", "--find-links", "--python",
                     "--platform", "--src", "--upgrade-strategy", "--cache-dir", "--log", "--proxy", "--timeout"}
WRAPPER_VALUE_OPTIONS = {
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U", "-T", "--user", "--group", "--chdir"},
    "doas": {"-u", "-C"},
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "-n", "--class", "--classdata"},
    "stdbuf": {"-i", "-o", "-e"},
    "time": {"-f", "-o", "--format", "--output"},
    "exec": {"-a"},
    "setsid": set(),
    "nohup": set(),
    "builtin": set(),
    "busybox": set(),
    "command": set(),
    "unbuffer": set(),
    "caffeinate": set(),
    "catchsegv": set(),
    "strace": {"-o", "-e", "-p", "-s", "-u", "-P", "-E"},
    "ltrace": {"-o", "-e", "-p", "-s", "-u"},
    "flock": {"-w", "-E", "--timeout", "--conflict-exit-code"},
    "chronic": set(),
}


class Deny(Exception):
    pass


def deny(reason):
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                   "permissionDecisionReason": reason}}


# --- switches -----------------------------------------------------------------

def codex_home():
    return Path(os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"))


def _components(path):
    return [part for part in path.replace("\\", "/").split("/") if part not in ("", ".")]


def token_strict():
    """CLAUDE_MB_DOGMA_TOKEN_STRICT=false: only .env and .env.local count (as token-protection.sh)."""
    return (os.environ.get("CLAUDE_MB_DOGMA_TOKEN_STRICT") or "true").strip().lower() != "false"


def token_allowed_dirs():
    """Directories whose files skip the credential name check (token-protection.sh allowlist):
    the plugin root of the running hook and CLAUDE_MB_DOGMA_TOKEN_ALLOW_DIRS (comma separated)."""
    roots = [os.environ.get("CLAUDE_PLUGIN_ROOT") or ""]
    roots += (os.environ.get("CLAUDE_MB_DOGMA_TOKEN_ALLOW_DIRS") or "").split(",")
    return [os.path.normpath(root.strip()) for root in roots if root.strip().startswith("/")]


def token_allowed(path):
    return any(_inside(os.path.normpath(path), root) for root in token_allowed_dirs())


CONFIG_HOME_PART_RE = re.compile(r"^\.(?:codex|claude(?:-.+)?)$")
# The session folder of a Claude configuration home holds the descriptors <id>.json (read freely) and the key
# files <id>.<hex>.key (secrets). SESSION_KEY_SAMPLE stands for a key file name in glob tests. A literal path
# into a configuration home in inline code is allowed only as the folder, or as its descriptors (*.json).
SESSION_KEY_SAMPLE = "session.key"
SESSION_LITERAL_RE = re.compile(r"(?:^|/)\.claude(?:-[\w.-]+)?/sessions(?:/(?:[^/\s]*\.json)?)?/?$")
CONFIG_MENTION_RE = re.compile(r"\.claude\b")


def config_home_auth(path, lowered):
    """auth.json below a Claude or Codex config home: below a directory named .codex, .claude or .claude-*,
    or inside CLAUDE_CONFIG_DIR or CODEX_HOME."""
    if any(CONFIG_HOME_PART_RE.match(part) for part in lowered[:-1]):
        return True
    for root in (os.environ.get("CLAUDE_CONFIG_DIR") or "", str(codex_home())):
        if not root:
            continue
        try:
            if _inside(os.path.realpath(path), os.path.realpath(root)):
                return True
        except (OSError, ValueError):
            continue
    return False


def sensitive_name(path):
    """Lexical credential check of one path (no filesystem access)."""
    parts = _components(path)
    if not parts:
        return False
    lowered = [part.lower() for part in parts]
    base = lowered[-1]
    for index, part in enumerate(lowered):
        if not GLOB_RE.search(part):
            continue
        if index >= 2 and lowered[index - 1] == "sessions" and CONFIG_HOME_PART_RE.match(lowered[index - 2]) \
                and fnmatch.fnmatchcase(SESSION_KEY_SAMPLE, part):
            return True  # a glob in a session folder that can match a key file
        literal = re.sub(r"\[[^\]]*\]|[*?]", "", part)
        names = [name for name in GLOB_SENSITIVE if fnmatch.fnmatchcase(name, part)] if len(literal) >= 2 else []
        # a login file sits directly in a configuration home: a login-file glob elsewhere matches nothing secret
        if names and not (index > 0 and not CONFIG_HOME_PART_RE.match(lowered[index - 1])
                          and all(name in PRIVATE_SECRET for name in names)):
            return True
    if re.match(r"^\.env($|[^a-z0-9])", base) or base == ".envrc":
        suffix = base[5:]
        if suffix not in SAFE_ENV_SUFFIXES and (token_strict() or base in (".env", ".env.local")):
            return True
    if base in SENSITIVE_NAMES and (base != "auth.json" or config_home_auth(path, lowered)):
        return True
    if base.endswith(SENSITIVE_SUFFIXES) or base in ("fish_history",):
        return True
    if re.match(r"^id_(rsa|ed25519|ecdsa|dsa|ecdsa_sk|ed25519_sk)", base) and not base.endswith(".pub"):
        return True
    if any(part in SENSITIVE_DIRS for part in lowered[:-1]) or base in (".ssh", ".gnupg", ".password-store"):
        return True
    if ("credential" in base or "secret" in base) and base.rsplit(".", 1)[-1] not in CODE_EXTENSIONS:
        return True
    for sequence in SENSITIVE_SEQUENCES:
        size = len(sequence)
        for index in range(len(lowered) - size + 1):
            if tuple(lowered[index:index + size]) == sequence:
                return True
    normalized = "/" + "/".join(parts)
    if path.startswith("/") and (re.match(r"^/proc/[^/]+/(environ|task/[^/]+/environ)$", normalized)
                                 or normalized in ("/etc/shadow", "/etc/gshadow", "/etc/sudoers")):
        return True
    return False


def codex_auth(path):
    try:
        return os.path.realpath(path) == os.path.realpath(codex_home() / "auth.json")
    except (OSError, ValueError):
        return False


def sensitive_path(path):
    return sensitive_name(path) or codex_auth(path)


SEARCH_GLOB_OPTIONS = ("--include", "--glob", "--iglob", "-g")


def glob_values(args):
    """{position: glob} of the file-name globs of a search (grep --include, rg -g/--glob/--iglob), the value
    after the option or after its "=". A glob selects files below the search root; it is no path."""
    found = {}
    for position, item in enumerate(args):
        if item in SEARCH_GLOB_OPTIONS and position + 1 < len(args):
            found[position + 1] = args[position + 1]
        elif item.startswith(tuple(option + "=" for option in SEARCH_GLOB_OPTIONS)):
            found[position] = item.partition("=")[2]
    return found


def login_glob(glob):
    """True for a wildcard file-name glob whose only sensitive matches are login files (*.json, .cred*)."""
    if not GLOB_RE.search(glob):
        return False
    names = [name for name in GLOB_SENSITIVE if fnmatch.fnmatchcase(name, glob)]
    return bool(names) and all(name in PRIVATE_SECRET for name in names)


def searches_recursively(verb, args):
    """grep -r/-R (also combined, -rl, -nR) and --recursive; rg, ag and ack recurse by default."""
    if verb in ("rg", "ag", "ack"):
        return True
    return any(item in ("--recursive", "--dereference-recursive") or re.match(r"^-[A-Za-z]*[rR]", item)
               for item in args)


def reaches_login_file(path):
    """True when a recursive search rooted at path can reach a login file of a configuration home: the root is
    a configuration home (.claude, .claude-*, .codex, CLAUDE_CONFIG_DIR, CODEX_HOME) or a directory above one.
    A subfolder such as plugins/ of a profile cannot hold the login file of the profile root."""
    try:
        real = os.path.realpath(path)
    except (OSError, ValueError):
        return True
    if CONFIG_HOME_PART_RE.match(os.path.basename(real)):
        return True
    for base in (home(), os.environ.get("CLAUDE_CONFIG_DIR") or "", str(codex_home())):
        if base:
            try:
                if _inside(os.path.realpath(base), real):
                    return True
            except (OSError, ValueError):
                continue
    return False


def is_session_folder(path):
    """True for a <configuration home>/sessions folder (its key files are secrets)."""
    try:
        real = os.path.realpath(path)
    except (OSError, ValueError):
        return True
    return os.path.basename(real) == "sessions" and CONFIG_HOME_PART_RE.match(os.path.basename(os.path.dirname(real))) \
        is not None


def _may_match(globs, names):
    """True when no file-name glob is given, or one of the globs can match one of the names."""
    return not globs or any(fnmatch.fnmatchcase(name, glob) for glob in globs.values() for name in names)


# A private key is the BEGIN line followed by base64 body: on the same line, or on the next line after
# optional PEM header fields (Proc-Type, DEK-Info) and blank lines. A lone header line is not a key.
# token-protection.sh has the same rule in awk (has_private_key_block) for the Read guard.
PRIVATE_KEY_BLOCK_RE = re.compile(
    r"-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----"
    r"(?:[^\n]*?[A-Za-z0-9+/=]{40}"
    r"|[^\n]*\n(?:[ \t\r]*\n|[ \t]*[A-Za-z][A-Za-z0-9-]*: [^\n]*\n)*[ \t]*[A-Za-z0-9+/=]{40,}[ \t\r]*(?:\n|\Z))")


def _contains_secret(text):
    return any(pattern.search(text) for pattern in SECRET_PATTERNS) or PRIVATE_KEY_BLOCK_RE.search(text) is not None


def _sensitive_variable(name):
    upper = name.upper()
    if any(pair in upper for pair in SENSITIVE_VAR_PAIRS):
        return True
    return any(part in SENSITIVE_VAR_PARTS for part in upper.split("_"))


# --- shell scanner ----------------------------------------------------------------

class Segment:
    def __init__(self, connector):
        self.connector = connector
        self.text = ""
        self.redirects = []
        self.herestrings = []
        self.piped_in = []  # literal text an echo, printf or cat before the pipe writes to stdin
        self.dups = []      # (operator, word) of file descriptor duplications (2>&1, >&3)
        self.group_piped = False  # inside a group or compound command that is the target of a pipe (| (...), | { ...; })

    @property
    def piped(self):
        """The segment reads the standard input of a pipe: it follows "|" or sits inside a piped group."""
        return self.connector == "|" or self.group_piped


class Script:
    def __init__(self):
        self.segments = []
        self.subs = []
        self.heredocs = []      # [body, quoted]
        self.visible = []       # text the shell expands (outside single quotes)
        self.unterminated = False
        self.text = ""          # the scanned text (line continuations joined outside heredoc bodies)
        self.proc_out = False   # an output process substitution ">(...)" occurs
        self.spans = {}         # heredoc slot -> (start, end) of its body lines incl. the delimiter line


def _heredoc_operator(text, index):
    """(delimiter, strip tabs, index after the delimiter word) for a heredoc operator "<<" at index, else None."""
    if not text.startswith("<<", index) or text.startswith("<<<", index):
        return None
    position = index + 2
    strip = text.startswith("-", position)
    position += strip
    while position < len(text) and text[position] in " \t":
        position += 1
    if position >= len(text):
        return None
    if text[position] in "'\"":
        end = text.find(text[position], position + 1)
        if end < 0:
            return None
        word, position = text[position + 1:end], end + 1
    else:
        end = position
        while end < len(text) and text[end] not in " \t\n;&|()<>":
            end += 1
        word, position = re.sub(r"[\\'\"]", "", text[position:end]), end
    return None if not word or word.isdigit() else (word, strip, position)


def _skip_heredoc_bodies(text, position, pending):
    """Index after the delimiter lines of the pending heredocs whose bodies start at position; None when
    a delimiter line is missing (then "<<" was no heredoc)."""
    for delimiter, strip in pending:
        while True:
            if position > len(text):
                return None
            end = text.find("\n", position)
            line = text[position:] if end < 0 else text[position:end]
            position = len(text) + 1 if end < 0 else end + 1
            if (line.lstrip("\t") if strip else line) == delimiter:
                break
    return min(position, len(text))


CASE_WORD_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
CASE_PREFIX_RE = re.compile(r"(?:^|[\s;&|({`])(?:then|do|else|elif|!|time)$")


def _command_position(text, index, start):
    """True when the word at index stands where a command may start: at the start, after a separator or
    after then, do, else, elif."""
    before = text[start:index].rstrip(" \t")
    return not before or before[-1] in ";&|()\n{`" or bool(CASE_PREFIX_RE.search(before))


def _close_paren(text, start, heredocs=True):
    """Index of the ")" closing a "$(" or "(" whose content starts at start; -1 if none.

    A heredoc inside is skipped (its body may hold quotes and parentheses that are text), so
    "$(cat <<'EOF' ... don't ... EOF)" closes at its own parenthesis. heredocs=False for "$((":
    there "<<" is a shift. A case command inside is followed: the ")" that ends a pattern
    ("$(case x in a) rm -rf /home;; esac)") closes no substitution."""
    depth, index, quote, pending = 1, start, None, []
    cases = []  # the open case commands: [phase, depth]; phase is head (before "in"), pattern or body
    while index < len(text):
        char = text[index]
        if quote:
            if char == "\\" and quote == '"':
                index += 2
                continue
            if char == quote:
                quote = None
        elif char == "\\":
            index += 2
            continue
        elif heredocs and char == "<" and _heredoc_operator(text, index):
            word, strip, index = _heredoc_operator(text, index)
            pending.append((word, strip))
            continue
        elif char == "\n" and pending:
            skipped = _skip_heredoc_bodies(text, index + 1, pending)
            pending = []
            if skipped is not None:
                index = skipped
                continue
        elif char in "'\"`":
            quote = char
        elif (char.isalpha() or char == "_") and not (index > start and (text[index - 1].isalnum()
                                                                       or text[index - 1] in "_$.-")):
            word = CASE_WORD_RE.match(text, index).group()
            index += len(word)
            if word == "case" and _command_position(text, index - len(word), start):
                cases.append(["head", depth])
            elif word == "in" and cases and cases[-1][0] == "head":
                cases[-1][0] = "pattern"
            elif word == "esac" and cases and cases[-1][1] == depth and cases[-1][0] != "head" \
                    and _command_position(text, index - len(word), start):
                cases.pop()
            continue
        elif char == ";" and cases and cases[-1][0] == "body" and cases[-1][1] == depth \
                and text[index + 1:index + 2] in (";", "&"):
            cases[-1][0] = "pattern"  # ;; ;& ;;& start the next pattern
            index += 2
            continue
        elif char == "(":
            if not (cases and cases[-1][0] == "pattern" and cases[-1][1] == depth):  # "(a)" opens a pattern
                depth += 1
        elif char == ")":
            if cases and cases[-1][0] == "pattern" and cases[-1][1] == depth:
                cases[-1][0] = "body"  # the ")" that ends a pattern
            else:
                depth -= 1
                if depth == 0:
                    return index
        index += 1
    return -1


def _close_backtick(text, start):
    index = start
    while index < len(text):
        if text[index] == "\\":
            index += 2
            continue
        if text[index] == "`":
            return index
        index += 1
    return -1


def _expansions(text):
    """Command substitutions inside expanding text (unquoted heredoc bodies)."""
    found, index = [], 0
    while index < len(text):
        if text[index] == "\\":
            index += 2
            continue
        if text.startswith("$((", index):
            end = _close_paren(text, index + 3, False)
            index = len(text) if end < 0 else end + 1
            continue
        if text.startswith("$(", index):
            end = _close_paren(text, index + 2)
            found.append(text[index + 2:] if end < 0 else text[index + 2:end])
            index = len(text) if end < 0 else end + 1
            continue
        if text[index] == "`":
            end = _close_backtick(text, index + 1)
            found.append(text[index + 1:] if end < 0 else text[index + 1:end])
            index = len(text) if end < 0 else end + 1
            continue
        index += 1
    return found


def _ansi_c(raw):
    try:
        return codecs.decode(raw.encode("latin-1", "backslashreplace"), "unicode_escape")
    except (UnicodeError, ValueError):
        return raw


def _read_word(text, index):
    """Raw shell word starting at index (quotes kept); returns (word, next index)."""
    start, quote, parts = index, None, []
    while index < len(text):
        char = text[index]
        if char == "\\" and quote != "'":
            match = CONT_RE.match(text, index)
            if match:  # bash removes a line continuation before it reads the word
                parts.append(text[start:index])
                start = index = match.end()
                continue
        if quote:
            if char == "\\" and quote == '"':
                index += 2
                continue
            if char == quote:
                quote = None
        elif char == "\\":
            index += 2
            continue
        elif char in "'\"":
            quote = char
        elif char in WORD_END:
            break
        index += 1
    return "".join(parts) + text[start:index], index


def _unquote(word):
    if "$'" in word or '$"' in word:
        # the shell reads $'...' (ANSI-C quoting) and $"..." as plain quoted words
        word = re.sub(r"\$'((?:[^'\\]|\\.)*)'", lambda match: shlex.quote(_ansi_c(match.group(1))), word)
        word = word.replace('$"', '"')
    try:
        parts = shlex.split(word, posix=True)
    except ValueError:
        return word.strip("'\"")
    return parts[0] if len(parts) == 1 else word


def scan(command):
    """Split a shell command into simple-command segments plus nested scripts."""
    # line continuations are removed while scanning (join), not up front: inside a quoted heredoc
    # body bash keeps the backslash and the newline, so removing them first would move the
    # line that ends the body and cut the real command after it out as data
    text = command
    script = Script()
    segment, buffer, visible = Segment(None), [], []
    pending, quote, index, size = [], None, 0, len(text)

    def join(position, window=0):
        """Remove the line continuations at position and, when window is set, inside the
        next few characters (an operator split by a continuation: >\\<newline>>)."""
        nonlocal text, size
        steps = -1
        while steps < window and position < size:
            match = CONT_RE.match(text, position)
            if match:
                text = text[:position] + text[match.end():]
                size = len(text)
                continue
            position += 1
            steps += 1

    groups = []  # open groups, innermost last: [kind, piped]; kind "(" for a subshell, "kw" for a compound command

    def track(words, piped):
        """Follow the compound commands a segment opens or closes (its first word). A group is piped when it
        is the target of a pipe (| (...), | { ...; }, | while ...; do ...; done) or lies inside one: every
        command in it reads the pipe (cd /tmp; sh), not only the first."""
        position = 0
        while position < len(words) and words[position] in ("do", "then", "else", "elif", "!", "time"):
            position += 1
        first = words[position] if position < len(words) else ""
        if first in GROUP_OPEN:
            groups.append(["kw", piped])
        elif first in GROUP_CLOSE and groups and groups[-1][0] == "kw":
            groups.pop()

    def flush(next_connector):
        nonlocal segment, buffer
        segment.text = "".join(buffer).strip()
        if segment.text or segment.redirects or segment.herestrings:
            segment.group_piped = any(group[1] for group in groups)
            words = segment.text.split()
            track(words, segment.piped)
            script.segments.append(segment)
            segment = Segment(next_connector)
        elif segment.connector == "|" and next_connector in ("(", "\n"):
            pass  # a subshell "| (sh)" or a line break after the pipe still receives the pipe
        else:
            segment.connector = next_connector if segment.connector is None or next_connector else segment.connector
        buffer = []
        if next_connector == "(":
            groups.append(["(", segment.piped or any(group[1] for group in groups)])
        elif next_connector == ")" and groups and groups[-1][0] == "(":
            groups.pop()

    def substitution(inner):
        script.subs.append(inner)
        return "__DOGMA_SUB_%d__" % (len(script.subs) - 1)

    def take_bodies(position):
        for item in pending:
            delimiter, strip_tabs, slot = item
            quoted = script.heredocs[slot][1]
            lines, carry = [], None
            begin = position
            while position <= size:
                end = text.find("\n", position)
                line = text[position:] if end < 0 else text[position:end]
                position = size + 1 if end < 0 else end + 1
                if not quoted and end >= 0 and (len(line) - len(line.rstrip("\\"))) % 2 == 1:
                    # an expanding body joins a line that ends in a backslash with the next one
                    carry = (carry or "") + line[:-1]
                    continue
                if carry is not None:
                    line, carry = carry + line, None
                check = line.lstrip("\t") if strip_tabs else line
                if check == delimiter:
                    break
                lines.append(line)
            if carry is not None:
                lines.append(carry)
            script.heredocs[slot][0] = "\n".join(lines)
            script.spans[slot] = (begin, min(position, size))
        pending.clear()
        return min(position, size)

    while index < size:
        char = text[index]
        if quote == "'":
            buffer.append(char)
            if char == "'":
                quote = None
            index += 1
            continue
        if char == "$" or (quote is None and char in "<>&|;"):
            join(index + 1, 2)
        if quote == '"':
            if char == "\\" and CONT_RE.match(text, index):
                join(index)
                continue
            if char == "\\" and index + 1 < size:
                buffer.append(text[index:index + 2])
                visible.append(" ")
                index += 2
                continue
            if char == '"':
                quote = None
                buffer.append(char)
                index += 1
                continue
            if text.startswith("$((", index):
                end = _close_paren(text, index + 3, False)
                end = size - 1 if end < 0 else end
                buffer.append(text[index:end + 1])
                index = end + 1
                continue
            if text.startswith("$(", index) or char == "`":
                if char == "`":
                    end = _close_backtick(text, index + 1)
                    inner = text[index + 1:] if end < 0 else text[index + 1:end]
                else:
                    end = _close_paren(text, index + 2)
                    inner = text[index + 2:] if end < 0 else text[index + 2:end]
                buffer.append(substitution(inner))
                index = size if end < 0 else end + 1
                continue
            buffer.append(char)
            visible.append(char)
            index += 1
            continue
        if char == "\\" and CONT_RE.match(text, index):
            join(index)
            continue
        if char == "\\" and index + 1 < size:
            buffer.append(text[index:index + 2])
            visible.append(" ")
            index += 2
            continue
        if text.startswith("$'", index):
            end = index + 2
            while end < size and text[end] != "'":
                end += 2 if text[end] == "\\" else 1
            buffer.append(shlex.quote(_ansi_c(text[index + 2:end])))
            index = end + 1
            continue
        if char in "'\"":
            quote = char
            buffer.append(char)
            index += 1
            continue
        if char == "#" and (not buffer or buffer[-1][-1:] in (" ", "\t")):
            end = text.find("\n", index)
            index = size if end < 0 else end
            continue
        if text.startswith("$((", index):
            end = _close_paren(text, index + 3, False)
            end = size - 1 if end < 0 else end
            buffer.append(text[index:end + 1])
            index = end + 1
            continue
        if text.startswith("$(", index) or text.startswith("<(", index) or text.startswith(">(", index):
            if text.startswith(">(", index):
                script.proc_out = True
            end = _close_paren(text, index + 2)
            inner = text[index + 2:] if end < 0 else text[index + 2:end]
            buffer.append(substitution(inner))
            index = size if end < 0 else end + 1
            continue
        if char == "`":
            end = _close_backtick(text, index + 1)
            inner = text[index + 1:] if end < 0 else text[index + 1:end]
            buffer.append(substitution(inner))
            index = size if end < 0 else end + 1
            continue
        if text.startswith("<<<", index):
            index += 3
            while index < size and text[index] in " \t":
                index += 1
            word, index = _read_word(text, index)
            segment.herestrings.append(word)
            continue
        if text.startswith("<<", index):
            match = HEREDOC_OP_RE.match(text, index)
            index = match.end()
            word, index = _read_word(text, index)
            quoted = any(mark in word for mark in "'\"\\")
            script.heredocs.append([None, quoted])
            pending.append((_unquote(word), bool(match.group(1)), len(script.heredocs) - 1))
            buffer.append(" __DOGMA_HEREDOC_%d__ " % (len(script.heredocs) - 1))
            continue
        if char in "<>" or text.startswith("&>", index):
            back = len(buffer)
            while back > 0 and buffer[back - 1].isdigit():
                back -= 1
            if back < len(buffer) and (back == 0 or buffer[back - 1] in (" ", "\t")):
                del buffer[back:]
            end = index
            while end < size and text[end] in "<>&|" and end - index < 3:
                if text[end] == "|" and end > index and text[end - 1] != ">":
                    break
                if text[end] == "&" and end > index and text[end - 1] == "&":
                    break
                end += 1
            operator = text[index:end]
            index = end
            while True:
                while index < size and text[index] in " \t":
                    index += 1
                if not CONT_RE.match(text, index):
                    break
                join(index)
            if text.startswith("$(", index) or text.startswith("`", index):
                word = ""
            else:
                word, index = _read_word(text, index)
            if operator.endswith("&") and re.match(r"^(\d+-?|-)?$", word):
                segment.dups.append((operator, word))
                continue
            if word:
                segment.redirects.append((operator, word))
            continue
        if char == "\n":
            flush("\n")
            index = take_bodies(index + 1)
            continue
        if char == ";":
            index += 2 if text.startswith(";;", index) else 1
            flush(";")
            continue
        if char == "&":
            if text.startswith("&&", index):
                index += 2
                flush("&&")
            else:
                index += 1
                flush("&")
            continue
        if char == "|":
            if text.startswith("||", index):
                index += 2
                flush("||")
            else:
                index += 2 if text.startswith("|&", index) else 1
                flush("|")
            continue
        if char in "()":
            index += 1
            flush(char)
            continue
        buffer.append(char)
        visible.append(char)
        index += 1
    if quote:
        script.unterminated = True
    flush(None)
    take_bodies(size)
    for body, quoted in script.heredocs:
        if body and not quoted:
            visible.append("\n" + body)
            for inner in _expansions(body):
                script.subs.append(inner)
    script.visible.append("".join(visible))
    script.text = text
    return script


def plain_output(target):
    """True when a redirect target is a normal file or /dev/null, not a device or another special path."""
    return target == "/dev/null" or not target.startswith(("/dev/", "/proc/", "/sys/"))


def resolved(path):
    """The file a path names after symlinks (the path itself when it cannot be resolved)."""
    try:
        return os.path.realpath(path)
    except (OSError, ValueError):
        return path


def tokenize(text):
    try:
        return shlex.split(text, posix=True), True
    except ValueError:
        return [word.strip("'\"") for word in text.split()], False


# --- protected paths -----------------------------------------------------------------

def home():
    return os.path.realpath(os.environ.get("HOME") or "/nonexistent-home")


def _depth(path):
    path = path.strip("/")
    return 0 if not path else path.count("/") + 1


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


_DELETE_GUARD = []


def delete_guard():
    """delete-guard.py, loaded once: its deletion rules are shared with this module."""
    if not _DELETE_GUARD:
        _DELETE_GUARD.append(load_delete_guard())
    return _DELETE_GUARD[0]


def dangerous(path):
    """The hard list of delete-guard.py (on_hard_list): never deleted, moved away or emptied."""
    return delete_guard().on_hard_list(path)


def overwrite_protected(path):
    """Paths that must never be truncated or overwritten (home level, roots, mounts, devices)."""
    path = os.path.normpath(path)
    if path in HARMLESS_DEVICES or path.startswith(("/dev/fd/", "/dev/pts/", "/proc/self/fd/")):
        return False
    if path.startswith("/dev/") or path == "/" or _depth(path) == 1:
        return True
    user_home = home()
    if path in (user_home, os.path.dirname(user_home)) or os.path.dirname(path) == user_home:
        return True
    if path.startswith("/home/"):
        return _depth(path[len("/home"):]) <= 2
    if path.startswith(("/mnt/", "/media/")):
        return _depth(path) <= 3
    return False


def private_roots():
    """Agent-private configuration homes that are never read wholesale nor written.

    Claude Code manages its own configuration home (skills and plugins read and write
    there), so only the Codex home of a machine that also runs Codex is listed."""
    roots = []
    for root in (codex_home(), Path(home()) / ".codex"):
        try:
            roots.append(os.path.realpath(root))
        except (OSError, ValueError):
            continue
    return sorted(set(roots))


def self_paths():
    """The installed dogma plugin (protected against writes from the shell).

    Only an installed copy below the Claude configuration home counts; a source checkout
    of the plugin stays editable."""
    plugin = Path(__file__).resolve().parents[1]
    config = Path(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home(), ".claude"))
    try:
        cache = os.path.realpath(config / "plugins")
    except (OSError, ValueError):
        return []
    return [str(plugin)] if _inside(str(plugin), cache) else []


def _inside(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


LITERAL_WORD_BAD_RE = re.compile(r"[\s\"'\\*?\[\]{}$`]")


def script_operand(verb, args):
    """0 when the first argument is the script an interpreter (bash, sh, python3, perl, node, ...) runs, else None.

    Only a literal first word counts. An option before it can change what runs (bash -s reads the commands
    from stdin, python3 -mvenv and -cCODE attach a value), and a word with quotes, a glob, a brace or an
    expansion can turn into an option or into several words: the word after it is then checked as a write."""
    if not (verb in SHELLS or INTERPRETER_RE.match(verb)) or not args:
        return None
    if args[0].startswith(("-", "+")) or LITERAL_WORD_BAD_RE.search(args[0]):
        return None
    return 0


BRACE_RE = re.compile(r"\{([^{},]*(?:,[^{},]*)+)\}")  # linear: commas only as separators
BRACE_MAX = 4096


def brace_expand(word, limit=64, strict=False):
    """Brace expansion of one word, at most limit variants and a bounded amount of work.

    A real brace expression sits in a short unquoted word; a longer word (for example a JSON
    document passed as one argument) is kept as it is, or refused with strict=True (an
    operand whose targets must be resolved)."""
    if len(word) > BRACE_MAX:
        if strict and "{" in word and "," in word:
            raise Deny("dogma: operand is too long to check its brace expansion; blocked.")
        return [word]
    results, pending, steps = [], [word], 0
    while pending and len(results) < limit and steps < 16 * limit:
        steps += 1
        if time_left() < 0:
            raise Deny("dogma: check ran out of time, command blocked (fail closed).")
        current = pending.pop(0)
        match = BRACE_RE.search(current)
        if not match:
            results.append(current)
            continue
        pending[:0] = [current[:match.start()] + option + current[match.end():]
                       for option in match.group(1).split(",")]
    return results or [word]


def mount_points():
    """Mounts that protect deletes, as (point, whole) pairs.

    A mount found in /proc/self/mounts protects its mount point and the first level below it (whole=False), at
    any depth: a cloud or rclone mount below the home (~/gdrive and ~/gdrive/Folder), a network share or a USB
    stick below /mnt or /media. Deeper files are ordinary: the delete setting decides. A declared mount
    (CLAUDE_MB_DOGMA_PROTECTED_MOUNTS) protects its whole subtree (whole=True)."""
    found = []
    try:
        with open("/proc/self/mounts", encoding="utf-8", errors="replace") as handle:
            for line in itertools.islice(handle, 4096):
                fields = line.split()
                if len(fields) > 1:
                    found.append(fields[1].replace("\\040", " "))
    except OSError:
        found = []
    user_home = home()
    points = []
    for point in found:
        if (_inside(point, user_home) and point != user_home) or point.startswith(("/mnt/", "/media/")):
            points.append((point, False))
    extra = os.environ.get("CLAUDE_MB_DOGMA_PROTECTED_MOUNTS") or ""
    for point in extra.split(":"):
        if point.startswith("/") and not re.fullmatch(r"/mnt/[A-Za-z]/*", point):
            point = os.path.normpath(point)
            if point.startswith(("/mnt/", "/media/")) or (_inside(point, user_home) and point != user_home):
                points.append((point, True))
    return points


def mounted(path):
    """True when path is a protected mount point or its first level, or lies inside a declared mount."""
    return any(_inside(path, point) if whole else (path == point or os.path.dirname(path) == point)
               for point, whole in mount_points())


def repository_root(path):
    try:
        return os.path.isdir(path) and os.path.lexists(os.path.join(path, ".git"))
    except (OSError, ValueError):
        return False


def allowed_roots(cwd):
    """Where apply_patch may write: the repository (or directory) of the session and temporary space."""
    cwd = os.path.realpath(cwd)
    roots = [cwd, "/tmp", "/var/tmp", os.path.realpath(os.environ.get("TMPDIR") or "/tmp")]
    probe = cwd
    while probe and probe != "/":
        if os.path.lexists(os.path.join(probe, ".git")):
            roots.append(probe)
            break
        probe = os.path.dirname(probe)
    return roots


def git_protected_file(path):
    """Git configuration and hooks: writing them can run arbitrary commands later."""
    lowered = path.replace("\\", "/")
    user_home = home()
    return ("/.git/hooks/" in lowered + "/" and "/.git/hooks" in lowered) or lowered.endswith("/.git/config") \
        or path in (os.path.join(user_home, ".gitconfig"), os.path.join(user_home, ".config", "git", "config")) \
        or _inside(path, os.path.join(user_home, ".config", "git"))


def short_flag(args, letter):
    return any(re.match(r"^-[a-zA-Z0-9]*%s[a-zA-Z0-9]*$" % letter, arg) and not arg.startswith("--") for arg in args)


# --- literal variables ----------------------------------------------------------------

LITERAL_ASSIGN_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", re.S)
# the words that start a compound command: an assignment inside one may be skipped or scoped
COMPOUND_WORDS = {"(", "{", "if", "then", "else", "elif", "fi", "do", "done", "for", "while", "until", "case",
                  "esac", "select", "function", "time", "!"}


def compound(text):
    words = text.split()
    return text.lstrip().startswith(("(", "{")) or bool(words) and words[0] in COMPOUND_WORDS


GOVERNING_VERBS = ("export", "readonly", "declare", "typeset")
GOVERNING_OPTIONS = ("-x", "-r", "-g")
# a word that sources a file ("." or "source"): the file runs in this shell and may set any variable
SOURCE_RE = re.compile(r"(?:^|[\s;&|(){}`])(?:source|\.)(?=[\s;&|)}`]|$)")


def plain_assignment(tokens):
    """The NAME=value word of a plain assignment: NAME=value alone, or export, readonly, declare or typeset with
    at most the options -x, -r and -g in front of it. local is no plain assignment (it fails outside a function)."""
    if len(tokens) == 1:
        return tokens[0]
    if len(tokens) >= 2 and tokens[0] in GOVERNING_VERBS and all(token in GOVERNING_OPTIONS for token in tokens[1:-1]):
        return tokens[-1]
    return None


def opaque(segment):
    """True when the segment holds compound syntax (subshell, group, function, loop, conditional): what follows it
    may be skipped or repeated, so literal_plan stops there."""
    tokens, _parsed = tokenize(segment.text)
    return compound(segment.text) or segment.connector == "(" or any(
        token in ("(", ")", "{", "}") or token.endswith("()") for token in tokens)


def literal_plan(script, command):
    """{segment index: (name, value)}: the plain assignments whose value may be used by the delete checks.

    Fail closed: a variable that fails one rule stays unresolved, so its targets are unsure (never allowed).
    The segment is one plain assignment (plain_assignment, no command word), first or after ";" or a newline
    (not after "&&": the command before it may fail and skip it), and followed by ";", a newline or "&&" (not
    "|", "||", "&" or a subshell). Its value after quote removal is not empty and has no $, backtick, ~, glob
    character or blank. The name occurs as a bare word exactly once in the whole command (the assignment
    itself). Only the segments before the first compound syntax count (see opaque): what follows it may be skipped
    or repeated."""
    segments = script.segments
    plan = {}
    for index in range(len(segments) - 1):
        segment, following = segments[index], segments[index + 1]
        if opaque(segment):
            break
        if segment.connector not in (None, ";", "\n") or following.connector not in (";", "\n", "&&"):
            continue
        tokens, parsed = tokenize(segment.text)
        word = plain_assignment(tokens) if parsed else None
        if word is None:
            continue
        match = LITERAL_ASSIGN_RE.fullmatch(word)
        if not match or not match.group(2) or re.search(r"[$`~*?\[\]\s]", match.group(2)):
            continue
        name = match.group(1)
        # a use ($NAME, ${NAME}) is no bare word; the assignment is the one bare occurrence
        if len(re.findall(r"(?<![\w$])(?<!\$\{)%s(?!\w)" % re.escape(name), command)) != 1:
            continue
        plan[index] = (name, match.group(2))
    return plan


# a value that is unknown and no candidate: a backtick (command substitution), a blank or a backslash. A ~, a $-reference
# and a glob character are expanded or matched (literal_candidates), not dropped
LITERAL_VALUE_BAD_RE = re.compile(r"[`\s\\]")
# $NAME, ${NAME} and the defaults ${NAME:-word} / ${NAME-word} (the only parameter forms that are resolved)
PARAM_RE = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)(?::?-([^$`{}'\"\\\s]*))?\}|([A-Za-z_][A-Za-z0-9_]*))")
ASSIGN_WORD_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", re.S)
# a quoted word is read as a command string only when it can hold an assignment (bounded: long words are data)
NESTED_TEXT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=|\bfor\b|\bprintf\b")
LITERAL_NESTED_MAX = 2048
NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# the words that end the word list of a for loop
LIST_END = {";", "&&", "||", "|", "&", "do", "(", ")"}
CANDIDATE_LIMIT = 64  # more candidate values than this: the target is hard-denied (fail closed), with a reason
TOO_MANY_VALUES = ("dogma: a variable of a delete target has more than %d possible values; blocked (fail closed)."
                   % CANDIDATE_LIMIT)


def literal_value(value):
    return not LITERAL_VALUE_BAD_RE.search(value)


def literal_values(text, found=None, depth=0):
    """{NAME: {literal value}}: every literal value the command text gives to a name, anywhere in it: NAME=value
    words (re-assigned, after || or |, in a subshell, as prefix assignment, the empty value included), the words
    of for NAME in ... and printf -v NAME value. Quoted command strings (bash -c, eval, $(...)) are read the same
    way. A value that is no literal is no candidate (literal_value)."""
    found = {} if found is None else found
    if depth > 4:
        return found
    script = scan(text)  # the simple commands (operators split, quotes kept), like the walk sees them
    for segment in script.segments:
        try:
            tokens = shlex.split(segment.text, posix=True)
        except ValueError:
            tokens = segment.text.split()
        for index, token in enumerate(tokens):
            match = ASSIGN_WORD_RE.fullmatch(token)
            if match and literal_value(match.group(2)):
                found.setdefault(match.group(1), set()).add(match.group(2))
            if token == "-v" and index and tokens[index - 1] == "printf" and index + 2 < len(tokens):
                name, value = tokens[index + 1], tokens[index + 2]
                if NAME_RE.fullmatch(name) and literal_value(value):
                    found.setdefault(name, set()).add(value)
            if token == "for" and index + 2 < len(tokens) and tokens[index + 2] == "in" and NAME_RE.fullmatch(
                    tokens[index + 1]):
                for word in tokens[index + 3:]:
                    if word in LIST_END:
                        break
                    if literal_value(word):
                        found.setdefault(tokens[index + 1], set()).add(word)
            if len(token) <= LITERAL_NESTED_MAX and NESTED_TEXT_RE.search(token) and re.search(r"[\s;&|()]", token):
                literal_values(token, found, depth + 1)  # a quoted command string: read the same way
    for inner in script.subs:
        literal_values(inner, found, depth + 1)  # $(...) and the like
    return found


# --- analysis -------------------------------------------------------------------------


class Analysis:
    def __init__(self, event_cwd, permissions, flags):
        self.event_cwd = os.path.realpath(event_cwd)
        self.permissions = permissions
        self.flags = flags
        self.assigns = {}
        self.literals = {}     # variables whose literal assignment already ran in this command (literal_plan)
        self.plan = {}         # literal_plan of the top-level script: {segment index: (name, value)}
        self.all_literals = {}  # literal_values of the whole command: the candidate values of a variable target
        self.top_text = ""     # the whole command text (variables that the command writes at all)
        self.mktemp = {}       # variables holding a fresh mktemp path
        self.batch = []        # (normalized simple command, candidate directories) for delete-guard
        self.deletes = []      # (label, target, directories)
        self.candidates = {}   # (label, target, frozenset(directories)) -> candidate paths (record_delete)
        self.git_ops = []      # (operation, directories, unknown)
        self.evasions = []     # (directories, label)
        self.installs = []
        self.xargs = 0
        self.launcher = False
        self.hashed = {}
        self.written = set()
        self.pipe_next = None
        self.git_alt = False
        self.anchors = {self.event_cwd}
        self.top = None        # Script of the whole command (first walk)
        self.data_bodies = set()  # heredoc slots of self.top that are only data (see segment)
        self.shadowed = None   # cat, tee or an interpreter may be redefined by the command (see shadowing)
        self.proc_out = False  # some script of the command has an output process substitution ">(...)"
        self.private = private_roots()
        self.own = self_paths()

    # helpers -----------------------------------------------------------------------
    def deny(self, feature, reason):
        if feature is None or self.flags.get(feature, True):
            raise Deny(reason)

    def expand(self, word, cwd=None):
        """Expand ~, ~user, ~+, $HOME and variables assigned in this command; unknown variables stay.

        Reads, redirects and commands use the sequential values of the assignments of this command. Delete
        targets are judged by expansions() instead (candidate values)."""
        if word == "~" or word.startswith("~/"):
            word = home() + word[1:]
        elif (word == "~+" or word.startswith("~+/")) and cwd:
            word = cwd + word[2:]
        elif word.startswith("~") and re.match(r"^~[A-Za-z0-9._-]+(/|$)", word):
            expanded = os.path.expanduser(word)
            if expanded != word:
                word = expanded

        def replace(match):
            name = match.group(1) or match.group(2)
            if name == "HOME":
                return home()
            if name == "PWD":
                return cwd or match.group(0)
            if name in self.literals:
                return self.literals[name]
            if name in self.mktemp:
                return self.mktemp[name]
            if name in self.assigns and name not in ("OLDPWD",):
                return self.assigns[name]
            if name in ("CODEX_HOME", "CLAUDE_CONFIG_DIR", "USER", "TMPDIR", "XDG_RUNTIME_DIR"):
                value = os.environ.get(name)
                if name == "CODEX_HOME" and not value:
                    value = str(codex_home())
                if value:
                    return value
            return match.group(0)

        return VAR_RE.sub(replace, word)

    def join(self, directory, path, physical=False):
        """Absolute path of path below directory; None when unknown.

        The default normalizes ".." textually like the shell's logical cd. physical=True keeps
        the path as the kernel sees it: a ".." after a symlink component is resolved against
        the link target by realpath later, so it must never be collapsed textually here."""
        path = self.expand(path, directory)
        if "$" in path or SUB_RE.search(path) or path.startswith("~"):
            return None
        if not path.startswith("/"):
            if directory is None:
                return None
            path = os.path.join(directory, path)
        return path if physical else os.path.normpath(path)

    def chdir(self, directory, path):
        """Working directory after a chdir() call (option -C of the environment wrapper, sudo -D,
        tar -C, git -C): resolved physically, unlike the logical shell cd."""
        joined = self.join(directory, path, physical=True)
        if joined is None or missing_before_dotdot(joined):
            return None  # unknown working directory: relative targets fail closed
        return os.path.realpath(joined)

    def bare_write(self, name):
        """True when the command names the variable as a bare word (an assignment, read, for, printf -v ...)."""
        return bool(re.search(r"(?<![\w$])(?<!\$\{)%s(?!\w)" % re.escape(name), self.top_text))

    def variable_values(self, name, directory, candidates):
        """(values, certain) of one variable of a target, or None when it has no certain value and candidates is off.

        Known for sure: HOME, PWD, a mktemp path, a live literal assignment (literal_plan) and a variable the
        command never writes (its environment value). Otherwise the candidates are its environment value (set:
        always; unset or empty: the empty value, unless a live literal assignment governs the use) and every
        literal value that the command gives to the name (literal_values). An unknown value adds no candidate."""
        if name == "HOME":
            return {home()}, True
        if name == "PWD":
            return ({directory}, True) if directory else None
        if name in self.mktemp:
            return {self.mktemp[name]}, True
        governed = name in self.literals
        environment = os.environ.get(name) or ""
        if not candidates:
            # the certain value only (overwrite and read targets): a governed literal, or a set variable the command
            # never writes; an unset variable is unknown, as before
            if governed:
                return {self.literals[name]}, True
            if environment and not self.bare_write(name):
                return {environment}, True
            return None
        values = set()
        for literal in self.all_literals.get(name, ()):
            values |= self.literal_candidates(literal, 0)
        if governed:
            values.add(self.literals[name])
        if environment or not governed:
            values.add(environment)
        return values, len(values) == 1 and (governed or not self.bare_write(name))

    def name_candidates(self, name, level):
        """The values of a variable named inside a literal: its environment value or empty and, at level 0 only,
        its literal values read one level deeper (level 1 names are the environment value or empty only)."""
        options = {os.environ.get(name) or ""}
        if level == 0:
            for literal in self.all_literals.get(name, ()):
                options |= self.literal_candidates(literal, level + 1)
        return options

    def literal_candidates(self, value, level):
        """The values one literal given to a variable can have: a leading ~ or ~/ is HOME, $HOME and $NAME (also
        ${NAME} and ${NAME:-word} / ${NAME-word}) are expanded to name_candidates; the default word is a candidate
        too. Glob characters stay (the target is matched like a glob). An unknown part (a command substitution,
        another user's home, another parameter form) makes the literal unknown: an empty set, no candidate."""
        if "`" in value or "$(" in value:
            return set()
        if value == "~" or value.startswith("~/"):
            value = home() + value[1:]
        elif value.startswith("~"):
            return set()
        if "$" in PARAM_RE.sub("", value):
            return set()
        results, last = {""}, 0
        for match in PARAM_RE.finditer(value):
            name = match.group(1) or match.group(3)
            options = {home()} if name == "HOME" else self.name_candidates(name, level)
            default = match.group(2)
            if default is not None:
                options = {option or default for option in options} | {default}
            literal = value[last:match.start()]
            results = {result + literal + option for result in results for option in options}
            if len(results) > CANDIDATE_LIMIT:
                raise Deny(TOO_MANY_VALUES)
            last = match.end()
        return {result + value[last:] for result in results}

    def expansions(self, word, directory, candidates=False):
        """(values, certain): the values a word can have after its variables are expanded, or None when a part is
        unknown (command or arithmetic substitution, another user's home, a parameter form other than $NAME,
        ${NAME} and ${NAME:-word} / ${NAME-word}, or a variable without candidates). certain: one value for sure."""
        if "`" in word or "$(" in word:
            return None
        if word == "~" or word.startswith("~/"):
            word = home() + word[1:]
        elif word == "~+" or word.startswith("~+/"):
            if not directory:
                return None
            word = directory + word[2:]
        elif word.startswith("~"):
            return None
        if "$" in PARAM_RE.sub("", word):
            return None
        values, certain, last = [""], True, 0
        for match in PARAM_RE.finditer(word):
            found = self.variable_values(match.group(1) or match.group(3), directory, candidates)
            if found is None:
                return None
            options, sure = found
            default = match.group(2)
            if default is not None:
                # ${NAME:-word}: an empty value takes the default; the default is a candidate itself
                options = {option or default for option in options} | {default}
                sure = sure and len(options) == 1
            literal = word[last:match.start()]
            values = [value + literal + option for value in values for option in sorted(options)]
            certain = certain and sure
            if len(values) > CANDIDATE_LIMIT:
                raise Deny(TOO_MANY_VALUES)
            last = match.end()
        values = sorted({value + word[last:] for value in values})
        return values, certain and len(values) == 1

    def absolute(self, directory, value):
        """The absolute form of one expanded value (below directory when relative); None when not known."""
        if "$" in value or SUB_RE.search(value) or value.startswith("~"):
            return None
        if value.startswith("/"):
            return value
        return os.path.join(directory, value) if directory is not None else None

    def sure(self, word, directories):
        """True when the operand has one certain value in every directory (no candidate is needed)."""
        for variant in brace_expand(word, strict=True):
            for directory in directories:
                found = self.expansions(variant, directory, candidates=True)
                if found is None or not found[1]:
                    return False
        return True

    def targets(self, word, directories, follow=True, candidates=False):
        """Absolute targets of one operand (brace and glob aware); None = cannot be resolved.

        follow=False: a symlink named as the last component is the target itself (rm and mv
        act on the link), so only its directory is resolved; a trailing slash still follows.
        candidates=True (delete targets): a variable without one certain value yields a target for every
        candidate value (see variable_values), so a hard candidate is found; an empty value deletes nothing."""
        def real(path, trailing):
            if follow or trailing:
                return os.path.realpath(path)
            name = os.path.basename(path)
            if name in ("", ".", ".."):
                return os.path.realpath(path)
            return os.path.join(os.path.realpath(os.path.dirname(path)), name)

        for variant in brace_expand(word, strict=True):
            for directory in directories:
                found = self.expansions(variant, directory, candidates)
                if found is None:
                    yield None
                    continue
                for value in found[0]:
                    if not value:
                        continue
                    path = self.absolute(directory, value)
                    if path is None:
                        yield None
                        continue
                    if missing_before_dotdot(path):
                        yield None  # where the following ".." leads is unknown before running: unsure
                        continue
                    trailing = value.endswith("/")
                    glob_match = GLOB_RE.search(path)
                    if glob_match:
                        base = path[:glob_match.start()]
                        base = base[:base.rfind("/") + 1] or "/"
                        yield os.path.join(os.path.realpath(base), "x")
                        for found_path in itertools.islice(glob.iglob(path), 64):
                            yield real(found_path, trailing)
                        continue
                    yield real(path, trailing)

    def anchor(self, path, strict=False):
        """True when path is the working directory (unless strict) or one of its parents."""
        for directory in self.anchors | {d for d in self.known if d}:
            if directory == path:
                if not strict:
                    return True
            elif directory.startswith(path.rstrip("/") + "/"):
                return True
        return False

    @property
    def known(self):
        return getattr(self, "_known", set())

    def unsure(self, label, target, directories):
        """A delete-type target that cannot be resolved for sure: recorded as a finding, so the delete setting
        of DOGMA-PERMISSIONS.md decides (file-protection.sh). Never a denial of its own."""
        self.record_delete(label, target, directories)

    def record_delete(self, label, target, directories):
        """A delete-type finding. A target with shell variables also gets its candidate paths (candidate_paths)."""
        self.deletes.append((label, target, set(directories)))
        paths = self.candidate_paths(target, directories)
        if paths is not None:
            self.candidates[(label, target, frozenset(directories))] = paths

    def candidate_paths(self, target, directories):
        """Absolute paths of every value that a target with shell variables can have, or None (no list).

        None unless every variable of the target is set by the command itself (all_literals: a literal assignment,
        export, readonly, declare, a for word or printf -v), so an environment-only or unset value on its own never
        counts, the command sources no file (SOURCE_RE), and the target has no command substitution, glob, brace or
        other parameter form. The candidate values are the same as in variable_values (an unset value adds the
        empty value). The list is only used for the temp-root check (delete-guard.py temp_only)."""
        if "$" not in target or not directories or None in directories or SOURCE_RE.search(self.top_text):
            return None  # a sourced file runs in this shell and may set any variable
        rest = PARAM_RE.sub("", target)
        if "$" in rest or SUB_RE.search(target) or re.search(r"[*?\[\]{}()\\`~]", rest):
            return None
        names = {match.group(1) or match.group(3) for match in PARAM_RE.finditer(target)}
        if not names <= set(self.all_literals) or names & set(self.mktemp):
            return None  # a mktemp path is temp only where TMPDIR is: it keeps the setting (not a literal value)
        paths = set()
        try:
            for directory in directories:
                found = self.expansions(target, directory, candidates=True)
                if found is None:
                    return None
                for value in found[0]:
                    path = self.absolute(directory, value) if value else None
                    if path is None:
                        return None
                    paths.add(path)
        except Deny:
            return None
        return sorted(paths) if len(paths) <= CANDIDATE_LIMIT else None

    def protect_delete(self, operands, directories, label, contents=False, follow=True):
        """Own protected-path check for deleting operations, independent of §0lgy."""
        self._known = set(directories)
        for operand in operands:
            if not self.sure(operand, directories):
                # no single certain value: every candidate is checked below, the setting decides as well
                self.unsure(label, operand, directories)
            for path in self.targets(operand, directories, follow, candidates=True):
                if path is None:
                    self.unsure(label, operand, directories)
                    continue
                if dangerous(path) or self.anchor(path, strict=contents) or \
                        (mounted(path) and not delete_guard().temp_root_of(path)):
                    raise Deny("dogma: %s of a protected path (%s) is never allowed." % (label, path))
                if not contents and repository_root(path):
                    raise Deny("dogma: %s of a whole repository or worktree (%s) is never allowed; let the user "
                               "remove it." % (label, path))

    def protect_overwrite(self, operands, directories, label, unresolved_ok=False):
        for operand in operands:
            for path in self.targets(operand, directories):
                if path is None:
                    if not unresolved_ok:
                        self.unsure(label, operand, directories)
                    continue
                if overwrite_protected(path):
                    raise Deny("dogma: %s of a protected path (%s) is never allowed." % (label, path))

    def protect_destination(self, destination, sources, directories, label, into=False, file_only=False,
                            contents=False):
        """Overwrite check of a cp/install/mv destination. When it is an existing directory
        (or given with -t), the files land inside it: each <dir>/<basename(source)> is checked
        instead of the directory, and only an existing protected entry there is refused."""
        for path in self.targets(destination, directories):
            if path is None:
                self.unsure(label, destination, directories)
                continue
            if not file_only and (into or os.path.isdir(path)):
                for source in sources:
                    # rsync src/ copies the contents of src: the names are unknown here
                    name = "" if contents and source.endswith("/") else \
                        os.path.basename(self.expand(source).rstrip("/"))
                    if not name or name in (".", "..") or "$" in name or SUB_RE.search(name):
                        # unknown name: only refused where any entry of that directory is protected
                        if overwrite_protected(os.path.join(path, "x")):
                            raise Deny("dogma: %s into %s cannot be checked; blocked." % (label, path))
                        continue
                    if GLOB_RE.search(name):
                        children = [os.path.join(path, os.path.basename(found))
                                    for found in itertools.islice(glob.iglob(os.path.join(path, name)), 64)]
                    else:
                        children = [os.path.join(path, name)]
                    for child in children:
                        # an existing entry is written through, so a symlink counts by its target
                        if os.path.lexists(child) and (overwrite_protected(child)
                                                       or overwrite_protected(os.path.realpath(child))):
                            raise Deny("dogma: %s of a protected path (%s) is never allowed." % (label, child))
                continue
            if overwrite_protected(path):
                raise Deny("dogma: %s of a protected path (%s) is never allowed." % (label, path))

    # walking ---------------------------------------------------------------------------
    def walk(self, command, directories, depth=0):
        if depth > 8:
            raise Deny("dogma: command nesting is too deep to check safely.")
        if time_left() < 0:
            raise Deny("dogma: check ran out of time, command blocked (fail closed).")
        script = scan(command)
        if self.top is None:
            self.top = script
            self.plan = literal_plan(script, command)
            self.all_literals = literal_values(command)
            self.top_text = command
        self.proc_out = self.proc_out or script.proc_out
        self.subs = script.subs
        visible = "".join(script.visible)
        if self.flags.get("token_protection", True):
            if "${!" in visible:
                raise Deny("dogma: indirect variable listing may expose credentials.")
            for name in SHELL_VAR_RE.findall(visible):
                if _sensitive_variable(name):
                    raise Deny("dogma: command references a token or secret variable. Do not print or pass credentials.")
        start = set(directories)
        current = set(directories)
        seen = set(directories)
        segments = script.segments
        for index, segment in enumerate(segments):
            if time_left() < 0:
                raise Deny("dogma: check ran out of time, command blocked (fail closed).")
            if segment.connector not in (None, "&&"):
                current = current | start
                start = set(current)
            following = segments[index + 1] if index + 1 < len(segments) else None
            self.pipe_next = tokenize(following.text)[0] if following is not None and following.connector == "|" \
                else None
            self.subs = script.subs
            if segment.connector == "|" and index:
                segment.piped_in = self.producer(segments[index - 1], script.heredocs)
            current = self.segment(segment, script.heredocs, current, depth)
            if script is self.top and index in self.plan:
                name, value = self.plan[index]
                self.literals[name] = value  # from here on the later segments see the value
            seen |= current
        for inner in script.subs:
            self.walk(inner, seen, depth + 1)
        return seen

    def segment(self, segment, heredocs, directories, depth):
        tokens, parsed = tokenize(segment.text)
        bodies, kept, slots = [], [], []
        for token in tokens:
            match = HEREDOC_RE.fullmatch(token)
            if match:
                bodies.append(heredocs[int(match.group(1))])
                slots.append(int(match.group(1)))
            else:
                kept.append(token)
        tokens = kept
        if slots and self.top is not None and heredocs is self.top.heredocs:
            self.mark_data_bodies(tokens, slots, heredocs, segment)
        while tokens and tokens[0] in KEYWORDS:
            tokens.pop(0)
        if tokens and tokens[0] in ("for", "select", "case"):
            return directories
        while tokens and tokens[-1] in ("}", "fi", "done", "esac", "]]"):
            tokens.pop()
        if not parsed and re.search(r"\b(rm|unlink|shred|rmdir|git|dd|mkfs|find|xargs|eval)\b", segment.text):
            raise Deny("dogma: command with unbalanced quoting cannot be checked safely.")
        bare = not tokens or all(ASSIGN_RE.match(token) for token in tokens) or tokens[0] in (":", "true")
        verb = os.path.basename(self.expand(tokens[0])) if tokens and not bare else ""
        for operator, word in segment.redirects:
            target = _unquote(word)
            if operator in ("<", "<&", "<>"):
                self.check_path(target, directories, "read", force=True)
            if operator.startswith((">", "&>")) or operator == "<>":
                self.check_path(target, directories, "write", force=True)
                if STREAM_TARGET_RE.match(target):
                    continue  # /dev/stdout and friends: no file, nothing to protect (nor to remember)
                self.remember_written(target, directories)
                self.critical_target(target, directories, ">>" in operator)
                if ">>" not in operator:
                    self.protect_overwrite([target], directories, "overwrite", unresolved_ok=not bare)
                    # a redirect without a command truncates its file; after a compound command (done, }, fi,
                    # a closing parenthesis) it is bare too. Only the literal /dev/null target (after quote
                    # removal) is exempt: no normalized form, so "/dev//null" or "x/../../dev/null" through a
                    # symlink still counts as a file
                    if bare and target != "/dev/null":
                        self.record_delete("truncate", target, directories)
        if verb in SHELLS | {"sh"} or INTERPRETER_RE.match(verb or "-"):
            for body, quoted in bodies:
                if not quoted and body and ("$(" in body or "`" in body):
                    self.deny("dependency_verification", "dogma: script built at run time is fed to %s; it cannot "
                                                         "be checked." % verb)
            for word in segment.herestrings:
                if SUB_RE.search(word) or "$(" in word or "`" in word or word.startswith("$\""):
                    self.deny("dependency_verification", "dogma: script built at run time is fed to %s; it cannot "
                                                         "be checked." % verb)
        return self.command(tokens, segment, bodies, directories, depth)

    def mark_data_bodies(self, tokens, slots, heredocs, segment):
        """Quoted heredoc bodies that are no shell text: written by cat or tee (not piped on),
        or the stdin of an interpreter, whose code this analysis checks itself (code()).

        delete-guard.py re-reads the original command line by line; such a body is left out
        there, so delete text that is only data (a script written to a file) is no command.
        Only when the output goes to a normal file or /dev/null: a body that reaches a shell
        (cat <<'EOF' > >(sh), > /dev/stdout, >&3 after exec 3> >(sh)) stays shell text."""
        if not tokens or self.pipe_next is not None:
            return
        verb = os.path.basename(tokens[0])
        if verb not in ("cat", "tee") and not INTERPRETER_RE.match(verb):
            return
        if self.shadowing():
            return  # a function, alias, hash or PATH may make cat or tee run the body as a shell
        if any(SUB_RE.search(token) for token in tokens):
            return
        outputs = [_unquote(word) for operator, word in segment.redirects
                   if operator.startswith((">", "&>")) or operator == "<>"]
        if verb == "tee":
            outputs += [token for token in tokens[1:] if not token.startswith("-")]
        if not all(plain_output(target) for target in outputs):
            return
        if any(word not in ("", "-", "0", "1", "2") for _operator, word in segment.dups):
            return
        for slot in slots:
            if heredocs[slot][1]:
                self.data_bodies.add(slot)

    def shadowing(self):
        """True when the command text can redefine cat, tee or an interpreter (SHADOW_RE: a function,
        an alias, hash, enable, builtin, a changed PATH, a sourced file). The text outside the heredoc
        bodies counts, and the body of a heredoc that is read by a sourced file (source /dev/stdin <<EOF)."""
        if self.shadowed is None:
            script = self.top
            cuts = []
            for segment in script.segments:
                words = tokenize(segment.text)[0]
                slots = [int(match.group(1)) for match in map(HEREDOC_RE.fullmatch, words) if match]
                if slots and not any(word in ("source", ".") for word in words):
                    cuts += [script.spans[slot] for slot in slots if slot in script.spans]
            text, last, parts = script.text, 0, []
            for start, end in sorted(cuts):
                if start >= last:
                    parts.append(text[last:start])
                    last = end
            parts.append(text[last:])
            self.shadowed = bool(SHADOW_RE.search("".join(parts)))
        return self.shadowed

    def without_data_bodies(self, command):
        """The command for the text checks of delete-guard.py, without data heredoc bodies."""
        if self.top is None or not self.data_bodies:
            return command
        if self.proc_out or re.search(r"\b(?:mkfifo|mknod)\b", command):
            return command  # a body could reach a shell through a process or a named pipe
        text, cut = self.top.text, 0
        parts = []
        for slot in sorted(self.data_bodies, key=lambda item: self.top.spans.get(item, (0, 0))[0]):
            start, end = self.top.spans.get(slot, (cut, cut))
            if start < cut:
                return command  # overlapping spans: keep the full text (fail safe)
            parts.append(text[cut:start])
            cut = end
        parts.append(text[cut:])
        return "".join(parts)

    def batch_word(self, arg):
        """An argument as delete-guard.py reads it: literal and mktemp variables are substituted, any other
        variable stays as written, so delete-guard.py sees it unresolved too (unsure, never a guessed value)."""
        def replace(match):
            name = match.group(1) or match.group(2)
            if name in self.literals:
                return self.literals[name]
            return self.mktemp.get(name, match.group(0))
        return VAR_RE.sub(replace, arg)

    def command(self, tokens, segment, bodies, directories, depth, wrapped=False):
        while tokens and ASSIGN_RE.match(tokens[0]):
            self.assign(tokens[0], directories)
            tokens = tokens[1:]
        if not tokens:
            return directories
        first = self.expand(tokens[0])
        if re.fullmatch(r"\{[^{}]*,[^{}]*\}", first):
            tokens = first[1:-1].split(",") + tokens[1:]
            first = tokens[0]
            wrapped = True
        if "$" in first or SUB_RE.search(first) or "`" in first or not first:
            self.dynamic(tokens, segment, directories)
            # what runs is only known at run time: its arguments and input are opaque text
            self.embedded(tokens[1:], segment, {None}, depth, bodies, executed=True)
            return directories
        if first in self.hashed:
            first = self.hashed[first]
            wrapped = True
        tokens = [first] + tokens[1:]
        verb = os.path.basename(first)
        args = tokens[1:]
        self.check_written_run(first, verb, args, directories, segment)
        safe = [self.batch_word(arg) for arg in args]
        self.batch.append(([verb] + [variant for arg in safe for variant in brace_expand(arg)], set(directories)))

        if verb in WRAPPER_VALUE_OPTIONS or verb in ("env", "timeout", "watch", "xargs", "flock"):
            return self.wrapper(verb, args, segment, bodies, directories, depth)
        if verb in ("cd", "pushd", "popd"):
            return self.change_directory(verb, args, directories)
        if verb in ("export", "declare", "typeset", "local", "readonly"):
            for arg in args:
                if ASSIGN_RE.match(arg):
                    self.assign(arg, directories)

        self.check_arguments(verb, args, directories)
        self.check_dumps(verb, args)
        self.check_install(verb, args)
        self.check_delete(verb, args, directories)
        self.check_special(verb, args, segment, bodies, directories, depth)
        piped = bool(segment and segment.piped)

        if verb in ("git", "hub"):
            self.git(args, directories, depth)
        elif verb == "eval":
            inner = " ".join(args)
            if "$" in inner or SUB_RE.search(inner) or "`" in inner:
                if not DELETE_TEXT_RE.search(inner):
                    raise Deny("dogma: eval of text built at run time cannot be checked; blocked (fail closed).")
                # text built at run time that deletes: unsure, the delete setting decides
                self.unsure("eval", inner[:200], directories)
            else:
                self.walk(inner, directories, depth + 1)
        elif verb in getopt.LAUNCHERS or verb in ("tmux", "bwrap"):
            self.launch(verb, args, segment, bodies, directories, depth)
        elif verb in ("runuser", "su"):
            self.switch_user(verb, args, segment, bodies, directories, depth, piped)
        elif verb in SHELLS or verb in ("su", "runuser", "script"):
            self.shell(verb, args, segment, bodies, directories, depth, piped)
        elif INTERPRETER_RE.match(verb):
            self.interpreter(verb, args, segment, bodies, directories, depth, piped)
        elif verb == "find":
            self.find(args, segment, directories, depth)
        elif verb in ("source", ".") and args and SUB_RE.search(args[0]):
            self.deny("dependency_verification",
                      "dogma: sourcing a script built at run time (for example a download) cannot be checked.")
        elif verb == "alias":
            for arg in args:
                if "=" in arg:
                    self.walk(arg.split("=", 1)[1], directories, depth + 1)
        elif verb == "trap" and args:
            self.walk(args[0], directories, depth + 1)
        elif verb in ("awk", "gawk", "mawk", "nawk"):
            self.awk(args, segment, directories, depth)
        elif verb in ("jq", "gojq"):
            self.jq(args)
        elif verb not in SAFE_VERBS:
            self.embedded(args, segment, directories, depth)
        return directories

    def assign(self, token, directories):
        name, value = ASSIGN_RE.match(token).groups()
        self.assigns[name] = self.expand(value)
        self.mktemp.pop(name, None)
        match = SUB_RE.fullmatch(value.strip("\"'"))
        subs = getattr(self, "subs", [])
        if match and int(match.group(1)) < len(subs) and MKTEMP_RE.match(subs[int(match.group(1))]):
            # a fresh temporary file or directory: known-safe to delete (like delete-guard.py)
            self.mktemp[name] = "/tmp/dogma-mktemp-" + name
            self.assigns[name] = self.mktemp[name]
        self.check_path(value, directories, "read")
        if name == "IFS":
            self.launcher = True
        if name in EXEC_ENV_ALWAYS and value:
            raise Deny("dogma: %s makes programs load code that cannot be checked; blocked." % name)
        if name == "NODE_OPTIONS" and re.search(r"(^|\s)(-r|--require|--import|--loader|--experimental-loader)\b",
                                                 value):
            raise Deny("dogma: NODE_OPTIONS with a preloaded module cannot be checked; blocked.")
        if name in EXEC_ENV_COMMAND and value.strip():
            self.walk(_unquote(value) if value[:1] in "'\"" else value, directories, 1)

    def wrapper(self, verb, args, segment, bodies, directories, depth):
        rest = list(args)
        if verb == "command" and rest[:1] and rest[0] in ("-v", "-V"):
            return directories
        if verb in getopt.WRAPPERS:
            # env, sudo, doas: options by the shared parser; the shell's own working
            # directory stays unchanged (env -C and sudo -D only apply to the wrapped command)
            self.run_wrapped(verb, rest, segment, bodies, directories, depth)
            return directories
        if verb == "timeout":
            while rest and rest[0].startswith("-"):
                item = rest.pop(0)
                if item in ("-s", "-k", "--signal", "--kill-after") and rest:
                    rest.pop(0)
            rest = rest[1:]
        elif verb == "watch":
            while rest and rest[0].startswith("-"):
                item = rest.pop(0)
                if item in ("-n", "--interval") and rest:
                    rest.pop(0)
            self.walk(" ".join(rest), directories, depth + 1)
            return directories
        elif verb == "xargs":
            return self.run_xargs(rest, segment, bodies, directories, depth)
        elif verb == "flock":
            while rest and rest[0].startswith("-"):
                item = rest.pop(0)
                if item in ("-c", "--command") and rest:
                    self.walk(rest[0], directories, depth + 1)
                    return directories
                if item in WRAPPER_VALUE_OPTIONS["flock"] and rest:
                    rest.pop(0)
            rest = rest[1:]
            if rest[:1] in (["-c"], ["--command"]) and len(rest) > 1:
                self.walk(rest[1], directories, depth + 1)
                return directories
        else:
            values = WRAPPER_VALUE_OPTIONS.get(verb, set())
            while rest and rest[0].startswith("-") and rest[0] != "-":
                item = rest.pop(0)
                if item == "--":
                    break
                if item in values and rest:
                    rest.pop(0)
        if not rest:
            return directories
        return self.command(rest, segment, bodies, directories, depth, wrapped=True)

    def run_wrapped(self, verb, args, segment, bodies, directories, depth, splits=0):
        """env, sudo or doas: parse the options with dogma_getopt, then check the wrapped command.

        env -S/--split-string: the string is split and option parsing goes on with its words
        followed by the remaining arguments (as GNU env does). An unknown or ambiguous option
        may take a value, so the wrapped command's working directory becomes unknown and
        relative targets fail closed."""
        options, rest, split = getopt.scan_wrapper(verb, args)
        for name, value in options:
            if name.startswith("?"):
                directories = {None}
            elif (verb, name) in (("env", "-C"), ("env", "--chdir"), ("sudo", "-D"), ("sudo", "--chdir")):
                directories = {self.chdir(directory, value) if value is not None else None
                               for directory in directories}
            elif verb == "sudo" and name in ("-R", "--chroot", "-i", "--login"):
                # another root, or a login shell that starts in the target user's home
                directories = {None}
        if split is not None:
            if splits > 8:
                raise Deny("dogma: env -S nesting is too deep to check safely.")
            try:
                words = getopt.env_split(split)
            except ValueError as error:
                raise Deny("dogma: env -S string cannot be checked (%s); blocked." % error)
            return self.run_wrapped(verb, words + rest, segment, bodies, directories, depth, splits + 1)
        if verb == "env":
            if rest[:1] == ["-"]:
                rest = rest[1:]  # a lone "-" means -i
            while rest and ASSIGN_RE.match(rest[0]):
                self.assign(rest.pop(0), directories)
            if not rest:
                if self.counts_only():
                    return directories
                self.deny("token_protection", "dogma: environment dump may expose credentials.")
                return directories
        if verb == "doas" and getopt.has(options, "-C"):
            return directories  # nothing runs (doas -C only checks a configuration file)
        if not rest:
            if verb != "env" and getopt.has(options, "-s", "-i", "--shell", "--login"):
                # a shell without a command reads its script from stdin, like sh does
                self.shell("sh", [], segment, bodies, directories, depth, bool(segment and segment.piped))
            return directories
        return self.command(rest, segment, bodies, directories, depth, wrapped=True)

    def switch_user(self, verb, args, segment, bodies, directories, depth, piped):
        """su and runuser: a login (-, -l, --login) starts in the target user's home, so the
        working directory becomes unknown and relative targets fail closed; -c/--command and
        --session-command strings and shell arguments after the user name are checked."""
        options, operands = getopt.parse(verb, args)
        login = getopt.has(options, "-l", "--login") or operands[:1] == ["-"]
        if login or any(name.startswith("?") for name, _value in options):
            directories = {None}
        shell = getopt.value(options, "-s", "--shell")
        if shell is not None and os.path.basename(shell) not in SHELLS:
            raise Deny("dogma: %s with the program %s as shell cannot be checked; blocked." % (verb, shell[:60]))
        commands = [value for name, value in options
                    if name in ("-c", "--command", "--session-command") and value is not None]
        for value in commands:
            if SUB_RE.search(value):
                self.deny("dependency_verification",
                          "dogma: %s runs a script built at run time; it cannot be checked." % verb)
            self.walk(value, directories, depth + 1)
        if verb == "runuser" and getopt.has(options, "-u", "--user"):
            if operands:
                self.command(operands, segment, bodies, directories, depth + 1, wrapped=True)
            return
        rest = operands[1:] if operands[:1] == ["-"] else operands
        if len(rest) > 1:
            # arguments after the user name go to the user's shell (su root -- -c "...")
            self.shell("sh", rest[1:], segment, [], directories, depth, False)
        elif not commands:
            # no command: the user's shell reads its script from stdin, like sh does
            self.shell("sh", [], segment, bodies, directories, depth, piped)

    def launch(self, verb, args, segment, bodies, directories, depth):
        """Launchers that run a command in their own working directory or root.

        The given directory is resolved physically; where the launcher starts somewhere
        else (systemd-run defaults, tmux windows, a login) the working directory is unknown
        and relative targets fail closed. Another root or mount namespace cannot be mapped
        to host paths, so a command run there is blocked."""
        def rooted(root):
            if root is None or os.path.realpath(self.join(next(iter(directories)), root, physical=True)
                                                or root) != "/":
                raise Deny("dogma: %s runs the command below another root or mount namespace; its paths "
                           "cannot be checked, so it is blocked." % verb)

        def workdir(value):
            if value is None or "#{" in value or value.startswith("-"):
                return {None}
            if value == "~" or value.startswith("~/"):
                value = home() + value[1:]
            return {self.chdir(directory, value) for directory in directories}

        if verb == "tmux":
            return self.launch_tmux(args, segment, bodies, directories, depth)
        if verb == "bwrap":
            return self.launch_bwrap(args, segment, bodies, directories, depth, rooted, workdir)
        options, rest = getopt.parse(verb, args)
        unknown = any(name.startswith("?") for name, _value in options)
        # option values may hold commands the launcher runs (systemd-run -p ExecStartPre=...)
        self.opaque([value.split("=", 1)[1] if "=" in value else value for _name, value in options if value],
                    depth)
        if verb == "systemd-run":
            if getopt.has(options, "-M", "--machine", "-H", "--host", "-C", "--capsule"):
                directories = {None}  # runs on another machine or in a capsule
            elif not getopt.has(options, "--scope", "-d", "--same-dir"):
                directories = {None}  # a service starts in / or the user's home
            for name, value in options:
                if name == "--working-directory":
                    directories = workdir(value)
                elif name in ("-p", "--property") and value and value.split("=", 1)[0] == "WorkingDirectory":
                    directories = workdir(value.split("=", 1)[1] if "=" in value else None)
                elif name in ("-p", "--property") and value and value.split("=", 1)[0] in (
                        "RootDirectory", "RootImage", "BindPaths", "TemporaryFileSystem", "MountImages"):
                    rooted(None)
        elif verb == "nsenter":
            for name, value in options:
                if name in ("-w", "--wd"):
                    directories = workdir(value)
                elif name == "--wdns":
                    directories = {None}
                elif rest and (name in ("-m", "--mount", "-a", "--all") or name in ("-r", "--root")):
                    rooted(value if name in ("-r", "--root") else None)
        elif verb == "unshare":
            for name, value in options:
                if name in ("-w", "--wd"):
                    directories = workdir(value)
                elif name in ("-R", "--root") and rest:
                    rooted(value)
        elif verb == "start-stop-daemon":
            if not getopt.has(options, "-S", "--start"):
                return
            directories = {"/"}  # it changes to / unless told otherwise
            for name, value in options:
                if name in ("-d", "--chdir"):
                    directories = workdir(value)
                elif name in ("-r", "--chroot"):
                    rooted(value)
            program = getopt.value(options, "-a", "--startas") or getopt.value(options, "-x", "--exec")
            rest = [program] + rest if program else []
        elif verb == "chroot":
            if not rest:
                return
            rooted(rest[0])
            if not getopt.has(options, "--skip-chdir"):
                directories = {"/"}
            rest = rest[1:]
        if unknown:
            directories = {None}
        if rest:
            self.command(rest, segment, bodies, directories, depth + 1, wrapped=True)

    def launch_bwrap(self, args, segment, bodies, directories, depth, rooted, workdir):
        """bwrap: long options with a fixed number of arguments (exact names). A bind or
        overlay that mounts a path somewhere else cannot be mapped back, so it is blocked."""
        counts = {name: 0 for name in (
            "--unshare-all", "--share-net", "--unshare-user", "--unshare-user-try", "--unshare-ipc",
            "--unshare-pid", "--unshare-net", "--unshare-uts", "--unshare-cgroup", "--unshare-cgroup-try",
            "--disable-userns", "--assert-userns-disabled", "--clearenv", "--new-session", "--die-with-parent",
            "--as-pid-1", "--help", "--version", "--level-prefix")}
        counts.update({name: 1 for name in (
            "--args", "--argv0", "--userns", "--userns2", "--pidns", "--uid", "--gid", "--hostname", "--chdir",
            "--unsetenv", "--lock-file", "--sync-fd", "--remount-ro", "--exec-label", "--file-label", "--proc",
            "--dev", "--tmpfs", "--mqueue", "--dir", "--seccomp", "--add-seccomp-fd", "--block-fd",
            "--userns-block-fd", "--info-fd", "--json-status-fd", "--cap-add", "--cap-drop", "--perms", "--size",
            "--overlay-src", "--tmp-overlay", "--ro-overlay")})
        binds = ("--bind", "--bind-try", "--dev-bind", "--dev-bind-try", "--ro-bind", "--ro-bind-try",
                 "--bind-fd", "--ro-bind-fd", "--file", "--bind-data", "--ro-bind-data", "--symlink", "--chmod",
                 "--setenv")
        counts.update({name: 2 for name in binds})
        counts["--overlay"] = 3
        position, cwd = 0, set(directories)
        while position < len(args) and args[position].startswith("--"):
            item = args[position]
            if item == "--":
                position += 1
                break
            if item not in counts or position + counts[item] >= len(args) + (0 if counts[item] else 1):
                cwd = {None}
                position += 1
                continue
            values = args[position + 1:position + 1 + counts[item]]
            if item == "--chdir":
                cwd = workdir(values[0])
            elif item in binds[:6] and os.path.normpath(values[0]) != os.path.normpath(values[1]) or \
                    item in ("--overlay", "--tmp-overlay", "--ro-overlay", "--bind-fd", "--ro-bind-fd"):
                rooted(None)
            position += 1 + counts[item]
        rest = args[position:]
        if rest[:1] and rest[0].startswith("-"):
            cwd = {None}  # an option this parser does not know
        if rest:
            self.command(rest, segment, bodies, cwd, depth + 1, wrapped=True)

    def launch_tmux(self, args, segment, bodies, directories, depth):
        """tmux: global options (-c runs a shell command), then a ";"-separated command list."""
        position = 0
        while position < len(args) and args[position].startswith("-") and args[position] != "--":
            item = args[position]
            if item[1:2] in "cfLST" and len(item) == 2:
                if item == "-c" and position + 1 < len(args):
                    self.walk(args[position + 1], {None}, depth + 1)
                position += 2
            else:
                position += 1
        if args[position:position + 1] == ["--"]:
            position += 1
        self.tmux_commands(args[position:], directories, depth)

    def tmux_commands(self, words, directories, depth):
        """A tmux command list: split on ";" (alone or at the end of an argument, "\\;" stays
        literal), each name resolved like tmux does (exact name or alias, else a unique prefix;
        an ambiguous prefix is checked as every candidate, an unknown one as opaque text)."""
        if depth > 8:
            raise Deny("dogma: tmux command nesting is too deep to check safely.")
        commands, current = [], []
        for word in words:
            if word in (";", "{", "}"):
                commands.append(current)
                current = []
            elif word.endswith("\\;"):
                current.append(word[:-2] + ";")
            elif word.endswith(";"):
                current.append(word[:-1])
                commands.append(current)
                current = []
            else:
                current.append(word)
        commands.append(current)
        for command in commands:
            if not command:
                continue
            word = command[0]
            names = [name for name, alias in TMUX_COMMANDS.items() if word in (name, alias)] or \
                [name for name in TMUX_COMMANDS if name.startswith(word)]
            if not names:
                self.opaque(command[1:], depth)
            for name in names:
                self.tmux_command(name, command[1:], directories, depth)

    def tmux_string(self, text, directories, depth):
        """A tmux command given as one string (if-shell, confirm-before, set-hook, ...)."""
        try:
            words = shlex.split(text, comments=True)
        except ValueError:
            self.opaque([text], depth)
            self.unclear(text, directories)
            return
        self.tmux_commands(words, directories, depth + 1)

    def tmux_command(self, name, args, directories, depth):
        if name not in TMUX_RUN:
            return
        values, kind = TMUX_RUN[name]
        flags, index = {}, 0
        while index < len(args) and args[index].startswith("-") and args[index] not in ("-", "--"):
            item, index = args[index], index + 1
            for offset, letter in enumerate(item[1:], 1):
                if letter in values:
                    flags[letter] = item[offset + 1:] or (args[index] if index < len(args) else None)
                    if not item[offset + 1:]:
                        index += 1
                    break
                flags[letter] = True
        if args[index:index + 1] == ["--"]:
            index += 1
        rest = args[index:]
        if kind == "shell" and name == "run-shell" and "C" in flags:
            kind = "tmux"
        if kind == "shell":
            directory = flags.get("d" if name == "display-popup" else "c")
            if isinstance(directory, str):
                cwd = {None} if "#{" in directory or directory.startswith("-") else \
                    {self.chdir(base, home() + directory[1:] if directory[:1] == "~" else directory)
                     for base in directories}
            else:
                cwd = set(directories) if name == "new-session" else {None}
            if len(rest) == 1:
                self.walk(rest[0], cwd, depth + 1)
            elif rest:
                self.command(rest, None, [], cwd, depth + 1, wrapped=True)
        elif kind == "if":
            if rest:
                self.walk(rest[0], {None}, depth + 1)
            for text in rest[1:]:
                self.tmux_string(text, directories, depth)
        elif kind == "tmux":
            for text in rest:
                self.tmux_string(text, directories, depth)
        elif kind == "argv":
            self.tmux_commands(rest[1:], directories, depth + 1)
        elif kind == "hook":
            for text in rest[1:]:
                self.tmux_string(text, directories, depth)
        elif kind == "keys":
            self.tmux_keys(flags, rest, depth)
        else:
            self.opaque(rest, depth)

    def tmux_keys(self, flags, keys, depth):
        """send-keys: the keys typed into a pane's shell, whose directory is unknown. -H keys are
        hex codes, -l sends literal text; a key name is mapped when it only adds text, any other
        key (cursor, delete, modifiers) or -K makes the result unclear (fail closed)."""
        text, unclear = "", "K" in flags
        for key in keys:
            if "H" in flags:
                try:
                    text += chr(int(key, 16))
                except (ValueError, OverflowError):
                    unclear = True
            elif "l" in flags or len(key) == 1:
                text += key
            elif key.lower() in TMUX_KEYS:
                text += TMUX_KEYS[key.lower()]
            elif TMUX_KEY_NAME_RE.fullmatch(key):
                unclear = True
            else:
                text += key
        if unclear:
            self.unclear(text)
        self.opaque([text], depth)

    def run_xargs(self, rest, segment, bodies, directories, depth):
        values = {"-I", "-L", "-n", "-P", "-s", "-d", "-E", "-a", "--arg-file", "--delimiter", "--max-args",
                  "--max-procs", "--max-lines", "--replace", "--eof"}
        while rest and rest[0].startswith("-"):
            item = rest.pop(0)
            if item == "--":
                break
            if item in values and rest:
                rest.pop(0)
        if not rest:
            return directories
        verb = os.path.basename(self.expand(rest[0]))
        if verb in ("git", "hub"):
            raise Deny("dogma: xargs git gets its arguments from input (a hook bypass or a restricted git "
                       "operation cannot be excluded); run git directly.")
        if verb in SHELLS or verb in WRAPPER_VALUE_OPTIONS or verb in ("env", "eval"):
            self.evasions.append((set(directories), "xargs " + verb))
        self.xargs += 1
        try:
            return self.command(rest, segment, bodies, directories, depth + 1, wrapped=True)
        finally:
            self.xargs -= 1

    def change_directory(self, verb, args, directories):
        if verb == "popd":
            return directories | {None}
        operands = [arg for arg in args if not arg.startswith("-") or arg == "-"]
        destination = operands[0] if operands else "~"
        if destination == "-":
            return {None}
        return {self.join(directory, destination) for directory in directories}

    def dynamic(self, tokens, segment, directories):
        """Command word unknown before run time (variable, substitution): fail closed when destructive."""
        text = segment.text if segment else " ".join(tokens)
        if re.search(r"--no-v|hookspath|HUSKY|GIT_CONFIG", text, re.I):
            raise Deny("dogma: a command chosen at run time may skip git hooks; blocked.")
        args = tokens[1:]
        destructive_flags = any(re.match(r"^-[a-zA-Z]*[rRfd][a-zA-Z]*$", arg) or arg in ("--force", "--recursive",
                                                                                      "-delete") for arg in args)
        for arg in args:
            if arg.startswith("-"):
                continue
            for path in self.targets(arg, directories):
                if path is None:
                    continue  # unsure: the "dynamic command" finding below decides by the delete setting
                if dangerous(path) and (destructive_flags or overwrite_protected(path)) or \
                        overwrite_protected(path) or self.anchor(path):
                    raise Deny("dogma: a command chosen at run time touches a protected path (%s); blocked." % path)
                self.check_path(arg, directories, "write")
        if re.search(r"\b(git|add|commit|push|stage)\b", text):
            self.evasions.append((set(directories), "dynamic command"))
        if re.search(r"\b(rm|unlink|shred|rmdir|truncate|del|clean)\b", text) or destructive_flags:
            self.deletes.append(("dynamic command", "", set(directories)))

    def producer(self, segment, heredocs):
        """Literal text the segment before a pipe writes (echo, printf, cat with a heredoc or here-string)."""
        tokens, parsed = tokenize(segment.text)
        if not parsed or not tokens or os.path.basename(tokens[0]) not in ("echo", "printf", "cat"):
            return []
        texts = [heredocs[int(match.group(1))][0] or "" for match in map(HEREDOC_RE.fullmatch, tokens) if match]
        texts += [_unquote(word) for word in segment.herestrings]
        if tokens[0] != "cat":
            words = [word for word in tokens[1:] if not HEREDOC_RE.fullmatch(word) and not word.startswith("-")]
            texts.append(" ".join(words))
        return texts

    def opaque(self, texts, depth):
        """Strings that are executed in a way the analyser cannot follow (a command word chosen at
        run time, launcher option values, tmux command strings and keys) are parsed as shell
        text with an unknown working directory, so relative targets fail closed. Text that
        cannot be parsed (or is too long) is refused when a delete-capable verb with an
        operand appears in it."""
        for text in texts:
            if time_left() < 0:
                raise Deny("dogma: check ran out of time, command blocked (fail closed).")
            if len(text or "") > OPAQUE_MAX:
                self.unclear(text)
                continue
            if not text or not OPAQUE_RE.search(text):
                continue
            try:
                self.walk(text, {None}, depth + 1)
            except (ValueError, RecursionError):
                self.unclear(text)

    def unclear(self, text, directories=None):
        """Text run by a program whose handling is not fully known: when it deletes or moves, its target is
        unsure (the delete setting decides); directories None = the working directory of the session."""
        if FALLBACK_RE.search(text):
            self.unsure("unclear", text[:200], directories or {None})

    def inputs(self, args, segment, bodies):
        """Argument strings plus everything the program may read as input."""
        return list(args) + [_ansi_c(word[2:-1]) if word.startswith("$'") else _unquote(word)
                             for word in (segment.herestrings if segment else [])] + \
            [body or "" for body, _quoted in bodies] + (list(segment.piped_in) if segment else [])

    def embedded(self, args, segment, directories, depth, bodies=(), executed=False):
        """Commands hidden in the arguments of an unknown program (wrappers, trap-like strings, system()).

        executed=True (a command word chosen at run time): the arguments and input are what
        runs, so every string is also parsed as shell text with an unknown working directory.
        Plain arguments of an ordinary unknown program (messages, test filters) are not."""
        for index, arg in enumerate(args):
            name = os.path.basename(arg)
            if name in EXEC_VERBS or INTERPRETER_RE.match(name):
                self.command(list(args[index:]), None, [], directories, depth + 1, wrapped=True)
                break
        if executed:
            self.opaque(self.inputs(args, segment, bodies), depth)
        strings = list(args) + [_ansi_c(word[2:-1]) if word.startswith("$'") else _unquote(word)
                                for word in (segment.herestrings if segment else [])]
        for text in strings:
            if not EXEC_WORD_RE.search(text):
                continue
            pieces = re.split(r"[;\n&|]+", text)
            pieces += [match.group(2) for match in re.finditer(r"(?:system|exec|popen|spawn)\s*\(\s*([\"'])(.*?)\1",
                                                               text)]
            for piece in pieces:
                piece = piece.strip().lstrip("!@-:").strip()
                words = piece.split()
                if words and (os.path.basename(words[0]) in EXEC_VERBS or INTERPRETER_RE.match(words[0])):
                    self.walk(piece, directories, depth + 1)

    # credentials and private files --------------------------------------------------------
    def verb_class(self, verb, args):
        if verb in LIST_VERBS:
            return "list"
        if verb in ("sed", "perl") and any(arg.startswith("-i") or arg.startswith("--in-place") for arg in args):
            return "write"
        if verb in ("awk", "gawk") and "inplace" in " ".join(args):
            return "write"
        if verb == "find" and any(arg in ("-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprintf",
                                          "-fls") for arg in args):
            return "write"
        if verb in READ_VERBS:
            return "read"
        return "write"

    def path_like(self, word, directories):
        if not word:
            return False
        exists = any(directory and os.path.lexists(os.path.join(directory, word)) for directory in directories)
        if re.search(r"\s", word) and not exists:
            return False
        return exists or bool(re.search(r"[/.~*?]", word))

    def check_path(self, word, directories, kind, force=False, runs=False):
        """kind: list, read or write. Raises Deny for credentials, private homes and own files.
        runs: the script operand of an interpreter (see script_operand); only the own-files rule relaxes."""
        if not word:
            return
        expanded = self.expand(word)
        static = SUB_RE.sub("x", expanded)
        token = self.flags.get("token_protection", True)
        if not (force or self.path_like(static, directories)):
            return
        reason = "dogma: command references a protected credential path. Use a non-secret source."
        if token and kind != "list" and sensitive_name(static):
            allowed = [self.join(directory, static) for directory in directories if "$" not in static]
            if not allowed or not all(path and token_allowed(path) for path in allowed):
                raise Deny(reason)
        for directory in directories:
            path = self.join(directory, static) if "$" not in static else None
            if path is None:
                continue
            if token and kind == "read" and SUB_RE.search(expanded) \
                    and any(_inside(path, root) for root in self.private):
                raise Deny("dogma: a name built by a substitution inside a private config home cannot be "
                           "checked; blocked.")
            candidates = [path]
            if GLOB_RE.search(path) and "**" not in path:
                candidates.extend(itertools.islice(glob.iglob(path), 64))
            for candidate in candidates:
                try:
                    real = os.path.realpath(candidate)
                except (OSError, ValueError):
                    real = candidate
                for item in {candidate, real}:
                    self.check_location(item, kind, token, globbed=bool(GLOB_RE.search(path)), runs=runs)

    def check_location(self, path, kind, token, globbed, runs=False):
        reason = "dogma: command references a protected credential path. Use a non-secret source."
        if token and kind != "list" and (sensitive_name(path) and not token_allowed(path) or codex_auth(path)):
            raise Deny(reason)
        if kind == "write" and git_protected_file(path):
            raise Deny("dogma: git configuration and hooks can run commands later; agents do not write them.")
        if os.path.basename(path) == PERMISSION_FILE and kind == "write":
            raise Deny("dogma: DOGMA-PERMISSIONS.md is changed by the user only, never by an agent command.")
        lowered = path.lower()
        if kind == "write" and (lowered.endswith("/.codex/hooks.json") or lowered.endswith("/.codex/config.toml")):
            raise Deny("dogma: Codex hook configuration is protected against agent writes.")
        for own in self.own:
            if kind == "write" and not runs and _inside(path, own):
                raise Deny("dogma: the dogma hook files are protected against agent writes.")
        for root in self.private:
            if not _inside(path, root):
                continue
            if kind == "list":
                if os.path.relpath(path, root).split("/")[0] in PRIVATE_SECRET:
                    raise Deny("dogma: %s holds sessions and logins; listing them is blocked too." % root)
                continue
            if kind == "write":
                raise Deny("dogma: %s is protected against agent writes (it holds hook switches, logins and "
                           "configuration)." % root)
            if token and private_blocked(path, root):
                raise Deny("dogma: %s holds logins and sessions; its secrets cannot be read (listing and "
                           "reading the rest is allowed)." % root)

    def text_positions(self, verb, args):
        skipped = set()
        if verb in TEXT_COMMANDS:
            return set(range(len(args)))
        if verb in SEARCH_COMMANDS:
            position, explicit = 0, False
            while position < len(args):
                item = args[position]
                if item in ("-e", "--regexp") and position + 1 < len(args):
                    skipped.add(position + 1)
                    explicit = True
                    position += 2
                    continue
                if item in ("-g", "--glob", "-t", "--type", "--iglob") and position + 1 < len(args):
                    skipped.add(position + 1)
                    position += 2
                    continue
                if item.startswith(("--glob=", "--type=", "--iglob=")) or (item.startswith("-g") and len(item) > 2):
                    skipped.add(position)
                    position += 1
                    continue
                if item == "--":
                    if not explicit and position + 1 < len(args):
                        skipped.add(position + 1)
                    break
                if item.startswith("-"):
                    position += 1
                    continue
                if not explicit:
                    skipped.add(position)
                break
        if verb in ("git", "hub"):
            # git grep: its pattern is text like the pattern of grep (paths after it stay checked)
            position = 0
            while position < len(args) and args[position].startswith("-"):
                position += 2 if args[position] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace",
                                                    "--exec-path", "--config-env") else 1
            if position < len(args) and args[position] == "grep":
                start = position + 1
                inner = self.text_positions("git-grep", args[start:])
                skipped |= {start + index for index in inner}
        if verb in ("git", "gh", "glab", "hub"):
            for position, item in enumerate(args):
                if item in GIT_MESSAGE_OPTIONS | {"--title", "--body", "-t", "-b", "--notes"} \
                        and position + 1 < len(args):
                    skipped.add(position + 1)
                elif item.startswith(("--message=", "--grep=", "--format=", "--pretty=", "--title=", "--body=")) \
                        or (item.startswith("-m") and len(item) > 2):
                    skipped.add(position)
        if verb in ("sed", "awk", "gawk", "jq") and args:
            for position, item in enumerate(args):
                if not item.startswith("-"):
                    skipped.add(position)
                    break
        if verb == "find":
            for position, item in enumerate(args):
                if item in ("-name", "-iname", "-path", "-ipath", "-regex", "-iregex", "-newer") \
                        and position + 1 < len(args):
                    skipped.add(position + 1)
        return skipped

    def check_arguments(self, verb, args, directories):
        skipped = self.text_positions(verb, args)
        kind = self.verb_class(verb, args)
        script = script_operand(verb, args)
        token = self.flags.get("token_protection", True)
        globs = glob_values(args) if token and verb in SEARCH_COMMANDS else {}
        if token and verb in SEARCH_COMMANDS:
            for position, item in enumerate(args):
                if item in ("-g", "--glob", "--iglob") and position + 1 < len(args):
                    pattern = args[position + 1]
                elif item.startswith(("--glob=", "--iglob=")):
                    pattern = item.partition("=")[2]
                elif item.startswith("-g") and len(item) > 2:
                    pattern = item[2:]
                else:
                    continue
                cleaned = re.sub(r"\.env\.(example|sample|template)", "", pattern)
                if not pattern.startswith("!") and re.search(
                        r"(?i)(?<![A-Za-z0-9_])(\.env|\.ssh|\.smbcredentials|\.netrc|\.git-credentials|\.npmrc|"
                        r"\.pypirc)|\.(pem|key)\b", cleaned):
                    raise Deny("dogma: search glob explicitly includes a protected credential path.")
        roots = []
        for position, item in enumerate(args):
            if position in skipped:
                continue
            value = item.split("=", 1)[1] if item.startswith("--") and "=" in item else item
            if verb == "dd" and re.match(r"^(if|of)=", item):
                value = item[3:]
            if value.startswith("-") and value != "-":
                continue
            if position in globs and login_glob(globs[position]):
                continue  # a file-name glob, not a path: the search root is checked below
            if position not in globs:
                roots.append(value)
            self.check_path(value, directories, kind, runs=position == script)
        if token and verb in SEARCH_COMMANDS and searches_recursively(verb, args):
            self.check_login_reach(roots, globs, directories)

    def check_login_reach(self, roots, globs, directories):
        """A recursive search reads a secret when its root holds one: the login file of a configuration home
        (root = that home or a directory above it) or a key file of a session folder (root = the folder). Its
        file-name globs (none given: every file) must be able to match that secret's name."""
        if roots:
            paths = [self.join(directory, root) for root in roots for directory in directories]
        else:
            paths = list(directories)
        if any(path and reaches_login_file(path) for path in paths) and _may_match(globs, PRIVATE_SECRET):
            raise Deny("dogma: a recursive search reaches a login file of a Claude or Codex configuration home; "
                       "search a subfolder such as plugins/ instead.")
        if any(path and is_session_folder(path) for path in paths) and _may_match(globs, (SESSION_KEY_SAMPLE,)):
            raise Deny("dogma: a recursive search of a session folder would read its key files; search *.json only.")

    def check_dumps(self, verb, args):
        if not self.flags.get("token_protection", True):
            return
        reason = "dogma: command may print environment variables or stored credentials."
        names = [arg for arg in args if not arg.startswith("-") and arg != "--"]
        options = [arg for arg in args if arg.startswith("-")]
        if verb == "printenv":
            # Claude parity: a named variable is still blocked (echo "$NAME" is the allowed route).
            if not names and self.counts_only():
                return
            raise Deny(reason)
        if verb in ("history", "fc"):
            raise Deny("dogma: shell history can contain typed passwords and tokens; it is never read.")
        if verb in ("export", "declare", "typeset", "readonly") and not names:
            if not options or all(re.match(r"^-[pxrfaAgilnu]*$", option) for option in options):
                raise Deny(reason)
        if verb == "set" and not args:
            raise Deny(reason)
        if verb == "compgen" and any(option in ("-v", "-e", "-A") or re.match(r"^-[a-zA-Z]*[ve]", option)
                                     for option in options):
            raise Deny(reason)
        if verb == "ps" and (any(re.match(r"^[a-zA-Z]*e[a-zA-Z]*$", arg) for arg in args) or "-E" in options):
            raise Deny(reason)
        if verb in ("systemctl", "tmux", "launchctl") and any("environment" in arg or arg == "showenv"
                                                             for arg in args):
            raise Deny(reason)
        if verb == "secret-tool" and names[:1] in (["lookup"], ["search"]) or verb.startswith("gnome-keyring") \
                or verb in ("kwallet-query", "keyring") and "get" in names \
                or verb == "pass" and (not names or names[0] not in ("ls", "list", "find", "search", "grep",
                                                                       "generate", "init", "git", "insert")) \
                or verb in ("gpg", "gpg2") and any(long_option(arg, "export-secret-keys", 15)
                                                    or long_option(arg, "export-secret-subkeys", 15) for arg in args) \
                or verb == "security" and any(re.match(r"^find-.*password$", arg) or arg == "dump-keychain"
                                              for arg in names):
            raise Deny("dogma: command reads a credential store or key ring.")
        if verb == "gh" and (args[:2] == ["auth", "token"] or args[:2] == ["auth", "status"]
                             and any(option in ("-t", "--show-token") for option in options)):
            raise Deny(reason)
        if verb == "gcloud" and "auth" in args and any("token" in arg for arg in args):
            raise Deny(reason)
        if verb == "aws" and args[:1] == ["configure"] and any(arg in ("get", "export-credentials") for arg in args):
            raise Deny(reason)
        if verb == "kubectl" and "config" in args and "--raw" in args:
            raise Deny(reason)
        if verb == "az" and "get-access-token" in args:
            raise Deny(reason)
        if verb in ("curl", "wget", "http", "xh"):
            for position, item in enumerate(args):
                header = None
                if item in ("-H", "--header") and position + 1 < len(args):
                    header = args[position + 1]
                elif item.startswith("--header="):
                    header = item.partition("=")[2]
                elif item.startswith("-H") and len(item) > 2:
                    header = item[2:]
                if header and re.search(r"(?i)authorization|bearer|token|api-key|apikey|cookie", header):
                    raise Deny("dogma: command includes authorization headers that could expose tokens.")
                if item in ("-u", "--user", "--oauth2-bearer", "--password", "--http-password"):
                    raise Deny("dogma: command includes credentials that could leak into logs.")

    def check_install(self, verb, args):
        names = [arg for arg in args if not arg.startswith("-")]
        if verb == "npx" and names and self.local_npm_tool(names[0]):
            return
        if verb in ("npx", "bunx", "uvx", "pnpx", "corepack"):
            if verb != "corepack" or names[:1] in (["enable"], ["install"], ["prepare"], ["use"]):
                self.installs.append(verb)
            return
        if verb == "go" and names[:1] == ["run"] and any("@" in name for name in names[1:]):
            self.installs.append("go run module@version")
            return
        if verb == "nix-shell" and any(arg in ("-p", "--packages") for arg in args) or \
                verb == "nix" and names[:1] in (["run"], ["shell"], ["develop"]):
            self.installs.append(verb + " packages")
            return
        if verb == "composer" and "require" in names or verb == "dotnet" and names[:2] == ["tool", "install"] \
                or verb == "luarocks" and names[:1] == ["install"] \
                or verb in ("mise", "rtx") and names[:1] in (["use"], ["install"], ["exec"], ["x"]) \
                or verb == "asdf" and names[:1] in (["install"], ["plugin"]) \
                or verb in ("cpan", "cpanm") or verb == "gem" and names[:1] == ["install"]:
            self.installs.append(verb + " " + " ".join(names[:2]))
            return
        if verb == "npm" and names[:2] == ["pkg", "set"] and any(name.startswith("scripts") for name in names[2:]):
            raise Deny("dogma: npm pkg set scripts writes commands that run later; let the user change them.")
        if verb in ("pip", "pip3") or re.match(r"^pip[0-9.]+$", verb):
            if names[:1] in (["install"], ["download"]) and len(args) > 1:
                self.installs.append("pip " + names[0])
            return
        if verb == "uv":
            if names[:2] in (["pip", "install"],) or names[:1] == ["add"] or names[:2] == ["tool", "install"]:
                self.installs.append("uv " + " ".join(names[:2]))
            return
        if verb in ("npm", "pnpm", "yarn", "bun") and names[:1] in (["exec"], ["x"], ["dlx"], ["create"], ["init"]):
            if verb != "npm" or names[0] != "init" or len(names) > 1:
                self.installs.append(verb + " " + names[0])
            return
        if verb in ("dpkg",) and any(arg in ("-i", "--install") for arg in args):
            self.installs.append("dpkg -i")
            return
        if verb == "rpm" and any(re.match(r"^-[a-zA-Z]*[iU]", arg) or arg in ("--install", "--upgrade")
                                 for arg in args):
            self.installs.append("rpm -i")
            return
        if verb == "nix" and names[:2] == ["profile", "install"]:
            self.installs.append("nix profile install")
            return
        if verb in ("conda", "mamba", "micromamba") and names[:1] in (["create"], ["install"]):
            self.installs.append(verb + " " + names[0])
            return
        rule = INSTALL_RULES.get(verb)
        if rule is None:
            if verb == "pacman" and any(re.match(r"^-[A-Za-z]*S", arg) for arg in args):
                self.installs.append("pacman -S")
            if verb == "nix-env" and any(arg in ("-i", "--install", "-iA") for arg in args):
                self.installs.append("nix-env -i")
            return
        subcommands, _needs_package = rule
        if verb == "yarn" and names[:2] == ["global", "add"]:
            names = names[1:]
        if verb == "dotnet" and names[:1] == ["add"] and "package" not in names:
            return
        if not names or names[0] not in subcommands:
            return
        if len(names) > 1:
            self.installs.append(verb + " " + names[0])

    def check_delete(self, verb, args, directories, posix=False):
        """posix=True re-checks with the POSIXLY_CORRECT reading (options end at the first
        operand); whether it is set is unknown before run time, so both readings are checked."""
        args = [variant for arg in args for variant in brace_expand(arg)]
        if not posix and verb in getopt.TABLES and len(getopt.parse_modes(verb, args)) > 1:
            self.check_delete(verb, args, directories, posix=True)

        def has(name, minimum, short=None):
            return any(long_option(arg, name, minimum) for arg in args) or bool(short and short_flag(args, short))

        def value_of(name, minimum, short=None):
            for position, arg in enumerate(args):
                if arg.startswith("--") and "=" in arg and long_option(arg, name, minimum):
                    return arg.split("=", 1)[1]
                if (long_option(arg, name, minimum) or short and arg == "-" + short) and position + 1 < len(args):
                    return args[position + 1]
                if short and arg.startswith("-" + short) and len(arg) > 2 and not arg.startswith("--"):
                    return arg[2:]
            return None

        valued = ("-s", "--size", "-r", "--reference", "-n", "-m", "--mode", "-o", "-g", "-t", "-C", "--directory",
                  "-f", "--file", "-I", "-e", "-T", "-S", "--suffix", "-b")
        operands = [arg for position, arg in enumerate(args) if not arg.startswith("-")
                    and not (position and args[position - 1] in valued)]
        parsed = getopt.parse(verb, args, posix)
        if parsed is not None:
            options, operands = parsed
        layout = getopt.copy_layout(verb, args, posix) if verb in ("cp", "mv", "install", "ln") else None
        target = operands[0] if operands else ""
        label = None
        if any(os.path.basename(arg) == PERMISSION_FILE for arg in operands) and verb in ("cp", "ln", "mv", "install",
                                                                                      "rsync", "tee"):
            raise Deny("dogma: DOGMA-PERMISSIONS.md is changed by the user only, never by an agent command.")
        if verb in DELETE_VERBS:
            label = verb
            if self.xargs:
                # the targets come from the input of xargs: unsure (the literal operands are still checked)
                self.unsure(verb, " ".join(operands), directories)
            self.protect_delete(operands, directories, verb, follow=verb in FOLLOWING_DELETERS)
        elif verb == "truncate":
            self.protect_overwrite(operands, directories, "truncation")
            for operand in operands:
                self.critical_target(operand, directories, False)  # the rule of ">" (system trees, dot folders)
        elif verb.startswith(("mkfs", "mke2fs")) or verb in DEVICE_TOOLS:
            raise Deny("dogma: destructive disk operation blocked.")
        elif verb == "hdparm" and any(re.match(r"^--(security-erase|security-set|trim|write-sector|dco|fwdownload|"
                                               r"make-bad|yes-i-know)", arg) for arg in args):
            raise Deny("dogma: destructive disk operation blocked.")
        elif verb in ("umount", "fusermount", "fusermount3") and operands:
            raise Deny("dogma: unmounting file systems is left to the user.")
        elif verb == "mount" and operands:
            raise Deny("dogma: mounting (including bind mounts) is left to the user.")
        elif verb == "dd":
            for arg in args:
                if arg.startswith("of="):
                    label, target = "dd", arg[3:]
                    self.protect_overwrite([target], directories, "raw write")
        elif verb in ("cp", "install"):
            options, sources, destination, into, no_target = layout
            if verb == "install" and getopt.has(options, "-d", "--directory"):
                destination = None  # creates directories, overwrites nothing
            if destination:
                self.protect_destination(destination, sources, directories, "overwrite", into=into,
                                         file_only=no_target and not into)
                self.remember_written(destination, directories)
            if "/dev/null" in sources and destination:
                label, target = verb + " /dev/null", destination
            if verb == "cp" and getopt.has(options, "-s", "--symbolic-link", "-l", "--link"):
                for source in sources:
                    for path in self.targets(source, directories):
                        if path is None or dangerous(path):
                            raise Deny("dogma: linking a protected tree (%s) is blocked." % source)
        elif verb == "rsync":
            unknown = [name[1:] for name, _value in options if name.startswith("?")]
            if unknown:
                # popt matches exactly; an option missing from the table may take a value
                raise Deny("dogma: rsync option %s is unknown to the guard, so its destination cannot be "
                           "determined; blocked." % unknown[0][:40])
            local = [operand for operand in operands if not re.match(r"^([^/]*:|rsync://)", operand)]
            if len(operands) > 1 and operands[-1] in local:
                # same overwrite protection as cp for the (local) destination
                self.protect_destination(operands[-1], [source for source in operands[:-1]], directories,
                                         "overwrite", contents=True)
            if any(arg.startswith("--del") for arg in args) and operands:
                label, target = "rsync --delete", operands[-1]
                self.protect_delete([operands[-1]], directories, "rsync --delete", contents=True)
            if has("remove-source-files", 4) or has("remove-sent-files", 8):
                label, target = "rsync --remove-source-files", operands[0] if operands else ""
                self.protect_delete(operands[:-1], directories, "rsync --remove-source-files")
        elif verb in ("tar", "bsdtar", "gtar"):
            base = value_of("directory", 3, "C")
            bases = {self.chdir(directory, base) for directory in directories} if base else set(directories)
            if has("remove-files", 4):
                label = "tar --remove-files"
                members = operands[1:] if operands and not any(arg.startswith(("-f", "--file")) for arg in args) \
                    else operands
                self.protect_delete(members or ["."], bases, "tar --remove-files", contents=False)
            if has("recursive-unlink", 10) or has("unlink-first", 3) or short_flag(args, "U"):
                self.protect_delete(["."], bases, "tar --recursive-unlink", contents=True)
                label = label or "tar --recursive-unlink"
            if has("overwrite-dir", 10) or has("overwrite", 9):
                self.protect_overwrite(["."], bases, "tar --overwrite")
        elif verb == "zip" and (short_flag(args, "m") or has("move", 3)):
            label = "zip -m"
            self.protect_delete(operands[1:], directories, "zip -m")
        elif verb in ("7z", "7za", "7zr") and any(arg.lower() == "-sdel" for arg in args):
            label = "7z -sdel"
            self.protect_delete(operands[2:], directories, "7z -sdel")
        elif verb == "mv" and operands:
            options, sources, destination, into, no_target = layout
            if destination is not None:
                # mv moves a symlink itself, so a source is checked as named
                self.protect_delete(sources, directories, "move", follow=False)
                self.protect_destination(destination, sources, directories, "overwrite", into=into,
                                         file_only=no_target and not into)
                self.remember_written(destination, directories)
            if destination == "/dev/null":
                label = "mv"
        elif verb == "ln":
            options, sources, destination, into, no_target = layout
            if destination is not None:
                self.protect_destination(destination, sources, directories, "replace", into=into,
                                         file_only=no_target and not into
                                         or getopt.has(options, "-n", "--no-dereference"))
        elif verb == "tee" and operands:
            appending = has("append", 2, "a")
            if not appending:
                self.protect_overwrite(operands, directories, "overwrite")
            for operand in operands:
                self.critical_target(operand, directories, appending)
                self.remember_written(operand, directories)
        elif verb in ("chmod", "chown", "chgrp", "setfacl", "chattr", "chcon") and (short_flag(args, "R") or
                                                                                   has("recursive", 3)):
            self.protect_overwrite(operands[1:] if verb not in ("setfacl",) else operands, directories,
                                   "recursive permission change")
        elif verb in ("chmod", "chown", "chattr") and operands:
            for operand in operands[1:]:
                for path in self.targets(operand, directories):
                    if path is not None and any(_inside(path, own) for own in self.own):
                        raise Deny("dogma: the dogma hook files are protected against agent changes.")
        elif verb == "sed" and (short_flag(args, "i") or has("in-place", 2)):
            scripts = [arg for arg in args if not arg.startswith("-")]
            files = scripts[1:] if not any(arg in ("-e", "--expression", "-f", "--file") for arg in args) else scripts
            self.protect_overwrite(files, directories, "in-place edit")
            if scripts and re.fullmatch(r"\s*(?:\d+\s*,\s*)?(?:\$|\d+)?\s*d\s*", scripts[0]):
                label, target = "sed -i d", scripts[-1] if len(scripts) > 1 else ""
        if label and not posix:
            # one entry per operand, so the temp-root exemption of file-protection.sh sees every target
            targets = [target]
            if verb in DELETE_VERBS:
                after_separator = args[args.index("--") + 1:] if "--" in args else []
                targets = operands + [arg for arg in after_separator if arg.startswith("-")]
            for each in targets or [target]:
                self.record_delete(label, each, directories)

    def remember_written(self, word, directories):
        for path in self.targets(word, directories):
            if path:
                self.written.add(path)
                self.written.add(os.path.basename(path))

    def critical_target(self, word, directories, append):
        """The rule of delete-guard.py for what a redirect or tee may write onto (startup and
        persistence files, dot folders of a home, system trees, drives), also for a relative
        word (after cd) and a word with quotes inside."""
        guard = load_delete_guard()
        words = [word]
        expanded = self.expand(word)
        unresolved = [position for position in (expanded.find("$"), expanded.find("`")) if position >= 0]
        if unresolved:
            # a variable that is not known here: the literal part before it decides (a name that
            # starts there could be any name, a dot name too: ~/$X, ~/.$X, /etc/$X)
            literal = expanded[:min(unresolved)]
            if not literal:
                return
            if re.search(r"(^|/)\.\.(/|$)", expanded[min(unresolved):]):
                raise Deny("dogma: a redirect target with an unknown part and \"..\" cannot be checked; blocked.")
            words = [literal + "x"] + ([literal + ".x"] if literal.endswith("/") else [])
            if append:
                prefix = literal[:len(literal) - len(literal.rpartition("/")[2])]
                words += [prefix + name for name in guard.HOME_RC_NAMES if name.startswith(literal[len(prefix):])]
        for item in words:
            for path in self.targets(item, directories):
                if path and guard.critical_redirect(path, append=append, unknown=bool(unresolved)):
                    raise Deny("dogma: %s a critical path (%s) is never allowed." % (
                        "appending to" if append else "overwriting", path))

    @staticmethod
    def syntax_check_only(args):
        """True when the options of a shell (before its script name) switch on noexec: -n, -xn, -o noexec.
        A later +n or an argument after the script name does not count."""
        syntax = False
        position = 0
        while position < len(args) and args[position][:1] in ("-", "+"):
            option = args[position]
            if option == "--":
                break
            if option in ("-o", "+o") and position + 1 < len(args):
                syntax = option == "-o" and args[position + 1] == "noexec" or syntax and not (
                    option == "+o" and args[position + 1] == "noexec")
                position += 1
            elif re.fullmatch(r"[-+][A-Za-z]+", option) and "n" in option:
                syntax = option[0] == "-"
            position += 1
        return syntax

    def check_written_run(self, first, verb, args, directories, segment=None):
        """A file written earlier in the same command and then run is a script that cannot be checked."""
        if not self.written:
            return
        if verb in SHELLS and self.syntax_check_only(args):
            return  # bash -n x.sh reads the script and runs nothing
        if segment is not None and (verb in SHELLS or verb in ("source", ".") or INTERPRETER_RE.match(verb)):
            # sh < script, sh -s < script: the shell reads the written file as its script
            for operator, word in segment.redirects:
                if operator in ("<", "<>"):
                    for path in self.targets(_unquote(word), directories):
                        if path and path in self.written:
                            raise Deny("dogma: a file written in this command is run right away; the script "
                                       "cannot be checked. Write it, show it to the user, then run it separately.")
        candidates = [first] if "/" in first or first in self.written else []
        if verb in SHELLS or INTERPRETER_RE.match(verb) or verb in ("source", ".", "make", "chmod"):
            candidates += [arg for arg in args if not arg.startswith(("-", "+"))][:1]
        if verb == "make":
            candidates += ["Makefile", "makefile", "GNUmakefile"]
        for candidate in candidates:
            if verb == "chmod":
                continue
            for path in self.targets(candidate, directories):
                if path and (path in self.written or verb == "make" and os.path.basename(path) in self.written):
                    raise Deny("dogma: a file written in this command is run right away; the script cannot be "
                               "checked. Write it, show it to the user, then run it separately.")
            if candidate in self.written and "/" not in candidate and verb != "make":
                raise Deny("dogma: a file written in this command is run right away; the script cannot be checked.")

    def local_npm_tool(self, tool):
        for directory in self.known_dirs():
            probe = directory
            while probe and probe != "/":
                if os.path.isfile(os.path.join(probe, "node_modules", ".bin", tool)):
                    return True
                if os.path.lexists(os.path.join(probe, ".git")):
                    break
                probe = os.path.dirname(probe)
        return False

    def known_dirs(self):
        return {directory for directory in getattr(self, "_known", set()) | self.anchors if directory}

    def counts_only(self):
        following = self.pipe_next or []
        if not following:
            return False
        verb = os.path.basename(following[0])
        return verb == "wc" or verb in ("grep", "rg") and any(arg in ("-c", "--count") for arg in following[1:])

    def check_special(self, verb, args, segment, bodies, directories, depth):
        """Windows tools from WSL, Codex switches, launchers and inline-code programs."""
        lowered = verb.lower()
        windows = lowered[:-4] if lowered.endswith(".exe") else lowered
        text = " ".join(args)
        if windows == "cmd" and re.search(r"(?i)(^|[\s&|(\"/])(rd|rmdir|del|erase|format|deltree|cipher|diskpart)"
                                          r"(\s|$|\")", text):
            raise Deny("dogma: Windows delete or format command blocked.")
        if windows in ("powershell", "pwsh"):
            for arg in args:
                bare = arg.lower().lstrip("-/")
                if arg[:1] in "-/" and bare and "encodedcommand".startswith(bare) and bare.startswith("e"):
                    raise Deny("dogma: encoded PowerShell commands cannot be checked; blocked.")
            if re.search(r"(?i)(^|[\s;|&({\"'])(remove-item|ri|rm|del|rd|rmdir|erase|clear-content|clear-item|"
                         r"format-volume|clear-disk|remove-partition|initialize-disk|clear-recyclebin)(\s|$|[\"';)])",
                         text):
                raise Deny("dogma: Windows delete or format command blocked.")
        if windows == "robocopy" and any(arg.upper() in ("/MIR", "/PURGE", "/MOV", "/MOVE") for arg in args):
            raise Deny("dogma: robocopy /MIR or /PURGE deletes files at the destination; blocked.")
        if windows in ("wsl", "wslg") and args:
            rest, cwd, shell = list(args), set(directories), True
            while rest and (rest[0].startswith("-") or rest[0] == "~") and rest[0] not in ("-e", "--exec", "--"):
                item = rest.pop(0)
                if item == "--cd" and rest:
                    value = rest.pop(0)
                    cwd = {None} if value[:1] == "~" or "\\" in value or ":" in value else \
                        {self.chdir(directory, value) for directory in directories}
                elif item in ("-u", "--user") and rest:
                    rest.pop(0)
                else:
                    # ~ (the home), another distribution or an option not known here
                    cwd = {None}
                    if item in ("-d", "--distribution", "--distribution-id") and rest:
                        rest.pop(0)
            if rest and rest[0] in ("-e", "--exec", "--"):
                shell = rest.pop(0) == "--"
            if rest:
                self.command(rest, segment, [], cwd, depth + 1, wrapped=True)
                if shell:
                    # without --exec the default shell runs the joined command line
                    self.walk(" ".join(rest), cwd, depth + 1)
        if lowered == "codex":
            if any(arg.startswith(("--dangerously", "--yolo")) for arg in args) or \
                    "features" in args and any(arg in ("disable", "set") for arg in args):
                raise Deny("dogma: switching off Codex hooks, sandbox or approvals is left to the user.")
            for position, arg in enumerate(args):
                value = args[position + 1] if arg in ("-c", "--config") and position + 1 < len(args) else \
                    arg.split("=", 1)[1] if arg.startswith("--config=") else None
                if value and re.search(r"(?i)hook|sandbox|approval|features", value):
                    raise Deny("dogma: overriding Codex hooks, sandbox or approvals is left to the user.")
        if lowered in ("batch", "at", "crontab") or lowered == "hash" and "-p" in args or \
                lowered == "set" and args[:1] in (["--"], ["-"]) or lowered == "source" and args[:1] in \
                (["/dev/stdin"], ["-"], ["/proc/self/fd/0"]):
            self.launcher = True
        if lowered == "hash" and "-p" in args:
            position = args.index("-p")
            if position + 2 < len(args):
                self.hashed[args[position + 2]] = args[position + 1]
        if lowered in ("batch", "at"):
            for word in (segment.herestrings if segment else []):
                self.walk(_unquote(word), directories, depth + 1)
            for body, _quoted in bodies:
                self.walk(body or "", directories, depth + 1)
        if lowered == "man":
            for position, arg in enumerate(args):
                if arg in ("-P", "--pager") and position + 1 < len(args):
                    self.walk(args[position + 1], directories, depth + 1)
                elif arg.startswith("--pager="):
                    self.walk(arg.split("=", 1)[1], directories, depth + 1)
        if verb in CODE_VERBS:
            codes = []
            flags = CODE_VERBS[verb]
            for position, arg in enumerate(args):
                if arg in flags and position + 1 < len(args):
                    codes.append(args[position + 1])
            if not flags or not codes:
                codes += [_unquote(word) for word in (segment.herestrings if segment else [])]
                codes += [body or "" for body, _quoted in bodies]
            for code in codes:
                self.code(code, directories, depth)
        if verb in ("gdb", "lldb"):
            for position, arg in enumerate(args):
                if arg in ("-ex", "--ex", "--eval-command", "-iex", "-o", "--one-line") and position + 1 < len(args):
                    value = args[position + 1].strip()
                    inner = re.sub(r"^(shell|!|platform shell|script)\s*", "", value)
                    if inner != value:
                        self.walk(inner, directories, depth + 1)
                    self.code(value, directories, depth)
        if verb in ("sqlite3", "duckdb"):
            texts = list(args) + [_unquote(word) for word in (segment.herestrings if segment else [])]
            texts += [body or "" for body, _quoted in bodies]
            for text_item in texts:
                for line in text_item.splitlines():
                    match = re.match(r"^\s*\.(shell|system)\s+(.*)$", line)
                    if match:
                        self.walk(match.group(2), directories, depth + 1)
        if verb == "sed":
            scripts = []
            for position, arg in enumerate(args):
                if arg in ("-e", "--expression") and position + 1 < len(args):
                    scripts.append(args[position + 1])
            if not scripts:
                scripts = [arg for arg in args if not arg.startswith("-")][:1]
            for script_text in scripts:
                for match in re.finditer(r"(?:^|[;\n{}]|\d|\$|/)\s*e(?:\s+([^;\n}]*))?(?=$|[;\n}])", script_text):
                    if match.group(1):
                        self.walk(match.group(1), directories, depth + 1)
                    else:
                        raise Deny("dogma: sed e runs file contents as commands; blocked.")
                substitute = re.match(r"^\s*s(.)(.*?)\1(.*?)\1([a-zA-Z0-9]*)\s*$", script_text, re.S)
                if substitute and "e" in substitute.group(4):
                    self.walk(substitute.group(3), directories, depth + 1)
                    raise Deny("dogma: sed s///e runs the result as a command; blocked.")
        if verb in ("tar", "bsdtar", "gtar"):
            for arg in args:
                for name in ("to-command", "checkpoint-action", "info-script", "new-volume-script",
                             "use-compress-program"):
                    if long_option(arg, name, 4) and "=" in arg:
                        value = arg.split("=", 1)[1]
                        if name == "use-compress-program" and re.fullmatch(r"[\w.+-]+", value):
                            continue
                        raise Deny("dogma: tar option that runs commands (%s) is blocked." % name)
                    if long_option(arg, name, 4) and name != "use-compress-program":
                        raise Deny("dogma: tar option that runs commands (%s) is blocked." % name)
            if "-F" in args:
                raise Deny("dogma: tar -F runs a script; blocked.")
        if verb == "zip" and any(arg in ("-TT", "--unzip-command") or arg.startswith("--unzip-command=")
                                 for arg in args):
            raise Deny("dogma: zip -TT runs a command; blocked.")
        if verb == "rsync":
            for position, arg in enumerate(args):
                value = args[position + 1] if arg in ("-e", "--rsh") and position + 1 < len(args) else \
                    arg.split("=", 1)[1] if long_option(arg, "rsh", 3) and "=" in arg else None
                if value is not None and not re.fullmatch(r"ssh( -[\w]+( \S+)?)*", value.strip()):
                    self.walk(value, directories, depth + 1)
                    if EXEC_WORD_RE.search(value):
                        raise Deny("dogma: rsync -e runs a command; blocked.")

    # git -----------------------------------------------------------------------------------
    def git(self, args, directories, depth):
        targets, unknown, aliases = set(directories), False, {}
        position = 0
        while position < len(args):
            item = args[position]
            value = None
            if item in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix",
                        "--exec-path") and position + 1 < len(args):
                value = args[position + 1]
                position += 2
            elif item.startswith("-") and not item.startswith("--") and len(item) > 2 and item[1] in "Cc":
                item, value = item[:2], item[2:]
                position += 1
            elif "=" in item and item.startswith("--"):
                item, value = item.split("=", 1)
                position += 1
            elif item.startswith("-"):
                position += 1
                continue
            else:
                break
            if item == "-C":
                targets = {self.chdir(directory, value) for directory in targets}
            elif item in ("-c", "--config-env"):
                self.git_config(value, aliases, directories, depth)
            elif item in ("--git-dir", "--work-tree", "--namespace", "--super-prefix"):
                unknown = True
                self.git_alt = True
            elif item == "--exec-path":
                raise Deny("dogma: git --exec-path runs git commands from another place; blocked.")
        if any(name in self.assigns for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
                                                 "GIT_NAMESPACE")):
            unknown = True
            self.git_alt = True
        if any(name == "GIT_CONFIG_PARAMETERS" or name.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_COUNT"))
               or name in ("GIT_CONFIG", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_EXEC_PATH")
               for name in self.assigns):
            raise Deny("dogma: git configuration through environment variables cannot be checked safely.")
        if position >= len(args):
            return
        sub = args[position]
        rest = args[position + 1:]
        if sub in aliases:
            expansion = aliases[sub]
            if expansion.startswith("!"):
                self.walk(expansion[1:] + " " + " ".join(shlex.quote(arg) for arg in rest), targets, depth + 1)
                self.evasions.append((set(targets), "git alias"))
                return
            try:
                words = shlex.split(expansion)
            except ValueError:
                words = expansion.split()
            if not words:
                return
            sub, rest = words[0], words[1:] + rest
        if "$" in sub or SUB_RE.search(sub):
            self.evasions.append((set(targets), "git dynamic subcommand"))
            return
        if sub not in GIT_KNOWN:
            self.evasions.append((set(targets), "git " + sub))
            return
        self.git_rules(sub, rest, targets)
        operation = GIT_OP.get(sub)
        if sub == "update-index" and "--add" in rest:
            operation = "add"
        if operation:
            self.git_ops.append((operation, targets, unknown or None in targets))

    def git_config_write(self, rest):
        names = [arg for arg in rest if not arg.startswith("-")]
        position = 0
        filtered = []
        while position < len(rest):
            arg = rest[position]
            if arg in ("-f", "--file", "--blob", "--type", "--default", "--comment") and position + 1 < len(rest):
                position += 2
                continue
            if not arg.startswith("-"):
                filtered.append(arg)
            position += 1
        names = filtered
        reading = any(arg in ("--get", "--get-all", "--get-regexp", "-l", "--list", "--get-urlmatch",
                              "--show-origin", "--unset", "--unset-all") for arg in rest)
        if not names or reading and not any(arg in ("--add", "--replace-all") for arg in rest):
            return
        key = names[0].lower()
        value = names[1] if len(names) > 1 else ""
        if len(names) < 2 and not any(arg in ("--add", "--replace-all") for arg in rest):
            return
        if key.startswith("alias.") and (value.startswith("!") or re.search(r"--no-v|hookspath", value, re.I)):
            raise Deny("dogma: a git alias that runs shell commands is blocked.")
        if GIT_COMMAND_CONFIG.match(key) or key.startswith(("filter.", "diff.")) and key.endswith(
                (".textconv", ".command", ".clean", ".smudge", ".process")) or key.startswith("credential"):
            raise Deny("dogma: git configuration that runs commands or stores credentials (%s) is left to the "
                       "user." % key)

    def git_config(self, value, aliases, directories, depth):
        name, _, setting = value.partition("=")
        lowered = name.lower()
        if lowered == "core.hookspath":
            raise Deny("dogma: overriding core.hooksPath skips git hooks and is never allowed for agents." + HOOK_HINT)
        if lowered.startswith("include"):
            raise Deny("dogma: git -c include.* loads configuration that cannot be checked safely.")
        if lowered.startswith("alias."):
            aliases[name[len("alias."):]] = setting
        elif GIT_COMMAND_CONFIG.match(lowered) and setting:
            self.walk(setting, directories, depth + 1)

    def git_rules(self, sub, rest, targets):
        options = [arg for arg in rest if arg.startswith("-")]
        hook_skip = self.assigns.get("HUSKY", "").lower() in ("0", "false") or bool(self.assigns.get("SKIP"))
        if sub in ("commit", "push", "merge", "rebase", "am") and hook_skip:
            raise Deny("dogma: HUSKY=0 or SKIP= skips git hooks and is never allowed for agents." + HOOK_HINT)
        if sub == "config" and any(arg.lower() == "core.hookspath" for arg in rest) and \
                not any(arg in ("--get", "--get-all", "-l", "--list") for arg in rest) and \
                len([arg for arg in rest if not arg.startswith("-")]) > 1:
            raise Deny("dogma: setting core.hooksPath skips git hooks and is never allowed for agents." + HOOK_HINT)
        if sub in GIT_NO_VERIFY and any(long_option(arg, "no-verify", 4) for arg in rest):
            raise Deny("dogma: --no-verify skips git hooks and is never allowed for agents." + HOOK_HINT)
        if sub == "commit":
            previous = None
            for arg in rest:
                if previous not in ("-m", "-F", "-C", "-c", "--author", "--date", "-t", "--template", "--fixup",
                                    "--squash", "--cleanup", "--trailer", "-S"):
                    if re.match(r"^-[a-zA-Z]*n[a-zA-Z]*$", arg) and not arg.startswith("--"):
                        raise Deny("dogma: git commit -n (--no-verify) skips git hooks and is never allowed for agents." +
                                   HOOK_HINT)
                previous = arg
        if sub in ("add", "stage") and self.flags.get("git_add_protection", True):
            if any(long_option(arg, "force", 2) for arg in options) or \
                    any(re.match(r"^-[a-zA-Z]*f[a-zA-Z]*$", arg) for arg in options):
                raise Deny("dogma: git add -f bypasses .gitignore and .git/info/exclude; ignored files stay out of git.")
            for arg in rest:
                if arg.startswith("-"):
                    continue
                name = arg.rstrip("/")
                if sensitive_name(name) or re.search(r"(?i)(^|/)[^/]*(password|token)[^/]*$", name) and \
                        name.rsplit(".", 1)[-1].lower() not in CODE_EXTENSIONS:
                    raise Deny("dogma: git add of a secret file is blocked; secrets never go into git.")
        if sub == "worktree" and rest[:1] == ["remove"] and \
                any(long_option(arg, "force", 1) or re.match(r"^-[a-zA-Z]*f", arg) for arg in options):
            raise Deny("dogma: git worktree remove --force discards uncommitted work of another worktree; "
                       "let the user run it.")
        if self.flags.get("token_protection", True):
            reason = "dogma: git command may print remote URLs or stored credentials (tokens can be embedded)."
            if sub == "remote" and any(arg in ("-v", "--verbose", "show", "get-url") for arg in rest):
                raise Deny(reason + SCOPE_HINT)
            if sub == "config" and (any(arg in ("-l", "--list") or long_option(arg, "list", 3)
                                        or long_option(arg, "get-regexp", 5) for arg in rest)
                                    or any(re.search(r"(?i)remote|url|credential|insteadof", arg) for arg in rest)):
                raise Deny(reason + SCOPE_HINT)
            if sub == "var" and any(arg in ("-l",) for arg in rest):
                raise Deny(reason)
            if sub == "ls-remote" and "--get-url" in rest:
                raise Deny(reason + SCOPE_HINT)
            if sub.startswith("credential"):
                raise Deny(reason)
        if sub == "config":
            self.git_config_write(rest)
        if sub == "difftool" and any(arg in ("-x", "-t") or long_option(arg, "extcmd", 2) or arg.startswith("-x")
                                     for arg in rest) \
                or sub == "rebase" and any(arg == "-x" or long_option(arg, "exec", 3) or arg.startswith("-x")
                                           for arg in rest) \
                or sub == "bisect" and rest[:1] == ["run"] or sub == "submodule" and "foreach" in rest \
                or sub in ("filter-branch", "filter-repo") \
                or sub == "grep" and any(arg.startswith("-O") or long_option(arg, "open-files-in-pager", 2)
                                         for arg in rest) \
                or sub == "mergetool" and any(arg in ("-t", "--tool") for arg in rest) \
                or sub == "commit" and any(long_option(arg, "template", 3) for arg in rest) and False:
            raise Deny("dogma: git %s runs arbitrary commands; let the user run it." % sub)
        label = self.git_destruction(sub, rest, options, targets)
        if label and self.git_alt:
            raise Deny("dogma: destructive git command with --work-tree, --git-dir or GIT_DIR/GIT_WORK_TREE cannot be "
                       "checked; blocked.")
        if label:
            operands = [arg for arg in rest if not arg.startswith("-")]
            if sub == "clean":
                for directory in targets:
                    if directory is None:
                        continue  # unsure: the git clean finding below decides by the delete setting
                    if dangerous(directory) or self.anchor(directory, strict=True):
                        raise Deny("dogma: git clean of a protected path (%s) is never allowed." % directory)
            if sub == "rm" and operands:
                self.protect_delete(operands, targets, "git rm")
            target = operands[-1] if operands and not label.endswith(" " + operands[-1]) else ""
            self.record_delete(label, target, targets)

    def checkout_path(self, rest, targets):
        """One operand of git checkout that names an existing file or folder (relative to a directory the
        command runs in) overwrites the working copy: a discard. A branch name with no such path is not."""
        if any(arg in ("-b", "-B") or long_option(arg, "orphan", 3) for arg in rest):
            return False
        names = [arg for arg in rest if not arg.startswith("-")]
        if len(names) != 1:
            return False
        bases = [directory if directory else self.event_cwd for directory in targets] or [self.event_cwd]
        return any(os.path.lexists(os.path.join(base, names[0])) for base in bases)

    def git_destruction(self, sub, rest, options, targets=()):
        def has(*names):
            return any(arg in names for arg in rest)

        def short(letter):
            return any(re.match(r"^-[a-zA-Z]*%s" % letter, arg) and not arg.startswith("--") for arg in options)

        operands = [arg for position, arg in enumerate(rest) if not arg.startswith("-")
                    and not (position and rest[position - 1] in ("-b", "-B", "--orphan", "-s", "--source", "-m",
                                                                  "--message", "-c", "-C"))]
        if sub == "clean" and not (short("n") or any(long_option(arg, "dry-run", 2) for arg in options)):
            return "git clean"
        if sub == "rm" and not any(long_option(arg, "cached", 2) for arg in options):
            return "git rm"
        if sub == "reset" and any(long_option(arg, "hard", 2) or long_option(arg, "merge", 2)
                                  or long_option(arg, "keep", 2) for arg in options):
            return "git reset --hard"
        if sub == "checkout" and ("--" in rest or "." in operands or short("f")
                                  or any(long_option(arg, "force", 2) for arg in options) or len(operands) > 1):
            return "git checkout (discard)"
        if sub == "checkout" and self.checkout_path(rest, targets):
            return "git checkout (discard)"
        if sub == "switch" and (short("f") or any(long_option(arg, "force", 2) or long_option(arg, "discard-changes", 3)
                                                  for arg in options)):
            return "git switch --discard-changes"
        if sub == "restore" and not (any(arg in ("--staged", "-S") or long_option(arg, "staged", 2) for arg in rest)
                                     and not any(arg in ("--worktree", "-W") or long_option(arg, "worktree", 2)
                                                 for arg in rest)):
            return "git restore"
        if sub == "stash" and operands[:1] and operands[0] in ("drop", "clear"):
            return "git stash " + operands[0]
        if sub == "branch" and (short("D") or (short("d") or any(long_option(arg, "delete", 3) for arg in options))
                                and (short("f") or any(long_option(arg, "force", 2) for arg in options))):
            return "git branch -D"
        # git worktree remove without --force refuses a dirty or locked worktree and git worktree
        # prune only forgets administrative entries of vanished ones: neither is a delete (owner
        # decision); remove --force / -f stays blocked in git_command
        if sub == "push" and (any(long_option(arg, "delete", 3) for arg in options) or short("d")
                              or any(arg.startswith(":") and len(arg) > 1 for arg in operands)):
            return "git push --delete"
        if sub == "update-ref" and short("d"):
            return "git update-ref -d"
        if sub == "reflog" and operands[:1] and operands[0] in ("expire", "delete"):
            return "git reflog " + operands[0]
        if sub == "gc" and any(arg.startswith("--prune") for arg in options):
            return "git gc --prune"
        if sub == "read-tree" and (short("u") or has("--reset")):
            return "git read-tree -u"
        if sub == "checkout-index" and (short("f") or any(long_option(arg, "force", 2) for arg in options)):
            return "git checkout-index -f"
        if sub in ("filter-branch", "filter-repo"):
            return "git " + sub
        if sub == "prune":
            return "git prune"
        return None

    # shells and interpreters ------------------------------------------------------------------
    def shell(self, verb, args, segment, bodies, directories, depth, piped):
        for position, item in enumerate(args):
            if verb in ("su", "runuser", "script") and item in ("-c", "--command") and position + 1 < len(args):
                self.walk(args[position + 1], directories, depth + 1)
                return
            if re.match(r"^-[a-zA-Z]*c[a-zA-Z]*$", item):
                inner = args[position + 1] if position + 1 < len(args) else ""
                if SUB_RE.search(inner):
                    self.deny("dependency_verification",
                              "dogma: shell runs a script built at run time (for example a download); it cannot be checked.")
                self.walk(inner, directories, depth + 1)
                return
        if verb in ("su", "runuser", "script"):
            return
        script_args = [arg for arg in args if not arg.startswith("-") and not arg.startswith("+")]
        for body, _quoted in bodies:
            self.walk(body or "", directories, depth + 1)
        for word in segment.herestrings if segment else []:
            self.walk(_unquote(word), directories, depth + 1)
        if script_args and SUB_RE.search(script_args[0]):
            self.deny("dependency_verification",
                      "dogma: shell runs a script from a process substitution; it cannot be checked.")
        if piped and not script_args and not bodies:
            self.deny("dependency_verification",
                      "dogma: piping data into a shell cannot be checked (download or decoded script).")

    def interpreter(self, verb, args, segment, bodies, directories, depth, piped):
        codes, stdin_script, script_file = [], False, False
        position = 0
        while position < len(args):
            item = args[position]
            if verb.startswith(("python", "pypy")):
                if item == "-m" and position + 1 < len(args):
                    module = args[position + 1]
                    if module == "pip":
                        names = [arg for arg in args[position + 2:] if not arg.startswith("-")]
                        if names[:1] in (["install"], ["download"]):
                            self.installs.append("pip " + names[0])
                    elif module == "ensurepip":
                        self.installs.append("python -m ensurepip")
                    script_file = True
                    break
                if re.match(r"^-[a-zA-Z]*c$", item) and position + 1 < len(args):
                    codes.append(args[position + 1])
                    script_file = True
                    break
            elif verb.startswith(("perl", "ruby")):
                if re.match(r"^-[a-zA-Z]*[eE]$", item) and position + 1 < len(args):
                    codes.append(args[position + 1])
                    position += 2
                    script_file = True
                    continue
            elif verb in ("node", "nodejs", "bun", "deno"):
                if item in ("-e", "--eval", "-p", "--print", "eval") and position + 1 < len(args):
                    codes.append(args[position + 1])
                    script_file = True
                    break
            elif verb.startswith("php") and item == "-r" and position + 1 < len(args):
                codes.append(args[position + 1])
                script_file = True
                break
            if item == "-":
                stdin_script = True
                break
            if not item.startswith("-"):
                if SUB_RE.search(item):
                    self.deny("dependency_verification",
                              "dogma: interpreter runs a script built at run time; it cannot be checked.")
                script_file = True
                break
            position += 1
        if not script_file:
            stdin_script = True
        if stdin_script:
            codes.extend(body or "" for body, _quoted in bodies)
            codes.extend(_unquote(word) for word in (segment.herestrings if segment else []))
            if piped and not bodies:
                self.deny("dependency_verification",
                          "dogma: piping data into an interpreter cannot be checked (download or decoded script).")
        for code in codes:
            self.code(code, directories, depth)

    def check_moves(self, code, literals, directories):
        """Inline code that only moves or renames (no delete, no command): refused when a path it
        names is one the redirect rule of delete-guard.py protects (the home itself, a home dot
        file or dot folder, system trees, the working directory and its parents), or when the
        home is looked up in a way that hides the path. Other paths pass: os.replace(p + '.tmp', p)
        below a project is the usual atomic write."""
        if MOVE_HOME_RE.search(code):
            raise Deny("dogma: inline code moves or renames files and looks up the home directory; the target "
                       "cannot be checked, blocked.")
        guard = load_delete_guard()
        for literal in literals:
            if not literal or "\n" in literal or "$" in literal or re.search(r"\s", literal):
                continue
            for directory in directories:
                path = self.join(directory, literal)
                if path and (guard.critical_redirect(os.path.normpath(path)) or self.anchor(path)):
                    raise Deny("dogma: inline code moves or renames a protected path (%s)." % path)

    def check_file_writes(self, code, literals, directories):
        """Inline code that truncates a file by path (os.truncate) or opens a literal path for writing
        (open(path, 'w'), Path(path).write_text): the rule of the redirect. A truncation is refused when a
        path it names is critical for ">" (the home and its direct children, a home dot folder, /home/X/Y,
        system trees, drives), or when the home is looked up in a way that hides the path; a write call
        only for the startup and persistence files (the rule of ">>": ~/.bashrc, ~/.ssh, ~/.config/autostart,
        /etc, ...), so writing a file below a project or into a cache folder passes."""
        guard = load_delete_guard()
        if CODE_TRUNCATE_RE.search(code):
            if MOVE_HOME_RE.search(code):
                raise Deny("dogma: inline code truncates a file and looks up the home directory; the target "
                           "cannot be checked, blocked.")
            for literal in literals:
                if not literal or "\n" in literal or "$" in literal or re.search(r"\s", literal) \
                        or not re.search(r"[/~.]", literal):
                    continue
                for directory in directories:
                    path = self.join(directory, os.path.expanduser(literal))
                    if path and guard.critical_redirect(os.path.normpath(path)):
                        raise Deny("dogma: inline code truncates a critical path (%s)." % path)
        for match in CODE_WRITE_RE.finditer(code):
            literal = next((group for group in match.groups()[1::2] if group), "")
            for directory in directories:
                path = self.join(directory, os.path.expanduser(literal)) if literal else None
                if path and guard.critical_redirect(os.path.normpath(path), append=True):
                    raise Deny("dogma: inline code writes a startup or persistence file (%s)." % path)

    def check_symlinks(self, code, literals, directories):
        """Inline code that creates a symlink (os.symlink, Path.symlink_to, perl symlink, File.symlink,
        fs.symlinkSync): refused when a path it names is one a symlink must not point at (the rule of
        `ln -s`: the home and its parent, a direct child of the home, /, a first-level directory,
        /home/X/Y), or when the home is looked up in a way that hides the path. A later delete through
        the link would otherwise wipe the target."""
        if MOVE_HOME_RE.search(code):
            raise Deny("dogma: inline code creates a symlink and looks up the home directory; the target "
                       "cannot be checked, blocked.")
        guard = load_delete_guard()
        for literal in literals:
            if not literal or "\n" in literal or "$" in literal or re.search(r"\s", literal) \
                    or not re.search(r"[/~]", literal) and literal not in (".", ".."):
                continue
            for directory in directories:
                path = self.join(directory, literal)
                if path and guard.is_protected_link_target(os.path.realpath(path)):
                    raise Deny("dogma: inline code creates a symlink onto a protected path (%s)." % path)

    def exec_commands(self, code, literals, directories, depth, home_lookup):
        """Inline code that runs commands (subprocess, os.system, the exec family, popen). A pure literal list
        or tuple of the code (["rm", "-rf", "/"]) is one command line and is judged like shell text, so a
        harmless command (["ls", "/home/X"], os.system("ls ~")) passes and a deleting one is refused by the
        shell analysis. A deleting word that is not in such a literal list (its target is built at run
        time) next to a home lookup cannot be checked and is refused."""
        pure = set()
        for match in LITERAL_LIST_RE.finditer(code):
            values = [item.group(1) if item.group(1) is not None else item.group(2)
                      for item in CODE_STRING_RE.finditer(match.group(1))]
            if not values:
                continue
            pure.update(values)
            # one element is a shell string (subprocess with shell=True); several are argv words
            command = values[0] if len(values) == 1 else " ".join(_command_word(value) for value in values)
            self.walk(command, directories, depth + 1)
        if home_lookup and any(_deleting_command(value) for value in literals if value not in pure):
            # a deleting command whose target the home lookup hides: unsure, the delete setting decides
            self.unsure("inline code deletion", "", directories)
        return pure

    def code(self, code, directories, depth, nesting=0):
        # a backslash-newline is a line continuation (python: os.\<newline>remove(...) is os.remove(...))
        code = CONT_RE.sub("", code)
        joined, runs = join_runs(code, ARG_RUN_RE)
        runs += join_runs(code, STRING_RUN_RE)[1]
        # string literals with whitespace are text (a message, file content, shell text written
        # to a file): the call detection below reads the code without them. A literal without
        # whitespace stays (getattr(os, 'remove'), __import__('os')); literals are still checked
        # as paths and, when the code can run commands, as command lines.
        calls = CODE_STRING_RE.sub(lambda m: m.group(0) if not re.search(r"\s", m.group(0)[1:-1])
                                   else m.group(0)[0] * 2, code)
        # the words of the code with every string literal blanked: a word inside a literal (a regex
        # that spells "rmdir", a message that says "run") is data, not a call
        words = CODE_STRING_RE.sub(lambda m: m.group(0)[0] * 2, code)
        deletes = bool(CODE_DELETE_RE.search(words)) or bool(IMPORT_DELETE_RE.search(calls)) \
            or bool(re.search(r"getattr\s*\(\s*(os|shutil|pathlib|fs)\b", words)) \
            or bool(re.search(r"\b(delete-directory|delete-file|file\s+delete|rm\s*\(|unlink\s*\(|"
                              r"os\.remove|remove_tree|rmtree)", words))
        # moving or renaming over a path destroys it like a delete (checked the same way, but
        # not reported as a deletion to file-protection.sh)
        moves = bool(re.search(r"\bshutil\s*\.\s*move\b|\bos\s*\.\s*(rename|renames|replace)\b|"
                               r"\bfrom\s+(os|shutil)\s+import\b[^\n;]*\b(move|rename|renames|replace)\b", calls))
        # the same calls through an alias (import os as o), posix or nt, getattr or vars, a dynamic
        # import: one detection with the text rule of delete-guard.py (python_calls)
        alias_deletes, alias_moves = alias_calls(calls)
        deletes, moves = deletes or alias_deletes, moves or alias_moves
        # code handed to exec, eval or compile as a string is code of its own (the blanked text
        # above hides it): every literal is analysed like the code itself
        if nesting < 3 and re.search(r"\b(?:exec|eval|compile)\s*\(", calls):
            for literal in load_delete_guard().python_literals(code):
                if len(literal) >= 6 and literal != code:
                    self.code(literal, directories, depth, nesting + 1)
        executes = bool(EXEC_PRIM_RE.search(words))
        # anything that can turn a literal into a command line (then literals are walked as shell)
        may_run = executes or bool(re.search(
            r"\b(subprocess|pty|exec\w*|spawn\w*|posix_spawn\w*|system|popen\w*|getattr|__import__|importlib|"
            r"eval|compile|ctypes|multiprocessing|child_process|Open3|Kernel|shell_exec|passthru|proc_open|"
            r"backticks|qx)\b|`|%x", calls))
        literals = [match.group(1) if match.group(1) is not None else match.group(2)
                    for text in dict.fromkeys((code, joined))
                    for match in CODE_STRING_RE.finditer(text)] + runs
        literals += re.findall(r"`([^`]+)`", code)
        if CODE_INSTALL_RE.search(code):
            self.installs.append("inline code install or download-and-run")
        if moves and not deletes and not executes:
            self.check_moves(code, literals, directories)
        if CODE_TRUNCATE_RE.search(calls) or CODE_WRITE_RE.search(calls):
            self.check_file_writes(calls, literals, directories)
        if any(CODE_SYMLINK_RE.search(text) for text in (calls, CODE_STRING_RE.sub(
                lambda m: m.group(0) if not re.search(r"\s", m.group(0)[1:-1]) else m.group(0)[0] * 2, joined))):
            self.check_symlinks(code, literals, directories)
        if deletes:
            # the target of the code is unsure unless a literal path of it is on the hard list (checked below)
            self.deletes.append(("inline code deletion", "", set(directories)))
            for literal in literals:
                if not literal or "\n" in literal:
                    continue
                for directory in directories:
                    path = self.join(directory, literal) if not re.search(r"\s", literal) else None
                    if path and (literal.startswith(("/", "~")) and dangerous(path) or self.anchor(path)):
                        raise Deny("dogma: inline code deletes a protected path (%s)." % path)
                    # the kernel resolves ".." after a symlink physically: when that lands
                    # somewhere else than the textual path, the physical target is checked
                    physical = self.join(directory, literal, physical=True) if path and ".." in literal else None
                    if physical and os.path.realpath(physical) != os.path.realpath(path):
                        physical = os.path.realpath(physical)
                        if dangerous(physical) or self.anchor(physical):
                            raise Deny("dogma: inline code deletes a protected path (%s)." % physical)
        exec_pure = set()
        if executes:
            exec_pure = self.exec_commands(code, literals, directories, depth, CODE_HOME_RE.search(code))
        if self.flags.get("token_protection", True):
            if CODE_ENV_DUMP_RE.search(code):
                raise Deny("dogma: inline code may print environment variables, which can expose credentials.")
            for name in CODE_NAME_RE.findall(code):
                if _sensitive_variable(name):
                    raise Deny("dogma: inline code references a token or secret variable.")
            # the agent configuration is read in inline code only as its session descriptors or the folder itself
            if any(CONFIG_MENTION_RE.search(literal) and not SESSION_LITERAL_RE.search(literal)
                   for literal in literals):
                raise Deny("dogma: inline code references credential files or agent configuration.")
            if CODE_FRAGMENT_RE.search(code):
                raise Deny("dogma: inline code references credential files or agent configuration.")
        for literal in literals:
            if not literal:
                continue
            if re.search(r"[/.~]", literal) and not re.search(r"\s", literal):
                for directory in directories:
                    path = self.join(directory, os.path.expanduser(literal))
                    if path:
                        # the path as written and the file it names through symlinks (checked in addition)
                        for item in dict.fromkeys((path, resolved(path))):
                            self.check_location(item, "write", self.flags.get("token_protection", True), False)
            first = literal.split(None, 1)[0] if literal.split() else ""
            # a list element of an exec call was judged as its command line already (exec_commands)
            if may_run and os.path.basename(first) in EXEC_VERBS and literal not in exec_pure:
                self.walk(literal, directories, depth + 1)

    def awk(self, args, segment, directories, depth):
        programs = [arg for arg in args if not arg.startswith("-")][:1]
        for program in programs:
            if self.flags.get("token_protection", True) and re.search(r"ENVIRON(?!\s*\[\s*[\"'])", program):
                raise Deny("dogma: awk ENVIRON may print environment variables, which can expose credentials.")
            for match in re.finditer(r"system\s*\(([^)]*)\)|\|\s*getline|print[^;}]*\|\s*", program):
                inner = (match.group(1) or "").strip()
                literal = re.fullmatch(r"\"([^\"]*)\"", inner)
                if literal:
                    self.walk(literal.group(1), directories, depth + 1)
                else:
                    raise Deny("dogma: awk runs a command built at run time; blocked.")
        # the program itself only runs commands through system(), print | and getline (checked
        # above); its text (patterns such as /mv / or /rm -rf/) is no command line
        rest = list(args)
        if programs:
            rest.remove(programs[0])
        self.embedded(rest, segment, directories, depth)

    def jq(self, args):
        if not self.flags.get("token_protection", True):
            return
        for arg in args:
            if arg.startswith("-"):
                continue
            if re.search(r"(^|[^.\w$])env\b(?!\s*\.)|\$ENV\b(?!\s*\.)|\$__prog_args|\benv\s*\|", arg):
                raise Deny("dogma: jq env may print environment variables, which can expose credentials.")
            break

    def find(self, args, segment, directories, depth):
        roots = []
        for arg in args:
            if arg.startswith("-") or arg in ("(", "!", ")"):
                break
            roots.append(arg)
        position = 0
        while position < len(args):
            if args[position] in ("-exec", "-execdir", "-ok", "-okdir"):
                end = position + 1
                while end < len(args) and args[end] not in (";", "+"):
                    end += 1
                inner = args[position + 1:end]
                if inner:
                    verb = os.path.basename(inner[0])
                    if verb in DELETE_VERBS:
                        self.protect_delete(roots or ["."], directories, "find deletion", contents=True)
                    if verb in READ_VERBS | {"cp", "tar", "base64", "xxd"}:
                        for root in roots or ["."]:
                            self.check_path(root, directories, "read")
                            for found in self.targets(root, directories):
                                if found and any(_inside(found, private) and private_blocked(found, private)
                                                 or _inside(private, found) for private in self.private):
                                    raise Deny("dogma: find -exec reads files in a protected configuration home.")
                    self.command(inner, None, [], directories, depth + 1, wrapped=True)
                position = end + 1
                continue
            position += 1
        for root in roots or ["."]:
            for found in self.targets(root, directories):
                if found and any(_inside(found, private) and private_blocked(found, private)
                                 for private in self.private):
                    raise Deny("dogma: searching a protected configuration home (logins, sessions) is blocked; "
                               "list it with ls instead.")
        if "-delete" in args:
            self.protect_delete(roots or ["."], directories, "find deletion", contents=True)
            # a leading option (find -L ...) hides the start points: recorded unresolved, so the normal rules apply
            unknown_start = not roots and bool(args) and args[0].startswith("-")
            for root in roots or ["" if unknown_start else "."]:
                self.record_delete("find -delete", root, directories)


def long_option(arg, name, minimum):
    """git accepts any unique prefix of a long option (--no-veri, --forc)."""
    if not arg.startswith("--"):
        return False
    stem = arg[2:].split("=", 1)[0]
    return len(stem) >= minimum and name.startswith(stem)




# --- delete-guard ---------------------------------------------------------------------

def time_left():
    return DEADLINE - (time.monotonic() - STARTED[0])


def load_delete_guard():
    path = Path(__file__).resolve().parent / "delete-guard.py"
    spec = importlib.util.spec_from_file_location("dogma_delete_guard", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# a pure literal list or tuple of strings handed to an exec call: ["rm", "-rf", "/"], ("ls", "~")
LITERAL_LIST_RE = re.compile(r"[\[(]\s*((?:%s)(?:\s*,\s*(?:%s))*)\s*,?\s*[\])]"
                             % (CODE_STRING_RE.pattern, CODE_STRING_RE.pattern))
# the commands that destroy data or a disk when run with a protected or home target (shell words, basenames)
DESTRUCTIVE_COMMAND_RE = re.compile(r"(?:rm|rmdir|unlink|shred|srm|wipe|del|dd|truncate|wipefs|mke2fs|mkswap|"
                                    r"blkdiscard|mkfs(?:\.\w+)?)$")


def _command_word(value):
    """One argument of a literal command list as shell text: quoted only when a shell would split or
    interpret it (blanks, ; | & < > ( ) ` quotes and backslashes); ~, $ and * stay open, so the shell
    analysis expands them like the shell would (a fail-closed reading)."""
    if not value:
        return "''"
    return shlex.quote(value) if re.search(r"[\s;|&<>()`\"'\\]", value) else value


def _deleting_command(text):
    words = text.split()
    return bool(words) and DESTRUCTIVE_COMMAND_RE.match(os.path.basename(words[0])) is not None


def alias_calls(code):
    """(deletes, moves) of python code under any import name or indirection (import os as o,
    posix, vars(os), importlib.import_module): the shared detection of delete-guard.py, so both
    layers read python the same way. Strings handed to exec, eval and compile are left to the
    caller (the code here has its string literals blanked)."""
    if not re.search(r"\b(?:os|posix|nt|shutil)\b|__import__|import_module", code):
        return False, False
    return load_delete_guard().python_calls(code, nested=False)


def guard_batch(analysis, command, cwd):
    """One guard input: every normalised simple command in each candidate directory, then the original."""
    lines = []
    for tokens, directories in analysis.batch:
        for directory in sorted(directories, key=lambda value: value or ""):
            lines.append("cd " + (shlex.quote(directory) if directory else '"$OLDPWD"'))
            lines.append(shlex.join(tokens))
    lines.append("cd " + shlex.quote(os.path.realpath(cwd)))
    lines.append(command)
    return "\n".join(lines)


def run_delete_guard(batch, cwd, command):
    """delete-guard.py verdict on the batch: None (pass) or a reason.

    The legacy text patterns see only the original command (main passes it without data
    heredoc bodies): the batch starts with "cd <dir>" lines whose own path (any project
    below /home) would match them."""
    guard = load_delete_guard()
    guard.DEADLINE_AT[0] = STARTED[0] + HOOK_BUDGET
    try:
        guard.check_legacy(command)
        guard.check_command(batch, guard.Ctx(os.path.realpath(cwd)))
    except guard.Deny as error:
        return str(error)
    return None


# --- entry points ---------------------------------------------------------------------

def enabled(name):
    value = os.environ.get("CLAUDE_MB_DOGMA_" + name.upper())
    if value is not None and value.strip():
        return value.strip().lower() in ("1", "true", "yes", "on")
    return True


def analyse(command, cwd, flags):
    """Run the analysis; returns (analysis, deny reason or None)."""
    analysis = Analysis(cwd, None, flags)
    try:
        if flags["token_protection"] and _contains_secret(command):
            raise Deny("dogma: command contains secret-like content. Remove it from the tool input.")
        analysis.walk(command, {os.path.realpath(cwd)})
        if analysis.launcher and RAW_DESTRUCT_RE.search(command) and (RAW_PROTECTED_RE.search(command)
                                                                      or home() in command):
            raise Deny("dogma: command uses a launcher or word splitting together with a destructive command and "
                       "a protected path; blocked (fail closed).")
    except Deny as error:
        return analysis, str(error)
    except (OSError, ValueError, RecursionError):
        return analysis, "dogma: command could not be checked safely."
    return analysis, None


# git commands that discard uncommitted changes: the hooks gate them with the discard setting
# (§b4dk), not with the delete setting (§0lgy). git clean and the other deletes stay under §0lgy.
DISCARD_LABELS = frozenset(("git reset --hard", "git checkout (discard)", "git switch --discard-changes",
                            "git restore", "git stash drop", "git stash clear"))


def findings(analysis, cwd):
    """Permission-dependent findings. A directory is "" when it is the working directory or
    unknown: the hooks then resolve DOGMA-PERMISSIONS.md the default way (pinned project,
    current directory, session folder). "discard" marks the git discards (DISCARD_LABELS)."""
    start = os.path.realpath(cwd)

    def dirs(directories):
        return sorted({"" if directory in (None, start) else directory for directory in directories})

    def shown(target):
        # a command substitution is an internal placeholder here: shown as $(...), it stays an unresolved
        # target for delete-guard.py --temp-only (a placeholder name could look like a plain file in a temp folder)
        return SUB_RE.sub(lambda match: "$(...)", target)

    def delete(label, target, directories):
        entry = {"label": label, "target": shown(target), "dirs": dirs(directories),
                 "discard": label in DISCARD_LABELS}
        paths = analysis.candidates.get((label, target, frozenset(directories)))
        if paths is not None:
            entry["candidates"] = paths  # every absolute value of the target's variables (temp-root check only)
        return entry

    return {
        "deletes": [delete(label, target, directories) for label, target, directories in analysis.deletes],
        "installs": list(analysis.installs),
        "git": [{"op": operation, "dirs": dirs(targets), "unknown": bool(unknown)}
                for operation, targets, unknown in analysis.git_ops],
        "evasions": [{"label": label, "dirs": dirs(directories)} for directories, label in analysis.evasions],
    }


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        event = json.load(sys.stdin)
    except (ValueError, OSError):
        event = None
    if not isinstance(event, dict):
        if mode != "--findings":
            print("dogma: hook input could not be checked safely.")
        return
    if (event.get("tool_name") or "Bash") != "Bash":
        return
    tool_input = event.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str) or not command.strip():
        return
    cwd = event.get("cwd") or os.getcwd()
    if not isinstance(cwd, str) or not os.path.isabs(cwd):
        cwd = os.getcwd()
    flags = {feature: enabled(feature) for feature in FEATURES}
    analysis, reason = analyse(command, cwd, flags)
    if mode == "--findings":
        result = findings(analysis, cwd)
        if reason:
            result["blocked"] = reason
        json.dump(result, sys.stdout)
        sys.stdout.write("\n")
        return
    if reason is None and time_left() < 0:
        reason = "dogma: check ran out of time, command blocked (fail closed)."
    if reason is None:
        # delete-guard.py re-reads the command without data heredoc bodies (mark_data_bodies)
        text = analysis.without_data_bodies(command)
        reason = run_delete_guard(guard_batch(analysis, text, cwd), cwd, text)
    if reason is None and time_left() < 0:
        reason = "dogma: check ran out of time, command blocked (fail closed)."
    if reason:
        print(reason.splitlines()[0][:400])


if __name__ == "__main__":
    main()
