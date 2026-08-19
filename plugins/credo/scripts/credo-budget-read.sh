#!/bin/bash
# credo-budget-read - read the limit-plugin usage cache (display values only).
#
# The ONLY budget data source is the limit-plugin cache in the temp dir:
#   /tmp/claude-mb-limit-cache_<profile>.json   (one file per Claude Code profile,
#   the <profile> suffix is basename "$CLAUDE_CONFIG_DIR", e.g. _.claude.json)
# The cache is ALWAYS pinned to the current profile: the script reads exactly
# that profile's file, so it can never return another profile's numbers. The
# profile is ${CLAUDE_CONFIG_DIR:-$HOME/.claude} - when CLAUDE_CONFIG_DIR is
# unset it is the default profile ($HOME/.claude, pinned to _.claude.json).
# Only an explicit CREDO_LIMIT_CACHE_GLOB override can make several files match;
# an ambiguous multi-match is then refused (exit 5), never guessed. The cache
# holds DISPLAY values only (utilization percentages and reset timestamps) - no
# credentials, no tokens.
#
# SECURITY (hard rule, do not change):
#   This script reads ONLY the cache file above. It NEVER reads
#   ~/.claude/.credentials.json or any OAuth token, and it NEVER runs the
#   usage-statusline script. Budget data is display values only.
#
# Freshness: the cache is only trustworthy while the limit plugin is active
# (the statusline refreshes it every 1-2 min). If the newest cache file is
# older than the max-age threshold it is treated as STALE and NOT used, so a
# dormant/absent limit plugin never yields misleading numbers.
#
# Usage:
#   credo-budget-read.sh            print key=value lines (exit 0 on success)
#   credo-budget-read.sh --json     print the trimmed JSON object
#
# Exit codes:
#   0  fresh cache found and printed
#   3  no cache file present (limit plugin absent -> budget data unavailable)
#   4  newest cache is stale (older than max age -> do not use)
#   5  multiple cache files match via an explicit CREDO_LIMIT_CACHE_GLOB
#      wildcard override -> refuse to guess (only reachable with that override;
#      the profile is otherwise always pinned)
#
# Env overrides (mainly for testing):
#   CREDO_LIMIT_CACHE_GLOB     explicit glob for cache files. When set it always
#                              wins and is never overwritten. A pattern matching
#                              exactly one file uses it; a wildcard matching
#                              several files is refused (exit 5). When unset, the
#                              glob is pinned to the current profile via
#                              ${CLAUDE_CONFIG_DIR:-$HOME/.claude} (see below).
#   CLAUDE_CONFIG_DIR          selects the profile whose cache is read (no
#                              explicit glob): the glob is pinned to
#                              /tmp/claude-mb-limit-cache_<basename>.json.
#                              When unset it defaults to $HOME/.claude, so the
#                              default profile pins to _.claude.json.
#   CREDO_BUDGET_MAX_AGE_SECONDS  staleness threshold in seconds (default 300)

set -euo pipefail

# Resolve the cache glob. Precedence:
#   1. explicit CREDO_LIMIT_CACHE_GLOB override always wins - never overwritten.
#   2. otherwise, pin to the current profile's exact cache file via
#      ${CLAUDE_CONFIG_DIR:-$HOME/.claude}, so another profile's numbers can
#      never be returned. This mirrors the limit plugin's own writer and every
#      sibling credo script: an unset CLAUDE_CONFIG_DIR is the default profile
#      ($HOME/.claude), pinned deterministically to _.claude.json - never a
#      profile-blind wildcard.
GLOB_EXPLICIT=0
if [ -n "${CREDO_LIMIT_CACHE_GLOB:-}" ]; then
    GLOB="$CREDO_LIMIT_CACHE_GLOB"
    GLOB_EXPLICIT=1
else
    GLOB="/tmp/claude-mb-limit-cache_$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}").json"
