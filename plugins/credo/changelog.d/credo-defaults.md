---
bump: minor
---

### Added

- Items: optional `## Freigaben` section (approvals) lists the downloads and installs a GO covers; nothing outside the list is approved, and the security check still applies to listed entries
- Items: optional `polish: true` for pure polish (wording, layout, small behavior details): one build, one light audit, fixes once best effort, then done; leftovers go to `## Verify`
- Items: optional `disk_gb` (free disk in GB a running item needs); the start waits until the free space covers it plus the reserve
- `credo-resource-check.sh` gains `--disk-gb` and `--path`, checks free disk at every start, and reads the reserve from `resources.disk_reserve_gb` (default 3 GB)

### Changed

- The task role pulls GO items from `1_todo/2_go` itself; the plan role never hands out batches and reports at most "new GO items are ready"
- Owner-owned clarify items (`clarify_owner: human` or missing) are clarified only with the owner in every mode; agent-owned clarify items are decided by the agent only in autonomous runs, interactive modes ask the user; build-time details of a GO item stay with the agent
