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
</permissions>
```

| Marker | Mode | Behavior |
|--------|------|----------|
| `[x]` | auto | Claude does it automatically |
| `[?]` | ask | Claude asks for confirmation |
| `[ ]` | deny | Blocked (manual only) |

Run `/dogma:permissions` to configure interactively.

**Stable setting ids:** every setting carries a fixed id `(§xxxx)` (4 lowercase base36 chars) right after its checkbox, the same in every repo; parsed headings carry it too (`### Test Commands (§ly5v)`, `Worktree files (§47p9) ...`). dogma and credo find a setting by its id first, anywhere in the `<permissions>` block, so the text may be reworded, translated or merged by `/dogma:sync` without silently losing the setting. Only when no line carries the id they fall back to the old heading + text match, so files without ids keep working. Keep the id when editing a line. The full list is in [`docs/permission-ids.md`](docs/permission-ids.md); scripts pass a spec `"§xxxx|text pattern"` to `get_permission_mode` / `check_permission` in `scripts/lib-permissions.sh`.

**Which DOGMA-PERMISSIONS.md applies (and inheritance):** a session is often started in a parent or workspace folder while the work happens in another repo. dogma therefore picks the file in this order: (1) the target of the action - a Bash command's `git -C <dir> ...`, a leading `cd <dir> && ...` / `cd <dir>; ...`, or the edited file's own path; (2) the credo pinned project (`/credo:project`), when credo is installed; (3) the folder the session was started in. From there the nearest `DOGMA-PERMISSIONS.md` upward counts (for a linked worktree also the main checkout). The checkbox `- [x] (§r3nx) inherit permissions` at the top of the `<permissions>` block (under `## Inheritance`; a file without it behaves like `[x]`) makes every setting the file does not define come from the session folder's file; settings defined in the file always win. Example: the session starts in `~/workspace` (with its own `DOGMA-PERMISSIONS.md`) and Claude runs `git -C ~/workspace-projects/app commit` - app's file applies, and every setting app's file lacks comes from `~/workspace`'s file; with `[ ]` only app's file counts. Inheritance goes per setting id (lines without ids per text, within each file), per Test Commands stage, and for the Worktree files list.

`scripts/permissions-summary.sh [--json] [dir]` lists only the restricting entries (`[?]` ask, `[ ]`/`[0]` deny) of the permission sections of the applicable `DOGMA-PERMISSIONS.md` (effective view including inherited entries; read-only, exit 4 when none is found), so any renderer can show them without parsing the file. `dir` is the target (default: pinned project, else the current folder). The JSON output marks inherited entries under an optional `"source": {"<label>": "<file>"}` key. Checkboxes under a `## Workflow ...` or `## Inheritance` heading are on/off switches (`[ ]` means off, not deny) and are skipped. Ids `(§xxxx)` never show up in its labels.

**Worktrees (Hydra subsection):** a fresh git worktree only has versioned files, so excluded ones (rules, credo items, local config) are missing there. The `### Hydra` subsection can carry a "Worktree files" list - `- link: CLAUDE.md` (symlink to the main checkout, the default kind; a line without a kind is a link) or `- copy: .env.local` (separate copy per worktree). `scripts/worktree-files.sh [--json] [dir]` prints the effective list as `<kind> <path>` lines (exit 0, 1 bad args); when the list is missing or empty it prints the default: link CLAUDE.md, CLAUDE/, GUIDES/, DOGMA-PERMISSIONS.md and .credo/. hydra's `worktree-setup.sh` and credo's `credo-worktree-setup.sh` apply it right after `git worktree add` (skipping missing and versioned paths, never overwriting). The checkbox `[x] clean up merged worktrees automatically` (default `[x]`; `[?]` asks each time, `[ ]` never, a file without it behaves as `[?]`) lets credo remove merged and clean worktrees at item close; with credo, `[x] use Hydra for 2+ independent tasks` makes credo use hydra's flow automatically for parallel code tracks. These Workflow lines do not change the `permissions-summary.sh` output.

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
