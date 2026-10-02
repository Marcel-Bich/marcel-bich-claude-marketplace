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

The relay is a no-op until a config file exists. It is OFF by default. Once the config
exists it starts automatically on session start (see Auto-start below), so start/stop
here is mostly for manual control.

## Peer name contract (common footgun)

Each `peers[].name` MUST equal that remote machine's own `this_machine` value. A remote
session only materializes (its holder and mirrored descriptor are created) when the
sender machine's `this_machine` matches a configured peer name. A mismatch means the
remote peer silently never appears. The daemon logs one warning per unknown machine
when a roster arrives from a machine that is not among its configured peer names - check
`peer-lan.log` if a peer you expect is missing.

## Auto-start and single instance

Once the config file exists, the `credo-peer-lan-autostart.sh` SessionStart hook brings
the daemon up automatically, detached so it never blocks session start. Only one daemon
runs per machine: the listen port is the single-instance lock, so a second daemon on the
same `listen_host:listen_port` logs that another is already listening and exits 0 without
disturbing the running one. Disable the auto-start (and the relay) with `CREDO_PEER_LAN`
set to `0`/`false`/`no`/`off`.

## One-time setup (the user does this, not the agent)

These steps touch the network and must be performed by Marcel himself:

1. Write the config at `~/.claude/credo/peer-lan.json` (override path with
   `CREDO_PEER_LAN_CONFIG`). See `scripts/peer-lan.example.json` or the README for the
   shape: `this_machine`, `listen_host`, `listen_port`, a shared `token` (identical on
   every machine), and `peers[]` of `{name, host, port}`.
2. Make the daemon reachable from the LAN - see Cross-machine networking below. This
   differs between WSL2 (needs a Windows portproxy) and native Linux (at most a firewall
   allow rule).
3. Use the SAME `token` on every machine; machines with a different token are rejected.

Do NOT perform step 2 or 3 automatically - opening a port, editing a firewall, and
registering a scheduled task are manual, user-owned actions that need elevation.

## Cross-machine networking

The daemon listens on `listen_host:listen_port` (default `0.0.0.0:48610`). How a LAN peer
reaches it depends on the platform. In every case `-Port` / the firewall port MUST match
`listen_port` in `peer-lan.json`.

### WSL2 (default NAT mode)

In WSL2 NAT mode a LAN machine cannot reach the WSL daemon directly: the WSL instance is
behind a NAT only the Windows host sees, and its IP changes on every WSL restart. The
Windows host must forward its own LAN-IP:PORT to the current WSL IP:PORT (a `netsh`
portproxy) and allow the port inbound. `scripts/credo-peer-lan-winproxy.ps1` makes this
self-healing. Run it ONCE per machine in an ELEVATED Windows PowerShell:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "\\wsl$\<distro>\<plugin path>\scripts\credo-peer-lan-winproxy.ps1" -Install -Port 48610
```

(The script lives under the plugin at `plugins/credo/scripts/credo-peer-lan-winproxy.ps1`;
use its real Windows-visible path, for example the `\\wsl$\...` UNC path or a copy on the
Windows side. `-Port` must equal `listen_port`.)

`-Install` creates a LAN-scoped inbound firewall rule, registers a scheduled task that
re-applies the portproxy at Windows startup and runs this script with `-Refresh`, and
applies the portproxy once immediately. After that it is automatic: the task refreshes at
boot, and the `credo-peer-lan-autostart.sh` hook triggers the same task on demand each
time the relay daemon starts - so the WSL-IP-change problem is handled with nothing manual
afterward. Remove everything again with `-Uninstall`.

This one-time elevated admin step is REQUIRED on EVERY machine, including remote ones; it
cannot be performed remotely (it opens a port and registers a scheduled task on that
host). Disable just the hook's proxy trigger with `CREDO_PEER_LAN_WINPROXY=0`.

### Native Linux

No NAT, no portproxy: the daemon already listens on the LAN at `0.0.0.0:listen_port`. If a
firewall is active, allow the port once, scoped to the LAN; otherwise there is nothing to
do. For `ufw`, from the LAN subnet (adjust to your subnet):

```
sudo ufw allow from 192.168.0.0/16 to any port 48610 proto tcp
```

### Security posture

The firewall rule is LAN-scoped (`LocalSubnet` on Windows, a private subnet for `ufw`),
not open to the internet. The relay itself still never forges a `from-mode`, so every
receiving session keeps applying its own consent gate - the portproxy only changes
reachability, not trust.

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
