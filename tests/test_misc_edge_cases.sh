#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Miscellaneous edge-case tests that don't naturally belong to one of
# the focused test files: CSV parser corner cases, CPU parser corner
# cases, integration probes, robustness against weird input.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

prep_results_dir() {
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    echo "$RESULTS_BASE/$IPERF_RUN_ID"
}

csv_cell() {
    local csv="$1" src="$2" dst="$3" col="$4"
    python3 - "$csv" "$src" "$dst" "$col" <<'PY'
import csv, sys
csv_path, src, dst, col = sys.argv[1:]
with open(csv_path) as f:
    for row in csv.DictReader(f):
        if row["source"] == src and row["target"] == dst:
            print(row.get(col, ""))
            break
PY
}

# ---- CSV parser additional edge cases -------------------------------------

test_parse_csv_handles_zero_throughput() {
    # bps=0 (failed/idle test) should still emit OK rows.
    local rd; rd=$(prep_results_dir)
    cat > "$rd/iperf_test_a_to_b_${IPERF_RUN_ID}.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,0,0
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,0,0
EOF
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    local v
    v=$(csv_cell "$rd/iperf_results.csv" a b mbps)
    assert_eq "0.0" "$v" "zero bps -> 0.0 mbps" || return 1
}

test_parse_csv_handles_scientific_notation_in_bps() {
    # Some iperf2 builds emit scientific-notation bps values.
    local rd; rd=$(prep_results_dir)
    cat > "$rd/iperf_test_a_to_b_${IPERF_RUN_ID}.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1.25e9,1.0e9
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,1.1e9,8.8e8
EOF
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    local v
    v=$(csv_cell "$rd/iperf_results.csv" a b mbps)
    assert_eq "1000.0" "$v" "scientific notation bps should parse" || return 1
}

test_parse_csv_handles_mixed_ok_and_failed_logs() {
    # Two log files: one normal, one with a connection-refused error
    # body and no summary lines. Output should have rows for both.
    local rd; rd=$(prep_results_dir)
    cat > "$rd/iperf_test_a_to_b_${IPERF_RUN_ID}.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,1100000000,880000000
EOF
    cat > "$rd/iperf_test_a_to_c_${IPERF_RUN_ID}.log" <<'EOF'
# pair_a=a pair_b=c duration=10 port=5001 parallel=1 test_start=1700000000
connect failed: Connection refused
EOF
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    local csv="$rd/iperf_results.csv"
    # 4 rows: 2 OK + 2 NO_SUMMARY
    local n_ok n_err
    n_ok=$(awk -F, 'NR>1 && $4=="OK"' "$csv" | wc -l)
    n_err=$(awk -F, 'NR>1 && $4=="NO_SUMMARY"' "$csv" | wc -l)
    assert_eq "2" "$n_ok" "should have 2 OK rows" || return 1
    assert_eq "2" "$n_err" "should have 2 NO_SUMMARY rows" || return 1
    # The error text should be on the failed rows.
    grep -q "Connection refused" "$csv" || {
        echo "expected 'Connection refused' in CSV" >&2
        return 1
    }
}

test_parse_csv_includes_filename_column() {
    local rd; rd=$(prep_results_dir)
    cat > "$rd/iperf_test_a_to_b_${IPERF_RUN_ID}.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,1100000000,880000000
EOF
    run_orch parse-csv >/dev/null 2>&1
    local v
    v=$(csv_cell "$rd/iperf_results.csv" a b filename)
    assert_eq "iperf_test_a_to_b_${IPERF_RUN_ID}.log" "$v" "filename should be the source log" || return 1
}

