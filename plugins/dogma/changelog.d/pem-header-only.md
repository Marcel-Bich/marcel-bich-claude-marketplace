---
bump: patch
---

### Fixed

- A lone PEM private-key header line (in docs, grep patterns, commit text, prose) is no longer denied by the Read guard and the Bash command scan; a key block (header followed by base64 body, on the same line or on the next line after PEM header fields and a blank line) is still denied
