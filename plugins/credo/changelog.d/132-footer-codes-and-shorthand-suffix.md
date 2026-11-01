---
bump: patch
---

### Changed

- The `?`, `??` and `???` shorthands also work at the end of any message, alone or as a suffix; the longest ending wins, and a normal question ending with `?` gets the short format (this reverses the 0.84.11 rule that a question mark attached to a word is not the shorthand)
- The periodic reminder asks to drop every code from the open-codes footer that is answered, verified, superseded, moved into an item or moot

### Fixed

- The band drops an open code as soon as the prompt answers it (`T3 vf`, `V5 ok`, `Q4: ...`, `drop all vetos`); the next footer still replaces the list
