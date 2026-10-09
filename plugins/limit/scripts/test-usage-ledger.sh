#!/usr/bin/env bash
# test-usage-ledger.sh - Fixture tests for the deduplicated JSONL usage ledger.
# Runs entirely in a temp dir (fake HOME / CLAUDE_CONFIG_DIR / PLUGIN_DATA_DIR);
# never touches the real projects dir or the real plugin state.
# shellcheck disable=SC2250

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="$TEST_DIR/home"
# Fake profile name (never ".claude"): debug logs and caches are keyed by it.
export CLAUDE_CONFIG_DIR="$TEST_DIR/home/limit-test-$$"
export CLAUDE_MB_LIMIT_DEBUG=false
export PLUGIN_DATA_DIR="$TEST_DIR/data"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/-home-myuser-acme" "$PLUGIN_DATA_DIR"
PROJ="$CLAUDE_CONFIG_DIR/projects/-home-myuser-acme"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
check() { # check <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# mkline <msg_id> <req_id> <model> <iso_ts> <in> <out> <cache_read> <cw5m> <cw1h> [block_type]
mkline() {
    jq -cn --arg id "$1" --arg rid "$2" --arg m "$3" --arg ts "$4" \
        --argjson i "$5" --argjson o "$6" --argjson cr "$7" --argjson c5 "$8" --argjson c1 "$9" \
        --arg bt "${10:-text}" \
        '{type:"assistant", requestId:$rid, timestamp:$ts,
          message:{id:$id, model:$m, content:[{type:$bt}],
            usage:{input_tokens:$i, output_tokens:$o, cache_read_input_tokens:$cr,
                   cache_creation_input_tokens:($c5+$c1),
                   cache_creation:{ephemeral_5m_input_tokens:$c5, ephemeral_1h_input_tokens:$c1}}}}'
}

# shellcheck source=usage-ledger.sh
source "$SCRIPT_DIR/usage-ledger.sh"

NOW=$(date -u +%s)
TS_RECENT=$(date -u -d "@$((NOW - 600))" +%Y-%m-%dT%H:%M:%S.123Z)
TS_OLD=$(date -u -d "@$((NOW - 6 * 3600))" +%Y-%m-%dT%H:%M:%S.000Z)

echo ">>> duplicated message.id lines (one per content block) count once"
SESSION_A="$PROJ/aaaa-session.jsonl"
{
    mkline msg_1 req_1 claude-opus-5-5 "$TS_RECENT" 10 100 1000 50 0 thinking
    mkline msg_1 req_1 claude-opus-5-5 "$TS_RECENT" 10 100 1000 50 0 text
    mkline msg_1 req_1 claude-opus-5-5 "$TS_RECENT" 10 100 1000 50 0 tool_use
    echo '{"type":"user","message":{"role":"user","content":"hi"}}'
    mkline msg_2 req_2 claude-opus-5-5 "$TS_RECENT" 5 20 2000 0 30 text
    mkline msg_2 req_2 claude-opus-5-5 "$TS_RECENT" 5 20 2000 0 30 tool_use
} > "$SESSION_A"
ledger_scan_files "$SESSION_A"
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals aaaa-session)"
check "session input (in+0)" "15" "$s_in"
check "session output" "120" "$s_out"
check "session cache reads separate" "3000" "$s_cr"
check "session cache writes" "80" "$s_cw"

echo ">>> incremental append continuing the same message id: last line wins, no double count"
mkline msg_2 req_2 claude-opus-5-5 "$TS_RECENT" 5 25 2000 0 30 text >> "$SESSION_A"
ledger_scan_files "$SESSION_A"
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals aaaa-session)"
check "output after continued message (last wins)" "125" "$s_out"
check "input unchanged after continued message" "15" "$s_in"

echo ">>> rescanning an unchanged file adds nothing"
ledger_scan_files "$SESSION_A"
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals aaaa-session)"
check "output stable on rescan" "125" "$s_out"

echo ">>> partial trailing line is not consumed until complete"
line=$(mkline msg_3 req_3 claude-opus-5-5 "$TS_RECENT" 1 7 0 0 0 text)
printf '%s' "${line:0:40}" >> "$SESSION_A"
ledger_scan_files "$SESSION_A"
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals aaaa-session)"
check "partial line ignored" "125" "$s_out"
printf '%s\n' "${line:40}" >> "$SESSION_A"
ledger_scan_files "$SESSION_A"
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals aaaa-session)"
check "completed line counted once" "132" "$s_out"

