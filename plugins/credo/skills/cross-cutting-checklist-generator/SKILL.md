---
name: cross-cutting-checklist-generator
description: Detect when a concern is scattered across many places in a project (config keys, enums, translations, feature flags, API endpoints, doc references) and auto-generate a project-local checklist so that same concern is never partially updated again. Use whenever you add or change something that also exists in several other spots, or when you edit something that already has a checklist. Runs fully autonomously with no user effort, including inside subagents.
---

# cross-cutting-checklist-generator

Keep concerns that are spread across many spots from being updated in only some of
them. When a concern appears in enough scattered places, generate a project-local
checklist of every spot; then consult and update that checklist automatically on later
changes. Fully autonomous - the user does nothing.

## The problem this solves

Some concerns live in many places at once: a config key referenced from several
modules, an enum handled in multiple switches, a translation across locale files, a
feature flag checked in several components, an endpoint listed in client plus docs. Add
a new case and it is easy to update three spots and miss the fourth. These checklists
make the full set of spots explicit so nothing is left half-done.

## When this fires

- You add or modify something and notice the SAME concern already exists in several
  other places (a scattered, cross-cutting concern).
- You edit a spot that a checklist already covers (consult and update it).
- You are about to report work complete on a concern that has a checklist (verify
  completeness against it).

This fires inside subagents too: a subagent editing a scattered concern consults and
maintains the checklist just as the main agent would.

## Where checklists live

Project-local files under `.credo/checklists/` (the credo per-project namespace from
`scripts/credo-init.sh`), one file per concern, named after the concern (ASCII, for
example `.credo/checklists/config-keys.md`). Write atomically per the credo persistence
convention. `.credo/**` is git-excluded; these are working artifacts, not committed.

## Auto-create (default threshold ~3 scattered spots)

When you find a concern touched in roughly three or more separate spots and no
checklist exists yet, create one automatically. The threshold is a soft default (about
3) and a matter of judgment, not a hard rule - create earlier if the concern is
clearly cross-cutting and error-prone, and do not manufacture a checklist for something
that genuinely lives in one place. If the config exposes a threshold value, honor it;
otherwise use ~3.

A new checklist lists every known spot for the concern with a short locator
(`path:line` or `path` plus a phrase) and a one-line note on what must stay in sync.

## Auto-consult and auto-update

- Before changing a concern that has a checklist, consult it so you touch every listed
  spot, not just the ones you happened to remember.
- After changing the concern, update the checklist: add newly discovered spots, adjust
  locators that moved, and remove spots that no longer exist. The checklist stays
  current on its own.

## Completeness verify

When wrapping up a change to a checklisted concern, walk the checklist and confirm each
listed spot was actually handled. If a spot was missed, handle it before declaring the
change done. This is the payoff: the concern is fully, not partially, updated.

## Skill judgment, soft, no enforcement

This is skill-driven judgment, not hook-enforced. There is no blocking hook and no
gate; the value comes from the agent applying it consistently and autonomously. It
costs the user no effort - detection, creation, consultation, and maintenance all
happen without prompting.

## Config

The scatter threshold and any related values come from the credo config cascade
(`builtin template < ~/.claude/credo/config < .credo/config`, read via
`scripts/credo-config.sh`) when present. This skill hardcodes no personal or
environment-specific values.

## Boundaries

- Self-contained: no dependency on non-credo skills. May be referenced by name from
  other credo skills.
- Generates and maintains checklists; it does not itself verify runtime behavior
  (that is the credo `verify` skill) or gate completion.
