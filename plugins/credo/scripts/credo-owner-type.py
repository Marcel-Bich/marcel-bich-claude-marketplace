#!/usr/bin/env python3
"""credo-owner-type.py - type the owner's message, or an answer to an Ask box or a permission
prompt, into one of the owner's own Claude Code sessions (logic: credo_owner_type.py).

  credo-owner-type.py send --session <session-id|name> (--text T | --stdin)
                           [--force-append] [--dry-run] [--json] [--all-profiles]
      Types T into the session's input field and presses Enter. The input field must be
      empty (a busy session is fine: the text is queued by Claude Code). With
      --force-append the field may hold text: " " + T is appended, nothing is deleted.
      --stdin reads the text from stdin (one trailing newline is dropped).

  credo-owner-type.py answer --session <session-id|name> --ask SPEC
                             [--dry-run] [--json] [--all-profiles]
      Answers the Ask box or permission prompt that is open in the session. SPEC is one of:
        <digit>        select the option and send (Ask box), or the permission option
        <label>        an option label of an Ask box (case-insensitive; must be unique)
        esc            decline (Escape)
        free:<text>    free text through the Type something row, then send
        multi:<d,d>    multi select: the boxes of exactly these options, then review and submit
      Refused when no Ask box or permission prompt is open, or the open dialog is unknown.

Exit codes: 0 delivered, answered or dry-run; 1 refused or failed (nothing submitted, or
own text taken back); 2 usage (text or answer not valid); 3 unknown or ambiguous session;
4 sent but not confirmed (check the pane before sending again).

The session is looked up in the session registry (the active profile, else --all-profiles),
and only a live session whose pane still belongs to it is used. Every attempt is appended to
<profile>/credo/owner-type.log (time, session id, mode, character count, result). The text is
written there only with CREDO_OWNER_TYPE_LOG_TEXT=1.

Python 3 stdlib only.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import credo_owner_type as ot  # noqa: E402

STDIN_READ = ot.MAX_TEXT_CHARS + 2  # more than the limit, so an oversized text is refused


def build_parser():
    parser = argparse.ArgumentParser(prog="credo-owner-type.py",
                                     description="Type the owner's text or an Ask answer into a session pane.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("send", "answer"):
        p = sub.add_parser(name)
        p.add_argument("--session", required=True, help="session id or session name")
        p.add_argument("--dry-run", action="store_true", help="check everything, send nothing")
        p.add_argument("--json", action="store_true", help="machine-readable result")
        p.add_argument("--all-profiles", action="store_true",
                       help="look the session up in every profile (default: the active one)")
    send = sub.choices["send"]
    source = send.add_mutually_exclusive_group(required=True)
    source.add_argument("--text", help="the text to type")
    source.add_argument("--stdin", action="store_true", help="read the text from stdin")
    send.add_argument("--force-append", action="store_true",
                      help="append after text already in the input field (never deletes it)")
    sub.choices["answer"].add_argument("--ask", required=True, help="the answer, see the header")
    return parser


def text_from_args(args):
    """The text of a send, or None when stdin is not usable."""
    if args.stdin:
        raw = sys.stdin.read(STDIN_READ)
    else:
        raw = args.text
    if raw is not None and raw.endswith("\n"):
        raw = raw[:-1]
    return raw


def run(args):
    if args.cmd == "send":
        text = text_from_args(args)
        return ot.send(args.session, text, force=args.force_append, dry_run=args.dry_run,
                       all_profiles=args.all_profiles)
    return ot.answer(args.session, args.ask, dry_run=args.dry_run, all_profiles=args.all_profiles)


def show(result, as_json):
    if as_json:
        print(json.dumps(result, sort_keys=True))
        return
    print("%s: %s" % (result["status"], result["reason"]))


def main(argv=None):
    args = build_parser().parse_args(argv)
    result = run(args)
    show(result, args.json)
    return result["exit"]


if __name__ == "__main__":
    sys.exit(main())