echo ">>> subagent files belong to their parent session; foreign models are skipped"
mkdir -p "$PROJ/aaaa-session/subagents"
SUB="$PROJ/aaaa-session/subagents/agent-x1.jsonl"
{
    mkline msg_s1 req_s1 claude-haiku-4-5-20251001 "$TS_OLD" 100 200 0 0 0 text
    mkline msg_s1 req_s1 claude-haiku-4-5-20251001 "$TS_OLD" 100 200 0 0 0 tool_use
    mkline msg_g1 req_g1 glm-4.6 "$TS_RECENT" 999 999 999 0 0 text
} > "$SUB"
ledger_scan_files "$SUB"
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals aaaa-session)"
check "session output incl. subagent" "332" "$s_out"

echo ">>> window tokens from timestamps (work = in+out+cache writes, cache reads separate)"
read -r w_work w_cr <<< "$(ledger_window_tokens $((NOW - 3600)))"
# recent: msg_1 (10+100+50) + msg_2 (5+25+30) + msg_3 (1+7) = 228; subagent line is 6h old
check "1h window work tokens" "228" "$w_work"
check "1h window cache reads" "3000" "$w_cr"
read -r w_work w_cr <<< "$(ledger_window_tokens $((NOW - 7 * 3600)))"
check "7h window includes old subagent" "528" "$w_work"

echo ">>> lifetime and pricing per concrete model id; unknown model -> n/a flag"
read -r lt_tokens lt_cost lt_unpriced <<< "$(ledger_lifetime)"
check "lifetime work tokens" "528" "$lt_tokens"
# opus-5-5: in 16*4 + out 132*20 + cr 3000*0.2 + cw5 50*5 + cw1 30*8 = 64+2640+600+250+240 = 3794 -> /1e6
# haiku-4-5: in 100*1 + out 200*5 = 1100 -> /1e6 ; total 0.004894
check "lifetime cost" "0.004894" "$lt_cost"
check "no unpriced models" "0" "$lt_unpriced"
OTHER="$PROJ/bbbb-session.jsonl"
mkline msg_u1 req_u1 claude-unknown-9 "$TS_RECENT" 1 1 0 0 0 text > "$OTHER"
ledger_scan_files "$OTHER"
read -r lt_tokens lt_cost lt_unpriced <<< "$(ledger_lifetime)"
check "unknown claude model flagged unpriced" "1" "$lt_unpriced"
check "unknown model adds no cost" "0.004894" "$lt_cost"

echo ">>> price lookup strips date suffix"
check "dated id resolves" "1 5 0.1 1.25 2" "$(ledger_price_for claude-haiku-4-5-20251001)"
check "unknown id empty" "" "$(ledger_price_for claude-unknown-9)"

echo ">>> global scan picks up files and is idempotent"
rm -f "$LEDGER_FILE"
ledger_scan_all
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals aaaa-session)"
check "global scan session output" "332" "$s_out"
touch "$SESSION_A" "$SUB"
LEDGER_FORCE_SCAN=1 ledger_scan_all
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals aaaa-session)"
check "second global scan does not double count" "332" "$s_out"

echo ">>> parallel scans of the same file count it once"
PAR="$PROJ/cccc-session.jsonl"
for n in 1 2 3 4 5 6; do mkline "msg_p$n" "req_p$n" claude-opus-5-5 "$TS_RECENT" 1 10 0 0 0 text; done > "$PAR"
pids=()
for n in 1 2 3 4 5 6; do ledger_scan_files "$PAR" & pids+=($!); done
for p in "${pids[@]}"; do wait "$p"; done
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals cccc-session)"
check "6 parallel scans -> output counted once" "60" "$s_out"
if jq -e . "$LEDGER_FILE" >/dev/null 2>&1; then ok "ledger valid JSON after parallel scans"; else bad "ledger corrupt after parallel scans"; fi

