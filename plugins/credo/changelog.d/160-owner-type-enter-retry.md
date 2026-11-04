---
bump: patch
---

### Fixed

- Type-as-owner: after the paste the pane is checked up to five times, 0.5 s apart, before Enter. A spinner row or another transient pane change no longer stops a message before it is submitted. Only a recognised dialog on the last check holds back Enter, and the own text is taken back out of the input field when that is safe. Each stop has its own code (`dialog-after-paste`, `pane-changed`, `unknown-state`, `input-not-visible`) in the result and the log.
