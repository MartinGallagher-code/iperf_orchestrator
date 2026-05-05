#!/usr/bin/env bash
# Tests for the `results-summary` subcommand: percentile/min/max/mean
# stats and "slowest 5" listing read from results/iperf_results.csv.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# Build a synthetic results CSV with controllable mbps values.
write_results_csv() {
    local csv="$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv"
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    {
        echo "source,target,mbps,error,filename"
        # 10 measured rows: 100, 200, ... 1000 Mbps
        local v
        for v in 100 200 300 400 500 600 700 800 900 1000; do
            printf 's%s,t%s,%s,,iperf_test_s%s_to_t%s.log\n' \
                "$v" "$v" "$v" "$v" "$v"
        done
        # One blank-mbps row should be ignored
        printf 'sX,tX,,READ_ERROR,iperf_test_sX_to_tX_${IPERF_RUN_ID}.log\n'
    } > "$csv"
}

test_results_summary_reports_basic_stats() {
    write_results_csv
    run_orch results-summary
    assert_status 0 "$RUN_RC" "results-summary should exit 0" || return 1
    assert_contains "$RUN_OUT" "min:" "should print min" || return 1
    assert_contains "$RUN_OUT" "P50:" "should print P50" || return 1
    assert_contains "$RUN_OUT" "P95:" "should print P95" || return 1
    assert_contains "$RUN_OUT" "max:" "should print max" || return 1
    assert_contains "$RUN_OUT" "Slowest 5" "should list slowest 5" || return 1
    # min should be 100 Mbps from our synthetic data.
    assert_contains "$RUN_OUT" "100.00" "should report 100 Mbps as min" || return 1
    assert_contains "$RUN_OUT" "1000.00" "should report 1000 Mbps as max" || return 1
}

test_results_summary_dies_without_csv() {
    # Run dir exists but no CSV inside.
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    ln -sfn "$IPERF_RUN_ID" "$RESULTS_BASE/latest"
    run_orch results-summary
    assert_status 1 "$RUN_RC" "should die when CSV missing" || return 1
    assert_contains "$RUN_OUT" "No CSV" "should explain missing CSV" || return 1
}

run_test test_results_summary_reports_basic_stats
run_test test_results_summary_dies_without_csv

report_tests
