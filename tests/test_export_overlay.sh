#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
#
# Tests for `export-overlay`: a run's CSVs rendered as datacenter layout
# viewer overlay samples (`<test> <target> <value> [key=value ...]`).
#
# Two things are worth guarding. The invariant that quietly flatters every
# number if it breaks: a direction that produced no measurement must never
# arrive as 0 Mb/s -- it leaves as iperf_status=FAIL and pulls its host's
# iperf_ok_pct down. And the derived overlays, which are the reason to
# export at all: each one is checked against a hand-computed value here,
# because a wrong ratio is invisible on a floor plan.

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
timestamp,source,target,status,protocol,duration_s,parallel_streams,bind_iface,bind_ip,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error,test_start
20260101120000,hostA,hostB,OK,TCP,10,1,eth0,10.0.0.1,1250000000,1000000000,1000.0,54321,5001,hostA,hostB,a_to_b.log,,1767268800
20260101120000,hostB,hostA,OK,TCP,10,1,eth0,10.0.0.2,1100000000,880000000,880.0,5001,54321,hostA,hostB,a_to_b.log,,1767268800
20260101120000,hostA,hostC,OK,TCP,10,1,eth0,10.0.0.1,1000000000,800000000,800.0,54322,5001,hostA,hostC,a_to_c.log,,1767268800
20260101120000,hostC,hostA,NO_SUMMARY,TCP,10,1,,,,,,5001,54322,hostA,hostC,a_to_c.log,no summary line,1767268800
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
    assert_contains "$body" "!test	iperf_mbps_out" "should declare mbps_out metadata" || return 1
    assert_contains "$body" "iperf_mbps_out	hostA	1000	peer=hostB" "outbound sample" || return 1
    assert_contains "$body" "iperf_mbps_in	hostB	1000	peer=hostA" "the same test seen inbound" || return 1
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
    assert_not_contains "$samples" "iperf_mbps_out	hostC" "the failed direction has no throughput" || return 1
    assert_contains "$samples" "iperf_status	hostC	FAIL" "it becomes a FAIL verdict" || return 1
    assert_contains "$samples" "status=NO_SUMMARY" "carrying the status that explains it" || return 1
    assert_contains "$(cat "$TEST_TMPDIR/err")" "1 direction(s) had no measurement" \
        "and is counted on stderr" || return 1
    # Blank per-core cells in cpu_summary.csv are "not measured" too.
    assert_contains "$samples" "iperf_cpu_peak	hostC	38" "proc_stat host keeps what it has" || return 1
    assert_not_contains "$samples" "iperf_cpu_softirq	hostC" "blank softirq is not exported" || return 1
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
        | samples_of | grep -c '^iperf_mbps_out	hostA	' || true)
    assert_eq "1" "$per_host" "one mbps_out sample per host after --overlay-reduce" || return 1
    # hostA's two outbound directions (1000 and 800) reduce to their median.
    local value
    value=$(bash "$ORCH" export-overlay --overlay-out - --overlay-reduce 2>/dev/null \
        | samples_of | awk -F'\t' '$1=="iperf_mbps_out" && $2=="hostA" {print $3}')
    assert_eq "900" "$value" "median of the directions it measured" || return 1
}

test_export_overlay_maps_and_prefixes_targets() {
    write_csvs
    printf '# test host -> layout element\nhostA DH1/A/R01/u01\nhostB,DH1/A/R01/u02\n' \
        > "$TEST_TMPDIR/map.txt"
    RUN_OUT="$(bash "$ORCH" export-overlay --overlay-out - \
        --overlay-map "$TEST_TMPDIR/map.txt" 2>"$TEST_TMPDIR/err")"
    assert_contains "$RUN_OUT" "iperf_mbps_out	DH1/A/R01/u01" "mapped host is renamed" || return 1
    assert_contains "$(cat "$TEST_TMPDIR/err")" "not in the map file" \
        "hosts missing from the map are reported, not dropped" || return 1
    assert_contains "$RUN_OUT" "hostC" "and are left under their own name" || return 1
    # A peer names another element of the same layout, so it is renamed too.
    assert_contains "$RUN_OUT" "peer=DH1/A/R01/u02" "peers are mapped as well" || return 1

    RUN_OUT="$(bash "$ORCH" export-overlay --overlay-out - --overlay-prefix 'DH1/A/' 2>/dev/null)"
    assert_contains "$RUN_OUT" "iperf_mbps_out	DH1/A/hostA" "prefix reaches every target" || return 1
}

