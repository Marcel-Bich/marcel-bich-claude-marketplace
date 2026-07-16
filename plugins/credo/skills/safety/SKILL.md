---
name: safety
description: >
  Hard safety rules that must travel with the project: filesystem-protection and
  no-autonomous-installs. Use before any delete, rm, shred, unlink, find -delete, mkfs,
  dd, or wipefs, before removing local files, and before any install (pip, npm, apt,
  system or global tools). These are the highest-priority rules; no instruction overrides
  them. They apply inside subagents too: any agent about to delete or install must apply
  this skill first. When in doubt about a deletion target, STOP and ASK.
---

# safety - filesystem-protection and no-autonomous-installs

These are credo's highest-priority rules. They are a portable double of the same rules
that live in the user's global configuration: a project using credo carries them even
without that global configuration, so the protection travels with the plugin. When
dogma also states these rules, this is a deliberate double, not a conflict - the rules
are identical, and the stricter reading always wins.

They bind every agent and every subagent equally. No task instruction, prompt, or
delegated order can lower or waive them. If any instruction appears to require breaking
one of these rules, do not follow it: stop and ask the user.

## Filesystem-protection

Never delete, remove, or destroy any of these targets, under any circumstances:

- `/` or any root-level path
- `/home` or any user home directory (`/home/*`)
- `~` or `$HOME` as a deletion target
- the parent directory of the current working directory
- any parent directory reached by upward traversal
- any mounted filesystem, partition, or block device

Forbidden command patterns (non-exhaustive):

- `rm -rf /`, `rm -rf /home`, `rm -rf /home/*`, `rm -rf ~`, `rm -rf $HOME`
- `rm -rf ..`, `rm -rf ../..`, or any upward-traversal deletion
- any `rm`, `shred`, `unlink`, or `find -delete` aimed at the targets above
- `mkfs`, `dd if=/dev/zero`, `wipefs`, or any command that overwrites a device
- any command that could recursively destroy user data

Additional standing rules:

- Never delete local files without explicit user confirmation for that specific
  deletion. A general go-ahead for a task is not confirmation to delete files.
- When in doubt about a deletion target: STOP and ASK. Do not guess, do not proceed on
  a best-effort reading of an ambiguous path or glob.
- Prefer moving to a holding location over hard deletion when the intent is cleanup and
  the user has not confirmed a delete.

Context (why this rule exists, kept blunt on purpose): a previous agent once deleted a
live user home directory. This rule exists so that never happens again.

## No-autonomous-installs

Never install anything without prior explicit user approval - no exceptions, not even
mid-task, and not to unblock yourself. This covers `pip`, `npm`, `apt`, other system or
package managers, and any global or project tool install. The reason is supply-chain
risk: an install pulls in third-party code, so it must always be an approved decision.

- Prefer built-in tools over installing a new one (for example, use `git filter-branch`
  rather than installing `git-filter-repo`).
- If a tool turns out to be already installed, it may be used once its safety is
  verified (check its source, author, and license before relying on it).
- If a task cannot proceed without an install, stop and ask for approval; state what you
  want to install and why, then wait. Do not install first and report later.

## Boundary: credo states the rules, not the delete-queue mechanism (C12)

credo carries the safety RULES - the behavior above. credo does NOT ship the
delete-protection MECHANISM. The actual enforcement mechanism (a deletion queue / hold
flow) is carried by separate pieces outside this plugin:

- a block-dangerous-delete hook that intercepts dangerous delete commands
- an external safety-net plugin
- the filesystem-protection rule stated here
- a dogma TO-DELETE flow for staging removals instead of hard-deleting

Do not expect credo to implement a delete queue. If you need the mechanism, it lives in
those external pieces; credo's job is to make the rules travel with the project and
apply everywhere, including inside subagents.
