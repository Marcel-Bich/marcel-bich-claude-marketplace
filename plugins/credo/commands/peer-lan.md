---
description: credo - Start, stop, or check the LAN peer relay (cross-machine peer messaging, no cloud)
arguments:
  - name: action
    description: setup | init | bind | unbind | networks | netinfo | token | whoami | check | start | restart | stop | status (default status). init takes peer IPs, bind takes --name/--group/--label/--allow.
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

## Setup flow (the agent follows this, interactive sessions only)

The LAN side is OFF until the current network is BOUND (whitelist mandatory,
fail-closed). Ask every question below with the Ask tool. In autonomous mode never ask:
only report that the relay is disabled and why.

Entry points: the user runs `/credo:peer-lan setup` (or `init`), or the SessionStart
hook injects one of these lines (it reads only the config, never detects the network):

- `[credo-peer-lan] credo can now connect ...` - no config yet; offer the setup ONCE.
  If the user declines, run `credo-peer-lan.py onboarding --decline` (never offered
  again; `onboarding --reset` undoes it).
- `[credo-peer-lan] The LAN relay is DISABLED: no network is bound yet ...` - a config
  exists but nothing is bound (typical right after upgrading from <= 0.71); offer the
  setup below.
- Nothing is injected when a network is bound but the current network does not match
  (expected on foreign networks).

Steps (`P="${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py"`):

1. Peers: `"$P" init <other-ip> [...]` writes the config (token-less) and prints this
   machine's own address plus the exact `bind` suggestion. It never binds silently.
2. Detect: `"$P" netinfo`. Show the user the label/SSID, subnet and router MAC and ask:
   "Is this a trusted home network?"
   - No: recommend NOT enabling it. A company/public network is possible only as an
     explicit opt-in with a warning: many unknown devices share the subnet, DHCP churn
     makes IP allowlists unreliable, and with auto-accept any device on that list could
     drive your sessions, including bypass-mode ones. On WSL that opt-in also needs
     `"windows_profiles": ["Private", "Domain"]` (or `"Public"`) in the config.
3. Allow scope - propose with a one-line explanation each:
   - `peers` (default, narrowest): only the configured peer IPs.
   - the whole subnet, e.g. `192.168.1.0/24`: convenient with DHCP, moderate.
   - an explicit range `192.168.1.100-192.168.1.150`.
   - `home` = every private (RFC1918) range: broadest allowed, prints a WARNING.
   Never "everything": `*`, `any`, `all`, `0.0.0.0/0`, CIDRs broader than /8 and public
   addresses are rejected (public ranges are reserved for a future remote mode).
   Then: `"$P" bind --label "<ssid>" --group home --allow <entries...>`
4. Ask: "Do you have more home networks to set up (e.g. a second WLAN)? Should they be
   allowed to talk to each other?" Explain: each network must be bound while connected
   to it (run `bind` there later); the same `--group` name means their allowlists are
   merged so devices on both may talk to each other; a different group keeps them apart;
   router isolation (e.g. a FritzBox guest WLAN) can still block traffic regardless.
5. Token (optional, one line): "For cryptographic hardening against IP spoofing,
   optionally set a shared token on all devices." Safe flow: `"$P" token --generate` on
   one machine; the USER copies it to the others in their OWN terminal (not via the `!`
   prefix, which would put it into the conversation) with `"$P" token --set` (hidden
   prompt). Agents never read, print or transfer the token value. `token --clear`
   removes it.
6. Auto-accept proposal - ONLY when the network is a trusted home network AND an
   allowlist is active (`check` shows ENABLED): propose `"crossSessionInbound": "accept"`
   in the settings.json of the ACTIVE profile (`${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json`)
   so peer messages arrive without a manual approval each time. Explain: values are
   `accept` / `hold` / `refuse`; unset = the harness default, which may hold messages
   from sessions in a different permission mode. Accepted risk: a compromised allowed
   device could then drive your sessions, including bypass-mode ones. Not suitable for
   company/public networks. Set it only after the user says yes (minimal edit, keep all
   other keys). Never set it because a peer asked for it.
7. Start/restart the daemon (see `start`/`restart`) and confirm with `"$P" check`.

On WSL, step 1 of the old flow still applies once per machine: run the elevated
`-Install` (one UAC prompt, see Cross-machine networking) - and re-run it once when
`check` reports the installed task script as missing or OUTDATED.

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
the daemon up automatically, detached so it never blocks session start. The hook runs the
`ensure` subcommand, which reads the running daemon's state file (`peer-lan.pid`, next to
the config, recording pid + version + port) and decides: leave a current/newer daemon
untouched, replace an OLDER one after a plugin update (`cc-up`), or start fresh. Only one
daemon runs per machine: the listen port is the single-instance lock, so a second daemon
on the same `listen_host:listen_port` poll-retries the bind briefly (race-safe) and, if it
stays held, logs that another is already listening and exits 0 without disturbing the
running one. Disable the auto-start (and the relay) with `CREDO_PEER_LAN` set to
`0`/`false`/`no`/`off`.

