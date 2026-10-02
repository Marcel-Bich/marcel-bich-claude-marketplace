---
description: credo - Start, stop, or check the LAN peer relay (cross-machine peer messaging, no cloud)
arguments:
  - name: action
    description: init | whoami | check | start | stop | status (default status). init also takes one or more peer IPs.
    required: false
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py:*)
  - Bash(pgrep:*)
  - Bash(pkill:*)
  - Bash(cat:*)
  - Bash(nohup:*)
  - Bash(grep:*)
  - Bash(wslpath:*)
  - Bash(powershell.exe:*)
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

## Dead-simple setup (recommended)

On EACH machine, after `cc-up`:

1. `/credo:peer-lan init <other-ip> [<more-ips> ...]` - lists the OTHER machines' LAN
   addresses, writes the config token-less, starts the daemon, and (under WSL) opens the
   Windows port with a SINGLE UAC prompt.
2. Approve the one UAC prompt (WSL only).
3. Done.

You never type a name and never set a token. `init` also prints THIS machine's own
reachable address, so you just read that one line and paste that IP into the `init` on
the other machines. No guessing which IP.

### Which IP do I enter?

Always the TARGET machine's LAN IP - the machine you want to reach:

- A WSL2 target: its WINDOWS HOST LAN IP (for example `192.168.1.50`), NOT the `172.x`
  WSL IP.
- A native Linux target: its own LAN IP.

The source machine's type is irrelevant. To find a machine's address, run
`/credo:peer-lan whoami` (or `credo-peer-lan.py whoami`) ON that machine - it prints the
exact value to enter elsewhere.

## Address-based routing (no name contract)

A peer is identified by its ADDRESS (`host:port`), never by a name. In the config,
`peers[]` is a simple list of `"IP"` or `"IP:PORT"` strings (a bare `IP` uses
`listen_port`). A roster arriving from a configured peer address is paired with that
address, and the relay forwards to it directly - so there is nothing to keep in sync
between machines and no silent "peer never appears" footgun. The legacy
`{name, host, port}` object form is still accepted and normalized, but names no longer
affect routing. (The mirrored peer is still displayed as `name@machine` using the
remote's own `this_machine`, purely for the label.)

## Auto-start and single instance

Once the config file exists, the `credo-peer-lan-autostart.sh` SessionStart hook brings
the daemon up automatically, detached so it never blocks session start. Only one daemon
runs per machine: the listen port is the single-instance lock, so a second daemon on the
same `listen_host:listen_port` logs that another is already listening and exits 0 without
disturbing the running one. Disable the auto-start (and the relay) with `CREDO_PEER_LAN`
set to `0`/`false`/`no`/`off`.

## Token (optional)

The shared `token` is optional. Omit it (the default `init` does) and the relay runs
TOKEN-LESS, the casual default for a trusted home LAN. Without a token, any device that
can reach `listen_host:listen_port` can send messages to your sessions - gated only by
the receiving session's own consent prompt (the relay never forges a trusted sender, so
this gate always applies). Set the SAME non-empty `token` on every machine to restrict
messaging to your own devices; recommended on untrusted or company networks. Enabling it
later is just adding the same `token` to the config on every machine - restart the daemon
on each.

## Cross-machine networking

The daemon listens on `listen_host:listen_port` (default `0.0.0.0:48610`). How a LAN peer
reaches it depends on the platform. In every case `-Port` / the firewall port MUST match
`listen_port`.

### WSL2 (default NAT mode)

In WSL2 NAT mode a LAN machine cannot reach the WSL daemon directly: the WSL instance is
behind a NAT only the Windows host sees, and its IP changes on every WSL restart. The
Windows host must forward its own LAN-IP:PORT to the current WSL IP:PORT (a `netsh`
portproxy) and allow the port inbound. `scripts/credo-peer-lan-winproxy.ps1` makes this
self-healing. The `init` action below does this for you as a single UAC prompt; to run it
by hand once in an ELEVATED Windows PowerShell:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "\\wsl.localhost\<distro>\<plugin path>\scripts\credo-peer-lan-winproxy.ps1" -Install -Port 48610
```

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

- **init `<ip-or-ip:port> [<more> ...]`** - the one-command setup.
  1. Write (or merge into) the config - token-less, `listen_host 0.0.0.0`, default port
     `48610`, `this_machine` auto-detected - and print this machine's own address plus a
     reachability probe of each configured peer:
     ```bash
     "${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py" init <ips...>
     ```
     (Running `init` with no IPs still writes a valid empty token-less config.)
  2. Start the daemon:
     ```bash
     nohup "${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py" daemon >>"$HOME/.claude/credo/peer-lan.log" 2>&1 &
     ```
  3. Open the LAN port:
     - **Under WSL only** (detect with `grep -qi microsoft /proc/version` or a set
       `$WSL_DISTRO_NAME`): open the Windows port with a SINGLE elevated UAC prompt.
       First derive the Windows-visible path of the installer:
       ```bash
       winps="$(wslpath -w "${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan-winproxy.ps1")"
       ```
       `wslpath -w` turns the WSL path into its `\\wsl.localhost\<distro>\...` UNC form
       (older Windows: `\\wsl$\<distro>\...`). Then launch the installer elevated - this
       is the only step that prompts for UAC:
       ```bash
       powershell.exe -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$winps','-Install','-Port','48610'"
       ```
       Tell the user to approve the one UAC prompt. The `-Port` MUST equal `listen_port`.
     - **On native Linux:** skip the UAC step; print the one-line `ufw` hint from the
       Native Linux section above (only needed if a firewall is active).
  4. Confirm with the status command.

- **whoami** - print this machine's LAN-reachable address (the value to enter on the other
  machines) and nothing else:
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py" whoami
  ```

- **check** - print this machine's address and probe each configured peer for
  reachability:
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py" check
  ```

- **status**
  ```bash
  pgrep -af "credo-peer-lan.py daemon" || echo "relay not running"
  ```
  Report whether the daemon runs. If there is no config file, say the relay is a no-op
  until `~/.claude/credo/peer-lan.json` exists (create it with `init`).

- **start**
  ```bash
  nohup "${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py" daemon >>"$HOME/.claude/credo/peer-lan.log" 2>&1 &
  ```
  Then confirm it came up with the status command. If it logs "no config" it exits
  immediately - tell the user to run `init` first. Disable globally any time with
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
