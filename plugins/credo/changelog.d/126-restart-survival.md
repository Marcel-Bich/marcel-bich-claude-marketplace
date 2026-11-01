---
bump: patch
---

### Added

- Restart survival helper `scripts/credo_runtime.py` (stdlib only). `keep` copies the session scratchpad (helper scripts, collection files, pending lists) into `.credo/process/runtime/<session>/` together with a manifest. It copies only and never deletes.
- compact-plus and `/credo:self-restart` (`run`, new `--scratchpad DIR` option) snapshot the scratchpad before a restart or compact. The SessionStart check names the snapshot once after the restart.
- Restart list of background services (`credo_runtime.py service add`, `start`, `status`). Each service runs in one detached tmux session `credo-svc-<name>` when tmux is used, else under `systemd-run --user` when systemd is booted, else under nohup. Each service has a durable script under `.credo/process/runtime/services/`.
- tmux pane references by name, written as `session:window.pane (purpose, last %ID)` and resolved before use (`credo_runtime.py pane add`, `resolve`, `status`). SSH panes are flagged.
- SessionStart post-restart check on startup and resume only. It reports services that are not running, SSH panes the user must reconnect (tmux only), and the scratchpad pointer.
- compact-plus handoff rules resolve plugin script paths by glob (`sort -V`), never by a pinned plugin version.
