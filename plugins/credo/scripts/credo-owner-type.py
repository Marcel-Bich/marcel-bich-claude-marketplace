#!/usr/bin/env python3
"""credo-owner-type.py - type the owner's message, or an answer to an Ask box or a permission
prompt, into one of the owner's own Claude Code sessions (logic: credo_owner_type.py).

  credo-owner-type.py show --session <session-id|name> [--json] [--all-profiles]
      Prints the prompt that is open in the session (kind, question, the command text of a
      permission prompt, options, cursor) and its digest (sha256 of the normalized prompt).
      Read only; nothing is typed.

  credo-owner-type.py send --session <session-id|name> (--text T | --stdin)
                           [--force-append] [--dry-run] [--json] [--all-profiles]
      Types T into the session's input field and presses Enter. The input field must be
      empty (a busy session is fine: the text is queued by Claude Code). With
      --force-append the field may hold text: " " + T is appended; the existing text is sent
      with it and never deleted by this tool. --stdin reads the text from stdin (one trailing
      newline is dropped).

  credo-owner-type.py answer --session <session-id|name> --ask SPEC [--expect DIGEST]
                             [--persist] [--dry-run] [--json] [--all-profiles]
      Answers the Ask box or permission prompt that is open in the session. SPEC is one of:
        <digit>        select the option and send (Ask box), or the permission option
        <label>        an option label of an Ask box (case-insensitive; must be unique)
        esc            decline (Escape)
        free:<text>    free text through the Type something row, then send
        multi:<d,d>    multi select: the boxes of exactly these options, then review and submit
      --expect DIGEST is required for a permission prompt and honoured for an Ask box: the
      prompt must still have this digest (read it with show) right before the key is sent.
      --persist confirms an option that keeps the approval for later prompts ("don't ask
      again" and similar); without it such an option is refused.
      Refused when no Ask box or permission prompt is open, or the open dialog is unknown.

Exit codes: 0 delivered, answered, shown or dry-run; 1 refused or failed (nothing submitted,
or own text taken back, or left and reported); 2 usage (text or answer not valid); 3 unknown
or ambiguous session; 4 sent but not confirmed, or partly sent (check the pane before sending
again: the text may already be submitted).

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
    answer = sub.choices["answer"]
    answer.add_argument("--ask", required=True, help="the answer, see the header")
    answer.add_argument("--expect", metavar="DIGEST",
                        help="the digest of the prompt that was read with show (required for "
                             "permission prompts)")
    answer.add_argument("--persist", action="store_true",
                        help="confirm an option that keeps the approval for later prompts")
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
                       all_profiles=args.all_profiles)
    return ot.answer(args.session, args.ask, dry_run=args.dry_run, all_profiles=args.all_profiles,
                     expect=args.expect, persist=args.persist)


def format_show(result):
    """The text form of a show result: the prompt as the owner reads it, then the digest."""
    lines = ["%s: %s" % (result["status"], result["reason"]),
             "session: %s" % result.get("session"), "kind: %s" % result.get("kind")]
    if result.get("digest"):
        lines.append("digest: %s" % result["digest"])
    if result.get("kind") == "permission":
        lines.append("title: %s" % result.get("title", ""))
        if result.get("body"):
            lines.append("body:")
            lines += ["  %s" % row for row in result["body"]]
        lines.append("question: %s" % result.get("question", ""))
        for opt in result.get("options", []):
            note = "  (keeps approval: needs --persist)" if opt.get("persist") else ""
            lines.append("  %d. %s%s" % (opt["n"], opt["label"], note))
    elif result.get("kind") == "ask":
        lines.append("question: %s" % result.get("question", ""))
        for opt in result.get("options", []):
            box = "" if opt.get("checked") is None else ("[x] " if opt["checked"] else "[ ] ")
            lines.append("  %d. %s%s - %s" % (opt["n"], box, opt["label"], opt.get("desc", "")))
        lines.append("  %d. Type something" % (result.get("type_n") or 0))
    elif result.get("kind") == "review":
        for ans in result.get("answers", []):
            lines.append("answer: %s -> %s" % (ans["question"], ", ".join(ans["labels"])))
        lines += ["  %d. %s" % (i + 1, label) for i, label in enumerate(result.get("options", []))]
    if result.get("cursor") is not None:
        lines.append("cursor: %s" % result["cursor"])
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