ledger_offset() { jq -r --arg p "$1" '.files[$p].b // 0' "$LEDGER_FILE"; }
ledger_pending() { jq -r --arg p "$1" '.files[$p].p // 0' "$LEDGER_FILE"; }
ledger_complete() { ledger_summary "" 0 0 | jq -r '.complete'; }

echo ">>> byte budget: a file is read in bounded chunks and resumed from the stored offset"
CHUNKED="$PROJ/dddd-session.jsonl"
{
    for n in 1 2 3 4 5 6 7 8; do
        mkline "msg_c$n" "req_c$n" claude-opus-5-5 "$TS_RECENT" 1 10 100 0 0 thinking
        mkline "msg_c$n" "req_c$n" claude-opus-5-5 "$TS_RECENT" 1 10 100 0 0 text
        mkline "msg_c$n" "req_c$n" claude-opus-5-5 "$TS_RECENT" 1 10 100 0 0 tool_use
    done
} > "$CHUNKED"
CHUNKED_SIZE=$(_ledger_file_size "$CHUNKED")
LINE_LEN=$(head -n 1 "$CHUNKED" | wc -c | tr -d ' ')
# Budget of two lines per call: messages are split across calls (dedup via tail).
LEDGER_SCAN_MAX_BYTES=$((LINE_LEN * 2)) ledger_scan_files "$CHUNKED"
off1=$(ledger_offset "$CHUNKED")
if [[ "$off1" -gt 0 && "$off1" -le $((LINE_LEN * 2)) ]]; then ok "first call stays within the byte budget ($off1 bytes)"; else bad "first call read $off1 bytes (budget $((LINE_LEN * 2)))"; fi
check "partially read file is marked pending" "1" "$(ledger_pending "$CHUNKED")"
check "ledger reports incomplete while a file is pending" "false" "$(ledger_complete)"
calls=1
while [[ "$(ledger_offset "$CHUNKED")" -lt "$CHUNKED_SIZE" && "$calls" -lt 40 ]]; do
    LEDGER_SCAN_MAX_BYTES=$((LINE_LEN * 2)) ledger_scan_files "$CHUNKED"
    calls=$((calls + 1))
done
check "chunked scan reaches the end of the file" "$CHUNKED_SIZE" "$(ledger_offset "$CHUNKED")"
if [[ "$calls" -ge 10 ]]; then ok "chunked scan needed several calls ($calls)"; else bad "chunked scan finished in $calls calls"; fi
check "pending flag cleared at the end" "0" "$(ledger_pending "$CHUNKED")"
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals dddd-session)"
check "chunked scan counts each message once (output)" "80" "$s_out"
check "chunked scan counts each message once (cache reads)" "800" "$s_cr"

echo ">>> a single line longer than the byte budget still makes progress"
LONGF="$PROJ/eeee-session.jsonl"
{
    mkline msg_l1 req_l1 claude-opus-5-5 "$TS_RECENT" 2 20 0 0 0 text
    mkline msg_l2 req_l2 claude-opus-5-5 "$TS_RECENT" 3 30 0 0 0 text
} > "$LONGF"
LEDGER_SCAN_MAX_BYTES=10 ledger_scan_files "$LONGF"
LEDGER_SCAN_MAX_BYTES=10 ledger_scan_files "$LONGF"
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals eeee-session)"
check "oversized lines are consumed one per call" "50" "$s_out"

echo ">>> the global scan resumes pending files that are not newer than last_scan"
rm -f "$LEDGER_FILE"
LEDGER_FORCE_SCAN=1 ledger_scan_all
check "global scan completes without a budget" "true" "$(ledger_complete)"
PEND="$PROJ/ffff-session.jsonl"
for n in 1 2 3 4 5 6; do mkline "msg_f$n" "req_f$n" claude-opus-5-5 "$TS_RECENT" 1 10 0 0 0 text; done > "$PEND"
touch -d "@$((NOW - 3600))" "$PEND"
PEND_LINE=$(head -n 1 "$PEND" | wc -c | tr -d ' ')
LEDGER_SCAN_MAX_BYTES=$PEND_LINE ledger_scan_files "$PEND"
check "pending after a budgeted session scan" "1" "$(ledger_pending "$PEND")"
check "summary incomplete while backfill pending" "false" "$(ledger_complete)"
LEDGER_FORCE_SCAN=1 ledger_scan_all
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals ffff-session)"
check "global scan finished the pending file" "60" "$s_out"
check "summary complete again" "true" "$(ledger_complete)"

