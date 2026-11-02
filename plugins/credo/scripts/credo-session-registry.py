#!/usr/bin/env python3
"""credo-session-registry.py - CLI of the session registry (logic: credo_session_registry.py).

  credo-session-registry.py record
      hook mode: the hook JSON on stdin; writes or refreshes this session's entry, prints
      nothing, always exits 0 (SessionStart and UserPromptSubmit, see hooks/)
  credo-session-registry.py list [--json] [--all-profiles]
  credo-session-registry.py resolve <session-id|name> [--json] [--all-profiles]

Exit codes: list 0; resolve 0 live, 1 stale, 3 not-found or ambiguous (2 for usage errors).
Without --all-profiles only the active profile is read (CLAUDE_CONFIG_DIR, else ~/.claude);
--all-profiles reads every profile peer-check knows. Only record writes; list and resolve are
read-only. Every row is verified against the live process tree before it is shown as live.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import credo_peer_meta as peer_meta  # noqa: E402
import credo_session_registry as registry  # noqa: E402

MAX_HOOK_BYTES = 65536
EXIT_STALE = 1
EXIT_MISSING = 3


def cmd_record():
    try:
        data = json.loads(sys.stdin.read(MAX_HOOK_BYTES))
    except (OSError, ValueError):
        return 0
    if not isinstance(data, dict) or data.get("agent_id"):
        return 0
    sid = data.get("session_id")
    if not peer_meta.valid_sid(sid):
        return 0
    try:
        profile = registry.profile_dir()
        registry.record_session(profile, sid, registry.process_chain())
        if data.get("hook_event_name") == "SessionStart":
            registry.prune(profile)
    except Exception:  # a hook never disrupts a session
        return 0
    return 0


def table_lines(rows, all_profiles):
    head = ["STATUS", "NAME", "SESSION", "PID", "PANE", "MODE", "UPDATED"]
    if all_profiles:
        head.append("PROFILE")
    body = []
    for row in rows:
        tmux = row.get("tmux") or {}
        cells = [row.get("status", "-"), row.get("name") or "-", row.get("session_id", "-"),
                 row.get("pid", "-"), tmux.get("pane") or "-", row.get("mode") or "-",
                 row.get("updated") or "-"]
        if all_profiles:
            cells.append(row.get("profile", "-"))
        body.append([str(c) for c in cells])
    widths = [max(len(line[i]) for line in [head] + body) for i in range(len(head))]
    return ["  ".join(c.ljust(widths[i]) for i, c in enumerate(line)).rstrip()
            for line in [head] + body]


def cmd_list(args):
    rows = registry.list_rows(registry.profiles_to_read(args.all_profiles))
    if args.json:
        print(json.dumps({"entries": rows}, indent=2, sort_keys=True))
    else:
        for line in table_lines(rows, args.all_profiles):
            print(line)
    return 0


def cmd_resolve(args):
    result = registry.resolve(registry.profiles_to_read(args.all_profiles), args.query)
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print("%s: %s" % (result["status"], result["reason"]))
        entry = result["entry"]
        if entry:
            tmux = entry.get("tmux") or {}
            pane = tmux.get("pane") or "-"
            print("session %s  name %s  pid %s  pane %s" % (
                entry["session_id"], entry.get("name") or "-", entry.get("pid"), pane))
        for cand in result["candidates"]:
            print("candidate %s  name %s  status %s  profile %s" % (
                cand["session_id"], cand.get("name") or "-", cand.get("status", "-"), cand["profile"]))
    if result["status"] == "live":
        return 0
    if result["status"] == "stale":
        return EXIT_STALE
    return EXIT_MISSING


def build_parser():
    parser = argparse.ArgumentParser(prog="credo-session-registry.py",
                                     description="Session registry: which tmux pane belongs to which session.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("record", help="hook mode: record this session from the hook JSON on stdin")
    for name, help_text in (("list", "list every entry with its verified status"),
                            ("resolve", "verify one entry by session id or name")):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("--json", action="store_true", help="machine-readable output")
        p.add_argument("--all-profiles", action="store_true",
                       help="read every profile under ~/.claude* (default: the active profile)")
        if name == "resolve":
            p.add_argument("query", help="session id or session name")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.cmd == "record":
        return cmd_record()
    if args.cmd == "list":
        return cmd_list(args)
    return cmd_resolve(args)


if __name__ == "__main__":
    sys.exit(main())
