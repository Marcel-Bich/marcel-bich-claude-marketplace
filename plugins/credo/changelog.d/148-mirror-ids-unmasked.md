---
bump: patch
---

### Fixed

- Remote mirror hooks: identifier fields (`type`, `session_id`, `ts`, `tool_use_id`, `chat_id`, `agent_type`, `agent_id`) are no longer masked. The secret masking turned every session id into `***`, so a sink could not tell which session an event came from. Content fields are still masked as before.
