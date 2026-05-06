#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Regression tests for the audit fixes that survived the stateless-mode
# refactor:
#   #1 parallel_hosts users die on missing server list
#   #2 invalid numeric flags rejected
#   #3 duplicate hostnames trigger a warning at use-time
#   #4 parse-csv direction detection (both-ephemeral, IP-prefix, SUM rows)
#   #6 parse-cpu blanks per-core fields when no per-core rows
#   #7 _run_parallel uses parallel arrays (avoids IPv6 truncation)

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# Helper: run with no server list configured.
run_no_servers() {
    unset IPERF_SERVERS
    run_orch --servers /no/such.txt "$@"
}

# Helper for parse-csv tests: results dir for the active run-id.
results_dir() { echo "$RESULTS_BASE/$IPERF_RUN_ID"; }
seed_run_dir() { mkdir -p "$(results_dir)"; }

# ---- #1: parallel_hosts users die when no server list -----------------------

test_check_iperf_dies_when_no_server_list() {
    run_no_servers check-iperf
    assert_ne 0 "$RUN_RC" "check-iperf should fail" || return 1
    assert_contains "$RUN_OUT" "no server list" || return 1
}

test_check_servers_dies_when_no_server_list() {
    run_no_servers check-servers
    assert_ne 0 "$RUN_RC" "check-servers should fail" || return 1
    assert_contains "$RUN_OUT" "no server list" || return 1
}

test_start_servers_dies_when_no_server_list() {
    run_no_servers start-servers
    assert_ne 0 "$RUN_RC" "start-servers should fail" || return 1
    assert_contains "$RUN_OUT" "no server list" || return 1
}

test_stop_servers_dies_when_no_server_list() {
    run_no_servers stop-servers
    assert_ne 0 "$RUN_RC" "stop-servers should fail" || return 1
}

test_cleanup_dies_when_no_server_list() {
    run_orch cleanup
    assert_ne 0 "$RUN_RC" "cleanup should fail (no --yes)" || return 1
}

test_distribute_scripts_dies_when_no_server_list() {
    run_no_servers distribute-scripts
    assert_ne 0 "$RUN_RC" "distribute-scripts should fail" || return 1
}

test_collect_results_dies_when_no_server_list() {
    run_no_servers collect-results
    assert_ne 0 "$RUN_RC" "collect-results should fail" || return 1
}

# ---- #2: invalid numeric flags --------------------------------------------

test_invalid_port_rejected() {
    run_orch --port=notanumber help
    assert_status 2 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "IPERF_PORT" || return 1
}

test_port_above_max_rejected() {
    run_orch --port=99999 help
    assert_status 2 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "65535" || return 1
}

test_duration_zero_rejected() {
    run_orch --duration=0 help
    assert_status 2 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "DURATION" || return 1
}

test_parallel_zero_rejected() {
    run_orch --streams=0 help
    assert_status 2 "$RUN_RC" || return 1
}

test_parallel_garbage_rejected() {
    run_orch --streams=foo help
    assert_status 2 "$RUN_RC" || return 1
}

test_start_delay_zero_is_allowed() {
    run_orch --start-delay=0 help
    assert_status 0 "$RUN_RC" || return 1
}

test_start_delay_garbage_rejected() {
    run_orch --start-delay=hi help
    assert_status 2 "$RUN_RC" || return 1
}

# ---- #3: duplicate hostnames ----------------------------------------------

test_duplicates_trigger_warning_at_create_scripts() {
    install_fake_ssh
    write_server_list host-a host-b host-a host-c host-b >/dev/null
    PATH="$FAKE_BIN:$PATH" run_orch create-scripts
    # _validate_server_list warns but doesn't die; create-scripts proceeds.
    assert_contains "$RUN_OUT" "duplicate" || return 1
    assert_contains "$RUN_OUT" "host-a" || return 1
    assert_contains "$RUN_OUT" "host-b" || return 1
}

test_no_warning_for_unique_hosts() {
    install_fake_ssh
    write_server_list h1 h2 h3 >/dev/null
    PATH="$FAKE_BIN:$PATH" run_orch create-scripts
    assert_status 0 "$RUN_RC" || return 1
    assert_not_contains "$RUN_OUT" "duplicate" "no duplicates -> no warning" || return 1
}

# ---- #8: addr fallback uses exact match (no IP-prefix false positives) ----

