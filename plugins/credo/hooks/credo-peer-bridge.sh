#!/usr/bin/env bash
#
# credo-peer-bridge.sh
#
# Cross-profile peer discovery bridge.
#
# Claude Code discovers local peer sessions (ListAgents / SendMessage) by reading
# session descriptor files under "<CLAUDE_CONFIG_DIR>/sessions/". Sessions started
# under a DIFFERENT profile (a different CLAUDE_CONFIG_DIR, e.g. ~/.claude vs
# ~/.claude-private) register in a different sessions/ dir and are therefore
# invisible to each other - even though the inbox sockets all live in one shared
# runtime dir and the transport works fine across profiles.
#
# This hook makes cross-profile peers discoverable by mirroring the LIVE descriptor
# of every sibling-profile session into the current profile's sessions/ dir as a
# regular file, tagged with an ownership marker. (Symlinks are NOT honored by the
# discovery reader - it only enumerates regular files - so a real copy is required.)
#
# The resume picker is unaffected: /resume reads transcripts under projects/, never
# sessions/, so a mirrored descriptor without a local transcript never appears there.
# Work and private history stay fully separate.
#
# SAFETY (highest priority):
#   - Only ever removes files that carry our ownership marker as a real top-level
#     JSON key ("credoPeerBridge"), plus leftover v1 symlinks that point into a
#     sibling sessions/ dir, plus our own temp files from dead runs. A real local
#     descriptor is a regular file WITHOUT the marker key and is never touched. If
#     the CLI ever reuses a pid and overwrites one of our copies, the marker is gone
#     with it, so we no longer consider that file ours.
#   - Never removes directories, never touches anything outside <config>/sessions/.
#   - Always exits 0 so a failure can never surface as a hook error.
#
# Caveat: the descriptor format is internal to Claude Code and undocumented; a future
# version may change it. This bridge is fail-safe - if that happens, at worst peers
# stop appearing; nothing is corrupted. Disable anytime with CREDO_PEER_BRIDGE=0.

# Intentionally NO `set -e`: runs on every prompt/tool, must never abort a turn.

case "${CREDO_PEER_BRIDGE:-1}" in
  0|false|no|off) exit 0 ;;
esac

cur_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
cur_cfg="${cur_cfg%/}"
cur_sess="$cur_cfg/sessions"
[ -d "$cur_sess" ] || exit 0

# python3 is required to inject/verify the marker as structured JSON; fail-safe if absent.
PY="$(command -v python3 2>/dev/null || true)"
[ -n "$PY" ] || exit 0

MARK='credoPeerBridge'
pid_alive() { kill -0 "$1" 2>/dev/null; }

# Ownership check: the marker must be a real top-level JSON key, not just a byte
# sequence somewhere in the file. grep is a cheap pre-filter; the structural python
# confirm only runs on the rare files that already contain the string, so the common
# case (no marker) stays fast.
is_ours() {
  grep -q "\"$MARK\"" "$1" 2>/dev/null || return 1
  "$PY" - "$1" "$MARK" >/dev/null 2>&1 <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and sys.argv[2] in d else 1)
PYEOF
}

if command -v shopt >/dev/null 2>&1; then shopt -s nullglob 2>/dev/null; fi

# housekeeping: drop leftover temp files from dead runs only (never a live peer's).
# tmp name is ".credo-bridge.<pid>.tmp.<ownerpid>"; the trailing component is the
# owning shell's pid.
for t in "$cur_sess"/.credo-bridge.*.tmp.*; do
  [ -e "$t" ] || continue
  owner="${t##*.}"
  if ! printf '%s' "$owner" | grep -Eq '^[0-9]+$' || ! pid_alive "$owner"; then
    rm -f -- "$t" 2>/dev/null || true
  fi
done

# --- 1) prune stale entries we own ------------------------------------------
for entry in "$cur_sess"/*.json; do
  # leftover v1 symlinks (never discovered anyway): remove only if they point into
  # a sibling sessions/ dir - never touch a symlink we did not create.
  if [ -L "$entry" ]; then
    ltarget="$(readlink "$entry" 2>/dev/null || true)"
    case "$ltarget" in
      "$HOME"/.claude*/sessions/*.json) rm -f -- "$entry" 2>/dev/null || true ;;
    esac
    continue
  fi
  [ -f "$entry" ] || continue
  is_ours "$entry" || continue             # only our marked copies
  pid="$(basename "$entry" .json)"
  if ! printf '%s' "$pid" | grep -Eq '^[0-9]+$' || ! pid_alive "$pid"; then
    rm -f -- "$entry" 2>/dev/null || true  # source session gone (its pid died)
  fi
done

# --- 2) mirror live sibling descriptors -------------------------------------
for sib_cfg in "$HOME"/.claude*/; do
  sib_cfg="${sib_cfg%/}"
  [ "$sib_cfg" = "$cur_cfg" ] && continue
  sib_sess="$sib_cfg/sessions"
  [ -d "$sib_sess" ] || continue

  for src in "$sib_sess"/*.json; do
    [ -e "$src" ] || continue
    [ -L "$src" ] && continue               # regular files only
    [ -f "$src" ] || continue
    is_ours "$src" && continue              # loop-safety: never bridge a bridged copy
    pid="$(basename "$src" .json)"
    printf '%s' "$pid" | grep -Eq '^[0-9]+$' || continue
    pid_alive "$pid" || continue

    dst="$cur_sess/$pid.json"
    # a regular file that is NOT ours is a real local session - never touch it
    if [ -e "$dst" ] && ! is_ours "$dst"; then
      continue
    fi
    # refresh only when the source is newer (keeps status fresh, avoids churn)
    if [ -e "$dst" ] && [ ! "$src" -nt "$dst" ]; then
      continue
    fi

    tmp="$cur_sess/.credo-bridge.$pid.tmp.$$"
    if "$PY" - "$src" "$MARK" "$sib_cfg" >"$tmp" 2>/dev/null <<'PYEOF'
import json, sys
src, mark, frm = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as fh:
    d = json.load(fh)
if not isinstance(d, dict):
    raise SystemExit(1)
d[mark] = True
d[mark + "From"] = frm
sys.stdout.write(json.dumps(d))
PYEOF
    then
      mv -f -- "$tmp" "$dst" 2>/dev/null || rm -f -- "$tmp" 2>/dev/null || true
    else
      rm -f -- "$tmp" 2>/dev/null || true
    fi
  done
done

exit 0
