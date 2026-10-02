---
description: credo - Start, stop, or check the LAN peer relay (cross-machine peer messaging, no cloud)
arguments:
  - name: action
    description: start | stop | status (default status)
    required: false
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py:*)
  - Bash(pgrep:*)
  - Bash(pkill:*)
  - Bash(cat:*)
  - Bash(nohup:*)
---

# Credo LAN Peer Relay

The LAN relay lets Claude Code peer sessions on DIFFERENT machines in the same trusted
network see and message each other (`ListAgents` / `SendMessage`) without the Anthropic
cloud. It extends the same-machine peer model: a small daemon on each machine publishes
its local sessions to its configured peers over TCP and mirrors every remote session
into the local `sessions/` registry so it shows up as an ordinary peer.

The relay is a no-op until a config file exists. It is OFF by default.

## One-time setup (the user does this, not the agent)

These steps touch the network and must be performed by Marcel himself:

1. Write the config at `~/.claude/credo/peer-lan.json` (override path with
   `CREDO_PEER_LAN_CONFIG`). See `scripts/peer-lan.example.json` or the README for the
   shape: `this_machine`, `listen_host`, `listen_port`, a shared `token` (identical on
   every machine), and `peers[]` of `{name, host, port}`.
2. Open the chosen `listen_port` in the host firewall for the LAN only, and under WSL
   set up any portproxy so the Windows host forwards the port to the WSL daemon.
3. Use the SAME `token` on every machine; machines with a different token are rejected.

Do NOT perform step 2 or 3 automatically - opening a port and editing a firewall are
manual, user-owned actions.

## Action from `$ARGUMENTS` (default: status)

- **status**
  ```bash
  pgrep -af "credo-peer-lan.py daemon" || echo "relay not running"
  ```
  Report whether the daemon runs. If there is no config file, say the relay is a no-op
  until `~/.claude/credo/peer-lan.json` exists.

- **start**
  ```bash
  nohup "${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py" daemon >>"$HOME/.claude/credo/peer-lan.log" 2>&1 &
  ```
  Then confirm it came up with the status command. If it logs "no config" it exits
  immediately - tell the user to create the config first. Disable globally any time with
  `CREDO_PEER_LAN=0` in the environment.

- **stop**
  ```bash
  pkill -TERM -f "credo-peer-lan.py daemon"
  ```
  SIGTERM lets the daemon clean up: it kills its holder subprocesses, removes the proxy
  sockets, and removes every `credoPeerLan` descriptor it created. Confirm with status.

## Notes

- The relay never sets a `from-mode` on injected messages, so each receiving session
  applies its own consent gate - the relay only carries name, body, and reply address.
- It only ever removes session descriptors carrying its own `credoPeerLan` marker, so it
  cannot disturb real local sessions or the `credoPeerBridge` cross-profile mirror.
- The descriptor format is internal to Claude Code and undocumented; the relay is
  fail-safe - if the format changes, remote peers simply stop appearing.
