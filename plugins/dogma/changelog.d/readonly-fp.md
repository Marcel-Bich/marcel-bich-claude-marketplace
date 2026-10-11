---
bump: patch
---

### Fixed

- Read-only inline Python no longer trips the deletion check on a word inside a string literal (a regex such as `r'rmdir'`); only real calls are judged
- A recursive search with a `--include` glob such as `*.json` no longer counts as a credential path when it searches a plugin folder; a recursive search rooted at a Claude or Codex config home, or at a directory above one, is refused because it reaches the login file
- Inline exec calls (`subprocess`, `os.system`) are judged by the command they run: a deleting command aimed at the home, root or a parent folder is refused, harmless commands such as `ls ~` pass; the exec pattern of `bash-guard.py` had a stray control character and never matched
- Disk tools named inside quoted `printf` or `echo` text (`mkfs`, `dd`, `wipefs`) are text, not a disk operation; real `dd`, `mkfs` and `wipefs` commands stay refused, also through `sudo`, `env` and `bash -c`
- Session descriptors `<profile>/sessions/*.json` can be read, also from inline code, globs and folder listings; the key files of that folder stay refused, and so do globs and recursive searches that would read them
