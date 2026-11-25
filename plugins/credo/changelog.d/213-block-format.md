---
bump: patch
---

### Changed

- Block format for question, test and veto blocks (#213): every block starts with its heading
  `### <emoji> <code> · <topic>` (e.g. `### ❓ Q12 · Scope`), a `---` line stands before and
  between blocks, the context of a question stays inside its block, and the recommendation
  stands on its own labelled line (`**Recommendation:** ...`, in the reply language). The
  canonical description lives in the `verify` skill; the session skills, the SessionStart and
  mode-inject Ask rules, the Ask buffer guard reason, the periodic reminder, the README, the
  guide and psalm point to it. The open-codes footer is unchanged.

### Fixed

- The remote mirror (question codes, blocking tests, Ask dedup) and the code counter floor
  of `credo-code-next.sh` read the new `### ❓ Q12 · topic` heading as well as the older
  `### ❓ Q12) topic` form; separator lines are dropped from a mirrored block text and context.
