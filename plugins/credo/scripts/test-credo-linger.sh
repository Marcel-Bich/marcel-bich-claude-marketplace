#!/bin/bash
# Tests for the linger proposal (item #209): credo_linger.py, `credo-peer-lan.py linger`,
# the linger lines of `status` / `check` and the one-time SessionStart hook
# hooks/credo-linger-hint.sh.
#
# loginctl and systemctl are FAKES on PATH (they print canned output and log their argv),
# so no real systemd manager is asked and nothing is ever enabled. Throwaway HOME, profile,
# relay config and state dirs in a temp tree; no daemon is started.
#
# Usage: bash test-credo-linger.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAN="$SCRIPT_DIR/credo-peer-lan.py"
HOOK="$SCRIPT_DIR/../hooks/credo-linger-hint.sh"
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "SKIP: python3 not found"; exit 0; fi
case "$(uname -s)" in Linux) ;; *) echo "SKIP: Linux only"; exit 0 ;; esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cling.XXXXXX")"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

PASS=0
FAIL=0
ok() { # name cond(0=pass)
    if [ "$2" = "0" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; fi
}
has() { printf '%s' "$1" | grep -qF -- "$2" && echo 0 || echo 1; }
hasnt() { printf '%s' "$1" | grep -qF -- "$2" && echo 1 || echo 0; }

FAKEBIN="$TMP/bin"
mkdir -p "$FAKEBIN"
ARGLOG="$TMP/fake-argv.log"
: > "$ARGLOG"

# fake loginctl: FAKE_LINGER (yes|no|garbage), FAKE_LOGINCTL_RC (default 0)
cat > "$FAKEBIN/loginctl" <<'EOF'
#!/bin/sh
echo "loginctl $*" >> "$FAKE_ARGLOG"
[ "${FAKE_LOGINCTL_RC:-0}" = "0" ] || { echo "System has not been booted with systemd" >&2; exit "$FAKE_LOGINCTL_RC"; }
case "$*" in
  "show-user "*" -p Linger --value") printf '%s\n' "${FAKE_LINGER:-no}" ;;
  *) exit 1 ;;
esac
EOF
# fake systemctl: FAKE_UNITS (newline-separated list-units lines), FAKE_SYSTEMCTL_RC
cat > "$FAKEBIN/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$FAKE_ARGLOG"
[ "${FAKE_SYSTEMCTL_RC:-0}" = "0" ] || exit "$FAKE_SYSTEMCTL_RC"
case "$*" in
  "--user list-units "*) [ -n "${FAKE_UNITS:-}" ] && printf '%s\n' "$FAKE_UNITS"; exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKEBIN/loginctl" "$FAKEBIN/systemctl"

RELAY_UNIT="credo-peer-lan-49731-1700000000-4242.service loaded active running credo peer-lan relay"
BRIDGE_UNIT="credo-win-bridge-1700000000-4343.service loaded active running credo WSL-Windows peer bridge"

HOME_DIR="$TMP/home"
PROFILE="$HOME_DIR/.claude"
mkdir -p "$PROFILE/credo" "$TMP/state" "$TMP/relay"
CFG="$TMP/relay/peer-lan.json"
printf '{"this_machine": "box-1", "listen_host": "127.0.0.1", "listen_port": 49731, "peers": []}\n' > "$CFG"
CFG_TOK="$TMP/relay/peer-lan-token.json"
printf '{"this_machine": "box-1", "listen_host": "127.0.0.1", "listen_port": 49731, "peers": [], "token": "fixture-secret-value-0001"}\n' > "$CFG_TOK"

# run a command in the isolated environment with the fakes first on PATH
run_env() {
    env HOME="$HOME_DIR" USER=alice LOGNAME=alice CLAUDE_CONFIG_DIR="$PROFILE" \
        XDG_STATE_HOME="$TMP/state" CREDO_WIN_BRIDGE_STATE="$TMP/state/wb" \
        CREDO_PEER_LAN_CONFIG="${T_CFG:-$CFG}" CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.." \
        PATH="$FAKEBIN:$PATH" FAKE_ARGLOG="$ARGLOG" \
        FAKE_LINGER="${T_LINGER:-no}" FAKE_UNITS="${T_UNITS:-}" \
        FAKE_LOGINCTL_RC="${T_LRC:-0}" FAKE_SYSTEMCTL_RC="${T_SRC:-0}" "$@"
}