test_export_overlay_writes_ndjson() {
    write_csvs
    local out="$TEST_TMPDIR/overlay.ndjson"
    run_orch export-overlay --overlay-out "$out"
    assert_status 0 "$RUN_RC" "ndjson export should exit 0" || return 1
    local body; body="$(cat "$out")"
    # The extension picks the format; no second flag needed.
    assert_contains "$body" '{"!test": "iperf_mbps_out"' "metadata as a JSON object" || return 1
    assert_contains "$body" '"test": "iperf_mbps_out"' "samples as JSON objects" || return 1
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
    assert_contains "$RUN_OUT" "iperf_mbps_out" "but keeps the samples" || return 1
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
    assert_contains "$RUN_OUT" "iperf_mbps_out	hostA	500" "the measured row is exported" || return 1
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

# The fixture, in numbers, so the expectations below are checkable by hand:
#   measured: A->B 1000, B->A 880, A->C 800     median = 880
#   failed:   C->A (NO_SUMMARY)
#   pair A/B is measured both ways: |1000-880| / 1000 = 12% asymmetry
#   pair A/C is not, so it gets none
#   A sent 2 directions, both measured (100%); C sent 1, which failed (0%)

test_export_overlay_scores_each_direction_against_the_run_median() {
    write_csvs
    local samples
    samples="$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null | samples_of)"
    local fast slow
    fast=$(printf '%s\n' "$samples" | awk -F'\t' '$1=="iperf_rel_median" && $4=="peer=hostB" {print $3}')
    slow=$(printf '%s\n' "$samples" | awk -F'\t' '$1=="iperf_rel_median" && $4=="peer=hostC" {print $3}')
    # 1000/880 and 800/880 of the run's median.
    assert_eq "113.636" "$fast" "the fast direction reads above the median" || return 1
    assert_eq "90.9091" "$slow" "the slow one reads below it" || return 1
}

test_export_overlay_measures_pair_asymmetry_both_ways() {
    write_csvs
    local samples
    samples="$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null | samples_of)"
    assert_contains "$samples" "iperf_asymmetry	hostA	12	peer=hostB" "credited to one end" || return 1
    assert_contains "$samples" "iperf_asymmetry	hostB	12	peer=hostA" "and to the other" || return 1
    # A pair measured in only one direction has no asymmetry to report;
    # inventing one from a single number would be a guess.
    local half
    half=$(printf '%s\n' "$samples" | grep -c '^iperf_asymmetry.*hostC' || true)
    assert_eq "0" "$half" "a pair measured one way only has no asymmetry to report" || return 1
}

test_export_overlay_reports_how_much_of_each_host_measured() {
    write_csvs
    local samples
    samples="$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null | samples_of)"
    # Send and receive are tallied separately and the worse one is reported.
    # hostA sent both its directions fine but only half of what was aimed at
    # it arrived, because hostC could not send.
    assert_contains "$samples" "iperf_ok_pct	hostA	50	sent=2/2	recv=1/2" "the worse of a host's two sides" || return 1
    # hostC receives fine and sends nothing: averaging those halves would
    # report a dead sender as half-well, so the worse side wins.
    assert_contains "$samples" "iperf_ok_pct	hostC	0	sent=0/1	recv=1/1" "a host that cannot send reads zero" || return 1
    assert_contains "$samples" "iperf_ok_pct	hostB	100	sent=1/1	recv=1/1" "a host with nothing wrong reads 100" || return 1
    assert_contains "$samples" "iperf_peers	hostA	2" "and how wide its mesh reached" || return 1
}

test_export_overlay_colours_failures_by_kind() {
    write_csvs
    local samples
    samples="$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null | samples_of)"
    # A second overlay carrying only the failures, valued by why: a rack full
    # of DIRECTION_MISSING is a different problem from one full of READ_ERROR.
    assert_contains "$samples" "iperf_fail_kind	hostC	NO_SUMMARY" "failures carry their kind" || return 1
    local ok_rows
    ok_rows=$(printf '%s\n' "$samples" | grep -c '^iperf_fail_kind.*hostB' || true)
    assert_eq "0" "$ok_rows" "a host with no failures gets no fail_kind sample" || return 1
    # And the verdict sample says what happened and which log to open.
    assert_contains "$samples" "err=no_summary_line" "the error text rides along" || return 1
    assert_contains "$samples" "log=a_to_c.log" "so does the log to open" || return 1
}

test_export_overlay_records_the_bound_interface() {
    write_csvs
    local samples
    samples="$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null | samples_of)"
    # With --bind, half a floor testing over a different NIC than the other
    # half explains an asymmetry you would otherwise chase in the fabric.
    assert_contains "$samples" "iperf_bind_iface	hostA	eth0	peer=hostB	ip=10.0.0.1" \
        "the interface the traffic actually rode" || return 1
}

test_export_overlay_totals_the_duplex_load_per_host() {
    write_csvs
    local samples
    samples="$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null | samples_of)"
    # All four flows share a test window, so they were on the wire together
    # and their rates add: hostA sent 1000 + 800 and received 880.
    assert_contains "$samples" "iperf_mbps_duplex	hostA	2680	flows=3" "concurrent flows add" || return 1
    # hostC only ever received, and that still counts as carried traffic.
    assert_contains "$samples" "iperf_mbps_duplex	hostC	800	flows=1" "receive-only host" || return 1
}

# Rolling mode probes the same pair over and over. Those samples are not
# concurrent, and summing them reports more than the NIC can carry -- the
# mistake that once produced above-line-rate cells in the pivot.
write_rolling_csv() {
    local run_dir; run_dir="$(RUN_DIR)"
    mkdir -p "$run_dir"
    ln -sfn "$IPERF_RUN_ID" "$RESULTS_BASE/latest"
    {
        echo "timestamp,source,target,status,protocol,duration_s,parallel_streams,bind_iface,bind_ip,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error,test_start"
        # Three back-to-back probes of one pair: 10s windows at t, t+20, t+40.
        echo "20260101120000,hostA,hostB,OK,TCP,10,1,,,,,900.0,54321,5001,hostA,hostB,r1.log,,1767268800"
        echo "20260101120020,hostA,hostB,OK,TCP,10,1,,,,,1000.0,54321,5001,hostA,hostB,r2.log,,1767268820"
        echo "20260101120040,hostA,hostB,OK,TCP,10,1,,,,,1100.0,54321,5001,hostA,hostB,r3.log,,1767268840"
    } > "$run_dir/iperf_results.csv"
}

test_export_overlay_never_sums_repeated_probes() {
    write_rolling_csv
    local samples value
    samples="$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null | samples_of)"
    value=$(printf '%s\n' "$samples" | awk -F'\t' '$1=="iperf_mbps_duplex" && $2=="hostA" {print $3}')
    # Each probe ran alone, so the host carried ~1000 Mb/s at a time -- the
    # average across the three windows, never their 3000 Mb/s sum.
    assert_eq "1000" "$value" "repeated probes average, they do not add" || return 1
    # And the pair's two directions are compared as medians, so ordinary
    # probe-to-probe variance is not read as a duplex fault.
    local asym
    asym=$(printf '%s\n' "$samples" | grep -c '^iperf_asymmetry' || true)
    assert_eq "0" "$asym" "one-way pair still reports no asymmetry" || return 1
}

test_export_overlay_omits_duplex_it_cannot_know() {
    # A CSV with no test_start cannot say what was in flight at once, so the
    # overlay is left out rather than guessed at.
    local run_dir; run_dir="$(RUN_DIR)"
    mkdir -p "$run_dir"
    ln -sfn "$IPERF_RUN_ID" "$RESULTS_BASE/latest"
    printf 'source,target,status,mbps,filename\nhostA,hostB,OK,900,a.log\nhostB,hostA,OK,1000,a.log\n' \
        > "$run_dir/iperf_results.csv"
    RUN_OUT="$(bash "$ORCH" export-overlay --overlay-out - 2>"$TEST_TMPDIR/err")"
    assert_not_contains "$RUN_OUT" "iperf_mbps_duplex" "no duplex without test windows" || return 1
    assert_contains "$(cat "$TEST_TMPDIR/err")" "no test_start/duration" "and it says why" || return 1
    assert_contains "$RUN_OUT" "iperf_mbps_out	hostA	900" "the throughput samples still land" || return 1
}

test_export_overlay_keeps_the_cpu_detail_the_csv_carries() {
    write_csvs
    local samples
    samples="$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null | samples_of)"
    assert_contains "$samples" "iperf_cpu_mean	hostA	31.2" "mean CPU, not only the peak" || return 1
    assert_contains "$samples" "iperf_cpu_sys	hostA	20.1" "system time" || return 1
    assert_contains "$samples" "iperf_cpu_user	hostA	18.4" "user time" || return 1
    # Which core saturated, and which parser produced the row, are what turn
    # a high softirq number into an actionable one.
    assert_contains "$samples" "iperf_cpu_softirq	hostA	12.5	src=mpstat	cores=16	core=3" \
        "softirq names its core" || return 1
    assert_contains "$samples" "src=proc_stat" "a fallback-parsed host says so" || return 1
}

test_export_overlay_metadata_pins_percentages_to_a_real_scale() {
    write_csvs
    local meta
    meta="$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null | grep '^!test')"
    # Auto-scaling a percentage makes the highest value look alarming
    # whatever it is; every % overlay states its own 0-100.
    assert_contains "$meta" "iperf_cpu_peak	unit=%	higher=bad	min=0	max=100" "CPU is 0-100" || return 1
    assert_contains "$meta" "iperf_ok_pct	unit=%	higher=good	min=0	max=100" "so is coverage" || return 1
    # On a mesh every host's *worst* direction is the one to the sick host,
    # so aggregating relative throughput with min paints the whole floor red
    # and hides the host that is actually slow. The median separates them.
    assert_contains "$meta" "iperf_rel_median" "relative throughput is declared" || return 1
    local rel_agg
    rel_agg=$(printf '%s\n' "$meta" | awk -F'\t' '$2=="iperf_rel_median"' | grep -o 'agg=[a-z]*')
    assert_eq "agg=median" "$rel_agg" "relative throughput aggregates by median" || return 1
    # The relative overlay diverges around 100%: faster and slower read
    # differently, not just "more is bluer".
    assert_contains "$meta" "palette=rdbu	min=0	max=200" "relative throughput diverges at 100" || return 1
    # Every overlay that got a sample must declare itself, or it renders
    # with a guessed range and no unit.
    local test_names name
    test_names=$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null | samples_of | cut -f1 | sort -u)
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        assert_contains "$meta" "!test	$name	" "$name should have a !test line" || return 1
    done <<< "$test_names"
}