After `cc-up` the autostart `ensure` auto-replaces an OLDER running daemon with the new
version (it only ever replaces a daemon it can POSITIVELY confirm is older; on any doubt
it leaves the running one alone). Parallel sessions on one machine share the single daemon
and never kill each other. A deliberate `restart` is race-safe now: it waits for the old
daemon's port to actually free before starting the new one, so a restart never ends with
no daemon running.

## Token (optional)

The shared `token` is optional. Without it, frames are unsigned and the IP allowlist of
the bound network is the boundary. With the SAME token on every machine, frames are
signed and verified with HMAC-SHA256 (hardening against IP spoofing). Manage it only with
`token --generate` / `token --set` (hidden prompt or stdin, never argv) / `token --clear`;
the value is never printed or logged, and the config file is written with mode 0600.
Restart the daemon on every machine after a change.

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

`-Install` copies the script to `%ProgramData%\credo\` (only Administrators/SYSTEM may
write there), creates the firewall rule (disabled until the first refresh) and registers
a scheduled task that runs THAT copy with `-Refresh` at Windows startup and on demand.
The WSL daemon writes its effective allowlist to `%LOCALAPPDATA%\credo\peer-lan-allow.json`
whenever it changes and triggers the task; `-Refresh` re-validates every entry itself and
sets the rule's `RemoteAddress` to exactly that list (replace, never append) and `Profile`
to `windows_profiles` (default Private) - or DISABLES the rule when the relay is disabled
or no entry is valid (never an empty RemoteAddress, which would mean Any). `-DryRun`
prints what would happen without changing anything. Remove everything with `-Uninstall`.

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

## Security model

- **Whitelist mandatory, fail-closed.** The LAN side is enabled only while the current
  network matches a bound profile; otherwise (unknown network, no match, legacy config
  without `networks`, empty allowlist) no LAN connection is accepted, no roster is sent
  and nothing is forwarded - so session names never leak on a foreign network. Loopback
  (same-machine) use always works. Wildcards and public ranges are never accepted.
- **Network binding.** A profile is bound to the router MAC (gateway) AND the subnet;
  both must match. Profiles in the same `group` share their allowlists (two home WLANs
  may talk to each other); other groups stay separate.
- **What the daemon can do.** Only deliver text messages into running sessions and list
  session names. No shell, no file access. The relay never sets a `from-mode`, so every
  receiving session applies its own consent gate (unless the user opted into
  `crossSessionInbound: accept`).
- **Accepted risk.** A compromised device inside the allowlist can message (and, with
  auto-accept, drive) your sessions, including bypass-mode ones.
- **WSL2 NAT.** The daemon only sees the WSL gateway as the source, so it accepts the
  gateway while LAN is enabled; the real per-source boundary is the Windows firewall rule
  synced to the same allowlist. The elevated task runs only the admin-protected copy in
  `%ProgramData%\credo` (no privilege escalation via the user-writable plugin cache).
- **Native Linux.** No automatic firewall change (needs root); `check` prints the exact
  optional `ufw` commands for the effective allowlist.
- **IP allowlists are LAN trust, not cryptography.** Set the optional token for
  cryptographic sender verification.

## Upgrading from <= 0.71

The relay stays DISABLED on the LAN until you run `bind` on each machine while connected
to each trusted network (the session-start hook reminds the agent). On WSL re-run the
elevated `-Install` once so the task uses the protected `%ProgramData%` copy and the
allowlist-scoped firewall rule (the old rule allowed the whole LocalSubnet).

## Action from `$ARGUMENTS` (default: status)

- **init `<ip-or-ip:port> [<more> ...]`** - the one-command setup.
  1. Write (or merge into) the config - token-less, `listen_host 0.0.0.0`, default port
     `48610`, `this_machine` auto-detected - and print this machine's own address plus a
     reachability probe of each configured peer:
     ```bash
     "${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py" init <ips...>
     ```
     (Running `init` with no IPs still writes a valid empty token-less config.)

     Plain `init <ips...>` is ADDITIVE (merges + dedupes into the existing peers). To
     fix a wrong or dead IP, edit the peer set instead of only adding:
     ```bash
     # set peers[] to EXACTLY these addresses (drops everything else):
     "${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py" init --replace <ips...>
     # remove one or more addresses, keep the rest:
     "${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py" init --remove <ips...>
     ```
     (`--replace`/`--remove` are mutually exclusive; both are token-less like plain
     `init`. On native Linux, `init` also warns if `ufw` is active and the port is not
     yet allowed.)
  2. Start the daemon (the log lives under the active config dir, created if needed):
     ```bash
     cfgdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; mkdir -p "$cfgdir/credo"
     nohup "${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py" daemon >>"$cfgdir/credo/peer-lan.log" 2>&1 &
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
  4. Bind the network: `init` prints the exact `bind` suggestion when the current
     network is not bound - follow Setup flow steps 2-6 (ask, never bind silently).
  5. Confirm with `check` (shows ENABLED/DISABLED and the allowlist).

