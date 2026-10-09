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
mirror name from mirror_name() (harness, network, device, user, profile, session
+ sid short form), and carries the marker key
"credoPeerLan" (NOT "credoPeerBridge", so the existing bridge never touches it).

When a local session writes into a proxy socket, the holder forwards the message as a
"deliver" to the owning remote daemon, which injects it into the real local target
socket there. The holder hands the deliver to its local daemon (relay unix socket), so
it travels over the return channel when one exists; only when the daemon's relay socket
is unreachable does the holder connect directly - never a --no-direct holder (a peer
outside the outbound allowlist, reachable only over the link it opened to us).

Return channel: each daemon keeps ONE persistent link per peer, opened by whichever side
can connect ("link" hello + ack), and rosters, delivers and pings flow in both
directions over it. This fixes one-way reachability (router behind a router / NAT).
Simultaneous opens are resolved deterministically (the link opened by the machine whose
(this_machine, listen_port, nonce) sorts lower survives), but only between links that
prove they come from the same peer: every link has a fresh random secret that its opener
sends only on that connection, and a competing link must carry a proof derived from it
(the nonce alone never grants anything); all gates and token checks apply to every link
frame. An inbound link may stand for a configured peer we can reach
ourselves only when its socket source is that peer (or loopback / the WSL NAT gateway),
inbound links are capped, and writes have a short deadline. Without a link, frames go
over fresh connections as before; an old relay that never acks is left on those.

Pairing keys (trust on first use, see PairStore): every installation has a persistent
peer id and a static DH key pair. The first link between two ids derives and stores a
shared pairing key K on both sides (K never travels); every later link proves K against
a fresh challenge from each side, and its frames carry a sequence-numbered MAC under a
per-link session key. A peer address (slot) bound to a paired id goes only to a link
that proves that id's key, rosters for it are served only over that link and frames to
it never fall back to a fresh connection, also while the paired peer is offline.
Unpaired peers (old relays, the Codex peer) keep
working token-only; a new id at a paired slot is refused and recorded as a pending
repair until `pair-reset` accepts it.

SAFETY
  - The injected envelope NEVER carries a from-mode attribute. Omitting it is the
    whole point: the receiving session applies its OWN built-in consent gate instead
    of us forging a trusted sender. The relay is mode-agnostic (name/body/reply only).
  - The only extra the relay may add is the local trust marker (see "trusted peers"):
    for a deliver over a PAIRED link from a session the local user trusted with the
    `trust` command. Nothing received over the wire can create or change trust.
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
import itertools
import json
import os
import re
import unicodedata
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


# Path components (below a Windows drive root) of the Windows tools the relay runs
# under WSL; any other tool is looked up directly in Windows/System32.
WIN_TOOL_PARTS = {
    "powershell.exe": ("Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
    "cmd.exe": ("Windows", "System32", "cmd.exe"),
}


def wsl_interop_host():
    """True on WSL by any of its signals: is_wsl() (proc version, WSL_DISTRO_NAME),
    WSL_INTEROP, or the WSLInterop binfmt entry (path overridable with
    CREDO_PEER_LAN_WSLINTEROP for deterministic tests)."""
    if is_wsl() or os.environ.get("WSL_INTEROP"):
        return True
    return os.path.exists(
        os.environ.get("CREDO_PEER_LAN_WSLINTEROP") or "/proc/sys/fs/binfmt_misc/WSLInterop")


def _unescape_mount(path):
    """/proc/mounts escapes space, tab, newline and backslash as octal (\\040 ...)."""
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), path)


def windows_drive_roots():
    """Mount points of the Windows drives, generic: every drvfs mount (or a 9p mount
    whose options name drvfs) from /proc/mounts, plus the single-letter dirs below the
    [automount] root of /etc/wsl.conf. Any automount root and drive letter works; no
    fixed path is assumed. Both files are overridable (CREDO_PEER_LAN_MOUNTS,
    CREDO_PEER_LAN_WSLCONF) for deterministic tests."""
    roots = []
    try:
        with open(os.environ.get("CREDO_PEER_LAN_MOUNTS") or "/proc/mounts") as fh:
            for line in fh:
                f = line.split()
                if len(f) < 4:
                    continue
                if f[2] == "drvfs" or (f[2] == "9p" and "drvfs" in f[3]):
                    roots.append(_unescape_mount(f[1]))
    except OSError:
        pass
    root = None
    try:
        section = ""
        with open(os.environ.get("CREDO_PEER_LAN_WSLCONF") or "/etc/wsl.conf") as fh:
            for line in fh:
                t = line.split("#", 1)[0].strip()
                if t.startswith("[") and t.endswith("]"):
                    section = t[1:-1].strip().lower()
                elif section == "automount" and "=" in t:
                    k, v = t.split("=", 1)
                    if k.strip().lower() == "root":
                        root = v.strip().strip('"')
    except OSError:
        pass
    if root and os.path.isabs(root):
        try:
            for name in sorted(os.listdir(root)):
                if len(name) == 1 and name.isalpha():
                    roots.append(os.path.join(root, name))
        except OSError:
            pass
    seen, out = set(), []
    for r in roots:
        if r not in seen:
            seen.add(r)
            out.append(r)
    # the system drive first: a root that really holds Windows/System32, C: before others
    out.sort(key=lambda r: (not _has_dir_ci(r, ("Windows", "System32")),
                            os.path.basename(r.rstrip("/")).lower() != "c"))
    return out


def _has_dir_ci(base, parts):
    """base/parts... exists as a directory, matched case-insensitively per component."""
    cur = base
    for part in parts:
        if os.path.isdir(os.path.join(cur, part)):
            cur = os.path.join(cur, part)
            continue
        try:
            hit = next((n for n in os.listdir(cur) if n.lower() == part.lower()), None)
        except OSError:
            return False
        if hit is None or not os.path.isdir(os.path.join(cur, hit)):
            return False
        cur = os.path.join(cur, hit)
    return True


def _find_ci(base, parts):
    """base/parts..., matched case-insensitively per component (an exact-case hit is
    tried first, so a case-insensitive drvfs never needs a directory scan)."""
    exact = os.path.join(base, *parts)
    if os.path.isfile(exact):
        return exact
    cur = base
    for part in parts:
        try:
            names = os.listdir(cur)
        except OSError:
            return None
        hit = next((n for n in names if n.lower() == part.lower()), None)
        if hit is None:
            return None
        cur = os.path.join(cur, hit)
    return cur if os.path.isfile(cur) else None


def win_tool(name):
    """Path of a Windows tool (powershell.exe, cmd.exe), or None. PATH wins. Under WSL
    only, a tool missing from PATH is searched in Windows/System32 on the mounted
    Windows drives (windows_drive_roots). After a WSL crash the session PATH can lack
    the Windows dirs (appendWindowsPath not applied); without this fallback network
    detection fails and the LAN relay silently disables itself."""
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if d and os.path.exists(os.path.join(d, name)):
            return os.path.join(d, name)
    if not wsl_interop_host():
        return None
    parts = WIN_TOOL_PARTS.get(name, ("Windows", "System32", name))
    for root in windows_drive_roots():
        hit = _find_ci(root, parts)
        if hit and os.access(hit, os.X_OK):
            return hit
    return None


