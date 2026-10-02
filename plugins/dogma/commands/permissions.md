---
description: dogma - Create or update DOGMA-PERMISSIONS.md interactively (Git, File, and Workflow permissions)
arguments: none
allowed-tools:
  - Read
  - Write
  - Edit
  - AskUserQuestion
  - Glob
  - Grep
  - Bash(git branch:*)
---

# /dogma:permissions - Create Permissions File

Create or update DOGMA-PERMISSIONS.md to configure what Claude can do autonomously.

<checkbox-legend>
| Symbol | Meaning |
|--------|---------|
| `[ ]` | Disabled |
| `[x]` | Enabled / Auto |
| `[?]` | On request |
</checkbox-legend>

<instructions>
## Step 1: Check for existing permissions

1. Check if `DOGMA-PERMISSIONS.md` exists in project root
2. If exists, show current permissions and ask if user wants to update
   - When updating, keep every existing `(§xxxx)` id and add the template id (Step 4) to each recognized setting line or parsed heading that has none yet. Ids come only from the template / `docs/permission-ids.md` - never invent a new one.
3. If not exists, will create new file

## Step 2: Git & File Permissions

Ask the user about each permission using AskUserQuestion. For each permission offer 3 choices:
- **auto** `[x]`: Claude does it automatically
- **ask** `[?]`: Claude asks for confirmation first
- **deny** `[ ]`: Claude cannot do it (blocked)

### Git Operations

**git add**
- auto: Claude can stage files for commits
- ask: Claude asks before staging
- deny: User must run `git add` manually

**git commit**
- auto: Claude can create commits autonomously
- ask: Claude asks before committing
- deny: User must create commits manually

**git push**
- auto: Claude can push to remote repositories
- ask: Claude asks before pushing (recommended)
- deny: User must push manually

### File Operations

**Delete files**
- auto: Claude can run rm, unlink, git clean
- ask: Claude prompts for confirmation before delete
- deny: Deletion commands are logged to TO-DELETE.md for manual deletion

## Step 3: Workflow Permissions

Ask about workflow automation settings.

### 3.1 Testing - When to run?

Ask: "When should tests be executed?"

Options (can select multiple):
- before commit
- before push
- on tasklist completion

Default: `[x] before commit`, `[x] before push`, `[x] on tasklist completion`

### 3.2 Testing - What to test?

Ask: "What should be tested?"

Options:
- relevant tests
- silent-failure check - finds code that swallows errors (empty catch, ignored promises)

Default: `[x] relevant tests`, `[x] silent-failure check`

### 3.3 Review - When?

Ask: "When should code review happen?"

Options (can select multiple):
- after implementation
- before commit
- before push

Default: `[x] after implementation`, `[x] before commit`, `[x] before push`

### 3.4 Review - What?

Ask: "What should be reviewed?"

Options:
- changed code
- architecture
- types

Default: `[x] changed code`

### 3.5 Fallback

Ask: "What to do when no tests exist?"

Options:
- spawn subagent for verification
- skip

Default: `[x] spawn subagent for verification`

### 3.6 Hydra - Parallel Work

Ask: "How should parallel work be handled?"

Options:
- use Hydra for 2+ independent tasks - only if Hydra available, otherwise sequential without asking

Default: `[x] use Hydra for 2+ independent tasks`

Note: If Hydra is not installed, work proceeds sequentially without asking. With credo installed, `[x]` makes credo use hydra's worktree flow for parallel code tracks automatically, `[?]` asks once per batch, `[ ]` uses plain `git worktree add`.

Ask: "Clean up merged worktrees automatically when an item is closed?" (3 options):
- auto `[x]` (default, set-and-forget): remove worktrees whose branch is fully merged into the main branch and that have no changes to tracked files, plus their merged branch
- ask `[?]`: list the candidates and ask each time
- never `[ ]`: never remove worktrees automatically

Default: `[x] clean up merged worktrees automatically`. A file without this checkbox behaves as `[?]` (older files predate the setting).

Ask: "Which excluded files should a new worktree get?" A fresh worktree only contains versioned files; excluded ones (rules, credo items, local config) are missing there. Offer:
- default (recommended): leave the list out - links CLAUDE.md, CLAUDE/, GUIDES/, DOGMA-PERMISSIONS.md and everything unversioned under .credo/, each only if it exists
- custom: free text, one entry per line as `link: <path>` (symlink to the main checkout, the default kind) or `copy: <path>` (separate copy, for files that must differ per worktree such as `.env.local`)