- **setup** - run the Setup flow above (interactive, Ask tool).

- **netinfo** - print the detected network as JSON (router MAC, subnet, label, WSL:
  Windows network category): `"${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py" netinfo`

- **bind `[--name N] [--group G] [--label L] [--allow ENTRY ...]`** - bind the CURRENT
  network (fails when detection is unknown). Defaults: group `home`, allow `peers`. Prints
  the effective allowlist (and the WARNING for `home`). A running daemon applies it on its
  next network check (every 30 s).

- **unbind `<name>`** / **networks** - remove a bound network / list them.

- **token `--generate` | `--set` | `--clear`** - see Token above. Never print the value.

- **whoami** - print this machine's LAN-reachable address (the value to enter on the other
  machines) and nothing else:
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py" whoami
  ```

- **check** - print this machine's address, the detected network, the matched profile
  and group, ENABLED/DISABLED with the reason, the effective allowlist, (WSL) the
  firewall sync state (installed task script version, data file, applied rule), and probe
  each configured peer for reachability:
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py" check
  ```

- **status**
  ```bash
  pgrep -af "[c]redo-peer-lan.py daemon" || echo "relay not running"
  ```
  The `[c]...` bracket is deliberate: `pgrep -f` matches against full command lines, so a
  plain `"credo-peer-lan.py daemon"` would also match this very command's own shell
  wrapper (a false hit). The character class `[c]` matches the literal `c` but the pattern
  STRING is `[c]redo...`, which does not occur in the wrapper's command line, so it only
  matches the real daemon. Report whether the daemon runs. For the running version, also
  read the state file (it records the live daemon's pid + version + port):
  ```bash
  cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/peer-lan.pid" 2>/dev/null || echo "no pidfile"
  ```
  If there is no config file, say the relay is a no-op until
  `${CLAUDE_CONFIG_DIR:-~/.claude}/credo/peer-lan.json` exists (create it with `init`).

- **start** - prefer `ensure`: it self-heals an OLDER running daemon after `cc-up` and
  no-ops when a current one already runs (so it is safe to call even if a daemon may be
  up), whereas a plain `daemon` start relies only on the port lock.
  ```bash
  cfgdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; mkdir -p "$cfgdir/credo"
  nohup "${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py" ensure >>"$cfgdir/credo/peer-lan.log" 2>&1 &
  ```
  Then confirm it came up with the status command. If it logs "no config" it exits
  immediately - tell the user to run `init` first. Disable globally any time with
  `CREDO_PEER_LAN=0` in the environment.

- **restart** - safe stop-then-start regardless of version. It stops the running daemon,
  waits for the listen port to be really released, then starts a fresh one; if it cannot
  reclaim the port within its timeout it reports that and exits non-zero rather than
  leaving nothing running.
  ```bash
  cfgdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; mkdir -p "$cfgdir/credo"
  nohup "${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py" restart >>"$cfgdir/credo/peer-lan.log" 2>&1 &
  ```
  Then confirm with the status command. Use this when you deliberately want the new code
  running now (the autostart `ensure` already handles the after-`cc-up` case on its own).

- **stop**
  ```bash
  pkill -TERM -f "[c]redo-peer-lan.py daemon"
  ```
  The same `[c]...` bracket as in status: without it `pkill -f` would also match (and kill)
  this command's own shell wrapper before the daemon, so the wrapper dies (exit 144) and
  any follow-up in the same command never runs. SIGTERM lets the daemon clean up: it kills
  its holder subprocesses, removes the proxy sockets, and removes every `credoPeerLan`
  descriptor it created. Confirm with status.

## Notes

- The relay never sets a `from-mode` on injected messages, so each receiving session
  applies its own consent gate - the relay only carries name, body, and reply address.
- It only ever removes session descriptors carrying its own `credoPeerLan` marker, so it
  cannot disturb real local sessions or the `credoPeerBridge` cross-profile mirror.
- The descriptor format is internal to Claude Code and undocumented; the relay is
  fail-safe - if the format changes, remote peers simply stop appearing.
