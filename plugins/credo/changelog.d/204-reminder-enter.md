---
bump: patch
---

### Fixed

- The periodic reminder no longer stays in the input field as `[Pasted text #n +x lines]` without
  being submitted: the check before Enter reads only the input box and what is drawn next to it, so
  an earlier numbered message or a quoted "Do you want to" line in the transcript above the box no
  longer holds back Enter. After Enter the field is checked; while the own burst is still there,
  Enter is re-sent up to 3 times with a growing wait. A reminder that is still not submitted is
  removed from the field again (WARNING in the log), so it never blocks `/credo:self-compact`,
  `/credo:self-reload` or `/credo:self-restart`; one that cannot be removed safely (a dialog, other
  text) is reported by ntfy