test_parse_csv_picks_correct_aggregate_when_per_stream_first() {
    # Per-stream rows appear before SUM rows in the iperf2 output;
    # parser should still pick the SUM row regardless of order.
    local rd; rd=$(prep_results_dir)
    cat > "$rd/iperf_test_a_to_b_${IPERF_RUN_ID}.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=2 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,1,0.0-10.0,500000000,400000000
20260101120000.000,10.0.0.1,SUM,10.0.0.2,5001,-1,0.0-10.0,1000000000,800000000
20260101120000.000,10.0.0.1,54322,10.0.0.2,5001,2,0.0-10.0,500000000,400000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,1,0.0-10.0,400000000,320000000
20260101120000.000,10.0.0.2,SUM,10.0.0.1,-1,-1,0.0-10.0,800000000,640000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54322,2,0.0-10.0,400000000,320000000
EOF
    run_orch parse-csv >/dev/null 2>&1
    local v
    v=$(csv_cell "$rd/iperf_results.csv" a b mbps)
    assert_eq "800.0" "$v" "should pick SUM row regardless of position" || return 1
    v=$(csv_cell "$rd/iperf_results.csv" b a mbps)
    assert_eq "640.0" "$v" || return 1
}

# ---- CPU parser additional edge cases -------------------------------------

