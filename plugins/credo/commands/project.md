---
description: credo - Pin the target repo for credo's project layer (hub-aware), or show the resolved target
arguments:
  - name: path
    description: Absolute path of the repo to target with credo (omit to show the current target)
    required: false
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/hooks/session-project-set.sh:*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh:*)
  - AskUserQuestion
---

# Credo Project Target

credo has two layers. The AUTONOMY layer (keep-alive flags) is global to your user
and is never changed here. This command only sets the PROJECT layer: which repo's
`.credo/`, config, and items credo operates on.

Why this exists: when your shell cwd is a launch hub (a directory you start other
repos from) rather than the repo you are actually working on, credo would otherwise
resolve its project layer to the wrong place. Pin the real target instead.

## With an argument (set the pin)

The user gave a path in `$ARGUMENTS`.

1. Pin it for this session:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/hooks/session-project-set.sh" "$ARGUMENTS"
   ```
   The script validates that the path is an existing directory and keys the pin by
   the current session_id. If it errors (path missing, no session_id), report the
   message verbatim and stop - do not guess a path.
2. Confirm the resolved target:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" resolve-project
   ```
3. Confirm briefly: credo now targets `<resolved .credo dir>` for this session.

## Without an argument (show the current target)

1. Resolve the current target and capture the exit code:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" resolve-project; echo "rc=$?"
   ```
2. Check whether the cwd is a hub:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" is-hub
   ```
3. Report:
   - exit 0: credo targets the printed `.credo` directory.
   - exit 4: no target resolved - the cwd is a hub (`is-hub` = true) or has no
     credo project yet. Tell the user to pin a repo with `/credo:project <path>`
     or set `CREDO_DIR`, then retry whatever needed the target.