echo ">>> a pending file that disappears does not block completeness forever"
GONE="$PROJ/hhhh-session.jsonl"
for n in 1 2 3 4; do mkline "msg_h$n" "req_h$n" claude-opus-5-5 "$TS_RECENT" 1 10 0 0 0 text; done > "$GONE"
LEDGER_SCAN_MAX_BYTES=$PEND_LINE ledger_scan_files "$GONE"
check "pending before removal" "1" "$(ledger_pending "$GONE")"
mv "$GONE" "$TEST_DIR/moved-away.jsonl"
LEDGER_FORCE_SCAN=1 ledger_scan_all
check "vanished pending file no longer pending" "0" "$(ledger_pending "$GONE")"
check "summary complete after a pending file vanished" "true" "$(ledger_complete)"
check "vanished transcript entry is pruned by the global scan" "null" "$(jq -r --arg p "$GONE" '.files[$p]' "$LEDGER_FILE")"

echo ">>> a global scan cut short by its byte budget does not advance last_scan"
rm -f "$LEDGER_FILE"
LEDGER_SCAN_MAX_BYTES=$PEND_LINE LEDGER_FORCE_SCAN=1 ledger_scan_all
check "last_scan stays 0 after a cut-short backfill" "0" "$(jq -r '.last_scan' "$LEDGER_FILE")"
check "cut-short backfill is incomplete" "false" "$(ledger_complete)"
runs=1
while [[ "$(ledger_complete)" != "true" && "$runs" -lt 200 ]]; do
    LEDGER_SCAN_MAX_BYTES=$((PEND_LINE * 4)) LEDGER_FORCE_SCAN=1 ledger_scan_all
    runs=$((runs + 1))
done
check "repeated budgeted scans finish the backfill" "true" "$(ledger_complete)"
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals aaaa-session)"
check "budgeted backfill session output" "332" "$s_out"
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals dddd-session)"
check "budgeted backfill split messages counted once" "80" "$s_out"

echo ">>> ingestion is linear: a large transcript is read in a few seconds"
BIG="$PROJ/gggg-session.jsonl"
awk -v base="$((NOW - 7200))" 'BEGIN {
    pad = sprintf("%200s", ""); gsub(/ /, "x", pad);
    for (i = 1; i <= 12000; i++) {
        ts = strftime("%Y-%m-%dT%H:%M:%S.000Z", base + int(i / 2), 1);
        printf "{\"type\":\"user\",\"timestamp\":\"%s\",\"message\":{\"role\":\"user\",\"content\":\"%s\"}}\n", ts, pad;
        for (b = 1; b <= 3; b++)
            printf "{\"type\":\"assistant\",\"requestId\":\"req_g%d\",\"timestamp\":\"%s\",\"message\":{\"id\":\"msg_g%d\",\"model\":\"claude-opus-5-5\",\"content\":[{\"type\":\"text\",\"text\":\"%s\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":2,\"cache_read_input_tokens\":3,\"cache_creation_input_tokens\":0}}}\n", i, ts, i, pad;
    }
}' > "$BIG"
t0=$(date +%s%N)
# Generous time budget: this measures throughput, not the budget cut-off.
LEDGER_SCAN_BUDGET=60 ledger_scan_files "$BIG"
t1=$(date +%s%N)
elapsed_ms=$(((t1 - t0) / 1000000))
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals gggg-session)"
check "36000 usage lines, 12000 messages counted once" "24000" "$s_out"
if [[ "$elapsed_ms" -lt 8000 ]]; then ok "large transcript scanned in ${elapsed_ms} ms"; else bad "large transcript took ${elapsed_ms} ms (quadratic?)"; fi

