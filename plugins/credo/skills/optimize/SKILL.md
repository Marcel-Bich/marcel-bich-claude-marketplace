---
name: optimize
description: The credo optimisation audit - an opt-in, read-only scan of a repo for things that slow parallel and long-term work (conflict hotspots, changelog fragments, test-stage convention, dogma settings, parallelism readiness), whose findings are then offered to the user one by one as Implement / Later / Never. Use when the user runs /credo:optimize, answers Yes to a [credo-optimize] opt-in question or welcome-back offer, or asks for an optimisation / health / workflow audit of the repo. It respects the repo's existing conventions, is language-agnostic, checks that the repo is fresh before scanning, and never scans or changes anything without the user's consent. Not for judging finished work against its requirement (use audit) and not for root-causing a bug (use diag).
---

# optimize - the credo optimisation audit

An audit credo OFFERS but never forces. It looks at how the repo is organised and
worked on, and proposes improvements that make parallel and long-running work smoother.
Every finding is a proposal; nothing changes without the user's explicit choice.

## Hard rules

- **Consent first.** Nothing is scanned before the user said Yes (opt-in question, the
  welcome-back offer, or running `/credo:optimize` by hand). Nothing is changed before the
  user picked Implement for that finding.
- **Interactive only.** Findings are presented with the Ask tool (plain text when no Ask
  tool exists). In credo autonomous mode never run this skill and never ask: leave a
  pending offer pending for the next attended session.
- **Read-only scan.** The scan only reads: files, `git log`, `git status`, `git branch`,
  `gh pr list` (when `gh` is available). The only write before the user's choices is the
  report file. `git fetch` in the freshness check is the only network-touching git call.
- **Never read secrets.** File NAMES of `.env*`, keys or credentials may be listed (for the
  worktree files list), their CONTENTS are never read.
- **Existing conventions win.** Detect what the repo already does first; recommend an
  ecosystem standard only where nothing exists, and let the user confirm it. Never push a
  convention onto a repo that has a working one.
- **Language-agnostic.** Use the repo's own ecosystem (package manager, test runner, CI)
  for every suggestion. Never invent a command that has no basis in the repo.

## State and helpers

All scripts live in `"${CLAUDE_PLUGIN_ROOT}/scripts/"`. State is per repo (the main
worktree) and per Claude Code profile, under
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/optimize/<repo-hash>/`.

- `credo-optimize-state.sh optin [yes|no]` - the opt-in answer. `yes` = run now, later
  offered again only to returners; `no` = never offered automatically, manual only.
- `credo-optimize-state.sh offered` - record that a welcome-back offer was asked (clears
  the pending marker; call it after ANY answer, so each return is asked once).
- `credo-optimize-state.sh never-add <id>` / `never-has <id>` / `never-list` - findings the
  user answered Never for; they are not offered again in this repo.
- `credo-optimize-idle.sh` - returner detection (used by the hook; `idle=yes` only when
  credo's last-seen, the reflog, the index and the modified files are all at least
  `optimize.idle_days` old, default 7).
- `credo-optimize-fresh.sh` - default branch + behind check (step 1).

The `credo-optimize-hook.sh` hook asks the opt-in question (credo active, answer still
open) and injects the welcome-back offer; the credo SessionStart ASK asks the opt-in
together with the credo decision. A manual `/credo:optimize` run does not change the
opt-in answer.

## Step 0: gate

1. Autonomous mode -> stop here (see Hard rules).
2. Not a git repo (`git rev-parse --show-toplevel` fails) -> say so and stop.
3. Resolve the report location: `"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" resolve-project`.
   Exit 0 -> `<credo-dir>/process/reports/`. Exit 4 (hub or no `.credo/`) -> the report is
   shown in chat only; say so (offer `/credo:setup` if the user wants it stored).

## Step 1: freshness check (before every run)

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-optimize-fresh.sh"
```

- exit 0 (`fresh=yes`): continue.
- exit 1 (`fresh=no`): show `branch`, `default`, `behind` and the `suggest=` commands
  (`git switch <default>`, `git pull --ff-only`). Ask whether to run them. Run them only
  on Yes. With uncommitted changes (`dirty` > 0) the switch may fail: say so, never stash,
  reset or discard on your own. If the user declines, stop - an audit of a stale state is
  never run silently. Continue on the stale state only when the user explicitly asks for
  that, and mark the report `fresh: no (user override)`.
- exit 3 (`fresh=unknown`: no default branch found, or `fetch=failed`): tell the user
  freshness could not be confirmed and ask whether to continue anyway; same override rule.

## Step 2: scan (delegated, read-only)

Delegate the scan to ONE read-only subagent (Explore, else general-purpose with a
read-only brief) per the credo `orchestration` skill. Brief it with the five areas below,
the Hard rules, and the never-list (`credo-optimize-state.sh never-list`) so it skips
those ids. It returns findings, each with: `id`, `area`, `title`, `evidence` (commands +
numbers, file:line where useful), `proposal`, `size` (small = a few lines in one or two
files, else large), and `convention` (existing / recommended standard).

Finding ids are stable so Never sticks: `hotspot:<path>`, `claude-md:split`,
`changelog:fragments`, `tests:convention`, `dogma:test-commands`, `dogma:release-only`,
`dogma:hydra`, `parallel:worktree-files:<path>`, `parallel:large-file:<path>`.

### 2.1 Conflict hotspots

