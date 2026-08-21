---
description: credo - Promote an accepted sandbox artifact from .credo/sandbox-tmp/ to .credo/sandbox/
argument-hint: <slug>
allowed-tools:
  - Bash
  - AskUserQuestion
  - Read
  - Edit
  - Skill
---

# Promote sandbox pre-work

Promote an accepted, version-worthy WIP artifact from `.credo/sandbox-tmp/<slug>/` to
`.credo/sandbox/<slug>/`. `<slug>` is the sandbox-tmp folder name (argument: `$1`).

First **invoke the `sandbox` skill via the Skill tool** for the two-folder model, the reference
search order, and the guardrails. Then run this flow:

1. **Confirm with the user (Ask).** Recommend promotion only when the artifact is good enough:
   the pre-work answered its clarify question and is worth versioning. Ask via AskUserQuestion
   whether to promote `sandbox-tmp/<slug>` to `sandbox/<slug>`. The user decides; do not promote
   on your own initiative.

2. **On YES, move the folder.** Refuse to clobber an existing destination:

   ```bash
   src=".credo/sandbox-tmp/$1"
   dest=".credo/sandbox/$1"
   [ -d "$src" ] || { echo "sandbox-promote: no such WIP folder: $src" >&2; exit 1; }
   [ -e "$dest" ] && { echo "sandbox-promote: refusing to clobber existing $dest" >&2; exit 1; }
   mkdir -p .credo/sandbox
   mv "$src" "$dest"
   ```

3. **Fix up references.** Update the item's `## Sandbox pre-work` pointer from `sandbox-tmp/` to
   `sandbox/`; add the entry to `sandbox/INDEX.md`; and mark the `sandbox-tmp/INDEX.md` entry as
   promoted (or remove it).

## Notes

- This move is NOT an item status move: the folder is not under `items/[0-9]_*`, so the
  credo-item-move guard does not apply here and does not block it.
- Versioning follows the credo folder policy: in a tracked repo `.credo/sandbox/` is versioned;
  the WIP `.credo/sandbox-tmp/` stays local. Only the task / build role (`role-task`) commits the
  promotion - the plan / clarify role never commits (a single index owner avoids the
  `.git/index.lock` race).
- Extraction into `docs/` is a separate step the user prompts for explicitly - not part of this
  command.