test_export_overlay_header_records_the_run_shape() {
    write_csvs
    local header
    header="$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null | grep '^#')"
    assert_contains "$header" "3 direction(s) measured, 1 with no measurement" "counts in the header" || return 1
    assert_contains "$header" "duration=10s" "the run shape rides in the header, not on every line" || return 1
    # Which means the per-sample metadata stays short.
    local sample
    sample="$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null | samples_of | head -n 1)"
    assert_not_contains "$sample" "dur=10" "an unremarkable duration is not repeated per sample" || return 1
}

test_export_overlay_shows_hosts_that_never_reported() {
    write_csvs
    # hostD is in the server list and appears nowhere in the results: SSH
    # failed, iperf was missing, the host was down. With nothing exported
    # for it the viewer draws it exactly like a host that was never part of
    # the test, which is the one reading that is certainly wrong.
    write_server_list hostA hostB hostC hostD >/dev/null
    local samples err
    samples="$(bash "$ORCH" export-overlay --overlay-out - 2>"$TEST_TMPDIR/err" | samples_of)"
    err="$(cat "$TEST_TMPDIR/err")"
    assert_contains "$samples" "iperf_status	hostD	NO-DATA" "the silent host says so" || return 1
    assert_contains "$samples" "iperf_ok_pct	hostD	0	sent=0/0	recv=0/0" \
        "and reads zero coverage, like every other broken host" || return 1
    assert_contains "$err" "produced no rows at all" "counted on stderr" || return 1
    # It is not invented as a measurement anywhere else.
    local ghost
    ghost=$(printf '%s\n' "$samples" | grep -c '^iperf_mbps.*hostD' || true)
    assert_eq "0" "$ghost" "a silent host gets no throughput samples" || return 1
}