echo ">>> A: an oversized line limited only by the chunk size does not stop the scan"
OVR="$PROJ/iiii-session.jsonl"
{
    mkline msg_o1 req_o1 claude-opus-5-5 "$TS_RECENT" 1 10 0 0 0 text
    mkline msg_o2 req_o2 claude-opus-5-5 "$TS_RECENT" 1 20 0 0 0 text
    mkline msg_o3 req_o3 claude-opus-5-5 "$TS_RECENT" 1 30 0 0 0 text
} > "$OVR"
OVR_SIZE=$(_ledger_file_size "$OVR")
# Chunks smaller than one line, no byte budget: one call must still read it all.
LEDGER_CHUNK_BYTES=50 LEDGER_SMALL_FILE_BYTES=0 ledger_scan_files "$OVR"
check "chunk-capped oversized lines read in one call" "$OVR_SIZE" "$(ledger_offset "$OVR")"
check "chunk-capped scan leaves nothing pending" "0" "$(ledger_pending "$OVR")"
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals iiii-session)"
check "chunk-capped scan counts all lines" "60" "$s_out"

echo ">>> B: many small transcripts are read in one batched run"
rm -f "$LEDGER_FILE"
SMALLP="$CLAUDE_CONFIG_DIR/projects/-home-myuser-many"
mkdir -p "$SMALLP"
for n in $(seq 1 300); do
    mkline "msg_b$n" "req_b$n" claude-opus-5-5 "$TS_RECENT" 1 1 0 0 0 text > "$SMALLP/s$n.jsonl"
done
t0=$(date +%s%N)
CLAUDE_MB_LIMIT_SCAN_BUDGET=20 LEDGER_SCAN_BUDGET=20 LEDGER_FORCE_SCAN=1 ledger_scan_all
t1=$(date +%s%N)
small_ms=$(((t1 - t0) / 1000000))
check "all small files read in one run" "300" "$(jq --arg d "$SMALLP/" '[.files | to_entries[] | select(.key | startswith($d)) | select(.value.b > 0)] | length' "$LEDGER_FILE")"
check "one batched run completes the backfill" "true" "$(ledger_complete)"
if [[ "$small_ms" -lt 6000 ]]; then ok "300 small files in ${small_ms} ms"; else bad "300 small files took ${small_ms} ms (per-file overhead?)"; fi

echo ">>> C: entries of deleted transcripts are pruned"
mv "$SMALLP/s1.jsonl" "$TEST_DIR/s1-moved.jsonl"
LEDGER_FORCE_SCAN=1 ledger_scan_all
check "deleted transcript pruned from files" "null" "$(jq -r --arg p "$SMALLP/s1.jsonl" '.files[$p]' "$LEDGER_FILE")"
check "existing transcripts kept" "299" "$(jq --arg d "$SMALLP/" '[.files | keys[] | select(startswith($d))] | length' "$LEDGER_FILE")"
read -r lt_tokens lt_cost lt_unpriced <<< "$(ledger_lifetime)"
if [[ "$lt_tokens" -gt 0 ]]; then ok "lifetime keeps the pruned file's tokens"; else bad "lifetime lost tokens"; fi

echo ">>> D: the render-time gate is per transcript and an unchanged scan does not rewrite the ledger"
GA="$PROJ/jjjj-session.jsonl"
GB="$PROJ/kkkk-session.jsonl"
mkline msg_ga req_ga claude-opus-5-5 "$TS_RECENT" 1 5 0 0 0 text > "$GA"
mkline msg_gb req_gb claude-opus-5-5 "$TS_RECENT" 1 7 0 0 0 text > "$GB"
CLAUDE_MB_LIMIT_SCAN_SYNC=0 CLAUDE_MB_LIMIT_SESSION_SCAN=10 LEDGER_SCAN_INTERVAL=999999 ledger_refresh "$GA"
CLAUDE_MB_LIMIT_SCAN_SYNC=0 CLAUDE_MB_LIMIT_SESSION_SCAN=10 LEDGER_SCAN_INTERVAL=999999 ledger_refresh "$GB"
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals kkkk-session)"
check "second session scanned right after the first one wrote the ledger" "7" "$s_out"
touch -d "@$((NOW - 50))" "$LEDGER_FILE"
m_before=$(stat -c %Y "$LEDGER_FILE")
ledger_scan_files "$GA"
check "scan without new data keeps the ledger mtime" "$m_before" "$(stat -c %Y "$LEDGER_FILE")"

