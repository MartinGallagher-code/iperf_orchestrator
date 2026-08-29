#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
#
# Tests for `export-overlay`: a run's CSVs rendered as datacenter layout
# viewer overlay samples (`<test> <target> <value> [key=value ...]`).
#
# The invariant worth guarding is the one that quietly flatters every
# number if it breaks: a direction that produced no measurement must never
# arrive as 0 Mb/s. It leaves as an iperf_status=FAIL sample instead.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

RUN_DIR() { echo "$RESULTS_BASE/$IPERF_RUN_ID"; }

# Two hosts, one full-duplex pair (both directions OK), plus one direction
# that failed and one host whose per-core CPU columns are blank.
write_csvs() {
    local run_dir; run_dir="$(RUN_DIR)"
    mkdir -p "$run_dir"
    ln -sfn "$IPERF_RUN_ID" "$RESULTS_BASE/latest"
    cat > "$run_dir/iperf_results.csv" <<'CSV'
timestamp,source,target,status,protocol,duration_s,parallel_streams,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error
20260101120000,hostA,hostB,OK,TCP,10,1,1250000000,1000000000,1000.0,54321,5001,hostA,hostB,a_to_b.log,
20260101120000,hostB,hostA,OK,TCP,10,1,1100000000,880000000,880.0,5001,54321,hostA,hostB,a_to_b.log,
20260101120000,hostA,hostC,OK,TCP,10,1,1000000000,800000000,800.0,54322,5001,hostA,hostC,a_to_c.log,
20260101120000,hostC,hostA,NO_SUMMARY,TCP,10,1,,,,5001,54322,hostA,hostC,a_to_c.log,no summary line
CSV
    cat > "$run_dir/cpu_summary.csv" <<'CSV'
host,source,n_cpus,peak_total_pct,mean_total_pct,peak_softirq_pct,peak_softirq_cpu,peak_sys_pct,peak_user_pct,peak_idle_floor_pct
hostA,mpstat,16,45.0,31.2,12.5,3,20.1,18.4,22.0
hostC,proc_stat,,38.0,25.5,,,15.0,20.0,
CSV
}

# Sample lines only: no comments, no !test metadata.
samples_of() { grep -v '^#' | grep -v '^!test'; }

test_export_overlay_writes_the_run_directory_file() {
    write_csvs
    run_orch export-overlay
    assert_status 0 "$RUN_RC" "export-overlay should exit 0" || return 1
    local out; out="$(RUN_DIR)/iperf_overlay.tsv"
    assert_file_exists "$out" "should write iperf_overlay.tsv into the run dir" || return 1
    local body; body="$(cat "$out")"
    assert_contains "$body" "!test	mbps_out" "should declare mbps_out metadata" || return 1
    assert_contains "$body" "mbps_out	hostA	1000	peer=hostB" "outbound sample" || return 1
    assert_contains "$body" "mbps_in	hostB	1000	peer=hostA" "the same test seen inbound" || return 1
    # Every sample carries its run, which is what keeps appended runs apart.
    assert_contains "$body" "run=$IPERF_RUN_ID" "samples should carry the run id" || return 1
}

test_export_overlay_writes_stdout_without_log_noise() {
    write_csvs
    RUN_OUT="$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null)"
    RUN_RC=$?
    assert_status 0 "$RUN_RC" "stdout export should exit 0" || return 1
    # Nothing but comments, !test lines and samples may reach stdout.
    local stray
    stray=$(printf '%s\n' "$RUN_OUT" | grep -c 'Exporting overlay' || true)
    assert_eq "0" "$stray" "progress logging must not pollute the samples" || return 1
    local fields
    fields=$(printf '%s\n' "$RUN_OUT" | samples_of | head -n 1 | awk -F'\t' '{print NF}')
    [ "${fields:-0}" -ge 3 ] || {
        echo "sample lines should be tab-separated with at least 3 fields" >&2
        return 1
    }
}

