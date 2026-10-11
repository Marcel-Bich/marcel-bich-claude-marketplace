---
bump: minor
---

### Added

- Model presets `quality`, `balanced` (default) and `budget` in `templates/presets.default.yaml`, selected with `preset: <name>` in the global or project config (project overrides global). Custom presets go under `presets:` with the same schema and may use any model; a same-named custom preset replaces the built-in one as a whole
- Each role (`explore`, `build`, `review`, `hard`) is one stage `{model, effort, attempts, subagent-prompt}` or a chain of stages that may end with `back-to-human`; `attempts` is a positive number or `until-done` (no attempt cap, budget caps and a repeated failure without progress stop it)
- `scripts/credo-preset.sh` resolves the active preset: `stage <role> [attempt]` prints the model, the Agent-tool alias, the effort, the prompt block and the next action (retry, next-stage or back-to-human); `mainagent`, `show [name]`, `list` and `active` cover the rest. Invalid parts print a warning and fall back to balanced for that role; missing prompt keys add nothing
- Prompts: `universal-prompt` for every agent, `mainagent-prompt` for the main agent (delivered by the SessionStart hook of an active session, also after a compaction; `/credo:session-active` and `/credo:session-init` print it once for a mid-session start) and a per-stage `subagent-prompt` that the main agent appends when it spawns a subagent, because the SubagentStart hook carries neither the role nor the prompt. A builder that may decide agent-owned questions also gets the `mainagent-prompt` in its brief
- Back-to-human: the item moves to `1_clarify` with a `> URGENT:` note and an ntfy push; an autonomous run continues with other items, an attended session asks the user
- `/credo:setup` Step 2d presents the built-in presets and lets the user pick one or describe a custom one (written into the chosen config and verified with `credo-preset.sh show`); `/credo:session-init` hints, read-only, when the main model differs from the preset recommendation
- `credo-config.sh`: the built-in presets as a builtin layer, flow-map syntax (`{key: value}`) in the stdlib YAML parser, and `CREDO_CONFIG_STDLIB_YAML=1` to force that parser
- `credo-item-move.sh` accepts the neutral agent decision marker `(GO: agent decision, <reason>)`; the older `(GO: agent per SOTA rule, <reason>)` stays accepted
- Tests: `test-credo-preset.sh` (helper, validation, config layering, SessionStart injection, doc invariants); `test-item-move.sh` covers both GO markers

### Changed

- The orchestration skill's model policy ("no downgrade, no model-choice logic") is replaced by the preset rules: the main agent picks model and effort per role from the active preset, follows the chains, and hands the item back when a chain is used up
- The agent decision philosophy (SOTA, else best effort, else note it) moved out of the items, orchestration, session-active, session-autonomous, role-plan and migrate skills and the credo guide into the preset's `mainagent-prompt`. The skills keep the fixed rules: who decides (human-owned or agent-owned), the GO line requirement, and the safety calls (user taste, deleting user data, installs, money, changes to the verbatim requirement)
- Worktrees for every code track, also a single isolated build track and not only parallel ones: `credo-worktree-flow.sh` runs before any worktree run. Under hydra the Agent tool's `isolation: "worktree"` is never used, and a bare `git worktree add` without the setup script is never run; always hydra's create flow plus its setup
