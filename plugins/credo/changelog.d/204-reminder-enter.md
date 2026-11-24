---
bump: patch
---

### Fixed

- The periodic reminder no longer stays in the input field as `[Pasted text #n +x lines]` without
  being submitted: the check before Enter reads only the input box and what is drawn next to it, so
  an earlier numbered message or a quoted "Do you want to" line in the transcript above the box no
  longer holds back Enter. The worker waits up to 10 s for the burst to show, then presses Enter;
  while the field still shows exactly what it showed before the first Enter, Enter is re-sent up
  to 3 times with a growing wait, and text the owner typed or pasted meanwhile is never touched.
  A reminder that is still not submitted is removed from the field again (WARNING in the log), so
  it never blocks `/credo:self-compact`, `/credo:self-reload` or `/credo:self-restart`; one that
  may be left (a dialog, copy mode, not shown in time, not removable) is reported by ntfy