def missing_win_tool_hint():
    """Explanation for a WSL host where powershell.exe cannot be found at all, else ''."""
    if not wsl_interop_host() or win_tool("powershell.exe"):
        return ""
    return ("powershell.exe not found (not on PATH, and no Windows/System32 on a mounted "
            "Windows drive) - the WSL PATH probably lost the Windows dirs. Open a fresh "
            "shell, or check appendWindowsPath under [interop] in /etc/wsl.conf and "
            "restart WSL")


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
    ps_exe = win_tool("powershell.exe")
    if not ps_exe:
        return None
    ps = (
        "Get-NetIPConfiguration | Where-Object {$_.IPv4DefaultGateway} | "
        "Select-Object -First 1 -ExpandProperty IPv4Address | "
        "Select-Object -ExpandProperty IPAddress"
    )
    try:
        out = subprocess.run(
            [ps_exe, "-NoProfile", "-Command", ps],
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


MIRROR_NAME_MAX = 150


def sid_short(sid):
    """First char of each dash group joined by "-", plus the last char of the id:
    a1b2c3d4-e5f6-... -> a-e-4-8-d8. Keeps two sessions of the same name apart."""
    sid = sid or "?"
    return "-".join(g[:1] for g in sid.split("-") if g) + sid[-1:]


def mirror_name(parts, session, sid):
    """`p1`--`p2`--...--`session`+sid-short; empty parts are dropped, backticks inside
    a part are removed, and the session part is trimmed so the name before "+" stays
    within MIRROR_NAME_MAX. Case, spaces and dots are kept (SendMessage accepts them)."""
    def clean(v):
        return re.sub(r"[`\x00-\x1f\x7f]", "", str(v or "")).strip()

    head = "--".join("`%s`" % clean(p) for p in parts if clean(p))
    sess = clean(session) or "?"
    room = MIRROR_NAME_MAX - len(head) - len("--``")
    if room < 1:
        head, room = head[: MIRROR_NAME_MAX - 8], 4
    return "%s--`%s`+%s" % (head, sess[:room], sid_short(sid))


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
    # run Windows tools from a Windows directory (the system drive first, see
    # windows_drive_roots) so cmd.exe does not warn about a UNC working directory
    for root in windows_drive_roots():
        if os.path.isdir(root):
            return root
    return None


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
    ps_exe = win_tool("powershell.exe")
    if not ps_exe:
        return None
    out = _run_out(
        [ps_exe, "-NoProfile", "-NonInteractive", "-Command", WSL_NETINFO_PS],
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
        hint = missing_win_tool_hint() if wsl else ""
        if hint:
            st["reason"] += ": " + hint
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
    cmd_exe = win_tool("cmd.exe")
    if not (cmd_exe and have_cmd("wslpath")):
        return None
    out = _run_out([cmd_exe, "/c", "echo %" + var + "%"], timeout=10, cwd=_win_cwd())
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
    ps_exe = win_tool("powershell.exe")
    if not ps_exe:
        return False
    task = os.environ.get("CREDO_PEER_LAN_WINPROXY_TASK") or DEFAULT_WIN_TASK
    if not re.match(r"^[A-Za-z0-9._ -]+$", task):
        return False
    try:
        subprocess.Popen(
            [ps_exe, "-NoProfile", "-NonInteractive", "-Command",
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


# sudo prompts for a password, which Claude Code's `!` shell cannot take interactively
SUDO_HINT = ("run these in a separate terminal (sudo asks for your password there; the ! "
             "prefix in Claude Code only works when sudo needs no password)")


def check_firewall_hint(cfg, state=None):
    """Native-Linux-only, read-only, best-effort firewall hint. It NEVER runs sudo and
    NEVER changes anything; any error (ufw absent, unreadable) is swallowed. When ufw
    is active and the LAN side is enabled it prints copy-paste-ready commands: one
    `ufw allow ... comment 'credo-peer-lan'` per allowlist entry not yet covered, plus
    `ufw delete` hints for credo-peer-lan rules whose entry was removed. The user runs
    them in a separate terminal (sudo asks for the password there; Claude Code's `!`
    prefix only works when sudo needs no password, see SUDO_HINT). On WSL
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
                    "(verify with: sudo ufw status). If port %d is not allowed yet, %s:"
                    % (port, SUDO_HINT)
                )
                print("\n".join("  " + c for c in add_cmds))
            elif add_cmds or del_cmds:
                if add_cmds:
                    print(
                        "FIREWALL: ufw is active and port %d is not allowed for: %s - peers "
                        "cannot reach this relay. %s%s:" % (port, ", ".join(missing),
                                                            SUDO_HINT[0].upper(), SUDO_HINT[1:])
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
            "yet, %s:" % (port, SUDO_HINT)
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
# return channel (persistent link). Whichever side CAN connect opens ONE TCP link
# to the peer ("link" hello, answered by a "link" ack) and keeps it open; rosters,
# delivers and pings then flow in BOTH directions over it, framed and signed exactly
# like fresh-connection frames. This fixes one-way reachability (router behind a
# router / NAT): the side that cannot connect answers over the link the other side
# opened. At most one channel per peer address; duplicates are resolved by a
# deterministic tie-break (see Daemon._register_channel).
# ---------------------------------------------------------------------------
MAX_LINE = 4 * 1024 * 1024
# A peer that stops reading must never stall the sender: every channel write has a
# short total deadline, after which the channel is dropped (and later re-opened).
CHAN_WRITE_TIMEOUT = 5.0
# a goodbye ping is best-effort: its total deadline (lock wait + write) is short, and
# several are sent in parallel, so stalled links never stretch a shutdown or restart
# towards TERMINATE_TIMEOUT
BYE_TIMEOUT = 0.5
# read timeout of a channel is ~3 roster intervals of the slower side, capped here so
# a peer announcing a huge interval cannot pin a dead link (and its slot) for long
CHAN_TIMEOUT_MAX = 60.0
# idle channels are pinged at least this often (keeps every side under the cap above)
CHAN_PING_MAX = 15.0
# a goodbye reason from a peer is logged, so only plain characters are kept
BYE_RE = re.compile(r"[^A-Za-z0-9 ._:-]")
# holders hand delivers to the daemon's relay unix socket; a burst must not overflow
# its accept queue, and a full queue (EAGAIN) is retried briefly, never bypassed
RELAY_BACKLOG = 128
RELAY_BUSY_RETRIES = 20
RELAY_BUSY_SLEEP = 0.05
# consecutive link attempts that connect but get no ack (an older relay) before the
# peer is marked "no link support" until the next network change or restart
LINK_REFUSED_MAX = 3
# inbound links from the WSL NAT gateway (every inbound connection under WSL NAT
# arrives from it, so the per-source cap cannot apply): at most max(this, number of
# configured peers) at once, so every configured peer behind NAT can hold a link
GW_LINK_MIN = 2
# once-only log tag sets hold at most this many entries (then start over), so a
# sender cycling through chosen values cannot grow them without bound
WARN_TAGS_MAX = 256


LINK_SECRET_RE = re.compile(r"[0-9a-f]{1,64}")


def _secret_str(v):
    """A per-link secret / proof as carried in a frame: lowercase hex of 1-64 chars
    (what os.urandom().hex() and sha256 hexdigest produce). Anything else (another
    type, non-hex text, a lone surrogate that cannot be UTF-8 encoded) is "" - no
    secret / no proof - so it never reaches a hash or compare that could raise."""
    return v if isinstance(v, str) and LINK_SECRET_RE.fullmatch(v) else ""


def link_proof(sender_out, receiver_out):
    """Proof that the sender of a link frame is the peer behind a link we know: it
    combines the secret of the sender's own outbound link (the receiver saw it as the
    hello "chal" of its inbound link) with the secret of the receiver's outbound link
    (the sender saw it in that link's hello). Each secret is sent only on its own
    connection to the dialed peer address; the value is a SHA-256 over both secrets,
    not the secrets themselves."""
    if not sender_out or not receiver_out:
        return ""
    return hashlib.sha256(("credo-link-tie|%s|%s" % (sender_out, receiver_out))
                          .encode("utf-8")).hexdigest()


def resume_proof(new, old):
    """Proof that a new outbound link comes from the opener of our live inbound link
    whose secret is old (a reconnect replacing its own stale link)."""
    if not new or not old:
        return ""
    return hashlib.sha256(("credo-link-resume|%s|%s" % (new, old))
                          .encode("utf-8")).hexdigest()


def proof_eq(got, want):
    """Constant-time compare of a received proof with the expected one. Both must
    be valid secret strings (_secret_str); anything else (empty, another type,
    non-hex, a lone surrogate) never matches and never raises."""
    if not _secret_str(got) or not _secret_str(want):
        return False
    return hmac.compare_digest(got.encode("utf-8"), want.encode("utf-8"))


# ---------------------------------------------------------------------------
# per-peer pairing keys (trust on first use). Every relay installation has a
# persistent random peer id and a static finite-field Diffie-Hellman key pair
# (RFC 3526 group 14). On the first link between two ids both sides derive the same
# pairing key K from their own private value and the other's public value; K and the
# private values never travel. From then on every link between the two must prove K
# against a fresh challenge from each side, and a slot (peer address) bound to a
# paired id is never given to anything that cannot (token or not). Frames on a
# paired link additionally carry a MAC under a per-link session key with a direction
# label and a sequence number. Because the DH values are static, any two exchanges
# between the same two installations (both directions, simultaneous, after a crash
# halfway) yield the same K, so the pairing converges without a confirmation round.
# ---------------------------------------------------------------------------
PAIR_P = int(
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74"
    "020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437"
    "4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
    "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05"
    "98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB"
    "9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"
    "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718"
    "3995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF", 16)
PAIR_G = 2
PAIR_Q = (PAIR_P - 1) // 2  # p is a safe prime; 2 generates the subgroup of order q
PAIR_X_BITS = 320
PAIR_TAG = "credo-peer-lan-pair-v1"
PAIR_HANDSHAKE_TIMEOUT = 10.0
PENDING_REPAIR_MAX = 16
PEER_ID_RE = re.compile(r"[0-9a-f]{32}")
DH_HEX_RE = re.compile(r"[1-9a-f][0-9a-f]{0,511}")
KEY_HEX_RE = re.compile(r"[0-9a-f]{64}")
_DH_VALID = set()  # public values already checked (bounded like the log tag sets)


def peer_id_str(v):
    """A peer id as carried in a frame: 32 lowercase hex chars, anything else ""."""
    return v if isinstance(v, str) and PEER_ID_RE.fullmatch(v) else ""


def dh_pub_value(v):
    """The peer's DH public value as an int, or None when it is not a canonical
    lowercase hex number y with 1 < y < p-1 in the prime-order subgroup (y^q = 1),
    so 0, 1, p-1, values >= p and small-subgroup elements are all refused."""
    if not isinstance(v, str) or not DH_HEX_RE.fullmatch(v):
        return None
    y = int(v, 16)
    if not 1 < y < PAIR_P - 1:
        return None
    if v not in _DH_VALID:
        if pow(y, PAIR_Q, PAIR_P) != 1:
            return None
        if len(_DH_VALID) >= WARN_TAGS_MAX:
            _DH_VALID.clear()
        _DH_VALID.add(v)
    return y


def pair_key(ident, peer_id, peer_pub):
    """K = sha256(tag | sorted ids | shared DH secret), hex. Both sides get the same K."""
    shared = pow(peer_pub, ident["x"], PAIR_P)
    lo, hi = sorted((ident["id"], peer_id))
    return hashlib.sha256(("%s|%s|%s|%x" % (PAIR_TAG, lo, hi, shared)).encode("ascii")).hexdigest()


PAIR_ANY = "*"   # the opener's expectation for an address bound to no paired id


def pair_expect_str(v):
    """The opener's "expect" field: the peer id it has bound to the address it dialed,
    or PAIR_ANY (also for anything malformed)."""
    return peer_id_str(v) or PAIR_ANY


def pair_proof(key, role, sender, receiver, c_open, c_accept, expect):
    """Proof of K for one handshake: bound to the role ("A" acceptor, "O" opener, so a
    proof is never valid when reflected), both ids in sender order, the fresh
    challenges of BOTH sides (so a captured proof is never valid again) and the
    opener's expectation for the address it dialed (the id bound there, or PAIR_ANY).
    Slot binding is enforced separately: a paired id is never accepted at another
    slot than its own (see PairStore.pin, _pair_accept, _pair_open)."""
    msg = "%s|proof|%s|%s|%s|%s|%s|%s" % (PAIR_TAG, role, sender, receiver, c_open, c_accept, expect)
    return hmac.new(bytes.fromhex(key), msg.encode("ascii"), hashlib.sha256).hexdigest()


def pair_session_key(key, opener, acceptor, c_open, c_accept, expect):
    msg = "%s|session|%s|%s|%s|%s|%s" % (PAIR_TAG, opener, acceptor, c_open, c_accept, expect)
    return hmac.new(bytes.fromhex(key), msg.encode("ascii"), hashlib.sha256).digest()


class PairLink(object):
    """Pairing state of one authenticated link: the paired peer id and the per-link
    session key. Every frame carries, besides the token MAC, a "pmac" over the body
    bound to the sending direction and a per-direction sequence number (TCP keeps the
    order), so a frame is never valid when injected, replayed, reordered or reflected."""

    def __init__(self, pair_id, skey, tx_label, rx_label, to_pin=None):
        self.pair_id = pair_id
        self.skey = skey
        self.tx_label, self.rx_label = tx_label, rx_label
        self.tx_seq = 0
        self.rx_seq = 0
        # (pid, pub, key, slot, machine) still to be stored: a new pairing is written
        # only once the whole handshake (both proofs AND the ack) went through
        self.to_pin = to_pin

    def _mac(self, label, seq, body):
        return hmac.new(self.skey, ("%s|%d|" % (label, seq)).encode("ascii") + body.encode("utf-8"),
                        hashlib.sha256).hexdigest()

    def frame(self, token, payload):
        """One wire line. Callers serialize sends per link (Channel.wlock)."""
        body = json.dumps(payload, separators=(",", ":"), sort_keys=True)
        wire = {"body": body, "pmac": self._mac(self.tx_label, self.tx_seq, body)}
        if token:
            wire["mac"] = sign(token, body)
        self.tx_seq += 1
        return json.dumps(wire) + "\n"

    def verify(self, token, line):
        """The payload of the next frame from the peer, or None (wrong token MAC, wrong
        or missing pair MAC, out of sequence). Only one reader per link calls this."""
        payload = verify_line(token, line)
        if payload is None:
            return None
        try:
            wire = json.loads(line)
            body, pm = wire.get("body"), wire.get("pmac")
            if not proof_eq(pm, self._mac(self.rx_label, self.rx_seq, body)):
                return None
        except Exception:
            return None
        self.rx_seq += 1
        return payload


def default_keys_dir():
    return os.path.join(os.path.dirname(config_path()), "peer-lan-keys")


def keys_dir_for(cfg):
    d = (cfg or {}).get("keys_dir")
    return d if isinstance(d, str) and d else default_keys_dir()


class PairStoreUnreadable(OSError):
    """The pairing key dir exists (or may exist) but cannot be listed or read right
    now (EACCES, EMFILE, EIO, ...). Callers treat every slot as bound to an unknown
    paired peer (fail closed) instead of as unbound."""


class PairIdentityInvalid(ValueError):
    """This installation's identity file is present but not a valid identity. It is
    left untouched (never replaced): pairing stays off until it is fixed or moved
    away, and only then is a new identity created."""


# _bound() stand-in while the key store is unreadable: an id no peer can have (not
# 32 hex chars), so no link is ever authenticated as it.
PAIR_UNKNOWN_ID = "unreadable"


class PairStore(object):
    """Pairing state on disk, one 0600 file per paired peer id plus this installation's
    identity, in a 0700 dir. Every write goes to a fresh O_EXCL temp file and is then
    renamed over the target (atomic: a reader sees the old or the new file, never a
    torn one); files are opened with O_NOFOLLOW (a planted symlink is never followed).
    Nothing is cached, so a `pair-reset` from the CLI applies to a running daemon at
    once. Corrupt peer and pending files count as absent and never raise; the
    identity file is never replaced once it exists (see identity())."""

    SELF = "self.json"
    PENDING = "pending-repair.json"

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self._ident = None

    # -- files ----------------------------------------------------------------
    def _ensure_dir(self):
        old = os.umask(0o077)
        try:
            os.makedirs(self.path, mode=0o700, exist_ok=True)
        finally:
            os.umask(old)
        st = os.stat(self.path)
        if st.st_uid == os.getuid() and (st.st_mode & 0o777) != 0o700:
            os.chmod(self.path, 0o700)

    def _read(self, name, strict=False, missing=None):
        """The JSON in name, None when it is corrupt, missing when it does not exist.
        strict: an open or read error other than "missing" raises PairStoreUnreadable
        instead."""
        try:
            fd = os.open(os.path.join(self.path, name), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        except FileNotFoundError:
            return missing
        except OSError as exc:
            if strict:
                raise PairStoreUnreadable(exc.errno, "pairing key file %s unreadable: %s"
                                          % (name, exc.strerror or exc))
            return None
        try:
            with os.fdopen(fd, "r") as fh:
                return json.load(fh)
        except OSError as exc:
            if strict:
                raise PairStoreUnreadable(exc.errno, "pairing key file %s unreadable: %s"
                                          % (name, exc.strerror or exc))
            return None
        except Exception:
            return None

    def _tmp_write(self, name, obj):
        """obj into a fresh 0600 temp file next to name; returns its path."""
        self._ensure_dir()
        tmp = os.path.join(self.path, ".%s.tmp-%d-%s" % (name, os.getpid(), secrets.token_hex(4)))
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            with os.fdopen(fd, "w") as fh:
                os.fchmod(fh.fileno(), 0o600)
                json.dump(obj, fh)
                fh.flush()
                os.fsync(fh.fileno())
        except BaseException:
            self._unlink_quiet(tmp)
            raise
        return tmp

    def _unlink_quiet(self, path):
        try:
            os.unlink(path)
        except OSError:
            pass

    def _write(self, name, obj):
        tmp = self._tmp_write(name, obj)
        try:
            os.replace(tmp, os.path.join(self.path, name))
        except BaseException:
            self._unlink_quiet(tmp)
            raise

    # -- identity ---------------------------------------------------------------
    @staticmethod
    def _valid_ident(d):
        if not isinstance(d, dict) or not peer_id_str(d.get("id")):
            return None
        x, pub = d.get("x"), d.get("pub")
        if not (isinstance(x, str) and DH_HEX_RE.fullmatch(x) and isinstance(pub, str)):
            return None
        xi = int(x, 16)
        if xi < 2 or "%x" % pow(PAIR_G, xi, PAIR_P) != pub:
            return None
        return {"id": d["id"], "x": xi, "pub": pub}

    def _existing_ident(self):
        """The stored identity, or None when there is no identity file. Raises
        PairStoreUnreadable when it cannot be read right now and PairIdentityInvalid
        when it is present but not a valid identity; both leave the file untouched."""
        absent = object()
        d = self._read(self.SELF, strict=True, missing=absent)
        if d is absent:
            return None
        ident = self._valid_ident(d)
        if ident is not None:
            return ident
        raise PairIdentityInvalid(
            "pairing identity %s is not a valid identity; it is left untouched (pairing "
            "stays off until it is fixed or moved away, then a new identity is created)"
            % os.path.join(self.path, self.SELF))

    def identity(self):
        """This installation's {id, x (private int), pub (hex)}; created on first use.
        Concurrent first starts agree on one identity (link(2) never overwrites). An
        existing identity file is never replaced: when it cannot be read or is not
        valid this raises (OSError / ValueError) and the file stays as it is."""
        with self.lock:
            if self._ident is not None:
                return self._ident
            ident = self._existing_ident()
            if ident is None:
                x = secrets.randbits(PAIR_X_BITS) | (1 << (PAIR_X_BITS - 1))
                new = {"id": secrets.token_hex(16), "x": "%x" % x, "pub": "%x" % pow(PAIR_G, x, PAIR_P)}
                tmp = self._tmp_write(self.SELF, new)
                try:
                    os.link(tmp, os.path.join(self.path, self.SELF))
                    ident = self._valid_ident(new)
                except FileExistsError:
                    # created meanwhile (a concurrent first start): use that one
                    ident = self._existing_ident()
                    if ident is None:
                        raise PairStoreUnreadable(errno.EAGAIN, "pairing key file %s changed "
                                                  "during creation; retried later" % self.SELF)
                finally:
                    self._unlink_quiet(tmp)
            self._ident = ident
            return ident

    # -- paired peers -------------------------------------------------------------
    @staticmethod
    def _valid_rec(d, pid):
        if not isinstance(d, dict) or d.get("id") != pid:
            return None
        pub, key, slot = d.get("pub"), d.get("key"), d.get("slot")
        if not (isinstance(pub, str) and DH_HEX_RE.fullmatch(pub) and isinstance(key, str)
                and KEY_HEX_RE.fullmatch(key) and isinstance(slot, str)):
            return None
        m = d.get("machine")
        return {"id": pid, "pub": pub, "key": key, "slot": slot,
                "machine": m[:60] if isinstance(m, str) else ""}

    def get(self, pid, strict=False):
        pid = peer_id_str(pid)
        if not pid:
            return None
        return self._valid_rec(self._read("peer-%s.json" % pid, strict), pid)

    def records(self):
        """Every valid paired record. A key dir that does not exist yet has none; a
        dir (or peer file) that cannot be read raises PairStoreUnreadable, never []."""
        try:
            names = sorted(os.listdir(self.path))
        except FileNotFoundError:
            return []
        except OSError as exc:
            raise PairStoreUnreadable(exc.errno, "pairing key dir %s unreadable: %s"
                                      % (self.path, exc.strerror or exc))
        out = []
        for n in names:
            if n.startswith("peer-") and n.endswith(".json"):
                r = self.get(n[5:-5], strict=True)
                if r is not None:
                    out.append(r)
        return out

    def by_slot(self, slot):
        for r in self.records():
            if r["slot"] == slot:
                return r
        return None

    def pin(self, pid, pub, key, slot, machine=""):
        """Store the pairing of pid at slot (or refresh its machine label). A slot
        belongs to at most one paired id and a paired id to exactly one slot: False
        (nothing written) when another id already holds the slot, so two first
        contacts racing for one slot can never both get it, and also when pid is
        already bound to ANOTHER slot - a paired id is never moved silently (its old
        slot would be left unbound for anyone); only `pair-reset` moves it."""
        with self.lock:
            other = self.by_slot(slot)
            if other is not None and other["id"] != pid:
                return False
            cur = self.get(pid, strict=True)   # unreadable: raise, never overwrite it
            if cur is not None and (cur["slot"] != slot or cur["pub"] != pub or cur["key"] != key):
                return False
            self._write("peer-%s.json" % pid, {"id": pid, "pub": pub, "key": key, "slot": slot,
                                              "machine": str(machine or "")[:60]})
            return True

    # -- pending repairs (a new id or key at a paired slot, refused) ---------------
    def pending(self, strict=False):
        d = self._read(self.PENDING, strict)
        if not isinstance(d, list):
            return []
        keep = ("slot", "old_id", "new_id", "machine", "reason")
        out = []
        for e in d:
            if isinstance(e, dict):
                r = {k: str(e.get(k, ""))[:120] for k in keep}
                # the pair-reset argument that accepts it (older entries: the slot)
                r["fix"] = str(e.get("fix") or r["slot"])[:120]
                out.append(r)
        return out

    def add_pending(self, entry):
        """Record a refused claim once per slot (the first one; later claims with other,
        sender-chosen ids neither add entries nor log lines); True when it is new."""
        with self.lock:
            cur = self.pending(strict=True)   # unreadable: raise, never drop the others
            if any(e["slot"] == entry.get("slot") for e in cur):
                return False
            cur.append({k: str(entry.get(k, "") or (entry.get("slot", "") if k == "fix" else ""))[:120]
                        for k in ("slot", "old_id", "new_id", "machine", "reason", "fix")})
            self._write(self.PENDING, cur[-PENDING_REPAIR_MAX:])
            return True

    def reset(self, selector):
        """Forget the pairing(s) matching selector (peer id or an 8+ char prefix of it,
        slot host:port, host, or machine label) and the pending repairs for them, so
        the next link pairs again. Returns (removed records, removed pending)."""
        sel = str(selector or "").strip()
        if not sel:
            return [], []

        def hit_id(pid):
            return bool(pid) and (pid == sel or (len(sel) >= 8 and pid.startswith(sel)))

        def hit_slot(slot):
            return bool(slot) and (slot == sel or slot.rsplit(":", 1)[0] == sel)

        with self.lock:
            gone = [r for r in self.records()
                    if hit_id(r["id"]) or hit_slot(r["slot"]) or (r["machine"] and r["machine"] == sel)]
            cur = self.pending(strict=True)   # read before anything is removed
            for r in gone:
                self._unlink_quiet(os.path.join(self.path, "peer-%s.json" % r["id"]))
            slots = set(r["slot"] for r in gone)
            ids = set(r["id"] for r in gone)
            drop = [e for e in cur if e["slot"] in slots or e["old_id"] in ids or e["new_id"] in ids
                    or hit_slot(e["slot"])
                    or hit_id(e["new_id"]) or hit_id(e["old_id"]) or (e["machine"] and e["machine"] == sel)]
            if drop:
                self._write(self.PENDING, [e for e in cur if e not in drop])
            return gone, drop


def recv_line(sock, buf):
    """Read one newline-terminated line. Returns (line, rest) or (None, buf) on EOF.
    Raises socket.timeout / OSError, or ValueError for an oversize line."""
    while b"\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            return None, buf
        buf += chunk
        if len(buf) > MAX_LINE:
            raise ValueError("oversize line")
    line, _, rest = buf.partition(b"\n")
    return line, rest


def open_link_socket(host, port, timeout):
    """TCP connect for an outbound link. TEST-ONLY: with CREDO_PEER_LAN_TEST_SENDLOG
    set it records "link <host>:<port>" and connects nowhere (returns None), so LAN-
    shaped peers in tests never touch a real network."""
    testlog = os.environ.get("CREDO_PEER_LAN_TEST_SENDLOG")
    if testlog:
        with open(testlog, "a") as fh:
            fh.write("link %s:%s\n" % (host, port))
        return None
    return socket.create_connection((host, int(port)), timeout=timeout)


def _sock_desc(sock):
    try:
        loc, rem = sock.getsockname(), sock.getpeername()
        return "%s:%s>%s:%s" % (loc[0], loc[1], rem[0], rem[1])
    except (OSError, TypeError, IndexError):
        return "?"


_CHANNEL_IDS = itertools.count(1)


class Channel(object):
    """One persistent link to a peer address. direction "out" = we opened it, "in" =
    the peer opened it. addr is the peer address its frames are attributed to (the
    forward target, resolved like a roster); src_ip is the socket's remote IP.
    secret = the link's random secret (generated by its opener, sent only in its
    hello); proof = the link_proof the peer sent with it (hello for "in", ack for
    "out"); resume = the resume_proof of an inbound hello. pair = the PairLink of a
    link authenticated with a pairing key (None: an unpaired, token-only link)."""

    def __init__(self, sock, addr, known, direction, src_ip, remote_machine,
                 remote_port, remote_interval, remote_nonce="", secret="", proof="",
                 resume="", pair=None):
        self.cid = next(_CHANNEL_IDS)
        self.sock = sock
        # writes go through a dup of the socket with its own short timeout, so a peer
        # that stops reading fails the write fast while the reader keeps its longer
        # read timeout (Python timeouts are per socket object, not per fd)
        try:
            self.wsock = sock.dup()
            self.wsock.settimeout(CHAN_WRITE_TIMEOUT)
        except (AttributeError, OSError):
            self.wsock = sock
        self.write_timeout = CHAN_WRITE_TIMEOUT
        self.addr = (addr[0], int(addr[1]))
        self.key = "%s:%d" % self.addr
        self.known = known
        self.direction = direction
        self.src_ip = src_ip
        self.remote_machine = str(remote_machine or "")
        try:
            self.remote_port = int(remote_port or 0)
        except (TypeError, ValueError):
            self.remote_port = 0
        try:
            self.remote_interval = min(max(float(remote_interval or 0), 0.0), 600.0)
        except (TypeError, ValueError):
            self.remote_interval = 0.0
        self.remote_nonce = str(remote_nonce or "")[:64]
        self.secret = _secret_str(secret)
        self.proof = _secret_str(proof)
        self.resume = _secret_str(resume)
        self.pair = pair
        self.pair_id = pair.pair_id if pair is not None else ""
        self.desc = _sock_desc(sock)
        self.wlock = threading.Lock()
        self.closed = False
        self.registered = False
        self.last_tx = time.monotonic()
        self.last_rx = self.last_tx  # last frame received (idle detection)
        self.bye = ""  # why the peer is about to close this link (its goodbye ping)

    def idle(self, limit):
        """No frame received for longer than limit seconds (a half-dead link)."""
        return time.monotonic() - self.last_rx > limit

    def send_line(self, data):
        """Write one frame within write_timeout (total, lock wait included). Raises
        socket.timeout / OSError; the caller then drops the channel."""
        self._send(lambda: data)

    def send_payload(self, token, payload):
        """Frame payload for this link (token MAC; plus the pair MAC and the next
        sequence number on a paired link, assigned under the write lock so the wire
        order matches the numbering) and write it like send_line."""
        if self.pair is None:
            return self._send(lambda: frame_for(token, payload).encode("utf-8"))
        return self._send(lambda: self.pair.frame(token, payload).encode("utf-8"))

    def verify(self, token, line):
        """Payload of a frame read from this link, or None when it is not acceptable."""
        if self.pair is None:
            return verify_line(token, line)
        return self.pair.verify(token, line)

    def send_bye(self, token, why, timeout=BYE_TIMEOUT):
        """Goodbye ping within a short total deadline (lock wait + write). Only on a
        dedicated write socket, whose timeout can change without touching the reader;
        otherwise it is skipped. Raises like send_line."""
        if self.wsock is self.sock:
            return
        payload = {"kind": "ping", "bye": why}
        if self.pair is None:
            make = lambda: frame_for(token, payload).encode("utf-8")
        else:
            make = lambda: self.pair.frame(token, payload).encode("utf-8")
        self._send(make, timeout)

    def _send(self, make, timeout=None):
        limit = self.write_timeout if timeout is None else timeout
        deadline = time.monotonic() + limit
        if not self.wlock.acquire(timeout=limit):
            raise socket.timeout("channel write busy for %.1fs" % limit)
        try:
            if self.closed:
                raise OSError("channel closed")
            if timeout is None:
                self.wsock.sendall(make())
            else:
                left = deadline - time.monotonic()
                if left <= 0:
                    raise socket.timeout("channel write busy for %.1fs" % limit)
                self.wsock.settimeout(left)
                try:
                    self.wsock.sendall(make())
                finally:
                    self.wsock.settimeout(self.write_timeout)
            self.last_tx = time.monotonic()
        finally:
            self.wlock.release()

    def close(self):
        self.closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        for s in (self.sock, self.wsock):
            try:
                s.close()
            except OSError:
                pass


def warn_once(tags, tag):
    """True the first time tag is seen (the caller logs then). The set is capped at
    WARN_TAGS_MAX entries and starts over when full, so it never grows unbounded."""
    if tag in tags:
        return False
    if len(tags) >= WARN_TAGS_MAX:
        tags.clear()
    tags.add(tag)
    return True


def _relay_connect(path, timeout):
    """Connect to the daemon's relay unix socket. A full accept queue (EAGAIN, or a
    connect timeout) is retried briefly and then reported as "busy" (None) - the
    daemon is alive, so the caller must NOT bypass it. Raises ConnectionError only
    when the socket is really unreachable (missing, refused)."""
    for attempt in range(RELAY_BUSY_RETRIES + 1):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(path)
            return s
        except (BlockingIOError, socket.timeout):
            s.close()
        except OSError as exc:
            s.close()
            if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                raise ConnectionError(str(exc))
        if attempt < RELAY_BUSY_RETRIES:
            time.sleep(RELAY_BUSY_SLEEP)
    return None


def relay_via_daemon(path, host, port, payload, timeout=10.0):
    """Holder -> local daemon: hand a deliver to the daemon's relay unix socket so it
    goes out over the return channel when one exists. Raises ConnectionError only
    when the relay socket cannot be reached (the caller may then send directly, the
    pre-channel path, unless it is a --no-direct holder); a busy relay socket yields
    an "err" reply instead; once connected, returns the daemon's one-line reply."""
    s = _relay_connect(path, timeout)
    if s is None:
        return "err relay socket busy"
    try:
        req = {"peer_host": host, "peer_port": int(port), "payload": payload}
        try:
            s.sendall((json.dumps(req) + "\n").encode("utf-8"))
            line, _ = recv_line(s, b"")
        except (OSError, ValueError) as exc:
            return "err relay: %s" % exc
        return (line or b"err no reply").decode("utf-8", "replace").strip()
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


# subcommands whose process runs the daemon itself (restart/start spawn `daemon`)
DAEMON_SUBCOMMANDS = (b"daemon", b"ensure")


def _is_daemon_argv(argv):
    """argv (bytes, from /proc/<pid>/cmdline) has the shape of a running daemon: a
    python interpreter, optional interpreter flags, the credo-peer-lan.py script and a
    daemon subcommand right after it. A pager or editor on the script, a shell whose
    command string mentions it, or a non-daemon subcommand never match."""
    if len(argv) < 3 or not os.path.basename(argv[0]).startswith(b"python"):
        return False
    i = 1
    while i < len(argv) and argv[i].startswith(b"-"):
        if argv[i] in (b"-c", b"-m"):
            return False
        i += 1
    return (i + 1 < len(argv)
            and os.path.basename(argv[i]) == b"credo-peer-lan.py"
            and argv[i + 1] in DAEMON_SUBCOMMANDS)


def daemon_is_alive(pid, pstart=None):
    """True only when pid is a live credo-peer-lan daemon. Requires os.kill(pid,0) AND,
    when /proc is available, that /proc/<pid>/cmdline has the argv shape of a daemon
    (_is_daemon_argv) and, when pstart is given, that the process start time matches -
    so a reused pid of an unrelated process (even one that has the script open) is
    never mistaken for our daemon. Our own pid never counts. When /proc is absent,
    falls back to os.kill alone."""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0 or pid == os.getpid():
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    if os.path.isdir("/proc"):
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as fh:
                argv = fh.read().split(b"\0")
        except OSError:
            # /proc present but this pid's entry vanished -> it is not alive
            return False
        if not _is_daemon_argv(argv):
            return False
        if isinstance(pstart, str) and pstart:
            try:
                return proc_start(pid) == pstart
            except (OSError, ValueError, IndexError):
                return False
        return True
    return True  # no /proc at all -> trust os.kill


def pidfile_daemon(pf=None):
    """pid of the live daemon the pidfile records for THIS config, or None. Only that
    pid is ever signaled (stop/restart/ensure) - never a process found by a command-line
    pattern, which would also hit the caller's own shell. Beyond daemon_is_alive it
    checks, when the pidfile has them, the recorded config path and the process start
    time, so a recycled pid is never taken for the daemon."""
    if pf is None:
        pf = read_pidfile()
    if not isinstance(pf, dict):
        return None
    pid = pf.get("pid")
    if not daemon_is_alive(pid, pf.get("pstart")):
        return None
    cfg = pf.get("config")
    if isinstance(cfg, str) and cfg and os.path.abspath(cfg) != os.path.abspath(config_path()):
        return None
    return int(pid)


def relay_log_path():
    """The relay log next to the config (the file the autostart hook appends to)."""
    return os.path.join(os.path.dirname(config_path()), "peer-lan.log")


def spawn_detached_daemon():
    """Start `credo-peer-lan.py daemon` fully detached from the caller: a new session
    (no controlling terminal, own process group, so the caller's shell exiting or being
    killed never takes it along), stdin from /dev/null, stdout/stderr appended to the
    relay log. Returns the child pid."""
    path = relay_log_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(os.devnull, "rb") as devnull, open(path, "ab") as out:
        proc = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "daemon"],
            stdin=devnull,
            stdout=out,
            stderr=subprocess.STDOUT,
            close_fds=True,
            start_new_session=True,
            cwd="/",
        )
    return proc.pid


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


