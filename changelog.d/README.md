# Changelog fragments

Every user-visible change to a plugin gets a changelog fragment, written in the same commit as the change. At release time `scripts/changelog/release.py` turns the fragments into the next version and the changelog entry.

## Where

`plugins/<plugin>/changelog.d/<slug>.md` - one directory per plugin. This root `changelog.d/` only holds this README. A `README.md` inside a plugin's `changelog.d/` is ignored.

## Name

Lowercase letters and digits, words separated by single hyphens, optional leading item number:

- `relay-restart-race.md`
- `42-peer-lan-init.md`

## Content

```markdown
---
bump: patch
---

### Fixed

- LAN relay restart no longer races a second instance
  (continuation lines are indented by two spaces)

### Added

- `ensure` and `restart` subcommands
```

- Front matter is exactly three lines and holds only `bump:`.
- Sections use the Keep a Changelog names, exact case: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
- Each section needs at least one `- ` bullet. No text before the first section, no other headings.

## Bump level

Repo rule (`CLAUDE/CLAUDE.versioning.md`); default to patch, when in doubt use patch:

- `patch` - everything else: bugfixes, small features, improvements, refactoring
- `minor` - breaking changes, migration required, big new features (not small ones)
- `major` - groundbreaking changes, relaunch, full rewrite, heavy migration needed

The highest level among a plugin's pending fragments decides the release (major resets minor and patch, minor resets patch).

## Release

```bash
scripts/changelog/release.py <plugin> --dry-run   # preview, writes nothing
scripts/changelog/release.py <plugin>             # bump, write changelogs, delete fragments
git add <listed files> ; git commit -m "vX.Y.Z: <summary>"
```

The script validates all fragments of the plugin and refuses to write anything if one is invalid or if `plugin.yaml` and `.claude-plugin/plugin.json` disagree on the version. It updates both version files, inserts the entry on top of `plugins/<plugin>/CHANGELOG.md`, regenerates the root `CHANGELOG.md`, deletes the consumed fragments, and prints the changed files plus a suggested commit subject. It never commits.

The entry month (`YYYY-MM`, never a day date) comes from `--month`, else `GIT_COMMITTER_DATE`, else `GIT_AUTHOR_DATE`, else today - so a backdated commit gets the backdated month.

Other modes:

- `scripts/changelog/release.py --check` - validate all fragments and changelogs; warns about plugins with changed files but no fragment
- `scripts/changelog/release.py --root` - only regenerate the root `CHANGELOG.md`

## Generated root changelog

The root `CHANGELOG.md` is generated from all `plugins/*/CHANGELOG.md` files. Never edit it by hand; edit the plugin changelog and run `--root`.
