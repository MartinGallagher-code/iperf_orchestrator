#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for the embedded CPU log parser invoked by `parse-cpu`. Covers
# both mpstat output (with -P ALL, ISO time format) and the proc_stat
# fallback used when mpstat is missing on the remote host.

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
    python3 - "$csv" "$host" "$col" <<'PY'
import csv, sys
csv_path, host, col = sys.argv[1:]
with open(csv_path) as f:
    for row in csv.DictReader(f):
        if row["host"] == host:
            print(row.get(col, ""))
            break
PY
}

# Write an mpstat-style log (4 cores, two samples). ISO time format
# matches what the run script invokes via LC_ALL=C S_TIME_FORMAT=ISO.
write_mpstat_log() {
    local path="$1"
    cat > "$path" <<'EOF'
Linux 5.15.0-100-generic (host-a)   01/01/2026  _x86_64_    (4 CPU)

12:00:00     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
12:00:01     all   10.00    0.00    5.00    0.00    0.00    2.00    0.00    0.00    0.00   83.00
12:00:01       0    8.00    0.00    4.00    0.00    0.00    1.00    0.00    0.00    0.00   87.00
12:00:01       1   12.00    0.00    6.00    0.00    0.00    3.00    0.00    0.00    0.00   79.00
12:00:01       2   11.00    0.00    5.00    0.00    0.00    2.00    0.00    0.00    0.00   82.00
12:00:01       3    9.00    0.00    5.00    0.00    0.00    2.00    0.00    0.00    0.00   84.00

12:00:01     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
12:00:02     all   25.00    0.00   15.00    0.00    0.00    5.00    0.00    0.00    0.00   55.00
12:00:02       0   20.00    0.00   12.00    0.00    0.00    3.00    0.00    0.00    0.00   65.00
12:00:02       1   30.00    0.00   18.00    0.00    0.00   25.00    0.00    0.00    0.00   27.00
12:00:02       2   23.00    0.00   13.00    0.00    0.00    1.00    0.00    0.00    0.00   63.00
12:00:02       3   25.00    0.00   15.00    0.00    0.00    2.00    0.00    0.00    0.00   58.00

Average:     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
Average:     all   17.50    0.00   10.00    0.00    0.00    3.50    0.00    0.00    0.00   69.00
EOF
}

write_proc_stat_log() {
    local path="$1"
    cat > "$path" <<'EOF'
# fallback=proc_stat host=host-b samples=14
2026-01-01 12:00:00
cpu  100 0 50 800 0 0 5 0 0 0
2026-01-01 12:00:01
cpu  120 0 70 850 0 0 10 0 0 0
2026-01-01 12:00:02
cpu  150 0 90 900 0 0 20 0 0 0
EOF
}

test_parse_cpu_no_logs_is_warning_not_failure() {
    prep_results_dir >/dev/null
    run_orch parse-cpu
    assert_status 0 "$RUN_RC" "missing logs should be warning, not error" || return 1
    assert_contains "$RUN_OUT" "No cpu_*.log" || return 1
}

test_parse_cpu_mpstat_summary_values() {
    local rd; rd=$(prep_results_dir)
    write_mpstat_log "$rd/cpu_host-a.log"
    run_orch parse-cpu
    assert_status 0 "$RUN_RC" || return 1
    local csv="$rd/cpu_summary.csv"
    assert_file_exists "$csv" || return 1
    local v
    v=$(cpu_cell "$csv" host-a source);            assert_eq "mpstat" "$v" "source should be mpstat" || return 1
    v=$(cpu_cell "$csv" host-a n_cpus);            assert_eq "4" "$v" "n_cpus should be 4" || return 1
    # peak_total = 100 - min(all %idle) = 100 - 55 = 45.0
    v=$(cpu_cell "$csv" host-a peak_total_pct);    assert_eq "45.0" "$v" "peak_total wrong" || return 1
    # mean_total = ((100-83)+(100-55))/2 = (17+45)/2 = 31.0
    v=$(cpu_cell "$csv" host-a mean_total_pct);    assert_eq "31.0" "$v" "mean_total wrong" || return 1
    # peak_softirq = max %soft over per-core samples = 25.0 (cpu 1, sample 2)
    v=$(cpu_cell "$csv" host-a peak_softirq_pct);  assert_eq "25.0" "$v" "peak_softirq wrong" || return 1
    v=$(cpu_cell "$csv" host-a peak_softirq_cpu);  assert_eq "1" "$v" "peak_softirq_cpu wrong" || return 1
    # peak_sys / peak_user are tracked from the 'all' row.
    v=$(cpu_cell "$csv" host-a peak_sys_pct);      assert_eq "15.0" "$v" "peak_sys wrong" || return 1
    v=$(cpu_cell "$csv" host-a peak_user_pct);     assert_eq "25.0" "$v" "peak_user wrong" || return 1
    # peak_idle_floor_pct = lowest %idle on any core = 27.0 (cpu 1, sample 2)
    v=$(cpu_cell "$csv" host-a peak_idle_floor_pct); assert_eq "27.0" "$v" "peak_idle_floor wrong" || return 1
}

