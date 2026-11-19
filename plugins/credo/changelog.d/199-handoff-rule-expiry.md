---
bump: minor
---

### Added

- `credo-handoff-rules.py check <HANDOFF.md> [RULES.md]` flags handoff rule lines without a
  `source:` or `until:`, expired until-dates and rule-like lines outside the
  `## Rules (temporary)` section, and lists the RULES.md headings to compare against; the
  post-compact rehydrate note now carries the precedence and this check

### Changed

- Handoff rules are temporary and need a source and an expiry:
  `- <rule> | source: owner "<quote>" (<date>) | until: <goal, date or event>` or
  `| source: agent decision | until: ...`. Without an `until` a rule does not apply and the
  agent says so aloud; agent decisions only fill gaps and are never shown as owner orders
- Precedence is stated in the rules, compact-plus and session-autonomous skills: the owner's
  current words > owner rules in the handoff > `.credo/RULES.md` > agent-decision rules. The
  handoff is compared with RULES.md before an autonomous start and after a compact; conflicts
  are reported aloud (ntfy in autonomous runs) and RULES.md wins until the owner settles it
- The `[credo-reminder]` text no longer asks to carry every standing agreement into the
  handoff; it carries only rules with source and until, drops expired ones and sends permanent
  ones to RULES.md