def _terminate_incumbent(pid, host, port, timeout=TERMINATE_TIMEOUT, pstart=None):
    """SIGTERM pid, then poll up to timeout until the pid is gone AND the listen port is
    free. Returns True iff the port became free (so a replacement can bind), else False.
    pstart (the pidfile's process start time) keeps a reused pid from reading as alive.
    Never raises - it is called where leaving a running daemon alone is the safe default."""
    try:
        os.kill(int(pid), signal.SIGTERM)
    except (OSError, ValueError, TypeError):
        pass
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not daemon_is_alive(pid, pstart) and port_is_free(host, port):
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


def descriptor_live(d):
    """True when the descriptor's pid is a live process and, when the descriptor
    records procStart, that it matches field 22 of /proc/<pid>/stat (pid reuse)."""
    pid = d.get("pid")
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        cur = proc_start(pid)
    except (OSError, ValueError, IndexError):
        return False
    want = d.get("procStart")
    if want not in (None, "") and str(want) != cur:
        return False
    # a pid from another pid namespace is not this process (pidDomain ends in pid:[ns])
    dom = d.get("pidDomain")
    m = re.search(r"(pid:\[\d+\])$", dom) if isinstance(dom, str) else None
    if m:
        try:
            own = os.readlink("/proc/self/ns/pid")
        except OSError:
            own = None
        if own and own != m.group(1):
            return False
    return True


class InjectMaybeSent(Exception):
    """The inject failed after frame bytes may already have reached the inbox; a
    retry into another descriptor of the same session could deliver it twice."""


def _desc_time(d):
    for k in ("updatedAt", "statusUpdatedAt", "startedAt"):
        v = d.get(k)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            return v
    return 0


def resolve_sockets(sess_dir, session_id):
    """(live candidates, stale count) for a sessionId. After a crash or resume the
    registry can hold several descriptors of one session: a dead one with an old
    socket path (e.g. under a vanished runtime dir) next to the live one. Only live
    descriptors count (descriptor_live); newest updatedAt first. Each candidate is
    (socket path, pid). Descriptor files are never touched."""
    live, stale = [], 0
    for d in read_local_sessions(sess_dir):
        if d.get("sessionId") != session_id:
            continue
        if descriptor_live(d):
            live.append(d)
        else:
            stale += 1
    live.sort(key=_desc_time, reverse=True)
    return [(d.get("messagingSocketPath"), d.get("pid")) for d in live], stale


def resolve_socket(sess_dir, session_id):
    cands, _ = resolve_sockets(sess_dir, session_id)
    return cands[0][0] if cands else None


def deliver_local(sess_dir, session_id, from_name, body, reply, trust=None):
    """Inject into the live local session: the newest live descriptor first, the
    next live one when an inject fails. Logs the chosen descriptor. Returns the
    socket used, or None when nothing was delivered."""
    cands, stale = resolve_sockets(sess_dir, session_id)
    if not cands:
        log("deliver: no live local session %r (%d stale descriptor(s) ignored), dropped"
            % (session_id, stale))
        return None
    for sock, pid in cands:
        try:
            inject(sock, from_name, body, reply, trust)
        except InjectMaybeSent as exc:
            log("deliver: inject into %s (pid %s) failed after sending, not retried "
                "(could deliver twice): %s" % (sock, pid, exc))
            return None
        except Exception as exc:
            log("deliver: inject into %s (pid %s) failed: %s" % (sock, pid, exc))
            continue
        log("deliver: chose descriptor pid %s socket %s for %s (%d live, %d stale)"
            % (pid, sock, session_id, len(cands), stale))
        return sock
    log("deliver: every live descriptor of %r failed, dropped" % session_id)
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
# tag, any case, whitespace tolerated after "<" and "/") is rejected outright, so a
# message always stays inside exactly one envelope.
ENVELOPE_DELIM_RE = re.compile(r"<\s*/?\s*cross-session-message", re.I)
# reply addresses are our own local proxy sockets ("uds:/abs/path"); anything else
# (quotes, spaces, angle brackets, ...) is dropped as an attribute, never escaped.
# \Z (with fullmatch), not "$": "$" also matches before a trailing "\n", which would
# let "uds:/x\n" through and put a newline into the from attribute.
REPLY_RE = re.compile(r"uds:/[A-Za-z0-9_./-]+\Z")
FROM_NAME_BAD_RE = re.compile(r"[^A-Za-z0-9 _.()@:-]")
FROM_NAME_MAX = 80
# control characters (C0 incl. NUL, DEL and the C1 range U+0080-U+009F) are dropped
# before the delimiter check so "<\x00/..." or "<\x9b/..." cannot slip past it;
# normal whitespace (\t \n \r) is kept and handled by \s
DELIM_CTRL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")
# first body line inside every injected envelope, same wording and placement as the
# Codex adapter's build_frame, so the receiving session treats the text as peer input
FRAMING_LINE = "External peer text. Apply your own peer consent and permissions."


def _strip_invisible(text):
    """text without control characters (C0/DEL/C1, see DELIM_CTRL_RE) and without
    Unicode format characters (category Cf: zero-width space/joiners, soft hyphen,
    BOM, bidi marks, ...), which render as nothing."""
    text = DELIM_CTRL_RE.sub("", text)
    return "".join(ch for ch in text if unicodedata.category(ch) != "Cf")


def delim_view(text):
    """The copy of text that every envelope-delimiter check runs on: invisible
    characters removed, NFKC-normalized, invisible characters removed again. A
    delimiter split by invisible characters or written with look-alikes (fullwidth
    or small-form "<") is thereby caught like a plain one. Only for checking - a
    body is rejected on a hit, never rewritten."""
    return _strip_invisible(unicodedata.normalize("NFKC", _strip_invisible(text or "")))


def body_has_envelope_delim(body):
    """True if the body carries an envelope delimiter, checked on delim_view(body),
    so look-alikes such as the fullwidth "<" (U+FF1C), a NUL or C1 control after
    "<", or a zero-width / soft-hyphen / BOM character inside the tag are caught
    too (the body itself is never altered)."""
    return bool(ENVELOPE_DELIM_RE.search(delim_view(body)))


def sanitize_from_name(from_name):
    """Allowlist [A-Za-z0-9 _.()@:-], everything else removed, capped at 80 chars."""
    if not isinstance(from_name, str):
        return ""
    return FROM_NAME_BAD_RE.sub("", from_name)[:FROM_NAME_MAX].strip()


