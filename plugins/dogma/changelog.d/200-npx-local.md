---
bump: patch
---

### Fixed

- `npx <tool>` for a locally installed tool is no longer denied as download-and-run after a `cd` into a sub-package (`cd web && npx vite build`): the local `node_modules/.bin/<tool>` is looked up from every folder the command runs in

### Security

- `npx -p/--package`, `-y/--yes` and `-c/--call` no longer pass as a local tool run: they can download a package or run a shell string, so they keep the download-and-run check
