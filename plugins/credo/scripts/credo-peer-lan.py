#!/usr/bin/env python3
"""credo-peer-lan.py - LAN relay so Claude Code peer sessions on different machines
in the same trusted network can see and message each other without the Anthropic
cloud (no Remote Control, no API).

It extends the same-machine peer model (see hooks/credo-peer-bridge.sh): Claude Code
enumerates local peers by reading session descriptor files under
"<CLAUDE_CONFIG_DIR>/sessions/<pid>.json" and resolves a peer name to its inbox unix
socket (messagingSocketPath). This daemon makes REMOTE sessions appear there too, so
ListAgents lists them and SendMessage reaches them, with replies routing back.

How a remote session is represented locally
--------------------------------------------
A remote session has no local process, so its pid is not alive and its descriptor
would be reaped by the discovery reader (which validates the pid is a live local
process, matching procStart = field 22 of /proc/<pid>/stat to resist pid reuse) and
by credo-peer-bridge.sh's prune. So for each remote session this daemon spawns one
lightweight local HOLDER subprocess that listens on a local PROXY unix socket. The
holder is a real live local process, so:
  - its pid is alive (kill -0 succeeds),
  - its /proc/<pid>/stat procStart is real,
and the mirrored descriptor uses the holder pid as both the <pid> filename and the
descriptor's pid/procStart fields, copies pidDomain from a real local session (so it
is treated as local), points messagingSocketPath at the proxy socket, keeps the
remote name suffixed with the machine ("name__machine"), and carries the marker key
"credoPeerLan" (NOT "credoPeerBridge", so the existing bridge never touches it).

When a local session writes into a proxy socket, the holder forwards the message as a
"deliver" over TCP to the owning remote daemon, which injects it into the real local
target socket there.

SAFETY
  - The injected envelope NEVER carries a from-mode attribute. Omitting it is the
    whole point: the receiving session applies its OWN built-in consent gate instead
    of us forging a trusted sender. The relay is mode-agnostic (name/body/reply only).
  - This daemon only ever removes session descriptors that carry its own
    "credoPeerLan" marker, and only proxy sockets / holders it created.
  - No-op when no config file exists, or when CREDO_PEER_LAN is set to off.
  - WHITELIST MANDATORY, FAIL-CLOSED: the LAN side is only enabled while the current
    network matches a bound network profile (router MAC + subnet, see `bind`). Then
    only sources/targets inside the effective allowlist (peer IPs, CIDRs, ranges or
    "home" = RFC1918; never a wildcard, never public ranges) are served. Unknown
    network, no match, legacy config without "networks" or an empty allowlist ->
    LAN disabled: no inbound from the LAN, no rosters, no forwards. Loopback
    (same-machine) use always works. All entries go through parse_allow_entry.
  - Under WSL2 NAT the daemon only sees the WSL gateway as the source address, so the
    real per-source filter there is the Windows firewall rule, which the elevated
    task (credo-peer-lan-winproxy.ps1) sets to exactly the same allowlist.

Transport: line-based JSON over TCP. A shared token is OPTIONAL. With a token, frames
are signed and verified with HMAC-SHA256 (reject on mismatch). Without one (the casual
default), the daemon runs token-less: it signs nothing and accepts unsigned frames, so
any device that can reach the port may message local sessions - still gated by each
receiving session's own consent prompt (we never forge a from-mode). Python 3 stdlib
only.
"""

import argparse
import errno
import getpass
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid

MARK = "credoPeerLan"
MARK_FROM = "credoPeerLanFrom"
DEFAULT_PORT = 48610
DEFAULT_ROSTER_INTERVAL = 5.0
DEFAULT_MACHINE_TIMEOUT = 30.0
# upper bound on remote sessions materialized per machine, to cap subprocess and
# disk growth from a large or hostile roster (config key max_remotes_per_machine)
MAX_REMOTES_PER_MACHINE = 64
# upper bound on concurrent inbound TCP handler threads. Auth happens only after a
# full line is read, so without this cap an unauthenticated LAN client could open
# many connections and exhaust threads/memory (config key max_conn_threads).
MAX_CONN_THREADS = 64
# upper bound on concurrent holder proxy-connection worker threads, so one stuck
# local client cannot block other local writers and the pool cannot grow unbounded.
MAX_HOLDER_WORKERS = 16
# how long the holder server socket blocks on accept before re-checking its parent
HOLDER_ACCEPT_TIMEOUT = 2.0
# how long an accept loop waits to acquire its concurrency slot before shedding a
# connection, so the accept loop itself never blocks on a full pool
ACQUIRE_TIMEOUT = 0.5
ENVELOPE_RE = re.compile(
    r"<cross-session-message\b[^>]*>(.*)</cross-session-message>", re.S
)
FROM_NAME_RE = re.compile(r'from-name="([^"]*)"')

# On EADDRINUSE at startup do NOT give up at once: poll-retry the bind for this long
# (interval between tries) before raising AlreadyRunning. This guards the restart
# kill/start race where the old daemon still holds the port for a moment while the new
# one starts, so the new one no longer loses the port and exits leaving nothing running.
BIND_RETRY_TOTAL = 8.0
BIND_RETRY_INTERVAL = 0.25
# how long _terminate_incumbent waits for a SIGTERMed daemon to die and free the port
TERMINATE_TIMEOUT = 8.0


def _read_version():
    """Best-effort plugin version from the sibling manifest
    (../.claude-plugin/plugin.json, key "version"). Each daemon is launched from its
    own versioned plugin dir after cc-up, so this yields that daemon's own version.
    CREDO_PEER_LAN_VERSION overrides it - TEST-ONLY, same spirit as the existing
    CREDO_PEER_LAN_PROCVERSION override. Fallback "unknown" when the manifest is
    missing, unreadable, or has no usable version."""
    override = os.environ.get("CREDO_PEER_LAN_VERSION")
    if override:
        return override
    manifest = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..", ".claude-plugin", "plugin.json",
    )
    try:
        with open(manifest) as fh:
            data = json.load(fh)
        v = data.get("version")
        if isinstance(v, str) and v:
            return v
    except Exception:
        pass
    return "unknown"


# computed once at import; the running daemon records it in the pidfile (see start())
VERSION = _read_version()


def log(msg):
    sys.stderr.write("[credo-peer-lan %d] %s\n" % (os.getpid(), msg))
    sys.stderr.flush()


def disabled():
    return str(os.environ.get("CREDO_PEER_LAN", "1")).lower() in (
        "0",
        "false",
        "no",
        "off",
    )


def config_path():
    p = os.environ.get("CREDO_PEER_LAN_CONFIG")
    if p:
        return p
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude"
    )
    return os.path.join(cfg, "credo", "peer-lan.json")


def sessions_dir():
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude"
    )
    return os.path.join(cfg, "sessions")


def sock_dir():
    p = os.environ.get("CREDO_PEER_LAN_SOCKDIR")
    if p:
        return p
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude"
    )
    return os.path.join(cfg, "credo", "peer-lan-sock")


def pidfile_path():
    """State file recording the running daemon's pid+version+port, next to the config.
    A new session's `ensure` reads it to decide whether to leave, replace, or start."""
    return os.path.join(os.path.dirname(config_path()), "peer-lan.pid")


def load_config():
    path = config_path()
    try:
        with open(path) as fh:
            cfg = json.load(fh)
    except FileNotFoundError:
        return None
    except Exception as exc:
        log("config %s unreadable: %s" % (path, exc))
        return None
    if not isinstance(cfg, dict):
        log("config %s is not a JSON object" % path)
        return None
    return cfg


# ---------------------------------------------------------------------------
# peer address normalization (routing is address-based: a peer is a host:port,
# NOT a name). A config "peers" entry may be a plain "IP" / "IP:PORT" string or
# the legacy {name?, host, port} object; both normalize to {host, port, name?}.
# ---------------------------------------------------------------------------
def split_host_port(text, default_port):
    """Split "host" or "host:port" into (host, port). Only the trailing ":port"
    (all digits) is treated as a port, so a bare host keeps default_port. IPv6
    literals are out of scope (the user lists plain IPv4 addresses)."""
    text = (text or "").strip()
    if not text:
        return None, default_port
    if ":" in text:
        head, _, tail = text.rpartition(":")
        if head and tail.isdigit():
            return head, int(tail)
    return text, default_port


def normalize_peer(entry, default_port):
    """Normalize one peers[] entry to {host, port, name} or None if unusable.
    Accepts a plain "IP"/"IP:PORT" string or a {name?, host, port} object."""
    if isinstance(entry, str):
        host, port = split_host_port(entry, default_port)
        if not host:
            return None
        return {"host": host, "port": int(port), "name": None}
    if isinstance(entry, dict):
        host = entry.get("host")
        if not host:
            return None
        return {
            "host": host,
            "port": int(entry.get("port", default_port)),
            "name": entry.get("name"),
        }
    return None


def normalize_peers(raw, default_port):
    """Normalize + dedupe a peers list by (host, port), preserving order."""
    out = []
    seen = set()
    if not isinstance(raw, list):
        return out
    for entry in raw:
        p = normalize_peer(entry, default_port)
        if not p:
            continue
        key = (p["host"], p["port"])
        if key in seen:
            continue
        seen.add(key)
        out.append(p)
    return out


def peer_to_string(peer, default_port):
    """Render a normalized peer back as the simple "host" or "host:port" string
    stored in the config (the port is dropped when it equals the listen port)."""
    if int(peer["port"]) == int(default_port):
        return peer["host"]
    return "%s:%d" % (peer["host"], int(peer["port"]))


# ---------------------------------------------------------------------------
# self-address detection + reachability probe (active setup help, so the user
# never has to figure out which IP to enter on the other machines)
# ---------------------------------------------------------------------------
IPV4_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")


def have_cmd(name):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if d and os.path.exists(os.path.join(d, name)):
            return True
    return False


def is_wsl():
    """True on WSL (same detection the autostart hook uses). The proc-version
    path is overridable with CREDO_PEER_LAN_PROCVERSION for deterministic tests."""
    procver = os.environ.get("CREDO_PEER_LAN_PROCVERSION", "/proc/version")
    try:
        with open(procver) as fh:
            if "microsoft" in fh.read().lower():
                return True
    except OSError:
        pass
    return bool(os.environ.get("WSL_DISTRO_NAME"))


def is_lan_ipv4(ip):
    """Reject addresses that are never a LAN-reachable peer address: loopback,
    link-local, the VirtualBox host-only net, and the 172.16-31 range WSL/Docker
    NAT uses. Used as a backstop when picking the self address."""
    if not IPV4_RE.match(ip or ""):
        return False
    if ip.startswith("127.") or ip.startswith("169.254.") or ip.startswith("192.168.56."):
        return False
    parts = ip.split(".")
    if parts[0] == "172":
        try:
            if 16 <= int(parts[1]) <= 31:
                return False
        except ValueError:
            pass
    return True


def parse_ip_route_src(text):
    """Extract the "src <ipv4>" address from `ip route get ...` output, ignoring
    a 127.0.0.1 src (which means no real route). Returns the IP or None."""
    m = re.search(r"\bsrc\s+(\d{1,3}(?:\.\d{1,3}){3})", text or "")
    if m and m.group(1) != "127.0.0.1":
        return m.group(1)
    return None


def self_ip_linux():
    """Primary LAN IPv4 = src of the default route (not 127.0.0.1)."""
    try:
        out = subprocess.run(
            ["ip", "route", "get", "1.1.1.1"],
            capture_output=True, text=True, timeout=5,
        )
    except Exception:
        return None
    return parse_ip_route_src(out.stdout)


def self_ip_wsl():
    """Windows host LAN IPv4 of the default-route adapter, via powershell.exe -
    the address a LAN peer must use to reach this WSL machine. Read-only; returns
    None (never raises) if powershell.exe is absent or the query fails."""
    if not have_cmd("powershell.exe"):
        return None
    ps = (
        "Get-NetIPConfiguration | Where-Object {$_.IPv4DefaultGateway} | "
        "Select-Object -First 1 -ExpandProperty IPv4Address | "
        "Select-Object -ExpandProperty IPAddress"
    )
    try:
        out = subprocess.run(
            ["powershell.exe", "-NoProfile", "-Command", ps],
            capture_output=True, text=True, timeout=15,
        )
    except Exception:
        return None
    cands = [ln.strip() for ln in out.stdout.splitlines() if IPV4_RE.match(ln.strip())]
    for ip in cands:
        if is_lan_ipv4(ip):
            return ip
    return cands[0] if cands else None


def detect_self_ip():
    """This machine's LAN-reachable IPv4, or None if it cannot be determined.
    Under WSL this is the Windows host IP; natively it is the default-route src."""
    if is_wsl():
        return self_ip_wsl()
    return self_ip_linux()


def probe_peer(host, port, timeout=1.5):
    """True if a TCP connect to host:port succeeds within timeout (non-fatal)."""
    try:
        s = socket.create_connection((host, int(port)), timeout=timeout)
        s.close()
        return True
    except Exception:
        return False


def print_self_address(cfg):
    port = int(cfg.get("listen_port", DEFAULT_PORT))
    ip = detect_self_ip()
    if ip:
        print(
            'This machine is reachable at %s:%d - run "/credo:peer-lan init %s" '
            "on your other machines." % (ip, port, ip)
        )
        return
    print("Could not auto-detect this machine's LAN address.")
    if is_wsl():
        print(
            "Under WSL2 enter this machine's WINDOWS HOST LAN IP (not the 172.x "
            "WSL IP) on your other machines. Find it with: powershell.exe "
            '-NoProfile -Command "Get-NetIPConfiguration | '
            'Where-Object {$_.IPv4DefaultGateway}"'
        )
    else:
        print("Find it with: ip route get 1.1.1.1 (use the 'src' address).")


def probe_all_peers(cfg):
    default_port = int(cfg.get("listen_port", DEFAULT_PORT))
    peers = normalize_peers(cfg.get("peers", []), default_port)
    if not peers:
        print("No peers configured yet.")
        return
    print("Peer reachability:")
    for p in peers:
        if probe_peer(p["host"], p["port"]):
            print("  %s:%d - reachable" % (p["host"], p["port"]))
        else:
            print(
                "  %s:%d - not reachable (check that the peer is running and its "
                "port is open)" % (p["host"], p["port"])
            )


