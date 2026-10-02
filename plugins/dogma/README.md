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
- `/dogma:versioning` - Check and sync version numbers across all config files
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
- [x] May run `git add` autonomously      # auto
- [x] May run `git commit` autonomously   # auto
- [?] May run `git push` autonomously     # ask first
- [?] May delete files autonomously       # ask first
</permissions>
```

| Marker | Mode | Behavior |
|--------|------|----------|
| `[x]` | auto | Claude does it automatically |
| `[?]` | ask | Claude asks for confirmation |
| `[ ]` | deny | Blocked (manual only) |

Run `/dogma:permissions` to configure interactively.

`scripts/permissions-summary.sh [--json] [dir]` lists only the restricting entries (`[?]` ask, `[ ]`/`[0]` deny) of the permission sections of the nearest `DOGMA-PERMISSIONS.md` (read-only, exit 4 when none is found), so any renderer can show them without parsing the file. Checkboxes under a `## Workflow ...` heading are on/off switches (`[ ]` means off, not deny) and are skipped.

**Test commands (optional):** a `### Test Commands` subsection under `## Workflow Permissions` says WHICH command runs at which stage (the Testing / Final Verification checkboxes say WHEN), language-agnostic, one line per stage: `` - commit: `npm run lint` ``, `` - all [main, stage]: `npm test` ``. Stages: `commit` (fast static checks before every commit), `push` (before `git push`), `relevant` (tests for the changed code when an item is reported done; takes no branch filter), `build` (build check), `all` (full suite at integration into a filtered branch and in Final Verification). The optional `[branch, ...]` filter limits a stage to those branches. Every line is optional - a missing line or section means Claude decides as before. dogma never runs them itself: `scripts/test-commands.sh [--json] [dir]` lists them and `scripts/test-commands.sh get <stage> [branch] [--dir dir]` prints the command that applies (exit 4 when none does), so Claude or other tools run it at the stage. The Final Verification checkbox `run ALL tests only at release` (default off) skips `all` on each merge and runs it once in the release commit, the normal commit that bundles several items with the version bump (never a tag or hosted release; those stay with the user).

### Update notices

When a dogma update adds something you should act on (for example a new section in `DOGMA-PERMISSIONS.md`), you are told once per repo - nobody has to remember to look. Relevance has two layers: the plugin author only adds an entry to `notices.json` for changes that need user action (most version bumps add none), and each entry's `applies` script decides whether it fits THIS repo; repos where it does not apply never see it.

At session start the `notices-inject.sh` hook tells Claude about pending notices. Claude asks you at the first natural pause (Ask tool, or plain text without one): **Run** the action (e.g. `/dogma:permissions`; marked seen after it completed), **Later** (asked again next session) or **Never** (marked seen). Running unattended/autonomously, Claude does not ask and leaves the notice pending. Seen state is per repo and per profile under `${CLAUDE_CONFIG_DIR:-~/.claude}/dogma/notices-seen/`. The notice mechanism never changes anything in the repo itself. With the band (below) a toast hints at pending notices at session start (visible for 12 s). `scripts/notices-pending.sh [--json] [dir]` lists them, `scripts/notices-pending.sh mark <id> [dir]` marks one seen.

### Claude Code band (optional)

When dogma runs inside Claude Code with mods support, `hooks/band.tsx` (listed under `modules` in `hooks/hooks.json`) draws a band above the prompt: `◆ dogma` with the restricting entries from `permissions-summary.sh`, one row block per kind (`deny` red, `ask` yellow; `all auto` when nothing restricts). Changed entries flash for 6 s (moved fuchsia, new white, removed struck through). When a dogma hook blocks a tool call, a `⛔ blocked` row with the tool and reason shows for 15 s, plus a toast. At session start a toast hints at pending update notices (12 s). With the credo band installed it sits below credo's band and hides at credo's `open only` preset; without credo it always shows. The band only reads and renders - the enforcement hooks work exactly the same without it and in harnesses without mods.

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
| `CLAUDE_MB_DOGMA_NOTICES` | `true` | Tell Claude once per repo about pending update notices at session start |
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
