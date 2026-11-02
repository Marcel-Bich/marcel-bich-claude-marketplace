#!/usr/bin/env python3
"""credo-owner-type.py - type the owner's message, or an answer to an Ask box or a permission
prompt, into one of the owner's own Claude Code sessions (logic: credo_owner_type.py).

  credo-owner-type.py show --session <session-id|name> [--json] [--all-profiles]
      Prints the prompt that is open in the session: the whole dialog block verbatim (every
      row from the box top rule to the footer: the command, description rows, every question
      row, review answer rows), the cursor, and the digest (sha256 over those rows, whitespace
      normalized; the cursor is not part of it). Read only; nothing is typed.

  credo-owner-type.py send --session <session-id|name> (--text T | --stdin)
                           [--force-append] [--dry-run] [--json] [--all-profiles]
      Pastes T into the session's input field (one bracketed paste, line breaks kept) and presses
      Enter. The input field must be empty; with --force-append it may hold text, and " " + T is
      appended at its end (the existing text is sent with it and never changed by this tool). A busy
      session is fine: Claude Code queues the text. --expect is accepted and not checked. --stdin
      reads the text from stdin (one trailing newline is dropped).

  credo-owner-type.py answer --session <session-id|name> --ask SPEC [--expect DIGEST]
                             [--persist] [--dry-run] [--json] [--all-profiles]
      Answers the Ask box or permission prompt that is open in the session. SPEC is one of:
        <digit>        select the option and send (Ask box), or the permission option
        <label>        an option label of an Ask box (case-insensitive; must be unique)
        esc            decline (Escape)
        free:<text>    free text through the Type something row, then send
        multi:<d,d>    multi select: the boxes of exactly these options, then review and submit
      --expect DIGEST is required for every answer (permission prompt, Ask box, review page,
      dry runs included): the open prompt must have this digest (read it with show), and it is
      read again before every key. --persist confirms a permission option whose label is not
      exactly Yes or No (for example "don't ask again"); without it such an option is refused.
      Refused when no Ask box or permission prompt is open, or the open dialog is unknown.

Exit codes: 0 delivered, answered, shown or dry-run; 1 refused or failed (nothing submitted,
or own text taken back, or left and reported); 2 usage (text or answer not valid); 3 unknown
or ambiguous session; 4 sent but not confirmed (check the pane before sending again: the text
may already be submitted).

The session is looked up in the session registry (the active profile, else --all-profiles),
and only a live session whose pane still belongs to it is used. Every attempt is appended to
<profile>/credo/owner-type.log (time, session id, mode, character count, result, option label).
The text is written there only with CREDO_OWNER_TYPE_LOG_TEXT=1.

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
    show = sub.add_parser("show", help="print the open prompt and its digest (read only)")
    show.add_argument("--session", required=True, help="session id or session name")
    show.add_argument("--json", action="store_true", help="machine-readable result")
    show.add_argument("--all-profiles", action="store_true",
                      help="look the session up in every profile (default: the active one)")
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
    send.add_argument("--expect", metavar="DIGEST", help="accepted and not checked")
    answer = sub.choices["answer"]
    answer.add_argument("--ask", required=True, help="the answer, see the header")
    answer.add_argument("--expect", metavar="DIGEST",
                        help="the digest of the prompt that was read with show (required for "
                             "every answer)")
    answer.add_argument("--persist", action="store_true",
                        help="confirm a permission option whose label is not exactly Yes or No")
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
    if args.cmd == "show":
        return ot.show(args.session, all_profiles=args.all_profiles)
    if args.cmd == "send":
        text = text_from_args(args)
        return ot.send(args.session, text, force=args.force_append, dry_run=args.dry_run,
                       all_profiles=args.all_profiles, expect=args.expect)
    return ot.answer(args.session, args.ask, dry_run=args.dry_run, all_profiles=args.all_profiles,
                     expect=args.expect, persist=args.persist)


def format_show(result):
    """The text form of a show result: the status, the digest, the dialog block verbatim (every
    row the owner is asked about), then the highlight and the --persist notes."""
    lines = ["%s: %s" % (result["status"], result["reason"]),
             "session: %s" % result.get("session"), "kind: %s" % result.get("kind")]
    if result.get("digest"):
        lines.append("digest: %s" % result["digest"])
    if result.get("block"):
        # every row is prefixed, so no row of the agent text can look like the end marker
        lines.append("--- prompt, as the box shows it (top rule to footer) ---")
        lines += ["| " + row for row in result["block"]]
        lines.append("--- end of prompt ---")
    if result.get("cursor") is not None:
        lines.append("cursor: %s" % result["cursor"])
    for opt in (result.get("options", []) if result.get("kind") == "permission" else []):
        if opt.get("persist"):
            lines.append("note: option %d needs --persist (only Yes or No run without it)" % opt["n"])
    return "\n".join(lines)


def main(argv=None):
    args = build_parser().parse_args(argv)
    result = run(args)
    if args.cmd == "show" and not args.json:
        if result["exit"] == 0:
            print(format_show(result))
        else:
            print("%s: %s" % (result["status"], result["reason"]))
        return result["exit"]
    if args.json:
        print(json.dumps(result, sort_keys=True, ensure_ascii=False))
    else:
        print("%s: %s" % (result["status"], result["reason"]))
    return result["exit"]


if __name__ == "__main__":
    sys.exit(main())