# ---------------------------------------------------------------------------
# allowlist (whitelist) - the ONE place every allow entry is parsed and validated.
# The daemon, `bind`, `check` and the Windows data file all go through
# parse_allow_entry/build_allowlist, so a future mode (e.g. remote A2A with public
# ranges) only has to extend this one function instead of several call sites.
# ---------------------------------------------------------------------------
PRIVATE_BLOCKS = tuple(
    ipaddress.IPv4Network(n)
    for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8")
)
HOME_CIDRS = ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
WILDCARD_WORDS = ("*", "any", "all", "everything", "0.0.0.0", "0.0.0.0/0", "::/0")
MIN_PREFIX = 8
HOME_WARNING = (
    'WARNING: allow entry "home" admits EVERY private (RFC1918) address '
    "(10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) while this network is active - "
    "the broadest scope allowed. Prefer the peer IPs or your subnet."
)
WIN_PROFILES_ALLOWED = ("Private", "Domain", "Public")
WIN_CATEGORY_TO_PROFILE = {
    "Private": "Private",
    "Public": "Public",
    "DomainAuthenticated": "Domain",
    "Domain": "Domain",
}
DEFAULT_NETWORK_RECHECK = 30.0
DEFAULT_WIN_TASK = "credo-peer-lan-proxy"
NETWORK_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
MAC_RE = re.compile(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")


class AllowEntryError(ValueError):
    """An allow entry that is malformed or not permitted (wildcard, too broad,
    public). The message is user-facing."""


def _parse_ipv4(text, raw):
    text = text.strip()
    if not IPV4_RE.match(text):
        raise AllowEntryError("%r is not a valid IPv4 address, CIDR or range" % raw)
    try:
        return ipaddress.IPv4Address(text)
    except ValueError:
        raise AllowEntryError("%r is not a valid IPv4 address, CIDR or range" % raw)


def _private_block(lo, hi):
    for block in PRIVATE_BLOCKS:
        if lo in block and hi in block:
            return block
    return None


def parse_allow_entry(raw):
    """Parse + validate ONE allow entry. Returns a dict:
      {"kind": "peers"}  - keyword: all configured peer IPs
      {"kind": "home"}   - keyword: all RFC1918 ranges (caller prints HOME_WARNING)
      {"kind": "addr", "text": canonical, "lo": int, "hi": int}
    Accepted address forms: single IPv4, CIDR (prefix /8../32), range "a-b".
    Raises AllowEntryError for wildcards, CIDRs broader than /8, anything that is not
    entirely inside one private (RFC1918) or loopback block, and malformed input.
    Public ranges are rejected on purpose for now: they are reserved for a future
    remote mode, which would extend THIS function."""
    if not isinstance(raw, str):
        raise AllowEntryError("allow entry %r must be a string" % (raw,))
    text = raw.strip()
    low = text.lower()
    if not text:
        raise AllowEntryError("empty allow entry")
    if low in WILDCARD_WORDS or "*" in text:
        raise AllowEntryError(
            "%r: wildcards are never allowed - list the peer IPs, a subnet, a range "
            "or 'home'" % raw
        )
    if low == "peers":
        return {"kind": "peers", "text": "peers"}
    if low == "home":
        return {"kind": "home", "text": "home"}
    if "/" in text:
        addr, _, pfx = text.partition("/")
        _parse_ipv4(addr, raw)
        if not pfx.strip().isdigit() or int(pfx) > 32:
            raise AllowEntryError("%r has an invalid prefix length" % raw)
        prefix = int(pfx)
        if prefix < MIN_PREFIX:
            raise AllowEntryError(
                "%r is broader than /%d - not allowed (use a smaller subnet, a range "
                "or 'home')" % (raw, MIN_PREFIX)
            )
        net = ipaddress.IPv4Network("%s/%d" % (addr.strip(), prefix), strict=False)
        lo, hi = net.network_address, net.broadcast_address
        canon = str(lo) if prefix == 32 else str(net)
    elif "-" in text:
        a, _, b = text.partition("-")
        lo, hi = _parse_ipv4(a, raw), _parse_ipv4(b, raw)
        if lo > hi:
            raise AllowEntryError("%r: range start is after its end" % raw)
        canon = str(lo) if lo == hi else "%s-%s" % (lo, hi)
    else:
        lo = hi = _parse_ipv4(text, raw)
        canon = str(lo)
    if _private_block(lo, hi) is None:
        raise AllowEntryError(
            "%r is not inside one private (RFC1918) or loopback range - public "
            "addresses/ranges are not supported yet (reserved for a future remote "
            "mode)" % raw
        )
    return {"kind": "addr", "text": canon, "lo": int(lo), "hi": int(hi)}


def build_allowlist(entries, peers):
    """Expand + validate + dedup a list of allow entries. "peers" expands to every
    configured peer host, "home" to the RFC1918 blocks (adds HOME_WARNING). Invalid
    entries are dropped and reported in errors (never silently widened).
    Returns {"allow": [canonical text], "ranges": [(lo, hi)], "warnings": [...],
    "errors": [...]}."""
    out = {"allow": [], "ranges": [], "warnings": [], "errors": []}
    seen = set()

    def _add(parsed):
        if parsed["text"] in seen:
            return
        seen.add(parsed["text"])
        out["allow"].append(parsed["text"])
        out["ranges"].append((parsed["lo"], parsed["hi"]))

    if not isinstance(entries, list):
        out["errors"].append("allow must be a list of entries")
        return out
    for raw in entries:
        try:
            parsed = parse_allow_entry(raw)
        except AllowEntryError as exc:
            out["errors"].append(str(exc))
            continue
        if parsed["kind"] == "peers":
            for p in peers or []:
                try:
                    _add(parse_allow_entry(p["host"]))
                except AllowEntryError as exc:
                    out["errors"].append("peer %s not allowlisted: %s" % (p["host"], exc))
        elif parsed["kind"] == "home":
            if HOME_WARNING not in out["warnings"]:
                out["warnings"].append(HOME_WARNING)
            for cidr in HOME_CIDRS:
                _add(parse_allow_entry(cidr))
        else:
            _add(parsed)
    return out


def is_loopback_ip(ip):
    ip = ip or ""
    if ip.startswith("::ffff:"):
        ip = ip[7:]
    return ip.startswith("127.") or ip == "::1"


def ip_in_ranges(ip, ranges):
    try:
        v = int(ipaddress.IPv4Address((ip or "").replace("::ffff:", "")))
    except ValueError:
        return False
    return any(lo <= v <= hi for lo, hi in ranges)


def windows_profiles(cfg):
    """Validated windows_profiles (WSL only): default ["Private"]; "Domain"/"Public"
    are explicit, not-recommended opt-ins for company/public networks."""
    raw = cfg.get("windows_profiles")
    if raw is None:
        return ["Private"]
    out = []
    if isinstance(raw, list):
        for v in raw:
            for allowed in WIN_PROFILES_ALLOWED:
                if isinstance(v, str) and v.strip().lower() == allowed.lower():
                    if allowed not in out:
                        out.append(allowed)
    return out or ["Private"]


# ---------------------------------------------------------------------------
# network detection + binding. A network profile is bound to the router's MAC
# address plus the subnet; only on a matching network is the LAN side enabled.
# ---------------------------------------------------------------------------
def normalize_mac(mac):
    m = (mac or "").strip().lower().replace("-", ":")
    if MAC_RE.match(m) and m not in ("00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff"):
        return m
    return None


def _win_cwd():
    # run Windows tools from a Windows directory so cmd.exe does not warn about a
    # UNC working directory
    return "/mnt/c" if os.path.isdir("/mnt/c") else None


def _run_out(argv, timeout=5, cwd=None):
    try:
        res = subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout, cwd=cwd
        )
    except Exception:
        return ""
    return res.stdout or ""


def linux_default_route():
    """(gateway_ip, device) of the lowest-metric IPv4 default route, or (None, None)."""
    best = None
    for line in _run_out(["ip", "-o", "-4", "route", "show", "default"]).splitlines():
        m = re.search(r"\bvia\s+(\d{1,3}(?:\.\d{1,3}){3})\s+dev\s+(\S+)", line)
        if not m:
            continue
        mm = re.search(r"\bmetric\s+(\d+)", line)
        metric = int(mm.group(1)) if mm else 0
        if best is None or metric < best[0]:
            best = (metric, m.group(1), m.group(2))
    if best is None:
        return None, None
    return best[1], best[2]


def _neigh_mac(gw, dev):
    out = _run_out(["ip", "neigh", "show", gw, "dev", dev])
    m = re.search(r"\blladdr\s+([0-9a-fA-F:]{17})", out)
    if m:
        return normalize_mac(m.group(1))
    try:
        with open("/proc/net/arp") as fh:
            for line in fh.read().splitlines()[1:]:
                cols = line.split()
                if len(cols) >= 4 and cols[0] == gw:
                    return normalize_mac(cols[3])
    except OSError:
        pass
    return None


def _ssid_linux():
    if have_cmd("iwgetid"):
        s = _run_out(["iwgetid", "-r"], timeout=3).strip()
        if s:
            return s
    if have_cmd("nmcli"):
        for line in _run_out(
            ["nmcli", "-t", "-f", "active,ssid", "dev", "wifi"], timeout=5
        ).splitlines():
            if line.startswith("yes:"):
                return line[4:].strip() or None
    return None


def detect_network_linux():
    gw, dev = linux_default_route()
    if not gw:
        return None
    mac = _neigh_mac(gw, dev)
    if mac is None:
        # the router is not in the neighbor table yet: one empty UDP datagram to it
        # makes the kernel resolve its MAC (ARP); then read the table again
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.sendto(b"", (gw, 9))
            s.close()
            time.sleep(0.3)
        except OSError:
            pass
        mac = _neigh_mac(gw, dev)
    out = _run_out(["ip", "-o", "-4", "addr", "show", "dev", dev])
    m = re.search(r"\binet\s+(\d{1,3}(?:\.\d{1,3}){3}/\d{1,2})", out)
    ip = subnet = None
    if m:
        iface = ipaddress.IPv4Interface(m.group(1))
        ip, subnet = str(iface.ip), str(iface.network)
    return {
        "iface": dev,
        "ip": ip,
        "subnet": subnet,
        "gateway_ip": gw,
        "gateway_mac": mac,
        "ssid": _ssid_linux(),
    }


# ONE read-only powershell call: the Windows default route with the lowest metric,
# the router MAC from the neighbor table, the adapter IPv4 + prefix, and the network
# profile (name = label, NetworkCategory = Private/Public/DomainAuthenticated).
WSL_NETINFO_PS = (
    '$ErrorActionPreference="Stop"; '
    '$r = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 | '
    "Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric } | "
    "Select-Object -First 1; "
    "$n = Get-NetNeighbor -IPAddress $r.NextHop -InterfaceIndex $r.ifIndex "
    "-ErrorAction SilentlyContinue | Select-Object -First 1; "
    "$a = Get-NetIPAddress -InterfaceIndex $r.ifIndex -AddressFamily IPv4 | "
    "Select-Object -First 1; "
    "$p = Get-NetConnectionProfile -InterfaceIndex $r.ifIndex "
    "-ErrorAction SilentlyContinue | Select-Object -First 1; "
    "[pscustomobject]@{iface=[string]$r.InterfaceAlias; gateway_ip=[string]$r.NextHop; "
    "gateway_mac=[string]$n.LinkLayerAddress; ip=[string]$a.IPAddress; "
    "prefix=[int]$a.PrefixLength; ssid=[string]$p.Name; "
    "windows_category=[string]$p.NetworkCategory} | ConvertTo-Json -Compress"
)


def detect_network_wsl():
    """Under WSL the WSL NAT gateway is not the real router, so ask Windows. Also
    records the WSL-internal NAT gateway (the source IP the daemon sees for every LAN
    connection under NAT) as wsl_nat_gateway."""
    if not have_cmd("powershell.exe"):
        return None
    out = _run_out(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", WSL_NETINFO_PS],
        timeout=25,
        cwd=_win_cwd(),
    )
    lines = [ln.strip() for ln in out.splitlines() if ln.strip().startswith("{")]
    if not lines:
        return None
    try:
        d = json.loads(lines[-1])
    except Exception:
        return None
    if not isinstance(d, dict):
        return None
    d["wsl_nat_gateway"] = linux_default_route()[0]
    return d


def normalize_netinfo(d):
    """Canonical netinfo dict or None. Fills subnet from ip+prefix, lowercases the MAC
    to colon form, drops anything unparseable (a field that cannot be trusted is
    None, so matching then fails closed)."""
    if not isinstance(d, dict):
        return None
    ip = d.get("ip") if isinstance(d.get("ip"), str) and IPV4_RE.match(d.get("ip")) else None
    subnet = None
    try:
        if d.get("subnet"):
            subnet = str(ipaddress.IPv4Network(str(d["subnet"]), strict=False))
        elif ip and d.get("prefix") not in (None, ""):
            subnet = str(ipaddress.IPv4Interface("%s/%d" % (ip, int(d["prefix"]))).network)
    except (ValueError, TypeError):
        subnet = None
    out = {
        "iface": d.get("iface") or None,
        "ip": ip,
        "subnet": subnet,
        "gateway_ip": d.get("gateway_ip") or None,
        "gateway_mac": normalize_mac(d.get("gateway_mac")),
        "ssid": d.get("ssid") or None,
    }
    if d.get("windows_category"):
        out["windows_category"] = str(d["windows_category"])
    if d.get("wsl_nat_gateway"):
        out["wsl_nat_gateway"] = str(d["wsl_nat_gateway"])
    return out


def detect_network():
    """The current network as a normalized dict, or None when unknown. TEST-ONLY
    override: CREDO_PEER_LAN_NETINFO holds a JSON object (or "@/path/file.json")
    that replaces detection entirely; "null", unreadable or invalid -> unknown."""
    raw = os.environ.get("CREDO_PEER_LAN_NETINFO")
    if raw is not None:
        try:
            if raw.startswith("@"):
                with open(raw[1:]) as fh:
                    raw = fh.read()
            return normalize_netinfo(json.loads(raw))
        except Exception:
            return None
    try:
        d = detect_network_wsl() if is_wsl() else detect_network_linux()
    except Exception as exc:
        log("network detection failed: %s" % exc)
        return None
    return normalize_netinfo(d)


def match_network(networks, net):
    """Name of the bound network the detected one matches, else None. A match needs
    BOTH the router MAC to be equal AND the detected IP to lie inside the bound
    subnet. Unknown detection or missing fields never match (fail-closed)."""
    if not net or not isinstance(networks, dict):
        return None
    mac, ip = net.get("gateway_mac"), net.get("ip")
    if not mac or not ip:
        return None
    for name in sorted(networks):
        prof = networks[name]
        if not isinstance(prof, dict):
            continue
        fp = prof.get("fingerprint") or {}
        if not isinstance(fp, dict) or normalize_mac(fp.get("gateway_mac")) != mac:
            continue
        try:
            if ipaddress.IPv4Address(ip) in ipaddress.IPv4Network(
                str(fp.get("subnet")), strict=False
            ):
                return name
        except ValueError:
            continue
    return None