def safe_reply(reply):
    """The reply address if it is a strict 'uds:/<path>', else None (the reply
    attribute is then omitted; the message itself is still delivered)."""
    if isinstance(reply, str) and REPLY_RE.fullmatch(reply):
        return reply
    return None


def build_envelope(body, from_name, reply, trust=None):
    """trust: (key, peer_id) from trust_lookup for a verified trusted paired sender;
    only then are the credo-trust attributes added (see the trusted peers section)."""
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
    inner = FRAMING_LINE + "\n" + body
    if trust and safe:
        key, pid = trust
        attrs.append('credo-trust-peer="%s"' % peer_id_str(pid))
        attrs.append('credo-trust="%s"' % trust_mac(key, peer_id_str(pid), safe, inner))
    head = "<cross-session-message" + "".join(" " + a for a in attrs) + ">"
    return head + "\n" + inner + "\n</cross-session-message>"


def inject(target_socket, from_name, body, reply, trust=None):
    """Write one cross-session-message frame into a local inbox unix socket.
    reply is a 'uds:<path>' address or None. No from-mode is ever set. trust: see
    build_envelope (None for every sender that is not a trusted paired peer)."""
    reply = safe_reply(reply)
    envelope = build_envelope(body, from_name, reply, trust)
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
        try:
            s.sendall(line)
        except OSError as exc:
            raise InjectMaybeSent(str(exc))
        try:
            s.shutdown(socket.SHUT_WR)
        except OSError:
            pass  # the whole frame was sent; the inbox has it
    finally:
        s.close()


# ---------------------------------------------------------------------------
# trusted peers (local, per receiving machine)
# ---------------------------------------------------------------------------
# The user of THIS machine may declare that tasks from one named session on one
# PAIRED peer count like the user's own tasks. The grant lives only here, in a 0600
# file next to the config, and is written only by the `trust` CLI; nothing that
# arrives over the wire ever reads into it or writes it. An entry binds the sender's
# pairing peer id, its pinned DH public value (a re-paired id with another key never
# inherits it) and its session name (the from-name the paired machine reports).
#
# When a deliver arrives over a link authenticated as that paired id from that
# session name, the daemon adds two attributes to the OPENING tag of the envelope it
# builds: credo-trust-peer (the peer id) and credo-trust, an HMAC under a random key
# that only this file holds, over peer id, session name and the envelope text. The
# body can never reach the opening tag (envelope delimiters are refused) and a forged
# attribute fails the HMAC, so the peer-message hook (`trust verify`) can tell a
# relay-made marker from text. Verification re-reads the file and the pairing store
# every time, so `trust remove` / `pair-reset` end the trust at once.
TRUST_FILE = "peer-lan-trust.json"
TRUST_TAG = "credo-peer-lan-trust-v1"
TRUST_KEY_RE = re.compile(r"[0-9a-f]{64}")
TRUST_MAC_RE = re.compile(r"[0-9a-f]{64}")
TRUST_ATTR_RE = re.compile(r' ([a-z][a-z-]*)="([^"<>]*)"')
TRUST_ENVELOPE_RE = re.compile(
    r'\A\s*<cross-session-message((?: [a-z][a-z-]*="[^"<>]*")*)>\n(.*)\n</cross-session-message>\s*\Z',
    re.S)
TRUST_TAG_MARK_RE = re.compile(r"<\s*cross-session-message[^>]*credo-trust", re.I)


def trust_path():
    return os.path.join(os.path.dirname(config_path()), TRUST_FILE)


def _trust_entry(e):
    """A stored trust entry in canonical form, or None when it is not valid."""
    if not isinstance(e, dict):
        return None
    pid, pub, sess, machine = e.get("peer_id"), e.get("pub"), e.get("session"), e.get("machine")
    if not (peer_id_str(pid) and isinstance(pub, str) and DH_HEX_RE.fullmatch(pub)
            and isinstance(sess, str) and sess and sanitize_from_name(sess) == sess):
        return None
    return {"peer_id": pid, "pub": pub, "session": sess,
            "machine": sanitize_from_name(machine) if isinstance(machine, str) else ""}