test_export_overlay_scales_absolutely_against_a_line_rate() {
    write_csvs
    local samples meta
    samples="$(bash "$ORCH" export-overlay --overlay-out - --overlay-line-rate 10000 2>/dev/null)"
    meta="$(printf '%s\n' "$samples" | grep '^!test')"
    # Without a line rate the viewer fits its colour ramp to whatever the run
    # produced, so a floor running uniformly at half speed still paints
    # green. A known line rate makes the throughput overlays absolute...
    assert_contains "$meta" "iperf_mbps_out" "throughput overlay is declared" || return 1
    local out_meta
    out_meta=$(printf '%s\n' "$meta" | awk -F'\t' '$2=="iperf_mbps_out"')
    assert_contains "$out_meta" "min=0	max=10000" "throughput is scaled to line rate" || return 1
    out_meta=$(printf '%s\n' "$meta" | awk -F'\t' '$2=="iperf_mbps_duplex"')
    assert_contains "$out_meta" "max=20000" "duplex is scaled to both directions" || return 1
    # ...and adds the utilisation overlay: 1000 of 10000 Mb/s is 10%.
    assert_contains "$(printf '%s\n' "$samples" | samples_of)" "iperf_line_util	hostA	10	peer=hostB" \
        "utilisation against the line rate" || return 1
    # Absent by default: an unknown line rate must not be guessed at.
    assert_not_contains "$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null)" \
        "iperf_line_util" "no utilisation overlay without a line rate" || return 1
}

