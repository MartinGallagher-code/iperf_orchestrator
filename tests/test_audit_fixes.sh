#!/usr/bin/env bash
# Regression tests for the audit fixes:
#   #1 parallel_hosts users die on missing server list
#   #2 invalid numeric flags rejected
#   #3 cmd_init warns on duplicate hostnames
#   #4 parse-csv direction detection with both-ephemeral case
#   #5 parser commands propagate Python exit codes (already
#      checked in the parse-csv / make-heatmap test files)
#   #6 parse-cpu blanks per-core fields when no per-core rows
#   #7 _run_parallel uses parallel arrays (avoids IPv6 truncation)

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# ---- #1: parallel_hosts users die when no server list -----------------------

test_check_iperf_dies_when_no_server_list() {
    # No init done; running check-iperf should NOT silently succeed
    # and should NOT flag IPERF_INSTALLED_CHECKED.
    run_orch check-iperf
    assert_ne 0 "$RUN_RC" "check-iperf should fail" || return 1
    assert_contains "$RUN_OUT" "No server list" || return 1
    if [ -f "$IPERF_DIR/state" ] && grep -q '^IPERF_INSTALLED_CHECKED=yes$' "$IPERF_DIR/state"; then
        echo "should not have flagged IPERF_INSTALLED_CHECKED" >&2
        cat "$IPERF_DIR/state" >&2
        return 1
    fi
}

test_check_servers_dies_when_no_server_list() {
    run_orch check-servers
    assert_ne 0 "$RUN_RC" "check-servers should fail" || return 1
    assert_contains "$RUN_OUT" "No server list" || return 1
    if [ -f "$IPERF_DIR/state" ] && grep -q '^SERVERS_RUNNING_CHECKED=yes$' "$IPERF_DIR/state"; then
        echo "should not have flagged SERVERS_RUNNING_CHECKED" >&2
        return 1
    fi
}

test_start_servers_dies_when_no_server_list() {
    run_orch start-servers
    assert_ne 0 "$RUN_RC" "start-servers should fail" || return 1
    assert_contains "$RUN_OUT" "No server list" || return 1
}

test_stop_servers_dies_when_no_server_list() {
    run_orch stop-servers
    assert_ne 0 "$RUN_RC" "stop-servers should fail" || return 1
}

test_cleanup_dies_when_no_server_list() {
    run_orch cleanup
    assert_ne 0 "$RUN_RC" "cleanup should fail" || return 1
}

test_distribute_scripts_dies_when_no_server_list() {
    run_orch distribute-scripts
    assert_ne 0 "$RUN_RC" "distribute-scripts should fail" || return 1
}

test_collect_results_dies_when_no_server_list() {
    run_orch collect-results
    assert_ne 0 "$RUN_RC" "collect-results should fail" || return 1
}

# ---- #2: invalid numeric flags --------------------------------------------

test_invalid_port_rejected() {
    run_orch --port=notanumber help
    assert_status 2 "$RUN_RC" "non-integer --port should exit 2" || return 1
    assert_contains "$RUN_OUT" "IPERF_PORT" "error should name the offending var" || return 1
}

test_port_above_max_rejected() {
    run_orch --port=99999 help
    assert_status 2 "$RUN_RC" "port > 65535 should be rejected" || return 1
    assert_contains "$RUN_OUT" "65535" "error should mention the upper bound" || return 1
}

test_duration_zero_rejected() {
    run_orch --duration=0 help
    assert_status 2 "$RUN_RC" "duration=0 should be rejected" || return 1
    assert_contains "$RUN_OUT" "DURATION" || return 1
}

test_parallel_zero_rejected() {
    run_orch --parallel=0 help
    assert_status 2 "$RUN_RC" "parallel=0 should be rejected" || return 1
}

test_parallel_garbage_rejected() {
    run_orch --parallel=foo help
    assert_status 2 "$RUN_RC" "non-int --parallel should be rejected" || return 1
}

test_start_delay_zero_is_allowed() {
    # 0 is a legal start delay (run immediately after sync).
    run_orch --start-delay=0 help
    assert_status 0 "$RUN_RC" "start-delay=0 should be accepted" || return 1
}

test_start_delay_garbage_rejected() {
    run_orch --start-delay=hi help
    assert_status 2 "$RUN_RC" "non-int start-delay should be rejected" || return 1
}

# ---- #3: duplicate hostnames in init --------------------------------------

test_init_warns_on_duplicates() {
    local src="$TEST_TMPDIR/dup.txt"
    printf 'host-a\nhost-b\nhost-a\nhost-c\nhost-b\n' > "$src"
    run_orch init "$src"
    assert_status 0 "$RUN_RC" "init should still succeed" || return 1
    assert_contains "$RUN_OUT" "duplicate" "should warn about duplicates" || return 1
    assert_contains "$RUN_OUT" "host-a" "should name the duplicate" || return 1
    assert_contains "$RUN_OUT" "host-b" "should name both duplicates" || return 1
}

