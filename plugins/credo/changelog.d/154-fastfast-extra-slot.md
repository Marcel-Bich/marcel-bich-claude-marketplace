---
bump: patch
---

### Changed

- fastfast may get one extra builder slot above the cap when the case is clearly simple (no touches overlap with running builders, no migration or shared hot file, small change); in doubt the owner is asked first, and an autonomous run with the owner absent waits for a free slot. The resource gate always stays.
