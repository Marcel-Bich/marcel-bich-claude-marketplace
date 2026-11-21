---
bump: minor
---

### Added

- Optional local ntfy relay `personal.ntfy_relay` (e.g. `http://127.0.0.1:8765/send`): `credo-ntfy-send.sh` and the self-* helpers POST JSON `{title, body, priority, tags}` to it and the relay forwards to its own topic, so agents no longer send to a remote host themselves. Only `http://` on `127.0.0.1`, `localhost` or `[::1]` is accepted, the topic is never sent to the relay, redirects and proxy variables are ignored. While a relay is set it is the only path. A failed relay push is reported, never sent directly instead. Contract and read-only probe in `scripts/credo_ntfy_relay.py`
- `credo-ntfy-send.sh` takes `-p priority` and `--tags` (also `CREDO_NTFY_TAGS`)
- `/credo:setup` offers the relay key when a read-only probe finds a listener on the default loopback port

### Fixed

- A configured ntfy push that cannot be delivered no longer fails silently: `credo-ntfy-send.sh` exits non-zero (2 invalid relay URL, 3 send failed) with the reason on stderr, so agents stop reporting a failed push as sent; not configured stays a silent no-op
