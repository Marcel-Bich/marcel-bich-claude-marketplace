#!/bin/bash
# credo-budget-read - read the limit-plugin usage cache (display values only).
#
# The ONLY budget data source is the limit-plugin cache in the temp dir:
#   /tmp/claude-mb-limit-cache_*.json   (one file per profile)
# The most recent file by mtime is used. The cache holds DISPLAY values only
# (utilization percentages and reset timestamps) - no credentials, no tokens.
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
#
# Env overrides (mainly for testing):
#   CREDO_LIMIT_CACHE_GLOB     glob for cache files
#                              (default /tmp/claude-mb-limit-cache_*.json)
#   CREDO_BUDGET_MAX_AGE_SECONDS  staleness threshold in seconds (default 300)

set -euo pipefail

GLOB="${CREDO_LIMIT_CACHE_GLOB:-/tmp/claude-mb-limit-cache_*.json}"
MAX_AGE="${CREDO_BUDGET_MAX_AGE_SECONDS:-300}"

MODE="${1:-kv}"
case "$MODE" in
    kv) MODE=kv ;;
    --json) MODE=json ;;
    *) echo "credo-budget-read: unknown argument: $MODE" >&2; exit 1 ;;
esac

CREDO_LIMIT_CACHE_GLOB="$GLOB" CREDO_BUDGET_MAX_AGE_SECONDS="$MAX_AGE" \
CREDO_BUDGET_MODE="$MODE" python3 - <<'PY'
import glob
import json
import os
import sys
import time

pattern = os.environ["CREDO_LIMIT_CACHE_GLOB"]
max_age = float(os.environ["CREDO_BUDGET_MAX_AGE_SECONDS"])
mode = os.environ["CREDO_BUDGET_MODE"]

files = glob.glob(pattern)
if not files:
    sys.stderr.write("credo-budget-read: no limit cache found (limit plugin absent)\n")
    sys.exit(3)

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
