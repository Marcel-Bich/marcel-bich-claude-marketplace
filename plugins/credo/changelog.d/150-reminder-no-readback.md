---
bump: patch
---

### Fixed

- Periodic reminder: after the one-burst paste the input field is no longer read back (that read depended on the box lines and pane size, and a failed read left the text stuck). Only a visible dialog withholds Enter; rows of the typed text itself are ignored for that check.
