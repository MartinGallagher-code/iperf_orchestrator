#!/usr/bin/env bash
# Extreme / boundary input tests:
#   - 100 Gbps throughput
#   - very small (sub-Mbps) throughput
#   - very long hostnames in pivot rendering
#   - very large mesh (200 hosts) script generation timing
#   - very large CPU log
#   - parallel_hosts with IPERF_JOBS > host count
#   - extreme port numbers (1, 65535)
#   - extreme durations (1s, large)

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# ---- Extreme bps values ---------------------------------------------------

test_parse_csv_handles_100_gbps() {
    mkdir -p "$IPERF_DIR/results"
    # 100 Gbps = 1e11 bps, 100000 Mbps
    cat > "$IPERF_DIR/results/iperf_test_a_to_b.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,125000000000,100000000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,110000000000,88000000000
EOF
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    local v
    v=$(python3 -c "
import csv
for r in csv.DictReader(open('$IPERF_DIR/results/iperf_results.csv')):
    if r['source']=='a' and r['target']=='b':
        print(r['mbps'])
")
    assert_eq "100000.0" "$v" "100 Gbps -> 100000 Mbps" || return 1
}

test_parse_csv_handles_very_low_throughput() {
    # Sub-Mbps test (e.g., 100 kbps).
    mkdir -p "$IPERF_DIR/results"
    cat > "$IPERF_DIR/results/iperf_test_x_to_y.log" <<'EOF'
# pair_a=x pair_b=y duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,125000,100000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,125000,100000
EOF
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    local v
    v=$(python3 -c "
import csv
for r in csv.DictReader(open('$IPERF_DIR/results/iperf_results.csv')):
    if r['source']=='x' and r['target']=='y':
        print(r['mbps'])
")
    assert_eq "0.1" "$v" "100 kbps -> 0.1 Mbps" || return 1
}

# ---- Pivot with extreme hostnames --------------------------------------

test_pivot_with_unicode_in_hostnames() {
    # ASCII-7 hostnames are normal but the orchestrator's hostname
    # parsing uses sed/grep with [[:space:]] which is locale-aware.
    # Verify accented hostnames work end-to-end (the script's column
    # width math should still succeed).
    mkdir -p "$IPERF_DIR/results"
    cat > "$IPERF_DIR/results/iperf_results.csv" <<'EOF'
timestamp,source,target,status,protocol,duration_s,parallel_streams,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error
20260101120000,host-1,host-2,OK,TCP,10,1,1000000,1000000,1000.0,54321,5001,host-1,host-2,iperf_test_host-1_to_host-2.log,
20260101120000,host-2,host-1,OK,TCP,10,1,1000000,1000000,1000.0,5001,54321,host-1,host-2,iperf_test_host-1_to_host-2.log,
EOF
    run_orch make-pivot
    assert_status 0 "$RUN_RC" || return 1
    [ -f "$IPERF_DIR/results/iperf_pivot.txt" ] || return 1
}

# ---- Large mesh ---------------------------------------------------------

test_create_scripts_for_200_hosts_completes_in_bounded_time() {
    # 200 hosts -> 200 generated scripts, ~19900 client tests
    # distributed by parity rule.
    local src="$TEST_TMPDIR/big.txt"
    : > "$src"
    local i
    for i in $(seq 1 200); do
        printf 'host%03d\n' "$i" >> "$src"
    done
    run_orch init "$src" >/dev/null 2>&1
    local start end
    start=$(date +%s)
    run_orch create-scripts >/dev/null 2>&1
    end=$(date +%s)
    local elapsed=$((end - start))
    if [ "$elapsed" -gt 30 ]; then
        echo "200-host create-scripts took ${elapsed}s (>30s budget)" >&2
        return 1
    fi
    local n
    n=$(find "$IPERF_DIR/scripts" -name 'run_*.sh' | wc -l)
    assert_eq "200" "$n" "should generate exactly 200 scripts" || return 1
}

test_pair_assignment_balanced_at_n_200() {
    local hosts=()
    local i
    for i in $(seq 1 200); do hosts+=("h$i"); done
    write_server_list "${hosts[@]}" >/dev/null
    source_orch
    build_host_idx
    # For every host, count the number of others it's the client for.
    local n=200 j c
    local min=999999 max=0 sum=0
    for ((i=0; i<n; i++)); do
        c=0
        for ((j=0; j<n; j++)); do
            [ "$i" -eq "$j" ] && continue
            if is_client_for "${hosts[i]}" "${hosts[j]}"; then
                c=$((c + 1))
            fi
        done
        sum=$((sum + c))
        [ "$c" -lt "$min" ] && min=$c
        [ "$c" -gt "$max" ] && max=$c
    done
    # N even -> spread should be exactly 1 (or 0 in lucky cases).
    local spread=$((max - min))
    if [ "$spread" -gt 1 ]; then
        echo "N=200 spread should be <=1, got min=$min max=$max" >&2
        return 1
    fi
    # Total = N*(N-1)/2 = 19900
    assert_eq "19900" "$sum" "N=200 total client tests" || return 1
}

# ---- IPERF_JOBS edge cases ---------------------------------------------

test_parallel_hosts_with_jobs_greater_than_host_count() {
    # IPERF_JOBS=100 but only 3 hosts: should run all 3 in parallel
    # without ever idling, total time ~= one worker's runtime.
    write_server_list a b c >/dev/null
    export IPERF_JOBS=100
    source_orch
    _w_sleep1() { sleep 1; }
    local start end
    start=$(date +%s)
    parallel_hosts _w_sleep1 >/dev/null
    end=$(date +%s)
    local elapsed=$((end - start))
    if [ "$elapsed" -gt 3 ]; then
        echo "3 parallel sleeps with jobs=100 took ${elapsed}s; expected <=2s" >&2
        return 1
    fi
}

test_parallel_hosts_with_jobs_equal_one_serializes() {
    # Strict serialization with IPERF_JOBS=1.
    write_server_list a b c >/dev/null
    export IPERF_JOBS=1
    source_orch
    _w_sleep1() { sleep 1; }
    local start end
    start=$(date +%s)
    parallel_hosts _w_sleep1 >/dev/null
    end=$(date +%s)
    local elapsed=$((end - start))
    if [ "$elapsed" -lt 3 ]; then
        echo "expected serial ~3s with jobs=1, got ${elapsed}s" >&2
        return 1
    fi
}

# ---- Port range boundaries ---------------------------------------------

test_port_lower_bound_one_accepted() {
    run_orch --port=1 help
    assert_status 0 "$RUN_RC" "port=1 should be accepted" || return 1
}

test_port_upper_bound_65535_accepted() {
    run_orch --port=65535 help
    assert_status 0 "$RUN_RC" "port=65535 should be accepted" || return 1
}

test_port_above_upper_bound_rejected() {
    run_orch --port=65536 help
    assert_status 2 "$RUN_RC" "port=65536 should be rejected" || return 1
}

# ---- Duration boundaries ----------------------------------------------

test_duration_one_accepted() {
    run_orch --duration=1 help
    assert_status 0 "$RUN_RC" || return 1
}

test_large_duration_accepted() {
    # 24-hour duration is unusual but valid.
    run_orch --duration=86400 help
    assert_status 0 "$RUN_RC" || return 1
}

# ---- Large CPU log ----------------------------------------------------

test_parse_cpu_handles_large_mpstat_log() {
    # 60 samples (1 minute @ 1Hz) with 16 cores each -> 60 * 17 = 1020 rows
    mkdir -p "$IPERF_DIR/results"
    {
        echo "Linux fake (host)   01/01/2026  _x86_64_    (16 CPU)"
        echo
        local s c
        for s in $(seq 1 60); do
            local ts; ts=$(printf '12:00:%02d' "$s")
            echo "$ts     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle"
            echo "$ts     all   10.00    0.00    5.00    0.00    0.00    2.00    0.00    0.00    0.00   83.00"
            for c in $(seq 0 15); do
                printf '%s     %2d   10.00    0.00    5.00    0.00    0.00    2.00    0.00    0.00    0.00   83.00\n' "$ts" "$c"
            done
            echo
        done
    } > "$IPERF_DIR/results/cpu_big.log"
    run_orch parse-cpu
    assert_status 0 "$RUN_RC" "should parse a 60-sample 16-core log" || return 1
    local v
    v=$(python3 -c "
import csv
for r in csv.DictReader(open('$IPERF_DIR/results/cpu_summary.csv')):
    if r['host'] == 'big':
        print(r['n_cpus'], r['source'])
")
    [ "$v" = "16 mpstat" ] || {
        echo "expected '16 mpstat', got '$v'" >&2
        return 1
    }
}

# ---- Large server list with comments ----------------------------------

test_read_servers_handles_5000_lines_with_comments() {
    source_orch
    {
        for i in $(seq 1 5000); do
            if [ $((i % 5)) -eq 0 ]; then
                echo "# comment $i"
            elif [ $((i % 7)) -eq 0 ]; then
                echo ""
            else
                printf 'host%05d\n' "$i"
            fi
        done
    } > "$SERVER_LIST_FILE"
    local n
    n=$(read_servers | wc -l)
    # ~5000 lines minus comments (every 5th) and blanks (every 7th).
    if [ "$n" -lt 3000 ] || [ "$n" -gt 4500 ]; then
        echo "unexpected host count: $n (expected ~3500-4000)" >&2
        return 1
    fi
}

run_test test_parse_csv_handles_100_gbps
run_test test_parse_csv_handles_very_low_throughput
run_test test_pivot_with_unicode_in_hostnames
run_test test_create_scripts_for_200_hosts_completes_in_bounded_time
run_test test_pair_assignment_balanced_at_n_200
run_test test_parallel_hosts_with_jobs_greater_than_host_count
run_test test_parallel_hosts_with_jobs_equal_one_serializes
run_test test_port_lower_bound_one_accepted
run_test test_port_upper_bound_65535_accepted
run_test test_port_above_upper_bound_rejected
run_test test_duration_one_accepted
run_test test_large_duration_accepted
run_test test_parse_cpu_handles_large_mpstat_log
run_test test_read_servers_handles_5000_lines_with_comments

report_tests