# --- linger subcommand ----------------------------------------------------------------
out="$(T_UNITS="$RELAY_UNIT
$BRIDGE_UNIT" run_env "$PY" "$LAN" linger 2>&1)"
ok "Linger=no: state line names the user" "$(has "$out" "linger: no for alice")"
ok "Linger=no: lists both units" "$(has "$out" "credo-peer-lan-49731-1700000000-4242.service, credo-win-bridge-1700000000-4343.service")"
ok "Linger=no: proposal command" "$(has "$out" "proposal (the owner decides; credo never runs it): loginctl enable-linger alice")"
ok "Linger=no: risk keeps running after logout" "$(has "$out" "keep running after logout")"
ok "Linger=no: relay reachable on its port" "$(has "$out" "stays reachable on port 49731 while nobody is logged in")"
ok "Linger=no: token and allow-list matter more" "$(has "$out" "shared token and the network allow-list matter more")"
ok "Linger=no, no token: says so" "$(has "$out" "no shared token is set")"

out="$(T_CFG="$CFG_TOK" T_UNITS="$RELAY_UNIT" run_env "$PY" "$LAN" linger 2>&1)"
ok "token set: no 'no shared token' line" "$(hasnt "$out" "no shared token")"
ok "token value never printed" "$(hasnt "$out" "fixture-secret-value-0001")"

out="$(T_UNITS="$BRIDGE_UNIT" run_env "$PY" "$LAN" linger 2>&1)"
ok "bridge only: proposal shown" "$(has "$out" "loginctl enable-linger alice")"
ok "bridge only: no relay port sentence" "$(hasnt "$out" "stays reachable")"

out="$(T_LINGER=yes T_UNITS="$RELAY_UNIT" run_env "$PY" "$LAN" linger 2>&1)"
ok "Linger=yes: yes line" "$(has "$out" "linger: yes for alice")"
ok "Linger=yes: no proposal" "$(hasnt "$out" "enable-linger")"

out="$(T_UNITS="" run_env "$PY" "$LAN" linger 2>&1)"
ok "no credo unit: silent" "$([ -z "$out" ] && echo 0 || echo 1)"

out="$(T_LRC=1 T_UNITS="$RELAY_UNIT" run_env "$PY" "$LAN" linger 2>&1)"
ok "loginctl fails (no systemd): silent" "$([ -z "$out" ] && echo 0 || echo 1)"

out="$(T_SRC=1 T_UNITS="$RELAY_UNIT" run_env "$PY" "$LAN" linger 2>&1)"
ok "systemctl fails: silent" "$([ -z "$out" ] && echo 0 || echo 1)"

out="$(T_LINGER=maybe T_UNITS="$RELAY_UNIT" run_env "$PY" "$LAN" linger 2>&1)"
ok "unexpected loginctl output: silent" "$([ -z "$out" ] && echo 0 || echo 1)"

# loginctl missing: a PATH with only the fake systemctl (python is called by full path)
ONLYSC="$TMP/onlysc"
mkdir -p "$ONLYSC"
cp "$FAKEBIN/systemctl" "$ONLYSC/systemctl"
out="$(env HOME="$HOME_DIR" USER=alice CLAUDE_CONFIG_DIR="$PROFILE" CREDO_PEER_LAN_CONFIG="$CFG" \
    XDG_STATE_HOME="$TMP/state" CREDO_WIN_BRIDGE_STATE="$TMP/state/wb" \
    PATH="$ONLYSC" FAKE_ARGLOG="$ARGLOG" FAKE_UNITS="$RELAY_UNIT" "$PY" "$LAN" linger 2>&1)"
ok "loginctl missing: silent" "$([ -z "$out" ] && echo 0 || echo 1)"

