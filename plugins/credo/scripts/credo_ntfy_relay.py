#!/usr/bin/env python3
"""Optional local ntfy relay for credo pushes (config key personal.ntfy_relay).

Some setups do not let an agent send straight to the public ntfy server (a command
safety net may block it as an upload to a remote host). They run a small local relay
instead: an HTTP service on the loopback interface that owns the ntfy topic and
forwards each push to it. credo then talks only to that relay and never sends the
topic anywhere.

Relay contract (what credo sends, what it expects back):

    POST <personal.ntfy_relay>            e.g. http://127.0.0.1:8765/send
    Content-Type: application/json; charset=utf-8
    {"title": "<1-50 chars>", "body": "<message>",
     "priority": "min|low|default|high|max", "tags": "<[A-Za-z0-9_,-]{0,64}>"}

    2xx  -> accepted (the relay forwarded it)
    else -> failure (credo reports it and exits non-zero)

All four fields are always sent. The topic and the ntfy server are NOT part of the
request: the relay owns them. Redirects are not followed and proxy variables are
ignored, so a push can never leave the loopback interface through credo.

Only plain http URLs on a loopback host are accepted: 127.0.0.1, localhost or
[::1], with an optional port and path. No user info, query or fragment.

CLI (used by credo-ntfy-send.sh and /credo:setup):
    credo_ntfy_relay.py validate <url>       exit 0 valid, 2 invalid (reason on stderr)
    credo_ntfy_relay.py send <url> [--title T] [--priority P] [--tags X]
                                             body from stdin; exit 0 sent, 2 invalid
                                             input, 3 send failed (reason on stderr)
    credo_ntfy_relay.py probe [<url>]        read-only: TCP connect only, nothing is
                                             sent; exit 0 listening, 1 not, 2 invalid
The default probe URL is DEFAULT_URL.
"""
import json
import re
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_URL = "http://127.0.0.1:8765/send"
LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1")
PRIORITIES = ("min", "low", "default", "high", "max")
TAGS_RE = re.compile(r"^[A-Za-z0-9_,-]{0,64}$")
TITLE_MAX = 50
DEFAULT_TITLE = "credo"


def validate_url(url):
    """(ok, reason). Accepts only http URLs on a loopback host."""
    if not url or not isinstance(url, str):
        return False, "empty relay URL"
    if any(c.isspace() or ord(c) < 32 for c in url):
        return False, "relay URL contains whitespace or control characters"
    try:
        parts = urllib.parse.urlsplit(url)
        port = parts.port
    except ValueError as exc:
        return False, "relay URL does not parse (%s)" % exc
    if parts.scheme != "http":
        return False, "relay URL must use http:// (got %r)" % (parts.scheme or "")
    if parts.username is not None or parts.password is not None or "@" in parts.netloc:
        return False, "relay URL must not carry user info"
    host = parts.hostname or ""
    if host not in LOOPBACK_HOSTS:
        return False, "relay host must be 127.0.0.1, localhost or [::1]"
    if host == "::1" and not parts.netloc.startswith("[::1]"):
        return False, "IPv6 loopback must be written as [::1]"
    if port is not None and not 0 < port < 65536:
        return False, "relay port out of range"
    if parts.query or parts.fragment or url.endswith(("?", "#")):
        return False, "relay URL must not have a query or fragment"
    return True, ""


def build_payload(title, body, priority, tags):
    """(payload_dict, reason). reason is empty when the payload is valid."""
    title = (title or "").strip() or DEFAULT_TITLE
    priority = priority or "default"
    tags = tags or ""
    if not body:
        return None, "empty message"
    if priority not in PRIORITIES:
        return None, "invalid priority %r (use %s)" % (priority, "|".join(PRIORITIES))
    if not TAGS_RE.match(tags):
        return None, "invalid tags (allowed: letters, digits, _ , -; max 64)"
    return {"title": title[:TITLE_MAX], "body": body, "priority": priority,
            "tags": tags}, ""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def _opener():
    # No proxies (a proxy would carry the push off the machine), no redirects.
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())


def send(url, title, body, priority=None, tags=None, timeout=15):
    """(ok, reason). Never raises; the reason never contains the body."""
    ok, reason = validate_url(url)
    if not ok:
        return False, "invalid personal.ntfy_relay: " + reason
    payload, reason = build_payload(title, body, priority, tags)
    if payload is None:
        return False, reason
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST",
                                 headers={"Content-Type": "application/json; charset=utf-8"})
    try:
        with _opener().open(req, timeout=timeout) as resp:
            code = resp.status
    except urllib.error.HTTPError as exc:
        return False, "relay answered HTTP %s" % exc.code
    except (OSError, ValueError) as exc:
        return False, "relay not reachable (%s)" % type(exc).__name__
    if 200 <= code < 300:
        return True, ""
    return False, "relay answered HTTP %s" % code


def probe(url=DEFAULT_URL, timeout=2):
    """(listening, reason). Read-only: opens and closes a TCP connection, sends nothing."""
    ok, reason = validate_url(url)
    if not ok:
        return False, reason
    parts = urllib.parse.urlsplit(url)
    try:
        conn = socket.create_connection((parts.hostname, parts.port or 80), timeout=timeout)
        conn.close()
    except OSError as exc:
        return False, "no listener (%s)" % type(exc).__name__
    return True, ""


def _opt(argv, name):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return None


def main(argv):
    if not argv or argv[0] not in ("validate", "send", "probe"):
        sys.stderr.write("usage: credo_ntfy_relay.py validate|send|probe [url] ...\n")
        return 2
    cmd = argv[0]
    url = argv[1] if len(argv) > 1 and not argv[1].startswith("--") else None
    if cmd == "probe":
        listening, reason = probe(url or DEFAULT_URL)
        if listening:
            print("listening %s" % (url or DEFAULT_URL))
            return 0
        ok, _ = validate_url(url or DEFAULT_URL)
        sys.stderr.write("credo_ntfy_relay: %s\n" % reason)
        return 1 if ok else 2
    ok, reason = validate_url(url)
    if not ok:
        sys.stderr.write("credo_ntfy_relay: invalid relay URL: %s\n" % reason)
        return 2
    if cmd == "validate":
        return 0
    body = sys.stdin.read()
    payload, reason = build_payload(_opt(argv, "--title"), body, _opt(argv, "--priority"),
                                    _opt(argv, "--tags"))
    if payload is None:
        sys.stderr.write("credo_ntfy_relay: %s\n" % reason)
        return 2
    sent, reason = send(url, payload["title"], body, payload["priority"], payload["tags"])
    if sent:
        return 0
    sys.stderr.write("credo_ntfy_relay: %s\n" % reason)
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
