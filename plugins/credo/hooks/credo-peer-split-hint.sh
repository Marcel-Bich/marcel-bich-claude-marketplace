#!/usr/bin/env bash
# credo-peer-split-hint.sh - credo plugin (SessionStart hook)
#
# Cheap "split world" hint: when this session's Claude peer socket dir (from its own
# registry descriptor) holds fewer live peers than another candidate dir
# ($XDG_RUNTIME_DIR/cc-socks vs the /tmp fallback), sessions were started with a
# different XDG_RUNTIME_DIR. The hint names the fix and points at
# scripts/credo-peer-check.py. Silent when there is no such split or when this
# session's descriptor is not found (no guessing, no false alarm).
#
# Read-only: lists socket dirs and reads descriptors, never connects or sends.
# Disable with CREDO_PEER_SPLIT_HINT=0. Always exits 0.

trap 'exit 0' ERR
case "${CREDO_PEER_SPLIT_HINT:-1}" in 0|false|no|off) exit 0 ;; esac
PY="$(command -v python3 2>/dev/null)" || exit 0
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" 2>/dev/null && pwd)/credo-peer-check.py"
[ -f "$SCRIPT" ] || exit 0
to=""
command -v timeout >/dev/null 2>&1 && to="timeout 4"
# shellcheck disable=SC2086  # $to is an intentional optional command prefix
$to "$PY" "$SCRIPT" hook 2>/dev/null || true
exit 0
