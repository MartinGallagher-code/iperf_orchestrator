#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for the mx-style live status ticker (one progress line per host,
# derived from the remote status files) and for the what-next hints that
# results-summary appends to its statistics.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# An ssh shim whose answer to the progress probe differs per host:
#   h1 -> finished (status file ends in DONE)
#   h2 -> never started
#   h3 -> mid-run (status file shows the pair under test)
install_progress_fake_ssh() {
    install_fake_ssh   # provides the scp shim + baseline behaviors
    cat > "$FAKE_BIN/ssh" <<'SHIM'
#!/usr/bin/env bash
set -u
LOG="${FAKE_SSH_LOG:-$(dirname "$0")/calls.log}"
target=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift; [ $# -gt 0 ] && shift ;;
        -[a-zA-Z]) shift ;;
        *@*) target="$1"; shift; break ;;
        *) shift ;;
    esac
done
remote_cmd="$*"
host="${target#*@}"
printf 'ssh\t%s\t%s\n' "$host" "$remote_cmd" >> "$LOG"

case "$remote_cmd" in
    *"iperf_run_"*".status"*)
        case "$host" in
            h1) printf '2|2026-08-19 10:00:12 DONE\n' ;;
            h2) echo 'NOT-STARTED' ;;
            h3) printf '1|2026-08-19 10:00:05 testing -> h1 [h1] (x1)\n' ;;
        esac
        exit 0 ;;
    *"iperf -v"*)
        echo "iperf version 2.1.9 (1 March 2023) pthreads"
        exit 0 ;;
    *"command -v mpstat"*)
        echo "yes"
        exit 0 ;;
    *"pgrep -ax iperf"*|*"pgrep -x iperf"*)
        exit 1 ;;
    *)
        exit 0 ;;
esac
SHIM
    chmod +x "$FAKE_BIN/ssh"
}

# ---- status ticker ---------------------------------------------------------

test_status_shows_one_progress_line_per_host() {
    write_server_list h1 h2 h3 >/dev/null
    install_progress_fake_ssh
    PATH="$FAKE_BIN:$PATH" run_orch status
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "Progress (run test-run):" || return 1
    assert_contains "$RUN_OUT" "DONE" "h1 should report DONE" || return 1
    assert_contains "$RUN_OUT" "NOT-STARTED" "h2 should report NOT-STARTED" || return 1
    assert_contains "$RUN_OUT" "testing -> h1" "h3 should echo its status line" || return 1
}

test_status_progress_shows_expected_totals() {
    write_server_list h1 h2 h3 >/dev/null
    install_progress_fake_ssh
    PATH="$FAKE_BIN:$PATH" run_orch status
    # 3 hosts, host-flows=1 -> each host owes 2 directed tests.
    assert_contains "$RUN_OUT" "2/2 tests" "finished host shows logs/expected" || return 1
    assert_contains "$RUN_OUT" "1/2 tests" "mid-run host shows logs/expected" || return 1
}

test_status_progress_skipped_without_a_run() {
    # No explicit run-id and no latest symlink: nothing to probe.
    write_server_list h1 h2 >/dev/null
    install_progress_fake_ssh
    RUN_OUT="$(env -u IPERF_RUN_ID PATH="$FAKE_BIN:$PATH" bash "$ORCH" status 2>&1)"
    RUN_RC=$?
    assert_status 0 "$RUN_RC" || return 1
    assert_not_contains "$RUN_OUT" "Progress (run" || return 1
}

test_status_mentions_plan_file_state() {
    run_orch status
    assert_contains "$RUN_OUT" "Plan file:" || return 1
}

# ---- results-summary hints -------------------------------------------------

_write_results_csv() {
    # _write_results_csv <mbps triplets: src dst mbps>...
    local out="$RESULTS_BASE/test-run/iperf_results.csv"
    mkdir -p "$RESULTS_BASE/test-run"
    echo "timestamp,source,target,status,protocol,duration_s,parallel_streams,bind_iface,bind_ip,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error,test_start" > "$out"
    while [ $# -ge 3 ]; do
        echo "x,$1,$2,OK,TCP,10,1,,,1,1,$3,5,5001,$1,$2,f,," >> "$out"
        shift 3
    done
}

test_summary_hints_flag_a_slow_outlier_pair() {
    _write_results_csv h1 h2 940.0 h2 h1 900.0 h1 h3 100.0 h3 h1 920.0
    run_orch results-summary
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "What next:" || return 1
    assert_contains "$RUN_OUT" "below" "should call out the below-median pair" || return 1
    assert_contains "$RUN_OUT" "sequential-pair" || return 1
}

test_summary_hints_suggest_raising_a_clean_load() {
    _write_results_csv h1 h2 1000.0 h2 h1 995.0 h1 h3 1005.0 h3 h1 998.0
    run_orch results-summary
    assert_contains "$RUN_OUT" "What next:" || return 1
    assert_contains "$RUN_OUT" "Raise the load" || return 1
}

test_summary_hints_flag_cpu_bound_hosts() {
    _write_results_csv h1 h2 1000.0 h2 h1 995.0
    mkdir -p "$RESULTS_BASE/test-run"
    {
        echo "host,source,n_cpus,peak_total_pct,mean_total_pct,peak_softirq_pct,peak_softirq_cpu,peak_sys_pct,peak_user_pct,peak_idle_floor_pct,filename"
        echo "h2,mpstat,8,96.5,70.0,40.0,3,30.0,20.0,2.0,cpu_h2.log"
    } > "$RESULTS_BASE/test-run/cpu_summary.csv"
    run_orch results-summary
    assert_contains "$RUN_OUT" "h2 peaked at 96% CPU" || return 1
    assert_contains "$RUN_OUT" "CPU-bound" || return 1
}

test_summary_stats_still_lead_the_output() {
    _write_results_csv h1 h2 500.0 h2 h1 400.0
    run_orch results-summary
    assert_contains "$RUN_OUT" "Throughput summary across 2 measured directions" || return 1
    assert_contains "$RUN_OUT" "Slowest 5" || return 1
}

# ---- runner ----------------------------------------------------------------

run_test test_status_shows_one_progress_line_per_host
run_test test_status_progress_shows_expected_totals
run_test test_status_progress_skipped_without_a_run
run_test test_status_mentions_plan_file_state
run_test test_summary_hints_flag_a_slow_outlier_pair
run_test test_summary_hints_suggest_raising_a_clean_load
run_test test_summary_hints_flag_cpu_bound_hosts
run_test test_summary_stats_still_lead_the_output

report_tests
