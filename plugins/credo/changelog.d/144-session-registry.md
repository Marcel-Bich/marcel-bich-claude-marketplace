---
bump: patch
---

### Added

- Session registry: the SessionStart and UserPromptSubmit hooks keep one file per session (`credo/session-registry/<session_id>.json`, active profile) with the session id, name, host, pid and start time, credo mode, and the tmux socket and pane when the process tree confirms them. Written only on change; SessionStart drops entries of gone processes older than a day. Disable with `CREDO_SESSION_REGISTRY=0`.
- `credo-session-registry.py list [--json] [--all-profiles]` and `resolve <session-id|name> [--json]`: every entry is re-checked against the live process (pid, start time, session descriptor, pane) before it is reported live; a stale entry reports the reason and exits 1, an unknown or ambiguous name exits 3.
