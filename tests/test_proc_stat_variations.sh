#!/usr/bin/env bash
# Variations on the /proc/stat fallback parser. The parser walks
# samples and computes per-sample deltas. We exercise:
#   - missing fallback marker -> rejected (returns None)
#   - older kernel format with fewer than 10 fields after "cpu " -> padded
#   - non-numeric junk on a cpu line -> sample skipped
#   - duplicate samples (zero delta) -> skipped, not counted
#   - mixed real + zero-delta samples -> only real samples count

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

prep_results_dir() {
    mkdir -p "$IPERF_DIR/results"
    echo "$IPERF_DIR/results"
}

cpu_cell() {
    local csv="$1" host="$2" col="$3"
    python3 -c "
import csv, sys
csv_path, host, col = sys.argv[1:]
with open(csv_path) as f:
    for row in csv.DictReader(f):
        if row['host'] == host:
            print(row.get(col, ''))
            break
" "$csv" "$host" "$col"
}

# ---- Marker presence -----------------------------------------------------

test_proc_stat_without_fallback_marker_is_rejected() {
    local rd; rd=$(prep_results_dir)
    # Looks like proc_stat samples but no "fallback=proc_stat" header.
    cat > "$rd/cpu_x.log" <<'EOF'
2026-01-01 12:00:00
cpu  100 0 50 800 0 0 5 0 0 0
2026-01-01 12:00:01
cpu  120 0 70 850 0 0 10 0 0 0
EOF
    run_orch parse-cpu >/dev/null 2>&1
    local v
    v=$(cpu_cell "$rd/cpu_summary.csv" x source)
    assert_eq "PARSE_ERROR" "$v" "no fallback marker -> parse error" || return 1
}

# ---- Old-kernel field counts --------------------------------------------

test_proc_stat_older_kernel_format_pads_to_ten_fields() {
    # /proc/stat on older kernels has fewer fields after "cpu". The
    # parser pads to 10 with zeros to keep idle/sys indexing correct.
    local rd; rd=$(prep_results_dir)
    cat > "$rd/cpu_old.log" <<'EOF'
# fallback=proc_stat host=old samples=2
2026-01-01 12:00:00
cpu  100 0 50 800 0 0 5
2026-01-01 12:00:01
cpu  150 0 90 900 0 0 20
EOF
    run_orch parse-cpu >/dev/null 2>&1
    local v
    v=$(cpu_cell "$rd/cpu_summary.csv" old source)
    assert_eq "proc_stat" "$v" "older format should still parse" || return 1
    # peak_total > 0 (real CPU usage).
    v=$(cpu_cell "$rd/cpu_summary.csv" old peak_total_pct)
    case "$v" in
        ''|0|0.0) echo "expected nonzero peak_total, got $v" >&2; return 1 ;;
    esac
}

# ---- Junk lines ----------------------------------------------------------

test_proc_stat_garbage_cpu_line_skipped() {
    # One sample is fine, the other has non-integer values and should
    # be skipped without aborting the whole file.
    local rd; rd=$(prep_results_dir)
    cat > "$rd/cpu_junk.log" <<'EOF'
# fallback=proc_stat host=junk samples=3
2026-01-01 12:00:00
cpu  100 0 50 800 0 0 5 0 0 0
2026-01-01 12:00:01
cpu  120 0 70 abcd 0 0 10 0 0 0
2026-01-01 12:00:02
cpu  150 0 90 900 0 0 20 0 0 0
EOF
    run_orch parse-cpu >/dev/null 2>&1
    local v
    v=$(cpu_cell "$rd/cpu_summary.csv" junk source)
    assert_eq "proc_stat" "$v" "garbage line should be skipped, not abort" || return 1
}

# ---- Zero-delta samples ---------------------------------------------------

test_proc_stat_zero_delta_samples_are_skipped() {
    # Two consecutive identical samples produce zero delta -> filtered
    # out by the "if total <= 0: continue" branch. The third sample
    # has real activity, so the file should produce a valid summary.
    local rd; rd=$(prep_results_dir)
    cat > "$rd/cpu_zd.log" <<'EOF'
# fallback=proc_stat host=zd samples=3
2026-01-01 12:00:00
cpu  100 0 50 800 0 0 5 0 0 0
2026-01-01 12:00:01
cpu  100 0 50 800 0 0 5 0 0 0
2026-01-01 12:00:02
cpu  150 0 90 900 0 0 20 0 0 0
EOF
    run_orch parse-cpu >/dev/null 2>&1
    local v
    v=$(cpu_cell "$rd/cpu_summary.csv" zd source)
    assert_eq "proc_stat" "$v" "should still parse despite zero-delta sample" || return 1
}