def network_group(prof):
    g = prof.get("group") if isinstance(prof, dict) else None
    return g if isinstance(g, str) and g.strip() else "home"


def compute_lan_state(cfg, net, peers, wsl=False):
    """Effective LAN state for the detected network. FAIL-CLOSED: no networks
    (legacy config), unknown detection, no match, a Windows network category outside
    windows_profiles (WSL), or an empty effective allowlist -> enabled False.
    When the current network matches profile P, the allowlist is the union of the
    allow entries of ALL networks in P's group (so two home WLANs in one group may
    talk to each other)."""
    st = {
        "enabled": False,
        "reason": "",
        "network": None,
        "group": None,
        "label": None,
        "allow": [],
        "ranges": [],
        "warnings": [],
        "errors": [],
        "netinfo": net,
        "windows_profiles": windows_profiles(cfg),
    }
    networks = cfg.get("networks")
    if not isinstance(networks, dict) or not networks:
        st["reason"] = (
            "no network is bound (legacy or new config) - run 'credo-peer-lan.py bind' "
            "while connected to a trusted network"
        )
        return st
    if net is None:
        st["reason"] = "network detection failed (unknown network)"
        return st
    name = match_network(networks, net)
    if name is None:
        st["reason"] = "current network (router %s, subnet %s) is not bound" % (
            net.get("gateway_mac") or "?",
            net.get("subnet") or "?",
        )
        return st
    group = network_group(networks[name])
    st["network"], st["group"] = name, group
    st["label"] = networks[name].get("label")
    entries = []
    for other in sorted(networks):
        prof = networks[other]
        if not isinstance(prof, dict) or network_group(prof) != group:
            continue
        allow = prof.get("allow", ["peers"])
        if isinstance(allow, list):
            entries.extend(allow)
        else:
            st["errors"].append("network %s: allow must be a list" % other)
    built = build_allowlist(entries, peers)
    st["allow"], st["ranges"] = built["allow"], built["ranges"]
    st["warnings"].extend(built["warnings"])
    st["errors"].extend(built["errors"])
    if wsl and net.get("windows_category"):
        prof = WIN_CATEGORY_TO_PROFILE.get(net["windows_category"])
        if prof not in st["windows_profiles"]:
            st["reason"] = (
                "Windows classifies this network as %s, which is not in "
                "windows_profiles %s" % (net["windows_category"], st["windows_profiles"])
            )
            return st
    if not st["allow"]:
        st["reason"] = "the effective allowlist is empty"
        return st
    st["enabled"] = True
    st["reason"] = "network %s (group %s) is bound" % (name, group)
    return st


def source_allowed(src_ip, state, wsl=False):
    """Inbound gate, evaluated BEFORE any byte is read. Loopback is always allowed
    (same-machine use). Otherwise the LAN side must be enabled and the source inside
    the effective allowlist. Under WSL2 NAT every LAN connection arrives from the
    WSL NAT gateway (the Windows host), so the daemon cannot see the real peer IP;
    there the gateway is accepted while LAN is enabled and the REAL per-source filter
    is the Windows firewall rule (RemoteAddress = the same allowlist, see
    credo-peer-lan-winproxy.ps1). In WSL mirrored mode real IPs arrive and the
    allowlist applies directly."""
    if is_loopback_ip(src_ip):
        return True
    if not state or not state.get("enabled"):
        return False
    if wsl:
        gw = (state.get("netinfo") or {}).get("wsl_nat_gateway")
        if gw and src_ip == gw:
            return True
    return ip_in_ranges(src_ip, state.get("ranges", []))


def peer_allowed_outbound(host, state):
    """Outbound gate for rosters/forwards: loopback always; LAN peers only while the
    LAN side is enabled AND the peer IP is inside the effective allowlist (so no
    session names leak on a foreign network)."""
    if is_loopback_ip(host):
        return True
    if not state or not state.get("enabled"):
        return False
    return ip_in_ranges(host, state.get("ranges", []))


# ---------------------------------------------------------------------------
# config writing (0600: the file may hold the token)
# ---------------------------------------------------------------------------
def write_config(cfg, path=None):
    path = path or config_path()
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(json.dumps(cfg, indent=2) + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------------------
# WSL2: Windows firewall allowlist sync. The daemon writes the effective allowlist
# as a DATA file into the user's %LOCALAPPDATA%\credo; the elevated scheduled task
# (installed copy in %ProgramData%\credo) re-validates every entry itself and applies
# it to the firewall rule. The data file is never trusted blindly.
# ---------------------------------------------------------------------------
PS_VERSION_RE = re.compile(r'^\$ScriptVersion\s*=\s*"?(\d+)"?', re.M)


def win_env_dir(var):
    """WSL path of a Windows environment directory (LOCALAPPDATA, ProgramData), or
    None. Read-only: cmd.exe echo + wslpath."""
    if not (have_cmd("cmd.exe") and have_cmd("wslpath")):
        return None
    out = _run_out(["cmd.exe", "/c", "echo %" + var + "%"], timeout=10, cwd=_win_cwd())
    val = out.strip().splitlines()[-1].strip() if out.strip() else ""
    if not val or "%" in val:
        return None
    p = _run_out(["wslpath", "-u", val], timeout=5).strip()
    return p or None


def win_port_suffix(port):
    """Per-port file-name suffix shared with credo-peer-lan-winproxy.ps1, so two relay
    instances (different listen ports, own tasks) never overwrite each other's data
    or applied-state file. The default port keeps the original single-instance names
    (backward compatible with an existing -Install)."""
    try:
        port = int(port)
    except (TypeError, ValueError):
        port = DEFAULT_PORT
    return "" if port == DEFAULT_PORT else "-%d" % port


def win_allow_name(port=DEFAULT_PORT):
    return "peer-lan-allow%s.json" % win_port_suffix(port)


def win_applied_name(port=DEFAULT_PORT):
    return "peer-lan-applied%s.json" % win_port_suffix(port)


def win_allow_file(port=DEFAULT_PORT):
    ov = os.environ.get("CREDO_PEER_LAN_WINALLOW_FILE")
    if ov:
        return ov
    base = win_env_dir("LOCALAPPDATA")
    return os.path.join(base, "credo", win_allow_name(port)) if base else None


def win_programdata_dir():
    ov = os.environ.get("CREDO_PEER_LAN_WINPROGRAMDATA")
    if ov:
        return ov
    base = win_env_dir("ProgramData")
    return os.path.join(base, "credo") if base else None


def win_allow_payload(state, port):
    enabled = bool(state.get("enabled"))
    return {
        "version": 1,
        "enabled": enabled,
        "allow": list(state.get("allow", [])) if enabled else [],
        "windows_profiles": list(state.get("windows_profiles") or ["Private"]),
        "port": int(port),
        "network": state.get("network"),
        "group": state.get("group"),
    }


def write_win_allow_file(path, payload):
    """Atomically write the data file, ONLY when its content changes. Returns True
    when it was (re)written, False when it already had this content."""
    text = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    try:
        with open(path) as fh:
            if fh.read() == text:
                return False
    except OSError:
        pass
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w") as fh:
        fh.write(text)
    os.replace(tmp, path)
    return True


def trigger_win_task():
    """Best-effort, non-blocking: ask the Task Scheduler to run the elevated refresh
    task (same pattern as the autostart hook). Honors CREDO_PEER_LAN_WINPROXY=off."""
    if str(os.environ.get("CREDO_PEER_LAN_WINPROXY", "1")).lower() in ("0", "false", "no", "off"):
        return False
    if not have_cmd("powershell.exe"):
        return False
    task = os.environ.get("CREDO_PEER_LAN_WINPROXY_TASK") or DEFAULT_WIN_TASK
    if not re.match(r"^[A-Za-z0-9._ -]+$", task):
        return False
    try:
        subprocess.Popen(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
             "schtasks /Run /TN '%s'" % task],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            cwd=_win_cwd(),
            start_new_session=True,
        )
        return True
    except Exception:
        return False


def ps_script_version(path):
    try:
        with open(path, encoding="utf-8-sig") as fh:
            m = PS_VERSION_RE.search(fh.read())
    except OSError:
        return None
    return int(m.group(1)) if m else None


def win_firewall_status(state, port):
    """Human-readable lines about the WSL Windows firewall sync (read-only)."""
    lines = []
    plugin_ps = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "credo-peer-lan-winproxy.ps1"
    )
    want = ps_script_version(plugin_ps)
    pd = win_programdata_dir()
    if pd is None:
        lines.append("installed task script: unknown (cannot resolve %ProgramData%)")
    else:
        have = ps_script_version(os.path.join(pd, "credo-peer-lan-winproxy.ps1"))
        if have is None:
            lines.append(
                "installed task script: NOT installed in %ProgramData%\\credo - run "
                "the elevated -Install once (see /credo:peer-lan)"
            )
        elif want is not None and have < want:
            lines.append(
                "installed task script: OUTDATED (installed v%d, plugin v%d) - re-run "
                "the elevated -Install once (one UAC prompt)" % (have, want)
            )
        else:
            lines.append("installed task script: v%d (current)" % have)
    path = win_allow_file(port)
    want_payload = win_allow_payload(state, port)
    if path is None:
        lines.append("allowlist data file: unknown (cannot resolve %LOCALAPPDATA%)")
    else:
        try:
            with open(path) as fh:
                cur = json.load(fh)
        except Exception:
            cur = None
        if cur is None:
            lines.append("allowlist data file: missing (%s) - the daemon writes it" % path)
        elif cur == want_payload:
            lines.append("allowlist data file: up to date (%s)" % path)
        else:
            lines.append("allowlist data file: STALE (%s) - the running daemon rewrites it on its next network check" % path)
    if pd is not None:
        try:
            with open(os.path.join(pd, win_applied_name(port)), encoding="utf-8-sig") as fh:
                applied = json.load(fh)
        except Exception:
            applied = None
        if not isinstance(applied, dict):
            lines.append("firewall rule: no applied state recorded yet")
        else:
            on = bool(applied.get("enabled"))
            lines.append(
                "firewall rule: %s, RemoteAddress=%s, Profile=%s (applied %s)"
                % (
                    "ENABLED" if on else "DISABLED",
                    ",".join(applied.get("remote_address") or []) or "-",
                    ",".join(applied.get("profiles") or []) or "-",
                    applied.get("applied_at", "?"),
                )
            )
            in_sync = on == want_payload["enabled"] and (
                not on or sorted(applied.get("remote_address") or []) == sorted(want_payload["allow"])
            )
            lines.append("firewall sync: %s" % ("in sync" if in_sync else "PENDING (task not run yet or failed)"))
    return lines


def print_lan_status(cfg, state):
    net = state.get("netinfo")
    if net:
        print(
            "Network:   %s, subnet %s, router %s (%s, this IP %s)"
            % (
                net.get("ssid") or "(no label)",
                net.get("subnet") or "?",
                net.get("gateway_mac") or "?",
                net.get("iface") or "?",
                net.get("ip") or "?",
            )
        )
    else:
        print("Network:   unknown (detection failed)")
    if state.get("network"):
        print("Profile:   %s (group %s)" % (state["network"], state["group"]))
    else:
        print("Profile:   none matched")
    if state.get("enabled"):
        print("LAN relay: ENABLED - %s" % state["reason"])
    else:
        print("LAN relay: DISABLED - %s (loopback/same-machine use still works)" % state["reason"])
    print("Allowlist: %s" % (", ".join(state["allow"]) if state["allow"] else "(empty)"))
    for w in state.get("warnings", []):
        print(w)
    for e in state.get("errors", []):
        print("ERROR: invalid entry dropped: %s" % e)
    print("Token:     %s" % ("set" if cfg.get("token") else "none (optional)"))
    if is_wsl():
        if net and net.get("windows_category"):
            print("Windows:   network category %s, windows_profiles %s" % (net["windows_category"], state["windows_profiles"]))
        for line in win_firewall_status(state, int(cfg.get("listen_port", DEFAULT_PORT))):
            print("WSL sync:  %s" % line)


UFW_COMMENT = "credo-peer-lan"


def _ufw_sources(entry):
    """ufw source spec(s) for one canonical allowlist entry. ufw has no range syntax,
    so an a-b range is split into the minimal list of covering CIDRs."""
    if "-" in entry:
        lo, hi = entry.split("-", 1)
        nets = ipaddress.summarize_address_range(
            ipaddress.IPv4Address(lo.strip()), ipaddress.IPv4Address(hi.strip())
        )
        return [n.with_prefixlen if n.prefixlen < 32 else str(n.network_address) for n in nets]
    return [entry]


def parse_ufw_status(text, port):
    """Parse `ufw status` output. Returns (active, rules) where rules is a list of
    {"source", "comment"} for IPv4 ALLOW rules whose target is `port` or `port/tcp`.
    IPv6 rows are ignored (the relay is IPv4)."""
    active = "Status: active" in (text or "")
    rules = []
    rule_re = re.compile(
        r"^(?P<to>\S+)(?:\s+on\s+\S+)?\s+ALLOW(?:\s+IN)?\s+"
        r"(?P<src>\S+)(?:\s+on\s+\S+)?\s*(?:#\s*(?P<comment>.*))?$"
    )
    for line in (text or "").splitlines():
        line = line.strip()
        if "(v6)" in line:
            continue
        m = rule_re.match(line)
        if not m or m.group("to") not in (str(port), "%d/tcp" % port):
            continue
        src = m.group("src")
        if src == "Anywhere":
            src = "0.0.0.0/0"
        rules.append({"source": src, "comment": (m.group("comment") or "").strip()})
    return active, rules


def ufw_rule_commands(allow, port, rules):
    """Pure command generator. Returns (missing_sources, add_cmds, delete_cmds).
    A needed source counts as covered when an existing ALLOW rule's source network
    contains it. Delete hints are produced only for rules that carry the
    credo-peer-lan comment (never for the user's own rules) and are no longer needed."""
    needed = []
    for entry in allow or []:
        for src in _ufw_sources(entry):
            if src not in needed:
                needed.append(src)
    existing = []
    for r in rules or []:
        try:
            existing.append((ipaddress.ip_network(r["source"], strict=False), r))
        except ValueError:
            continue
    missing = []
    for src in needed:
        net = ipaddress.ip_network(src, strict=False)
        if not any(net.version == e.version and net.subnet_of(e) for e, _r in existing):
            missing.append(src)
    add_cmds = [
        "sudo ufw allow from %s to any port %d proto tcp comment '%s'" % (src, port, UFW_COMMENT)
        for src in missing
    ]
    needed_nets = set(str(ipaddress.ip_network(s, strict=False)) for s in needed)
    delete_cmds = []
    for e, r in existing:
        if r["comment"] == UFW_COMMENT and str(e) not in needed_nets:
            cmd = "sudo ufw delete allow from %s to any port %d proto tcp" % (r["source"], port)
            if cmd not in delete_cmds:
                delete_cmds.append(cmd)
    return missing, add_cmds, delete_cmds


