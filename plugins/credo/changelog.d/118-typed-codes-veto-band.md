---
bump: patch
---

### Added

- Veto marker: an agent that decides or does something on its own writes it as its own heading line `### ✋✋ V2) Veto possible: <what> ✋✋`; open vetos show in the answer footer as `**✋: V2, V5**` and in the band as a bold yellow `✋` slot next to the test and question codes

### Changed

- Test and question codes are typed counters: tests `T1, T2 ...` and questions `Q1, Q2 ...`, one monotonic counter each, replacing the shared A..Z letter sequence; step 2 of test T3 is written `T3.2`
- Single-letter codes left open from before this convention are still read from footers