test_export_overlay_never_invents_zero_for_a_failed_direction() {
    write_csvs
    RUN_OUT="$(bash "$ORCH" export-overlay --overlay-out - 2>"$TEST_TMPDIR/err")"
    local samples; samples="$(printf '%s\n' "$RUN_OUT" | samples_of)"
    assert_not_contains "$samples" "mbps_out	hostC" "the failed direction has no throughput" || return 1
    assert_contains "$samples" "iperf_status	hostC	FAIL" "it becomes a FAIL verdict" || return 1
    assert_contains "$samples" "status=NO_SUMMARY" "carrying the status that explains it" || return 1
    assert_contains "$(cat "$TEST_TMPDIR/err")" "1 direction(s) had no measurement" \
        "and is counted on stderr" || return 1
    # Blank per-core cells in cpu_summary.csv are "not measured" too.
    assert_contains "$samples" "cpu_peak	hostC	38" "proc_stat host keeps what it has" || return 1
    assert_not_contains "$samples" "cpu_softirq	hostC" "blank softirq is not exported" || return 1
}

test_export_overlay_reduce_collapses_to_one_sample_per_host() {
    write_csvs
    local full reduced
    full=$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null | samples_of | wc -l)
    reduced=$(bash "$ORCH" export-overlay --overlay-out - --overlay-reduce 2>/dev/null | samples_of | wc -l)
    [ "$reduced" -lt "$full" ] || {
        echo "--overlay-reduce should emit fewer samples ($reduced vs $full)" >&2
        return 1
    }
    local per_host
    per_host=$(bash "$ORCH" export-overlay --overlay-out - --overlay-reduce 2>/dev/null \
        | samples_of | grep -c '^mbps_out	hostA	' || true)
    assert_eq "1" "$per_host" "one mbps_out sample per host after --overlay-reduce" || return 1
    # hostA's two outbound directions (1000 and 800) reduce to their median.
    local value
    value=$(bash "$ORCH" export-overlay --overlay-out - --overlay-reduce 2>/dev/null \
        | samples_of | awk -F'\t' '$1=="mbps_out" && $2=="hostA" {print $3}')
    assert_eq "900" "$value" "median of the directions it measured" || return 1
}

test_export_overlay_maps_and_prefixes_targets() {
    write_csvs
    printf '# test host -> layout element\nhostA DH1/A/R01/u01\nhostB,DH1/A/R01/u02\n' \
        > "$TEST_TMPDIR/map.txt"
    RUN_OUT="$(bash "$ORCH" export-overlay --overlay-out - \
        --overlay-map "$TEST_TMPDIR/map.txt" 2>"$TEST_TMPDIR/err")"
    assert_contains "$RUN_OUT" "mbps_out	DH1/A/R01/u01" "mapped host is renamed" || return 1
    assert_contains "$(cat "$TEST_TMPDIR/err")" "not in the map file" \
        "hosts missing from the map are reported, not dropped" || return 1
    assert_contains "$RUN_OUT" "hostC" "and are left under their own name" || return 1
    # A peer names another element of the same layout, so it is renamed too.
    assert_contains "$RUN_OUT" "peer=DH1/A/R01/u02" "peers are mapped as well" || return 1

    RUN_OUT="$(bash "$ORCH" export-overlay --overlay-out - --overlay-prefix 'DH1/A/' 2>/dev/null)"
    assert_contains "$RUN_OUT" "mbps_out	DH1/A/hostA" "prefix reaches every target" || return 1
}

test_export_overlay_writes_ndjson() {
    write_csvs
    local out="$TEST_TMPDIR/overlay.ndjson"
    run_orch export-overlay --overlay-out "$out"
    assert_status 0 "$RUN_RC" "ndjson export should exit 0" || return 1
    local body; body="$(cat "$out")"
    # The extension picks the format; no second flag needed.
    assert_contains "$body" '{"!test": "mbps_out"' "metadata as a JSON object" || return 1
    assert_contains "$body" '"test": "mbps_out"' "samples as JSON objects" || return 1
    assert_contains "$body" '"value": 1000.0' "numbers stay numbers" || return 1
    # One object per line keeps the format append-only.
    local braces; braces=$(grep -c '^{' "$out")
    local lines;  lines=$(grep -vc '^#' "$out")
    assert_eq "$lines" "$braces" "every non-comment line is its own object" || return 1
}