echo ">>> E: a run stopping at the time budget between files leaves an incomplete state"
LEDGER_FORCE_SCAN=1 ledger_scan_all
check "complete before new files" "true" "$(ledger_complete)"
for n in 1 2 3; do mkline "msg_e$n" "req_e$n" claude-opus-5-5 "$TS_RECENT" 1 1 0 0 0 text > "$PROJ/e$n-session.jsonl"; done
# One file per unit (no batching), budget 0: only the first unit runs.
LEDGER_SMALL_FILE_BYTES=0 LEDGER_SCAN_BUDGET=0 LEDGER_FORCE_SCAN=1 ledger_scan_all
check "budget stop marks unread files pending" "false" "$(ledger_complete)"
LEDGER_FORCE_SCAN=1 ledger_scan_all
check "next run finishes them" "true" "$(ledger_complete)"
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals e3-session)"
check "unread file counted once after resume" "1" "$s_out"

echo ">>> F: the CLI scan works on a fresh profile without a data dir"
FRESH="$TEST_DIR/fresh-data/limit"
out=$(PLUGIN_DATA_DIR="$FRESH" bash "$SCRIPT_DIR/usage-ledger.sh" scan 2>&1)
check "CLI scan on a fresh profile" "scan done" "$out"
if jq -e '.schema_version' "$FRESH"/limit-ledger_*.json >/dev/null 2>&1; then ok "fresh ledger written"; else bad "no ledger on a fresh profile"; fi

echo ">>> H: a 1 s render budget never fires before the first chunk"
misses=0
for n in $(seq 1 30); do
    mkline "msg_t$n" "req_t$n" claude-opus-5-5 "$TS_RECENT" 1 1 0 0 0 text > "$PROJ/t$n-session.jsonl"
    LEDGER_SCAN_BUDGET=1 ledger_scan_files "$PROJ/t$n-session.jsonl"
    [[ "$(ledger_offset "$PROJ/t$n-session.jsonl")" -gt 0 ]] || misses=$((misses + 1))
done
check "every 1 s budget call made progress" "0" "$misses"

echo ">>> MINOR1: a small pending file whose rest is only a partial line is no longer pending"
PP="$PROJ/pp-session.jsonl"
mkline msg_pp1 req_pp1 claude-opus-5-5 "$TS_RECENT" 1 4 0 0 0 text > "$PP"
PP_LINE=$(_ledger_file_size "$PP")
pp2=$(mkline msg_pp2 req_pp2 claude-opus-5-5 "$TS_RECENT" 1 4 0 0 0 text)
printf '%s' "${pp2:0:30}" >> "$PP"
LEDGER_SCAN_MAX_BYTES=$PP_LINE ledger_scan_files "$PP"
check "pending after a budgeted read with a partial rest" "1" "$(ledger_pending "$PP")"
ledger_scan_files "$PP"
check "batch path drops the pending flag when only a partial line is left" "0" "$(ledger_pending "$PP")"
m_before=$(stat -c %Y "$LEDGER_FILE")
touch -d "@$((NOW - 50))" "$LEDGER_FILE"
m_before=$(stat -c %Y "$LEDGER_FILE")
ledger_scan_files "$PP"
check "a partial rest alone does not rewrite the ledger" "$m_before" "$(stat -c %Y "$LEDGER_FILE")"

echo ">>> MAJOR2: one transcript under two spellings is counted once"
SPELL="$PROJ/spell-session.jsonl"
mkline msg_sp1 req_sp1 claude-opus-5-5 "$TS_RECENT" 1 9 0 0 0 text > "$SPELL"
ledger_scan_files "${PROJ}//spell-session.jsonl"
CLAUDE_PROJECTS_DIR="$CLAUDE_CONFIG_DIR//projects/" LEDGER_FORCE_SCAN=1 ledger_scan_all
ln -s "$CLAUDE_CONFIG_DIR/projects" "$TEST_DIR/projects-link"
ledger_scan_files "$TEST_DIR/projects-link/-home-myuser-acme/spell-session.jsonl"
mkline msg_sp2 req_sp2 claude-opus-5-5 "$TS_RECENT" 1 11 0 0 0 text >> "$SPELL"
ledger_scan_files "$TEST_DIR/projects-link/-home-myuser-acme/./spell-session.jsonl"
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals spell-session)"
check "two messages under four spellings counted once each" "20" "$s_out"
check "a single ledger entry for the transcript" "1" "$(jq '[.files | keys[] | select(endswith("/spell-session.jsonl"))] | length' "$LEDGER_FILE")"

