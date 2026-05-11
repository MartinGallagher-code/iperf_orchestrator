#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Robustness probes: large inputs, weird whitespace, non-default paths,
# parser pathologies, behavior on the boundary between commands. None
# of these are happy-path tests -- they're the "what if a user does
# something weird" set.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# ---- Server-list robustness ---------------------------------------------

test_read_servers_handles_crlf_line_endings() {
    source_orch
    # Windows-style line endings -- trailing \r should be stripped by
    # the whitespace-trim sed rule.
    printf 'host1\r\nhost2\r\nhost3\r\n' > "$SERVER_LIST_FILE"
    local out
    out=$(read_servers)
    assert_eq "host1
host2
host3" "$out" "CRLF should be tolerated like any trailing whitespace" || return 1
}

test_read_servers_only_comments_yields_empty() {
    source_orch
    cat > "$SERVER_LIST_FILE" <<'EOF'
# all comments
# nothing else here
# really
EOF
    local out
    out=$(read_servers)
    assert_eq "" "$out" "comments-only file should produce no hosts" || return 1
}

test_read_servers_only_blank_lines_yields_empty() {
    source_orch
    printf '\n\n\n\n' > "$SERVER_LIST_FILE"
    local out
    out=$(read_servers)
    assert_eq "" "$out" "blank-lines-only file should produce no hosts" || return 1
}

test_read_servers_handles_long_input() {
    source_orch
    : > "$SERVER_LIST_FILE"
    local i
    for i in $(seq 1 1000); do
        printf 'host%04d.example.com\n' "$i" >> "$SERVER_LIST_FILE"
    done
    local n
    n=$(read_servers | wc -l)
    assert_eq "1000" "$n" || return 1
}

# ---- Parser robustness ---------------------------------------------------

test_parse_csv_ignores_logs_in_subdirectories() {
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID/sub"
    # iperf_test_*.log under a subdirectory should NOT be picked up.
    cat > "$RESULTS_BASE/$IPERF_RUN_ID/sub/iperf_test_x_to_y_${IPERF_RUN_ID}.log" <<'EOF'
# pair_a=x pair_b=y duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,1100000000,880000000
EOF
    # Top-level legitimate log to compare against.
    cat > "$RESULTS_BASE/$IPERF_RUN_ID/iperf_test_a_to_b_${IPERF_RUN_ID}.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,1100000000,880000000
EOF
    run_orch parse-csv >/dev/null 2>&1
    local n
    n=$(($(wc -l < "$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv") - 1))
    assert_eq "2" "$n" "should only pick up the top-level log (2 rows)" || return 1
}

test_parse_csv_handles_log_with_only_comments() {
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    # All-comment log file (no CSV body).
    cat > "$RESULTS_BASE/$IPERF_RUN_ID/iperf_test_x_to_y_${IPERF_RUN_ID}.log" <<'EOF'
# pair_a=x pair_b=y duration=10 port=5001 parallel=1 test_start=1700000000
# additional comment lines
# only here for context
EOF
    run_orch parse-csv >/dev/null 2>&1
    # Should produce 2 NO_SUMMARY rows.
    local n
    n=$(grep -c NO_SUMMARY "$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv")
    assert_eq "2" "$n" "comment-only log should give 2 NO_SUMMARY rows" || return 1
}

