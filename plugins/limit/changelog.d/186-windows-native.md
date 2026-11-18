---
bump: patch
---

### Fixed

- Native Windows (Git Bash): the 5h and weekly figures show again. The usage response is now saved through a command-line path that Git Bash translates; before, the native curl wrote it to the drive root (`C:\tmp`) and the shared cache stayed empty
- Highscore and token figures no longer need `bc` (missing in Git Bash); they use bash integer math with the same one-decimal truncation
- Background refresh, ledger scan, plan detection and the provider hand-off start the running bash instead of a `bash` looked up on PATH, which on native Windows can be the WSL launcher (`System32\bash.exe`)