class TrustStore(object):
    """The local trust list: {"key": hex, "trusted": [entries]} in one 0600 file.
    A missing, unreadable or corrupt file means no trust (fail closed). Writes go to
    a fresh O_EXCL temp file renamed over the target; reads never follow a symlink."""

    def __init__(self, path):
        self.path = path

    def read(self):
        empty = {"key": "", "trusted": []}
        try:
            fd = os.open(self.path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        except OSError:
            return empty
        try:
            with os.fdopen(fd, "r") as fh:
                d = json.load(fh)
        except Exception:
            return empty
        if not isinstance(d, dict):
            return empty
        key = d.get("key")
        out = {"key": key if isinstance(key, str) and TRUST_KEY_RE.fullmatch(key) else "",
               "trusted": []}
        for e in d.get("trusted") or []:
            e = _trust_entry(e)
            if e is not None:
                out["trusted"].append(e)
        return out

    def _write(self, obj):
        d = os.path.dirname(self.path) or "."
        os.makedirs(d, exist_ok=True)
        tmp = os.path.join(d, ".%s.tmp-%d-%s" % (os.path.basename(self.path), os.getpid(),
                                                 secrets.token_hex(4)))
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            with os.fdopen(fd, "w") as fh:
                os.fchmod(fh.fileno(), 0o600)
                json.dump(obj, fh, indent=2)
                fh.write("\n")
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def add(self, peer_id, pub, session, machine=""):
        """Trust session on the paired peer (peer_id, pub). True when it is new."""
        e = _trust_entry({"peer_id": peer_id, "pub": pub, "session": session, "machine": machine})
        if e is None:
            raise ValueError("invalid trust entry")
        cur = self.read()
        if any(x["peer_id"] == e["peer_id"] and x["session"] == e["session"] and x["pub"] == e["pub"]
               for x in cur["trusted"]):
            return False
        cur["key"] = cur["key"] or secrets.token_hex(32)
        cur["trusted"] = [x for x in cur["trusted"]
                          if not (x["peer_id"] == e["peer_id"] and x["session"] == e["session"])]
        cur["trusted"].append(e)
        self._write(cur)
        return True

    def remove(self, pred):
        """Drop every entry pred(entry) is true for; returns the removed entries."""
        cur = self.read()
        gone = [x for x in cur["trusted"] if pred(x)]
        if gone:
            cur["trusted"] = [x for x in cur["trusted"] if not pred(x)]
            self._write(cur)
        return gone


def trust_lookup(peer_id, session, pairs, store):
    """(key, entry, paired record) when session on paired peer peer_id is trusted
    here: an entry for exactly that id and name, and the id is still paired with
    the same DH public value. None otherwise (also on any read problem)."""
    pid = peer_id_str(peer_id)
    if not pid or not isinstance(session, str) or not session or sanitize_from_name(session) != session:
        return None
    data = store.read()
    if not data["key"]:
        return None
    for e in data["trusted"]:
        if e["peer_id"] == pid and e["session"] == session:
            try:
                rec = pairs.get(pid)
            except Exception:
                return None
            if rec is None or rec["pub"] != e["pub"]:
                return None
            return data["key"], e, rec
    return None


def trust_mac(key, peer_id, session, inner):
    """The credo-trust marker: HMAC over peer id, session name and the envelope text
    (the lines between the tags, CRLF folded, outer whitespace stripped)."""
    text = (inner or "").replace("\r\n", "\n").strip()
    msg = "%s|%s|%s|%s" % (TRUST_TAG, peer_id, session,
                           hashlib.sha256(text.encode("utf-8")).hexdigest())
    return hmac.new(bytes.fromhex(key), msg.encode("ascii"), hashlib.sha256).hexdigest()


def verify_trust_prompt(prompt, pairs=None, store=None):
    """Check a delivered prompt for a valid trust marker. The prompt must be exactly
    one envelope (nothing before or after, one opening and one closing tag) whose
    opening tag carries from-name, credo-trust-peer and a credo-trust HMAC that
    matches a CURRENT trust entry of a still-paired peer. Returns {"trusted": bool,
    "marker": "none" | "invalid" | "valid", ...}; never raises."""
    out = {"trusted": False, "marker": "none"}
    try:
        if not isinstance(prompt, str):
            return out
        view = delim_view(prompt)
        if TRUST_TAG_MARK_RE.search(view):
            out["marker"] = "invalid"
        m = TRUST_ENVELOPE_RE.match(prompt)
        if not m:
            return out
        if len(ENVELOPE_DELIM_RE.findall(view)) != 2:
            return out
        raw = m.group(1)
        pairs_found = TRUST_ATTR_RE.findall(raw)
        attrs = dict(pairs_found)
        if len(attrs) != len(pairs_found) or "".join(' %s="%s"' % kv for kv in pairs_found) != raw:
            return out
        if "credo-trust" not in attrs and "credo-trust-peer" not in attrs:
            return out
        out["marker"] = "invalid"
        name, pid, mac = attrs.get("from-name", ""), attrs.get("credo-trust-peer", ""), attrs.get("credo-trust", "")
        if not TRUST_MAC_RE.fullmatch(mac):
            return out
        if pairs is None:
            pairs = PairStore(keys_dir_for(load_config() or {}))
        if store is None:
            store = TrustStore(trust_path())
        hit = trust_lookup(pid, name, pairs, store)
        if hit is None:
            return out
        key, entry, rec = hit
        if not hmac.compare_digest(mac.encode("ascii"), trust_mac(key, pid, name, m.group(2)).encode("ascii")):
            return out
        out.update(trusted=True, marker="valid", session=name, peer=pid,
                   machine=entry["machine"] or sanitize_from_name(rec.get("machine") or ""))
    except Exception:
        out["trusted"] = False
    return out


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
    # Prefer the daemon: it sends over the return channel when one exists (the only
    # way to reach a peer that cannot be connected to). Only when the daemon's relay
    # socket is unreachable does the holder fall back to its own direct connection.
    # A --no-direct holder serves a via-inbound peer (outside the outbound allowlist,
    # reachable only over the link it opened to us): it NEVER connects on its own.
    relay = getattr(args, "relay_sock", None)
    no_direct = bool(getattr(args, "no_direct", False))
    if relay:
        try:
            reply = relay_via_daemon(relay, host, port, payload)
        except ConnectionError as exc:
            if no_direct:
                log("holder: daemon relay unreachable (%s); %s:%s is reachable only over "
                    "the return channel, deliver dropped" % (exc, host, port))
                return
            log("holder: daemon relay unreachable (%s), sending directly" % exc)
        else:
            if reply.startswith("ok"):
                log("holder: forwarded deliver to %s:%s (%s)" % (host, port, reply[3:] or "daemon"))
            else:
                log("holder: forward to %s:%s failed: %s" % (host, port, reply))
            return
    elif no_direct:
        log("holder: no daemon relay socket; %s:%s is reachable only over the return "
            "channel, deliver dropped" % (host, port))
        return
    try:
        if PairStore(keys_dir_for(load_config())).by_slot("%s:%s" % (host, port)) is not None:
            log("holder: %s:%s is a paired peer, reachable only over its paired link; "
                "deliver dropped" % (host, port))
            return
    except Exception as exc:
        log("holder: pairing state for %s:%s unknown (%s); deliver dropped" % (host, port, exc))
        return
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
        # (peer addr, announced machine) -> last roster monotonic time; tells a real
        # machine rename (old name went silent) from a second sender on one address
        self.machine_last = {}
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
        # return channel state. Lock order: self.lock may be held while taking
        # chan_lock, never the other way round.
        self.chan_lock = threading.Lock()
        self.channels = {}  # peer addr "host:port" -> Channel (at most one per key)
        self.link_pending = set()  # keys with an outbound link attempt in flight
        self.link_retry = {}  # key -> (consecutive failures, next attempt monotonic)
        self.link_warned = set()  # keys whose link failure was already logged
        self.chan_reject_warned = set()  # refused-link log tags, logged once each
        # random per-run nonce: last tie-breaker between two links of daemons with an
        # identical this_machine and listen port (both sides must pick the same link).
        # It is public (every hello and ack carries it) and never proves identity;
        # the per-link secrets below do that.
        self.link_nonce = os.urandom(8).hex()
        # per-link secrets, kept for configured peer keys only (bounded by the config):
        # key -> secret of our latest outbound link attempt, and (key, direction) ->
        # secret of the last channel registered for that key
        self.link_out_secret = {}
        self.link_last_secret = {}
        self.link_refused = {}  # key -> consecutive links that connected but got no ack
        self.link_unsupported = set()  # keys marked "no link support" (old relay)
        self.link_tie_lost = {}  # key -> the channel our own link lost a tie-break to
        self.no_relay_warned = set()  # via-inbound peers skipped for lack of a relay
        self.relay_srv = None
        self.relay_path = None
        self.relay_sem = threading.Semaphore(MAX_HOLDER_WORKERS)
        # pairing keys (see PairStore): this installation's id + one key per paired
        # peer id, read from disk on every use (a CLI pair-reset applies at once)
        self.pairs = PairStore(keys_dir_for(cfg))
        self.pair_warned = set()  # pairing refusal log tags, logged once each

    # -- lifecycle ----------------------------------------------------------
    def _ensure_sock_dir(self):
        """Create the sock dir 0700 (proxy and relay sockets live there) and tighten
        an existing one we own, so other local users can never reach the sockets."""
        try:
            os.makedirs(self.sock_dir, mode=0o700, exist_ok=True)
            if os.stat(self.sock_dir).st_uid == os.getuid():
                os.chmod(self.sock_dir, 0o700)
        except OSError as exc:
            log("cannot create sock dir %s: %s" % (self.sock_dir, exc))

    def start(self):
        self._ensure_sock_dir()
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
        self._start_relay()
        threading.Thread(target=self._netwatch_loop, daemon=True).start()
        threading.Thread(target=self._accept_loop, daemon=True).start()
        threading.Thread(target=self._link_loop, daemon=True).start()
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
        gone = []  # (channel, was registered) dropped by the new network
        with self.lock:
            self.lan_state = state
            if changed:
                self._lan_key = key
                self.outbound_skip_warned.clear()
                self.rejected_warned.clear()
                self.no_relay_warned.clear()
                with self.chan_lock:
                    # a peer marked "no link support" gets another try on a new network
                    self.link_unsupported.clear()
                    self.link_refused.clear()
                # channels never outlive their gate: an outbound link needs the
                # outbound gate, an inbound one the inbound source gate. They are
                # unregistered here; the goodbye and the close happen after self.lock
                # is released, so a stalled link never blocks the daemon behind it.
                with self.chan_lock:
                    chans = list(self.channels.values())
                for ch in chans:
                    if ch.direction == "out":
                        still = peer_allowed_outbound(ch.addr[0], state)
                    else:
                        still = source_allowed(ch.src_ip, state, self.wsl)
                    if not still:
                        gone.append((ch, self._unregister_channel(ch)))
                for rkey, rec in list(self.remotes.items()):
                    host = split_host_port(rkey[0], self.listen_port)[0]
                    if peer_allowed_outbound(host, state):
                        continue
                    # keep a mirror only while its peer's inbound link is alive AND its
                    # holder can never send directly; a holder spawned while the address
                    # was allowlisted is replaced by a --no-direct one on the next roster
                    if not (self._inbound_channel(rkey[0]) and rec.get("no_direct")):
                        self._remove_remote_locked(rkey)
        if gone:
            self._say_byes([ch for ch, _ in gone], "network no longer allowed")
            for ch, was in gone:
                self._close_channel(ch, was, "no longer allowed on this network")
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
            "config": os.path.abspath(config_path()),
        }
        try:
            # process start time: lets stop/restart/status tell a recycled pid apart
            data["pstart"] = proc_start(os.getpid())
        except (OSError, ValueError, IndexError):
            pass
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
        with self.chan_lock:
            chans = list(self.channels.values())
        self._say_byes(chans, "daemon shutdown")
        for ch in chans:
            self._drop_channel(ch, "shutdown")
        if self.relay_srv is not None:
            try:
                self.relay_srv.close()
            except OSError:
                pass
            try:
                os.unlink(self.relay_path)
            except OSError:
                pass
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
        handed_off = False
        try:
            conn.settimeout(10)
            buf = b""
            while b"\n" not in buf:
                try:
                    chunk = conn.recv(65536)
                except socket.timeout:
                    break
                except OSError:
                    break
                if not chunk:
                    break
                buf += chunk
                if len(buf) > MAX_LINE:
                    log("oversize message from %s dropped" % (addr,))
                    return
            # A verified "link" hello as the FIRST line turns this connection into a
            # persistent return channel (source gate already passed in _accept_loop).
            first, _, rest = buf.partition(b"\n")
            if b"\n" in buf and first.strip():
                hello = verify_line(self.token, first.strip().decode("utf-8", "replace"))
                if hello is not None and hello.get("kind") == "link":
                    handed_off = True
                    self._accept_link(conn, addr, hello, rest)
                    return
        finally:
            if not handed_off:
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

    def _dispatch(self, payload, src_ip="", chan=None):
        kind = payload.get("kind")
        if kind == "roster":
            self._on_roster(payload, src_ip, chan)
        elif kind == "deliver":
            self._on_deliver(payload, src_ip, chan)
        elif kind in ("ping", "link"):
            # keepalive / a repeated hello. A ping may carry "bye": the peer's reason
            # for closing this link next (daemon shutdown, link replaced), so the
            # "channel down" line here says why instead of only "closed by peer".
            bye = payload.get("bye")
            if chan is not None and isinstance(bye, str) and bye:
                chan.bye = BYE_RE.sub("", bye)[:60]
        else:
            log("unknown message kind %r" % kind)

    # -- return channel (persistent link) -----------------------------------
    def _link_hello(self, peer_host, ack=False, chal="", proof="", resume="", expect=""):
        """The "link" frame: who we are, our listen port and roster cadence, plus
        the same advertise fields a roster carries (so the acceptor resolves our
        peer address exactly like it resolves our rosters). A hello carries the new
        link's secret (chal) and, when we know one, the link_proof / resume_proof
        tying it to the peer's link; an ack carries only a link_proof."""
        hello = {
            "kind": "link",
            "machine": self.this_machine,
            "listen_port": self.listen_port,
            "roster_interval": self.roster_interval,
            "nonce": self.link_nonce,
        }
        for k, v in (("chal", chal), ("proof", proof), ("resume", resume)):
            if v:
                hello[k] = v
        ident = None if ack else self._ident()
        if ident is not None:
            # pairing: our persistent id and static DH public value (both public)
            hello.update(pid=ident["id"], dh=ident["pub"])
            if expect:
                # the paired id we have bound to the address we dialed (bound into
                # both proofs and the session key); absent = an unpaired address
                hello["expect"] = expect
        if ack:
            hello["ack"] = True
        elif is_loopback_ip(peer_host):
            hello.update(advertise_host="127.0.0.1", advertise_port=self.listen_port)
        elif self.advertise_host:
            hello.update(advertise_host=self.advertise_host, advertise_port=self.advertise_port)
        return hello

    # -- pairing keys (trust on first use, see PairStore / PairLink) ---------
    def _ident(self):
        """Our pairing identity, or None when the key dir is unusable (then this
        daemon pairs with nobody and works token-only, logged once)."""
        try:
            return self.pairs.identity()
        except (OSError, ValueError) as exc:
            if warn_once(self.pair_warned, "ident"):
                log("pairing disabled: key dir %s unusable (%s)" % (self.pairs.path, exc))
            return None

    @property
    def peer_id(self):
        ident = self._ident()
        return ident["id"] if ident else ""

    def _bound(self, slot):
        """The paired peer record bound to slot (a peer address key), or None. While
        the key store cannot be read, every slot counts as bound to an unknown peer
        (PAIR_UNKNOWN_ID, "unknown": True): no token-only link, no fresh connection."""
        try:
            rec = self.pairs.by_slot(slot)
        except Exception as exc:
            self._pair_log("unreadable",
                           "pairing key store %s unreadable (%s): every peer address counts as "
                           "paired until it can be read again; links without a stored key and "
                           "fresh connections are refused" % (self.pairs.path, exc))
            return {"id": PAIR_UNKNOWN_ID, "pub": "", "key": "", "slot": slot, "machine": "",
                    "unknown": True}
        self._pair_readable()
        return rec

    def _pair_readable(self):
        """The key store reads again: a later unreadable phase is logged again."""
        if "unreadable" in self.pair_warned:
            self.pair_warned.discard("unreadable")
            log("pairing key store %s readable again" % self.pairs.path)

    def _slot_trusted(self, slot, chan):
        """A frame attributed to slot may be served: the slot is not bound to a paired
        peer, or the frame came over a link authenticated as exactly that peer."""
        rec = self._bound(slot)
        return rec is None or (chan is not None and chan.pair_id == rec["id"])

    def _pair_log(self, tag, msg):
        if warn_once(self.pair_warned, tag):
            log(msg)

    def _pair_conflict(self, slot, rec, new_id, machine, why, fix=None):
        """A new id (or a changed key) claims a paired slot, or a paired id shows up
        at another slot: refused, and surfaced once per slot as a pending repair
        (state file + log line with the one command that accepts it, fix = the
        pair-reset argument, default the slot). Never logs or stores anything secret."""
        fix = fix or slot
        entry = {"slot": slot, "old_id": rec["id"], "new_id": new_id,
                 "machine": str(machine or "")[:60], "reason": why, "fix": fix}
        try:
            fresh = self.pairs.add_pending(entry)
        except OSError:
            fresh = warn_once(self.pair_warned, ("pending", slot))
        if fresh:
            log("pairing: %s at %s (peer id %s, machine %r), paired there: %s (%r); "
                "refused. If that is expected (peer reinstalled, keys reset, moved to a new "
                "address, or an older relay / the Codex peer lives there), accept it with: "
                "credo-peer-lan.py pair-reset %s"
                % (why, slot, (new_id or "none")[:8], entry["machine"], (rec["id"] or "none")[:8],
                   rec["machine"], fix))

    def _pair_moved(self, slot, rec, machine):
        """A link that PROVED the key of paired id rec["id"] serves another slot than
        the one that id is bound to: refused for this slot, the old slot stays bound,
        surfaced as a pending repair; only `pair-reset <id>` moves it."""
        self._pair_conflict(slot, {"id": rec["id"], "machine": rec["machine"]}, rec["id"], machine,
                            "paired peer bound to %s" % rec["slot"], fix=rec["id"])

    def _send_refusal(self, conn, why):
        try:
            conn.sendall(frame_for(self.token, {"kind": "link", "refused": why,
                                                "machine": self.this_machine}).encode("utf-8"))
        except OSError:
            pass

    def _pair_accept(self, conn, src, slot, machine, hello, rest):
        """Pairing step of an inbound link keyed by slot. Returns (pair, rest):
        pair = a PairLink (authenticated paired peer), None (unpaired, token-only) or
        False (refused; a signed refusal was sent). A slot bound to a paired id only
        goes to a link proving that id's key against our fresh challenge; a paired id
        never gets in without that proof (no downgrade); a new id at a paired slot is
        refused and surfaced as a pending repair."""
        bound = self._bound(slot)
        ident = self._ident()
        if bound is not None and (ident is None or bound.get("unknown")):
            # a paired (or, with an unreadable store, possibly paired) slot needs a key
            # proof we cannot check right now: refused, nothing recorded
            self._send_refusal(conn, "pairing required")
            return False, rest
        if ident is None:
            return None, rest
        pid = peer_id_str(hello.get("pid"))
        if pid == ident["id"]:
            pid = ""   # our own id is never a peer (a copied config dir, or a probe)
        if bound is not None and bound["id"] != pid:
            if pid:
                self._pair_conflict(slot, bound, pid, machine, "a new peer id")
            else:
                self._pair_log(("downgrade", src),
                               "link from %s for paired slot %s carries no pairing proof; refused "
                               "(a paired peer never falls back to token-only)" % (src, slot))
                # an older relay / the Codex peer whose slot a pairing peer took first
                # (trust on first use) would otherwise be locked out silently
                self._pair_conflict(slot, bound, "", machine, "a link without pairing support")
            self._send_refusal(conn, "pairing required")
            return False, rest
        if not pid:
            return None, rest
        rec = self.pairs.get(pid)
        pub = hello.get("dh")
        y = dh_pub_value(pub)
        c_open = _secret_str(hello.get("chal"))
        if y is None or not c_open:
            if rec is not None:
                self._pair_log(("downgrade", src),
                               "link from %s claims paired peer %s without a key proof; refused"
                               % (src, pid[:8]))
                self._send_refusal(conn, "pairing required")
                return False, rest
            return None, rest   # no usable pairing fields: an unpaired, token-only link
        if rec is not None and rec["pub"] != pub:
            self._pair_conflict(slot, rec, pid, machine, "a changed key for a paired id")
            self._send_refusal(conn, "pairing required")
            return False, rest
        key = rec["key"] if rec is not None else pair_key(ident, pid, y)
        expect = pair_expect_str(hello.get("expect"))
        c_acc = os.urandom(16).hex()
        challenge = {"kind": "link", "machine": self.this_machine, "pid": ident["id"],
                     "dh": ident["pub"], "challenge": c_acc}
        conn.settimeout(PAIR_HANDSHAKE_TIMEOUT)
        if expect not in (PAIR_ANY, ident["id"]):
            # the opener dialed an address it has bound to ANOTHER paired id: we are not
            # who it wants, so we prove nothing; our id still goes out (no proof), so
            # the opener can surface the new id at its paired address
            self._pair_log(("expect", src),
                           "link from %s expects another peer id at this address; no proof sent"
                           % src)
            conn.sendall(frame_for(self.token, challenge).encode("utf-8"))
            return False, rest
        challenge["auth"] = pair_proof(key, "A", ident["id"], pid, c_open, c_acc, expect)
        conn.sendall(frame_for(self.token, challenge).encode("utf-8"))
        line, rest = recv_line(conn, rest)
        reply = verify_line(self.token, line.strip().decode("utf-8", "replace")) if line else None
        want = pair_proof(key, "O", pid, ident["id"], c_open, c_acc, expect)
        if not (reply and reply.get("kind") == "link" and proof_eq(reply.get("auth"), want)):
            self._pair_log(("proof", src),
                           "link from %s as peer %s failed the pairing key proof; refused"
                           % (src, pid[:8]))
            self._send_refusal(conn, "pairing failed")
            return False, rest
        if rec is not None and rec["slot"] != slot:
            # a proven paired id at a slot that is not its own: never moved silently
            self._pair_moved(slot, rec, machine)
            self._send_refusal(conn, "pairing required")
            return False, rest
        to_pin = None
        if rec is None or rec["machine"] != machine[:60]:
            to_pin = (pid, pub, key, slot, machine)   # stored once the ack went out
        return PairLink(pid, pair_session_key(key, pid, ident["id"], c_open, c_acc, expect),
                        "a2o", "o2a", to_pin=to_pin), rest

    def _pair_store(self, pair):
        """Store a pairing whose handshake completed (both proofs and the ack). False
        when it cannot be stored (another id took the slot meanwhile, or the id got
        bound elsewhere): the caller drops the link, it is surfaced as a pending
        repair. A failing disk also drops the link (logged; the next link retries)."""
        if pair is None or not pair.to_pin:
            return True
        pid, pub, key, slot, machine = pair.to_pin
        try:
            new = self.pairs.get(pid) is None
            stored = self.pairs.pin(pid, pub, key, slot, machine)
        except OSError as exc:
            self._pair_log(("store", slot), "pairing with %s at %s not stored (%s); link dropped"
                           % (pid[:8], slot, exc))
            return False
        if not stored:
            rec = self.pairs.get(pid)
            if rec is not None and rec["slot"] != slot:
                self._pair_moved(slot, rec, machine)
            else:
                other = self._bound(slot) or {"id": "?", "machine": ""}
                self._pair_conflict(slot, other, pid, machine, "a new peer id")
            return False
        pair.to_pin = None
        if new:
            log("paired with peer %s (%r) at %s: pairing key stored" % (pid[:8], machine, slot))
        return True

    def _pair_open(self, sock, key, c_open, msg, expected):
        """Pairing step of our own outbound link to key, after the acceptor's
        challenge msg. Returns (PairLink, "") or (None, why). The acceptor proves the
        key first (bound to our fresh chal); a paired address answered by another id
        or key is refused and surfaced as a pending repair."""
        ident = self._ident()
        a_id = peer_id_str(msg.get("pid"))
        pub = msg.get("dh")
        y = dh_pub_value(pub)
        c_acc = _secret_str(msg.get("challenge"))
        machine = msg.get("machine") if isinstance(msg.get("machine"), str) else ""
        if ident is None or not a_id or a_id == ident["id"] or y is None or not c_open or not c_acc:
            return None, "malformed pairing challenge"
        if expected is not None and expected.get("unknown"):
            return None, "pairing key store unreadable"
        if expected is not None and expected["id"] != a_id:
            self._pair_conflict(key, expected, a_id, machine, "a new peer id")
            return None, "a new peer id answers at a paired address"
        rec = self.pairs.get(a_id)
        if rec is not None and rec["pub"] != pub:
            self._pair_conflict(key, rec, a_id, machine, "a changed key for a paired id")
            return None, "the paired peer's key changed"
        expect = expected["id"] if expected is not None else PAIR_ANY
        k = rec["key"] if rec is not None else pair_key(ident, a_id, y)
        if not proof_eq(msg.get("auth"), pair_proof(k, "A", a_id, ident["id"], c_open, c_acc, expect)):
            self._pair_log(("proof", key),
                           "link to %s: peer %s failed the pairing key proof; not used" % (key, a_id[:8]))
            return None, "pairing key proof failed"
        if rec is not None and rec["slot"] != key:
            # a proven paired id answers at an address that is not its own: we send
            # no proof, nothing moves, its own slot stays bound
            self._pair_moved(key, rec, machine)
            return None, "a paired peer answers at an address it is not bound to"
        sock.sendall(frame_for(self.token, {
            "kind": "link", "auth": pair_proof(k, "O", ident["id"], a_id, c_open, c_acc, expect),
        }).encode("utf-8"))
        to_pin = None
        if rec is None or rec["machine"] != machine[:60]:
            to_pin = (a_id, pub, k, key, machine)   # stored once the ack arrived
        return PairLink(a_id, pair_session_key(k, ident["id"], a_id, c_open, c_acc, expect),
                        "o2a", "a2o", to_pin=to_pin), ""

    def _chan_timeout(self, remote_interval):
        """Read timeout of a channel: about 3 roster intervals of the slower side.
        Both sides send at least a ping every interval, so silence this long means
        a half-dead link, which is then dropped and re-established."""
        return min(3.0 * max(self.roster_interval, remote_interval or 0.0) + 1.0,
                   CHAN_TIMEOUT_MAX)

    def _ping_every(self):
        return min(self.roster_interval * 0.9, CHAN_PING_MAX)

    def _idle_limit(self, ch):
        """Silence after which a live channel counts as idle: about 2 ping intervals
        of the slower side (both sides send at least a ping every interval)."""
        return 2.0 * min(max(self.roster_interval, ch.remote_interval), CHAN_PING_MAX) + 1.0

    def _is_wsl_gw(self, src, state=None):
        if not self.wsl:
            return False
        gw = ((state or self.lan_state or {}).get("netinfo") or {}).get("wsl_nat_gateway")
        return bool(gw) and src == gw

    @staticmethod
    def _link_verified(src, host):
        """The link's socket source IS the address it is keyed by (or both are local),
        so the claim is proven by the connection itself, not by what it says."""
        return src == host or (is_loopback_ip(src) and is_loopback_ip(host))

    def _link_claim_ok(self, src, cand, state):
        """May an inbound link from src be keyed by peer address cand (host, port)? An
        address the outbound gate allows (one we may reach ourselves) only from that
        host itself, loopback, or (WSL NAT) the gateway every inbound connection
        arrives from. An address outside the outbound allowlist is the via-inbound
        exception (we never send to it except over this very link, so nothing can be
        redirected), but only for a CONFIGURED peer address: anything else is keyed by
        the link's own source, so a sender cannot mint fresh keys to fill the slots."""
        host = cand[0]
        if not peer_allowed_outbound(host, state):
            return tuple(cand) in self.peer_addrs
        return self._link_verified(src, host) or is_loopback_ip(src) or self._is_wsl_gw(src, state)

    def _is_peer_key(self, key):
        """key ("host:port") is a configured peer address (per-link secrets are kept
        only for those, so their maps stay bounded by the config)."""
        return any("%s:%d" % (p["host"], p["port"]) == key for p in self.peers)

    def _peer_link_proof_locked(self, key, their_out):
        """link_proof we can offer the peer at key for its outbound link whose
        secret is their_out: combined with our own latest outbound link to that key
        (live or still pending). Must hold chan_lock."""
        return link_proof(self.link_out_secret.get(key, ""), their_out)

    def _get_channel(self, key):
        with self.chan_lock:
            ch = self.channels.get(key)
        return ch if ch is not None and not ch.closed else None

    def _inbound_channel(self, key):
        ch = self._get_channel(key)
        return ch if ch is not None and ch.direction == "in" else None

    def _refuse_log(self, kind, src, msg):
        """Log a refused link once per (kind, source IP): never keyed by values the
        sender chooses (machine name, claimed address), so the tag set stays small."""
        if warn_once(self.chan_reject_warned, (kind, src)):
            log(msg)

    def _inbound_cap_locked(self, ch):
        """Slot caps for an inbound link (must hold chan_lock): one live inbound link
        per source IP (loopback exempt; the WSL NAT gateway, which every inbound
        connection under WSL NAT shares, at most max(GW_LINK_MIN, len(peers)), so
        every configured peer behind NAT can hold one) and len(peers)+2 in total.
        Replacing the link on the same key does not count. Returns a refusal reason
        or None."""
        ins = [c for c in self.channels.values()
               if c.direction == "in" and not c.closed and c.key != ch.key]
        same_src = len([c for c in ins if c.src_ip == ch.src_ip])
        if self._is_wsl_gw(ch.src_ip):
            gw_max = max(GW_LINK_MIN, len(self.peers))
            if same_src >= gw_max:
                return "WSL gateway link cap (%d) reached" % gw_max
        elif not is_loopback_ip(ch.src_ip) and same_src:
            return "another link from %s is already open" % ch.src_ip
        if len(ins) >= len(self.peers) + 2:
            return "inbound link cap (%d) reached" % (len(self.peers) + 2)
        return None

    def _register_channel(self, ch):
        """Register ch as THE channel for its peer address. Returns False (the caller
        closes ch; ch.refuse_reason says why) when it is refused. Rules:
          - inbound links are capped (see _inbound_cap_locked),
          - same direction: the new link replaces the live one only when it comes
            from the SAME source IP and machine (a stale link after a reconnect). A
            shared source (loopback / WSL gateway) does not identify the sender, so
            there a new inbound link must also carry the resume_proof of the live
            link's secret (sent only on that connection), unless the live link is
            idle (no frame for 2 ping intervals); anything else never takes over an
            address another link serves,
          - one in + one out: the inbound link is a true simultaneous open only when
            a link_proof over both links' secrets came with it (in its hello, or in
            the ack of our outbound link). Each secret is sent only on its own
            connection. Then the link opened by the machine whose (this_machine,
            listen_port, nonce) sorts LOWER is kept (an idle link loses); both sides
            apply the same rule, so exactly one connection survives. Without the
            proof our own outbound link (we dialed the configured address) wins."""
        drop = None
        ch.refuse_reason = ""
        with self.chan_lock:
            if ch.direction == "in":
                why = self._inbound_cap_locked(ch)
                if why:
                    ch.refuse_reason = "busy"
                    self._refuse_log("cap", ch.src_ip,
                                     "link from %s (%r) refused: %s" % (ch.src_ip, ch.remote_machine, why))
                    return False
            cur = self.channels.get(ch.key)
            if cur is not None and not cur.closed:
                # both links proved the same pairing key: the same peer installation
                same_pair = bool(ch.pair_id) and ch.pair_id == cur.pair_id
                if cur.direction == ch.direction:
                    shared = is_loopback_ip(ch.src_ip) or self._is_wsl_gw(ch.src_ip)
                    if ch.direction == "in":
                        same_instance = proof_eq(ch.resume, resume_proof(ch.secret, cur.secret))
                    else:  # two of our own outbound links (we dialed both)
                        same_instance = bool(ch.remote_nonce) and ch.remote_nonce == cur.remote_nonce
                    if (cur.pair_id and not same_pair) or (not same_pair and (
                            cur.src_ip != ch.src_ip or cur.remote_machine != ch.remote_machine
                            or (shared and not same_instance
                                and not cur.idle(self._idle_limit(cur))))):
                        ch.refuse_reason = "address served"
                        self._refuse_log(
                            "dup", ch.src_ip,
                            "link from %s (%r) for %s refused: a live channel from %s (%r) "
                            "already serves this address"
                            % (ch.src_ip, ch.remote_machine, ch.key, cur.src_ip, cur.remote_machine))
                        return False
                else:
                    inb, outb = (ch, cur) if ch.direction == "in" else (cur, ch)
                    want = link_proof(inb.secret, outb.secret)
                    proven = same_pair or proof_eq(inb.proof, want) or proof_eq(outb.proof, want)
                    if not proven:
                        # not provably the peer our own link talks to: ours wins
                        keep = outb
                    elif inb.idle(self._idle_limit(inb)) != outb.idle(self._idle_limit(outb)):
                        keep = inb if outb.idle(self._idle_limit(outb)) else outb
                    else:
                        keep_ours = (self.this_machine, self.listen_port, self.link_nonce) < (
                            inb.remote_machine, inb.remote_port, inb.remote_nonce)
                        keep = outb if keep_ours else inb
                    if keep is cur:
                        ch.refuse_reason = "duplicate"
                        if ch.direction == "out":
                            self.link_tie_lost[ch.key] = cur
                        return False
                    if keep is inb:
                        # our own link lost to the peer's: stop re-dialing it
                        self.link_tie_lost[ch.key] = inb
                drop = cur
                cur.registered = False
                log("channel down: key=%s dir=%s conn=%s (duplicate, replaced)"
                    % (cur.key, cur.direction, cur.desc))
            self.channels[ch.key] = ch
            ch.registered = True
            if ch.secret and self._is_peer_key(ch.key):
                self.link_last_secret[(ch.key, ch.direction)] = ch.secret
            self.link_warned.discard(ch.key)
            self.link_retry.pop(ch.key, None)
            self.link_refused.pop(ch.key, None)
            log("channel up: key=%s dir=%s peer=%r conn=%s%s"
                % (ch.key, ch.direction, ch.remote_machine, ch.desc,
                   " paired=%s" % ch.pair_id[:8] if ch.pair_id else ""))
        if drop is not None:
            self._say_bye(drop, "replaced by a newer link")
            drop.close()
        return True

    def _say_bye(self, ch, why):
        """Best-effort goodbye on a link we are about to close: a ping carrying the
        reason, so the peer logs why the link went down (a peer without this field
        just sees a keepalive). Never raises; bounded by BYE_TIMEOUT. Never call it
        while holding self.lock or chan_lock."""
        if ch.closed:
            return
        try:
            ch.send_bye(self.token, why)
        except Exception:
            pass

    def _say_byes(self, chans, why):
        """_say_bye on several links in parallel, so n stalled links cost about one
        BYE_TIMEOUT instead of n. Returns after all are sent or the deadline passed."""
        chans = [ch for ch in chans if not ch.closed]
        if len(chans) <= 1:
            for ch in chans:
                self._say_bye(ch, why)
            return
        threads = []
        for ch in chans:
            t = threading.Thread(target=self._say_bye, args=(ch, why), daemon=True)
            t.start()
            threads.append(t)
        deadline = time.monotonic() + BYE_TIMEOUT + 0.5
        for t in threads:
            t.join(max(0.0, deadline - time.monotonic()))

    def _unregister_channel(self, ch):
        """Remove ch from the channel table; True if it was registered."""
        with self.chan_lock:
            if self.channels.get(ch.key) is ch:
                del self.channels[ch.key]
            was = ch.registered
            ch.registered = False
        return was

    def _close_channel(self, ch, was, reason):
        ch.close()
        if was:
            log("channel down: key=%s dir=%s conn=%s (%s)" % (ch.key, ch.direction, ch.desc, reason))

    def _drop_channel(self, ch, reason, bye=None):
        if bye:
            self._say_bye(ch, bye)
        self._close_channel(ch, self._unregister_channel(ch), reason)

    def _channel_reader(self, ch, buf=b""):
        """Read frames from a channel until EOF/error/timeout and dispatch each one
        through the normal frame path (token check included); then drop it."""
        reason = "closed by peer"
        try:
            while not self.stop.is_set() and not ch.closed:
                line, buf = recv_line(ch.sock, buf)
                if line is None:
                    if ch.bye:
                        reason = "closed by peer: %s" % ch.bye
                    break
                line = line.strip()
                if not line:
                    continue
                payload = ch.verify(self.token, line.decode("utf-8", "replace"))
                if payload is None:
                    reason = "unauthenticated/garbled frame"
                    log("rejected unauthenticated/garbled frame on channel %s" % ch.key)
                    break
                ch.last_rx = time.monotonic()
                try:
                    self._dispatch(payload, ch.src_ip, ch)
                except Exception as exc:
                    log("channel %s: frame handling failed: %s" % (ch.key, exc))
        except socket.timeout:
            reason = "timeout, no traffic"
        except (OSError, ValueError) as exc:
            reason = "error: %s" % exc
        finally:
            self._drop_channel(ch, reason)

    def _link_addr(self, src, hello):
        """Peer address an inbound link is keyed by. Resolved like a roster, but a
        claim to an address we can reach ourselves must be proven by the socket
        source (see _link_claim_ok); otherwise the link is keyed by its own source
        address, which can never collide with another configured peer."""
        state = self.lan_state
        lp = int(hello.get("listen_port") or DEFAULT_PORT)
        cand, known = self._resolve_peer_addr(
            src, lp, hello.get("advertise_host"), hello.get("advertise_port"))
        if self._link_claim_ok(src, cand, state):
            return cand, known
        self._refuse_log(
            "claim", src,
            "link from %s claims peer address %s:%d but does not come from it; keyed by "
            "its source address instead" % (src, cand[0], cand[1]))
        own = (src, lp)
        return own, own in self.peer_addrs

    def _accept_link(self, conn, addr, hello, rest):
        """Inbound "link" hello (source gate and token already checked): resolve the
        peer address, register the connection as that peer's channel, ack it, and
        serve frames from it until it ends. A refused link gets a signed "refused"
        reply so a current peer backs off instead of taking us for an old relay."""
        src = addr[0] if isinstance(addr, tuple) and addr else ""
        machine = hello.get("machine")
        try:
            if not isinstance(machine, str) or not machine:
                raise ValueError("link hello without a machine")
            conn.settimeout(self._chan_timeout(0.0))
            peer_addr, known = self._link_addr(src, hello)
            # pairing first: a slot bound to a paired peer goes only to a link that
            # proves that peer's key (nothing is registered or acked before)
            pair, rest = self._pair_accept(conn, src, "%s:%d" % peer_addr, machine[:120],
                                           hello, rest)
            if pair is False:
                conn.close()
                return
            ch = Channel(conn, peer_addr, known, "in", src, machine[:120],
                         hello.get("listen_port"), hello.get("roster_interval"),
                         hello.get("nonce"), secret=hello.get("chal"),
                         proof=hello.get("proof"), resume=hello.get("resume"), pair=pair)
            conn.settimeout(self._chan_timeout(ch.remote_interval))
        except Exception as exc:
            log("link from %s rejected: %s" % (src, exc))
            conn.close()
            return
        try:
            registered = self._register_channel(ch)
            # the link_proof (ack or refusal) only ever combines the opener's OWN
            # secret with ours: it tells the peer which link won and carries no
            # nonce and no secret
            with self.chan_lock:
                proof = self._peer_link_proof_locked(ch.key, ch.secret)
            if not registered:
                refusal = {"kind": "link", "refused": ch.refuse_reason or "refused",
                           "machine": self.this_machine}
                if proof:
                    refusal["proof"] = proof
                try:
                    ch.send_payload(self.token, refusal)
                except OSError:
                    pass
                ch.close()
                return
            ch.send_payload(self.token, self._link_hello(src, ack=True, proof=proof))
            # handshake complete (opener proof verified, ack sent): store a new pairing
            if not self._pair_store(pair):
                self._drop_channel(ch, "pairing could not be stored")
                return
        except Exception as exc:
            # never leave a registered link behind that was not acked and has no
            # reader: it would serve the peer's address without ever timing out
            log("link from %s failed: %s" % (src, exc))
            self._drop_channel(ch, "link setup failed: %s" % exc)
            return
        self._channel_reader(ch, rest)


    def _link_loop(self):
        while not self.stop.is_set():
            try:
                self.link_tick()
            except Exception as exc:
                log("link tick failed: %s" % exc)
            if self.stop.wait(min(self.roster_interval, CHAN_PING_MAX)):
                break

    def link_tick(self):
        """Keepalive pings on idle channels, then (re)open an outbound link to every
        peer the outbound gate allows that has no channel yet. An inbound channel the
        peer opened counts only when its socket source proves the address (or our
        own link already lost the tie-break to it); otherwise we prefer our own
        outbound link. Peers marked "no link support" are skipped until the next
        network change. Attempts run in their own threads with a capped backoff, so
        a dead address never blocks the loop."""
        state = self.lan_state  # lock-free read: never stall pings behind self.lock
        now = time.monotonic()
        with self.chan_lock:
            chans = list(self.channels.values())
        for ch in chans:
            if now - ch.last_tx >= self._ping_every():
                try:
                    ch.send_payload(self.token, {"kind": "ping"})
                except OSError as exc:
                    self._drop_channel(ch, "ping failed: %s" % exc)
        for peer in self.peers:
            host, port = peer["host"], peer["port"]
            key = "%s:%d" % (host, port)
            if not peer_allowed_outbound(host, state):
                continue
            ch = self._get_channel(key)
            if ch is not None and (ch.direction == "out" or self._link_verified(ch.src_ip, host)
                                   or self.link_tie_lost.get(key) is ch):
                continue
            with self.chan_lock:
                if key in self.link_pending or key in self.link_unsupported:
                    continue
                if self.link_retry.get(key, (0, 0.0))[1] > now:
                    continue
                self.link_pending.add(key)
            threading.Thread(target=self._open_link, args=(host, port), daemon=True).start()

    def _link_failed(self, key, why, silent=False):
        """Count a failed link attempt (capped backoff). silent = it connected but got
        no ack at all, the signature of a relay too old to know links: after
        LINK_REFUSED_MAX of those in a row the peer is marked "no link support" and
        left on fresh connections until the next network change or restart."""
        marked = False
        with self.chan_lock:
            fails = self.link_retry.get(key, (0, 0.0))[0] + 1
            backoff = min(self.roster_interval * (2 ** (fails - 1)), self.roster_interval * 6)
            self.link_retry[key] = (fails, time.monotonic() + backoff)
            if silent:
                n = self.link_refused.get(key, 0) + 1
                self.link_refused[key] = n
                if n >= LINK_REFUSED_MAX and key not in self.link_unsupported:
                    self.link_unsupported.add(key)
                    marked = True
            first = key not in self.link_warned
            self.link_warned.add(key)
        if first:
            log("link to %s not established (%s); retrying, sends use fresh connections meanwhile" % (key, why))
        if marked:
            log("peer %s does not support the return channel (no link ack %d times); using "
                "fresh connections, next try after a network change or restart"
                % (key, LINK_REFUSED_MAX))

    def _open_link(self, host, port):
        key = "%s:%d" % (host, port)
        sock = None
        ch = None
        try:
            try:
                sock = open_link_socket(host, port, min(5.0, max(1.0, 3 * self.roster_interval)))
            except OSError as exc:
                self._link_failed(key, str(exc))
                return
            if sock is None:
                self._link_failed(key, "test mode")
                return
            # fresh per-link secret: sent only on this connection to the address we
            # dialed. proof ties it to the peer's live inbound link (simultaneous
            # open), resume to our own previous link it may replace (reconnect).
            chal = os.urandom(16).hex()
            with self.chan_lock:
                cur = self.channels.get(key)
                theirs = (cur.secret if cur is not None and not cur.closed and cur.direction == "in"
                          else self.link_last_secret.get((key, "in"), ""))
                proof = link_proof(chal, theirs)
                resume = resume_proof(chal, self.link_last_secret.get((key, "out"), ""))
                if self._is_peer_key(key):
                    self.link_out_secret[key] = chal
            # a paired peer bound to this address must prove its key (never token-only)
            expected = self._bound(key)
            try:
                sock.settimeout(min(10.0, max(2.0, 3 * self.roster_interval)))
                sock.sendall(frame_for(self.token, self._link_hello(
                    host, chal=chal, proof=proof, resume=resume,
                    expect=expected["id"] if expected is not None else "")).encode("utf-8"))
                line, buf = recv_line(sock, b"")
            except (OSError, ValueError) as exc:
                self._link_failed(key, "no ack: %s" % exc, silent=True)
                sock.close()
                return
            ack = verify_line(self.token, (line or b"").strip().decode("utf-8", "replace"))
            pair = None
            if ack and ack.get("kind") == "link" and "challenge" in ack:
                pair, why = self._pair_open(sock, key, chal, ack, expected)
                if pair is None:
                    self._link_failed(key, why)
                    sock.close()
                    return
                try:
                    line, buf = recv_line(sock, buf)
                except (OSError, ValueError) as exc:
                    self._link_failed(key, "no ack after pairing: %s" % exc)
                    sock.close()
                    return
                ack = pair.verify(self.token, (line or b"").strip().decode("utf-8", "replace"))
            elif expected is not None and not (ack and ack.get("kind") == "link" and ack.get("refused")):
                self._pair_log(("downgrade", key),
                               "link to paired peer %s answered without a pairing proof; not used "
                               "(a paired peer never falls back to token-only)" % key)
                self._link_failed(key, "paired peer answered without a pairing proof")
                sock.close()
                return
            if ack and ack.get("kind") == "link" and ack.get("refused"):
                # a current relay refused this link (duplicate, cap, address served):
                # back off, but it does support links
                why = str(ack.get("refused"))[:80]
                if why == "duplicate":
                    # the peer kept its own link to us: stop re-dialing only when the
                    # refusal proves it is the peer behind our live inbound link
                    with self.chan_lock:
                        cur = self.channels.get(key)
                        if (cur is not None and not cur.closed and cur.direction == "in"
                                and proof_eq(_secret_str(ack.get("proof")),
                                             link_proof(cur.secret, chal))):
                            self.link_tie_lost[key] = cur
                self._link_failed(key, "peer refused the link: %s" % why)
                sock.close()
                return
            if not ack or ack.get("kind") != "link" or not ack.get("ack"):
                # an older relay (never acks) or a token mismatch
                self._link_failed(key, "peer did not accept the link", silent=True)
                sock.close()
                return
            # the handshake is complete (both proofs and the ack): only now is a new
            # pairing stored (a crash or refusal before this point stores nothing)
            if not self._pair_store(pair):
                self._link_failed(key, "pairing could not be stored")
                sock.close()
                return
            ch = Channel(sock, (host, port), True, "out", host, ack.get("machine"),
                         ack.get("listen_port") or port, ack.get("roster_interval"),
                         ack.get("nonce"), secret=chal, proof=ack.get("proof"), pair=pair)
            sock.settimeout(self._chan_timeout(ch.remote_interval))
            if not self._register_channel(ch):
                ch.close()
                return
        except Exception as exc:
            # any other failure still counts as a failed attempt (backoff), never a
            # silent re-dial on every tick; nothing of this attempt stays registered
            if ch is not None:
                self._drop_channel(ch, "link setup failed: %s" % exc)
            elif sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
            self._link_failed(key, "link setup failed: %s" % exc)
            return
        finally:
            with self.chan_lock:
                self.link_pending.discard(key)
        self._channel_reader(ch, buf)


    def send_frame(self, host, port, payload, allow_raw=True):
        """Send one frame to a peer address: over its channel when one is alive,
        else over a fresh connection (send_to_peer) - but only when allow_raw, i.e.
        the address passes the outbound gate. Returns "channel" or "direct"."""
        key = "%s:%d" % (host, int(port))
        ch = self._get_channel(key)
        bound = self._bound(key)
        if bound is not None and (ch is None or ch.pair_id != bound["id"]):
            # a paired peer is reached only over the link that proved its key, never
            # over a fresh connection to whoever holds its address meanwhile
            raise ConnectionError("%s is a paired peer without its paired link right now" % key)
        if ch is not None:
            try:
                ch.send_payload(self.token, payload)
                return "channel"
            except OSError as exc:
                self._drop_channel(ch, "send failed: %s" % exc)
                if bound is not None:
                    raise ConnectionError("paired link to %s failed: %s" % (key, exc))
        if not allow_raw:
            raise ConnectionError(
                "no channel to %s and the address is outside the outbound allowlist" % key)
        send_to_peer(host, int(port), self.token, payload)
        return "direct"

    # -- holder relay (local unix socket) -----------------------------------
    def _start_relay(self):
        """Unix socket the holders hand their delivers to, so they leave over the
        return channel. Bound under umask 077 inside the 0700 sock dir (never a
        moment with loose permissions), then chmod 0600. On failure normal holders
        keep sending directly; via-inbound holders are then not created at all."""
        path = os.path.join(self.sock_dir, "relay-%d.sock" % self.listen_port)
        old_umask = None
        try:
            try:
                os.unlink(path)
            except OSError:
                pass
            srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            old_umask = os.umask(0o077)
            try:
                srv.bind(path)
            finally:
                os.umask(old_umask)
            os.chmod(path, 0o600)
            srv.listen(min(RELAY_BACKLOG, socket.SOMAXCONN))
        except OSError as exc:
            log("holder relay socket %s unavailable (%s); holders send directly" % (path, exc))
            return
        self.relay_srv, self.relay_path = srv, path
        threading.Thread(target=self._relay_loop, daemon=True).start()


    def _relay_loop(self):
        while not self.stop.is_set():
            try:
                conn, _ = self.relay_srv.accept()
            except OSError:
                break
            if not self.relay_sem.acquire(timeout=ACQUIRE_TIMEOUT):
                conn.close()
                continue
            threading.Thread(target=self._handle_relay, args=(conn,), daemon=True).start()

    def _handle_relay(self, conn):
        try:
            conn.settimeout(10)
            try:
                line, _ = recv_line(conn, b"")
                req = json.loads((line or b"").decode("utf-8"))
                payload = req.get("payload") if isinstance(req, dict) else None
                if not isinstance(payload, dict) or payload.get("kind") != "deliver":
                    raise ValueError("only deliver frames are relayed")
                host, port = str(req.get("peer_host")), int(req.get("peer_port"))
                via = self.send_frame(host, port, payload,
                                      allow_raw=peer_allowed_outbound(host, self.lan_state))
                reply = "ok %s" % via
            except Exception as exc:
                reply = "err %s" % exc
            try:
                conn.sendall((reply.replace("\n", " ") + "\n").encode("utf-8"))
            except OSError:
                pass
        finally:
            conn.close()
            self.relay_sem.release()

    # -- deliver (inject into a real local session) -------------------------
    def _on_deliver(self, payload, src_ip="", chan=None):
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
        reply = self._reply_addr_for(payload.get("from_sessionId"), chan)
        from_name = sanitize_from_name(payload.get("from_name", ""))
        trust = self._trust_for(chan, from_name)
        if deliver_local(self.sess_dir, target, from_name, body, reply, trust):
            log("deliver: injected into %s (from %r%s)"
                % (target, from_name, ", trusted peer" if trust else ""))

    def _trust_for(self, chan, from_name):
        """(key, peer id) when this deliver came over a link authenticated as a paired
        peer AND the local user trusts from_name on that peer (see TrustStore), else
        None. Unpaired links, fresh connections and any read problem: None."""
        pid = getattr(chan, "pair_id", "") if chan is not None else ""
        if not peer_id_str(pid) or not from_name:
            return None
        try:
            hit = trust_lookup(pid, from_name, self.pairs, TrustStore(trust_path()))
        except Exception:
            return None
        return (hit[0], pid) if hit else None

    def _reply_addr_for(self, from_session, chan=None):
        """A local proxy socket that routes back to the remote sender, if we hold
        one. Replies written there are forwarded home by that holder. A mirror of a
        paired peer is offered as the reply route only to a deliver that came over
        that peer's paired link (nobody else may pose as one of its sessions)."""
        if not from_session:
            return None
        hit = None
        with self.lock:
            for (mkey, sid), rec in self.remotes.items():
                if sid == from_session:
                    hit = (mkey, "uds:" + rec["proxy"])
                    break
        if hit is None or not self._slot_trusted(hit[0], chan):
            return None
        return hit[1]

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
                targets.append((peer, True))
                continue
            addr = "%s:%d" % (peer["host"], peer["port"])
            # outside the outbound allowlist but the peer opened an accepted channel to
            # us (its source passed the inbound gate): answer over that channel only
            if self._inbound_channel(addr):
                targets.append((peer, False))
                continue
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
        try:
            bound = dict((r["slot"], r["id"]) for r in self.pairs.records())
            self._pair_readable()
        except Exception as exc:
            self._pair_log("unreadable",
                           "pairing key store %s unreadable (%s): every peer address counts as "
                           "paired until it can be read again; links without a stored key and "
                           "fresh connections are refused" % (self.pairs.path, exc))
            bound = None
        if bound is None:
            # unknown pairing state: only links already authenticated by a key
            targets = [t for t in targets
                       if getattr(self._get_channel("%s:%d" % (t[0]["host"], t[0]["port"])),
                                  "pair_id", "")]
        elif bound:
            def paired_ok(peer):
                pid = bound.get("%s:%d" % (peer["host"], peer["port"]))
                if pid is None:
                    return True
                ch = self._get_channel("%s:%d" % (peer["host"], peer["port"]))
                return ch is not None and ch.pair_id == pid
            targets = [t for t in targets if paired_ok(t[0])]
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
            # naming fields for the receiver's mirror names (see mirror_name)
            "harness": "Claude Code",
            "network": (state or {}).get("label") or (state or {}).get("network") or "",
            "user": getpass.getuser(),
            "profile": os.path.basename(
                (os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")).rstrip("/")
            ),
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
        # A loopback peer is told our loopback address instead: it reaches us there,
        # and a strict receiver configured with 127.0.0.1 would drop a LAN address.
        for peer, raw_ok in targets:
            host, port = peer["host"], peer["port"]
            out = payload
            if is_loopback_ip(host):
                out = dict(payload, advertise_host="127.0.0.1", advertise_port=self.listen_port)
            elif self.advertise_host:
                out = dict(payload, advertise_host=self.advertise_host,
                           advertise_port=self.advertise_port)
            try:
                self.send_frame(host, port, out, allow_raw=raw_ok)
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
             it matches the config, so replies only ever go to a configured peer.
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

    def _on_roster(self, payload, src_ip="", chan=None):
        machine = payload.get("machine")
        if not machine or not isinstance(machine, str):
            return  # a missing or non-string machine (also unhashable ones) is ignored
        sessions = payload.get("sessions")
        if not isinstance(sessions, list):
            sessions = []
        if chan is not None:
            # a roster on a channel belongs to the peer address the channel serves
            peer_addr, known = chan.addr, chan.known
        else:
            peer_addr, known = self._resolve_peer_addr(
                src_ip,
                payload.get("listen_port"),
                payload.get("advertise_host"),
                payload.get("advertise_port"),
            )
        addr_key = "%s:%d" % peer_addr
        if not self._slot_trusted(addr_key, chan):
            # a paired peer announces its sessions only over its paired link
            self._pair_log(("roster", addr_key),
                           "roster for paired peer %s not over its paired link; ignored" % addr_key)
            return
        now = time.monotonic()
        with self.lock:
            # outbound gate: never materialize a holder whose forward target is a LAN
            # address the current allowlist does not permit (forwards would leak).
            # Sole exception: the roster arrived over an ACCEPTED inbound channel (its
            # socket source passed the inbound gate); replies then only ever go back
            # over that channel (send_frame allow_raw=False), never to the raw address.
            via_inbound = chan is not None and chan.direction == "in"
            if not peer_allowed_outbound(peer_addr[0], self.lan_state) and not via_inbound:
                if addr_key not in self.outbound_skip_warned:
                    self.outbound_skip_warned.add(addr_key)
                    log("roster from %s ignored: forward target not allowed (%s; %s is "
                        "outside this machine's allowlist, so replies could not go back). "
                        "It is served once this peer's link to us is up, or add the "
                        "address to the bound network's allow list (bind --allow)"
                        % (addr_key,
                           "fresh connection, no link from this peer" if chan is None
                           else "over our own outbound link",
                           peer_addr[0]))
                return
            self.machine_seen[addr_key] = now
            # per-(address, machine) last roster, bounded: stale entries go first,
            # then the oldest one
            if (addr_key, machine) not in self.machine_last and len(self.machine_last) >= WARN_TAGS_MAX:
                stale = now - max(4.0 * self.roster_interval, self.machine_timeout)
                for k in [k for k, t in self.machine_last.items() if t < stale]:
                    del self.machine_last[k]
                if len(self.machine_last) >= WARN_TAGS_MAX:
                    del self.machine_last[min(self.machine_last, key=self.machine_last.get)]
            silent_after = 2.0 * self.roster_interval

            def renamed_from(rec):
                """The mirror of a live sessionId may follow this sender to a new
                machine name only when the mirror came from this very link (one peer
                per channel) or its old machine has gone silent; otherwise it is a
                second sender on the same address (single-peer fallback, or a link
                beside a machine still sending over fresh connections) and the first
                owner keeps it."""
                if chan is not None and rec.get("chan") == chan.cid:
                    return True
                return now - self.machine_last.get((addr_key, rec.get("machine")), 0.0) > silent_after
            # Unexpected-inbound signal: a roster whose source address is NOT among
            # the configured peer addresses. Token-less this is still served (the
            # receiving session's own consent gate is the protection), so it is only
            # a warning, once per address (no per-interval spam). A correctly
            # configured multi-IP setup matches a peer address and never warns.
            if not known and warn_once(self.unknown_warned, addr_key):
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
            # owned by a DIFFERENT address, or by another machine on this address
            # that is still alive (see renamed_from); a machine rename is refreshed below
            owned_elsewhere = {
                sid for (mkey, sid), rec in self.remotes.items()
                if mkey != addr_key or (rec.get("machine") != machine
                                        and not renamed_from(rec))
            }
            self.machine_last[(addr_key, machine)] = now
            for s in sessions:
                if not isinstance(s, dict):
                    continue  # tolerate a malformed/hostile roster entry
                sid = s.get("sessionId")
                if not sid or not isinstance(sid, str):
                    continue
                if sid in local_ids or sid in owned_elsewhere:
                    if warn_once(self.dup_session_warned, sid):
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
                # sender-level naming fields (optional; older senders omit them)
                for fld in ("harness", "network", "user", "profile"):
                    v = payload.get(fld)
                    s[fld] = v[:60] if isinstance(v, str) else ""
                present[sid] = s
            # remove sessions that vanished from THIS sender's roster. The prune is
            # scoped to the same announced machine as well as the forward address: with
            # the single-peer fallback (resolution rule 3) two different senders can map
            # to the same configured peer address, and a roster from one must never prune
            # the other's sessions.
            # A machine rename (same address, same sessionId, new announced machine)
            # carries the old name into the prune scope, so the renamed sender's
            # vanished sessions go too.
            scope = {machine}
            for (mkey, sid), rec in self.remotes.items():
                if mkey == addr_key and sid in present and rec.get("machine") != machine:
                    scope.add(rec.get("machine"))
            for (mkey, sid), rec in list(self.remotes.items()):
                if mkey == addr_key and rec.get("machine") in scope and sid not in present:
                    self._remove_remote_locked((mkey, sid))
            # ensure a holder+descriptor for each present session
            template = self._template_descriptor_locked()
            for sid, s in present.items():
                key = (addr_key, sid)
                if key in self.remotes:
                    self._refresh_descriptor_locked(key, s)
                elif template is None:
                    continue  # no real local session to model yet; retry next tick
                else:
                    self._create_remote_locked(key, s, template)
                if key in self.remotes:
                    # the link this mirror was last announced over (None: fresh
                    # connections); only that link may carry a rename at once
                    self.remotes[key]["chan"] = chan.cid if chan is not None else None

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

    def _mirror_name(self, sess, sid, host):
        """`harness`--`network`--`device`--`user`--`profile`--`session`+sid-short.
        Fields come from the sender's roster; a loopback sender without a network
        shares this machine's network, so its label is used."""
        network = sess.get("network") or ""
        if not network and is_loopback_ip(host):
            st = self.lan_state or {}
            network = st.get("label") or st.get("network") or ""
        return mirror_name(
            [sess.get("harness") or "Claude Code", network, sess.get("machine") or host,
             sess.get("user") or "", sess.get("profile") or ""],
            sess.get("name") or sid,
            sid,
        )

    def _create_remote_locked(self, key, sess, template):
        addr_key, sid = key
        # last-line duplicate guard: one mirror per sessionId, whoever announced it
        if any(osid == sid for (_m, osid) in self.remotes):
            return
        host, port = split_host_port(addr_key, self.listen_port)
        # routing is by address; the display name follows mirror_name() (SendMessage
        # accepts backticks, spaces and "+" but not "@"). Fall back to the host when the
        # roster did not annotate a machine.
        machine = sess.get("machine") or host
        name = self._mirror_name(sess, sid, host)
        # via-inbound peer (outside the outbound allowlist, reachable only over the
        # link it opened to us): its holder must never connect on its own, and
        # without the relay socket it could not send at all - so it is not created
        no_direct = not peer_allowed_outbound(host, self.lan_state)
        if no_direct and not self.relay_path:
            if addr_key not in self.no_relay_warned:
                self.no_relay_warned.add(addr_key)
                log("remote %s skipped: %s is reachable only over the return channel and "
                    "the holder relay socket is unavailable" % (name, addr_key))
            return
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
            ] + (["--relay-sock", self.relay_path] if self.relay_path else [])
            + (["--no-direct"] if no_direct else []),
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
            "no_direct": no_direct,
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
        # follow a rename (session or machine) or a network change of the sender
        d["name"] = self._mirror_name(sess, key[1], split_host_port(key[0], self.listen_port)[0])
        if sess.get("machine"):
            rec["machine"] = sess["machine"]
            d[MARK_FROM] = sess["machine"]
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
    Shared by run_daemon / run_ensure (restart spawns a detached `daemon`). Returns 0 normally, 0 on a clean
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
    if pidfile_daemon(pf) is not None:
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
        if _terminate_incumbent(old_pid, host, port, pstart=pf.get("pstart")):
            return _serve(cfg)
        log(
            "could not reclaim %s:%d from older daemon pid %s; leaving it running"
            % (host, port, old_pid)
        )
        return 0
    return _serve(cfg)