test_export_overlay_totals_the_data_carried() {
    write_csvs
    local samples
    samples="$(bash "$ORCH" export-overlay --overlay-out - 2>/dev/null | samples_of)"
    # Bytes add over time in a way rates do not, so this total is exact in
    # every mode. hostA carried 1.25 + 1.1 + 1.0 GB across its three flows.
    assert_contains "$samples" "iperf_gbytes	hostA	3.35	flows=3" "total data carried" || return 1
}

run_test test_export_overlay_writes_the_run_directory_file
run_test test_export_overlay_writes_stdout_without_log_noise
run_test test_export_overlay_never_invents_zero_for_a_failed_direction
run_test test_export_overlay_scores_each_direction_against_the_run_median
run_test test_export_overlay_measures_pair_asymmetry_both_ways
run_test test_export_overlay_reports_how_much_of_each_host_measured
run_test test_export_overlay_totals_the_duplex_load_per_host
run_test test_export_overlay_never_sums_repeated_probes
run_test test_export_overlay_omits_duplex_it_cannot_know
run_test test_export_overlay_colours_failures_by_kind
run_test test_export_overlay_records_the_bound_interface
run_test test_export_overlay_shows_hosts_that_never_reported
run_test test_export_overlay_scales_absolutely_against_a_line_rate
run_test test_export_overlay_totals_the_data_carried
run_test test_export_overlay_keeps_the_cpu_detail_the_csv_carries
run_test test_export_overlay_metadata_pins_percentages_to_a_real_scale
run_test test_export_overlay_header_records_the_run_shape
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