def firewalld_rule_commands(allow, port):
    """firewalld equivalent. Its rules cannot be read without root, so these are
    printed as "add if not present"; --permanent plus --reload keeps them across boots."""
    cmds = []
    for entry in allow or []:
        for src in _ufw_sources(entry):
            cmds.append(
                "sudo firewall-cmd --permanent --add-rich-rule='rule family=\"ipv4\" "
                "source address=\"%s\" port port=\"%d\" protocol=\"tcp\" accept'" % (src, port)
            )
    if cmds:
        cmds.append("sudo firewall-cmd --reload")
    return cmds


UFW_RULES_UNREADABLE = "#rules-unreadable"


def _ufw_status_text():
    """`ufw status` output, or None when ufw is absent/unknown. CREDO_PEER_LAN_UFW_STATUS
    (the text itself, or "@/path/file") replaces the call for deterministic tests.
    Without root `ufw status` refuses; then the world-readable /etc/ufw/ufw.conf
    (ENABLED=yes) still tells whether ufw is active, with the rules marked unknown."""
    raw = os.environ.get("CREDO_PEER_LAN_UFW_STATUS")
    if raw is not None:
        if raw.startswith("@"):
            try:
                with open(raw[1:]) as fh:
                    return fh.read()
            except OSError:
                return None
        return raw
    if not have_cmd("ufw"):
        return None
    try:
        out = subprocess.run(["ufw", "status"], capture_output=True, text=True, timeout=5)
        text = out.stdout or ""
    except Exception:
        text = ""
    if "Status:" in text:
        return text
    try:
        with open("/etc/ufw/ufw.conf") as fh:
            if re.search(r"^\s*ENABLED\s*=\s*yes\s*$", fh.read(), re.M):
                return "Status: active\n%s\n" % UFW_RULES_UNREADABLE
    except OSError:
        pass
    return None


def _firewalld_running():
    """Cheap firewalld detection (`firewall-cmd --state`). CREDO_PEER_LAN_FIREWALLD_STATE
    replaces the call for tests."""
    raw = os.environ.get("CREDO_PEER_LAN_FIREWALLD_STATE")
    if raw is not None:
        return raw.strip() == "running"
    if not have_cmd("firewall-cmd"):
        return False
    try:
        out = subprocess.run(["firewall-cmd", "--state"], capture_output=True, text=True, timeout=5)
        return (out.stdout or "").strip() == "running"
    except Exception:
        return False


def check_firewall_hint(cfg, state=None):
    """Native-Linux-only, read-only, best-effort firewall hint. It NEVER runs sudo and
    NEVER changes anything; any error (ufw absent, unreadable) is swallowed. When ufw
    is active and the LAN side is enabled it prints copy-paste-ready commands: one
    `ufw allow ... comment 'credo-peer-lan'` per allowlist entry not yet covered, plus
    `ufw delete` hints for credo-peer-lan rules whose entry was removed. The user runs
    them (sudo needs the user's password; in Claude Code with the `!` prefix). On WSL
    there is no local firewall to consult (the Windows firewall is synced from the
    allowlist instead), so this is a no-op there."""
    if is_wsl():
        return
    port = int(cfg.get("listen_port", DEFAULT_PORT))
    enabled = bool(state and state.get("enabled"))
    allow = state["allow"] if enabled else []
    status = _ufw_status_text()
    if status is not None:
        active, rules = parse_ufw_status(status, port)
        unreadable = UFW_RULES_UNREADABLE in status
        if active and not enabled:
            if not rules:
                print(
                    "WARNING: ufw is active and port %d has no ALLOW rule%s - the relay port "
                    "may be blocked on this machine. Once a network is bound, allow it "
                    "scoped to the allowlist, e.g.:\n"
                    "  sudo ufw allow from <peer-ip-or-subnet> to any port %d proto tcp comment '%s'"
                    % (port, " (rules unreadable without root)" if unreadable else "", port, UFW_COMMENT)
                )
        elif active:
            missing, add_cmds, del_cmds = ufw_rule_commands(allow, port, rules)
            if unreadable:
                print(
                    "FIREWALL: ufw is active; its rules are not readable without root "
                    "(verify with: sudo ufw status). If port %d is not allowed yet, run "
                    "(in Claude Code with the ! prefix):" % port
                )
                print("\n".join("  " + c for c in add_cmds))
            elif add_cmds or del_cmds:
                if add_cmds:
                    print(
                        "FIREWALL: ufw is active and port %d is not allowed for: %s - peers "
                        "cannot reach this relay. Run (sudo asks for your password; in Claude "
                        "Code type each line with the ! prefix):" % (port, ", ".join(missing))
                    )
                    print("\n".join("  " + c for c in add_cmds))
                if del_cmds:
                    print(
                        "FIREWALL: stale credo-peer-lan ufw rules (allowlist entries removed), "
                        "clean up with:"
                    )
                    print("\n".join("  " + c for c in del_cmds))
            else:
                print("Firewall:  ufw active, port %d allowed for the effective allowlist" % port)
    if enabled and _firewalld_running():
        print(
            "FIREWALL: firewalld is running (rules not checked). If port %d is not allowed "
            "yet, run (in Claude Code with the ! prefix):" % port
        )
        print("\n".join("  " + c for c in firewalld_rule_commands(allow, port)))


# ---------------------------------------------------------------------------
# line transport (HMAC-signed when a token is configured, unsigned otherwise)
# ---------------------------------------------------------------------------
def sign(token, body_str):
    return hmac.new(
        token.encode("utf-8"), body_str.encode("utf-8"), hashlib.sha256
    ).hexdigest()


def frame_for(token, payload):
    body = json.dumps(payload, separators=(",", ":"), sort_keys=True)
    if token:
        wire = {"mac": sign(token, body), "body": body}
    else:
        wire = {"body": body}
    return json.dumps(wire) + "\n"


def verify_line(token, line):
    """Return the payload dict for an acceptable line, else None.
    With a token the line MUST carry a matching HMAC (reject on mismatch or when
    unsigned). Token-less, an unsigned body is accepted as-is (any mac is ignored)."""
    try:
        wire = json.loads(line)
    except Exception:
        return None
    if not isinstance(wire, dict):
        return None
    body = wire.get("body")
    if not isinstance(body, str):
        return None
    if token:
        mac = wire.get("mac")
        if not isinstance(mac, str):
            return None
        if not hmac.compare_digest(sign(token, body), mac):
            return None
    try:
        payload = json.loads(body)
    except Exception:
        return None
    return payload if isinstance(payload, dict) else None


def send_to_peer(host, port, token, payload, timeout=5.0):
    # TEST-ONLY: CREDO_PEER_LAN_TEST_SENDLOG records "<kind> <host>:<port>" lines
    # instead of connecting, so the test suite can assert outbound enforcement for
    # LAN-shaped peer addresses without ever touching a real LAN.
    testlog = os.environ.get("CREDO_PEER_LAN_TEST_SENDLOG")
    if testlog:
        with open(testlog, "a") as fh:
            fh.write("%s %s:%s\n" % (payload.get("kind"), host, port))
        return
    line = frame_for(token, payload).encode("utf-8")
    s = socket.create_connection((host, port), timeout=timeout)
    try:
        s.sendall(line)
        s.shutdown(socket.SHUT_WR)
    finally:
        s.close()


# ---------------------------------------------------------------------------
# descriptor / proc helpers
# ---------------------------------------------------------------------------
def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError):
        return False


def read_pidfile():
    """Parsed pidfile dict, or None when it is missing or corrupt. Never raises, so a
    garbled file is treated as "no reliable state" (conservative: ensure then leaves a
    running daemon untouched rather than acting on bad data)."""
    try:
        with open(pidfile_path()) as fh:
            d = json.load(fh)
    except Exception:
        return None
    return d if isinstance(d, dict) else None


def daemon_is_alive(pid):
    """True only when pid is a live credo-peer-lan daemon. Requires os.kill(pid,0) AND,
    when /proc is available, that /proc/<pid>/cmdline mentions credo-peer-lan.py (so a
    reused pid belonging to an unrelated process is never mistaken for our daemon). When
    /proc is absent, falls back to os.kill alone."""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    if os.path.isdir("/proc"):
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as fh:
                return b"credo-peer-lan.py" in fh.read()
        except OSError:
            # /proc present but this pid's entry vanished -> it is not alive
            return False
    return True  # no /proc at all -> trust os.kill


def version_tuple(s):
    """Parse "X.Y.Z" into an int tuple for comparison. None for "unknown" or anything
    unparseable, so an unknown/garbled version is never compared (conservative: ensure
    then leaves the incumbent untouched instead of guessing newer/older)."""
    if not isinstance(s, str):
        return None
    parts = s.strip().split(".")
    if len(parts) != 3:
        return None
    try:
        return tuple(int(p) for p in parts)
    except ValueError:
        return None


