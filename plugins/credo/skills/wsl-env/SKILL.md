---
name: wsl-env
description: >
  Reach and act on Windows-side services, processes, launchers, and logs when the agent
  runs inside WSL. Use whenever a service seems unreachable from WSL (a localhost curl
  fails), when you need to start/stop or inspect a Windows-side process or .ps1 launcher,
  read Windows logs, hibernate the machine, or when the repo ships both a .sh and a .ps1
  entry point. Self-detecting: if this is not WSL or the target is not Windows-side, it is
  a no-op. Applies inside subagents too. Never conclude "unreachable" or "can't test this"
  from WSL without first trying both the Windows LAN-IP and powershell.exe.
---

# wsl-env - WSL to Windows-side helper

When the agent runs inside WSL, the thing it needs to reach or drive often lives on the
Windows side. WSL frequently cannot reach Windows `localhost` ports directly, so a naive
`curl localhost:PORT` failing is NOT evidence that a service is down. This skill defines
how to detect that situation and how to act across the WSL/Windows boundary correctly.

## Self-detect first (no-op when irrelevant)

Before doing anything WSL-specific, check whether it applies:

- Is this actually WSL? Check for the WSL kernel signature, e.g.
  `grep -qi microsoft /proc/version` (or check `/proc/sys/kernel/osrelease`). If not
  WSL, this skill is a no-op - use normal local access.
- Is the target Windows-side? A service bound by a Windows process, a Windows `.ps1`
  launcher, a Windows path, or a machine-level action (hibernate). If the target is a
  native Linux service inside the WSL distro, this skill is a no-op - reach it the
  normal Linux way.

Only when both are true do the rules below apply.

## Reaching a service: try BOTH methods before giving up

A service reachability failure from WSL has two distinct fixes depending on how the
service is bound. Never conclude "unreachable" without trying both.

1. Service bound to `0.0.0.0` (all interfaces): reachable from WSL via the Windows
   LAN-IP, NOT via `localhost`/`127.0.0.1`. Point the request at the host's real LAN
   address plus the port.
2. True localhost-only service (bound to `127.0.0.1` on Windows): not reachable from
   WSL by IP at all. Reach it by running the request on the Windows side through
   `powershell.exe`, for example:

   ```
   powershell.exe -NoProfile -Command "(Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 http://localhost:PORT/path).Content"
   ```

Rule: if the LAN-IP method fails, try the `powershell.exe` method (and vice versa)
before reporting the service as down.

## Getting the values: config first, then discover

The LAN-IP is environment-specific and DYNAMIC - the host's real LAN address. Resolve it
at runtime, never hardcode it; the config only caches it:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get personal.wsl.lan_ip
```

Windows-side services are configured as a named endpoint list under
`personal.wsl.endpoints`, each entry `{name, port, reach}`. The `reach` field records how
that one endpoint is reached, because different services on the same machine bind
differently:

- `reach: lan_ip` - the service binds `0.0.0.0`; reach it from WSL via the Windows LAN-IP
  plus its port, never via `localhost`/`127.0.0.1`.
- `reach: localhost` - the service is Windows-localhost-only; reach it by running the
  request on the Windows side through `powershell.exe`.

So a single repo can have several endpoints, each with its own reach path - for example a
UI/panel via `lan_ip` and an API via `localhost` - and you pick the method per endpoint
from its `reach` field, not one method for the whole machine. Read the list with:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/credo-config.sh" get personal.wsl.endpoints
```

(Config keys: `personal.wsl.lan_ip` and `personal.wsl.endpoints`. Empty by default - fill
just-in-time with the user's permission. Never conclude a service is unreachable without
having tried both reach methods for its endpoint.)

If the LAN-IP is not configured, discover it generically on the Windows side rather than
guessing. Query the Windows adapters and pick the real physical LAN adapter (Wi-Fi or
Ethernet), not a virtual adapter (WSL, Hyper-V, VirtualBox, and similar virtual switches
have their own addresses that are not the machine's LAN address):

```
powershell.exe -NoProfile -Command "Get-NetIPAddress -AddressFamily IPv4 | Select-Object IPAddress,InterfaceAlias"
```

Choose the address whose `InterfaceAlias` is the real Wi-Fi/Ethernet adapter and whose
address is a private LAN address. Do not assume any particular subnet - what is a valid
LAN range on one machine is not on another. Confirm the choice by reachability, then
offer to store it in config so it need not be rediscovered.

## Windows processes, launchers, logs, hibernate: use powershell.exe

Anything on the Windows side is driven through `powershell.exe`, which runs in the
Windows context and can see Windows localhost, processes, and scripts:

- Inspect processes:
  `powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"name='python.exe'\" | Select ProcessId,CommandLine"`
- Start a Windows-side server by invoking the project's `.ps1` launcher via
  `powershell.exe` - run it detached / in the background so the WSL call does not block
  on a foreground server.
- Stop a Windows-side process: `powershell.exe -NoProfile -Command "Stop-Process -Id <pid>"`
  or the project's stop script.
- Read Windows logs by having `powershell.exe` read them on the Windows side.
- Hibernate: `shutdown.exe /h` (subject to the credo autonomous-session hibernate rules -
  veto window and double-hibernate protection; never hibernate on the agent's own
  initiative outside those rules).

If a Windows-side service must accept inbound connections from WSL and still cannot be
reached after both methods above, a Windows Firewall inbound rule for that port may be
required. Propose it; do not silently change the firewall.

## Dual-platform parity (.sh + .ps1)

When a repo is meant to run on both Linux/WSL and Windows, entry points and helper
scripts need a working counterpart on each platform - a `.sh` and an equivalent `.ps1`.
The agent checks for itself whether this parity is relevant for the current repo (it is
not relevant for a Linux-only or Windows-only project). If it is relevant, keeping the
two in parity is mandatory: do not add or change one platform's script without providing
or updating the other. A missing counterpart on a dual-platform repo is an incomplete
change, not an optional extra.
