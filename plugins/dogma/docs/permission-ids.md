# DOGMA-PERMISSIONS.md setting ids

Every setting of the `DOGMA-PERMISSIONS.md` template (`commands/permissions.md`) carries a
fixed short id `(§xxxx)` (4 lowercase base36 chars) right after its checkbox:

```markdown
- [ ] (§8eyz) run ALL tests only at release
```

Parsed headings and list labels carry it at the end of the heading or label text:

```markdown
### Test Commands (§ly5v)
Worktree files (§47p9) (excluded files only; versioned files come with git checkout):
```

Rules:

- The id is the setting. It is identical in every repo (fixed here, never random per repo)
  and never reused for another meaning. New settings get a new id, appended to this table.
- The text after the id is free: it may be reworded, translated or merged by `/dogma:sync`
  without breaking any reader.
- Readers match the id first, anywhere in the `<permissions>` block (the subsection does not
  matter). Only when no line carries the id they fall back to the old heading + text match,
  so files without ids keep working unchanged.
- Shell API: `get_permission_mode` / `check_permission` in `scripts/lib-permissions.sh` accept
  a spec `"§xxxx|text pattern"` (or `"§xxxx"` alone) wherever a pattern is accepted;
  `perm_is_checked` and `perm_has_heading` cover `[x]`-only switches and parsed headings.
  credo reads checkboxes without dogma via `credo-dogma-mode.sh --id <id> <subsection> <pattern>`.

## Registry

| Id | Section | Meaning | Read by |
|----|---------|---------|---------|
| `§r3nx` | Inheritance | inherit permissions (missing settings come from the session folder's file; missing checkbox = on) | `lib-permissions.sh` (`dogma_inherit_file`, all dogma readers), credo `credo-dogma-mode.sh` |
| `§6gpt` | Git Permissions | May run `git add` autonomously | `git-permissions.sh` (via `lib-permissions.sh`) |
| `§2w1t` | Git Permissions | May run `git commit` autonomously | `git-permissions.sh` |
| `§bww9` | Git Permissions | May run `git push` autonomously | `git-permissions.sh` |
| `§0lgy` | File Operations | May delete files autonomously (rm, unlink, git clean) | `file-protection.sh` |
| `§pq4z` | Workflow / Testing | run tests before commit | Claude (instructions) |
| `§zn2t` | Workflow / Testing | run tests before push | Claude (instructions) |
| `§r308` | Workflow / Testing | run tests on tasklist completion | Claude (instructions) |
| `§em4i` | Workflow / Testing | test: relevant tests | Claude (instructions) |
| `§2t40` | Workflow / Testing | test: silent-failure check | Claude (instructions) |
| `§d33m` | Workflow / Review | review after implementation | `review-trigger.sh` |
| `§38bw` | Workflow / Review | review before commit | Claude (instructions) |
| `§hms3` | Workflow / Review | review before push | Claude (instructions) |
| `§z66u` | Workflow / Review | review: changed code | Claude (instructions) |
| `§6h8w` | Workflow / Review | review: architecture | Claude (instructions) |
| `§n0wg` | Workflow / Review | review: types | Claude (instructions) |
| `§33tc` | Workflow / Fallback | no tests: spawn subagent for verification | `subagent-enforcement.sh` |
| `§ab7k` | Workflow / Fallback | no tests: skip | Claude (instructions) |
| `§xw1i` | Workflow / Hydra | use Hydra for 2+ independent tasks | `subagent-enforcement.sh`, credo `credo-worktree-flow.sh` (via `credo-dogma-mode.sh`) |
| `§36ch` | Workflow / Hydra | clean up merged worktrees automatically | credo `credo-item-move.sh` (via `credo-dogma-mode.sh`) |
| `§47p9` | Workflow / Hydra | "Worktree files" list label (link/copy entries below it) | `worktree-files.sh` (used by hydra `worktree-setup.sh`, credo `credo-worktree-setup.sh`) |
| `§o85w` | Workflow / Subagent Delegation | Task tool usage counts as delegation | `subagent-enforcement.sh`, `subagent-suggestion.sh` |
| `§i397` | Workflow / Subagent Delegation | Skill tool usage counts as delegation | `subagent-enforcement.sh`, `subagent-suggestion.sh` |
| `§on8g` | Workflow / TDD | TDD when tests exist | Claude (instructions) |
| `§7i3k` | Workflow / TDD | enforce TDD even without existing tests | Claude (instructions) |
| `§0c7y` | Workflow / Final Verification | run relevant tests | Claude (instructions) |
| `§aq02` | Workflow / Final Verification | check build | Claude (instructions) |
| `§3dy3` | Workflow / Final Verification | run ALL tests | Claude (instructions) |
| `§8eyz` | Workflow / Final Verification | run ALL tests only at release (the bundling commit with the version bump; never a tag) | Claude (instructions; credo `audit` skill) |
| `§ly5v` | Workflow / Test Commands | `### Test Commands` heading (per-stage commands below it) | `test-commands.sh`, `notice-applies-test-commands.sh`, `subagent-suggestion.sh` |

`permissions-summary.sh` (and the dogma band that renders it) lists the ask/deny entries of
the permission sections; it strips `(§xxxx)` from the labels, so ids never show up there.

Inheritance (`§r3nx`) is per id as well: a reader first looks a setting up in the file that
applies (target of the action > credo pinned project > session folder); only when that file
does not define it (no line with its id, and no matching text line without id) the session
folder's file is asked. `permissions-summary.sh` never lists `§r3nx` itself (a switch, not a
restriction) and marks inherited entries in its JSON output under `"source"`.
