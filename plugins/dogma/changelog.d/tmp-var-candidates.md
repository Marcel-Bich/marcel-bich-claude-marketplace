---
bump: patch
---

### Fixed

- A delete, overwrite or `sed -i` whose shell variables the command sets itself, with every value inside a temp root, is allowed like the literal temp path (no ask); covers `NAME=value`, `export`, `readonly`, `declare` and `for` word lists
- An assignment after `&&` no longer sets a variable for the delete checks: `false && S=/tmp/x; rm -f "$S/a"` is judged with `S` unset
- An assignment before a `for` loop or a group is read again, so `S=/tmp/x; for f in a b; do rm -f "$S/$f"; done` is no longer a hard deny
- The ask and deny texts of the delete setting name the `(§0lgy)` delete line of the permissions file
