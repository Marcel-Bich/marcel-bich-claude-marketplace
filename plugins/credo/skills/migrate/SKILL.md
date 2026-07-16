---
name: migrate
description: >
  The credo procedure for migrating an existing repo into the .credo/ structure, without
  any loss risk. Use when migrating a repo into .credo/, onboarding a legacy project into
  credo, or turning scattered process docs (requirements logs, handoffs, progress notes,
  audits, plans, specs) and open work into credo items. It is copy-only and additive:
  originals are never touched until a final, user-gated tidy step. This is a long,
  multi-phase, subagent-heavy operation. Applies inside subagents too - any agent doing
  migration work follows these rules and the credo safety skill.
---

# migrate - bring an existing repo into `.credo/`

A generic, reusable procedure to migrate ANY existing repo into the credo target form. It
tells you HOW to reach that end state safely. Everywhere below, `<repo>` is the target
repo and "the user" is its owner. This skill contains no personal, project-specific, or
absolute-path data.

## Target form: what "conformant" means here (authority)

The binding target form is defined INSIDE this plugin, not by any external design
document. At the end of a migration, everything under `.credo/` must match:

- **The scaffolded tree** produced by `"${CLAUDE_PLUGIN_ROOT}/scripts/credo-init.sh"` -
  folder layout and the files it creates (see step 1). That tree is the layout authority.
- **The `items` skill** - the work-item model: folder = status, the lean frontmatter, the
  body sections, the Definition of Done, and id issuance.
- **The `safety` skill** - the highest-priority filesystem-protection and
  no-autonomous-installs rules; they bind this whole procedure.
- **The `requirements-verbatim` skill** - the append-only, never-censored requirements log
  and the strict separation of user-verbatim text from any assistant proposal.
- **The `verify` skill** - what a real (visual, per-viewport) verification is, which
  governs whether a criterion counts as `exercised`.
- **The `budget` skill** - budget caps and the commit-identity gate, when a migration run
  is autonomous and commits anything.

Reference these by name. If any instruction points you at an external "structure design"
document, ignore it - the plugin-internal authority above is the target form.

## 0. What "migration" means (read first)

- **Migration produces the structure-conformant END STATE.** At the end, everything in
  `.credo/` matches the target form above: folder layout, file names, frontmatter, and the
  `items` model. It is NOT a verbatim copy of the old files under new folders.
- **Loss protection comes from the untouched originals**, not from verbatim file names in
  `.credo/`. The originals stay exactly where they are until the final step (8), so you may
  restructure aggressively inside `.credo/`.
- **"Verbatim" is scoped.** Preserve the CONTENT wording of requirements logs and
  evidence / reports (never rewrite, trim, soften, or censor them - this is the
  `requirements-verbatim` rule). File names, placement, frontmatter, and splitting sources
  into items ARE adapted.

## 1. Safety model (always)

The `safety` skill applies in full and overrides any task instruction. In addition, these
migration-specific safety rules hold at every step:

- **Filesystem protection.** Only copy / create. Never hard-delete (`rm`, `find -delete`,
  `shred`). The only removal is a MOVE to `.deleted/` in the final step, with the path
  mirrored (step 8).
- **Symlink check.** Test with `-L`. Never follow a symlink that points OUT of the repo
  (it can pull external content in, or write into another repo). Handle such files
  separately, with the user.
- **No secrets.** Never read or copy `.env*`, keys, credentials, ssh, or smb credentials.
- **Case-insensitive filesystems.** On NTFS (via a mount) or default APFS, a rename that
  differs only in letter case names the SAME file. A naive copy-then-`rm` can delete the
  file you just wrote. For a case-only rename, use a two-step move via a temp name; never
  `rm` the case-twin of a just-written file. The `credo-item-move.sh` helper already
  contains this two-step case-only-rename guard - prefer it for any item move.
- **No personal data in versioned / public content.** No names of people or employers in
  commit messages, PR text, or any delivered plugin files. Use role-based wording.

## 2. Modes (pick per situation)

- **User present:** on ANY ambiguity, ask directly (no report file needed).
- **User briefly away:** do read-only prep (inventory and classification), ask on return.
- **Fully autonomous:** do only the unambiguous, additive work; collect every unclear case
  into a MIGRATION REPORT with documented defaults. NEVER move originals autonomously
  (step 8 is user-gated). Budget caps and the commit-identity gate from the `budget` skill
  apply to any autonomous run that commits.

This is a long, multi-phase operation: delegate the heavy work (inventory, classification,
item cutting, and the self-audit) to subagents per the `orchestration` skill, and keep the
`safety` skill in force inside every subagent.

## 3. Step 1: scaffold and git rules and id-counter (zero risk)