def port_is_free(host, port):
    """True if a throwaway TCP bind on host:port succeeds (SO_REUSEADDR, closed at
    once). While a daemon actively listens on the port the bind fails, so this doubles
    as a liveness probe for the listen port. Never raises."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((host, int(port)))
        return True
    except OSError:
        return False
    finally:
        try:
            s.close()
        except OSError:
            pass


def _terminate_incumbent(pid, host, port, timeout=TERMINATE_TIMEOUT):
    """SIGTERM pid, then poll up to timeout until the pid is gone AND the listen port is
    free. Returns True iff the port became free (so a replacement can bind), else False.
    Never raises - it is called where leaving a running daemon alone is the safe default."""
    try:
        os.kill(int(pid), signal.SIGTERM)
    except (OSError, ValueError, TypeError):
        pass
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not daemon_is_alive(pid) and port_is_free(host, port):
            return True
        time.sleep(0.2)
    return port_is_free(host, port)


def proc_start(pid):
    """Field 22 (starttime) of /proc/<pid>/stat as a string, robust to a comm
    containing spaces or parentheses."""
    with open("/proc/%d/stat" % int(pid)) as fh:
        data = fh.read()
    rparen = data.rfind(")")
    if rparen < 0:
        raise ValueError("no comm close paren")
    rest = data[rparen + 2 :].split()
    # overall field 3 (state) is rest[0]; field 22 (starttime) is rest[19]
    return rest[19]


def read_local_sessions(sess_dir):
    """Real local session descriptors only (not our mirrors, not bridge mirrors),
    returning the parsed dicts that have a socket and a sessionId."""
    out = []
    try:
        names = os.listdir(sess_dir)
    except OSError:
        return out
    for name in names:
        if not name.endswith(".json"):
            continue
        base = name[:-5]
        if not base.isdigit():
            continue
        path = os.path.join(sess_dir, name)
        if os.path.islink(path):
            continue
        try:
            with open(path) as fh:
                d = json.load(fh)
        except Exception:
            continue
        if not isinstance(d, dict):
            continue
        if d.get(MARK) or d.get("credoPeerBridge"):
            continue
        if d.get("sessionId") and d.get("messagingSocketPath"):
            out.append(d)
    return out


def local_real_session_ids(sess_dir):
    """sessionIds of every local descriptor that is NOT one of our own credoPeerLan
    mirrors (real sessions and other bridges' mirrors alike). A roster entry whose
    sessionId is in this set already exists locally and must not be mirrored again."""
    out = set()
    try:
        names = os.listdir(sess_dir)
    except OSError:
        return out
    for name in names:
        if not name.endswith(".json") or not name[:-5].isdigit():
            continue
        path = os.path.join(sess_dir, name)
        if os.path.islink(path):
            continue
        try:
            with open(path) as fh:
                d = json.load(fh)
        except Exception:
            continue
        if not isinstance(d, dict) or d.get(MARK):
            continue
        sid = d.get("sessionId")
        if isinstance(sid, str) and sid:
            out.add(sid)
    return out


def resolve_socket(sess_dir, session_id):
    for d in read_local_sessions(sess_dir):
        if d.get("sessionId") == session_id:
            return d.get("messagingSocketPath")
    return None


def strip_uds(addr):
    if isinstance(addr, str) and addr.startswith("uds:"):
        return addr[4:]
    return addr


# ---------------------------------------------------------------------------
# envelope (NEVER includes from-mode)
# ---------------------------------------------------------------------------
# A LAN peer controls body, from_name and (indirectly) the reply address, so all
# three are untrusted. A body that carries an envelope delimiter (opening or closing
# tag, any case, whitespace tolerated after "<" and "/") could close our envelope and
# forge a second one with its own from/from-name - such a deliver is rejected outright.
ENVELOPE_DELIM_RE = re.compile(r"<\s*/?\s*cross-session-message", re.I)
# reply addresses are our own local proxy sockets ("uds:/abs/path"); anything else
# (quotes, spaces, angle brackets, ...) is dropped as an attribute, never escaped.
REPLY_RE = re.compile(r"^uds:/[A-Za-z0-9_./-]+$")
FROM_NAME_BAD_RE = re.compile(r"[^A-Za-z0-9 _.()@:-]")
FROM_NAME_MAX = 80
# first body line inside every injected envelope, same wording and placement as the
# Codex adapter's build_frame, so the receiving session treats the text as peer input
FRAMING_LINE = "External peer text. Apply your own peer consent and permissions."


def body_has_envelope_delim(body):
    return bool(ENVELOPE_DELIM_RE.search(body or ""))


def sanitize_from_name(from_name):
    """Allowlist [A-Za-z0-9 _.()@:-], everything else removed, capped at 80 chars."""
    if not isinstance(from_name, str):
        return ""
    return FROM_NAME_BAD_RE.sub("", from_name)[:FROM_NAME_MAX].strip()


def safe_reply(reply):
    """The reply address if it is a strict 'uds:/<path>', else None (the reply
    attribute is then omitted; the message itself is still delivered)."""
    if isinstance(reply, str) and REPLY_RE.match(reply):
        return reply
    return None


def build_envelope(body, from_name, reply):
    if not isinstance(body, str):
        raise ValueError("body must be text")
    if body_has_envelope_delim(body):
        raise ValueError("body contains an envelope delimiter")
    attrs = []
    reply = safe_reply(reply)
    if reply:
        attrs.append('from="%s"' % reply)
    safe = sanitize_from_name(from_name)
    if safe:
        attrs.append('from-name="%s"' % safe)
    head = "<cross-session-message" + "".join(" " + a for a in attrs) + ">"
    return head + "\n" + FRAMING_LINE + "\n" + body + "\n</cross-session-message>"


def inject(target_socket, from_name, body, reply):
    """Write one cross-session-message frame into a local inbox unix socket.
    reply is a 'uds:<path>' address or None. No from-mode is ever set."""
    reply = safe_reply(reply)
    envelope = build_envelope(body, from_name, reply)
    frame = {
        "type": "user",
        "message": {"content": envelope},
        "uuid": str(uuid.uuid4()),
        "priority": "next",
    }
    if reply:
        frame["from"] = reply
    line = (json.dumps(frame) + "\n").encode("utf-8")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    try:
        s.connect(target_socket)
        s.sendall(line)
        s.shutdown(socket.SHUT_WR)
    finally:
        s.close()


# ===========================================================================
# HOLDER subprocess: one per remote session. Listens on the proxy socket and
# forwards every frame a local session writes into it as a "deliver" to the
# owning remote daemon over TCP.
# ===========================================================================
def run_holder(args):
    cfg = load_config()
    if cfg is None:
        log("holder: no config, exiting")
        return 1
    token = cfg.get("token", "")
    # Routing is address-based: the holder forwards straight to the peer host:port
    # it was spawned with. No name lookup, so no name contract to get wrong.
    host, port = args.peer_host, int(args.peer_port)
    sess_dir = sessions_dir()
    proxy = args.proxy
    parent = os.getppid()

    try:
        os.unlink(proxy)
    except OSError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        srv.bind(proxy)
    except OSError as exc:
        log("holder: cannot bind %s: %s" % (proxy, exc))
        return 1
    srv.listen(16)
    # wake accept() periodically so an orphaned holder (parent daemon SIGKILLed or
    # power-lost, so we got reparented to init) can notice and exit cleanly, rather
    # than lingering and blocking a new daemon from reaping its descriptor.
    srv.settimeout(HOLDER_ACCEPT_TIMEOUT)

    stop = {"v": False}

    def _sig(_signo, _frame):
        stop["v"] = True
        try:
            srv.close()
        except OSError:
            pass

    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)
    log(
        "holder up: proxy=%s target=%s via %s:%s"
        % (proxy, args.target_session, host, port)
    )

    # Each accepted proxy connection is handled in its own short-lived daemon worker
    # thread, bounded by this semaphore, so a local client that opens the proxy and
    # stalls cannot delay other local writers (no head-of-line block). The accept
    # loop keeps its periodic wakeup so an orphaned holder still self-exits.
    worker_sem = threading.Semaphore(MAX_HOLDER_WORKERS)

    def _serve(conn):
        try:
            try:
                conn.settimeout(5)
                buf = b""
                while True:
                    try:
                        chunk = conn.recv(65536)
                    except socket.timeout:
                        break
                    if not chunk:
                        break
                    buf += chunk
            finally:
                conn.close()
            for line in buf.splitlines():
                line = line.strip()
                if not line:
                    continue
                _forward(line, token, host, port, args, sess_dir)
        except Exception as exc:
            log("holder: worker error: %s" % exc)
        finally:
            worker_sem.release()

    workers = []
    try:
        while not stop["v"]:
            workers = [w for w in workers if w.is_alive()]
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                if os.getppid() != parent:
                    log("holder: parent gone, exiting")
                    break
                continue
            except OSError:
                break
            if not worker_sem.acquire(timeout=ACQUIRE_TIMEOUT):
                log(
                    "holder: worker cap reached (%d); dropping a proxy connection"
                    % MAX_HOLDER_WORKERS
                )
                try:
                    conn.close()
                except OSError:
                    pass
                continue
            try:
                t = threading.Thread(target=_serve, args=(conn,), daemon=True)
                t.start()
                workers.append(t)
            except Exception as exc:
                worker_sem.release()
                log("holder: could not start worker: %s" % exc)
                try:
                    conn.close()
                except OSError:
                    pass
    finally:
        try:
            os.unlink(proxy)
        except OSError:
            pass
        for w in workers:
            w.join(timeout=1.0)
    return 0


def _forward(line, token, host, port, args, sess_dir):
    try:
        frame = json.loads(line.decode("utf-8"))
    except Exception:
        log("holder: unparseable frame dropped")
        return
    content = ""
    if isinstance(frame, dict):
        msg = frame.get("message")
        if isinstance(msg, dict):
            content = msg.get("content") or ""
    m = ENVELOPE_RE.search(content)
    body = m.group(1).strip() if m else content
    nm = FROM_NAME_RE.search(content)
    from_name = nm.group(1) if nm else ""
    reply = frame.get("from") if isinstance(frame, dict) else None
    from_session = ""
    sock_path = strip_uds(reply)
    if sock_path:
        for d in read_local_sessions(sess_dir):
            if d.get("messagingSocketPath") == sock_path:
                from_session = d.get("sessionId", "")
                break
    payload = {
        "kind": "deliver",
        "target_sessionId": args.target_session,
        "from_sessionId": from_session,
        "from_name": from_name,
        "body": body,
    }
    try:
        send_to_peer(host, port, token, payload)
        log("holder: forwarded deliver to %s:%s" % (host, port))
    except Exception as exc:
        log("holder: forward to %s:%s failed: %s" % (host, port, exc))


# ===========================================================================
# DAEMON
# ===========================================================================
class AlreadyRunning(Exception):
    """Raised when the listen port is already bound by another daemon instance.
    The listen port itself is the single-instance lock, so a second start exits
    cleanly (0) instead of crashing with a traceback."""


class Daemon(object):
    def __init__(self, cfg):
        self.cfg = cfg
        self.token = cfg.get("token", "")
        self.this_machine = cfg.get("this_machine", socket.gethostname())
        self.listen_host = cfg.get("listen_host", "127.0.0.1")
        self.listen_port = int(cfg.get("listen_port", DEFAULT_PORT))
        # how long start() poll-retries the bind on EADDRINUSE before giving up cleanly
        # (config keys bind_retry_total / bind_retry_interval; tests shorten the window)
        self.bind_retry_total = float(cfg.get("bind_retry_total", BIND_RETRY_TOTAL))
        self.bind_retry_interval = float(
            cfg.get("bind_retry_interval", BIND_RETRY_INTERVAL)
        )
        # Peers are normalized to {host, port, name?} and routing is ADDRESS-based:
        # a peer is identified by its host:port, never by name. A string "IP"/"IP:PORT"
        # and the legacy {name, host, port} object are both accepted.
        self.peers = normalize_peers(cfg.get("peers", []), self.listen_port)
        # addresses of configured peers; an inbound roster whose source address is
        # NOT in here is "unexpected" inbound (warned once; see _on_roster)
        self.peer_addrs = set((p["host"], p["port"]) for p in self.peers)
        # Address we ADVERTISE to peers so they forward back to us at our real LAN
        # address, never at the raw inbound source IP. Under WSL2 NAT the source IP a
        # peer sees is the WSL gateway (e.g. 172.23.x.1), NOT this machine - so a
        # receiver keying us by that source IP would forward to its own gateway and
        # time out. Each daemon therefore announces detect_self_ip() (the Windows host
        # LAN IP under WSL, the default-route src natively) plus listen_port, and the
        # receiver pairs that against its configured peers. An explicit config
        # "advertise_host" (and optional "advertise_port") skips auto-detection; when
        # neither is set it is detected once in a background thread (see start()) so
        # the slow powershell probe under WSL never blocks the roster loop.
        self.advertise_host = cfg.get("advertise_host")
        self.advertise_port = int(cfg.get("advertise_port", self.listen_port))
        self.roster_interval = float(
            cfg.get("roster_interval", DEFAULT_ROSTER_INTERVAL)
        )
        self.machine_timeout = float(
            cfg.get("machine_timeout", DEFAULT_MACHINE_TIMEOUT)
        )
        self.max_remotes = int(
            cfg.get("max_remotes_per_machine", MAX_REMOTES_PER_MACHINE)
        )
        self.max_conn_threads = int(
            cfg.get("max_conn_threads", MAX_CONN_THREADS)
        )
        # bounds concurrent inbound handler threads; the accept loop sheds load
        # rather than blocking when the pool is full (pre-auth exhaustion guard)
        self.conn_sem = threading.Semaphore(self.max_conn_threads)
        self.sess_dir = sessions_dir()
        self.sock_dir = sock_dir()
        self.script = os.path.abspath(__file__)
        self.lock = threading.Lock()
        # key (machine, sessionId) -> dict(holder=Popen, proxy, descriptor, pid)
        self.remotes = {}
        self.machine_seen = {}  # peer addr "host:port" -> last roster monotonic time
        self.unknown_warned = set()  # peer addrs warned once (not a configured peer)
        self.stop = threading.Event()
        self.srv = None
        # LAN allowlist state. FAIL-CLOSED: disabled until the network watcher has
        # detected and matched a bound network (loopback keeps working meanwhile).
        self.wsl = is_wsl()
        self.network_recheck = float(
            cfg.get("network_recheck_interval", DEFAULT_NETWORK_RECHECK)
        )
        self.lan_state = compute_lan_state({}, None, self.peers, self.wsl)
        self.lan_state["reason"] = "network not detected yet"
        self._lan_key = None
        self.rejected_warned = set()  # inbound source IPs rejected (logged once each)
        self.outbound_skip_warned = set()  # peers skipped by the outbound gate
        self.deliver_rejected_warned = set()  # sources whose deliver was rejected (once)
        self.dup_session_warned = set()  # roster sessionIds skipped as duplicates (once)
        self._win_allow_path = None
        self._win_allow_resolved = False

    # -- lifecycle ----------------------------------------------------------
    def start(self):
        try:
            os.makedirs(self.sock_dir, exist_ok=True)
        except OSError as exc:
            log("cannot create sock dir %s: %s" % (self.sock_dir, exc))
        # Bind the listen port FIRST - it is the single-instance lock. On EADDRINUSE we
        # do NOT give up immediately: a restart's old daemon can still hold the port for
        # a moment while we start, so we poll-retry the bind for a bounded window. Only
        # when the window expires still EADDRINUSE do we exit cleanly (0) via
        # AlreadyRunning WITHOUT running any descriptor/socket cleanup, so a genuinely
        # running daemon is never disturbed by a second accidental start.
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        deadline = time.monotonic() + self.bind_retry_total
        while True:
            try:
                self.srv.bind((self.listen_host, self.listen_port))
                break
            except OSError as exc:
                if exc.errno != errno.EADDRINUSE:
                    raise
                if time.monotonic() >= deadline:
                    log(
                        "another daemon already listening on %s:%d, exiting"
                        % (self.listen_host, self.listen_port)
                    )
                    try:
                        self.srv.close()
                    except OSError:
                        pass
                    raise AlreadyRunning()
                time.sleep(self.bind_retry_interval)
        self._cleanup_stale_descriptors()
        self._cleanup_stale_sockets()
        self.srv.listen(32)
        self._write_pidfile()
        log(
            "listening on %s:%d as %r; peers=%s"
            % (
                self.listen_host,
                self.listen_port,
                self.this_machine,
                ["%s:%d" % (p["host"], p["port"]) for p in self.peers],
            )
        )
        if not self.token:
            log(
                "WARNING: running without a shared token - any device that can "
                "reach %s:%d may send messages to your sessions (protected only by "
                "the receiving session's consent gate); set \"token\" in the config "
                "to restrict to your own devices."
                % (self.listen_host, self.listen_port)
            )
        if self.advertise_host:
            log("advertising self address %s:%d in rosters" % (self.advertise_host, self.advertise_port))
        else:
            # detect in the background so a slow powershell probe (WSL) never blocks the
            # roster loop; until it resolves, rosters simply omit the advertise fields
            # (receivers then fall back - see _resolve_peer_addr).
            threading.Thread(target=self._detect_advertise_host, daemon=True).start()
        threading.Thread(target=self._netwatch_loop, daemon=True).start()
        threading.Thread(target=self._accept_loop, daemon=True).start()
        threading.Thread(target=self._roster_loop, daemon=True).start()
        threading.Thread(target=self._janitor_loop, daemon=True).start()

    def _detect_advertise_host(self):
        try:
            ip = detect_self_ip()
        except Exception as exc:
            log("self-address detection failed: %s" % exc)
            return
        if ip:
            self.advertise_host = ip
            log("advertising self address %s:%d in rosters" % (ip, self.advertise_port))
        else:
            log("self-address not detected; rosters omit the advertise fields")

    # -- network watcher (allowlist state) ------------------------------------
    def _netwatch_loop(self):
        """Detect the network at start and then every network_recheck_interval
        seconds, in its own thread so a slow detection (powershell under WSL) never
        blocks the accept or roster loops."""
        while not self.stop.is_set():
            try:
                self.recheck_network()
            except Exception as exc:
                log("network check failed: %s" % exc)
            if self.stop.wait(self.network_recheck):
                break

    def recheck_network(self):
        """Re-detect the network, recompute the effective allowlist (re-reading the
        config's networks/windows_profiles so `bind` applies without a restart), log
        every transition, prune remotes that are no longer allowed, and (WSL) sync
        the Windows firewall data file. Returns the new state."""
        fresh = load_config()
        merged = dict(self.cfg)
        for key in ("networks", "windows_profiles"):
            merged.pop(key, None)
            if isinstance(fresh, dict) and key in fresh:
                merged[key] = fresh[key]
        state = compute_lan_state(merged, detect_network(), self.peers, self.wsl)
        key = (
            state["enabled"],
            state["network"],
            state["group"],
            tuple(state["allow"]),
            state["reason"],
        )
        changed = key != self._lan_key
        with self.lock:
            self.lan_state = state
            if changed:
                self._lan_key = key
                self.outbound_skip_warned.clear()
                self.rejected_warned.clear()
                for rkey in list(self.remotes.keys()):
                    host = split_host_port(rkey[0], self.listen_port)[0]
                    if not peer_allowed_outbound(host, state):
                        self._remove_remote_locked(rkey)
        if changed:
            if state["enabled"]:
                log(
                    "network: %s (group %s) -> LAN enabled, allow: %s"
                    % (state["network"], state["group"], ", ".join(state["allow"]))
                )
            elif state["netinfo"] is None:
                log("network unknown -> LAN disabled (%s)" % state["reason"])
            else:
                log("network not allowed -> LAN disabled (%s)" % state["reason"])
            for w in state["warnings"]:
                log(w)
            for e in state["errors"]:
                log("invalid allow entry dropped: %s" % e)
        self._win_sync(state)
        return state

    def _win_sync(self, state):
        """WSL only: write the effective allowlist to the Windows data file (only on
        change) and trigger the elevated refresh task. Skipped for a loopback-only
        listener (nothing is reachable from the LAN, so there is nothing to open)."""
        if not self.wsl or is_loopback_ip(self.listen_host):
            return
        if not self._win_allow_resolved:
            self._win_allow_resolved = True
            self._win_allow_path = win_allow_file(self.listen_port)
            if not self._win_allow_path:
                log("cannot resolve %LOCALAPPDATA% - Windows firewall allowlist not synced")
        if not self._win_allow_path:
            return
        try:
            written = write_win_allow_file(
                self._win_allow_path, win_allow_payload(state, self.listen_port)
            )
        except Exception as exc:
            log("windows allowlist write %s failed: %s" % (self._win_allow_path, exc))
            return
        if written:
            log("windows firewall allowlist data updated (%s)" % self._win_allow_path)
            if not os.environ.get("CREDO_PEER_LAN_WINALLOW_FILE"):
                trigger_win_task()

    def _write_pidfile(self):
        """Atomically record our pid, version, listen port and start time after a
        successful bind+listen, so a later session's `ensure` can read what is running
        and decide. Best-effort: pidfile I/O must never crash the daemon."""
        path = pidfile_path()
        data = {
            "pid": os.getpid(),
            "version": VERSION,
            "listen_port": self.listen_port,
            "started": time.time(),
        }
        tmp = "%s.%d.tmp" % (path, os.getpid())
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(tmp, "w") as fh:
                fh.write(json.dumps(data))
            os.replace(tmp, path)
        except Exception as exc:
            log("pidfile write %s failed: %s" % (path, exc))
            try:
                os.unlink(tmp)
            except OSError:
                pass

    def _remove_pidfile(self):
        """Remove the pidfile on shutdown, but ONLY if it still records our own pid, so
        we never delete a successor daemon's file (e.g. after a restart handed the port
        over). Best-effort - never raises."""
        try:
            d = read_pidfile()
            if isinstance(d, dict) and int(d.get("pid", -1)) == os.getpid():
                os.unlink(pidfile_path())
        except Exception:
            pass

    def shutdown(self):
        if self.stop.is_set():
            return
        self.stop.set()
        log("shutting down")
        try:
            if self.srv:
                self.srv.close()
        except OSError:
            pass
        self._remove_pidfile()
        with self.lock:
            keys = list(self.remotes.keys())
        for key in keys:
            self._remove_remote(key)

    # -- inbound TCP --------------------------------------------------------
    def _accept_loop(self):
        while not self.stop.is_set():
            try:
                conn, addr = self.srv.accept()
            except OSError:
                break
            # allowlist gate BEFORE reading any byte: loopback always, otherwise only
            # while LAN is enabled and the source is allowed (see source_allowed)
            src = addr[0] if isinstance(addr, tuple) and addr else ""
            with self.lock:
                state = self.lan_state
            if not source_allowed(src, state, self.wsl):
                if src not in self.rejected_warned:
                    self.rejected_warned.add(src)
                    log(
                        "rejected inbound connection from %s (%s)"
                        % (
                            src,
                            "not in the allowlist" if state.get("enabled")
                            else "LAN disabled: " + state.get("reason", ""),
                        )
                    )
                try:
                    conn.close()
                except OSError:
                    pass
                continue
            # bound concurrency: try to grab a slot without blocking the accept loop.
            # If the pool is full, shed this (still unauthenticated) connection rather
            # than spawning an unbounded number of handler threads.
            if not self.conn_sem.acquire(timeout=ACQUIRE_TIMEOUT):
                log(
                    "connection cap reached (%d); dropping %s"
                    % (self.max_conn_threads, addr)
                )
                try:
                    conn.close()
                except OSError:
                    pass
                continue
            try:
                threading.Thread(
                    target=self._handle_conn_guarded, args=(conn, addr), daemon=True
                ).start()
            except Exception as exc:
                self.conn_sem.release()
                log("could not start handler thread for %s: %s" % (addr, exc))
                try:
                    conn.close()
                except OSError:
                    pass

    def _handle_conn_guarded(self, conn, addr):
        try:
            self._handle_conn(conn, addr)
        finally:
            self.conn_sem.release()

    def _handle_conn(self, conn, addr):
        try:
            conn.settimeout(10)
            buf = b""
            while b"\n" not in buf:
                try:
                    chunk = conn.recv(65536)
                except socket.timeout:
                    break
                if not chunk:
                    break
                buf += chunk
                if len(buf) > 4 * 1024 * 1024:
                    log("oversize message from %s dropped" % (addr,))
                    return
        finally:
            conn.close()
        for line in buf.splitlines():
            line = line.strip()
            if not line:
                continue
            payload = verify_line(self.token, line.decode("utf-8", "replace"))
            if payload is None:
                log("rejected unauthenticated/garbled message from %s" % (addr,))
                continue
            src_ip = addr[0] if isinstance(addr, tuple) and addr else ""
            self._dispatch(payload, src_ip)

    def _dispatch(self, payload, src_ip=""):
        kind = payload.get("kind")
        if kind == "roster":
            self._on_roster(payload, src_ip)
        elif kind == "deliver":
            self._on_deliver(payload, src_ip)
        else:
            log("unknown message kind %r" % kind)

    # -- deliver (inject into a real local session) -------------------------
    def _on_deliver(self, payload, src_ip=""):
        target = payload.get("target_sessionId")
        body = payload.get("body", "")
        if not isinstance(body, str) or body_has_envelope_delim(body):
            # envelope-injection attempt (or garbage): never inject, log once per source
            src = src_ip or "?"
            if src not in self.deliver_rejected_warned:
                self.deliver_rejected_warned.add(src)
                log(
                    "deliver from %s rejected: body contains an envelope delimiter "
                    "or is not text (further rejects from this source not logged)" % src
                )
            return
        target_socket = resolve_socket(self.sess_dir, target)
        if not target_socket:
            log("deliver: no local session %r, dropped" % target)
            return
        reply = self._reply_addr_for(payload.get("from_sessionId"))
        from_name = sanitize_from_name(payload.get("from_name", ""))
        try:
            inject(target_socket, from_name, body, reply)
            log("deliver: injected into %s (from %r)" % (target, from_name))
        except Exception as exc:
            log("deliver: inject into %s failed: %s" % (target_socket, exc))

    def _reply_addr_for(self, from_session):
        """A local proxy socket that routes back to the remote sender, if we hold
        one. Replies written there are forwarded home by that holder."""
        if not from_session:
            return None
        with self.lock:
            for (machine, sid), rec in self.remotes.items():
                if sid == from_session:
                    return "uds:" + rec["proxy"]
        return None

    # -- roster -------------------------------------------------------------
    def _roster_loop(self):
        while not self.stop.wait(self.roster_interval):
            self.roster_tick()

    def roster_tick(self):
        """Send one roster to every peer the outbound gate allows. While LAN is
        disabled no LAN peer gets anything (no session names leak on a foreign
        network); loopback peers are unaffected."""
        with self.lock:
            state = self.lan_state
        targets = []
        for peer in self.peers:
            if peer_allowed_outbound(peer["host"], state):
                targets.append(peer)
                continue
            addr = "%s:%d" % (peer["host"], peer["port"])
            if addr not in self.outbound_skip_warned:
                self.outbound_skip_warned.add(addr)
                log(
                    "not sending rosters to %s (%s)"
                    % (
                        addr,
                        "outside the allowlist" if state.get("enabled")
                        else "LAN disabled: " + state.get("reason", ""),
                    )
                )
        if not targets:
            return 0
        sessions = [
            {
                "sessionId": d.get("sessionId"),
                "name": d.get("name") or d.get("sessionId"),
                "status": d.get("status", "idle"),
            }
            for d in read_local_sessions(self.sess_dir)
        ]
        payload = {
            "kind": "roster",
            "machine": self.this_machine,
            # announce our listen port so the receiver can pair this roster
            # (by source IP + this port) with the configured peer address to
            # forward replies to - address-based routing, no name contract.
            "listen_port": self.listen_port,
            "sessions": sessions,
        }
        # advertise our own reachable address so the receiver forwards to the
        # CONFIGURED peer matching it, never to the raw inbound source IP (which
        # under WSL2 NAT is the gateway, not us). Omitted until detected, so an
        # old peer that never sends it still works via the receiver's fallback.
        if self.advertise_host:
            payload["advertise_host"] = self.advertise_host
            payload["advertise_port"] = self.advertise_port
        for peer in targets:
            host, port = peer["host"], peer["port"]
            try:
                send_to_peer(host, port, self.token, payload)
            except Exception as exc:
                log("roster to %s:%s failed: %s" % (host, port, exc))
        return len(targets)

    def _resolve_peer_addr(self, src_ip, listen_port, adv_host=None, adv_port=None):
        """Map an inbound roster to the peer ADDRESS its replies/messages forward to,
        and whether that address is a configured peer. The forward target must be the
        CONFIGURED peer, never the raw inbound source IP (under WSL2 NAT the source IP
        is the WSL gateway, not the peer). Resolution order:
          1. the configured peer matching the roster's ADVERTISED host (the sender's
             own reachable address). An advertised address is only ever honored when
             it matches the config, so a rogue cannot redirect traffic elsewhere.
          2. the configured peer matching the raw source IP + announced port (the
             no-NAT / loopback case where the source IP really is the peer).
          3. the single configured peer, if exactly one is configured (unambiguous;
             also makes the NAT fix work for a peer too old to advertise).
          4. else the raw (src_ip, port), flagged unexpected. Served token-less (the
             receiving session's own consent gate is the protection), warned once."""
        port = int(listen_port) if listen_port else DEFAULT_PORT
        # 1. advertised host matches a configured peer (NAT-safe path)
        if adv_host:
            aport = int(adv_port) if adv_port else None
            if aport is not None:
                for p in self.peers:
                    if p["host"] == adv_host and p["port"] == aport:
                        return (p["host"], p["port"]), True
            for p in self.peers:
                if p["host"] == adv_host:
                    return (p["host"], p["port"]), True
        # 2. source IP + announced port matches a configured peer
        for p in self.peers:
            if p["host"] == src_ip and p["port"] == port:
                return (p["host"], p["port"]), True
        # 3. exactly one configured peer -> unambiguous forward target
        if len(self.peers) == 1:
            p = self.peers[0]
            return (p["host"], p["port"]), True
        # 4. not resolvable to a configured peer
        return (src_ip, port), False

    def _on_roster(self, payload, src_ip=""):
        machine = payload.get("machine")
        if not machine:
            return
        sessions = payload.get("sessions")
        if not isinstance(sessions, list):
            sessions = []
        peer_addr, known = self._resolve_peer_addr(
            src_ip,
            payload.get("listen_port"),
            payload.get("advertise_host"),
            payload.get("advertise_port"),
        )
        addr_key = "%s:%d" % peer_addr
        now = time.monotonic()
        with self.lock:
            # outbound gate: never materialize a holder whose forward target is a LAN
            # address the current allowlist does not permit (forwards would leak)
            if not peer_allowed_outbound(peer_addr[0], self.lan_state):
                if addr_key not in self.outbound_skip_warned:
                    self.outbound_skip_warned.add(addr_key)
                    log("roster from %s ignored: forward target not allowed" % addr_key)
                return
            self.machine_seen[addr_key] = now
            # Unexpected-inbound signal: a roster whose source address is NOT among
            # the configured peer addresses. Token-less this is still served (the
            # receiving session's own consent gate is the protection), so it is only
            # a warning, once per address (no per-interval spam). A correctly
            # configured multi-IP setup matches a peer address and never warns.
            if not known and addr_key not in self.unknown_warned:
                self.unknown_warned.add(addr_key)
                log(
                    "roster from %s (machine %r) whose address is not among this "
                    "daemon's configured peer addresses %s - add it with "
                    "'credo-peer-lan.py init %s' if this peer is expected"
                    % (
                        addr_key,
                        machine,
                        sorted("%s:%d" % a for a in self.peer_addrs),
                        peer_addr[0],
                    )
                )
            present = {}
            # Duplicate guard: a bridge (e.g. a Codex bridge service) may re-announce
            # sessions that already exist here or that another sender already owns.
            # Skip a sessionId that is a real local session (not one of our mirrors),
            # and dedupe by sessionId across all senders - the first owner wins.
            local_ids = local_real_session_ids(self.sess_dir)
            owned_elsewhere = {
                sid
                for (mkey, sid), rec in self.remotes.items()
                if mkey != addr_key or rec.get("machine") != machine
            }
            for s in sessions:
                if not isinstance(s, dict):
                    continue  # tolerate a malformed/hostile roster entry
                sid = s.get("sessionId")
                if not sid or not isinstance(sid, str):
                    continue
                if sid in local_ids or sid in owned_elsewhere:
                    if sid not in self.dup_session_warned:
                        self.dup_session_warned.add(sid)
                        log(
                            "roster from %s (machine %r): session %s skipped, %s"
                            % (
                                addr_key,
                                machine,
                                sid,
                                "it is a local session" if sid in local_ids
                                else "already mirrored from another sender",
                            )
                        )
                    continue
                if len(present) >= self.max_remotes:
                    log(
                        "roster from %s over cap %d; ignoring extra sessions"
                        % (addr_key, self.max_remotes)
                    )
                    break
                s = dict(s)
                s["machine"] = machine  # announced this_machine, for the display name
                present[sid] = s
            # remove sessions that vanished from THIS sender's roster. The prune is
            # scoped to the same announced machine as well as the forward address: with
            # the single-peer fallback (resolution rule 3) two different senders can map
            # to the same configured peer address, and a roster from one must never prune
            # the other's sessions.
            for (mkey, sid), rec in list(self.remotes.items()):
                if mkey == addr_key and rec.get("machine") == machine and sid not in present:
                    self._remove_remote_locked((mkey, sid))
            # ensure a holder+descriptor for each present session
            template = self._template_descriptor_locked()
            for sid, s in present.items():
                key = (addr_key, sid)
                if key in self.remotes:
                    self._refresh_descriptor_locked(key, s)
                    continue
                if template is None:
                    continue  # no real local session to model yet; retry next tick
                self._create_remote_locked(key, s, template)

    # -- holder / descriptor lifecycle (must hold self.lock) ----------------
    def _template_descriptor_locked(self):
        best = None
        best_mtime = -1
        for d in read_local_sessions(self.sess_dir):
            if not d.get("pidDomain"):
                continue
            pid = d.get("pid")
            mtime = 0
            try:
                mtime = os.path.getmtime(
                    os.path.join(self.sess_dir, "%s.json" % pid)
                )
            except OSError:
                pass
            if mtime > best_mtime:
                best_mtime = mtime
                best = d
        return best

    def _foreign_descriptor(self, path):
        """True if path holds a descriptor that is NOT ours (missing our marker, or
        unparseable). Such a file must never be overwritten. Absent or marked-ours
        paths return False (safe to write)."""
        try:
            with open(path) as fh:
                d = json.load(fh)
        except FileNotFoundError:
            return False
        except Exception:
            return True  # garbled: do not assume it is ours
        if not isinstance(d, dict):
            return True
        return not d.get(MARK)

    def _create_remote_locked(self, key, sess, template):
        addr_key, sid = key
        # last-line duplicate guard: one mirror per sessionId, whoever announced it
        if any(osid == sid for (_m, osid) in self.remotes):
            return
        host, port = split_host_port(addr_key, self.listen_port)
        # routing is by address; machine is kept to disambiguate the display name. The
        # mirror name must be SendMessage-addressable: SendMessage rejects a name that
        # contains "@", so the machine is joined with a double underscore
        # ("<session>__<machine>") instead - addressable, and still unique per machine.
        # Fall back to the host when the roster did not annotate a machine.
        machine = sess.get("machine") or host
        name = (sess.get("name") or sid) + "__" + machine
        proxy = os.path.join(self.sock_dir, "pl-%s.sock" % uuid.uuid4().hex[:12])
        env = dict(os.environ)
        env["CREDO_PEER_LAN_CONFIG"] = config_path()
        proc = subprocess.Popen(
            [
                sys.executable,
                self.script,
                "holder",
                "--proxy",
                proxy,
                "--target-session",
                sid,
                "--peer-host",
                host,
                "--peer-port",
                str(port),
                "--this-machine",
                self.this_machine,
            ],
            env=env,
        )
        # wait briefly for the holder to bind its proxy socket
        for _ in range(40):
            if os.path.exists(proxy):
                break
            if proc.poll() is not None:
                log("holder for %s exited early (rc=%s)" % (name, proc.returncode))
                return
            time.sleep(0.05)
        desc_path = os.path.join(self.sess_dir, "%d.json" % proc.pid)
        if self._foreign_descriptor(desc_path):
            # pid reuse: a real local descriptor (one without our marker) already
            # occupies this pid path. Never clobber a file we do not own - kill the
            # holder we just spawned and skip this remote; the next roster retries.
            log(
                "remote %s skipped: holder pid %d collides with a real local descriptor"
                % (name, proc.pid)
            )
            if proc.poll() is None:
                try:
                    proc.terminate()
                    proc.wait(timeout=3)
                except Exception:
                    try:
                        proc.kill()
                    except OSError:
                        pass
            try:
                os.unlink(proxy)
            except OSError:
                pass
            return
        self._write_descriptor(desc_path, proc.pid, sid, name, machine, sess, template, proxy)
        self.remotes[key] = {
            "holder": proc,
            "proxy": proxy,
            "descriptor": desc_path,
            "pid": proc.pid,
            "machine": machine,
        }
        log("remote up: %s -> holder pid %d, proxy %s" % (name, proc.pid, proxy))

    def _refresh_descriptor_locked(self, key, sess):
        rec = self.remotes.get(key)
        if not rec:
            return
        proc = rec["holder"]
        if proc.poll() is not None:
            # holder died: drop and let the next roster recreate it
            self._remove_remote_locked(key)
            return
        try:
            with open(rec["descriptor"]) as fh:
                d = json.load(fh)
        except Exception:
            return
        now_ms = int(time.time() * 1000)
        d["status"] = sess.get("status", d.get("status", "idle"))
        d["statusUpdatedAt"] = now_ms
        d["updatedAt"] = now_ms
        self._atomic_write(rec["descriptor"], d)

    def _write_descriptor(self, path, pid, sid, name, machine, sess, template, proxy):
        try:
            pstart = proc_start(pid)
        except Exception as exc:
            log("cannot read procStart for holder %d: %s" % (pid, exc))
            pstart = template.get("procStart", "")
        now_ms = int(time.time() * 1000)
        d = {
            "pid": pid,
            "sessionId": sid,
            "cwd": template.get("cwd", ""),
            "startedAt": now_ms,
            "procStart": pstart,
            "version": template.get("version", ""),
            "peerProtocol": template.get("peerProtocol", 1),
            "peerFeatures": template.get("peerFeatures", []),
            "kind": template.get("kind", "interactive"),
            "entrypoint": template.get("entrypoint", "cli"),
            "pidDomain": template.get("pidDomain", ""),
            "messagingSocketPath": proxy,
            "name": name,
            "nameSource": "credo-peer-lan",
            "nameSince": now_ms,
            "updatedAt": now_ms,
            "status": sess.get("status", "idle"),
            "statusUpdatedAt": now_ms,
            MARK: True,
            MARK_FROM: machine,
        }
        self._atomic_write(path, d)

    def _atomic_write(self, path, obj):
        tmp = "%s.credo-lan.%d.tmp" % (path, os.getpid())
        try:
            with open(tmp, "w") as fh:
                fh.write(json.dumps(obj))
            os.replace(tmp, path)
        except Exception as exc:
            log("descriptor write %s failed: %s" % (path, exc))
            try:
                os.unlink(tmp)
            except OSError:
                pass

    def _remove_remote(self, key):
        with self.lock:
            self._remove_remote_locked(key)

    def _remove_remote_locked(self, key):
        rec = self.remotes.pop(key, None)
        if not rec:
            return
        proc = rec.get("holder")
        if proc is not None and proc.poll() is None:
            try:
                proc.terminate()
            except OSError:
                pass
            try:
                proc.wait(timeout=3)
            except Exception:
                try:
                    proc.kill()
                except OSError:
                    pass
        for p in (rec.get("descriptor"), rec.get("proxy")):
            if p:
                try:
                    os.unlink(p)
                except OSError:
                    pass
        log("remote removed: %s" % (key,))

    def _janitor_loop(self):
        while not self.stop.wait(self.roster_interval):
            now = time.monotonic()
            with self.lock:
                dead_machines = set()
                for machine, seen in self.machine_seen.items():
                    if now - seen > self.machine_timeout:
                        dead_machines.add(machine)
                for key in list(self.remotes.keys()):
                    machine, _sid = key
                    rec = self.remotes[key]
                    proc = rec.get("holder")
                    holder_dead = proc is not None and proc.poll() is not None
                    if machine in dead_machines or holder_dead:
                        self._remove_remote_locked(key)
                for machine in dead_machines:
                    self.machine_seen.pop(machine, None)

    def _cleanup_stale_descriptors(self):
        """Remove leftover credoPeerLan descriptors from a previous daemon run whose
        holder pid is no longer alive. Never touches anything without our marker."""
        try:
            names = os.listdir(self.sess_dir)
        except OSError:
            return
        for name in names:
            if not name.endswith(".json"):
                continue
            base = name[:-5]
            if not base.isdigit():
                continue
            path = os.path.join(self.sess_dir, name)
            if os.path.islink(path):
                continue
            try:
                with open(path) as fh:
                    d = json.load(fh)
            except Exception:
                continue
            if not isinstance(d, dict) or not d.get(MARK):
                continue
            if not pid_alive(base):
                try:
                    os.unlink(path)
                    log("pruned stale descriptor %s" % name)
                except OSError:
                    pass

    def _cleanup_stale_sockets(self):
        """Remove leftover proxy sockets in our sock dir that no live credoPeerLan
        descriptor points at (e.g. orphaned by a SIGKILLed previous daemon). Only
        touches our own 'pl-*.sock' naming, never anything we cannot attribute."""
        try:
            names = os.listdir(self.sock_dir)
        except OSError:
            return
        referenced = set()
        try:
            snames = os.listdir(self.sess_dir)
        except OSError:
            snames = []
        for sname in snames:
            if not sname.endswith(".json"):
                continue
            base = sname[:-5]
            if not base.isdigit():
                continue
            spath = os.path.join(self.sess_dir, sname)
            if os.path.islink(spath):
                continue
            try:
                with open(spath) as fh:
                    d = json.load(fh)
            except Exception:
                continue
            if not isinstance(d, dict) or not d.get(MARK):
                continue
            if not pid_alive(base):
                continue
            msp = d.get("messagingSocketPath")
            if msp:
                referenced.add(msp)
        for name in names:
            if not (name.startswith("pl-") and name.endswith(".sock")):
                continue
            path = os.path.join(self.sock_dir, name)
            if path in referenced:
                continue
            try:
                os.unlink(path)
                log("pruned stale proxy socket %s" % name)
            except OSError:
                pass


def _serve(cfg):
    """Build the Daemon, install SIGTERM/SIGINT handlers, start it (start() now
    bind-retries on EADDRINUSE), run until stopped, and always shut down in finally.
    Shared by run_daemon / run_ensure / run_restart. Returns 0 normally, 0 on a clean
    AlreadyRunning give-up, 1 on an unexpected start failure."""
    daemon = Daemon(cfg)

    def _sig(_signo, _frame):
        daemon.shutdown()

    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)
    try:
        daemon.start()
    except AlreadyRunning:
        return 0
    except Exception as exc:
        log("failed to start: %s" % exc)
        return 1
    try:
        while not daemon.stop.wait(1.0):
            pass
    finally:
        daemon.shutdown()
    return 0


