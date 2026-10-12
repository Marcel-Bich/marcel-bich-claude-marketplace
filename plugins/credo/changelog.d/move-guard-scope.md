---
bump: patch
---

### Fixed

- The item move guard blocks a raw move only when an item file of the status tree is its source or destination. Moves of other `.credo/` files, such as the requirements log, pass even when the shell stands inside the item tree.
- A raw move of an item file chained after a `credo-item-move.sh` call in the same command is now blocked; before, the helper call exempted the whole command.