# --- status / check carry the same lines ------------------------------------------------
out="$(T_UNITS="$RELAY_UNIT" run_env "$PY" "$LAN" status 2>&1)"
ok "status shows the linger proposal" "$(has "$out" "loginctl enable-linger alice")"
out="$(T_UNITS="$RELAY_UNIT" run_env timeout 60 "$PY" "$LAN" check --no-install 2>&1)"
ok "check shows the linger proposal" "$(has "$out" "loginctl enable-linger alice")"
out="$(T_UNITS="" run_env "$PY" "$LAN" status 2>&1)"
ok "status without credo units: no linger line" "$(hasnt "$out" "linger:")"

# --- one-time SessionStart hook -----------------------------------------------------------
STAMP="$PROFILE/credo/linger-hint.stamp"
out="$(T_LINGER=yes T_UNITS="$RELAY_UNIT" run_env bash "$HOOK" 2>&1)"; rc=$?
ok "hook Linger=yes: silent" "$([ -z "$out" ] && echo 0 || echo 1)"
ok "hook Linger=yes: exit 0" "$([ "$rc" = 0 ] && echo 0 || echo 1)"
ok "hook Linger=yes: no stamp" "$([ ! -e "$STAMP" ] && echo 0 || echo 1)"

out="$(T_UNITS="" run_env bash "$HOOK" 2>&1)"
ok "hook without units: silent, no stamp" "$([ -z "$out" ] && [ ! -e "$STAMP" ] && echo 0 || echo 1)"

out="$(T_LRC=1 T_UNITS="$RELAY_UNIT" run_env bash "$HOOK" 2>&1)"; rc=$?
ok "hook loginctl error: silent, exit 0, no stamp" "$([ -z "$out" ] && [ "$rc" = 0 ] && [ ! -e "$STAMP" ] && echo 0 || echo 1)"

out="$(T_UNITS="$RELAY_UNIT" run_env bash "$HOOK" 2>&1)"
ok "hook Linger=no: hint printed" "$(has "$out" "[credo-linger]")"
ok "hook hint: proposal" "$(has "$out" "\`loginctl enable-linger alice\`")"
ok "hook hint: never run it yourself" "$(has "$out" "never run it yourself")"
ok "hook hint: no shared token mentioned" "$(has "$out" "No shared token is set")"
ok "hook hint: stamp written" "$([ -e "$STAMP" ] && echo 0 || echo 1)"
out="$(T_UNITS="$RELAY_UNIT" run_env bash "$HOOK" 2>&1)"
ok "hook second run: silent (one-time)" "$([ -z "$out" ] && echo 0 || echo 1)"

# another profile gets its own one-time hint
P2="$HOME_DIR/.claude-two"
mkdir -p "$P2/credo"
out="$(T_UNITS="$RELAY_UNIT" run_env env CLAUDE_CONFIG_DIR="$P2" bash "$HOOK" 2>&1)"
ok "hook: other profile gets its own hint" "$(has "$out" "[credo-linger]")"

# a profile without a credo dir: silent (nothing to persist the stamp in)
P3="$HOME_DIR/.claude-three"
mkdir -p "$P3"
out="$(T_UNITS="$RELAY_UNIT" run_env env CLAUDE_CONFIG_DIR="$P3" bash "$HOOK" 2>&1)"
ok "hook: no credo dir -> silent" "$([ -z "$out" ] && [ ! -e "$P3/credo" ] && echo 0 || echo 1)"

# --- never enables linger -----------------------------------------------------------------
ok "loginctl enable-linger was never called" "$(grep -q "enable-linger" "$ARGLOG" && echo 1 || echo 0)"
ok "only read-only loginctl calls" "$(grep '^loginctl' "$ARGLOG" | grep -vq 'show-user .* -p Linger --value' && echo 1 || echo 0)"

# --- quoting of an odd user name ---------------------------------------------------------
out="$("$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); import credo_linger as l; print(l.enable_command("a b;c")); print(l.enable_command("alice"))' "$SCRIPT_DIR")"
ok "odd user name is shell-quoted" "$(has "$out" "loginctl enable-linger 'a b;c'")"
ok "plain user name unquoted" "$(has "$out" "loginctl enable-linger alice")"

echo "linger tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