- **Scaffold the tree.** Run `"${CLAUDE_PLUGIN_ROOT}/scripts/credo-init.sh"`. It is
  idempotent and creates the `.credo/` namespace: `docs/`, `screenshots/`,
  `items/{1_todo/{1_clarify,2_go},2_done,3_verified,4_archived,parked/{hold,future}}`,
  `process/{requirements,handoffs/archive,reports}`, `checklists/`, an empty `id-counter`,
  and a per-project `config` stub. Do not hand-create this tree - let the script own the
  layout so it stays the authority.
- **git-exclude.** credo default: `credo-init.sh` excludes ALL of `.credo/**` via
  `.git/info/exclude`; persistence is disk and backups, not commits. If the user opts in
  to versioning `.credo/` in this repo, re-run with `CREDO_VERSION_TRACKED=1`, which
  excludes ONLY `.credo/config` and `.credo/screenshots/` and versions the rest. `config`
  and `screenshots` are ALWAYS excluded so personal values and binaries never get
  committed.
- Also git-exclude the migration working folder (step 4).
- **`id-counter` = the highest existing legacy id** in the repo, so new ids never collide
  and old numbers are never reused. If there are no legacy ids, leave it empty (treated as 0).
  Issue every new id afterwards with `"${CLAUDE_PLUGIN_ROOT}/scripts/credo-id-next.sh"`,
  never by scanning folders or taking `max+1` yourself.

## 4. Working folder (recommended)

Keep a separate, non-versioned working folder (for example `.migration/`, git-excluded)
for the migration run itself: the plan, a progress / handoff note, the item-candidate
list, and any feedback on this procedure. Keep it distinct from `.credo/` (the target).

## 5. Step 2: classify and place process artifacts (COPY)

- **Name patterns are a case-insensitive STARTING heuristic** (match as substring / suffix,
  not exact prefix); adjust per repo. Common process-artifact name fragments to look for:
  `requirements` / `verbatim`, `handoff` / `session`, `progress` / `status`, `diag`,
  `audit`, `verification` / `verify`, `deeptest` / `test-run` / `final`, `gap`, `testplan`,
  `plan` / `buildplan`, and stable convention docs (`authority-order`, `persistence`,
  `working-method`). If a file matches no fragment or several, do not guess: ask (user
  present) or report (autonomous).
- **Content beats name.** A file whose name matches a process pattern but whose content is
  something else (for example an inter-component note named like a "handoff") is content,
  not a process artifact. Do not copy it as a handoff.
- **Process CODE never goes into `.credo/`.** `.credo/` holds prose and data only. Scripts
  (livetests, helpers, admin tools) belong in the repo tree (`scripts/`, `tests/`); code
  found under `docs/` is misplaced. Relocating it is a final-step MOVE (8), not a copy.
- **Test vs live-smoke script.** The RESULT prose of a live verification goes to
  `reports/`; the executing script goes to repo tooling, never `.credo/`. A leading `_`
  (or similar) on a script name often signals a throwaway / live script rather than a real
  test.
- **Place each artifact in the right zone, with the credo name and frontmatter:**
  - `process/requirements/`: the verbatim, append-only requirements log (the
    `requirements-verbatim` skill governs its form).
  - `process/handoffs/`: a rolling `HANDOFF.md` (the always-current "read me first" anchor)
    and `archive/` for older dated states. Historical progress / session logs also go to
    `archive/`. There is NO `process/progress/` folder; ongoing progress lives as items in
    `2_done/`.
  - `process/reports/`: diag / audit / verification / plan / design-record, each with a
    `kind:` frontmatter field; file names lowercase-kebab, keep the date.
  - `docs/`: stable "how we work here" conventions only (not feature content).
- **Language:** `.credo/` content is written in the project's working language; the
  delivered credo plugin files themselves are English. Item body section names follow the
  `items` model and are written in the project working language.

## 6. Steps 3 and 4 (iterative): content vs process vs open work, then items

These two interleave; run them together.

- **Three outcomes, not two.** A `docs/` file is either (a) content (stays at its content
  location), (b) a process report (copy to `reports/`), or (c) open work (becomes an item).
  A single doc can be partly done (report) AND partly open (item); split it.
- **Verify the REAL status before deciding done vs open.** Check the actual code /
  endpoint / version / GO marker. Do NOT trust a document's self-declared status; in-doc
  status often lies (says "open" while the feature is already built).
- **A spec without GO is content AND open work.** The spec stays as a reference at its
  content location; it spawns clarify / go items that cite it. It is neither moved to
  `items/` nor to `.credo/docs/`.
- **An audit / gap report is a report AND an item source.** Copy it to `reports/` and READ
  it to derive items; it is not consumed or deleted.
- **Decision-log tiebreaker.** A log that is USED as a stable, referenced source of truth
  (canon) stays at its content location; a pure genesis-trail of requirements goes to
  `process/requirements/`.
