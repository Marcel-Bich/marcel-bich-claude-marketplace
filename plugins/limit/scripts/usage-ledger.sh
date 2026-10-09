#!/usr/bin/env bash
# usage-ledger.sh - Single, deduplicated token ledger built from Claude Code JSONL.
#
# One counting scheme for main agent AND subagents:
#   - source: ~/.claude/projects/<project>/<session>.jsonl (main) and
#             ~/.claude/projects/<project>/<session>/subagents/agent-*.jsonl (subagents)
#   - Claude Code writes one JSONL line per content block (thinking, text,
#     tool_use, ...) and repeats the SAME message.usage on every one of them.
#     Lines are therefore deduplicated by message.id + requestId; the last line
#     of a message wins (its usage is final). Known limit: this is per file -
#     a message present in two transcripts (subagent sidechain + parent) is
#     counted in both (about 1 %). Duplicates are contiguous, so a
#     short per-file tail of recently counted keys makes the dedup survive an
#     incremental scan that splits one message across two reads.
#   - only native Anthropic models (model id starting with "claude") count.
#   - files are read incrementally from a stored byte offset; a trailing partial
#     line is left for the next scan. Reads are bounded (time + bytes per call)
#     and linear in the bytes read: grep prefilter, one streaming jq pass, one
#     awk pass for dedup and sums (no per-line processes, no growing arrays).
#
# Token vector everywhere: [input, output, cache_read, cache_write_5m, cache_write_1h]
# "work tokens" = input + output + cache writes. Cache reads are tracked
# separately - they are ~99 % of raw volume and must not be counted 1:1.
#
# Ledger state (schema 3, atomic writes under lock):
#   files    { path: {b: offset, ts: epoch, k: main|sub, s: session_id, sum: vec, tail: [[key, model, vec...]],
#                     p: 1 while a budgeted read stopped inside the file} }
#   lifetime { main|sub: { model_id: vec } }
#   buckets  { "<epoch, 5 min aligned>": vec }   (kept 8 days; window token sums)
# shellcheck disable=SC2250

CLAUDE_BASE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
PROFILE_NAME=$(basename "${CLAUDE_BASE_DIR}")
_LEDGER_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_LEDGER_DIR" == "${BASH_SOURCE[0]}" ]] && _LEDGER_DIR="."

# shellcheck source=state-io.sh
source "${_LEDGER_DIR}/state-io.sh"

LEDGER_SCHEMA_VERSION=3
LEDGER_FILE="${PLUGIN_DATA_DIR:-${CLAUDE_BASE_DIR}/marcel-bich-claude-marketplace/limit}/limit-ledger_${PROFILE_NAME}.json"
LEDGER_LOCK="${LEDGER_FILE}.lock"
LEDGER_TS_FILE="${LEDGER_FILE}.scan-ts"
CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-${CLAUDE_BASE_DIR}/projects}"

