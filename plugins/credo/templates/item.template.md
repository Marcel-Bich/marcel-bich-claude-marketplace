---
id: 0
title: Short imperative title
created: YYYY-MM-DD
type: feature
ui: false
---

<!--
credo work-item template. Copy to .credo/items/1_todo/1_clarify/<id>-<slug>.md
Get <id> from: "${CLAUDE_PLUGIN_ROOT}/scripts/credo-id-next.sh" (never derive it from folders).
Frontmatter is lean and mandatory: id, title, created, type, ui.
  type: bug | optimization | feature | question | chore
  ui:   true means a visual verify (credo verify skill) is a DoD requirement.
Do NOT add a status field - the FOLDER the file lives in is the only status truth.
Add priority / source / blocked_by / relates_to / regression only if they apply, free-form below.
Keep the section headings; fill them in as the item progresses.
-->

## Requirement (verbatim)

> Quote the requirement in the user's exact words here. Never trim, soften, or reinterpret.
> Source: <where this came from, e.g. chat 2026-07-04 / issue #12 / requirements log entry>

(Assistant proposals, if any, go here clearly labeled as a proposal - kept separate from the verbatim text above.)

## Success Criteria (= DoD)

Observable, checkable "the user can X" statements. These are the Definition of Done.

- [ ] The user can ...
- [ ] The user can ...

## Implemented

What was actually built, with concrete file:line references (including the wiring - which
caller reaches the new code).

- (not started)

## Verify

Honest 3-valued state per layer: present | wired-but-behavior-unverified | exercised.

- backend: present
- ui: present            # only relevant if ui: true; drive via the credo verify skill
- human-only: n/a        # if used, add why_human: <what the user must confirm and why>

## History

- created (clarify) YYYY-MM-DD

<!--
================================================================================
FILLED EXAMPLE (reference only - delete this comment block in real items):

---
id: 124
title: Live-reload the status panel without a full page refresh
created: 2026-07-04
type: feature
ui: true
---

## Requirement (verbatim)

> "the panel should update by itself when a job finishes, i dont want to hit F5 every time"
> Source: chat 2026-07-04, the user.

Proposal (assistant): push updates over the existing websocket and patch the DOM in place.

## Success Criteria (= DoD)

- [x] The user can watch a job finish and see the panel row update without reloading.
- [x] The user can have the panel open for >10 min and updates keep arriving.

## Implemented

- panel/ws_client.js:42 - subscribe to the "job_done" event on the existing socket.
- panel/render.js:88 - patch the affected row in place (called from ws_client.js:57).
- server/emit.py:120 - emit "job_done" after a job transitions to done (wired into the job runner).

## Verify

- backend: exercised - triggered a real job, observed "job_done" emitted (server log 2026-07-05).
- ui: exercised - credo verify skill, viewports 320/768/1440, row updated in place with no reload;
  screenshots live-reload-panel-{320,768,1440}-2026-07-05.png under .credo/screenshots/.
- human-only: n/a

## History

- created (clarify) 2026-07-04
- go 2026-07-04 (the user gave explicit GO)
- done 2026-07-05 (DoD met; audit passed by a dedicated subagent, not the builder; docs + version bumped)
================================================================================
-->
