---
bump: patch
---

### Fixed

- An owner decision already logged in the requirements log or the item History is no longer raised again as a
  new owner question. One central rule "Never re-ask a decided point" in the items skill, referenced from the
  verify typed codes (no Q code for a decided point), session-active, session-passive, session-autonomous, the
  orchestration owner-question and return-and-resume paths and the subagent DECISIONS inject
- The audit skill checks the requirements log for the audited area; a finding that is exactly an owner-accepted point goes
  into an own "Accepted (owner)" report section as `accepted (owner <date>, "<quote>")`, never as BLOCKER or
  MAJOR and never as a new owner question; only the owner's own words count, for exactly the decided point with
  unchanged facts; the orchestration audit brief points the auditor to the log
- The periodic reminder re-checks every open Q code against the requirements log and closes what the owner
  already decided
