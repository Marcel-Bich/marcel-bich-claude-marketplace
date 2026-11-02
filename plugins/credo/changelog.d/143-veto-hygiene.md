---
bump: patch
---

### Changed

- Veto codes (V) only for decisions the owner notices in the product (behaviour, visible text, money, taste, data); internal process, measurement, test-set and tooling decisions go only into the History. The agent closes a veto itself when its item is done or verified and nothing of the decision is still open, or when later work superseded it, and notes the closure in the handoff. The periodic reminder checks every open veto against its item status.