test_parse_csv_ip_prefix_addresses() {
    seed_run_dir
    cat > "$(results_dir)/iperf_test_x_to_y_${IPERF_RUN_ID}.log" <<'EOF'
# pair_a=10.0.0.1 pair_b=10.0.0.10 duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.10,12345,3,0.0-10.0,1250000000,1000000000
20260101120000.000,10.0.0.10,54322,10.0.0.1,12345,3,0.0-10.0,1100000000,880000000
EOF
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    local v
    v=$(python3 -c "
import csv
for r in csv.DictReader(open('$(results_dir)/iperf_results.csv')):
    if r['source']=='10.0.0.1' and r['target']=='10.0.0.10':
        print(r['mbps'])
")
    assert_eq "1000.0" "$v" "10.0.0.1 -> 10.0.0.10 should be 1000 Mbps" || return 1
    v=$(python3 -c "
import csv
for r in csv.DictReader(open('$(results_dir)/iperf_results.csv')):
    if r['source']=='10.0.0.10' and r['target']=='10.0.0.1':
        print(r['mbps'])
")
    assert_eq "880.0" "$v" "10.0.0.10 -> 10.0.0.1 should be 880 Mbps" || return 1
}

# ---- #9: parse-csv prefers SUM rows when -P > 1 ---------------------------

test_parse_csv_picks_sum_row_with_parallel_streams() {
    seed_run_dir
    cat > "$(results_dir)/iperf_test_a_to_b_${IPERF_RUN_ID}.log" <<'EOF'
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
    local csv
    csv="$(results_dir)/iperf_results.csv"
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
    seed_run_dir
    cat > "$(results_dir)/iperf_test_a_to_b_${IPERF_RUN_ID}.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=2 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,1,0.0-10.0,300000000,240000000
20260101120000.000,10.0.0.1,54322,10.0.0.2,5001,2,0.0-10.0,300000000,240000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,1,0.0-10.0,275000000,220000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54322,2,0.0-10.0,275000000,220000000
EOF
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    local v
    v=$(python3 -c "
import csv
for r in csv.DictReader(open('$(results_dir)/iperf_results.csv')):
    if r['source']=='a' and r['target']=='b':
        print(r['mbps'])
")
    assert_eq "240.0" "$v" "without SUM marker, pick max-bps stream" || return 1
}

# ---- #4: parse-csv direction detection with both-ephemeral case ------------

test_parse_csv_both_ephemeral_ports() {
    seed_run_dir
    cat > "$(results_dir)/iperf_test_a_to_b_${IPERF_RUN_ID}.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,12345,3,0.0-10.0,1250000000,1000000000
20260101120000.000,10.0.0.2,54322,10.0.0.1,12345,3,0.0-10.0,1100000000,880000000
EOF
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    if grep -q "DIRECTION_MISSING" "$(results_dir)/iperf_results.csv"; then
        echo "fallback should populate both directions, not leave one missing" >&2
        cat "$(results_dir)/iperf_results.csv" >&2
        return 1
    fi
    local ok
    ok=$(awk -F, 'NR>1 && $4=="OK"' "$(results_dir)/iperf_results.csv" | wc -l)
    assert_eq "2" "$ok" "should have 2 OK rows" || return 1
}

# ---- #6: parse-cpu blanks per-core fields when only "all" rows ------------

test_parse_cpu_blanks_per_core_when_only_all_row() {
    seed_run_dir
    cat > "$(results_dir)/cpu_no-percore_${IPERF_RUN_ID}.log" <<'EOF'
Linux 5.15.0 (host)   01/01/2026  _x86_64_    (1 CPU)

12:00:00     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
12:00:01     all   50.00    0.00   30.00    0.00    0.00   10.00    0.00    0.00    0.00   10.00

12:00:01     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
12:00:02     all   60.00    0.00   25.00    0.00    0.00    8.00    0.00    0.00    0.00    7.00
EOF
    run_orch parse-cpu
    assert_status 0 "$RUN_RC" || return 1
    local csv
    csv="$(results_dir)/cpu_summary.csv"
    local v
    v=$(python3 -c "
import csv
for row in csv.DictReader(open('$csv')):
    if 'no-percore' in row['host']:
        print(repr(row['peak_softirq_pct']), repr(row['peak_idle_floor_pct']))
")
    assert_eq "'' ''" "$v" "per-core fields should be blank when no per-core rows" || return 1
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
run_test test_duplicates_trigger_warning_at_create_scripts
run_test test_no_warning_for_unique_hosts
run_test test_parse_csv_both_ephemeral_ports
run_test test_parse_csv_ip_prefix_addresses
run_test test_parse_csv_picks_sum_row_with_parallel_streams
run_test test_parse_csv_handles_parallel_without_explicit_sum_marker
run_test test_parse_cpu_blanks_per_core_when_only_all_row

report_tests
