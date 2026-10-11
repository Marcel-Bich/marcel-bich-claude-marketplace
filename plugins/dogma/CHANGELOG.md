Changelog of the dogma plugin. Newest first. Months group releases; no day dates. Releases up to v1.43 are summarized by minor version.

# 2026-10

## v1

### v1.45

#### v1.45.3

##### Changed

- Reading inside the private Codex config home is allowed anywhere, no longer only in a fixed list of folders (`cat ~/.codex/myplugin/state.json`, `grep foo ~/.codex/history.jsonl`, `ls ~/.codex/logs`, `cat ~/.codex/archived_sessions/x.jsonl`). Credential files stay blocked: `auth.json` (in the Codex and the Claude config homes `~/.claude`, `~/.claude-*`, `$CLAUDE_CONFIG_DIR`), `.credentials*`, `credentials.json`, `.pem` and `.key` files, `.env` (not `.env.example`); the home itself and a glob in its first path component stay refused. Writing there is blocked as before
- `git worktree remove` without `--force` and `git worktree prune` are no deletes under the delete setting and pass (also inside `bash -c`); `git worktree remove --force`, `-f`, `-ff` and any prefix of `--force` (`--f`, `--fo`) stay blocked
- The redirect target is read the way the shell reads it: quotes inside the word (`"$HOME"/.bashrc`, `~/".bashrc"`), `$'...'`, a relative target after `cd ~` and `tee -a` are checked too
- The truncating redirect `>` is blocked only onto a critical path (the home and its parent, direct children of a home, everything inside a home's dot folders, `/home/X/Y`, `/` and first-level directories, the system trees except `/var/tmp`, devices, and `/mnt` and `/media` with the drive and the first level below it plus the dot entries of `/mnt/<x>/Users/<name>` and the Windows system and persistence paths below a drive (`Windows`, `ProgramData`, `Program Files*`, `Users/<name>/AppData` with the Startup folder, `Start Menu`, `NTUSER.DAT*`, `Documents/PowerShell`, `Documents/WindowsPowerShell`; also for `>>` and `tee -a`); files deeper inside a project on a Windows drive (`/mnt/c/work/project/.bench/x.log`) are ordinary files. This relaxation applies to redirects only: `rm`, `mv` and `truncate` below a deep `/mnt` path are not relaxed and follow the normal delete rules (protected mounts and the delete permission `§0lgy`)
- The standard streams `/dev/stdout`, `/dev/stderr`, `/dev/stdin` and `/dev/fd/N` are no files and pass as redirect targets (`> /dev/stdout`, `>> /dev/stderr`); a heredoc body written to them is still checked as shell text
- A file written in the same command and then read by a shell or interpreter through `<` (`sh < x.sh`, `sh -s < x.sh`, `. /dev/stdin < x.sh`) is refused like running it by name; a syntax check does not run the script, so `bash -n x.sh` and `sh -n x.sh` pass
- Quoted heredoc bodies written by `cat` or `tee` (not piped on) or fed to an interpreter are data for the text rules of the delete guard only while the output goes to a normal file or `/dev/null`; a process substitution (`> >(sh)`), another `/dev/*` or `/proc/*` target, a file descriptor copy other than `1` and `2`, or `mkfifo` in the command keeps the body checked as shell text
- Python deletes are detected under every spelling of the module and through indirection, in the text rule and in the inline code analysis of heredoc bodies alike (one shared detection): `import os as o`, `from os import remove` and `from os import *`, `posix` and `nt`, `(os).remove`, `getattr(o, 'remove')`, `vars(os)`, `os.__dict__`, `importlib.import_module('posix')`, `sys.modules['os']`, and strings handed to `exec`, `eval` or `compile`. `os.rename`, `os.replace` and `shutil.move` are refused only when a path they name is critical (as for redirects) or the working directory or a parent, or the home is looked up in a way that hides the path
- Deletes whose targets all lie strictly inside a temporary root (`/tmp`, `/var/tmp`, `$TMPDIR` and the Windows temp folders `/mnt/<drive>/Users/<name>/AppData/Local/Temp`, `/mnt/<drive>/Windows/Temp`) are allowed whatever the delete setting (`§0lgy`). The root itself, the home below a temp root and any target that cannot be resolved for sure follow the normal rules

##### Fixed

- Delete guard: quoted heredoc bodies written by `cat` or `tee` (not piped on) or fed to an interpreter are data; the line-by-line delete check and the text rules no longer read them as commands, so a script written to a file (`rm -rf "${VAR:?}"`, `find it's here`) no longer blocks
- The shell scanner no longer removes a backslash-newline before it looks for the end of a heredoc: bash keeps it literal inside a quoted body, so the line that ends the body and the command after it were misplaced and a command after the first `EOF` could be read as data
- A heredoc inside `$(...)` inside double quotes, the standard commit pattern `git commit -m "$(cat <<'EOF' ... EOF)"` (also `git tag -a` and `--amend`), is read as a heredoc: an apostrophe in its body (`don't`) no longer unbalances the quoting and blocks the command; `<<` inside `$((...))` is still a shift
- Delete guard: the python text rule reacts to deleting calls instead of the bare words `remove`, `unlink` or `shutil`; the interpreter symlink rule needs a symlink call, not the word; `os.replace(p + '.tmp', p)` (the atomic write) below a project passes
- Inline code: string literals with whitespace are text, so a message or file content mentioning `unlink` or `run` no longer counts as a deletion or a command; literals are only walked as shell commands when the code can run commands
- `git grep`: the search pattern is text like the pattern of `grep` (`git grep -n '.credentials' plugins/`); paths after it are still checked
- A shell option that starts with `+` (`bash +x x.sh`) is no longer taken for the script name by the check for a script written and run in the same command
- Delete guard: `truncate` is a truncation only in command position (start of a command, after `sudo`, `env`, `xargs`, `find -exec`); `grep -n truncate a.py` and `cd /home/u/proj && grep -n truncate a.py` pass
- Delete guard: a `>` inside a quoted string, a `$(...)` inside double quotes or a comment is text, no redirect (`git commit -m "no longer blocks > ~/.bashrc"`, `grep -n "> ~/.bashrc" notes.md`, a commit message heredoc with `> /etc/passwd`); a real unquoted redirect stays blocked, and the target word keeps blanks inside quotes (`> "/mnt/c/Program Files/x"`). The text rules for python, perl, node and ruby react to the interpreter as a command, not to its name inside a quoted message (`git commit -m "fix: python os.remove(~/x)"`). A command whose quotes cannot be read is judged as before
- New parity table `guard-cases/false_positives.py`: false positives that must pass, the protection that must stay, and Edit/Write inputs that no Edit/Write hook may treat as a deletion

##### Security

- New: an append `>>` and `tee -a` are blocked onto startup and persistence files. Before, `>>` was never checked at all. Blocked are the shell and session startup files of a home (`.bashrc`, `.bash_profile`, `.bash_login`, `.bash_logout`, `.bash_aliases`, `.profile`, `.zshrc`, `.zprofile`, `.zshenv`, `.zlogin`, `.zlogout`, `.inputrc`, `.xprofile`, `.xinitrc`, `.xsession`, `.pam_environment`), `~/.ssh`, `~/.gnupg`, `~/.config/fish`, `~/.config/autostart`, `~/.config/systemd`, `~/.config/environment.d` and `~/.local/bin` (the same below `/home/X` and a Windows home `/mnt/c/Users/<name>`), the system trees (the cron and at spools are below `/var`), devices and the top levels of `/mnt` and `/media`. Every other append passes: plain files of the home (`~/notes.md`), a log below a project, the other dot folders (`~/.cache/x.log`, `~/.local/state/...`, `~/.claude/...`, `~/.npm/_logs/...`)
- A redirect target with a variable that is not known (`> ~/$X`, `> /etc/$X`, `> $HOME/.$X`, `>> $HOME/.bash$X`) is judged by its literal part before the first `$`: a name that starts there could be any name, a dot name too. A target that starts with the variable (`> $X`) is unknown and passes, as before
- `$'...'` (ANSI-C quoting) and `$"..."` redirect targets are read the way the shell reads them (`> $'/etc/hosts'`, `>> $'\x2fetc/hosts'`); `tee -a` already did
- A heredoc body written by `cat` or `tee` or fed to an interpreter is data only when these commands are the real ones: a function (`cat() { sh; }`, `function cat`), an alias, `hash`, `enable`, `builtin`, a changed `PATH` or a sourced file in the same command keep the body checked as shell text (`/bin/cat` stays data)
- Inline interpreter code in a heredoc is checked for symlink calls again (`os.symlink`, `Path.symlink_to`, `from os import symlink`, perl `symlink`, `File.symlink`, `fs.symlinkSync`, under any import name): a path the code names that a link must not point at (the rule of `ln -s`: the home and its parent, a direct child of the home, `/`, a first-level directory, `/home/X/Y`) or a home lookup that hides the path is refused
- A mount declared in `CLAUDE_MB_DOGMA_PROTECTED_MOUNTS` is protected against `>`, `>>` and `tee` at any depth (`> /mnt/nas/share/a/b/c/x.txt`); a Windows drive such as `/mnt/c` is excepted, it follows the drive rules, so a project below it stays writable
- A heredoc piped into a subshell (`cat <<'EOF' | (sh)`, `| ( bash -s )`, `| (python3)`, `tee /dev/null <<'EOF' | (sh)`) is piped on like `| { sh; }`: its body is no data and is checked
- Inline and heredoc code that truncates a file by path (`os.truncate`, `fs.truncateSync`) is refused when a path it names is critical for `>` or the home is looked up so that the path is hidden; `open(path, 'w'|'a')`, `Path(path).write_text()` and `fs.writeFileSync(path, ...)` onto a startup or persistence file (the rule of `>>`) are refused as well, like the `python3 -c` form
- A python line continuation in inline or heredoc code (`os.\<newline>remove(...)`) is joined before the calls are read, so it no longer hides a delete
- A `#` inside `${...}` is part of the parameter expansion, no comment: `echo ${x// #/y} > /etc/hosts` and `echo ${x%% #*} > ~/.bashrc` are checked as redirects
- Inside `$(...)` a `)` that ends a case pattern no longer closes the substitution, in double quotes and unquoted alike, so the commands after it are checked (`echo "$(case x in a) rm -rf /home;; esac)"`); `truncate` onto a critical path inside a substitution is refused like `>`
- 8.3 short names below a Windows drive (`/mnt/c/PROGRA~1/...`, `Users/<name>/Documents/WINDOW~1/profile.ps1`) count as the critical system and profile folders for `>` and `>>`; the PowerShell profile rule covers the localized `Dokumente` too
- A shell or interpreter that reads stdin anywhere inside a group or compound command that is the target of a pipe is refused (`curl ... | (cd /tmp; sh)`, `| { true; sh; }`, `| while read l; do sh; done`), not only as the first command
- Inline code `open(file='...', mode='a'|'w')` (either argument order) onto a startup or persistence file is refused like the positional form

#### v1.45.2

##### Fixed

- Test suites remove their temp dirs and stop their child processes on exit, including failures and interrupts

#### v1.45.1

##### Fixed

- bash-guard: strings that are executed in a way the analyser cannot follow (the arguments and input of a command word chosen at run time, launcher option values, tmux command strings and send-keys text) are parsed as shell text with an unknown working directory, so relative delete targets fail closed; text that cannot be parsed is refused when a delete-capable verb with an operand appears in it. Plain arguments and stdin of ordinary programs (commit messages, test filters, clipboard tools, database clients) are not treated as shell text
- bash-guard: sudo -s/-i, doas -s, su and runuser without a command are handled like a shell reading its script from stdin
- bash-guard: tmux command names resolve by alias and unique prefix, ";" at the end of an argument splits commands, nested command strings (if-shell, confirm-before, bind-key, set-hook and similar) go through the same tmux analysis, and send-keys text is checked with an unknown working directory (hex keys decoded, single keys joined, unclear keys fail closed)
- bash-guard: wsl.exe honours --cd, ~ and other distributions for the working directory and checks the joined command line its shell runs; bwrap with an unknown option runs with an unknown working directory
- bash-guard: awk programs are only checked through system(), print | and getline, so patterns such as /mv / no longer count as commands
- bash-guard: brace expansion is bounded (long words such as a JSON document are not expanded), the time budget is checked inside the analysis loops, and long or pathological arguments are analysed in linear time
- bash-guard: every refusal of a git hook bypass (core.hooksPath, HUSKY=0/SKIP=, --no-verify, commit -n) now ends with the same hint to make a normal commit and to fix or report a failing hook
- delete-guard: string arguments of a command word chosen at run time that contain a delete command are checked with an unknown working directory

#### v1.45.0

##### Added

- `scripts/bash-guard.py`: shell-aware analysis of Bash commands for the guard hooks (quoting, variables, wrappers, nested shells, substitutions, heredocs, `cd` tracking, abbreviated long options); every simple command is checked on its own
- Protected paths now also cover mount points, devices, the working directory and its parents, and whole repositories or worktrees; `CLAUDE_MB_DOGMA_PROTECTED_MOUNTS` adds mount points
- `scripts/test-guard-parity.py` with shared case tables in `scripts/guard-cases/` (review rounds, audit probes, everyday commands that must pass)

##### Changed

- Hardened the delete guard: commands whose command word is only known at run time, archive/sync tools that delete their sources, data-destroying git commands with a redirected work tree or git dir, filesystem wipe tools and Windows-side deletion from WSL are blocked; inline interpreter code is checked for deletes near protected paths
- File protection, git permissions, token protection and dependency verification use the shell-aware analysis when python3 exists (text patterns remain the fallback); data-destroying git commands follow the delete setting, and words inside commit messages or search patterns no longer trigger the guards
- Git hook bypasses (`--no-verify`, also abbreviated, hook path overrides, hook-skipping variables) are blocked
- Both guards share one option parser (`scripts/dogma_getopt.py`) for cp, mv, install, ln, rm, unlink, rmdir, rsync, su, runuser and the env, sudo and doas wrappers: bundled short options, abbreviated long options (exact match for rsync, unknown rsync options are blocked), and both the GNU and the `POSIXLY_CORRECT` reading of the arguments are checked; an `env -S` string is split by the GNU env rules and refused when it uses an escape or expansion those rules do not allow; unknown wrapper options make relative targets fail closed
- Commands that start in another working directory are checked there (`env -C`, `sudo -D`, systemd-run, tmux, bwrap, nsenter, unshare, start-stop-daemon); where it is not known before running (a login with `sudo -i` or `su -`, a systemd service, a new tmux window) relative targets fail closed, and a command run below another root or mount namespace (chroot, nsenter/unshare with a root or mount namespace, bwrap with remapped paths) is blocked
- `rm`, `unlink`, `rmdir` and `mv` of a symlink act on the link itself and are no longer blocked when it points at a protected path; `..` after a symlink component is resolved against the link target, as the kernel does, and a path whose component before `..` does not exist yet is blocked

### v1.44

#### v1.44.4

##### Fixed

- German-only language rules now fire on German text only: the write reminder's "Keep it in
  German" note and the post-write ASCII umlaut check (fuer -> für) use a stricter shared
  detection (`lib-german.sh`) instead of substring matches that also hit English or other
  languages. Quoted text and code are ignored, and German function words must be a
  meaningful share of all words and clearly outweigh English ones
- An English file that quotes German examples is no longer reported as German, and a
  bilingual file gets no language note instead of a wrong one
- A German file is no longer reported as English because German prose contains "in" / "is"
- `/dogma:force` examples show the real umlauts again (they had been stripped to "fur",
  "konnen"); `/dogma:cleanup` and the prompt reminder state the umlaut rule is German text only
- New `scripts/test-german-detection.sh` checks German, English, French, Spanish, Dutch and
  Portuguese samples, English text with German quotes and code, and a bilingual document
  against the detection and both hooks

#### v1.44.3

##### Fixed

- dogma band no longer shows a "blocked" line forever: the notice is time-stamped and hidden after 15 s even when a plugin reload cut its timer short, and a new session starts without it

#### v1.44.2

##### Fixed

- Delete guard only analyzes a segment whose command word can delete, move or link; a verb inside an argument (a file name, a grep pattern with <...>) no longer blocks harmless commands

#### v1.44.1

##### Changed

- Notice tests use an invented project name instead of a real one

#### v1.44.0

##### Added

- Always-on delete guard: blocks deleting, moving or symlinking onto protected paths (/, first-level dirs, /home depth 0-2, the home and its children); targets are resolved first (~, $HOME, cwd and cd, symlinks, glob base), unresolvable targets are blocked, fails closed without python3

##### Security

- A symlink under /tmp pointing at a protected directory can no longer route a recursive delete past the /tmp allowance

### v1.43

#### Added

- DOGMA-PERMISSIONS.md is picked by action target, pinned project, then session folder, with per-id inheritance (default on)
- Notices also show in non-git folders and for pinned projects that inherit permissions

### v1.42

#### Added

- Source broadcasts via NOTICES.md
- `CLAUDE_MB_DOGMA_SOURCE` for sync and recommended setup
- Per-folder git identity for the source fetch

### v1.41

#### Added

- Stable setting ids (`§xxxx`) matched first with a text fallback, plus an id registry
- changelog.d assembly in `/dogma:versioning`

### v1.40

#### Added

- Worktree files list (link or copy, `.credo/` included by default) and a cleanup-merged-worktrees checkbox

#### Changed

- Subagents may commit in their own worktree, never push or merge

### v1.39

#### Added

- One-time per-repo update notices for updates that need user action (Run/Later/Never), with an optional band toast

### v1.38

#### Added

- Final Verification option to run all tests only at release

### v1.37

#### Added

- Optional per-stage test commands (commit, push, relevant, build, all) with branch filters

### v1.36

#### Added

- Optional Claude Code band showing restricting permissions with change highlights

### v1.35

#### Added

- `permissions-summary.sh` listing only the restricting DOGMA-PERMISSIONS entries

# 2026-08

## v1

### v1.34

#### Added

- `FORCE_PARENT_MODEL` setting to enforce the parent model for all plugins
- Configurable reset interval for subagent enforcement
- Allowlist for path-based token-protection checks

#### Changed

- Command UI strings are English
- Profile config dir is respected for model-policy and plan-mode checks

#### Security

- Credential protection extended to all tools and file types, including a Grep hook

# 2026-01

## v1

### v1.33

#### Changed

- git-add-protection hook about 15x faster

### v1.32

#### Added

- Review-trigger hook for PostToolUse Write/Edit

#### Changed

- Model override uses the higher of the agent default and the parent model, also for built-in agents

### v1.31

#### Added

- Working model override hook for Anthropic agents

### v1.30

#### Added

- MIT-licensed agents and a model override hook
- Read-only Bash whitelist for subagent enforcement

### v1.29

#### Added

- `/dogma:ignore` commands (add, audit, sync-all)
- `/dogma:recommended:setup` command
- Universal version file discovery in versioning, including marketplace registries
- git-pull-before-push hook to prevent data loss
- Subagent enforcement and orchestration hooks with subagent context rules and section-specific permissions

### v1.28

#### Added

- Three-state permissions (auto/ask/deny)

#### Security

- Token protection scans files before Read operations
- Chained command, subshell and backtick detection in all hooks
- Dependency verification denies instead of asking

### v1.27

#### Added

- Token-protection hook blocking commands that expose credentials

### v1.26

#### Added

- `/dogma:docs-update` command for documentation sync

### v1.25

#### Added

- `/dogma:sanitize-git` command for git history cleanup

### v1.23

#### Added

- `/dogma:force` for interactive rule enforcement

#### Changed

- `/dogma:setup` renamed to `/dogma:permissions`

### v1.22

#### Added

- `/dogma:sync` migrates permissions from CLAUDE.git.md to DOGMA-PERMISSIONS.md

### v1.21

#### Added

- `/dogma:sync` option for global or project settings.json

### v1.20

#### Added

- DOGMA-PERMISSIONS.md support with a setup command

### v1.19

#### Added

- Pre-commit lint hook and project-agnostic `/dogma:lint`

### v1.18

#### Added

- `/dogma:lint` and `/dogma:lint:setup` commands
- `/dogma:versioning` command

### v1.17

#### Changed

- Environment variables renamed to the `CLAUDE_MB_DOGMA_*` prefix

### v1.16

#### Added

- Prompt-intervention reminder and version-sync check hooks

### v1.14

#### Changed

- File protection logs and asks before deleting instead of blocking; TO-DELETE.md uses checklist format

### v1.13

#### Added

- Log mode for file deletion protection

### v1.12

#### Added

- `DOGMA_ENABLED` master switch for all hooks

#### Changed

- Hooks differentiate deny and ask; AI and secret files are blocked without bypass
- Hook output is English

### v1.11

#### Changed

- Hooks ask for confirmation instead of denying

### v1.9

#### Added

- LICENSE file handling with legal warnings

### v1.8

#### Added

- Checklist tracking

### v1.7

#### Added

- Enforcement hooks for security and consistency

### v1.6

#### Added

- Recommendations shown during sync as informational tips

### v1.5

#### Changed

- Flexible argument parsing for sync: source and instructions in any order

### v1.4

#### Added

- Rule-by-rule merging with structure conflict detection and preview before apply

### v1.3

#### Added

- git config sync (user, email)

### v1.2

#### Added

- Source analysis that scans the project structure, finds GUIDES and follows @references

### v1.1

#### Changed

- Command renamed to `/dogma:sync`

### v1.0

#### Added

- dogma plugin: sync of Claude instructions with interactive merge