test_parse_cpu_proc_stat_fallback() {
    local rd; rd=$(prep_results_dir)
    write_proc_stat_log "$rd/cpu_host-b.log"
    run_orch parse-cpu
    assert_status 0 "$RUN_RC" || return 1
    local csv="$rd/cpu_summary.csv"
    local v
    v=$(cpu_cell "$csv" host-b source);          assert_eq "proc_stat" "$v" "source should be proc_stat fallback" || return 1
    # Per-core fields should be blank in fallback mode.
    v=$(cpu_cell "$csv" host-b peak_softirq_pct); assert_eq "" "$v" "fallback shouldn't have softirq" || return 1
    v=$(cpu_cell "$csv" host-b peak_idle_floor_pct); assert_eq "" "$v" "fallback shouldn't have per-core idle" || return 1
    # peak_total should be present and >0.
    v=$(cpu_cell "$csv" host-b peak_total_pct)
    case "$v" in
        ''|0|0.0) echo "expected peak_total > 0, got <$v>" >&2; return 1 ;;
    esac
}

test_parse_cpu_handles_both_kinds_in_one_run() {
    local rd; rd=$(prep_results_dir)
    write_mpstat_log    "$rd/cpu_host-a.log"
    write_proc_stat_log "$rd/cpu_host-b.log"
    run_orch parse-cpu
    assert_status 0 "$RUN_RC" || return 1
    local csv="$rd/cpu_summary.csv"
    # Both hosts present, with the right source classification each.
    local va vb
    va=$(cpu_cell "$csv" host-a source)
    vb=$(cpu_cell "$csv" host-b source)
    assert_eq "mpstat" "$va" "host-a should be mpstat" || return 1
    assert_eq "proc_stat" "$vb" "host-b should be proc_stat" || return 1
}

test_parse_cpu_garbage_input_marks_parse_error() {
    local rd; rd=$(prep_results_dir)
    echo "this is neither mpstat nor proc_stat output" > "$rd/cpu_host-c.log"
    run_orch parse-cpu
    assert_status 0 "$RUN_RC" || return 1
    local v
    v=$(cpu_cell "$rd/cpu_summary.csv" host-c source)
    assert_eq "PARSE_ERROR" "$v" "unparseable log should yield PARSE_ERROR row" || return 1
}

test_parse_cpu_sets_state_flag() {
    local rd; rd=$(prep_results_dir)
    write_mpstat_log "$rd/cpu_host-a.log"
    run_orch parse-cpu >/dev/null 2>&1
    grep -q '^CPU_PARSED=yes$' "$IPERF_DIR/state" || {
        echo "CPU_PARSED not flagged in state" >&2
        return 1
    }
}

test_parse_cpu_prints_ranked_table() {
    local rd; rd=$(prep_results_dir)
    write_mpstat_log "$rd/cpu_host-a.log"
    run_orch parse-cpu
    assert_contains "$RUN_OUT" "host" "ranked table header" || return 1
    assert_contains "$RUN_OUT" "peak%" "ranked table column" || return 1
    assert_contains "$RUN_OUT" "host-a" "host-a should appear in ranking" || return 1
}

run_test test_parse_cpu_no_logs_is_warning_not_failure
run_test test_parse_cpu_mpstat_summary_values
run_test test_parse_cpu_proc_stat_fallback
run_test test_parse_cpu_handles_both_kinds_in_one_run
run_test test_parse_cpu_garbage_input_marks_parse_error
run_test test_parse_cpu_sets_state_flag
test_parse_cpu_prefers_host_header_over_filename() {
    # Phase 3: the remote script writes a "# host=<original>" line at the
    # top of cpu_*.log so the parser can recover an unsanitized hostname
    # (e.g. for bracketed IPv6 like [fe80::1]) even though the on-disk
    # filename was rewritten to cpu__fe80__1_.log.
    local rd; rd=$(prep_results_dir)
    local sanitized_path="$rd/cpu__fe80__1_.log"
    local body="$TEST_TMPDIR/mpstat-body.log"
    write_mpstat_log "$body"
    {
        echo "# host=[fe80::1]"
        cat "$body"
    } > "$sanitized_path"
    run_orch parse-cpu
    assert_status 0 "$RUN_RC" || return 1
    local csv="$rd/cpu_summary.csv"
    # Recovered host should be the unsanitized original.
    if ! grep -F -- '[fe80::1]' "$csv" >/dev/null; then
        echo "expected '[fe80::1]' as host in $csv:" >&2
        cat "$csv" >&2
        return 1
    fi
}

test_parse_cpu_falls_back_to_filename_without_header() {
    # Older logs without "# host=" still parse via filename derivation.
    local rd; rd=$(prep_results_dir)
    write_mpstat_log "$rd/cpu_legacy-host.log"
    run_orch parse-cpu
    assert_status 0 "$RUN_RC" || return 1
    local v
    v=$(cpu_cell "$rd/cpu_summary.csv" legacy-host source)
    assert_eq "mpstat" "$v" "filename-derived host should still parse" || return 1
}

run_test test_parse_cpu_prints_ranked_table
run_test test_parse_cpu_prefers_host_header_over_filename
run_test test_parse_cpu_falls_back_to_filename_without_header

report_tests