# Canonical path spelling, so one transcript can never be counted under two
# keys (e.g. CLAUDE_CONFIG_DIR with a trailing slash -> "//", "/./", or a
# symlinked directory). Sets _LEDGER_CANON: the physical directory (symlinks
# resolved once per directory and cached) plus the file name; a directory that
# cannot be resolved keeps its normalized spelling.
declare -gA _LEDGER_CANON_DIRS=()
_LEDGER_CANON=""
_ledger_canon() {
    local p="$1" d b c
    while [[ "$p" == *//* ]]; do p="${p//\/\//\/}"; done
    while [[ "$p" == */./* ]]; do p="${p//\/.\//\/}"; done
    [[ "$p" == ./* ]] && p="${PWD}/${p#./}"
    [[ "$p" == /* ]] || p="${PWD}/${p}"
    [[ "$p" == */ && "$p" != "/" ]] && p="${p%/}"
    d="${p%/*}"
    b="${p##*/}"
    [[ -n "$d" ]] || d="/"
    c="${_LEDGER_CANON_DIRS[$d]:-}"
    if [[ -z "$c" ]]; then
        c=$(cd -P -- "$d" 2>/dev/null && pwd -P) || c=""
        [[ -n "$c" ]] || c="$d"
        _LEDGER_CANON_DIRS["$d"]="$c"
    fi
    [[ "$c" == "/" ]] && c=""
    _LEDGER_CANON="${c}/${b}"
}
# Canonical directory (no trailing slash) into _LEDGER_CANON.
_ledger_canon_dir() {
    local d="$1"
    while [[ "$d" == */ && "$d" != "/" ]]; do d="${d%/}"; done
    _ledger_canon "${d}/x"
    _LEDGER_CANON="${_LEDGER_CANON%/x}"
}

# Global scan cadence (seconds) and per-scan budgets. Every scan stops at its
# time budget (seconds, millisecond resolution, checked before each batch or
# chunk except the first) and at its byte budget (bytes in total, 0 =
# unlimited). Files up to LEDGER_SMALL_FILE_BYTES are read in batches; larger
# ones in chunks of at most LEDGER_CHUNK_BYTES (a single longer line is read
# whole). Unfinished files keep their offset and a pending flag and are
# resumed by the next scan, so a first backfill never blocks a render.
LEDGER_SCAN_INTERVAL="${CLAUDE_MB_LIMIT_CACHE_AGE:-120}"
LEDGER_SCAN_BUDGET="${CLAUDE_MB_LIMIT_SCAN_BUDGET:-3}"
LEDGER_SCAN_MAX_BYTES="${LEDGER_SCAN_MAX_BYTES:-${CLAUDE_MB_LIMIT_SCAN_BYTES:-0}}"
LEDGER_CHUNK_BYTES="${LEDGER_CHUNK_BYTES:-8388608}"
LEDGER_SMALL_FILE_BYTES="${LEDGER_SMALL_FILE_BYTES:-1048576}"
# Inline (render-time) scan of the current transcript: bytes per render.
LEDGER_SESSION_SCAN_BYTES="${CLAUDE_MB_LIMIT_SESSION_SCAN_BYTES:-2097152}"
LEDGER_BUCKET=300
LEDGER_BUCKET_RETENTION=$((8 * 86400))
LEDGER_TAIL_KEYS=4

ledger_log() {
    limit_debug_enabled || return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ledger: $*" >> "/tmp/claude-mb-limit-debug_${PROFILE_NAME}.log" 2>/dev/null || true
}

# Pricing per MTok: [input, output, cache_read, cache_write_5m, cache_write_1h].
# Keyed by concrete model id (date suffix stripped). Cache writes: 5m = 1.25x
# input, 1h = 2x input. A model that is not listed is NOT priced (shown as n/a)
# instead of being guessed. Long-context or tiered surcharges are not modelled.
LEDGER_PRICES='{
  "claude-fable-5-1":  [10, 50, 0.25, 12.5, 20],
  "claude-mythos-5-1": [10, 50, 0.25, 12.5, 20],
  "claude-fable-5":    [10, 50, 1, 12.5, 20],
  "claude-mythos-5":   [10, 50, 1, 12.5, 20],
  "claude-opus-5-5":   [4, 20, 0.2, 5, 8],
  "claude-opus-5":     [5, 25, 0.5, 6.25, 10],
  "claude-opus-4-8":   [5, 25, 0.5, 6.25, 10],
  "claude-opus-4-7":   [5, 25, 0.5, 6.25, 10],
  "claude-opus-4-6":   [5, 25, 0.5, 6.25, 10],
  "claude-opus-4-5":   [5, 25, 0.5, 6.25, 10],
  "claude-opus-4-1":   [15, 75, 1.5, 18.75, 30],
  "claude-opus-4-0":   [15, 75, 1.5, 18.75, 30],
  "claude-sonnet-5-5": [2, 10, 0.2, 2.5, 4],
  "claude-sonnet-5":   [2, 10, 0.2, 2.5, 4],
  "claude-sonnet-4-6": [3, 15, 0.3, 3.75, 6],
  "claude-sonnet-4-5": [3, 15, 0.3, 3.75, 6],
  "claude-sonnet-4-0": [3, 15, 0.3, 3.75, 6],
  "claude-haiku-5-5":  [0.1, 0.5, 0.01, 0.125, 0.2],
  "claude-haiku-4-5":  [1, 5, 0.1, 1.25, 2]
}'

# jq helper definitions shared by all programs below.
_LEDGER_JQ_DEFS='
def vz: [0,0,0,0,0];
def vadd(a; b): [range(0;5) as $i | ((a // vz)[$i] // 0) + ((b // vz)[$i] // 0)];
def vsub(a; b): [range(0;5) as $i | ((a // vz)[$i] // 0) - ((b // vz)[$i] // 0)];
def work(v): (v[0] // 0) + (v[1] // 0) + (v[3] // 0) + (v[4] // 0);
def base_model: sub("\\[.*$"; "") | sub("-[0-9]{8}$"; "");
'

# Print the price vector "in out cr cw5 cw1" for a model id, or nothing.
ledger_price_for() {
    jq -rn --argjson p "$LEDGER_PRICES" --arg m "$1" "${_LEDGER_JQ_DEFS}"'
        ($m | base_model) as $b | ($p[$b] // empty) | map(tostring) | join(" ")'
}

_ledger_empty_state() {
    jq -cn --argjson v "$LEDGER_SCHEMA_VERSION" \
        '{schema_version: $v, last_scan: 0, files: {}, lifetime: {main: {}, sub: {}}, buckets: {}}'
}

_ledger_file_size() {
    stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo 0
}

# Milliseconds since the epoch (sub-second time budgets). EPOCHREALTIME is
# bash 5, date +%s%N is GNU; the last fallback has second resolution.
_ledger_now_ms() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local t="${EPOCHREALTIME/[.,]/}"
        echo "${t:0:${#t}-3}"
    else
        local n
        n=$(date +%s%N 2>/dev/null)
        if [[ "$n" =~ ^[0-9]{13,}$ ]]; then echo "${n:0:${#n}-6}"; else echo "$(($(date +%s) * 1000))"; fi
    fi
}

# Sizes of many files in one process. Reads NUL-separated paths on stdin,
# prints "<size>\t<path>" for every file that exists.
_ledger_sizes() {
    if stat -c %s / >/dev/null 2>&1; then
        xargs -0 stat -c $'%s\t%n' -- 2>/dev/null
    else
        xargs -0 stat -f $'%z\t%N' -- 2>/dev/null
    fi
    return 0
}

# Kind + session id of a JSONL path into _LK / _LS (no subshell: runs per file).
_ledger_classify_vars() {
    local path="$1"
    if [[ "$path" == */subagents/* ]]; then
        local sdir="${path%/subagents/*}"
        _LK=sub
        _LS="${sdir##*/}"
    else
        local b="${path##*/}"
        _LK=main
        _LS="${b%.jsonl}"
    fi
}

# Line extraction for a batch of jobs in one linear awk pass (LC_ALL=C, so
# length() counts bytes). Job file (TSV): fid input off rel_off lim path kind
# sid pending. For every input it keeps the complete lines that start at or
# after rel_off and end (newline included) at or before lim, prints the usage
# candidates as "fid<TAB>line" and writes "fid<TAB>consumed_bytes" to consfile.
# A trailing line without newline ends after lim and is never consumed.
_LEDGER_EXTRACT_AWK='
BEGIN {
    while ((getline l < jobs) > 0) {
        split(l, a, "\t"); jf[a[2]] = a[1]; jo[a[2]] = a[4] + 0; jl[a[2]] = a[5] + 0
    }
    close(jobs)
}
FNR == 1 { fid = jf[FILENAME]; o = jo[FILENAME]; lim = jl[FILENAME]; pos = 0 }
{
    s = pos; pos += length($0) + 1
    if (s >= o && pos <= lim) {
        cons[fid] = pos - o
        if (index($0, "\"usage\"") > 0) print fid "\t" $0
    }
}
END { for (f in cons) print f "\t" cons[f] > consfile; close(consfile) }'

# Row extraction: one jq pass over the usage candidates of a batch, one TSV row
# per line: fid, key, model, bucket, in, out, cache_read, cw5m, cw1h. Each line
# is parsed on its own (no slurp, no growing arrays), so the cost is linear.
# jq still validates every candidate, so a "usage" string inside other
# content cannot count. (The fid prefix is ASCII, so index() is safe on jq 1.6.)
_LEDGER_ROWS_JQ='
    def u: .message.usage;
    # Claude Code writes UTC timestamps "YYYY-MM-DDTHH:MM:SS.mmmZ"; slicing is
    # much cheaper than a regex per line on jq 1.6. Unparsable -> now.
    def bucket: (if (.timestamp | type) == "string" and (.timestamp | length) >= 19
                 then ((.timestamp[0:19] + "Z") | fromdateiso8601?) else null end) as $t
                | (($t // $now) / $bsize | floor) * $bsize | tostring;
    index("\t") as $i
    | .[0:$i] as $fid
    | .[$i + 1:] | fromjson?
    | select(type == "object" and (.message | type) == "object"
        and (.message.usage | type) == "object"
        and (.message.model | type) == "string"
        and (.message.model | startswith("claude")))
    | [ $fid,
        (if ((.message.id // "") | tostring) != "" then "\(.message.id)|\(.requestId // "")" else "" end),
        .message.model, bucket,
        (u.input_tokens // 0), (u.output_tokens // 0), (u.cache_read_input_tokens // 0),
        (if (u.cache_creation | type) == "object"
             then (u.cache_creation.ephemeral_5m_input_tokens // 0)
             else (u.cache_creation_input_tokens // 0) end),
        (if (u.cache_creation | type) == "object"
             then (u.cache_creation.ephemeral_1h_input_tokens // 0) else 0 end) ]
    | map(tostring) | @tsv'

# Deduplication + delta aggregation per job in one linear awk pass (hash maps).
# Inputs: tailfile ("fid<TAB>key<TAB>model<TAB>v1..v5", previous tails),
# consfile (fids that consumed bytes) and the rows. A message key seen again
# keeps its last values (last line wins); keys from the previous tail are
# counted as a delta against their already counted values. Writes the new
# tails to newtail and prints one {fid, models, buckets, sum, tail} per job.
_LEDGER_AGG_AWK='
function js(s) { gsub(/"/, "\\\"", s); return "\"" s "\"" }
function num(x) { return sprintf("%.0f", x) }
# No "var (" concatenations below: busybox awk parses them as function calls.
function vec(arr, f, key,    i, r, sep) {
    r = "["; sep = ""
    for (i = 1; i <= 5; i++) { r = r sep num(arr[f, key, i]); sep = "," }
    return r "]"
}
FILENAME == tailfile {
    if ($0 == "") next
    f = $1; k = $2
    pk[f, ++np[f]] = k; inprev[f, k] = 1; pm_[f, k] = $3
    for (i = 1; i <= 5; i++) pv[f, k, i] = $(3 + i)
    next
}
FILENAME == consfile { if ($0 != "") fl[++nf] = $1; next }
{
    f = $1; k = $2
    if (k == "") k = "#" FNR
    if (!((f, k) in seen)) { seen[f, k] = 1; ord[f, ++n[f]] = k }
    m[f, k] = $3; b[f, k] = $4
    for (i = 1; i <= 5; i++) v[f, k, i] = $(4 + i)
    if (!(f in la) || $4 + 0 > la[f]) la[f] = $4 + 0
}
END {
    for (x = 1; x <= nf; x++) {
        f = fl[x]; nm = 0; nb = 0
        for (j = 1; j <= n[f]; j++) {
            k = ord[f, j]; mk = m[f, k]; bk = b[f, k]
            if (!((f, mk) in mi)) { mi[f, mk] = 1; ml[++nm] = mk }
            if (!((f, bk) in bi)) { bi[f, bk] = 1; bl[++nb] = bk }
            for (i = 1; i <= 5; i++) {
                d = v[f, k, i] - (((f, k) in inprev) ? pv[f, k, i] : 0)
                dm[f, mk, i] += d; db[f, bk, i] += d; ds[f, i] += d
            }
        }
        # New tail: previous keys not seen in this chunk, then this chunk in order.
        nt = 0
        for (j = 1; j <= np[f]; j++) { k = pk[f, j]; if (!((f, k) in seen)) { tk[++nt] = k; tsrc[nt] = "p" } }
        for (j = 1; j <= n[f]; j++) { k = ord[f, j]; if (substr(k, 1, 1) != "#") { tk[++nt] = k; tsrc[nt] = "c" } }
        first = (nt > keep) ? nt - keep + 1 : 1
        tj = ""; tsep = ""
        for (j = first; j <= nt; j++) {
            k = tk[j]
            if (tsrc[j] == "p") { mm = pm_[f, k]; for (i = 1; i <= 5; i++) tv[i] = pv[f, k, i] }
            else { mm = m[f, k]; for (i = 1; i <= 5; i++) tv[i] = v[f, k, i] }
            line = f "\t" k "\t" mm; row = js(k) "," js(mm)
            for (i = 1; i <= 5; i++) { line = line "\t" num(tv[i]); row = row "," num(tv[i]) }
            print line > newtail
            tj = tj tsep "[" row "]"; tsep = ","
        }
        out = "{\"fid\":" js(f) ",\"la\":" num((f in la) ? la[f] : 0) ",\"models\":{"; sep = ""
        for (j = 1; j <= nm; j++) { out = out sep js(ml[j]) ":" vec(dm, f, ml[j]); sep = "," }
        out = out "},\"buckets\":{"; sep = ""
        for (j = 1; j <= nb; j++) { out = out sep js(bl[j]) ":" vec(db, f, bl[j]); sep = "," }
        out = out "},\"sum\":["; sep = ""
        for (i = 1; i <= 5; i++) { out = out sep num(ds[f, i]); sep = "," }
        print out "],\"tail\":[" tj "]}"
    }
    close(newtail)
}'

# Run one batch of jobs ($1, TSV, see _LEDGER_EXTRACT_AWK) with their previous
# tails ($2). Prints one result object per job that consumed bytes; writes
# "fid<TAB>consumed" to $3 and the new tails to $4. Linear in the bytes read;
# a fixed number of processes per batch, not per file.
_ledger_run_batch() {
    local jobs="$1" tails_in="$2" consfile="$3" newtail="$4"
    local rows inputs=()
    : > "$consfile"
    : > "$newtail"
    rows=$(mktemp "${TMPDIR:-/tmp}/claude-mb-limit-rows.XXXXXX") || return 0
    local fid input rest
    while IFS=$'\t' read -r fid input rest; do
        [[ -n "$input" ]] && inputs+=("$input")
    done < "$jobs"
    [[ "${#inputs[@]}" -gt 0 ]] || { rm -f "$rows"; return 0; }
    LC_ALL=C awk -v jobs="$jobs" -v consfile="$consfile" "$_LEDGER_EXTRACT_AWK" "${inputs[@]}" 2>/dev/null \
        | jq -R -r --argjson now "$(date +%s)" --argjson bsize "$LEDGER_BUCKET" "$_LEDGER_ROWS_JQ" 2>/dev/null \
        > "$rows" || true
    [[ -s "$consfile" ]] || { rm -f "$rows"; return 0; }
    LC_ALL=C awk -F'\t' -v tailfile="$tails_in" -v consfile="$consfile" -v newtail="$newtail" \
        -v keep="$LEDGER_TAIL_KEYS" "$_LEDGER_AGG_AWK" "$tails_in" "$consfile" "$rows" 2>/dev/null \
        | jq -n -c --rawfile jobs "$jobs" --rawfile cons "$consfile" --argjson now "$(date +%s)" '
            ($jobs | split("\n") | map(select(. != "") | split("\t")
                | {key: .[0], value: {path: .[5], off: (.[2] | tonumber), kind: .[6], sid: .[7],
                                      pending: (.[8] | tonumber)}}) | from_entries) as $J
            | ($cons | split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: (.[1] | tonumber)})
                | from_entries) as $C
            | inputs | . as $a | $J[$a.fid] as $j
            | {path: $j.path, kind: $j.kind, sid: $j.sid, bytes: ($j.off + $C[$a.fid]), ts: $now,
               pending: $j.pending, tail: $a.tail, la: ($a.la // 0),
               d: {models: $a.models, buckets: $a.buckets, sum: $a.sum}}' 2>/dev/null || true
    rm -f "$rows"
}

# Merge per-file results (JSONL in $1) into the state (file $2); print new state.
# A file whose result is pending (read stopped at a budget) keeps p: 1 so the
# next global scan resumes it even when it is not newer than last_scan.
# $5: TSV "path kind sid" of files with unread data left when a run stopped
#     early - marked pending (created when new), so the ledger reads incomplete.
# $6: paths that vanished - their pending flag is dropped.
# $7: when non-empty, the complete list of existing transcripts; entries under
#     CLAUDE_PROJECTS_DIR that are not in it are pruned (lifetime and buckets stay).
_ledger_merge() {
    local results="$1" state_file="$2" complete="$3" scan_start="$4"
    local pendfile="$5" vanishfile="$6" existfile="${7:-}"
    local now cutoff prune=0
    now=$(date +%s)
    cutoff=$((now - LEDGER_BUCKET_RETENTION))
    [[ -n "$existfile" ]] && prune=1
    jq -c --slurpfile r "$results" --argjson cutoff "$cutoff" --argjson now "$now" \
        --arg complete "$complete" --argjson scan_start "$scan_start" \
        --rawfile pend "$pendfile" --rawfile vanish "$vanishfile" \
        --rawfile exist "${existfile:-/dev/null}" --argjson prune "$prune" \
        --arg root "${CLAUDE_PROJECTS_DIR%/}/" "${_LEDGER_JQ_DEFS}"'
        reduce $r[] as $f (.;
            .files[$f.path] = ({b: $f.bytes, ts: $f.ts, k: $f.kind, s: $f.sid, tail: $f.tail,
                               la: ([.files[$f.path].la // 0, $f.la // 0] | max),
                               sum: vadd(.files[$f.path].sum; $f.d.sum)}
                              + (if ($f.pending // 0) == 1 then {p: 1} else {} end))
            | reduce ($f.d.models | to_entries[]) as $m (.;
                .lifetime[$f.kind][$m.key] = vadd(.lifetime[$f.kind][$m.key]; $m.value))
            | reduce ($f.d.buckets | to_entries[]) as $bk (.;
                .buckets[$bk.key] = vadd(.buckets[$bk.key]; $bk.value)))
        | reduce ($pend | split("\n")[] | select(. != "") | split("\t")) as $p (.;
            .files[$p[0]] = ((.files[$p[0]] // {b: 0, ts: $now, k: $p[1], s: $p[2], sum: vz}) + {p: 1}))
        | reduce ($vanish | split("\n")[] | select(. != "")) as $v (.;
            if .files[$v] then .files[$v] |= del(.p) else . end)
        | if $prune == 1 then
            # Never prune what this run read or marked pending: a transcript
            # created while the lists were built would otherwise be dropped
            # and recounted from offset 0 by the next scan.
            (($exist | split("\n") | map(select(. != "")))
             + [$r[].path]
             + ($pend | split("\n") | map(select(. != "") | split("\t")[0]))
             | map({key: ., value: 1}) | from_entries) as $E
            | .files |= with_entries(select((.key | startswith($root) | not) or $E[.key] != null))
          else . end
        | .buckets |= with_entries(select((.key | tonumber) >= $cutoff))
        # Tails only matter while a transcript is still being written: keep
        # them by last message activity, not scan time (a backfill of old
        # transcripts must not give every file a tail). A pending file keeps
        # it: its next chunk may continue a message split at the boundary.
        | .files |= with_entries(if (.value.la // 0) < ($now - 172800) and (.value.p // 0) != 1
                                 then .value |= del(.tail) else . end)
        | if $complete == "1" then .last_scan = $scan_start else . end
    ' "$state_file"
}

# Locked worker: process the given files, merge, write atomically.
# Arg 1: "1" when this is a complete global scan (advances last_scan only if
# nothing was left over). Arg 3 (global scans): file listing all existing
# transcripts, used to prune entries of deleted ones (empty = no pruning).
# Limits per call: LEDGER_SCAN_BUDGET seconds (sub-second resolution, checked
# before every batch/chunk except the first, so each call makes progress) and
# LEDGER_SCAN_MAX_BYTES bytes in total (0 = unlimited). Small files (up to
# LEDGER_SMALL_FILE_BYTES) are read in batches with a fixed number of processes
# per batch; larger ones in chunks of at most LEDGER_CHUNK_BYTES. Whatever is
# left over is marked pending and resumed by the next call.
_ledger_scan_locked() {
    local complete="$1" scan_start="$2" existfile="${3:-}"
    shift 3
    local work
    work=$(mktemp -d "${TMPDIR:-/tmp}/claude-mb-limit-scan.XXXXXX") || return 1
    local state_file="$work/state" results="$work/results" pendfile="$work/pend" vanishfile="$work/vanish"
    local jobs="$work/jobs" tails_in="$work/tails" consfile="$work/cons" newtail="$work/newtail" chunk="$work/chunk"
    # State as a file copy plus ONE schema check (no bash string of the whole
    # ledger: it can be ~1 MB with thousands of transcripts). Writers hold the
    # same lock, so the copy is consistent.
    if [[ ! -e "$LEDGER_FILE" ]]; then
        _ledger_empty_state > "$state_file"
    elif ! cp "$LEDGER_FILE" "$state_file" 2>/dev/null \
        || ! jq -e --argjson v "$LEDGER_SCHEMA_VERSION" 'type == "object" and .schema_version == $v' \
            "$state_file" >/dev/null 2>&1; then
        # Corrupt/old-schema ledger: start over (lifetime is rebuilt from JSONL).
        ledger_log "ledger unreadable or old schema - rebuilding"
        _ledger_empty_state > "$state_file"
        complete="0"
        rm -f "$LEDGER_TS_FILE" 2>/dev/null || true
    fi
    : > "$results"; : > "$pendfile"; : > "$vanishfile"

    # Known offsets and tails in one pass each (a jq call per file would
    # dominate a scan over many files).
    local -A known=() tails=() sizes=()
    local kp kb
    # Only the entries of the passed paths: a render-time scan of one file
    # must not walk thousands of ledger entries in bash.
    local wantfile="$work/want"
    printf '%s\n' "$@" > "$wantfile"
    local -A knownp=() pend_now=()
    # One jq pass: "K path offset pending" and "T path tail-row" lines.
    local kpend ktag
    while IFS=$'\t' read -r ktag kp kb kpend; do
        [[ -n "$kp" ]] || continue
        if [[ "$ktag" == "K" ]]; then
            known["$kp"]="$kb"
            [[ "$kpend" == "1" ]] && knownp["$kp"]=1
        else
            tails["$kp"]+="${kb}${kpend:+$'\t'$kpend}"$'\n'
        fi
    done < <(jq -r --rawfile want "$wantfile" '
        ($want | split("\n") | map(select(. != "") | {key: ., value: 1}) | from_entries) as $W
        | .files | to_entries[] | select($W[.key] != null)
        | "K\t\(.key)\t\(.value.b // 0)\t\(.value.p // 0)",
          (.key as $p | (.value.tail // [])[] | "T\t\($p)\t\(map(tostring) | @tsv)")' "$state_file" 2>/dev/null)
    while IFS=$'\t' read -r kb kp; do
        [[ -n "$kp" ]] && sizes["$kp"]="$kb"
    done < <(printf '%s\0' "$@" | _ledger_sizes)

    local max_bytes="${LEDGER_SCAN_MAX_BYTES:-0}" chunk_bytes="${LEDGER_CHUNK_BYTES:-8388608}"
    local small_bytes="${LEDGER_SMALL_FILE_BYTES:-1048576}"
    [[ "$max_bytes" =~ ^[0-9]+$ ]] || max_bytes=0
    [[ "$chunk_bytes" =~ ^[0-9]+$ ]] && [[ "$chunk_bytes" -gt 0 ]] || chunk_bytes=8388608
    [[ "$small_bytes" =~ ^[0-9]+$ ]] || small_bytes=1048576
    local budget_ms
    budget_ms=$(awk -v b="${LEDGER_SCAN_BUDGET:-3}" 'BEGIN { printf "%d", b * 1000 }' 2>/dev/null) || budget_ms=3000
    local start_ms
    start_ms=$(_ledger_now_ms)

    local used=0 units=0 stopped=0 f size off allowed left
    local -a order=() batch=()
    local -A seen_f=() off_of=() size_of=()
    local batch_bytes=0

    # Drop a pending flag (only when one is set, so an unchanged file never
    # causes a ledger write).
    _scan_unpend() {
        if [[ -n "${knownp[$1]:-}" || -n "${pend_now[$1]:-}" ]]; then
            printf '%s\n' "$1" >> "$vanishfile"
            unset 'knownp[$1]' 'pend_now[$1]'
        fi
    }
    # Per-call budget check before each unit of work; the first unit always runs.
    _scan_over_budget() {
        [[ "$units" -gt 0 ]] || return 1
        [[ $(($(_ledger_now_ms) - start_ms)) -ge "$budget_ms" ]]
    }
    # Apply a batch run: advance offsets, keep the new tails.
    _scan_apply() {
        local cf cn p
        while IFS=$'\t' read -r cf cn; do
            [[ -n "$cf" ]] || continue
            p="${order[$cf]}"
            off_of["$p"]=$((off_of[$p] + cn))
            used=$((used + cn))
            tails["$p"]=""
        done < "$consfile"
        local tf trow
        while IFS=$'\t' read -r tf trow; do
            [[ -n "$tf" ]] && tails["${order[$tf]}"]+="${trow}"$'\n'
        done < "$newtail"
    }
    _scan_tails_for() { # fid path -> prefixed tail lines
        local line
        while IFS= read -r line; do
            [[ -n "$line" ]] && printf '%s\t%s\n' "$1" "$line"
        done <<< "${tails[$2]:-}"
    }
    _scan_flush() {
        [[ "${#batch[@]}" -gt 0 ]] || return 0
        : > "$jobs"; : > "$tails_in"
        local p fid
        for p in "${batch[@]}"; do
            fid="${#order[@]}"
            order+=("$p")
            _ledger_classify_vars "$p"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t0\n' "$fid" "$p" "${off_of[$p]}" "${off_of[$p]}" \
                "${size_of[$p]}" "$p" "$_LK" "$_LS" >> "$jobs"
            _scan_tails_for "$fid" "$p" >> "$tails_in"
        done
        local -A before_off=()
        for p in "${batch[@]}"; do before_off["$p"]="${off_of[$p]}"; done
        _ledger_run_batch "$jobs" "$tails_in" "$consfile" "$newtail" >> "$results"
        _scan_apply
        # Nothing complete left (only a partial trailing line): a pending flag
        # from an earlier budgeted read must not stay forever.
        for p in "${batch[@]}"; do
            [[ "${off_of[$p]}" -eq "${before_off[$p]}" ]] && _scan_unpend "$p"
        done
        batch=()
        batch_bytes=0
        units=$((units + 1))
    }
    # One chunk of a large file. Returns 1 when the budget stops the run.
    _scan_chunk() {
        local p="$1" want remaining overrun capped=0 fid
        remaining=$((size_of[$p] - off_of[$p]))
        allowed="$chunk_bytes"
        local budget_limited=0
        if [[ "$max_bytes" -gt 0 ]]; then
            left=$((max_bytes - used))
            [[ "$left" -le 0 ]] && return 1
            if [[ "$left" -lt "$allowed" ]]; then allowed="$left"; budget_limited=1; fi
        fi
        want="$remaining"
        if [[ "$remaining" -gt "$allowed" ]]; then want="$allowed"; capped=1; fi
        # A single line longer than the chunk is always allowed through when
        # only the chunk size limits; against a byte budget only as the first
        # unit of a call (bounded, but every call makes progress).
        overrun=1
        [[ "$budget_limited" -eq 1 && "$used" -gt 0 ]] && overrun=0
        tail -c +$((off_of[$p] + 1)) "$p" 2>/dev/null | head -c "$want" > "$chunk"
        if [[ "$capped" -eq 1 && "$overrun" -eq 1 ]] && [[ "$(LC_ALL=C tr -cd '\n' < "$chunk" | wc -c | tr -d ' ')" -eq 0 ]]; then
            # No complete line in the chunk: take exactly the first line.
            local first_len
            first_len=$(tail -c +$((off_of[$p] + 1)) "$p" 2>/dev/null | head -c "$remaining" | head -n 1 | wc -c | tr -d ' ')
            if [[ "$first_len" -gt 0 ]]; then
                tail -c +$((off_of[$p] + 1)) "$p" 2>/dev/null | head -c "$first_len" > "$chunk"
                want="$first_len"
                [[ "$first_len" -lt "$remaining" ]] || capped=0
            fi
        fi
        fid="${#order[@]}"
        order+=("$p")
        _ledger_classify_vars "$p"
        printf '%s\t%s\t%s\t0\t%s\t%s\t%s\t%s\t%s\n' "$fid" "$chunk" "${off_of[$p]}" "$want" \
            "$p" "$_LK" "$_LS" "$capped" > "$jobs"
        _scan_tails_for "$fid" "$p" > "$tails_in"
        local before="${off_of[$p]}"
        _ledger_run_batch "$jobs" "$tails_in" "$consfile" "$newtail" >> "$results"
        _scan_apply
        units=$((units + 1))
        if [[ "${off_of[$p]}" -le "$before" ]]; then
            # No progress: budget-limited (next line does not fit) -> stop the
            # run; otherwise only a partial trailing line is left.
            [[ "$capped" -eq 1 ]] && return 1
            # A partial trailing line must not keep an earlier pending flag.
            _scan_unpend "$p"
            return 2
        fi
        [[ "$capped" -eq 1 ]] && pend_now["$p"]=1
        return 0
    }

    for f in "$@"; do
        [[ -n "$f" ]] || continue
        [[ -n "${seen_f[$f]:-}" ]] && continue
        seen_f["$f"]=1
        size="${sizes[$f]:-}"
        if [[ -z "$size" || ! -r "$f" ]]; then
            # Gone (or unreadable): drop a pending flag so it cannot keep the
            # ledger incomplete forever. Counted parts stay.
            _scan_unpend "$f"
            continue
        fi
        off="${known[$f]:-0}"
        [[ "$size" -eq "$off" ]] && continue
        # File shrank (rewritten): restart from 0, previous counts stay.
        if [[ "$size" -lt "$off" ]]; then
            off=0
            tails["$f"]=""
        fi
        off_of["$f"]="$off"
        size_of["$f"]="$size"
        if [[ "$stopped" -eq 1 ]]; then
            _ledger_classify_vars "$f"
            printf '%s\t%s\t%s\n' "$f" "$_LK" "$_LS" >> "$pendfile"
            continue
        fi
        local rem=$((size - off))
        if [[ "$size" -le "$small_bytes" ]] && { [[ "$max_bytes" -eq 0 ]] || [[ $((used + batch_bytes + rem)) -le "$max_bytes" ]]; }; then
            batch+=("$f")
            batch_bytes=$((batch_bytes + rem))
            if [[ "${#batch[@]}" -ge 400 ]] || [[ "$batch_bytes" -ge "$chunk_bytes" ]]; then
                if _scan_over_budget; then
                    stopped=1
                    local q
                    for q in "${batch[@]}"; do
                        _ledger_classify_vars "$q"
                        printf '%s\t%s\t%s\n' "$q" "$_LK" "$_LS" >> "$pendfile"
                    done
                    batch=()
                    continue
                fi
                _scan_flush
            fi
            continue
        fi
        # Large file (or one that does not fit the byte budget): flush the
        # small ones first, then read it in chunks.
        if [[ "${#batch[@]}" -gt 0 ]]; then
            if _scan_over_budget; then
                stopped=1
            else
                _scan_flush
            fi
        fi
        while [[ "$stopped" -eq 0 ]] && [[ "${off_of[$f]}" -lt "$size" ]]; do
            if _scan_over_budget; then stopped=1; break; fi
            local rc=0
            _scan_chunk "$f" || rc=$?
            [[ "$rc" -eq 1 ]] && { stopped=1; break; }
            [[ "$rc" -eq 2 ]] && break
        done
        if [[ "$stopped" -eq 1 ]]; then
            local q
            for q in "${batch[@]}" "$f"; do
                [[ "${off_of[$q]}" -lt "${size_of[$q]}" ]] || continue
                _ledger_classify_vars "$q"
                printf '%s\t%s\t%s\n' "$q" "$_LK" "$_LS" >> "$pendfile"
            done
            batch=()
        fi
    done
    if [[ "${#batch[@]}" -gt 0 ]]; then
        if _scan_over_budget; then
            stopped=1
            local q
            for q in "${batch[@]}"; do
                _ledger_classify_vars "$q"
                printf '%s\t%s\t%s\n' "$q" "$_LK" "$_LS" >> "$pendfile"
            done
        else
            _scan_flush
        fi
    fi
    [[ "$stopped" -eq 1 ]] && complete="0"

    local rc=0
    if [[ "$complete" != "1" && ! -s "$results" && ! -s "$pendfile" && ! -s "$vanishfile" ]]; then
        # Nothing changed: leave the ledger (and its mtime) alone.
        rm -rf "$work"
        return 0
    fi
    # jq output is valid JSON by construction: skip the second validation parse.
    _ledger_merge "$results" "$state_file" "$complete" "$scan_start" "$pendfile" "$vanishfile" "$existfile" \
        | LIMIT_ATOMIC_RAW=1 limit_atomic_write "$LEDGER_FILE" || rc=1
    rm -rf "$work"
    return "$rc"
}

# Process specific files now (e.g. the current session transcript).
ledger_scan_files() {
    local -a canon=()
    local a
    for a in "$@"; do
        [[ -n "$a" ]] || continue
        _ledger_canon "$a"
        canon+=("$_LEDGER_CANON")
    done
    limit_with_lock "$LEDGER_LOCK" _ledger_scan_locked 0 0 "" "${canon[@]}"
}

_ledger_set_ts_file() {
    local epoch="$1"
    if [[ "$epoch" -le 0 ]]; then
        touch -t 197001010000 "$LEDGER_TS_FILE" 2>/dev/null || true
    elif date --version >/dev/null 2>&1; then
        touch -d "@${epoch}" "$LEDGER_TS_FILE" 2>/dev/null || true
    else
        touch -t "$(date -r "$epoch" "+%Y%m%d%H%M.%S")" "$LEDGER_TS_FILE" 2>/dev/null || true
    fi
}

# All transcripts (main + subagents) below the projects dir, one per line.
_ledger_list_transcripts() {
    find "$CLAUDE_PROJECTS_DIR" -maxdepth 2 -name '*.jsonl' -type f "$@" 2>/dev/null
    find "$CLAUDE_PROJECTS_DIR" -mindepth 4 -maxdepth 4 -path '*/subagents/*' -name 'agent-*.jsonl' -type f "$@" 2>/dev/null
}

_ledger_scan_all_locked() {
    local last_scan
    last_scan=$(jq -r '.last_scan // 0' "$LEDGER_FILE" 2>/dev/null) || last_scan=0
    [[ "$last_scan" =~ ^[0-9]+$ ]] || last_scan=0
    local scan_start
    scan_start=$(date +%s)
    _ledger_set_ts_file "$last_scan"
    # Canonical root: find then prints canonical paths, the same spelling the
    # render-time scan uses.
    _ledger_canon_dir "$CLAUDE_PROJECTS_DIR"
    local CLAUDE_PROJECTS_DIR="$_LEDGER_CANON"
    local existfile
    existfile=$(mktemp "${TMPDIR:-/tmp}/claude-mb-limit-exist.XXXXXX") || return 1
    local -a files=()
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] && files+=("$f")
    done < <(
        # Pending files first: a budgeted earlier read stopped inside them, and
        # they are not necessarily newer than last_scan.
        jq -r '.files | to_entries[] | select(.value.p == 1) | .key' "$LEDGER_FILE" 2>/dev/null
        _ledger_list_transcripts -newer "$LEDGER_TS_FILE"
    )
    # Existence list AFTER the scan list: a file created in between is in
    # both. The merge also never prunes what this run read or marked pending.
    _ledger_list_transcripts > "$existfile"
    local rc=0
    if [[ -s "$existfile" ]]; then
        _ledger_scan_locked 1 "$scan_start" "$existfile" "${files[@]}" || rc=$?
    else
        _ledger_scan_locked 1 "$scan_start" "" "${files[@]}" || rc=$?
    fi
    rm -f "$existfile"
    return "$rc"
}

# Global incremental scan of all projects, at most every LEDGER_SCAN_INTERVAL
# seconds (LEDGER_FORCE_SCAN=1 bypasses the cadence). Non-blocking: if another
# render holds the lock, this one skips.
ledger_scan_all() {
    [[ -d "$CLAUDE_PROJECTS_DIR" ]] || return 0
    if [[ "${LEDGER_FORCE_SCAN:-0}" != "1" ]] && [[ -f "$LEDGER_FILE" ]]; then
        local last now
        last=$(jq -r '.last_scan // 0' "$LEDGER_FILE" 2>/dev/null) || last=0
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        now=$(date +%s)
        [[ $((now - last)) -lt "$LEDGER_SCAN_INTERVAL" ]] && return 0
    fi
    LIMIT_LOCK_WAIT=0 limit_with_lock "$LEDGER_LOCK" _ledger_scan_all_locked
}

# Render-time refresh: the current transcript (at most every 10 s, bounded to
# LEDGER_SESSION_SCAN_BYTES per render) and the global scan (cadence-gated,
# detached). A large transcript right after an upgrade is therefore read over
# several renders instead of blocking one; the global scan finishes it too.
ledger_refresh() {
    local transcript="${1:-}"
    if [[ -n "$transcript" ]] && [[ -f "$transcript" ]]; then
        _ledger_canon "$transcript"
        transcript="$_LEDGER_CANON"
        # Gate per transcript (its own last scan time and offset), so parallel
        # sessions never starve each other through the shared ledger's mtime,
        # and nothing is locked or written while the transcript did not grow.
        local size ts=0 b=-1 now
        size=$(_ledger_file_size "$transcript")
        if [[ -f "$LEDGER_FILE" ]]; then
            read -r ts b <<< "$(jq -r --arg p "$transcript" '.files[$p] | "\(.ts // 0) \(.b // -1)"' "$LEDGER_FILE" 2>/dev/null || echo "0 -1")"
            [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
        fi
        now=$(date +%s)
        if [[ "$b" != "$size" ]] && [[ $((now - ts)) -ge "${CLAUDE_MB_LIMIT_SESSION_SCAN:-10}" ]]; then
            LIMIT_LOCK_WAIT=0 LEDGER_SCAN_MAX_BYTES="$LEDGER_SESSION_SCAN_BYTES" \
                LEDGER_SCAN_BUDGET=1 ledger_scan_files "$transcript" || true
        fi
    fi
    ledger_scan_all_detached || true
}

# Global scan without blocking the render: when due, start it detached (it
# survives the statusline being cancelled) with a larger time budget. A first
# run after install/upgrade backfills all transcripts over a few of these runs.
# CLAUDE_MB_LIMIT_SCAN_SYNC=1 runs it inline (tests).
ledger_scan_all_detached() {
    [[ -d "$CLAUDE_PROJECTS_DIR" ]] || return 0
    if [[ "${CLAUDE_MB_LIMIT_SCAN_SYNC:-0}" == "1" ]]; then
        ledger_scan_all
        return
    fi
    local now last=0
    now=$(date +%s)
    if [[ -f "$LEDGER_FILE" ]]; then
        last=$(jq -r '.last_scan // 0' "$LEDGER_FILE" 2>/dev/null) || last=0
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
    fi
    [[ $((now - last)) -lt "$LEDGER_SCAN_INTERVAL" ]] && return 0
    # One detached scan at a time: skip while a recent start marker exists.
    local marker="${LEDGER_FILE}.scan-started"
    if [[ -f "$marker" ]]; then
        local mt
        mt=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null || echo 0)
        [[ $((now - mt)) -lt 30 ]] && return 0
    fi
    touch "$marker" 2>/dev/null || true
    local self="${_LEDGER_DIR}/usage-ledger.sh"
    local data_dir
    data_dir=$(dirname "$LEDGER_FILE")
    if command -v setsid >/dev/null 2>&1; then
        PLUGIN_DATA_DIR="$data_dir" CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" \
            CLAUDE_MB_LIMIT_SCAN_BUDGET="${CLAUDE_MB_LIMIT_BG_SCAN_BUDGET:-25}" \
            setsid bash "$self" scan >/dev/null 2>&1 < /dev/null &
    else
        ( PLUGIN_DATA_DIR="$data_dir" CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" \
            CLAUDE_MB_LIMIT_SCAN_BUDGET="${CLAUDE_MB_LIMIT_BG_SCAN_BUDGET:-25}" \
            bash "$self" scan >/dev/null 2>&1 < /dev/null ) &
    fi
    disown 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# Readers. Each returns 1 when the ledger is unreadable (never a silent 0).
# ---------------------------------------------------------------------------

# One-shot summary for the statusline (single jq parse).
# Args: session_id start_5h start_7d. Prints JSON:
# {complete, session: vec, w5: [work, cache_read], w7: [...], lifetime: {tokens, cost, unpriced, cache_read}}
# complete is false until a global scan has finished once and while any file is
# pending - window sums are too low then (backfill still running).
ledger_summary() {
    local sid="${1:-}" s5="${2:-0}" s7="${3:-0}"
    [[ "$s5" =~ ^-?[0-9]+$ ]] || s5=0
    [[ "$s7" =~ ^-?[0-9]+$ ]] || s7=0
    # One jq call straight on the file (render path): schema check + summary.
    # Missing file -> empty state; empty, corrupt or wrong schema -> exit 1.
    local input="$LEDGER_FILE" out
    if [[ ! -e "$LEDGER_FILE" ]]; then
        input=$(mktemp "${TMPDIR:-/tmp}/claude-mb-limit-ledger-empty.XXXXXX") || return 1
        _ledger_empty_state > "$input"
    fi
    out=$(jq -c --arg sid "$sid" --argjson s5 "$s5" --argjson s7 "$s7" \
        --argjson v "$LEDGER_SCHEMA_VERSION" \
        --argjson p "$LEDGER_PRICES" --argjson bsize "$LEDGER_BUCKET" "${_LEDGER_JQ_DEFS}"'
        if type == "object" and .schema_version == $v then . else error("ledger unreadable") end
        | def win($s): (($s / $bsize | floor) * $bsize) as $from
            | [.buckets | to_entries[] | select((.key | tonumber) >= $from) | .value]
            | reduce .[] as $v (vz; vadd(.; $v)) | [work(.), .[2]];
        def cost(m; v): ($p[m | base_model]) as $pr
            | if $pr == null then null
              else ([range(0;5) as $i | (v[$i] // 0) * $pr[$i]] | add) / 1000000 end;
        ([.lifetime.main, .lifetime.sub] | map(to_entries[]) ) as $models
        | {
            complete: ((.last_scan // 0) > 0 and ([.files[] | select(.p == 1)] | length) == 0),
            session: ([.files[] | select(.s == $sid) | .sum] | reduce .[] as $v (vz; vadd(.; $v))),
            w5: win($s5),
            w7: win($s7),
            lifetime: {
                tokens: ($models | map(work(.value)) | add // 0),
                cache_read: ($models | map(.value[2] // 0) | add // 0),
                cost: ($models | map(cost(.key; .value) // 0) | add // 0),
                unpriced: ($models | map(select(cost(.key; .value) == null)) | length),
                main_tokens: ([.lifetime.main | to_entries[] | work(.value)] | add // 0),
                sub_tokens: ([.lifetime.sub | to_entries[] | work(.value)] | add // 0),
                main_cost: ([.lifetime.main | to_entries[] | cost(.key; .value) // 0] | add // 0),
                sub_cost: ([.lifetime.sub | to_entries[] | cost(.key; .value) // 0] | add // 0)
            }
          }' "$input" 2>/dev/null) || out=""
    [[ "$input" == "$LEDGER_FILE" ]] || rm -f "$input"
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

# Prints "input output cache_read cache_write" for a session (main + subagents).
ledger_session_totals() {
    local sum
    sum=$(ledger_summary "$1" 0 0) || return 1
    printf '%s' "$sum" | jq -r '.session | "\(.[0]) \(.[1]) \(.[2]) \(.[3] + .[4])"'
}

# Prints "work_tokens cache_read" since <start_epoch>.
ledger_window_tokens() {
    local sum
    sum=$(ledger_summary "" "$1" "$1") || return 1
    printf '%s' "$sum" | jq -r '.w5 | "\(.[0]) \(.[1])"'
}

# Prints "work_tokens cost(6 decimals) unpriced_model_count".
ledger_lifetime() {
    local sum
    sum=$(ledger_summary "" 0 0) || return 1
    printf '%s' "$sum" | jq -r '.lifetime | "\(.tokens) \(.cost * 1000000 | round / 1000000 | tostring) \(.unpriced)"' \
        | awk '{printf "%s %.6f %s\n", $1, $2, $3}'
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        scan)
            LEDGER_FORCE_SCAN=1 ledger_scan_all && echo "scan done"
            rm -f "${LEDGER_FILE}.scan-started" 2>/dev/null || true
            ;;
        lifetime) ledger_lifetime ;;
        session) ledger_session_totals "${2:-}" ;;
        window) ledger_window_tokens "${2:-0}" ;;
        price) ledger_price_for "${2:-}" ;;
        show) jq '{schema_version, last_scan, files: (.files | length), lifetime, buckets: (.buckets | length)}' "$LEDGER_FILE" ;;
        *)
            echo "Usage: $0 <scan|lifetime|session <id>|window <start_epoch>|price <model>|show>"
            ;;
    esac
fi
