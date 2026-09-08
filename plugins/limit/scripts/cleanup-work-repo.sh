#!/usr/bin/env bash
# cleanup-work-repo.sh - limit plugin
#
# SessionEnd hook. Removes the per-session work-repo state file written by
# track-work-repo.sh so /tmp does not accumulate stale files.
#
# Always exits 0. Deletes ONLY the exact per-session file - no wildcards,
# no rm -rf, no parent paths.

set +e

input=$(cat 2>/dev/null) || input=""
[[ -z "$input" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || session_id=""
[[ -z "$session_id" || "$session_id" == "null" ]] && exit 0

state_file="/tmp/claude-mb-workrepo_${session_id}"
[[ -f "$state_file" ]] && rm -f "$state_file" 2>/dev/null

exit 0