def run_restart(_args):
    """Explicit stop-then-start regardless of version, safe to call from any shell
    (an agent's tool shell included). It signals ONLY the pidfile's verified daemon pid
    (never a command-line pattern, which would also hit the calling shell), waits until
    that daemon is gone and the port is free, then starts the new daemon fully DETACHED
    (spawn_detached_daemon) and returns once it is up - the caller's shell exiting or
    being killed never takes the new daemon along. Never ends with nothing running by
    its own doing: if the old daemon cannot be stopped and its port reclaimed within
    the timeout, it reports that on STDERR, leaves the old one running and returns 1."""
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
    old_pid = pidfile_daemon(pf)
    if old_pid is not None:
        log("restart: stopping running daemon pid %s" % old_pid)
        if not _terminate_incumbent(old_pid, host, port, pstart=pf.get("pstart")):
            sys.stderr.write(
                "credo-peer-lan restart: could not reclaim %s:%d from the running "
                "daemon (pid %s) within %.0fs; left it running\n"
                % (host, port, old_pid, TERMINATE_TIMEOUT)
            )
            return 1
    return _start_detached(cfg, "restart")


def run_start(_args):
    """Start the daemon DETACHED from the calling shell (like restart) and return once
    it listens. A running current/newer (or unparseable) daemon is left alone; a
    positively OLDER one is replaced like `ensure` does after a plugin update."""
    if disabled():
        log("disabled via CREDO_PEER_LAN; exiting")
        return 0
    cfg = load_config()
    if cfg is None:
        log("no config at %s; nothing to do (no-op)" % config_path())
        return 0
    pf = read_pidfile()
    pid = pidfile_daemon(pf)
    if pid is not None:
        running_v, cur_v = version_tuple(pf.get("version")), version_tuple(VERSION)
        if running_v is None or cur_v is None or running_v >= cur_v:
            print("relay already running: pid %d, version %s, port %s"
                  % (pid, pf.get("version"), pf.get("listen_port")))
            return 0
        return run_restart(_args)
    return _start_detached(cfg, "start")


