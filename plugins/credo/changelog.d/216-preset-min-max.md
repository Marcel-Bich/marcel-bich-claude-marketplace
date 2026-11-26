---
bump: minor
---

### Added

- Preset rungs accept `any` and `{ from: X, to: Y }` ranges for `model` and `effort` (`model: any` implies `effort: any` unless effort is given), and `allowed-pairs:` for exact combinations with nothing in between
- Hard spawn limits: top-level `default-spawn-limits:` and a per-preset `spawn-limits:` with `min-allowed`, `max-allowed` (default claude-opus-5-5/medium), `forbidden-models` (model, optional effort, roles and action) and `forbidden-action: warn | block` (default block); every config layer can override them
- `credo-preset.sh stage` prints `allowed`, `min-allowed`, `max-allowed` and `forbidden`; `show` prints the spawn limits; new `credo-preset.sh json` for the spawn guard
- A rung that requests a pair above max-allowed, below min-allowed or a forbidden pair warns when the preset loads
- Preset inheritance with `extends: <preset>` (single base, chains allowed): child roles replace base roles, `mainagent` merges field-wise, `universal-prompt` replaces, spawn-limits min/max/action override and forbidden-models append; `show` marks inherited parts `(from <base>)`; a cycle or unknown base is an error (the spawn guard fails open with a log line)

### Changed

- Pairs are ordered model first, then effort: a stronger model satisfies a rung at any effort (opus/medium passes a haiku/xhigh rung); a pair above every pair of the rung passes with the visible `stronger than preset` line, but never above max-allowed
- The spawn guard denies a spawn above max-allowed, below min-allowed or on a blocked forbidden model, also over preset exception and continue rules; a forbidden model with action warn passes with a visible line
- A fork is denied when the parent model is above the max-allowed model; the same model passes with a visible `fork effort not checkable` note
- New built-in defaults, listed ascending (budget, balanced, quality): max-allowed claude-opus-5-5/medium and claude-sonnet-5-5 forbidden with action warn for every preset; budget explore effort low to high and review medium to xhigh; balanced explore effort low to xhigh and build 4 haiku/xhigh, 2 opus/medium, 4 haiku/xhigh, then opus/medium until done; quality min-allowed haiku/xhigh and explore haiku/xhigh or opus/medium