def run_daemon(_args):
    if disabled():
        log("disabled via CREDO_PEER_LAN; exiting")
        return 0
    cfg = load_config()
    if cfg is None:
        log("no config at %s; nothing to do (no-op)" % config_path())
        return 0
    return _serve(cfg)


def run_ensure(_args):
    """Autostart entry (replaces the old pgrep-check + plain `daemon`): start the
    daemon, OR self-heal an OLDER running one after a plugin update (cc-up), but never
    disturb a current/newer or uncertain incumbent.

    Decision (CONSERVATIVE INVARIANT - only ever replace a POSITIVELY older daemon):
      - disabled or no config    -> log + return 0 (no-op).
      - a live daemon on the pidfile pid:
          * running or current version unparseable, or running >= current
                                   -> leave it, return 0 (no-op).
          * running < current      -> SIGTERM it; if the port frees, serve the new
                                      version, else leave the old one and return 0.
      - no live daemon            -> serve (start() bind-retries past any lingering
                                      hold). AlreadyRunning -> return 0."""
    if disabled():
        log("disabled via CREDO_PEER_LAN; exiting")
        return 0
    cfg = load_config()
    if cfg is None:
        log("no config at %s; nothing to do (no-op)" % config_path())
        return 0
    pf = read_pidfile()
    if pf and daemon_is_alive(pf.get("pid")):
        old_pid = pf.get("pid")
        running_v = version_tuple(pf.get("version"))
        cur_v = version_tuple(VERSION)
        if running_v is None or cur_v is None or running_v >= cur_v:
            log(
                "daemon already running (pid %s, v%s), leaving it"
                % (old_pid, pf.get("version"))
            )
            return 0
        log(
            "replacing older daemon pid %s v%s with v%s"
            % (old_pid, pf.get("version"), VERSION)
        )
        host = cfg.get("listen_host", "127.0.0.1")
        port = int(cfg.get("listen_port", DEFAULT_PORT))
        if _terminate_incumbent(old_pid, host, port):
            return _serve(cfg)
        log(
            "could not reclaim %s:%d from older daemon pid %s; leaving it running"
            % (host, port, old_pid)
        )
        return 0
    return _serve(cfg)


