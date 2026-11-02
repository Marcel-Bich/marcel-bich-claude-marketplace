---
bump: patch
---

### Fixed

- The periodic reminder is typed as one burst, settles for 0.5 s and is then submitted. It no longer types in pieces and compares the field with the exact text, so a reminder could stay in the input field when the field was scrolled or too tall for the box check. A paste placeholder ("[Pasted text #1]") counts as typed.
- A field that holds text when the reminder is due is skipped at once and left as it is, instead of waiting for it to clear.
- A dialog that covers the input box after the burst stops the reminder before Enter.