echo ">>> MAJOR3: tails are kept only for recently active transcripts"
OLDF="$PROJ/old-session.jsonl"
TS_ANCIENT=$(date -u -d "@$((NOW - 5 * 86400))" +%Y-%m-%dT%H:%M:%S.000Z)
mkline msg_old1 req_old1 claude-opus-5-5 "$TS_ANCIENT" 1 2 0 0 0 text > "$OLDF"
ledger_scan_files "$OLDF" "$SPELL"
check "backfilled old transcript keeps no tail" "0" "$(jq --arg p "$OLDF" '.files[$p].tail // [] | length' "$LEDGER_FILE")"
check "recently active transcript keeps its tail" "2" "$(jq --arg p "$SPELL" '.files[$p].tail // [] | length' "$LEDGER_FILE")"

echo ">>> an old transcript read in chunks keeps its tail while pending (split messages count once)"
OLDSPLIT="$PROJ/oldsplit-session.jsonl"
{
    for n in 1 2 3 4; do
        mkline "msg_os$n" "req_os$n" claude-opus-5-5 "$TS_ANCIENT" 1 10 100 0 0 thinking
        mkline "msg_os$n" "req_os$n" claude-opus-5-5 "$TS_ANCIENT" 1 10 100 0 0 text
        mkline "msg_os$n" "req_os$n" claude-opus-5-5 "$TS_ANCIENT" 1 10 100 0 0 tool_use
    done
} > "$OLDSPLIT"
OS_LINE=$(head -n 1 "$OLDSPLIT" | wc -c | tr -d ' ')
calls=0
while [[ "$(ledger_offset "$OLDSPLIT")" -lt "$(_ledger_file_size "$OLDSPLIT")" && "$calls" -lt 40 ]]; do
    LEDGER_SCAN_MAX_BYTES=$((OS_LINE * 2)) ledger_scan_files "$OLDSPLIT"
    calls=$((calls + 1))
done
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals oldsplit-session)"
check "5-day-old transcript in split chunks: output exact" "40" "$s_out"
check "5-day-old transcript in split chunks: cache reads exact" "400" "$s_cr"
check "tail dropped once the old transcript is fully read" "0" "$(jq --arg p "$OLDSPLIT" '.files[$p].tail // [] | length' "$LEDGER_FILE")"

echo ">>> MAJOR3: a render-time scan of one file does not walk all ledger entries"
# Baseline in the same run (machine speed): the same single-file scan while
# the ledger holds only a few dozen entries.
mkline msg_r0 req_r0 claude-opus-5-5 "$TS_RECENT" 1 0 0 0 0 text >> "$SPELL"
t0=$(date +%s%N)
LEDGER_SCAN_MAX_BYTES=2097152 LEDGER_SCAN_BUDGET=1 ledger_scan_files "$SPELL"
t1=$(date +%s%N)
base_ms=$(((t1 - t0) / 1000000))
MANY="$CLAUDE_CONFIG_DIR/projects/-home-myuser-lots"
mkdir -p "$MANY"
for n in $(seq 1 2000); do
    printf '{"type":"assistant","requestId":"rl%s","timestamp":"%s","message":{"id":"ml%s","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1}}}\n' "$n" "$TS_RECENT" "$n" > "$MANY/l$n.jsonl"
done
LEDGER_SCAN_BUDGET=60 LEDGER_FORCE_SCAN=1 ledger_scan_all
mkline msg_r1 req_r1 claude-opus-5-5 "$TS_RECENT" 1 3 0 0 0 text >> "$SPELL"
t0=$(date +%s%N)
LEDGER_SCAN_MAX_BYTES=2097152 LEDGER_SCAN_BUDGET=1 ledger_scan_files "$SPELL"
t1=$(date +%s%N)
one_ms=$(((t1 - t0) / 1000000))
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals spell-session)"
check "single-file scan with 2000 ledger entries counts the new message" "23" "$s_out"
# Old code walked every entry in bash (~4x the baseline and more); allow 2.5x + 150 ms.
limit_ms=$((base_ms * 5 / 2 + 150))
if [[ "$one_ms" -lt "$limit_ms" ]]; then ok "single-file scan with 2000 entries in ${one_ms} ms (baseline ${base_ms} ms, limit ${limit_ms} ms)"; else bad "single-file scan with 2000 entries took ${one_ms} ms (baseline ${base_ms} ms, limit ${limit_ms} ms)"; fi