def _start_detached(cfg, what):
    try:
        child = spawn_detached_daemon()
    except Exception as exc:
        sys.stderr.write("credo-peer-lan %s: could not start the daemon: %s\n" % (what, exc))
        return 1
    log("%s: started daemon pid %d (detached, log %s)" % (what, child, relay_log_path()))
    return _await_daemon(child, cfg, what)


def _await_daemon(child, cfg, what="restart"):
    """Wait until the detached daemon child recorded itself in the pidfile (it is
    listening). Returns 0 then, 1 when it exited first or never came up in time."""
    wait = float(cfg.get("bind_retry_total", BIND_RETRY_TOTAL)) + 10.0
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        pf = read_pidfile()
        if pf and pf.get("pid") == child and pidfile_daemon(pf) == child:
            print("relay %s: pid %d, version %s, port %s"
                  % ("restarted" if what == "restart" else "started", child,
                     pf.get("version"), pf.get("listen_port")))
            return 0
        try:
            # reap it if it already exited (it is our child until it is reparented)
            done, _status = os.waitpid(child, os.WNOHANG)
        except ChildProcessError:
            done = 0
        if done == child or not pid_alive(child):
            sys.stderr.write("credo-peer-lan %s: the new daemon exited at once; see %s\n"
                             % (what, relay_log_path()))
            return 1
        time.sleep(0.2)
    sys.stderr.write("credo-peer-lan %s: the new daemon (pid %d) did not come up within "
                     "%.0fs; see %s\n" % (what, child, wait, relay_log_path()))
    return 1


