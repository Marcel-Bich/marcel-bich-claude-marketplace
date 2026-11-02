---
bump: patch
---

### Changed

- items skill: done means completely finished for the agent (merged, pushed, released or deployed, worktree and branch cleaned up); pending human-only checks never keep work in a branch. A defect found during the owner's verify sends the same item back with an updated DoD, to 1_clarify when an owner decision is open, otherwise to 2_go, with a new branch and worktree; follow-up items only as a last resort.
