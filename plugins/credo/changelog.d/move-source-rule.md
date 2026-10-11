---
bump: patch
---

### Changed

- The session-move cleanup script decides by the source. A source file is removed while it is unchanged since the verify and its target copy exists as a regular file; a target that changed after the copy (the resumed session's transcript included) no longer keeps it. A missing or emptied target copy still keeps the source, and a changed source still refuses the cleanup.