- **Locate the task store.** If open work is not tracked in the repo (for example it lives
  only in tool metadata), reconstruct item candidates from handoffs / progress logs; the
  NEWEST progress source is authoritative (older roadmaps go stale).
- **Cut items per the `items` model.** One id = one item. Keep existing legacy numbers as
  the item `id`; new items draw the next `id` from `credo-id-next.sh`. Frontmatter:
  `id, title, created, type, ui` (no `status` / `marker` field - the folder is the status).
  Body sections, exactly as in the `items` model: `Requirement (verbatim)`,
  `Success Criteria (= DoD)`, `Implemented`, `Verify` (4-valued per layer: not-started /
  present / wired-but-behavior-unverified / exercised - `failed` is a defect outcome, not
  one of the four states), `History`. These are the canonical English names; a project writes them in
  its own working language (for example a German project localizes the headings), but the
  model and order stay the same.
- **GO rule.** Only a 100% clarified item goes to `1_todo/2_go`. Anything with an open
  question goes to `1_todo/1_clarify` (or split: keep the fully-clarified core in `2_go`
  and file a separate clarify item for the open part).
- **Wiring / status-verify (mandatory).** Before an item records `failed` / "not started",
  wiring-check the real code (search endpoint / class / function / tests). A feature may
  already be built under a DIFFERENT task id. If built but behavior unobserved, use
  `wired-but-behavior-unverified`, not `failed`. This mirrors the `items` skill.
- **Dedup.** The same task surfacing from several sources becomes ONE item.
- **Granularity.** A large spec becomes one item with many Success Criteria, not dozens of
  micro-items. A pure decision block becomes one clarify / question item that gates the
  related go items.
- **Status-folder heuristic.** Unclear legacy todos -> `1_todo/1_clarify` (clarify when
  they come up). Deliberately deferred -> `parked/future`. `parked/hold` ONLY for a genuine
  external blocker (rare).
- **Move items with the helper.** Use `"${CLAUDE_PLUGIN_ROOT}/scripts/credo-item-move.sh"
  <id> <target>` for status moves - it is atomic, never deletes, refuses the user-only
  `3_verified` target, and carries the case-only-rename guard (step 1 safety). Update the
  item `History` after each move.
- **Reference sweep.** After any rename / restructure inside `.credo/`, update internal
  references (ids, links, paths) so nothing breaks. The `docs/` originals are untouched, so
  references pointing at them stay valid.

## 7. Self-audit (before the final step)

Run a read-only audit against the target form (the scaffolded tree and the `items`
model). Prefer delegating this to a fresh reviewer subagent (the `audit` skill), not the
agent that did the migration - a fresh reviewer catches self-inconsistencies. Check:

- folder structure matches the `credo-init.sh` tree;
- file names (lowercase-kebab; `<id>-slug.md` for items);
- mandatory frontmatter present and no `status` / `marker` field;
- no duplicate ids; no broken internal references;
- `id-counter` == the highest id in use;
- completeness: cross-check every open id / task mentioned in the sources against the
  created items, report real gaps, and confirm items correctly absent because already done.

Fix all findings before step 8.

## 8. Final step: tidy originals (ONLY with the user)

This step is ALWAYS user-gated. Do it only after all earlier steps (scaffold, classify,
items, self-audit) are complete and accepted, and never autonomously.

1. For each original that was migrated into `.credo/`, grep the WHOLE repo for its file
   name AND path-stem (without extension), across code, docs, conventions, and `.credo/`,
   INCLUDING git-ignored areas (`rg --no-ignore`) so code references without a `.md`
   extension are not missed.
2. Still referenced anywhere -> the original STAYS.
3. Zero references -> MOVE it to `.deleted/**` with the original path mirrored exactly, and
   append a line to the repo's dogma TO-DELETE list. Never hard-delete; final deletion is
   the user's manual decision later.
4. Process scripts move to the repo `scripts/` (same reference-check first).
5. If a target is a symlink pointing OUT of the repo, do not write through it
   autonomously; the `.deleted/` mirror is the primary reversible record; append the log
   entry only with the user's explicit OK.

## 9. Reuse on a new repo / future

- This procedure is repo-independent. Adjust the step-5 name patterns to the repo's
  conventions, and include any other process-doc locations (for example `notes/`,
  `planning/`) in step 6.
- Order is strict and safe: scaffold -> classify and place -> items -> self-audit ->
  tidy originals. Everything up to the tidy step is additive and copy-only; the tidy step
  is user-gated. Originals move only after the user accepts it, never before, and are never
  hard-deleted.
- dogma-first: where dogma already governs a concern (versioning, git rules, language),
  follow dogma first and treat these rules as fallback only. DOGMA-PERMISSIONS always take
  precedence.