- Files touched by the most commits recently, for example
  `git log --since=90.days --format= --name-only | sort | uniq -c | sort -rn | head -20`,
  plus the `touches:` of recent done items under `.credo/items/2_done/` when present.
- Per hotspot, propose what fits its nature:
  - a central registration list everyone appends to -> auto-discovery (directory scan,
    glob, plugin registry) instead of a hand-maintained list;
  - a large module touched for unrelated reasons -> split into smaller modules;
  - hand-written mirror lists (the same list kept in several files) -> generate them from
    one source;
  - a growing `CLAUDE.md` -> split into the dogma pattern: topic files `CLAUDE/<topic>.md`
    referenced by `@CLAUDE/<topic>.md` lines, with long background in `GUIDES/`. When text
    moves, check and fix every `@`-path that pointed at it; when unsure where a part
    belongs or whether a path is still used, ask instead of guessing.

### 2.2 Changelog fragments

- Detect the existing approach first: `CHANGELOG*`, `changelog.d/`, towncrier, changesets,
  release-please or similar. If one works, report it as existing and propose nothing.
- Otherwise, when the repo keeps a changelog that many parallel changes edit (a hotspot),
  recommend a versioned `changelog.d/` at the repo root: one small fragment per change,
  assembled by `/dogma:versioning` at the release. The release is the bundling commit with
  the version bump, never a tag; tags stay with the user. Generated files (the assembled
  changelog) change only at the release.

### 2.3 Test-stage convention

- Detect the existing layout and runner first and keep it.
- Only where none exists, recommend the ecosystem standard and let the user confirm:
  pytest `tests/` mirroring the package; jest / vitest co-located `*.test.ts`; .NET a
  `Foo.Tests/` project per `Foo`; Flutter / Dart `test/` mirroring `lib/` with
  `*_test.dart`; Go `x_test.go` next to `x.go`; other ecosystems analogously (their
  documented default).

### 2.4 dogma settings

Infer the actual workflow, read-only:

- branches: `git branch -a` (long-lived ones such as `main`, `develop`, `stage`);
- direct pushes vs merges / PRs: `git log --merges --oneline | wc -l` against
  `git log --oneline | wc -l`, and `gh pr list --state all --limit 20` when `gh` exists;
- CI config (`.github/workflows/*`, `.gitlab-ci.yml`, `azure-pipelines.yml`, ...), test
  runners and build scripts (`package.json`, `pyproject.toml`, `*.csproj`, `pubspec.yaml`,
  `go.mod`, `Makefile`, git hooks);
- current DOGMA-PERMISSIONS values via
  `"${CLAUDE_PLUGIN_ROOT}/scripts/credo-dogma-mode.sh" <subsection> <pattern>` (prints
  `missing` when not set), so only gaps or mismatches become findings.

Propose: `### Test Commands` stages (`commit`, `push`, `relevant`, `build`, `all`, with
branch filters that match the inferred branches), the Final Verification option
`run ALL tests only at release` (fits repos that bundle several items into a release
commit), and the Hydra checkboxes (`use Hydra for 2+ independent tasks`,
`clean up merged worktrees automatically`).

credo holds no dogma logic. On Implement, show the inferred values as suggestions and run
`/dogma:permissions` (Skill tool); in its Ask rounds offer these suggestions as the
recommended option. The user confirms every value there. If dogma is not installed (no
`/dogma:permissions` in this session), only report the suggestions.

### 2.5 Parallelism readiness

- Worktree files list: the effective list (dogma's `### Hydra` "Worktree files" list when
  present, else the credo default in `scripts/credo-worktree-setup.sh`: link `CLAUDE.md`,
  `CLAUDE/`, `GUIDES/`, `DOGMA-PERMISSIONS.md`, `.credo/`) against the excluded or ignored
  files that an agent in a fresh worktree would need (names only, from
  `git status --porcelain --ignored` and `.git/info/exclude`; never read their contents).
  Missing entries -> propose adding them (`link:` by default, `copy:` for files that must
  differ per worktree, such as a local env file).
- Large files that block parallel work: big files (by line count, for example over 1000
  lines) that are also hotspots -> propose a split along their natural seams.

## Step 3: report

Write `optimize-<YYYY-MM-DD>.md` (append `-2`, `-3` for further runs that day) to the
reports dir from step 0. It is versioned exactly like the rest of `.credo` in this repo
(never force-add an excluded file). Frontmatter `kind: optimize`, `date`, `fresh`
(`yes` / `no (user override)` / `unknown (user override)`), `branch`, `commit` (short
sha). Body: a summary line, then one section per finding (id, area, evidence, proposal,
size, convention) with a `decision:` line filled in step 4 (`implement`, `later`, `never`,
or `open`).

## Step 4: present findings

Present every finding not on the never-list, most valuable first, up to four per Ask
round, each with exactly these options:

- **Implement** - small: show the concrete change and do it after the user confirms
  (delegated per `orchestration`, commits per the repo rules). Large: create a credo item
  per the `items` skill (`1_todo/1_clarify` by default; straight to GO only when the user
  gives a GO and the GO entry gate passes), with the finding id and report path in its
  body. dogma settings: the `/dogma:permissions` flow in 2.4.
- **Later** - nothing is stored except the report line; the finding is offered again in a
  later audit.
- **Never** - `credo-optimize-state.sh never-add <id>`; never offered again in this repo.

Without an Ask tool, list the findings as plain text with the same three choices and wait
for the user's answers. Fill each `decision:` line in the report, then give a short
summary: implemented, items created (with their `#N`), later, never.