fi
MAX_AGE="${CREDO_BUDGET_MAX_AGE_SECONDS:-300}"

MODE="${1:-kv}"
case "$MODE" in
    kv) MODE=kv ;;
    --json) MODE=json ;;
    *) echo "credo-budget-read: unknown argument: $MODE" >&2; exit 1 ;;
esac

CREDO_LIMIT_CACHE_GLOB="$GLOB" CREDO_BUDGET_MAX_AGE_SECONDS="$MAX_AGE" \
CREDO_BUDGET_GLOB_EXPLICIT="$GLOB_EXPLICIT" \
CREDO_BUDGET_MODE="$MODE" python3 - <<'PY'
import glob
import json
import os
import sys
import time

pattern = os.environ["CREDO_LIMIT_CACHE_GLOB"]
max_age = float(os.environ["CREDO_BUDGET_MAX_AGE_SECONDS"])
glob_explicit = os.environ.get("CREDO_BUDGET_GLOB_EXPLICIT") == "1"
mode = os.environ["CREDO_BUDGET_MODE"]

files = glob.glob(pattern)
if not files:
    sys.stderr.write("credo-budget-read: no limit cache found (limit plugin absent)\n")
    sys.exit(3)

# Fail loud instead of guessing: the profile is always pinned (via
# CLAUDE_CONFIG_DIR or the $HOME/.claude default), so the resolved glob is an
# exact single-file pattern and matches at most one cache by construction.
# Several files can therefore only match through an explicit CREDO_LIMIT_CACHE_GLOB
# wildcard override; picking "newest" across them could return another profile's
# numbers, so refuse instead of guessing (glob_explicit names the likely cause).
if len(files) > 1:
    hint = (
        "an explicit CREDO_LIMIT_CACHE_GLOB wildcard matched several profiles"
        if glob_explicit
        else "the resolved profile glob unexpectedly matched several files"
    )
    sys.stderr.write(
        "credo-budget-read: %d cache files match (%s) - no single profile is "
        "pinned; set CLAUDE_CONFIG_DIR or a single-file CREDO_LIMIT_CACHE_GLOB; "
        "refusing to guess\n" % (len(files), hint)
    )
    sys.exit(5)

newest = max(files, key=os.path.getmtime)
age = time.time() - os.path.getmtime(newest)
if age > max_age:
    sys.stderr.write(
        "credo-budget-read: newest cache is stale (%.0fs > %.0fs) - not used\n"
        % (age, max_age)
    )
    sys.exit(4)

try:
    with open(newest, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError) as exc:
    sys.stderr.write("credo-budget-read: cannot read cache: %s\n" % exc)
    sys.exit(1)


def sub(name):
    val = data.get(name)
    return val if isinstance(val, dict) else {}


five = sub("five_hour")
week = sub("seven_day")
sonnet = sub("seven_day_sonnet")

trimmed = {
    "cache_file": newest,
    "cache_age_seconds": round(age, 1),
    "five_hour": {
        "utilization": five.get("utilization"),
        "resets_at": five.get("resets_at"),
    },
    "seven_day": {
        "utilization": week.get("utilization"),
        "resets_at": week.get("resets_at"),
    },
    "seven_day_sonnet": {
        "utilization": sonnet.get("utilization"),
    },
}

if mode == "json":
    print(json.dumps(trimmed, indent=2))
else:
    print("cache_file=%s" % trimmed["cache_file"])
    print("cache_age_seconds=%s" % trimmed["cache_age_seconds"])
    print("five_hour_utilization=%s" % trimmed["five_hour"]["utilization"])
    print("five_hour_resets_at=%s" % trimmed["five_hour"]["resets_at"])
    print("seven_day_utilization=%s" % trimmed["seven_day"]["utilization"])
    print("seven_day_resets_at=%s" % trimmed["seven_day"]["resets_at"])
    print("seven_day_sonnet_utilization=%s" % trimmed["seven_day_sonnet"]["utilization"])
PY