test_init_no_warning_for_unique_hosts() {
    local src="$TEST_TMPDIR/unique.txt"
    printf 'h1\nh2\nh3\n' > "$src"
    run_orch init "$src"
    assert_status 0 "$RUN_RC" || return 1
    assert_not_contains "$RUN_OUT" "duplicate" "no duplicates -> no warning" || return 1
}

# ---- #8: addr fallback uses exact match (no IP-prefix false positives) ----

test_parse_csv_ip_prefix_addresses() {
    mkdir -p "$IPERF_DIR/results"
    # Both ephemeral source ports + addresses where one is a substring
    # of the other ("10.0.0.1" vs "10.0.0.10"). The old substring-based
    # fallback would mis-assign because '10.0.0.1' in '10.0.0.10' is
    # True; the exact-match fallback handles it correctly.
    cat > "$IPERF_DIR/results/iperf_test_x_to_y.log" <<'EOF'
# pair_a=10.0.0.1 pair_b=10.0.0.10 duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.10,12345,3,0.0-10.0,1250000000,1000000000
20260101120000.000,10.0.0.10,54322,10.0.0.1,12345,3,0.0-10.0,1100000000,880000000
EOF
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    local v
    v=$(python3 -c "
import csv
for r in csv.DictReader(open('$IPERF_DIR/results/iperf_results.csv')):
    if r['source']=='10.0.0.1' and r['target']=='10.0.0.10':
        print(r['mbps'])
")
    assert_eq "1000.0" "$v" "10.0.0.1 -> 10.0.0.10 should be 1000 Mbps" || return 1
    v=$(python3 -c "
import csv
for r in csv.DictReader(open('$IPERF_DIR/results/iperf_results.csv')):
    if r['source']=='10.0.0.10' and r['target']=='10.0.0.1':
        print(r['mbps'])
")
    assert_eq "880.0" "$v" "10.0.0.10 -> 10.0.0.1 should be 880 Mbps" || return 1
}

# ---- #9: parse-csv prefers SUM rows when -P > 1 ---------------------------

test_parse_csv_picks_sum_row_with_parallel_streams() {
    mkdir -p "$IPERF_DIR/results"
    # -P 4 layout: 4 per-stream rows + 1 SUM row per direction.
    # SUM rows have transfer_id='-1' and src_port='SUM'. The aggregate
    # bandwidth must come from the SUM rows (960/880), not from one of
    # the per-stream rows (240/220 each).
    cat > "$IPERF_DIR/results/iperf_test_a_to_b.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=4 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,1,0.0-10.0,300000000,240000000
20260101120000.000,10.0.0.1,54322,10.0.0.2,5001,2,0.0-10.0,300000000,240000000
20260101120000.000,10.0.0.1,54323,10.0.0.2,5001,3,0.0-10.0,300000000,240000000
20260101120000.000,10.0.0.1,54324,10.0.0.2,5001,4,0.0-10.0,300000000,240000000
20260101120000.000,10.0.0.1,SUM,10.0.0.2,5001,-1,0.0-10.0,1200000000,960000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,1,0.0-10.0,275000000,220000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54322,2,0.0-10.0,275000000,220000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54323,3,0.0-10.0,275000000,220000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54324,4,0.0-10.0,275000000,220000000
20260101120000.000,10.0.0.2,SUM,10.0.0.1,-1,-1,0.0-10.0,1100000000,880000000
EOF
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    local csv="$IPERF_DIR/results/iperf_results.csv"
    local v
    v=$(python3 -c "
import csv
for r in csv.DictReader(open('$csv')):
    if r['source']=='a' and r['target']=='b':
        print(r['mbps'])
")
    assert_eq "960.0" "$v" "a->b should report SUM (960 Mbps), not per-stream" || return 1
    v=$(python3 -c "
import csv
for r in csv.DictReader(open('$csv')):
    if r['source']=='b' and r['target']=='a':
        print(r['mbps'])
")
    assert_eq "880.0" "$v" "b->a should report SUM (880 Mbps), not per-stream" || return 1
}

test_parse_csv_handles_parallel_without_explicit_sum_marker() {
    # Some iperf2 builds emit per-stream rows but no SUM marker. The
    # parser falls back to picking the highest-bps row, which is at
    # least as large as any single stream and is a reasonable proxy
    # for the aggregate when present.
    mkdir -p "$IPERF_DIR/results"
    cat > "$IPERF_DIR/results/iperf_test_a_to_b.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=2 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,1,0.0-10.0,300000000,240000000
20260101120000.000,10.0.0.1,54322,10.0.0.2,5001,2,0.0-10.0,300000000,240000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,1,0.0-10.0,275000000,220000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54322,2,0.0-10.0,275000000,220000000
EOF
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    # No SUM marker -> parser uses max-bps heuristic. 240/220 is what
    # it can do with no explicit aggregate; a is reasonable behavior
    # since it doesn't double-count streams.
    local v
    v=$(python3 -c "
import csv
for r in csv.DictReader(open('$IPERF_DIR/results/iperf_results.csv')):
    if r['source']=='a' and r['target']=='b':
        print(r['mbps'])
")
    # Both rows have identical bps in this fixture, so result is 240.
    assert_eq "240.0" "$v" "without SUM marker, pick max-bps stream" || return 1
}

# ---- #4: parse-csv direction detection with both-ephemeral case ------------

test_parse_csv_both_ephemeral_ports() {
    mkdir -p "$IPERF_DIR/results"
    # Both summary lines have ephemeral source ports (neither matches
    # listening_port=5001). Without the fix, a_to_b gets overwritten
    # by the second row and b_to_a stays None.
    cat > "$IPERF_DIR/results/iperf_test_a_to_b.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,12345,3,0.0-10.0,1250000000,1000000000
20260101120000.000,10.0.0.2,54322,10.0.0.1,12345,3,0.0-10.0,1100000000,880000000
EOF
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    # Both directions should be OK and reasonable -- no DIRECTION_MISSING.
    if grep -q "DIRECTION_MISSING" "$IPERF_DIR/results/iperf_results.csv"; then
        echo "fallback should populate both directions, not leave one missing" >&2
        cat "$IPERF_DIR/results/iperf_results.csv" >&2
        return 1
    fi
    # 2 OK rows
    local ok
    ok=$(awk -F, 'NR>1 && $4=="OK"' "$IPERF_DIR/results/iperf_results.csv" | wc -l)
    assert_eq "2" "$ok" "should have 2 OK rows" || return 1
}

# ---- #6: parse-cpu blanks per-core fields when only "all" rows ------------

test_parse_cpu_blanks_per_core_when_only_all_row() {
    mkdir -p "$IPERF_DIR/results"
    cat > "$IPERF_DIR/results/cpu_no-percore.log" <<'EOF'
Linux 5.15.0 (host)   01/01/2026  _x86_64_    (1 CPU)

12:00:00     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
12:00:01     all   50.00    0.00   30.00    0.00    0.00   10.00    0.00    0.00    0.00   10.00

12:00:01     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
12:00:02     all   60.00    0.00   25.00    0.00    0.00    8.00    0.00    0.00    0.00    7.00
EOF
    run_orch parse-cpu
    assert_status 0 "$RUN_RC" || return 1
    local csv="$IPERF_DIR/results/cpu_summary.csv"
    local v
    v=$(python3 -c "
import csv
for row in csv.DictReader(open('$csv')):
    if row['host'] == 'no-percore':
        print(repr(row['peak_softirq_pct']), repr(row['peak_idle_floor_pct']))
")
    # Both per-core fields should be empty strings, not 0.0/100.0.
    assert_eq "'' ''" "$v" "per-core fields should be blank when no per-core rows" || return 1
}

# ---- #7: _run_parallel parallel-arrays (sanity check on code shape) -------

test_run_parallel_uses_parallel_arrays() {
    # Code review check: the implementation should not depend on
    # splitting "$pid:$host" anymore (which truncates IPv6 addresses).
    if grep -E 'pid_to_host\+=' "$ORCH" >/dev/null; then
        echo "old pid_to_host=\"\$p:\$host\" pattern still present" >&2
        return 1
    fi
    grep -q 'hosts_for_pids' "$ORCH" || {
        echo "expected hosts_for_pids parallel array" >&2
        return 1
    }
}

run_test test_check_iperf_dies_when_no_server_list
run_test test_check_servers_dies_when_no_server_list
run_test test_start_servers_dies_when_no_server_list
run_test test_stop_servers_dies_when_no_server_list
run_test test_cleanup_dies_when_no_server_list
run_test test_distribute_scripts_dies_when_no_server_list
run_test test_collect_results_dies_when_no_server_list
run_test test_invalid_port_rejected
run_test test_port_above_max_rejected
run_test test_duration_zero_rejected
run_test test_parallel_zero_rejected
run_test test_parallel_garbage_rejected
run_test test_start_delay_zero_is_allowed
run_test test_start_delay_garbage_rejected
run_test test_init_warns_on_duplicates
run_test test_init_no_warning_for_unique_hosts
run_test test_parse_csv_both_ephemeral_ports
run_test test_parse_csv_ip_prefix_addresses
run_test test_parse_csv_picks_sum_row_with_parallel_streams
run_test test_parse_csv_handles_parallel_without_explicit_sum_marker
run_test test_parse_cpu_blanks_per_core_when_only_all_row
run_test test_run_parallel_uses_parallel_arrays

report_tests
