---
description: hydra - Live monitoring of background agents with status table
arguments:
  - name: interval
    description: Poll interval in seconds (default 5)
    required: false
allowed-tools:
  - Bash
  - Read
  - TaskOutput
  - TodoWrite
---

# Hydra Watch

You are executing the `/hydra:watch` command. Live monitoring of all background agents with real-time status updates.

## Purpose

Monitor multiple background agents running in parallel:
- Poll agent output files for current status
- Display live table with agent progress
- Detect blocked/completed/waiting states
- Offer actions: resume, check output, kill

## Process

### 1. Find Running Agents

Use the output file paths the tools reported. When a background agent or shell starts, its
tool result names the file its output is written to (for example "output_file: <path>" or
"Output is being written to: <path>"). Never build or guess that path (no hard-coded
`/tmp/claude/...`): the location differs per platform (a native Windows install writes
under the Windows temp dir) and per Claude Code version.

- Collect every reported `.output` path of this session.
- None reported in this conversation: say so ("No background agents started in this
  session") and stop; do not search the file system for other sessions' files.
- `TaskOutput` with the task id also works without any path.

```bash
# TASK_DIR = the directory of a reported output path (all agents of a session share it)
TASK_DIR="$(dirname "<reported output path>")"

# List all agent output files
ls -la "$TASK_DIR"/*.output 2>/dev/null || echo "No agents found"
```

### 2. Parse Agent Status

For each `.output` file, extract the current status:

```bash
for f in "$TASK_DIR"/*.output; do
  AGENT_ID=$(basename "$f" .output)

  # Get last meaningful lines (skip empty lines)
  LAST_ACTION=$(tail -50 "$f" | grep -v '^$' | tail -5)

  # Detect status
  if echo "$LAST_ACTION" | grep -qi "completed\|finished\|done"; then
    STATUS="completed"
  elif echo "$LAST_ACTION" | grep -qi "blocked\|denied\|permission"; then
    STATUS="blocked"
  elif echo "$LAST_ACTION" | grep -qi "waiting\|user input\|confirmation"; then
    STATUS="waiting"
  else
    STATUS="running"
  fi

  echo "$AGENT_ID|$STATUS|$LAST_ACTION"
done
```

### 3. Display Status Table

Format output as a clear table:

```
Hydra Watch - Live Agent Monitor
================================

  Agent   | Status    | Current Action
  --------|-----------|------------------------------------------
  a81dddd | running   | Optimizing Playwright config...
  abc3593 | running   | Running tests...
  adb39f1 | blocked   | git commit blocked by DOGMA-PERMISSIONS
  af848c1 | completed | All tasks finished
  ac49e7c | waiting   | Waiting for user confirmation

Last updated: 00:42:15 | Polling every 5s
```

### 4. Detect Problems

Check for common blockers:

```bash
# DOGMA-PERMISSIONS blocks
grep -l "DOGMA-PERMISSIONS\|git commit.*blocked\|git push.*blocked" "$TASK_DIR"/*.output 2>/dev/null

# Permission denied
grep -l "permission denied\|BLOCKED by" "$TASK_DIR"/*.output 2>/dev/null

# Waiting for input
grep -l "waiting for\|user input\|confirmation" "$TASK_DIR"/*.output 2>/dev/null
```

If blockers found, show summary:

```
WARNINGS DETECTED:

  Agent adb39f1: git commit blocked by DOGMA-PERMISSIONS
  Agent af848c1: pnpm install requires confirmation

Suggested actions:
  - Resume blocked agent: TaskOutput with resume
  - Check full output: Read <reported output path of {id}>
  - Adjust permissions: Edit DOGMA-PERMISSIONS.md
```

### 5. Offer Actions

After displaying status, offer options via AskUserQuestion:

```
What would you like to do?

Options:
- Continue watching (poll again)
- Resume agent [id] - Continue a blocked/waiting agent
- Check output [id] - Show full output of an agent
- Stop watching - Exit monitor
```

### 6. Continuous Mode

If user chooses "Continue watching":

```bash
sleep ${INTERVAL:-5}
# Then repeat from step 1
```

Note: Use a reasonable limit (e.g., 10 iterations) before asking again.

## Output Format

**Running agents:**
```
[running] a81dddd: Implementing feature X...
```

**Completed agents:**
```
[done] af848c1: Task completed successfully (2m 34s)
```

**Blocked agents:**
```
[BLOCKED] adb39f1: git commit denied - DOGMA-PERMISSIONS
  -> Action needed: Adjust permissions or resume with override
```

**Waiting agents:**
```
[waiting] ac49e7c: Waiting for user confirmation
  -> Action: Resume to continue
```

## Tips

- Use `TaskOutput` tool to get detailed agent results
- Use `Read` tool to view full output files
- Blocked agents can often be resumed after fixing the blocker
- Completed agents show their final summary in TaskOutput