# ---- Mixed real-vs-stale samples ----------------------------------------

test_proc_stat_busy_workload_high_peak_total() {
    # Heavy synthetic load: idle barely advances between samples.
    local rd; rd=$(prep_results_dir)
    cat > "$rd/cpu_busy.log" <<'EOF'
# fallback=proc_stat host=busy samples=3
2026-01-01 12:00:00
cpu  100 0 50 800 0 0 5 0 0 0
2026-01-01 12:00:01
cpu  600 0 300 802 0 0 50 0 0 0
2026-01-01 12:00:02
cpu  1100 0 600 805 0 0 100 0 0 0
EOF
    run_orch parse-cpu >/dev/null 2>&1
    local v
    v=$(cpu_cell "$rd/cpu_summary.csv" busy peak_total_pct)
    # peak_total should be very high (> 99%) since idle barely grew.
    python3 -c "exit(0 if float('$v') > 99 else 1)" || {
        echo "expected peak_total_pct > 99%, got $v" >&2
        return 1
    }
}

# ---- Single-sample handling --------------------------------------------

test_proc_stat_single_sample_yields_parse_error() {
    local rd; rd=$(prep_results_dir)
    cat > "$rd/cpu_solo.log" <<'EOF'
# fallback=proc_stat host=solo samples=1
2026-01-01 12:00:00
cpu  100 0 50 800 0 0 5 0 0 0
EOF
    run_orch parse-cpu >/dev/null 2>&1
    local v
    v=$(cpu_cell "$rd/cpu_summary.csv" solo source)
    assert_eq "PARSE_ERROR" "$v" "single sample should produce a parse error" || return 1
}

# ---- Boundary: exactly 2 samples ---------------------------------------

test_proc_stat_two_sample_minimum_works() {
    local rd; rd=$(prep_results_dir)
    cat > "$rd/cpu_two.log" <<'EOF'
# fallback=proc_stat host=two samples=2
2026-01-01 12:00:00
cpu  100 0 50 800 0 0 5 0 0 0
2026-01-01 12:00:01
cpu  150 0 90 900 0 0 20 0 0 0
EOF
    run_orch parse-cpu >/dev/null 2>&1
    local v
    v=$(cpu_cell "$rd/cpu_summary.csv" two source)
    assert_eq "proc_stat" "$v" "two samples is the minimum; should parse" || return 1
}

# ---- All-iowait sample (rare but possible) -----------------------------

test_proc_stat_iowait_only_sample() {
    # Pathological: all the delta is in iowait. peak_user / peak_sys
    # stay at 0, peak_total reflects (total - idle).
    local rd; rd=$(prep_results_dir)
    cat > "$rd/cpu_iow.log" <<'EOF'
# fallback=proc_stat host=iow samples=2
2026-01-01 12:00:00
cpu  100 0 50 800 0 0 5 0 0 0
2026-01-01 12:00:01
cpu  100 0 50 800 1000 0 5 0 0 0
EOF
    run_orch parse-cpu >/dev/null 2>&1
    local v
    v=$(cpu_cell "$rd/cpu_summary.csv" iow source)
    assert_eq "proc_stat" "$v" || return 1
    # peak_user should be 0 (no user-time delta).
    v=$(cpu_cell "$rd/cpu_summary.csv" iow peak_user_pct)
    assert_eq "0.0" "$v" "no user CPU activity -> peak_user=0" || return 1
}

# ---- mpstat-fallback boundary ------------------------------------------

test_proc_stat_log_with_only_marker_no_samples() {
    local rd; rd=$(prep_results_dir)
    cat > "$rd/cpu_marker.log" <<'EOF'
# fallback=proc_stat host=marker samples=0
EOF
    run_orch parse-cpu >/dev/null 2>&1
    local v
    v=$(cpu_cell "$rd/cpu_summary.csv" marker source)
    assert_eq "PARSE_ERROR" "$v" "no samples -> parse error" || return 1
}

run_test test_proc_stat_without_fallback_marker_is_rejected
run_test test_proc_stat_older_kernel_format_pads_to_ten_fields
run_test test_proc_stat_garbage_cpu_line_skipped
run_test test_proc_stat_zero_delta_samples_are_skipped
run_test test_proc_stat_busy_workload_high_peak_total
run_test test_proc_stat_single_sample_yields_parse_error
run_test test_proc_stat_two_sample_minimum_works
run_test test_proc_stat_iowait_only_sample
run_test test_proc_stat_log_with_only_marker_no_samples

report_tests
