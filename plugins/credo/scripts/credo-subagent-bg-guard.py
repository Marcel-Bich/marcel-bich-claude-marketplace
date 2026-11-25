#!/usr/bin/env python3
"""credo-subagent-bg-guard.py - SubagentStop hook: no finish with own background work alive (#215).

A subagent may run background work (run_in_background Bash, Monitor, background Agent) to
work in parallel, but it must stop everything it started before it finishes. Background
work left running wakes the finished agent each time it ends, and every wake reaches the
main agent as another task-notification.

The hook reads the subagent's own transcript (agent_transcript_path from the hook input,
else <session transcript dir>/<session id>/subagents/agent-<agent_id>.jsonl) and collects:
  started  the task ids from tool results: Bash "backgroundTaskId" (run_in_background and
           commands moved to the background after their timeout), Monitor "taskId",
           Agent "agentId" with status "async_launched";
  ended    a <task-notification> for that id with status completed, failed, killed or
           stopped (the harness writes it into the subagent transcript), a TaskStop
           (task_id) or KillShell (shell_id) call for that id, or a non-persistent Monitor
           whose timeoutMs has passed.
Started and not ended = still alive. Then the finish is blocked once with a reason that
lists them (id + short command) and "stop these first, then finish". At most 2 blocks per
subagent (state file <config>/credo/subagent-bg/<session_id>/<agent_id>); the next stop is
let through with a line in <config>/credo/logs/subagent-bg-guard.log.

Fail open: a missing transcript, a parse error or any other problem lets the stop through
without output. Off with CREDO_SUBAGENT_BG_GUARD=0. Hooks start it through hooks/credo-py.sh.
"""
import datetime
import json
import os
import re
import sys

MAX_BLOCKS = 2
ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
SID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
BLOCK_RE = re.compile(r"<task-notification>(.*?)</task-notification>", re.S)
TID_RE = re.compile(r"<task-id>([A-Za-z0-9_-]{1,64})</task-id>")
STATUS_RE = re.compile(r"<status>(completed|failed|killed|stopped)</status>")
END_STATUSES = ("completed", "failed", "killed", "stopped")


def config_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")


def log(line):
    path = os.environ.get("CREDO_SUBAGENT_BG_GUARD_LOG") or os.path.join(
        config_dir(), "credo", "logs", "subagent-bg-guard.log")
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        stamp = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (stamp, line))
    except OSError:
        pass


def transcript_path(data, agent_id):
    path = data.get("agent_transcript_path")
    if isinstance(path, str) and path and os.path.isfile(path):
        return path
    main = data.get("transcript_path")
    if not isinstance(main, str) or not main.endswith(".jsonl"):
        return None
    path = os.path.join(main[:-len(".jsonl")], "subagents", "agent-%s.jsonl" % agent_id)
    return path if os.path.isfile(path) else None


def parse_ts(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def short(text, limit=80):
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[:limit - 3] + "..."


def end_ids_in(text):
    ids = set()
    for block in BLOCK_RE.findall(text):
        tid = TID_RE.search(block)
        if tid and STATUS_RE.search(block):
            ids.add(tid.group(1))
    return ids


def scan(path, now):
    """Return {task_id: label} of background tasks started and not ended."""
    uses = {}
    started = {}
    ended = set()
    monitors = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(entry, dict):
                continue
            if "<task-notification>" in raw:
                # decoded strings anywhere in the entry (message content, queued_command
                # attachments) carry the notification text
                ended |= end_ids_in(json.dumps(entry, ensure_ascii=False).replace("\\n", "\n"))
            message = entry.get("message")
            content = message.get("content") if isinstance(message, dict) else None
            if not isinstance(content, list):
                continue
            for item in content:
                if not isinstance(item, dict):
                    continue
                if item.get("type") == "tool_use":
                    name = item.get("name")
                    args = item.get("input") if isinstance(item.get("input"), dict) else {}
                    uses[item.get("id")] = (name, args)
                    if name in ("TaskStop", "KillShell"):
                        for key in ("task_id", "shell_id"):
                            if isinstance(args.get(key), str):
                                ended.add(args[key])
                elif item.get("type") == "tool_result":
                    use = uses.get(item.get("tool_use_id"))
                    result = entry.get("toolUseResult")
                    if not use or not isinstance(result, dict):
                        continue
                    name, args = use
                    tid, label = None, None
                    if name == "Bash" and result.get("backgroundTaskId"):
                        tid = result.get("backgroundTaskId")
                        label = "Bash: " + short(args.get("description") or args.get("command"))
                    elif name == "Monitor" and result.get("taskId"):
                        tid = result.get("taskId")
                        label = "Monitor: " + short(args.get("description") or args.get("command"))
                        if not result.get("persistent"):
                            start = parse_ts(entry.get("timestamp"))
                            timeout = result.get("timeoutMs")
                            if start is not None and isinstance(timeout, (int, float)):
                                monitors[tid] = start + timeout / 1000.0
                    elif name in ("Agent", "Task") and result.get("status") == "async_launched" \
                            and result.get("agentId"):
                        tid = result.get("agentId")
                        label = "Agent: " + short(args.get("description"))
                    if isinstance(tid, str) and ID_RE.match(tid):
                        started[tid] = label
    for tid, deadline in monitors.items():
        if deadline < now:
            ended.add(tid)
    return {tid: label for tid, label in started.items() if tid not in ended}


def main():
    if os.environ.get("CREDO_SUBAGENT_BG_GUARD", "1").lower() in ("0", "false", "no", "off"):
        return
    data = json.loads(sys.stdin.read() or "{}")
    if not isinstance(data, dict):
        return
    agent_id = data.get("agent_id")
    session_id = data.get("session_id")
    if not isinstance(agent_id, str) or not ID_RE.match(agent_id):
        return
    if not isinstance(session_id, str) or not SID_RE.match(session_id) or session_id in (".", ".."):
        return
    path = transcript_path(data, agent_id)
    if not path:
        return
    alive = scan(path, datetime.datetime.now().timestamp())
    if not alive:
        return
    state_dir = os.path.join(config_dir(), "credo", "subagent-bg", session_id)
    state = os.path.join(state_dir, agent_id)
    count = 0
    try:
        with open(state, encoding="utf-8") as fh:
            count = int(fh.read().strip() or "0")
    except (OSError, ValueError):
        count = 0
    listing = "; ".join("%s (%s)" % (tid, label) for tid, label in sorted(alive.items()))
    if count >= MAX_BLOCKS:
        log("fail open: agent %s (session %s) finished after %d blocks with background "
            "tasks still running: %s" % (agent_id, session_id, count, listing))
        return
    os.makedirs(state_dir, exist_ok=True)
    with open(state, "w", encoding="utf-8") as fh:
        fh.write("%d\n" % (count + 1))
    reason = ("credo: you still have background tasks you started running: %s. Stop these "
              "first (TaskStop with the task id; kill a process you started yourself), then "
              "finish with your report. Never finish with own background work alive - every "
              "task that ends later wakes you again and floods the main agent. (Check %d of "
              "%d; a task that already ended is fine to stop again.)"
              % (listing, count + 1, MAX_BLOCKS))
    print(json.dumps({"decision": "block", "reason": reason}))


if __name__ == "__main__":
    try:
        main()
    except Exception:  # fail open on anything unexpected
        pass
    sys.exit(0)
