---
bump: patch
---

### Added

- Test script `scripts/test-state-io.sh` covers the state primitives under parallel writers. A read-modify-write held under the lock loses no update, a reader never sees a partial file, a rejected write leaves the target untouched, and the mkdir fallback lock refuses a second holder

### Changed

- The tokens line label `User Tokens` is now `Work Tokens` (Input + Output, cache reads excluded), matching the README and the ledger's work tokens
- Context cache fields `total_input` and `total_output` are renamed to `last_input_tokens` and `last_output_tokens`; they hold the most recent API response, not session totals

### Fixed

- The threshold inject state is read, decided and written under one lock for the session, so parallel hook calls no longer all inject the same ACTION or status line
- The z.ai statusline line is labelled `LastReq` with `In+Out`, since it shows the last API response
- A stale mkdir lock that cannot be removed no longer makes the lock wait spin forever
