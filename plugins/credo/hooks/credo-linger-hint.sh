#!/usr/bin/env bash
#
# credo-linger-hint.sh
#
# SessionStart hook (item #209): a ONE-TIME hint per Claude Code profile when credo's
# daemons (LAN relay, WSL <-> Windows bridge) run as systemd user services and linger is
# off for the user (`loginctl show-user $USER -p Linger --value` = no). Without linger the
# user's systemd manager, and with it those services, stops at the last logout. The hint
# tells the agent to PROPOSE `loginctl enable-linger <user>` with a short risk note; credo
# never runs it.
#
# One-time: the stamp `credo/linger-hint.stamp` in the profile is written before the hint
# is printed; while it exists this hook does nothing (not even a Python start). Delete the
# stamp to see the hint again.
#
# Fail silent: no Linux, no loginctl/systemctl, systemd not running, Linger=yes, no credo
# unit, any error -> no output and exit 0.

case "$(uname -s 2>/dev/null)" in
  Linux) ;;
  *) exit 0 ;;
esac

cfgdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
cfgdir="${cfgdir%/}"
[ -d "$cfgdir/credo" ] || exit 0
[ -e "$cfgdir/credo/linger-hint.stamp" ] && exit 0
command -v loginctl >/dev/null 2>&1 || exit 0
command -v systemctl >/dev/null 2>&1 || exit 0

script="${CLAUDE_PLUGIN_ROOT}/scripts/credo-peer-lan.py"
[ -f "$script" ] || exit 0
# shellcheck source-path=SCRIPTDIR source=credo-python-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/credo-python-lib.sh" 2>/dev/null || exit 0
credo_find_python || exit 0
[ "$CREDO_PYTHON_OS" = "posix" ] || exit 0

to8=""
command -v timeout >/dev/null 2>&1 && to8="timeout 8"
# shellcheck disable=SC2086  # $to8 is an intentional optional command prefix
$to8 "$CREDO_PYTHON" "$script" linger --session-hint 2>/dev/null
exit 0