test_parse_csv_handles_corrupt_csv_lines_gracefully() {
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    # Mix of valid and broken CSV lines.
    cat > "$RESULTS_BASE/$IPERF_RUN_ID/iperf_test_a_to_b_${IPERF_RUN_ID}.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=1 test_start=1700000000
this,is,not,a,valid,csv,row,really,really
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,bad-interval,1250000000,1000000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,1100000000,880000000
EOF
    run_orch parse-csv
    assert_status 0 "$RUN_RC" "should still produce CSV" || return 1
    # The two valid summary rows are picked up.
    local v
    v=$(python3 -c "
import csv
for r in csv.DictReader(open('$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv')):
    if r['source']=='a' and r['target']=='b':
        print(r['mbps'])
")
    assert_eq "1000.0" "$v" "valid summary should be parsed despite garbage lines" || return 1
}

test_parse_csv_handles_very_large_log() {
    # 200 KB of garbage + 2 valid summaries should still parse.
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    {
        echo "# pair_a=a pair_b=b duration=10 port=5001 parallel=1 test_start=1700000000"
        # Dump 200 KB of noise.
        head -c 200000 /dev/urandom | base64 | head -n 4000
        echo "20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000"
        echo "20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,1100000000,880000000"
    } > "$RESULTS_BASE/$IPERF_RUN_ID/iperf_test_a_to_b_${IPERF_RUN_ID}.log"
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    local v
    v=$(python3 -c "
import csv
for r in csv.DictReader(open('$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv')):
    if r['source']=='a' and r['target']=='b':
        print(r['mbps'])
")
    assert_eq "1000.0" "$v" "valid summary should be parsed in a very large log" || return 1
}

# ---- Concurrency / atomicity --------------------------------------------

# ---- Empty-but-existing server list -------------------------------------

test_parallel_hosts_users_succeed_quietly_with_empty_server_list() {
    # The server list FILE exists but contains zero hosts. parallel_hosts
    # users should treat that as "nothing to do", not a failure.
    : > "$IPERF_SERVERS"
    install_fake_ssh
    PATH="$FAKE_BIN:$PATH" run_orch check-iperf
    assert_status 0 "$RUN_RC" "empty list -> exit 0 (nothing to do)" || return 1
    PATH="$FAKE_BIN:$PATH" run_orch check-servers
    assert_status 0 "$RUN_RC" || return 1
    PATH="$FAKE_BIN:$PATH" run_orch start-servers
    assert_status 0 "$RUN_RC" || return 1
}

# ---- Pivot/heatmap edge cases -------------------------------------------

test_make_pivot_handles_single_host_csv_gracefully() {
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    # Self-test row (same source and target). Pivot should still
    # render without crashing -- diagonal is just '-'.
    cat > "$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv" <<'EOF'
timestamp,source,target,status,protocol,duration_s,parallel_streams,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error
20260101120000,a,a,OK,TCP,10,1,0,0,0,54321,5001,a,a,iperf_test_a_to_a_${IPERF_RUN_ID}.log,
EOF
    run_orch make-pivot
    assert_status 0 "$RUN_RC" || return 1
    [ -f "$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt" ] || return 1
}

test_make_pivot_handles_all_missing_data() {
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    # Two pairs, both with empty mbps (never measured).
    cat > "$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv" <<'EOF'
timestamp,source,target,status,protocol,duration_s,parallel_streams,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error
,a,b,DIRECTION_MISSING,TCP,10,1,,,,,,a,b,iperf_test_a_to_b_${IPERF_RUN_ID}.log,no data
,b,a,DIRECTION_MISSING,TCP,10,1,,,,,,a,b,iperf_test_a_to_b_${IPERF_RUN_ID}.log,no data
EOF
    run_orch make-pivot
    assert_status 0 "$RUN_RC" "pivot should not crash on all-NaN data" || return 1
    # Output should mark every cell as '-'
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    # With every cell missing, the per-host section is correctly
    # omitted; the pivot just renders the header + grid of '-(N)' cells.
    grep -q "iperf2 full-duplex mesh throughput" "$pivot" || return 1
}

# ---- Status output cleanliness ------------------------------------------

test_status_output_includes_no_uninterpolated_variables() {
    # A bug in the heredoc would leave literal "$IPERF_DIR" in output.
    run_orch status
    assert_status 0 "$RUN_RC" || return 1
    # No literal "$IPERF_DIR" / "$STATE_FILE" / etc. in the output.
    if echo "$RUN_OUT" | grep -qE '\$[A-Z_]+'; then
        echo "status output has uninterpolated shell vars:" >&2
        echo "$RUN_OUT" | grep -E '\$[A-Z_]+' >&2
        return 1
    fi
}

run_test test_read_servers_handles_crlf_line_endings
run_test test_read_servers_only_comments_yields_empty
run_test test_read_servers_only_blank_lines_yields_empty
run_test test_read_servers_handles_long_input
run_test test_parse_csv_ignores_logs_in_subdirectories
run_test test_parse_csv_handles_log_with_only_comments
run_test test_parse_csv_handles_corrupt_csv_lines_gracefully
run_test test_parse_csv_handles_very_large_log
run_test test_parallel_hosts_users_succeed_quietly_with_empty_server_list
run_test test_make_pivot_handles_single_host_csv_gracefully
run_test test_make_pivot_handles_all_missing_data
run_test test_status_output_includes_no_uninterpolated_variables

report_tests
