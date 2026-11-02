---
bump: patch
---

### Added

- `credo-go-stall.sh [hours]` lists GO items whose file and last History date are both older than the threshold (default `items.go_stall_hours`, 24), one line per item with id, age and the last History line; read-only.
- `credo-item-move.sh --remove-duplicate <path> --user-authorized` removes one duplicate item file (same id, untracked or byte-identical to the other copy) on the owner's explicit yes; nothing else is removed.

### Changed

- The items and session-autonomous skills classify each stalled GO item (buildable, Named-Decision to `1_clarify`, human-only verify to `2_done`, blocked to `3_blocked`) before any idle or nothing-to-do report; "all GO items wait on the owner" is no longer a valid report.
- The reminder points to the stall check, compact-plus re-checks handoff labels such as "waits on T38" against the open DoD, and verify keeps the full copyable command in a shortened repeat of an owner question.
- Before an owner question or an approval park for an install, the rules and safety skills check the repo's `.credo/RULES.md` grants and the standing agreements; a grant whose conditions the agent can close is used, and the no-install default stays where no grant applies.