test_parse_cpu_proc_stat_with_only_one_sample() {
    # Need at least 2 samples to compute a delta. With 1 sample the
    # parser should return None -> PARSE_ERROR row.
    local rd; rd=$(prep_results_dir)
    cat > "$rd/cpu_x_${IPERF_RUN_ID}.log" <<'EOF'
# host=x
# fallback=proc_stat host=x samples=1
2026-01-01 12:00:00
cpu  100 0 50 800 0 0 5 0 0 0
EOF
    run_orch parse-cpu >/dev/null 2>&1
    local v
    v=$(python3 -c "
import csv
for r in csv.DictReader(open('$rd/cpu_summary.csv')):
    if r['host'] == 'x':
        print(r['source'])
")
    assert_eq "PARSE_ERROR" "$v" "single-sample proc_stat should be parse error" || return 1
}

test_parse_cpu_handles_idle_proc_stat_run() {
    # All samples report only idle ticks accumulating. Total cpu work
    # is zero each delta -> "if total <= 0: continue" path.
    local rd; rd=$(prep_results_dir)
    cat > "$rd/cpu_idle_${IPERF_RUN_ID}.log" <<'EOF'
# host=idle
# fallback=proc_stat host=idle samples=3
2026-01-01 12:00:00
cpu  100 0 50 800 0 0 5 0 0 0
2026-01-01 12:00:01
cpu  100 0 50 800 0 0 5 0 0 0
2026-01-01 12:00:02
cpu  100 0 50 800 0 0 5 0 0 0
EOF
    run_orch parse-cpu >/dev/null 2>&1
    # No deltas -> total_pcts empty -> parse_proc_stat_fallback
    # returns None -> PARSE_ERROR.
    grep -q '^idle,PARSE_ERROR' "$rd/cpu_summary.csv" || {
        echo "expected PARSE_ERROR for all-idle proc_stat run" >&2
        cat "$rd/cpu_summary.csv" >&2
        return 1
    }
}

test_parse_cpu_skips_unrelated_files_in_results_dir() {
    # The glob `cpu_*.log` should only pick cpu logs, not stray files.
    local rd; rd=$(prep_results_dir)
    cat > "$rd/cpu_real_${IPERF_RUN_ID}.log" <<'EOF'
# fallback=proc_stat host=real samples=3
2026-01-01 12:00:00
cpu  100 0 50 800 0 0 5 0 0 0
2026-01-01 12:00:01
cpu  120 0 70 850 0 0 10 0 0 0
2026-01-01 12:00:02
cpu  150 0 90 900 0 0 20 0 0 0
EOF
    # Decoy files
    echo "stray data" > "$rd/something_else.log"
    echo "more decoys" > "$rd/iperf_test_x_to_y_${IPERF_RUN_ID}.log"
    run_orch parse-cpu >/dev/null 2>&1
    local n
    n=$(($(wc -l < "$rd/cpu_summary.csv") - 1))
    assert_eq "1" "$n" "only one cpu_*.log -> only one row" || return 1
}

# ---- Robustness / integration ---------------------------------------------

test_status_lists_existing_run_dirs() {
    mkdir -p "$RESULTS_BASE/run-a" "$RESULTS_BASE/run-b"
    ln -sfn run-b "$RESULTS_BASE/latest"
    run_orch status
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "run-a" || return 1
    assert_contains "$RUN_OUT" "run-b" || return 1
    assert_contains "$RUN_OUT" "<- latest" || return 1
}

test_status_works_with_no_runs_yet() {
    # No results subdir at all: status should still succeed and report nothing.
    rm -rf "$RESULTS_BASE"
    run_orch status
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "Runs: (none)" || return 1
}

test_create_scripts_handles_50_hosts() {
    # Stress: large mesh shouldn't fail, and load balance should hold.
    local src="$IPERF_SERVERS"
    : > "$src"
    local i
    for i in $(seq 1 50); do
        printf 'host%02d\n' "$i" >> "$src"
    done
    run_orch create-scripts
    assert_status 0 "$RUN_RC" || return 1
    local n
    n=$(find "$RESULTS_BASE/$IPERF_RUN_ID/scripts" -name 'run_*.sh' | wc -l)
    assert_eq "50" "$n" "50 hosts -> 50 scripts" || return 1
    assert_contains "$RUN_OUT" "min=24" || return 1
    assert_contains "$RUN_OUT" "max=25" || return 1
    assert_contains "$RUN_OUT" "total tests=1225" || return 1
}

test_create_scripts_with_special_hostname_chars() {
    cat > "$IPERF_SERVERS" <<'EOF'
host-01.dc1.example.com
host-02.dc1.example.com
192.168.1.10
EOF
    run_orch create-scripts
    assert_status 0 "$RUN_RC" || return 1
    local sd="$RESULTS_BASE/$IPERF_RUN_ID/scripts"
    [ -f "$sd/run_host-01.dc1.example.com_${IPERF_RUN_ID}.sh" ] || {
        echo "expected script for host-01.dc1.example.com" >&2
        return 1
    }
    [ -f "$sd/run_192.168.1.10_${IPERF_RUN_ID}.sh" ] || {
        echo "expected script for 192.168.1.10" >&2
        return 1
    }
}

test_status_after_no_runs_still_succeeds() {
    # status should never fail, even with no results dir at all.
    rm -rf "$RESULTS_BASE"
    run_orch status
    assert_status 0 "$RUN_RC" || return 1
}

test_validate_uint_helper_rejects_negative_via_dash() {
    # The helper's case pattern '*[!0-9]*' rejects the leading '-'.
    run_orch --port=-1 help
    assert_status 2 "$RUN_RC" "negative integer should be rejected" || return 1
}

test_validate_uint_helper_rejects_leading_plus() {
    # '+5' contains a non-digit '+'; rejected.
    run_orch --duration=+5 help
    assert_status 2 "$RUN_RC" "leading plus should be rejected" || return 1
}

test_validate_uint_helper_rejects_decimals() {
    run_orch --port=80.5 help
    assert_status 2 "$RUN_RC" "decimal should be rejected" || return 1
}

test_jobs_one_is_minimum_acceptable() {
    run_orch --jobs=1 help
    assert_status 0 "$RUN_RC" "--jobs=1 should be accepted" || return 1
}

run_test test_parse_csv_handles_zero_throughput
run_test test_parse_csv_handles_scientific_notation_in_bps
run_test test_parse_csv_handles_mixed_ok_and_failed_logs
run_test test_parse_csv_includes_filename_column
run_test test_parse_csv_picks_correct_aggregate_when_per_stream_first
run_test test_parse_cpu_proc_stat_with_only_one_sample
run_test test_parse_cpu_handles_idle_proc_stat_run
run_test test_parse_cpu_skips_unrelated_files_in_results_dir
run_test test_status_lists_existing_run_dirs
run_test test_status_works_with_no_runs_yet
run_test test_create_scripts_handles_50_hosts
run_test test_create_scripts_with_special_hostname_chars
run_test test_status_after_no_runs_still_succeeds
run_test test_validate_uint_helper_rejects_negative_via_dash
run_test test_validate_uint_helper_rejects_leading_plus
run_test test_validate_uint_helper_rejects_decimals
run_test test_jobs_one_is_minimum_acceptable

report_tests