echo ">>> MAJOR1: a transcript created while the global scan lists files is never pruned and recounted"
RACE_DIR="$CLAUDE_CONFIG_DIR/projects/-home-myuser-race"
mkdir -p "$RACE_DIR"
eval "$(declare -f _ledger_list_transcripts | sed '1s/_ledger_list_transcripts/_orig_list_transcripts/')"
_ledger_list_transcripts() {
    # Simulate a session writing its first line while the scan list is built
    # (old code: after the existence listing, so the new entry got pruned).
    if [[ "$*" == *-newer* && ! -e "$RACE_DIR/race.jsonl" ]]; then
        mkline msg_race req_race claude-opus-5-5 "$TS_RECENT" 1 5 0 0 0 text > "$RACE_DIR/race.jsonl"
    fi
    _orig_list_transcripts "$@"
}
read -r lt_before _ _ <<< "$(ledger_lifetime)"
LEDGER_FORCE_SCAN=1 ledger_scan_all
sleep 1
LEDGER_FORCE_SCAN=1 ledger_scan_all
LEDGER_FORCE_SCAN=1 ledger_scan_all
read -r lt_after _ _ <<< "$(ledger_lifetime)"
check "lifetime grows by the race message exactly once (in 1 + out 5)" "6" "$((lt_after - lt_before))"
eval "$(declare -f _orig_list_transcripts | sed '1s/_orig_list_transcripts/_ledger_list_transcripts/')"
read -r s_in s_out s_cr s_cw <<< "$(ledger_session_totals race)"
check "file created between the listings counted once" "5" "$s_out"
check "its entry survives the scan that read it" "true" "$(jq --arg p "$RACE_DIR/race.jsonl" '.files[$p] != null' "$LEDGER_FILE")"

echo ">>> MAJOR1: appends and new files during scans are counted exactly once"
for seed in 1 2 3; do
    CONC="$CLAUDE_CONFIG_DIR/projects/-home-myuser-conc$seed"
    mkdir -p "$CONC"
    RANDOM=$seed
    read -r conc_before _ _ <<< "$(ledger_lifetime)"
    (
        for i in $(seq 1 120); do
            f="$CONC/c$((RANDOM % 6)).jsonl"
            printf '%s\n' "$(mkline "msg_k${seed}_$i" "req_k${seed}_$i" claude-opus-5-5 "$TS_RECENT" 1 1 0 0 0 text)" >> "$f"
            [[ $((RANDOM % 4)) -eq 0 ]] && sleep 0.0$((RANDOM % 9))
        done
    ) &
    app=$!
    while kill -0 "$app" 2>/dev/null; do
        LEDGER_FORCE_SCAN=1 ledger_scan_all
        ledger_scan_files "$CONC/c$((RANDOM % 6)).jsonl" 2>/dev/null
    done
    wait "$app"
    LEDGER_FORCE_SCAN=1 ledger_scan_all
    LEDGER_FORCE_SCAN=1 ledger_scan_all
    total=$(jq --arg d "$CONC/" '[.files | to_entries[] | select(.key | startswith($d)) | .value.sum[1]] | add // 0' "$LEDGER_FILE")
    check "seed $seed: 120 concurrent appends counted exactly once" "120" "$total"
    read -r conc_after _ _ <<< "$(ledger_lifetime)"
    check "seed $seed: lifetime grows by exactly 120 x 2 work tokens" "240" "$((conc_after - conc_before))"
done

echo ">>> corrupt ledger is reported as unreadable, never as zero"
echo -n "" > "$LEDGER_FILE"
if ledger_window_tokens $((NOW - 3600)) >/dev/null 2>&1; then
    bad "empty ledger must fail the read"
else
    ok "empty ledger read fails"
fi

echo ""
echo "passed: $PASS failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
