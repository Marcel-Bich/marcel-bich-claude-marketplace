#!/bin/bash
# credo-optimize-idle - is this repo idle long enough to offer the optimisation audit
# to a RETURNING user? Never meant to disturb someone who is actively working.
#
# Idle means ALL four signals are older than the threshold (wall-clock):
#   last_seen  credo's own per-repo last-seen timestamp (credo-optimize-state.sh)
#   reflog     newest reflog entry of HEAD (commits, checkouts, pulls, merges);
#              read as the mtime of the append-only logs/HEAD file
#   index      mtime of the git index
#   dirty      newest mtime among the paths `git status --porcelain` reports as
#              modified or untracked (no full tree scan; deleted paths are skipped,
#              an untracked directory counts with its own mtime)
# A missing signal (never seen, no reflog, no index, clean tree) does not argue
# against idle. The index mtime is read BEFORE `git status` runs, and git status runs
# with GIT_OPTIONAL_LOCKS=0, so this check never refreshes the index itself.
#
# Usage:
#   credo-optimize-idle.sh [--repo DIR] [--days N] [--json]
#
# Threshold: --days > CREDO_OPTIMIZE_IDLE_DAYS > config optimize.idle_days > 7.
#
# Output (key=value lines, or one JSON object with --json):
#   idle=yes|no  threshold_days=N  and one age per signal in seconds
#   (age_last_seen_s, age_reflog_s, age_index_s, age_dirty_s; "none" when absent)
#
# Env overrides (tests): CREDO_OPTIMIZE_NOW (epoch "now"), CREDO_OPTIMIZE_DIR (state
# store, see credo-optimize-state.sh).
#
# Exit codes: 0 idle, 1 not idle, 2 bad arguments, 4 not a git repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "credo-optimize-idle: $1" >&2; exit "${2:-2}"; }

REPO_ARG=""
DAYS=""
JSON=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) [ $# -ge 2 ] || die "--repo needs a dir"; REPO_ARG="$2"; shift 2 ;;
        --days) [ $# -ge 2 ] || die "--days needs a number"; DAYS="$2"; shift 2 ;;
        --json) JSON=1; shift ;;
        *) die "usage: credo-optimize-idle.sh [--repo DIR] [--days N] [--json]" ;;
    esac
done

START="${REPO_ARG:-$PWD}"
[ -d "$START" ] || die "no such dir: $START"
TOP="$(git -C "$START" rev-parse --show-toplevel 2>/dev/null)" || die "not a git repo: $START" 4
[ -n "$TOP" ] || die "not a git repo: $START" 4

# --- threshold ---------------------------------------------------------------
if [ -z "$DAYS" ]; then DAYS="${CREDO_OPTIMIZE_IDLE_DAYS:-}"; fi
if [ -z "$DAYS" ]; then
    DAYS="$(cd "$TOP" && CREDO_SKIP_ENSURE=1 "$SCRIPT_DIR/credo-config.sh" get optimize.idle_days 2>/dev/null)" || DAYS=""
fi
[[ "$DAYS" =~ ^[0-9]+$ ]] || DAYS=7
THRESHOLD=$((DAYS * 86400))

NOW="${CREDO_OPTIMIZE_NOW:-$(date +%s)}"
[[ "$NOW" =~ ^[0-9]+$ ]] || die "CREDO_OPTIMIZE_NOW is not an epoch"

mtime() { stat -c %Y -- "$1" 2>/dev/null || true; }

# --- signals (index first, before git status can touch anything) -------------
abs_git_path() { # git-path -> absolute
    local p
    p="$(git -C "$TOP" rev-parse --git-path "$1")"
    case "$p" in /*) printf '%s' "$p" ;; *) printf '%s/%s' "$TOP" "$p" ;; esac
}
ts_index="$(mtime "$(abs_git_path index)")"
ts_reflog="$(mtime "$(abs_git_path logs/HEAD)")"
ts_seen="$("$SCRIPT_DIR/credo-optimize-state.sh" --repo "$TOP" get-seen 2>/dev/null)" || ts_seen=""
[[ "$ts_seen" =~ ^[0-9]+$ ]] || ts_seen=""

ts_dirty=""
while IFS= read -r -d '' entry; do
    status="${entry:0:2}"
    path="${entry:3}"
    # rename/copy entries carry the source path as an extra NUL field: skip it
    case "$status" in R*|C*) IFS= read -r -d '' _ || true ;; esac
    case "$status" in *D*) continue ;; esac
    t="$(mtime "$TOP/$path")"
    [ -n "$t" ] || continue
    if [ -z "$ts_dirty" ] || [ "$t" -gt "$ts_dirty" ]; then ts_dirty="$t"; fi
done < <(GIT_OPTIONAL_LOCKS=0 git -C "$TOP" status --porcelain -z --untracked-files=normal 2>/dev/null)

age() { # timestamp-or-empty -> age in seconds or "none" (future mtimes count as 0)
    if [ -z "$1" ]; then echo none; return; fi
    local a=$((NOW - $1))
    [ "$a" -lt 0 ] && a=0
    echo "$a"
}
a_seen="$(age "$ts_seen")"; a_reflog="$(age "$ts_reflog")"
a_index="$(age "$ts_index")"; a_dirty="$(age "$ts_dirty")"

idle=yes
for a in "$a_seen" "$a_reflog" "$a_index" "$a_dirty"; do
    [ "$a" = none ] && continue
    [ "$a" -ge "$THRESHOLD" ] || idle=no
done

if [ "$JSON" -eq 1 ]; then
    j() { [ "$1" = none ] && echo null || echo "$1"; }
    printf '{"idle":%s,"threshold_days":%s,"repo":"%s","age_last_seen_s":%s,"age_reflog_s":%s,"age_index_s":%s,"age_dirty_s":%s}\n' \
        "$([ "$idle" = yes ] && echo true || echo false)" "$DAYS" \
        "$(printf '%s' "$TOP" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
        "$(j "$a_seen")" "$(j "$a_reflog")" "$(j "$a_index")" "$(j "$a_dirty")"
else
    printf 'idle=%s\nthreshold_days=%s\nage_last_seen_s=%s\nage_reflog_s=%s\nage_index_s=%s\nage_dirty_s=%s\n' \
        "$idle" "$DAYS" "$a_seen" "$a_reflog" "$a_index" "$a_dirty"
fi
[ "$idle" = yes ]