test_export_overlay_appends_instead_of_replacing() {
    write_csvs
    local out="$TEST_TMPDIR/nightly.tsv"
    bash "$ORCH" export-overlay --overlay-out "$out" >/dev/null 2>&1
    local first; first=$(samples_of < "$out" | wc -l)
    bash "$ORCH" export-overlay --overlay-out "$out" --overlay-append >/dev/null 2>&1
    local both; both=$(samples_of < "$out" | wc -l)
    assert_eq "$((first * 2))" "$both" "appending keeps the samples already there" || return 1
    # Without --overlay-append the file is replaced, not grown.
    bash "$ORCH" export-overlay --overlay-out "$out" >/dev/null 2>&1
    local again; again=$(samples_of < "$out" | wc -l)
    assert_eq "$first" "$again" "a plain export replaces the destination" || return 1
}

test_export_overlay_no_meta_omits_the_test_lines() {
    write_csvs
    RUN_OUT="$(bash "$ORCH" export-overlay --overlay-out - --overlay-no-meta 2>/dev/null)"
    assert_not_contains "$RUN_OUT" "!test" "--overlay-no-meta drops the metadata lines" || return 1
    assert_contains "$RUN_OUT" "mbps_out" "but keeps the samples" || return 1
}

test_export_overlay_rejects_an_unknown_format() {
    write_csvs
    run_orch export-overlay --overlay-format xml
    assert_status 1 "$RUN_RC" "an unknown format should fail" || return 1
    assert_contains "$RUN_OUT" "expected 'tsv' or 'ndjson'" "and say what it wanted" || return 1
}

test_export_overlay_dies_without_a_results_csv() {
    mkdir -p "$(RUN_DIR)"
    ln -sfn "$IPERF_RUN_ID" "$RESULTS_BASE/latest"
    run_orch export-overlay
    assert_status 1 "$RUN_RC" "should die when the CSV is missing" || return 1
    assert_contains "$RUN_OUT" "No CSV" "should explain what is missing" || return 1
}

test_export_overlay_reads_a_csv_without_a_status_column() {
    # Hand-made and pre-2.0 CSVs have no status column; there a row that
    # carries a number is a row that succeeded.
    local run_dir; run_dir="$(RUN_DIR)"
    mkdir -p "$run_dir"
    ln -sfn "$IPERF_RUN_ID" "$RESULTS_BASE/latest"
    printf 'source,target,mbps,error,filename\nhostA,hostB,500,,a.log\nhostB,hostA,,READ_ERROR,a.log\n' \
        > "$run_dir/iperf_results.csv"
    RUN_OUT="$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null)"
    assert_contains "$RUN_OUT" "mbps_out	hostA	500" "the measured row is exported" || return 1
    assert_contains "$RUN_OUT" "iperf_status	hostB	FAIL" "the blank one is a FAIL" || return 1
}

test_process_exports_the_overlay_only_when_asked() {
    write_csvs
    # The fleet-facing steps of `process` are stubbed out: what is under
    # test is whether the overlay export is wired into it, not the pipeline.
    cmd_collect_results() { :; }
    cmd_parse_csv()       { :; }
    cmd_parse_cpu()       { :; }
    cmd_make_pivot()      { :; }
    cmd_make_heatmap()    { :; }
    local out; out="$(RUN_DIR)/iperf_overlay.tsv"

    IPERF_OVERLAY=0
    cmd_process >/dev/null 2>&1
    [ ! -f "$out" ] || {
        echo "process should not write an overlay unless asked" >&2
        return 1
    }

    IPERF_OVERLAY=1
    cmd_process >/dev/null 2>&1
    assert_file_exists "$out" "--overlay should export as part of process" || return 1
}

run_test test_export_overlay_writes_the_run_directory_file
run_test test_export_overlay_writes_stdout_without_log_noise
run_test test_export_overlay_never_invents_zero_for_a_failed_direction
run_test test_export_overlay_reduce_collapses_to_one_sample_per_host
run_test test_export_overlay_maps_and_prefixes_targets
run_test test_export_overlay_writes_ndjson
run_test test_export_overlay_appends_instead_of_replacing
run_test test_export_overlay_no_meta_omits_the_test_lines
run_test test_export_overlay_rejects_an_unknown_format
run_test test_export_overlay_dies_without_a_results_csv
run_test test_export_overlay_reads_a_csv_without_a_status_column
run_test test_process_exports_the_overlay_only_when_asked

report_tests