def run_status(_args):
    """Is the relay running? Decided by the pidfile and the verified daemon pid, so a
    daemon started by `daemon`, `ensure` (autostart) or `restart` all count. Exit 0 =
    running, 1 = not running."""
    cfg = load_config()
    pf = read_pidfile()
    pid = pidfile_daemon(pf)
    if pid is None:
        print("relay not running")
        if cfg is None:
            print("No config at %s - the relay is a no-op until it exists. Create it with "
                  "'credo-peer-lan.py init <peer-ip> ...'." % config_path())
        return 1
    started = pf.get("started")
    try:
        since = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(float(started)))
    except (TypeError, ValueError, OverflowError):
        since = "unknown"
    print("relay running: pid %d, version %s, port %s, since %s"
          % (pid, pf.get("version"), pf.get("listen_port"), since))
    running_v, cur_v = version_tuple(pf.get("version")), version_tuple(VERSION)
    if running_v is not None and cur_v is not None and running_v != cur_v:
        print("installed plugin version is %s; `restart` switches to it (the next "
              "session's autostart also replaces an older daemon)" % VERSION)
    return 0


def run_stop(_args):
    """Stop the running daemon: SIGTERM to the pidfile's verified daemon pid only, then
    wait until it is gone. Exit 0 when it stopped or none was running, 1 when it is
    still alive after the timeout."""
    pf = read_pidfile()
    pid = pidfile_daemon(pf)
    if pid is None:
        print("relay not running")
        return 0
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    deadline = time.monotonic() + TERMINATE_TIMEOUT
    while time.monotonic() < deadline:
        if not daemon_is_alive(pid, pf.get("pstart")):
            print("relay stopped (pid %d)" % pid)
            return 0
        time.sleep(0.2)
    sys.stderr.write("credo-peer-lan stop: daemon pid %d still running after %.0fs\n"
                     % (pid, TERMINATE_TIMEOUT))
    return 1


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
        hint = missing_win_tool_hint() if is_wsl() else ""
        if hint:
            print("Cause: " + hint)
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
    print("")
    print_pairs(cfg)
    return 0


def print_pairs(cfg):
    """Pairing state: this installation's id, the paired peers and any pending
    repair with the one command that accepts it. Never prints a key."""
    store = PairStore(keys_dir_for(cfg))
    print("Pairing (per-peer keys, trust on first use): %s" % store.path)
    unreadable = None
    try:
        ident = store._existing_ident()
        who = ident["id"] if ident else "no id yet (created on the first link)"
    except PairStoreUnreadable as exc:
        unreadable, who = exc, "unknown (key store unreadable)"
    except PairIdentityInvalid as exc:
        who = "none - %s" % exc
    try:
        recs = store.records()
    except PairStoreUnreadable as exc:
        unreadable, recs = unreadable or exc, None
    if unreadable is not None:
        print("  key store unreadable: %s" % unreadable)
    print("  this installation: %s" % who)
    if recs is None:
        print("  paired peers: UNKNOWN (until the key store can be read, every peer address "
              "counts as paired: links without a stored key and fresh connections are refused)")
    if recs == []:
        print("  paired peers: none yet (peers pair automatically on their first link)")
    for r in recs or []:
        print("  paired: %s  machine=%r  slot=%s" % (r["id"], r["machine"], r["slot"]))
    pend = store.pending()
    for e in pend:
        print("  PENDING REPAIR at %s: %s (peer id %s, machine %r) was refused, paired there: %s. "
              "If that is expected (peer reinstalled, keys reset, moved, or an older relay / the "
              "Codex peer lives there), accept it with: credo-peer-lan.py pair-reset %s"
              % (e["slot"], e["reason"], (e["new_id"] or "none")[:8], e["machine"],
                 (e["old_id"] or "none")[:8], e["fix"]))
    return pend


def run_pairs(_args):
    print_pairs(load_config() or {})
    return 0


def run_pair_reset(args):
    """Forget a peer's pairing so its next link pairs again (trust on first use).
    The only manual pairing step, for a reinstalled peer or lost keys."""
    store = PairStore(keys_dir_for(load_config() or {}))
    try:
        gone, drop = store.reset(args.peer)
    except PairStoreUnreadable as exc:
        print("pair-reset: %s; nothing changed" % exc)
        return 1
    if not gone and not drop:
        print("no pairing or pending repair matches %r (see: credo-peer-lan.py pairs)" % args.peer)
        return 1
    for r in gone:
        print("removed pairing with %s (machine %r, slot %s)" % (r["id"], r["machine"], r["slot"]))
    for e in drop:
        print("cleared pending repair at %s (peer id %s)" % (e["slot"], e["new_id"][:8]))
    # a trust grant binds to the pairing: a reset pairing never keeps it (whoever
    # pairs at that id next must be trusted again by the user)
    ids = set(r["id"] for r in gone)
    try:
        dropped = TrustStore(trust_path()).remove(lambda e: e["peer_id"] in ids)
    except OSError as exc:
        dropped = []
        print("could not update the trust list %s: %s (its entries no longer match the "
              "reset pairing anyway)" % (trust_path(), exc))
    for e in dropped:
        print("removed trust for session %r on machine %r (peer %s)"
              % (e["session"], e["machine"], e["peer_id"][:8]))
    print("the next link from that peer pairs again automatically")
    return 0


def _pair_matches(recs, sel):
    """Paired records matching sel: peer id (or an 8+ char prefix), slot host:port,
    host, or machine label (the same selectors as pair-reset)."""
    sel = str(sel or "").strip()
    if not sel:
        return []
    return [r for r in recs
            if r["id"] == sel or (len(sel) >= 8 and r["id"].startswith(sel))
            or r["slot"] == sel or r["slot"].rsplit(":", 1)[0] == sel
            or (r["machine"] and r["machine"] == sel)]


def run_trust(args):
    """Local trust list (see TrustStore). Only the user of this machine grants trust,
    here, never a peer: add asks for confirmation (or needs --yes after the user
    confirmed elsewhere) and only accepts a PAIRED peer."""
    cfg = load_config() or {}
    store = TrustStore(trust_path())
    pairs = PairStore(keys_dir_for(cfg))
    if args.action == "verify":
        # internal, for the peer-message hook: the hook's JSON on stdin
        try:
            data = json.loads(sys.stdin.read() or "{}")
            prompt = data.get("prompt") if isinstance(data, dict) else None
        except Exception:
            prompt = None
        print(json.dumps(verify_trust_prompt(prompt, pairs, store)))
        return 0
    try:
        recs = pairs.records()
    except PairStoreUnreadable as exc:
        recs = None
        if args.action == "add":
            print("trust add: %s; nothing changed" % exc)
            return 1
    if args.action == "list":
        print("Trusted peers (tasks count like the user's own, except dangerous ones): %s"
              % store.path)
        entries = store.read()["trusted"]
        if not entries:
            print("  none (add one with: credo-peer-lan.py trust add <peer> <session> --yes)")
        by_id = dict((r["id"], r) for r in recs or [])
        for e in entries:
            rec = by_id.get(e["peer_id"])
            state = "active" if rec is not None and rec["pub"] == e["pub"] else \
                "INACTIVE (peer not paired with this key anymore)"
            print("  session %r on machine %r  peer=%s  %s"
                  % (e["session"], e["machine"], e["peer_id"], state))
        return 0
    if args.action == "add":
        if not args.peer or not args.session:
            print("usage: credo-peer-lan.py trust add <peer> <session> [--yes]")
            return 2
        hits = _pair_matches(recs, args.peer)
        if len(hits) != 1:
            print("trust add: %s paired peer matches %r; trust needs exactly one PAIRED peer "
                  "(see: credo-peer-lan.py pairs)" % ("no" if not hits else "more than one", args.peer))
            return 1
        rec = hits[0]
        session = sanitize_from_name(args.session)
        if not session or session != args.session:
            print("trust add: session name %r is not a valid from-name (allowed: "
                  "A-Z a-z 0-9 space _ . ( ) @ : -, at most 80)" % args.session)
            return 1
        machine = sanitize_from_name(rec["machine"])
        question = ("Treat tasks from session %r on machine %r (peer %s) like tasks from you? "
                    "Dangerous ones (deleting data, installs, money, permissions, credentials, "
                    "security settings, irreversible steps outside the repo) are still only "
                    "reported, never done." % (session, machine, rec["id"][:8]))
        if not args.yes:
            if not sys.stdin.isatty():
                print("trust add: not confirmed. %s Only the user of this machine may answer; "
                      "re-run with --yes once the user said yes." % question)
                return 1
            try:
                answer = input(question + " [y/N] ")
            except EOFError:
                answer = ""
            if answer.strip().lower() not in ("y", "yes", "j", "ja"):
                print("trust add: not confirmed, nothing changed")
                return 1
        new = store.add(rec["id"], rec["pub"], session, machine)
        print("%s session %r on machine %r (peer %s)"
              % ("trusted" if new else "already trusted:", session, machine, rec["id"]))
        return 0
    # remove
    if not args.peer:
        print("usage: credo-peer-lan.py trust remove <peer> [<session>]")
        return 2
    sel = args.peer.strip()
    ids = set(r["id"] for r in _pair_matches(recs or [], sel))

    def hit(e):
        if args.session and e["session"] != args.session:
            return False
        return (e["peer_id"] in ids or e["peer_id"] == sel
                or (len(sel) >= 8 and e["peer_id"].startswith(sel))
                or (e["machine"] and e["machine"] == sel))
    gone = store.remove(hit)
    if not gone:
        print("no trust entry matches %r (see: credo-peer-lan.py trust list)" % sel)
        return 1
    for e in gone:
        print("removed trust for session %r on machine %r (peer %s)"
              % (e["session"], e["machine"], e["peer_id"]))
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

    p_start = sub.add_parser(
        "start",
        help="start the daemon DETACHED from this shell and return once it listens; "
        "no-op when a current/newer daemon already runs, an older one is replaced",
    )
    p_start.set_defaults(func=run_start)

    p_restart = sub.add_parser(
        "restart",
        help="stop the running daemon and start a fresh one DETACHED, then return "
        "(race-safe; waits for the port to actually free, errors out instead of "
        "leaving nothing running)",
    )
    p_restart.set_defaults(func=run_restart)

    p_status = sub.add_parser(
        "status",
        help="is the daemon running? (pidfile + verified pid + version; exit 0 = "
        "running, 1 = not running)",
    )
    p_status.set_defaults(func=run_status)

    p_stop = sub.add_parser(
        "stop", help="stop the running daemon (signals only the pidfile's daemon pid)"
    )
    p_stop.set_defaults(func=run_stop)

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

    p_pairs = sub.add_parser(
        "pairs", help="list this installation's pairing id, paired peers and pending repairs"
    )
    p_pairs.set_defaults(func=run_pairs)

    p_preset = sub.add_parser(
        "pair-reset",
        help="forget a peer's pairing key (reinstalled peer / lost keys) so it pairs again",
    )
    p_preset.add_argument("peer", help="peer id (or 8+ char prefix), slot host:port, host or machine")
    p_preset.set_defaults(func=run_pair_reset)

    p_trust = sub.add_parser(
        "trust",
        help="local trust list: tasks from a named session on a PAIRED peer count like "
        "the user's own (granted only here, by the user of this machine)",
    )
    p_trust.add_argument("action", choices=("list", "add", "remove", "verify"))
    p_trust.add_argument("peer", nargs="?", default="",
                         help="peer id (or 8+ char prefix), slot host:port, host or machine")
    p_trust.add_argument("session", nargs="?", default="", help="the sender's session name")
    p_trust.add_argument("--yes", action="store_true",
                         help="the user already confirmed (no interactive question)")
    p_trust.set_defaults(func=run_trust)

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
    p_holder.add_argument("--relay-sock", default="")
    p_holder.add_argument("--no-direct", action="store_true",
                          help="never connect to the peer directly (via-inbound peer)")
    p_holder.set_defaults(func=run_holder)

    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        return run_daemon(args)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