Only list excluded/ignored paths - versioned files come with `git checkout` and are skipped with a warning. Write the "Worktree files" list only when the user chose custom.

### 3.7 Subagent Delegation

Ask: "What counts as delegation (prevents subagent-first warning)?"

Options:
- Task tool usage counts as delegation
- Skill tool usage counts as delegation

Default: `[x] Task tool usage counts as delegation`, `[x] Skill tool usage counts as delegation`

### 3.8 TDD

Ask: "How should Test-Driven Development be handled?"

Options:
- TDD when tests exist
- enforce TDD even without existing tests

Default: `[x] TDD when tests exist`

### 3.9 Final Verification

Ask: "What to check after merge/review?"

Order: relevant tests -> build -> ALL tests (as final check before push)

Options:
- run relevant tests
- check build
- run ALL tests - as final check before push
- run ALL tests only at release - skip ALL tests on each merge; run them once in the release commit that bundles several items (version bump + assembled changelog; a normal commit, never a tag or a hosted release)

Default: `[x] run relevant tests`, `[x] check build`, `[x] run ALL tests`, `[ ] run ALL tests only at release`

### 3.10 Test Commands (optional)

The checkboxes above say WHEN to test; this step records WHICH command runs at which stage. Every stage is optional - a stage left empty means Claude decides as before, and the user may leave all of them empty (then the whole `### Test Commands` subsection is omitted). dogma never runs these commands itself; Claude reads them via `scripts/test-commands.sh get <stage> [branch]` and runs them at the stage.

Stages:
- `commit` - fast static checks before every commit (lint, typecheck)
- `push` - before `git push`
- `relevant` - tests for the changed code when a builder/audit agent reports an item done (item-scoped, takes no branch filter)
- `build` - build check
- `all` - full suite at integration into a filtered branch and in Final Verification

Before asking, detect suggestions from the repo's own files (read-only, nothing is written yet):
- `package.json` scripts (`lint`, `typecheck`, `test`, `build`, ...) - use the repo's package manager (lockfile: `pnpm-lock.yaml`, `yarn.lock`, `bun.lockb`, else npm)
- `pytest.ini`, `pyproject.toml` (`[tool.pytest]`, `[tool.ruff]`, ...), `tox.ini`, `setup.cfg`
- `*.csproj` / `*.sln` (`dotnet build`, `dotnet test`)
- `pubspec.yaml` (`flutter analyze`, `flutter test` or `dart test`)
- `go.mod` (`go vet ./...`, `go build ./...`, `go test ./...`)
- `Makefile` targets (`lint`, `test`, `build`, `check`)
- existing git hooks (`.git/hooks/*` without `.sample`, `.husky/`, `.pre-commit-config.yaml`, `lefthook.yml`) - what they already run is a good `commit` / `push` candidate
- CI config (`.github/workflows/*.yml`, `.gitlab-ci.yml`, `azure-pipelines.yml`, `Jenkinsfile`, ...) - the commands CI runs are good `build` / `all` candidates

Also run `git branch -a` and offer the repo's long-lived branches (for example `main`, `develop`, `stage`) as optional branch filters for `commit`, `push`, `build` and `all`. Filter meaning: commit = the branch committed on; push = the push target; build/all = the branch the work is integrated into (local merge, push, or PR/MR into it). No filter = every branch.

Ask per stage via AskUserQuestion: the detected suggestion (if any), "leave empty", and free text for a custom command. Ask for the branch filter only when the user set a command for that stage. Never invent a command that has no basis in the repo; nothing is written without the user's confirmation.

## Step 4: Generate DOGMA-PERMISSIONS.md

Create the file with the user's choices:

```markdown
# Dogma Permissions

Configure what Claude is allowed to do autonomously.
Mark with `[x]` for auto, `[?]` for ask, `[ ]` for deny.
The `(§xxxx)` after a checkbox is the setting's stable id: keep it, reword the text freely.

<permissions>
## Git Permissions
- [x] (§6gpt) May run `git add` autonomously
- [x] (§2w1t) May run `git commit` autonomously
- [?] (§bww9) May run `git push` autonomously

## File Operations
- [?] (§0lgy) May delete files autonomously (rm, unlink, git clean)

## Workflow Permissions

Checkbox legend: `[ ]` = disabled, `[x]` = auto, `[?]` = on request

### Testing

When to run tests?
- [x] (§pq4z) before commit
- [x] (§zn2t) before push
- [x] (§r308) on tasklist completion

What to test?
- [x] (§em4i) relevant tests
- [x] (§2t40) silent-failure check

### Review

When to review?
- [x] (§d33m) after implementation
- [x] (§38bw) before commit
- [x] (§hms3) before push

What to review?
- [x] (§z66u) changed code
- [ ] (§6h8w) architecture
- [ ] (§n0wg) types

### Fallback

When no tests exist:
- [x] (§33tc) spawn subagent for verification
- [ ] (§ab7k) skip

### Hydra

Parallel work (only if Hydra available, otherwise sequential):
- [x] (§xw1i) use Hydra for 2+ independent tasks

Worktree cleanup at item close ([x] = remove without asking, [?] = ask each time, [ ] = never):
- [x] (§36ch) clean up merged worktrees automatically

Worktree files (§47p9) (excluded files only; versioned files come with git checkout):
- link: CLAUDE.md
- link: .credo/
- copy: .env.local

### Subagent Delegation

What counts as delegation (prevents subagent-first warning):
- [x] (§o85w) Task tool usage counts as delegation
- [x] (§i397) Skill tool usage counts as delegation

### TDD

Test-Driven Development:
- [x] (§on8g) TDD when tests exist
- [ ] (§7i3k) enforce TDD even without existing tests

### Final Verification

After merge/review (order: relevant tests -> build -> ALL tests):
- [x] (§0c7y) run relevant tests
- [x] (§aq02) check build
- [x] (§3dy3) run ALL tests
- [ ] (§8eyz) run ALL tests only at release (release = the commit that bundles several items with the version bump; never a tag)

### Test Commands (§ly5v)

Per-stage commands, all optional (missing line = Claude decides as before).
Optional branch filter in brackets: the stage only applies when its branch is listed
(commit: the branch committed on; push: the push target; build/all: the branch the work
is integrated into - local merge, push, or PR/MR into it). No filter = every branch.
- commit: `npm run lint`
- push [main, develop, stage]: `npx vitest related --run`
- relevant: `npx vitest related --run`
- build: `npm run build`
- all [main, stage]: `npm test`
</permissions>

## Behavior

| Permission | [x] auto | [?] ask | [ ] deny |
|------------|----------|---------|----------|
| git add | Stages files | Asks first | Blocked |
| git commit | Creates commits | Asks first | Blocked |
| git push | Pushes to remote | Asks first | Blocked |
| delete files | Deletes files | Asks first | Logged to TO-DELETE.md |

Every setting carries a fixed id `(§xxxx)` right after its checkbox (same id in every repo). dogma and credo find a setting by its id first, so the text may be reworded or translated freely; keep the id. A line without an id is still found by its old text.
```

Replace markers based on user choices. Keep every `(§xxxx)` id exactly as in the template (they are fixed, identical in every repo and listed in `docs/permission-ids.md`); only the checkbox state changes. The "Worktree files" lines above are examples: write the list only when the user chose a custom list, otherwise leave it out (the default list applies). The `### Test Commands` lines above are examples: write only the stages the user confirmed (with their filters), and omit the whole subsection when every stage was left empty.

## Step 5: Confirm

Show the created file content and confirm with user.
</instructions>

<example>
User: /dogma:permissions

Claude: Checking if DOGMA-PERMISSIONS.md exists...

No existing permissions file found. I'll help you create DOGMA-PERMISSIONS.md.

**Git & File Permissions:**
[Uses AskUserQuestion for git add, commit, push, delete - 3 options each: auto/ask/deny]

**Workflow Permissions:**
[Uses AskUserQuestion for each workflow category]

**Test Commands (optional):**
[Suggests commands detected from package.json, CI config, git hooks, ...; asks per stage, each may stay empty]

Based on your answers:
[Shows content]

File created: DOGMA-PERMISSIONS.md. You can edit it anytime to adjust permissions.
</example>