def run_restart(_args):
    """Explicit stop-then-start regardless of version. Never ends with no daemon: if a
    running daemon cannot be stopped and its port reclaimed within the timeout, report a
    clear error to STDERR and return 1 rather than leaving nothing (and never force-serve
    into a still-held port)."""
    if disabled():
        log("disabled via CREDO_PEER_LAN; exiting")
        return 0
    cfg = load_config()
    if cfg is None:
        log("no config at %s; nothing to do (no-op)" % config_path())
        return 0
    host = cfg.get("listen_host", "127.0.0.1")
    port = int(cfg.get("listen_port", DEFAULT_PORT))
    pf = read_pidfile()
    if pf and daemon_is_alive(pf.get("pid")):
        old_pid = pf.get("pid")
        log("restart: stopping running daemon pid %s" % old_pid)
        if not _terminate_incumbent(old_pid, host, port):
            sys.stderr.write(
                "credo-peer-lan restart: could not reclaim %s:%d from the running "
                "daemon (pid %s) within %.0fs; left it running\n"
                % (host, port, old_pid, TERMINATE_TIMEOUT)
            )
            return 1
    return _serve(cfg)


def run_init(args):
    """Write/update the config from one or more peer IPs, token-less, then print
    this machine's own address and probe the configured peers. Pure: it never
    starts the daemon or touches Windows (that is the command doc / autostart).
    It never binds a network silently: when the current network is not bound yet it
    prints the exact `bind` suggestion for the agent/user to confirm.

    Modes:
      init <ips...>            additive + dedup (default)
      init --replace <ips...>  peers[] becomes EXACTLY the given addresses
      init --remove <ips...>   remove the given addresses from peers[]"""
    path = config_path()
    cfg = load_config() or {}
    cfg.setdefault("this_machine", socket.gethostname())
    cfg.setdefault("listen_host", "0.0.0.0")
    cfg.setdefault("listen_port", DEFAULT_PORT)
    # token-less by default: NEVER add a token here (an existing one is kept as-is)
    default_port = int(cfg.get("listen_port", DEFAULT_PORT))
    peers = normalize_peers(cfg.get("peers", []), default_port)
    added = []
    removed = []
    if getattr(args, "replace", False):
        # peers[] becomes exactly the given addresses (normalized + deduped)
        peers = normalize_peers(list(args.ips), default_port)
        added = list(peers)
    elif getattr(args, "remove", False):
        drop = set()
        for raw in args.ips:
            p = normalize_peer(raw, default_port)
            if p:
                drop.add((p["host"], p["port"]))
            else:
                log("init: ignoring unparseable peer %r" % raw)
        kept = []
        for p in peers:
            if (p["host"], p["port"]) in drop:
                removed.append(p)
            else:
                kept.append(p)
        peers = kept
    else:
        seen = set((p["host"], p["port"]) for p in peers)
        for raw in args.ips:
            p = normalize_peer(raw, default_port)
            if not p:
                log("init: ignoring unparseable peer %r" % raw)
                continue
            key = (p["host"], p["port"])
            if key in seen:
                continue
            seen.add(key)
            peers.append(p)
            added.append(p)
    cfg["peers"] = [peer_to_string(p, default_port) for p in peers]
    try:
        write_config(cfg, path)
    except Exception as exc:
        log("init: could not write %s: %s" % (path, exc))
        return 1

    print("Wrote %s" % path)
    print("  this_machine: %s" % cfg["this_machine"])
    print("  listen:       %s:%d" % (cfg["listen_host"], default_port))
    print("  token:        %s" % ("set" if cfg.get("token") else "none (token-less)"))
    if cfg["peers"]:
        print("  peers:        %s" % ", ".join(cfg["peers"]))
    else:
        print("  peers:        (none yet - re-run with one or more peer IPs)")
    if added:
        print("  added:        %s" % ", ".join(peer_to_string(p, default_port) for p in added))
    if removed:
        print("  removed:      %s" % ", ".join(peer_to_string(p, default_port) for p in removed))
    print("")
    print_self_address(cfg)
    print("")
    probe_all_peers(cfg)
    net = detect_network()
    state = compute_lan_state(cfg, net, normalize_peers(cfg["peers"], default_port), is_wsl())
    print("")
    print_bind_suggestion(cfg, net, state)
    check_firewall_hint(cfg, state)
    return 0


