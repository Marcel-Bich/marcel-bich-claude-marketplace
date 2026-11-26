---
bump: patch
---

### Fixed

- A typed code (T, Q, V) written by hand into a reply no longer gets issued again: after each reply a Stop hook raises the project's counter to the highest code heading the agent showed
  (`credo-code-next.sh reconcile`, same heading rule and lock as the counter) and notes the slip to the agent; a code shown again with a different topic is noted once per session
