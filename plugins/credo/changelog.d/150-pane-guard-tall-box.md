---
bump: patch
---

### Fixed

- The pane guard finds an input box of up to 60 rows between its rules (was 20). Claude Code fills a 53-row pane with 21 rows of input for a long text, and the box was then not found, so the input was never recognised as empty or as the own text.
