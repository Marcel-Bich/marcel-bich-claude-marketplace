# dogma

Intelligent sync of Claude instructions from any source, with enforcement hooks for security and consistency. Use the opinionated [default rules](https://github.com/Marcel-Bich/marcel-bich-claude-dogma) or bring your own.

## Why dogma?

Claude Code is powerful, but without guardrails it's YOLO mode - and many developers (or their employers) don't want that.

### For Teams and Enterprises

**Single Source of Truth**: Define your coding standards, security rules, and AI guidelines once. Use the [default source repository](https://github.com/Marcel-Bich/marcel-bich-claude-dogma) or create your own - every team member syncs from the same source, ensuring consistency across the organization.

**Custom Rules, Your Way**: dogma doesn't force you to use anyone's defaults. Point it at your own private repository with your company's specific guidelines. The only requirement: a similar structure to the [default source repository](https://github.com/Marcel-Bich/marcel-bich-claude-dogma).

**No AI Traces in Code**: Many companies prohibit AI-generated artifacts in their codebase. dogma's hooks and cleanup commands help detect and remove typical AI patterns (curly quotes, em-dashes, AI phrases) before they reach your commits.

**Smart Merging**: When syncing rules, dogma doesn't blindly overwrite your local customizations. It handles merging intelligently, so project-specific rules stay intact while shared standards get updated.

### For Individual Developers

**Sync Across Projects**: Same rules everywhere. Whether you have 5 or 50 repositories, one `/dogma:sync` keeps them all aligned with your personal standards.

**Sync Across Devices**: Work on multiple machines? Your rules live in a source repository - sync them wherever you need them.

### Continuously Maintained

The [default source repository](https://github.com/Marcel-Bich/marcel-bich-claude-dogma) is actively developed and used by the author across all personal and professional projects. Strong self-interest ensures it stays functional and up-to-date.

## Features

### Slash Commands

- `/dogma:sync` - Sync Claude instructions from any source with interactive review
- `/dogma:cleanup` - Find and fix AI-typical patterns in code
- `/dogma:lint` - Project-agnostic linting and formatting on staged files (non-interactive)
- `/dogma:lint:setup` - Interactive setup for linting/formatting tools
- `/dogma:versioning` - Check and sync version numbers across all config files; at a release it assembles a versioned `changelog.d/` into the CHANGELOG (no tag)
- `/dogma:permissions` - Create or update DOGMA-PERMISSIONS.md interactively
- `/dogma:force` - Interactively collect and apply CLAUDE rules to the project
- `/dogma:sanitize-git` - Sanitize git history from Claude/AI traces and fix tracking issues
- `/dogma:docs-update` - Sync documentation across README files and wiki articles
- `/dogma:ignore` - Add ignore patterns to multiple locations at once (.gitignore, .git/info/exclude)
- `/dogma:ignore:audit` - Show which AI patterns are missing from ignore files
- `/dogma:ignore:sync-all` - Sync AI patterns from sync.md to all local repos (marketplace only)
- `/dogma:recommended:setup` - Check and install recommended plugins and MCP servers from a source

### Permissions System

Control Claude's autonomy with `DOGMA-PERMISSIONS.md` in your project root:

```markdown
<permissions>
- [x] (§6gpt) May run `git add` autonomously      # auto
- [x] (§2w1t) May run `git commit` autonomously   # auto
- [?] (§bww9) May run `git push` autonomously     # ask first
- [?] (§0lgy) May delete files autonomously       # ask first
- [?] (§b4dk) Discard uncommitted changes         # ask first (a missing line counts as [?])
</permissions>
```

| Marker | Mode | Behavior |
|--------|------|----------|
| `[x]` | auto | Claude does it automatically |
| `[?]` | ask | Claude asks for confirmation |
| `[ ]` | deny | Blocked (manual only) |

Run `/dogma:permissions` to configure interactively.

**Stable setting ids:** every setting carries a fixed id `(§xxxx)` (4 lowercase base36 chars) right after its checkbox, the same in every repo; parsed headings carry it too (`### Test Commands (§ly5v)`, `Worktree files (§47p9) ...`). dogma and credo find a setting by its id first, anywhere in the `<permissions>` block, so the text may be reworded, translated or merged by `/dogma:sync` without silently losing the setting. Only when no line carries the id they fall back to the old heading + text match, so files without ids keep working. Keep the id when editing a line. The full list is in [`docs/permission-ids.md`](docs/permission-ids.md); scripts pass a spec `"§xxxx|text pattern"` to `get_permission_mode` / `check_permission` in `scripts/lib-permissions.sh`.

**Which DOGMA-PERMISSIONS.md applies (and inheritance):** a session is often started in a parent or workspace folder while the work happens in another repo. dogma therefore picks the file in this order: (1) the target of the action - a Bash command's `git -C <dir> ...`, a leading `cd <dir> && ...` / `cd <dir>; ...`, or the edited file's own path; (2) the credo pinned project (`/credo:project`), when credo is installed; (3) the current folder (normally the folder the session was started in). From there the nearest `DOGMA-PERMISSIONS.md` upward counts (for a linked worktree also the main checkout). The checkbox `- [x] (§r3nx) inherit permissions` at the top of the `<permissions>` block (under `## Inheritance`; a file without it behaves like `[x]`) makes every setting the file does not define come from the session folder's file; settings defined in the file always win. Example: the session starts in `~/workspace` (with its own `DOGMA-PERMISSIONS.md`) and Claude runs `git -C ~/workspace-projects/app commit` - app's file applies, and every setting app's file lacks comes from `~/workspace`'s file; with `[ ]` only app's file counts. Inheritance goes per setting id (lines without ids per text, within each file), per Test Commands stage, and for the Worktree files list. The session folder is recorded at session start by the `session-dir-record.sh` SessionStart hook (per session id under `${CLAUDE_CONFIG_DIR:-~/.claude}/dogma/session-dirs/`, found again through `$CLAUDE_CODE_SESSION_ID`; records older than 30 days are pruned), so inheritance still works when a Bash command ran `cd <project> && ...` first; without a record, or when the recorded folder is gone, `$PWD` counts as before.

`scripts/permissions-summary.sh [--json] [dir]` lists only the restricting entries (`[?]` ask, `[ ]`/`[0]` deny) of the permission sections of the applicable `DOGMA-PERMISSIONS.md` (effective view including inherited entries; read-only, exit 4 when none is found), so any renderer can show them without parsing the file. `dir` is the target (default: pinned project, else the current folder). The JSON output marks inherited entries under an optional `"source": {"<label>": "<file>"}` key. Checkboxes under a `## Workflow ...` or `## Inheritance` heading are on/off switches (`[ ]` means off, not deny) and are skipped. Ids `(§xxxx)` never show up in its labels.

**Worktrees (Hydra subsection):** a fresh git worktree only has versioned files, so excluded ones (rules, credo items, local config) are missing there. The `### Hydra` subsection can carry a "Worktree files" list - `- link: CLAUDE.md` (symlink to the main checkout, the default kind; a line without a kind is a link) or `- copy: .env.local` (separate copy per worktree). `scripts/worktree-files.sh [--json] [dir]` prints the effective list as `<kind> <path>` lines (exit 0, 1 bad args); when the list is missing or empty it prints the default: link CLAUDE.md, CLAUDE/, GUIDES/, DOGMA-PERMISSIONS.md and .credo/. hydra's `worktree-setup.sh` and credo's `credo-worktree-setup.sh` apply it right after `git worktree add` (skipping missing and versioned paths and untracked paths that are not ignored in the main checkout, never overwriting) - so list only excluded/ignored paths. The checkbox `[x] clean up merged worktrees automatically` (default `[x]`; `[?]` asks each time, `[ ]` never, a file without it behaves as `[?]`) lets credo remove merged and clean worktrees at item close; with credo, `[x] use Hydra for 2+ independent tasks` makes credo use hydra's flow automatically for parallel code tracks. These Workflow lines do not change the `permissions-summary.sh` output.

**Test commands (optional):** a `### Test Commands` subsection under `## Workflow Permissions` says WHICH command runs at which stage (the Testing / Final Verification checkboxes say WHEN), language-agnostic, one line per stage: `` - commit: `npm run lint` ``, `` - all [main, stage]: `npm test` ``. Stages: `commit` (fast static checks before every commit), `push` (before `git push`), `relevant` (tests for the changed code when an item is reported done; takes no branch filter), `build` (build check), `all` (full suite at integration into a filtered branch and in Final Verification). The optional `[branch, ...]` filter limits a stage to those branches. Every line is optional - a missing line or section means Claude decides as before. dogma never runs them itself: `scripts/test-commands.sh [--json] [dir]` lists them and `scripts/test-commands.sh get <stage> [branch] [--dir dir]` prints the command that applies (exit 4 when none does), so Claude or other tools run it at the stage. The Final Verification checkbox `run ALL tests only at release` (default off) skips `all` on each merge and runs it once in the release commit, the normal commit that bundles several items with the version bump (never a tag or hosted release; those stay with the user).

**Changelog fragments (`changelog.d/`):** when the repo has a versioned `changelog.d/` at its root, `/dogma:versioning` assembles the fragments at release - the bundling commit with the version bump, never a tag. It prepends a `## [X.Y.Z] - YYYY-MM-DD` section built from the fragments to the existing CHANGELOG, keeping the repo's existing heading and subsection format (it asks when the format is unclear), and removes the consumed fragments in the same commit. Language-agnostic; without a versioned `changelog.d/` nothing changes.

### Update notices

When a dogma update adds something you should act on (for example a new section in `DOGMA-PERMISSIONS.md`), you are told once per repo - nobody has to remember to look. Relevance has two layers: the plugin author only adds an entry to `notices.json` for changes that need user action (most version bumps add none), and each entry's `applies` script decides whether it fits THIS repo; repos where it does not apply never see it.

At session start the `notices-inject.sh` hook tells Claude about pending notices. Claude asks you at the first natural pause (Ask tool, or plain text without one): **Run** the action (e.g. `/dogma:permissions`; marked seen after it completed), **Later** (asked again next session) or **Never** (marked seen). Running unattended/autonomously, Claude does not ask and leaves the notice pending. Seen state is per repo and per profile under `${CLAUDE_CONFIG_DIR:-~/.claude}/dogma/notices-seen/`. Notices apply wherever an effective `DOGMA-PERMISSIONS.md` resolves (same resolution as the permission hooks, also in non-git folders) and are keyed to that file's directory - the git toplevel for a repo with its own file, otherwise e.g. the session folder whose file a credo pinned project inherits, so they are shown once across both. The notice mechanism never changes anything in the repo itself. With the band (below) a toast hints at pending notices at session start (visible for 12 s). `scripts/notices-pending.sh [--json] [dir]` lists them, `scripts/notices-pending.sh mark <id> [dir]` marks one seen.

### Source broadcasts

The owner of a dogma source (the template repo `/dogma:sync` pulls from) can tell every repo that syncs from it something important once - for example "run `/dogma:sync` to get the new setting ids" - without anyone having to remember. Only hand-written entries in a `NOTICES.md` at the source root are announced; there are no generic "files changed" notices.

```markdown
# Notices

## 2026-10-02 (§n001) Stable setting ids
Action: /dogma:sync
Every setting now carries a fixed id. Run a sync once so this repo gets them.
```

One `## ` heading per entry with a date `YYYY-MM-DD` and an id `(§...)` (letters, digits, `.`, `_`, `-`; never reuse one); the rest of the heading is the title. An optional `Action:` line names the command to offer (usually `/dogma:sync`); the other lines are the text. Entries are parsed id-first: a heading without an id or without a date is ignored, and so is text before the first entry. `NOTICES.md` itself is never synced into projects.

They are delivered exactly like the plugin's update notices (ids prefixed `src:`, e.g. `src:n001`; same Run / Later / Never question, same seen state per repo and profile, the band toast counts both kinds), with these rules:

- The source is `CLAUDE_MB_DOGMA_SOURCE` (an https or ssh URL including SSH host aliases like `git@github-work:owner/repo.git`, a `file://` URL, or an absolute local path). Unset means no broadcasts. `/dogma:sync` asks once for it when it is unset and stores it (global settings by default).
- URL sources are read through a shallow clone in `${CLAUDE_CONFIG_DIR:-~/.claude}/dogma/source-cache/<hash>/`, refreshed with `git fetch` at most once a day per source, in the background (a session never waits for it; a new entry shows up the session after the fetch). Local paths are read directly. Fetches never prompt and never hang (15 s timeout, no terminal or askpass prompt, ssh `BatchMode=yes`); your normal git configuration is used as is. With several git accounts routed per folder, the fetch uses the identity routing of the repo the session runs in (its `url.*.insteadOf` rewrites and `core.sshCommand`, nothing credential-related), and each identity gets its own cache, daily check and hint.
- An unreachable source stays silent; at most once a day Claude mentions that the source is not reachable with the current git access (use a URL your git reaches without prompts, e.g. an SSH host alias, or a local path).
- Only contexts that use dogma get them (an effective `DOGMA-PERMISSIONS.md`, own or inherited, also in non-git folders; or a `CLAUDE/` dir at the git root), never the source repo itself. Entries older than 90 days (`CLAUDE_MB_DOGMA_NOTICES_MAX_AGE_DAYS`) are skipped so a fresh repo is not flooded.
- A completed `/dogma:sync` marks pending source broadcasts whose action is `/dogma:sync` as seen.

### Claude Code band (optional)

When dogma runs inside Claude Code with mods support, `hooks/band.tsx` (listed under `modules` in `hooks/hooks.json`) draws a band above the prompt: `◆ dogma` with the restricting entries from `permissions-summary.sh`, one row block per kind (`deny` red, `ask` yellow; `all auto` when nothing restricts). Changed entries flash for 6 s (moved fuchsia, new white, removed struck through). When a dogma hook blocks a tool call, a `⛔ blocked` row with the tool and reason shows for 15 s, plus a toast (6 s). At session start a toast hints at pending update notices and source broadcasts (12 s). With the credo band installed it sits below credo's band and hides at credo's `open only` preset; without credo it always shows. The band only reads and renders - the enforcement hooks work exactly the same without it and in harnesses without mods.

### Enforcement Hooks

- Git permissions, secrets detection
- File and search protection, prompt injection detection
- AI traces validation, language rules reminders
- Dependency verification (asks before package installs)
- All hooks toggleable via environment variables

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MB_DOGMA_ENABLED` | `true` | Master switch for all hooks |
| `CLAUDE_MB_DOGMA_PRE_COMMIT_LINT` | `true` | Block git commit until /dogma:lint is run |
| `CLAUDE_MB_DOGMA_SKIP_LINT_CHECK` | `false` | Skip pre-commit lint check (set by Claude after lint) |
| `CLAUDE_MB_DOGMA_AUTO_FORMAT` | `true` | Allow automatic formatting of staged files |
| `CLAUDE_MB_DOGMA_LINT_ON_STOP` | `true` | Run lint check when task completes (fallback) |
| `CLAUDE_MB_DOGMA_MODEL_POLICY` | `true` | Toggle for model enforcement hook |
| `CLAUDE_MB_DOGMA_FORCE_PARENT_MODEL` | `true` | Enforce parent model for all plugins |
| `CLAUDE_MB_DOGMA_BUILTIN_INHERIT_MODEL` | `true` | Force built-in agents to inherit parent model |
| `CLAUDE_MB_DOGMA_ALLOW_MODEL_DOWNGRADE` | `false` | Allow explicit model downgrades below parent |
| `CLAUDE_MB_DOGMA_RESET_INTERVAL` | `2` | Reset interval for subagent enforcement state (number of prompts between resets). Set to 0 to disable enforcement entirely. |
| `CLAUDE_MB_DOGMA_NOTICES` | `true` | Tell Claude once per repo about pending update notices and source broadcasts at session start |
| `CLAUDE_MB_DOGMA_SOURCE` | - | Your dogma source: https/ssh git URL (SSH host aliases work), `file://` URL or absolute path. Used by `/dogma:sync` instead of the built-in default and read for source broadcasts (`NOTICES.md`); `/dogma:sync` asks once and stores it when unset |
| `CLAUDE_MB_DOGMA_NOTICES_MAX_AGE_DAYS` | `90` | Skip source broadcasts older than this many days (`0` = no limit) |
| `CLAUDE_MB_DOGMA_SOURCE_FETCH` | `background` | How a stale source cache is refreshed: `background` (never delays a session), `sync` (wait, max 15 s), `off` (never fetch) |
| `CLAUDE_MB_DOGMA_TOKEN_ALLOW_DIRS` | - | Comma-separated list of directories whose files skip path-based name checks (content scanning still applies). `CLAUDE_PLUGIN_ROOT` is always allowed automatically. |

### Token and File Protection

- **Safe dotenv variants:** `.env.example`, `.env.sample`, `.env.template` are excluded from secret detection and git-add protection
- **Grep hook:** The Grep tool is blocked from searching in sensitive files (credential files, .env files, key files) - same rules as the Read hook

### Owner/repo scope check (git-scope.sh)

`git remote -v`, `git remote show`, `git remote get-url`, `git config` on remote URLs and `git ls-remote --get-url` stay blocked, because remote URLs can embed tokens. To learn which owner a repository belongs to, run `bash <plugin>/scripts/git-scope.sh [dir]`. It prints only `<host>/<owner>/<repo>` of `origin` (fallback: the first remote), for example `github.com/acme/demo`. Scheme, userinfo, port, query string and a `.git` suffix are dropped, and no error message echoes the URL. The block message names the absolute path of the installed script, so agents can run the check directly.

### Delete Guard (always on)

`scripts/delete-guard.sh` (core: `bash-guard.py` + `delete-guard.py`, python3) blocks Bash commands that would delete, move away or symlink onto protected paths: `/`, every first-level directory, `/home` down to depth 2, the home directory and its direct children, mount points, devices, the working directory and its parents, whole repositories and worktrees, `/mnt` and `/media` for every filesystem (Windows drive, network share, USB stick) down to depth 3 (`/mnt/d/data`, `/mnt/nas/share`, `/media/usb/folder`), the mount point itself at any depth and the mounts below the home with their whole subtree; a Windows user profile root and its first level, the Windows system and profile paths and the declared mounts (whole subtree) are protected too; deeper project files there are ordinary, and every other absolute path outside the temporary roots (`/tmp/X+`, `/var/tmp/X+`, `$TMPDIR/X+` and the Windows temp folders, see Temporary folders below). Unlike file protection it ignores DOGMA-PERMISSIONS.md, has no per-hook switch and no worktree exemption; only `CLAUDE_MB_DOGMA_ENABLED=false` turns it off. `CLAUDE_MB_DOGMA_PROTECTED_MOUNTS` (colon separated) adds mount points to the ones found in `/proc/self/mounts`.

- **Shell-aware:** `bash-guard.py` reads the command like a shell (quoting, variables, wrappers such as `sudo`/`env`/`xargs`, nested shells, substitutions, heredocs, `cd` tracking, abbreviated long options) and checks every simple command on its own. File protection, git permissions, token protection and dependency verification use the same analysis when python3 exists, so a delete, `git commit` or install is found however it is written, and words inside commit messages or search patterns no longer trigger them.
- **Data-destroying commands:** archive and sync tools that delete their sources, data-destroying git commands (`git reset --hard`, `git checkout -- .`, `git clean`, ...) follow the delete setting; with a redirected work tree or git dir they are blocked. Filesystem and disk wipe tools, mount/unmount and Windows-side deletion from WSL are always blocked.

- **Targets are resolved before the check:** `~` and `$HOME` are expanded, relative paths are joined to the working directory (including a preceding `cd`), symlinks are followed, and for a glob the directory before the wildcard is checked. A symlink in `/tmp` pointing at the home therefore cannot smuggle `rm -rf /tmp/link/*` through.
- **Strict when unsure:** a target that cannot be resolved for sure (command substitution, an unset or re-assigned variable, `eval`, `xargs rm`, `find -L ... -delete`) is blocked. Variables assigned from `mktemp` in the same command are known-safe.
- **Symlink creation:** `ln -s`, `cp -s` and interpreter `symlink` calls onto protected paths are blocked as an extra hurdle. This covers inline interpreter code and heredoc code alike (`os.symlink`, `Path.symlink_to`, perl `symlink`, `File.symlink`, `fs.symlinkSync`, under any import name): a path the code names that a link must not point at (the home and its parent, a direct child of the home, `/`, a first-level directory, `/home/X/Y`) or a home lookup that hides the path is refused.
- **Data is not a command:** a quoted heredoc body written by `cat` or `tee`, or fed to an interpreter, is file content or code the guard analyses itself, so writing a script that contains `rm -rf` passes, and so does a `printf` or `echo` argument that names a tool (`mkfs`, `rm`). This holds only while the output goes to a normal file or `/dev/null` and the body is not piped on: with a process substitution (`> >(sh)`), another `/dev/*` or `/proc/*` target, a file descriptor copy other than `1` and `2` (`>&3`), or `mkfifo` in the command, the body is checked as shell text. Heredoc bodies are cut at the line the shell ends them on (a backslash-newline stays literal inside a quoted body). String literals in inline interpreter code are text unless the code can run commands. A body is no longer data when the command can redefine `cat`, `tee` or the interpreter: a function (`cat() { sh; }`, `function cat`), `alias`, `hash`, `enable`, `builtin`, a changed `PATH` or a sourced file; then the body is checked as shell text (`/bin/cat` itself stays data). A heredoc piped into a subshell (`cat <<'EOF' | (sh)`, `| ( bash -s )`, `| (python3)`) is piped on like `| { sh; }`: it is no data and is checked. A heredoc inside `$(...)` inside double quotes, as in `git commit -m "$(cat <<'EOF' ... EOF)"`, is read as a heredoc: apostrophes in its body do not count for the quote balance.
- **Write and run:** a file written earlier in the same command and then run is refused, also when a shell or interpreter reads it through `<` (`sh < x.sh`, `sh -s < x.sh`, `. /dev/stdin < x.sh`). A syntax check does not run the script: `bash -n x.sh` and `sh -n x.sh` pass.
- **Redirects:** a truncating `>` onto a critical path is blocked. Critical are the home and its parent, direct children of a home, anything inside a home's dot folders such as `~/.config` or `~/.ssh`, `/home/X/Y`, `/` and the first-level directories, the system trees (except `/var/tmp`), devices (except `/dev/null`, `/dev/stdout` and similar), and `/mnt` and `/media` with the drive and the first level below it (`/mnt`, `/mnt/c`, `/mnt/c/Users`) plus the dot entries of a Windows home (`/mnt/c/Users/<name>/.ssh`) and the Windows system and persistence paths below a drive, deep or not (`/mnt/c/Windows`, `ProgramData`, `Program Files*`, `Users/<name>/AppData` with the Startup folder, `Start Menu`, `NTUSER.DAT*`, `Documents/PowerShell` and `Documents/WindowsPowerShell`, also below OneDrive and as `Dokumente`; a name in 8.3 short form such as `PROGRA~1` or `WINDOW~1` at these levels counts as critical). An append `>>` and `tee -a` are blocked only onto startup and persistence files: the shell and session startup files of a home (`.bashrc`, `.bash_profile`, `.bash_login`, `.bash_logout`, `.bash_aliases`, `.profile`, `.zshrc`, `.zprofile`, `.zshenv`, `.zlogin`, `.zlogout`, `.inputrc`, `.xprofile`, `.xinitrc`, `.xsession`, `.pam_environment`), `~/.ssh`, `~/.gnupg`, `~/.config/fish`, `~/.config/autostart`, `~/.config/systemd`, `~/.config/environment.d` and `~/.local/bin` (the same for `/home/X` and the Windows home `/mnt/c/Users/<name>`), the system trees (which hold the cron and at spools below `/var`), devices, the `/mnt` and `/media` levels above and the Windows system and persistence paths just named. Every other append passes: plain files of the home (`~/notes.md`), a log below a project, the other dot folders (`~/.cache/x.log`, `~/.local/state/...`, `~/.claude/...`, `~/.npm/_logs/...`), files deeper inside a Windows drive (`/mnt/c/work/project/.bench/x.log`). Files inside the Windows user temp folder (`/mnt/c/Users/<name>/AppData/Local/Temp/run.ps1`) are scratch space and pass for `>` and `>>`; the folder itself, the rest of `AppData` and `Windows/Temp` stay critical. A mount you declare in `CLAUDE_MB_DOGMA_PROTECTED_MOUNTS` is protected against `>`, `>>` and `tee` at any depth (a Windows drive such as `/mnt/c` excepted: it follows the drive rules above, so a project below it stays writable). A `#` inside `${...}` is part of the parameter expansion, no comment (`echo ${x// #/y} > /etc/hosts` is blocked). A `>` inside a quoted string or a comment is text, no redirect (`git commit -m "no longer blocks > ~/.bashrc"`, `grep -n "> ~/.bashrc" notes.md`); what a quoted string runs (`bash -c`, `$(...)`) is checked on its own. The word `truncate` is a truncation only in command position (at the start of a command, after `sudo`, `env`, `xargs`, `find -exec`), not as an argument or search pattern (`grep -n truncate a.py`), and the words of the interpreter rules (`python`, `perl`, `node`, `ruby`) inside a quoted string are text too. The standard streams (`/dev/stdout`, `/dev/stderr`, `/dev/stdin`, `/dev/fd/N`) are no files and pass as redirect targets. Targets are read the way the shell reads them: quotes inside the word (`"$HOME"/.bashrc`, `~/".bashrc"`), `$'...'` and `$"..."` words and relative targets after a `cd` are resolved first. A target with a variable that is not known (`~/$X`, `/etc/$X`, `$HOME/.$X`) is judged by its literal part before the first `$`; a target that starts with the variable is unknown and passes. The relaxation for deep `/mnt` and `/media` paths (any filesystem) covers redirects and the delete floor (`rm`, `unlink`, `shred`, `rmdir`, `find -delete`, `mv`) below such a path, which then follow the normal delete rules (the protected mounts named above and the delete permission §0lgy); `truncate` below such a path stays refused.
- **Python:** deleting calls (`os.remove`, `os.unlink`, `os.rmdir`, `os.removedirs`, `shutil.rmtree`, `Path.unlink()`) are detected, also in heredoc code, under any import name or indirection: `import os as o`, `from os import remove` or `from os import *`, `posix` and `nt`, `(os).remove`, `getattr(o, 'remove')`, `vars(os)` and `os.__dict__`, `importlib.import_module('posix')`, `sys.modules['os']`, and strings handed to `exec`, `eval` or `compile`. Inline exec calls (`subprocess`, `os.system`, ...) are judged by the commands they run: a list such as `["rm", "-rf", "/"]` is one command line, so a deleting command aimed at a protected path is refused, while `os.system("ls ~")` passes. Moving and renaming calls (`os.rename`, `os.replace`, `shutil.move`) are refused only when a path they name is critical (as for redirects, or the working directory and its parents) or the home is looked up so that the path is hidden (`Path.home()`, `expanduser(variable)`); `os.replace(p + '.tmp', p)` below a project passes. Inline and heredoc code that truncates a file by path (`os.truncate`, `fs.truncateSync`) is refused when a path it names is critical for `>` or the home is looked up so that the path is hidden; `open(path, 'w'|'a')` (also `open(file=path, mode='a')`), `Path(path).write_text()` and `fs.writeFileSync(path, ...)` onto a startup or persistence file (as for `>>`) are refused too. The bare words alone (`replace` on a string, `shutil.copy`, text that says "remove") are no deletion. A word inside a string literal of inline code (a regex such as `r'rmdir'` or `r'run'`) is data, not a call, while the strings handed to `exec`, `eval` or `compile` are read as code. A backslash-newline in python code is a line continuation (`os.\<newline>remove(...)`) and is joined before the calls are read.
- **Substitutions and pipes:** inside `$(...)` the `)` that ends a `case` pattern does not close the substitution, so a command after it is checked in double quotes like the unquoted form. A shell or interpreter that reads its script from stdin is refused anywhere inside a group or compound command that is the target of a pipe (`curl ... | (cd /tmp; sh)`, `| { true; sh; }`, `| while read l; do sh; done`), not only as the first command.
- **Private Codex home:** the Codex config home (`~/.codex` or `CODEX_HOME`) is never written. Reading is allowed inside it (`cat ~/.codex/myplugin/state.json`, `grep foo ~/.codex/history.jsonl`, `ls ~/.codex`), except the credential files (`auth.json`, `.credentials*`, `credentials.json`, `.pem` and `.key` files, `.env` but not `.env.example`), the home itself (a recursive read would reach them) and a glob in its first path component. A name built by a substitution inside it is refused. `auth.json` is refused in the Claude config homes as well (`~/.claude`, `~/.claude-*`, `$CLAUDE_CONFIG_DIR`). A recursive search (`grep -r`, `rg`, `ag`, `ack`) rooted at a Claude config home or at a directory above one is refused, because it reaches `.credentials.json`; a search of a subfolder such as `plugins/` passes, also with a `--include` glob such as `*.json`, because the glob selects file names and is not a path. The session descriptors `<profile>/sessions/*.json` can be read (also from inline code, globs and folder listings); the key files `<id>.<hex>.key` of that folder are refused, and so are globs and recursive searches that would read them.
- **Worktrees:** `git worktree remove` without `--force` (git itself refuses a dirty or locked worktree) and `git worktree prune` are no deletes; `git worktree remove --force`, `-f`, `-ff` and any prefix of `--force` (`--f`) stay blocked.
- **Temporary folders:** a delete (`rm`, `unlink`, `shred`, `rmdir`, `find -delete`) whose targets all resolve, symlinks followed, strictly inside a temporary root (`/tmp`, `/var/tmp`, `$TMPDIR` or the Windows temp folders `/mnt/<drive>/Users/<name>/AppData/Local/Temp` and `/mnt/<drive>/Windows/Temp`) is allowed whatever the delete setting (`§0lgy`). The root itself, the home below a temp root and any target that cannot be resolved for sure follow the normal rules.
- **Fail closed:** without python3, or on an internal error, a destructive-looking command is denied.

### Usage Warning

The enforcement hooks increase token consumption significantly. Recommended for Claude Max 20x (or minimum Max 5x). For sync-only usage without hooks, any plan works.

## Requirements

- `jq` - JSON processor (install: `sudo apt install jq`)

## Installation

```bash
claude plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
claude plugin install dogma@marcel-bich-claude-marketplace
```

## Documentation

Full documentation, hook details, configuration, and customization options:

**[View Documentation on Wiki](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Dogma-Plugin)**

## License

MIT - See [LICENSE](LICENSE) for full terms.

---

<details>
<summary>Keywords / Tags</summary>

Claude Code, Claude Code Plugin, Claude Code Extension, Claude Code Hooks, Claude Code Rules, Claude Code Enforcement, Claude Code Security, Claude Code Git, Claude Code Secrets, Claude Code Dependencies, Claude Code AI Traces, Claude Code Prompt Injection, Claude Code Instructions, Claude Code CLAUDE.md, Claude Code Configuration, Claude Code Settings, Claude Code Customization, Claude Code Workflow, Claude Code Automation, Claude Code Best Practices, Claude Code Guidelines, Claude Code Standards, Claude Code Conventions, Claude Code Linting, Claude Code Validation, Claude Code Protection, Claude Code Safety, Claude Code Guard, Claude Code Filter, Claude Code Block, Claude Code Warn, Claude Code Remind, Claude Code Sync, Claude Code Merge, Claude Code Import, Claude Code Export, Anthropic CLI, Anthropic Plugin, Anthropic Extension, Anthropic Claude, Anthropic AI, AI Agent Rules, AI Agent Guidelines, AI Agent Instructions, AI Agent Configuration, AI Agent Customization, AI Code Assistant, AI Coding, AI Programming, AI Development, LLM Rules, LLM Guidelines, LLM Instructions, LLM Configuration, Git Hooks, Git Protection, Git Security, Git Secrets, Git Credentials, Git Add Protection, Git Commit Protection, Git Push Protection, Secret Detection, Credential Detection, API Key Protection, Environment Variables, Prompt Injection Detection, Prompt Injection Protection, Prompt Injection Guard, AI Traces Detection, AI Traces Removal, Git History Sanitization, Git History Cleanup, Force Push, Filter Branch, Curly Quotes, Em Dashes, Smart Quotes, Typography Cleanup, German Umlauts, Language Rules, Code Quality, Code Standards, Code Conventions, Code Review, Pre-commit Hooks, Post-commit Hooks, UserPromptSubmit, PreToolUse, PostToolUse, Stop Hook, Marcel Bich, marcel-bich-claude-marketplace, dogma plugin, rules enforcement plugin

</details>