def _shell_quote(text):
    if re.match(r"^[A-Za-z0-9._/:@-]+$", text or ""):
        return text
    return "'" + (text or "").replace("'", "'\\''") + "'"


def default_network_name(net, label=None):
    base = label or (net or {}).get("ssid") or ""
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", base).strip("-._").lower()[:40]
    if not name:
        name = "net-" + ((net or {}).get("subnet") or "unknown").replace(".", "-").replace("/", "-")
    return name


def print_bind_suggestion(cfg, net, state):
    if state.get("enabled"):
        print(
            "LAN relay ENABLED on this network: %s (group %s), allow: %s"
            % (state["network"], state["group"], ", ".join(state["allow"]))
        )
        return
    if net is None or not net.get("gateway_mac") or not net.get("subnet"):
        print(
            "LAN relay DISABLED: the current network could not be detected, so it cannot "
            "be bound. Run 'credo-peer-lan.py netinfo' to inspect detection."
        )
        return
    if state.get("network"):
        print("LAN relay DISABLED on bound network %s: %s" % (state["network"], state["reason"]))
        return
    label = net.get("ssid") or ""
    cmd = "credo-peer-lan.py bind"
    if label:
        cmd += " --label %s" % _shell_quote(label)
    cmd += " --group home --allow peers"
    print(
        "This network (%s, subnet %s, router %s) is NOT bound yet - the relay stays "
        "DISABLED on it (fail-closed). If it is a trusted home network, bind it with:"
        % (label or "no label", net["subnet"], net["gateway_mac"])
    )
    print("  %s" % cmd)
    print(
        "(--allow alternatives: the subnet %s, a range a-b, or 'home' = all private "
        "ranges, broadest; wildcards are never accepted.)" % net["subnet"]
    )


def run_whoami(_args):
    cfg = load_config() or {}
    print_self_address(cfg)
    return 0


def current_state(cfg):
    default_port = int(cfg.get("listen_port", DEFAULT_PORT))
    return compute_lan_state(
        cfg, detect_network(), normalize_peers(cfg.get("peers", []), default_port), is_wsl()
    )


def run_check(_args):
    cfg = load_config()
    if cfg is None:
        print(
            "No config at %s - the relay is a no-op until it exists. Create it with "
            "'credo-peer-lan.py init <peer-ip> ...'." % config_path()
        )
        return 0
    print_self_address(cfg)
    print("")
    state = current_state(cfg)
    print_lan_status(cfg, state)
    print("")
    probe_all_peers(cfg)
    check_firewall_hint(cfg, state)
    return 0


def run_netinfo(_args):
    net = detect_network()
    if net is None:
        print(json.dumps({"detected": False}, indent=2))
        return 0
    out = {"detected": True}
    out.update(net)
    print(json.dumps(out, indent=2))
    return 0


def _flatten(values):
    out = []
    for v in values or []:
        out.extend(v if isinstance(v, list) else [v])
    return out


def run_bind(args):
    cfg = load_config()
    if cfg is None:
        sys.stderr.write("No config at %s - run 'credo-peer-lan.py init <peer-ip>' first.\n" % config_path())
        return 1
    net = detect_network()
    if net is None or not net.get("gateway_mac") or not net.get("subnet") or not net.get("ip"):
        sys.stderr.write(
            "Cannot bind: the current network could not be detected (need router MAC + "
            "subnet). Run 'credo-peer-lan.py netinfo' to inspect.\n"
        )
        return 1
    allow = _flatten(args.allow) or ["peers"]
    parsed_ok = []
    for raw in allow:
        try:
            parse_allow_entry(raw)
        except AllowEntryError as exc:
            sys.stderr.write("Rejected allow entry: %s\n" % exc)
            return 2
        if raw.strip().lower() not in [p.strip().lower() for p in parsed_ok]:
            parsed_ok.append(raw.strip())
    group = (args.group or "home").strip()
    if not NETWORK_NAME_RE.match(group):
        sys.stderr.write("Invalid group name %r (letters, digits, . _ -)\n" % group)
        return 2
    networks = cfg.get("networks") if isinstance(cfg.get("networks"), dict) else {}
    # a network already bound to this exact fingerprint is updated, never duplicated
    same = [
        n for n, p in networks.items()
        if isinstance(p, dict)
        and normalize_mac((p.get("fingerprint") or {}).get("gateway_mac")) == net["gateway_mac"]
        and (p.get("fingerprint") or {}).get("subnet") == net["subnet"]
    ]
    name = args.name or (same[0] if same else default_network_name(net, args.label))
    if not NETWORK_NAME_RE.match(name):
        sys.stderr.write("Invalid network name %r (letters, digits, . _ -)\n" % name)
        return 2
    for n in same:
        if n != name:
            networks.pop(n, None)
            print("Replaced the previous binding %s (same router + subnet)." % n)
    networks[name] = {
        "fingerprint": {"gateway_mac": net["gateway_mac"], "subnet": net["subnet"]},
        "label": args.label or net.get("ssid") or "",
        "group": group,
        "allow": parsed_ok,
    }
    cfg["networks"] = networks
    try:
        write_config(cfg)
    except Exception as exc:
        sys.stderr.write("Could not write %s: %s\n" % (config_path(), exc))
        return 1
    print(
        "Bound network %s: router %s, subnet %s, label %r, group %s, allow %s"
        % (name, net["gateway_mac"], net["subnet"], networks[name]["label"], group, parsed_ok)
    )
    state = current_state(cfg)
    for w in state["warnings"]:
        print(w)
    for e in state["errors"]:
        print("ERROR: invalid entry dropped: %s" % e)
    if state["enabled"]:
        print("Effective allowlist (group %s): %s" % (state["group"], ", ".join(state["allow"])))
    else:
        print("LAN relay still DISABLED: %s" % state["reason"])
    print("A running daemon picks this up on its next network check (or restart it).")
    return 0


def run_unbind(args):
    cfg = load_config()
    networks = (cfg or {}).get("networks")
    if not isinstance(networks, dict) or args.name not in networks:
        sys.stderr.write("No bound network named %r.\n" % args.name)
        return 1
    networks.pop(args.name)
    cfg["networks"] = networks
    write_config(cfg)
    print("Unbound network %s." % args.name)
    if not networks:
        print("No network is bound any more - the LAN relay is DISABLED everywhere (loopback still works).")
    return 0


def run_networks(_args):
    cfg = load_config() or {}
    networks = cfg.get("networks")
    if not isinstance(networks, dict) or not networks:
        print("No networks bound - the LAN relay is DISABLED (fail-closed). Bind one with 'credo-peer-lan.py bind'.")
        return 0
    current = match_network(networks, detect_network())
    for name in sorted(networks):
        p = networks[name] if isinstance(networks[name], dict) else {}
        fp = p.get("fingerprint") or {}
        print(
            "%s%s: label %r, group %s, router %s, subnet %s, allow %s"
            % (
                name,
                " (current)" if name == current else "",
                p.get("label", ""),
                network_group(p),
                fp.get("gateway_mac"),
                fp.get("subnet"),
                p.get("allow", ["peers"]),
            )
        )
    print("windows_profiles: %s" % windows_profiles(cfg))
    return 0


def run_token(args):
    """Manage the optional shared token. The value is NEVER printed or logged."""
    cfg = load_config()
    if cfg is None:
        sys.stderr.write("No config at %s - run 'credo-peer-lan.py init <peer-ip>' first.\n" % config_path())
        return 1
    if args.clear:
        cfg.pop("token", None)
        write_config(cfg)
        print("token cleared (token-less). Clear it on every machine and restart the daemons.")
        return 0
    if args.generate:
        cfg["token"] = secrets.token_hex(32)
        write_config(cfg)
        print("token set (not shown). Transfer it to your other machines in YOUR OWN terminal with 'credo-peer-lan.py token --set', then restart the daemons.")
        return 0
    if sys.stdin.isatty():
        value = getpass.getpass("Shared token (input hidden): ")
    else:
        value = sys.stdin.readline()
    value = (value or "").strip()
    if len(value) < 16 or any(c.isspace() for c in value):
        sys.stderr.write("Refused: the token must be at least 16 characters without whitespace.\n")
        return 2
    cfg["token"] = value
    write_config(cfg)
    print("token set (not shown). Restart the daemon to apply it.")
    return 0


def onboarding_marker():
    return os.path.join(os.path.dirname(config_path()), "peer-lan-onboarding-declined")


def onboarding_state():
    """Cheap, config-only (NO network detection): not-configured | declined |
    unbound | bound. Used by the SessionStart hook."""
    cfg = load_config()
    if cfg is None:
        if os.path.exists(config_path()):
            return "unbound"  # present but unreadable: treat like unbound, never offer setup
        return "declined" if os.path.exists(onboarding_marker()) else "not-configured"
    nets = cfg.get("networks")
    return "bound" if isinstance(nets, dict) and nets else "unbound"


def run_onboarding(args):
    marker = onboarding_marker()
    if args.decline:
        os.makedirs(os.path.dirname(marker), exist_ok=True)
        with open(marker, "w") as fh:
            fh.write("declined %s\n" % time.strftime("%Y-%m-%d"))
        print("LAN relay onboarding declined - it will not be offered again (undo: onboarding --reset).")
        return 0
    if args.reset:
        try:
            os.unlink(marker)
        except OSError:
            pass
        print("LAN relay onboarding reset - it will be offered again on the next session start.")
        return 0
    print(onboarding_state())
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="credo LAN peer relay")
    sub = parser.add_subparsers(dest="cmd")

    p_daemon = sub.add_parser("daemon", help="run the relay daemon (default)")
    p_daemon.set_defaults(func=run_daemon)

    p_ensure = sub.add_parser(
        "ensure",
        help="start the daemon, or replace an OLDER running one after a plugin "
        "update; no-op when a current/newer daemon already runs (autostart entry)",
    )
    p_ensure.set_defaults(func=run_ensure)

    p_restart = sub.add_parser(
        "restart",
        help="stop any running daemon and start a fresh one (race-safe; waits for the "
        "port to actually free, errors out instead of leaving nothing running)",
    )
    p_restart.set_defaults(func=run_restart)

    p_init = sub.add_parser(
        "init", help="write/update the config from peer IPs (token-less)"
    )
    p_init.add_argument("ips", nargs="*", help="peer addresses: IP or IP:PORT")
    g_init = p_init.add_mutually_exclusive_group()
    g_init.add_argument(
        "--replace",
        action="store_true",
        help="set peers[] to EXACTLY the given addresses (not additive)",
    )
    g_init.add_argument(
        "--remove",
        action="store_true",
        help="remove the given addresses from peers[]",
    )
    p_init.set_defaults(func=run_init)

    p_whoami = sub.add_parser(
        "whoami", help="print this machine's LAN-reachable address"
    )
    p_whoami.set_defaults(func=run_whoami)

    p_check = sub.add_parser(
        "check",
        help="print this machine's address, the network/allowlist status and probe "
        "configured peers",
    )
    p_check.set_defaults(func=run_check)

    p_netinfo = sub.add_parser("netinfo", help="print the detected network as JSON")
    p_netinfo.set_defaults(func=run_netinfo)

    p_bind = sub.add_parser(
        "bind", help="bind the CURRENT network as trusted (enables the LAN side on it)"
    )
    p_bind.add_argument("--name", help="profile name (default: from label/subnet)")
    p_bind.add_argument("--group", default="home", help="group name (default home)")
    p_bind.add_argument("--label", help="display label (default: SSID / profile name)")
    p_bind.add_argument(
        "--allow",
        action="append",
        nargs="+",
        help="allow entries: peers | IP | CIDR | a-b range | home (default peers)",
    )
    p_bind.set_defaults(func=run_bind)

    p_unbind = sub.add_parser("unbind", help="remove a bound network")
    p_unbind.add_argument("name")
    p_unbind.set_defaults(func=run_unbind)

    p_networks = sub.add_parser("networks", help="list bound networks")
    p_networks.set_defaults(func=run_networks)

    p_token = sub.add_parser(
        "token", help="manage the optional shared token (never printed)"
    )
    g_token = p_token.add_mutually_exclusive_group(required=True)
    g_token.add_argument("--generate", action="store_true", help="generate a random token")
    g_token.add_argument(
        "--set",
        action="store_true",
        help="read a token from a hidden prompt (or stdin when not a TTY)",
    )
    g_token.add_argument("--clear", action="store_true", help="remove the token")
    p_token.set_defaults(func=run_token)

    p_onb = sub.add_parser(
        "onboarding",
        help="session-start onboarding state (config only, no network detection)",
    )
    g_onb = p_onb.add_mutually_exclusive_group(required=True)
    g_onb.add_argument("--state", action="store_true", help="print not-configured|declined|unbound|bound")
    g_onb.add_argument("--decline", action="store_true", help="never offer the setup again")
    g_onb.add_argument("--reset", action="store_true", help="offer the setup again")
    p_onb.set_defaults(func=run_onboarding)

    p_holder = sub.add_parser("holder", help="internal: per-remote-session holder")
    p_holder.add_argument("--proxy", required=True)
    p_holder.add_argument("--target-session", required=True)
    p_holder.add_argument("--peer-host", required=True)
    p_holder.add_argument("--peer-port", required=True)
    p_holder.add_argument("--this-machine", default="")
    p_holder.set_defaults(func=run_holder)

    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        return run_daemon(args)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
