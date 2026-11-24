---
bump: patch
---

### Fixed

- Bash network redirections to `/dev/tcp/<host>/<port>` and `/dev/udp/<host>/<port>` (`exec 3<>/dev/tcp/127.0.0.1/8080`, `echo x > /dev/udp/127.0.0.1/514`, also inside `bash -c '...'`) are no longer denied as "overwriting a critical path": they open a socket, no file. Only the literal two-part form counts; real devices (`/dev/sda`, `/dev/mem`) and dotdot forms stay denied
- `sh -c 'echo x >/tmp/x.log'` (a redirect word right before the closing quote) is no longer denied by delete-guard as "unparseable quoting in a destructive command"
