#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for `make-pivot` (text pivot table) and `make-heatmap` (PNG
# render). The heatmap test requires matplotlib + numpy; if missing,
# the heatmap test is skipped (treated as pass with a SKIP note).

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

prep_csv() {
    # Build a small results CSV manually so we don't rely on parse-csv.
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    cat > "$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv" <<'EOF'
timestamp,source,target,status,protocol,duration_s,parallel_streams,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error
20260101120000,a,b,OK,TCP,10,1,1250000000,1000000000,1000.0,54321,5001,a,b,iperf_test_a_to_b_${IPERF_RUN_ID}.log,
20260101120000,b,a,OK,TCP,10,1,1100000000,880000000,880.0,5001,54321,a,b,iperf_test_a_to_b_${IPERF_RUN_ID}.log,
20260101120000,a,c,OK,TCP,10,1,1000000000,800000000,800.0,54322,5001,a,c,iperf_test_a_to_c_${IPERF_RUN_ID}.log,
20260101120000,c,a,OK,TCP,10,1,900000000,720000000,720.0,5001,54322,a,c,iperf_test_a_to_c_${IPERF_RUN_ID}.log,
20260101120000,b,c,OK,TCP,10,1,800000000,640000000,640.0,54323,5001,b,c,iperf_test_b_to_c_${IPERF_RUN_ID}.log,
20260101120000,c,b,OK,TCP,10,1,750000000,600000000,600.0,5001,54323,b,c,iperf_test_b_to_c_${IPERF_RUN_ID}.log,
EOF
}

test_make_pivot_requires_csv() {
    # Need a results dir to address; it just won't have a CSV in it.
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    ln -sfn "$IPERF_RUN_ID" "$RESULTS_BASE/latest"
    run_orch make-pivot
    assert_status 1 "$RUN_RC" "should die without CSV" || return 1
    assert_contains "$RUN_OUT" "No CSV" || return 1
}

test_make_pivot_produces_grid() {
    prep_csv
    run_orch make-pivot
    assert_status 0 "$RUN_RC" || return 1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    assert_file_exists "$pivot" || return 1
    local content; content=$(cat "$pivot")
    # Header line and the three host columns/rows should appear.
    assert_contains "$content" "iperf2 full-mesh throughput" || return 1
    assert_contains "$content" "Per-host incoming bandwidth" || return 1
    # Numeric values should appear (1000.00, 880.00, etc.).
    assert_contains "$content" "1000.00" "expected 1000.00 in pivot" || return 1
    assert_contains "$content" "640.00"  "expected 640.00 in pivot" || return 1
    # Diagonal placeholder
    assert_contains "$content" "-" "diagonal placeholder missing" || return 1
}

test_make_pivot_per_host_incoming_ranking() {
    prep_csv
    run_orch make-pivot
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    # prep_csv data: a's in = 880 (from b) + 720 (from c) = 1600.
    #                b's in = 1000 (from a) + 600 (from c) = 1600.
    #                c's in = 800 (from a) + 640 (from b) = 1440.
    # Sorted high to low: a (or b), then c. Just verify a, b, c all appear
    # in the section in some order.
    local section
    section=$(awk '/Per-host incoming bandwidth/,/^$/' "$pivot")
    for h in a b c; do
        echo "$section" | grep -qE "^  $h[[:space:]]" || {
            echo "Per-host incoming section missing $h" >&2
            echo "$section" >&2
            return 1
        }
    done
}

test_make_pivot_writes_pivot_file() {
    prep_csv
    run_orch make-pivot >/dev/null 2>&1
    [ -f "$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt" ] || return 1
}

test_make_pivot_annotates_failed_only_cells_with_attempt_count() {
    # For a pair with multiple attempts but no successful samples
    # (every iperf failed), the cell should read "-(N)" instead of "-".
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    cat > "$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv" <<EOF
timestamp,source,target,status,protocol,duration_s,parallel_streams,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error
,a,b,OK,TCP,5,1,0,0,1000.0,5001,40000,a,b,r1,
,a,c,NO_SUMMARY,TCP,5,1,,,,5001,40000,a,c,r2,
,a,c,NO_SUMMARY,TCP,5,1,,,,5001,40000,a,c,r3,
,a,c,NO_SUMMARY,TCP,5,1,,,,5001,40000,a,c,r4,
EOF
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    grep -q -- "-(3)" "$pivot" || {
        echo "expected -(3) annotation for the all-failed cell" >&2
        cat "$pivot" >&2
        return 1
    }
    grep -q "'-(N)'" "$pivot" || {
        echo "expected legend explaining -(N) annotation" >&2
        return 1
    }
}

test_make_pivot_includes_fleet_aggregate_bandwidth() {
    prep_csv
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    assert_contains "$(cat "$pivot")" "Fleet aggregate bandwidth" \
        "pivot should report fleet-wide total" || return 1
    assert_contains "$(cat "$pivot")" "measured flows:" \
        "pivot should report flow count" || return 1
}

test_make_pivot_includes_per_host_incoming_bandwidth() {
    prep_csv
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    assert_contains "$(cat "$pivot")" "Per-host incoming bandwidth" \
        "pivot should have per-host incoming section" || return 1
    # Per-host incoming totals should sum to the fleet aggregate; verify
    # the section reports a value for each source in prep_csv (a,b,c).
    for h in a b c; do
        grep -qE "^  $h[[:space:]]" "$pivot" || {
            echo "expected per-host line for $h" >&2
            cat "$pivot" >&2; return 1
        }
    done
}

test_make_pivot_sums_concurrent_flows() {
    # Three rows with the SAME timestamp = three concurrent flows in
    # the same direction (e.g. --host-flows 3). Each flow runs for 5s.
    # Cell = sum(mbps * duration) / wall_time = 30000 / 5 = 6000 Mbps
    # (the directional total, not the per-flow mean of 2000).
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    cat > "$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv" <<EOF
timestamp,source,target,status,protocol,duration_s,parallel_streams,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error
20260101120000,a,b,OK,TCP,5,1,0,0,1000.0,5001,40000,a,b,r1,
20260101120000,a,b,OK,TCP,5,1,0,0,2000.0,5001,40000,a,b,r2,
20260101120000,a,b,OK,TCP,5,1,0,0,3000.0,5001,40000,a,b,r3,
EOF
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    grep -q "6000.00" "$pivot" || { echo "expected sum 6000.00 (concurrent flows)"; cat "$pivot" >&2; return 1; }
    grep -q "Samples per cell" "$pivot" || { echo "expected samples summary"; return 1; }
}

test_make_pivot_averages_sequential_flows() {
    # Three rows with timestamps 5s apart = three back-to-back flows
    # (e.g. --host-flows 1). Wall-time spans 10 + 5 = 15s. Cell =
    # sum(1000+2000+3000)*5 / 15 = 30000 / 15 = 2000 Mbps (the
    # time-averaged per-flow rate).
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    cat > "$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv" <<EOF
timestamp,source,target,status,protocol,duration_s,parallel_streams,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error
20260101120000,a,b,OK,TCP,5,1,0,0,1000.0,5001,40000,a,b,r1,
20260101120005,a,b,OK,TCP,5,1,0,0,2000.0,5001,40000,a,b,r2,
20260101120010,a,b,OK,TCP,5,1,0,0,3000.0,5001,40000,a,b,r3,
EOF
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    grep -q "2000.00" "$pivot" || { echo "expected mean 2000.00 (sequential flows)"; cat "$pivot" >&2; return 1; }
}

test_make_pivot_parallel_header_comes_from_csv_not_env() {
    # The "Parallel: N" line in the pivot header must reflect what
    # actually ran (recorded in iperf_results.csv parallel_streams),
    # not the orchestrator's current IPERF_STREAMS env. Otherwise a
    # standalone `make-pivot` shows whatever the user happens to type.
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    cat > "$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv" <<EOF
timestamp,source,target,status,protocol,duration_s,parallel_streams,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error
20260101120000,a,b,OK,TCP,30,8,0,0,1000.0,5001,40000,a,b,r,
20260101120000,b,a,OK,TCP,30,8,0,0,1000.0,5001,40000,a,b,r,
EOF
    # IPERF_STREAMS deliberately set to a different value.
    IPERF_STREAMS=1 run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    grep -qE "Parallel:[[:space:]]+8" "$pivot" || {
        echo "pivot Parallel: should read '8' from CSV, not '1' from env" >&2
        grep -E "^Mode:|Parallel:" "$pivot" >&2
        return 1
    }
}

test_make_pivot_duration_and_port_come_from_csv_not_env() {
    # Same idea for Duration / Port — derived from the run's data.
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    cat > "$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv" <<EOF
timestamp,source,target,status,protocol,duration_s,parallel_streams,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error
20260101120000,a,b,OK,TCP,42,1,0,0,1000.0,7777,7777,a,b,r,
20260101120000,b,a,OK,TCP,42,1,0,0,1000.0,7777,7777,a,b,r,
EOF
    IPERF_DURATION=10 IPERF_PORT=5001 run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    grep -qE "Duration:[[:space:]]+42s" "$pivot" || {
        echo "Duration should be 42s from CSV"; grep "Duration" "$pivot" >&2; return 1
    }
    grep -qE "Port:[[:space:]]+7777" "$pivot" || {
        echo "Port should be 7777 from CSV"; grep "Port" "$pivot" >&2; return 1
    }
}

test_make_pivot_shows_gbs_alongside_mbps() {
    # Both Per-host incoming bandwidth and Fleet aggregate should
    # show GB/s next to Mbps. Conversion is decimal: 8000 Mbps = 1 GB/s.
    # Four directional flows of 8000 Mbps each:
    #   a's incoming = 8000 (from b) + 8000 (from c) = 16000 Mbps = 2.000 GB/s
    #   b's incoming = 8000 (from a) = 8000 Mbps = 1.000 GB/s
    #   c's incoming = 8000 (from a) = 8000 Mbps = 1.000 GB/s
    # Sum = 32000 Mbps = 4.000 GB/s = fleet aggregate.
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    cat > "$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv" <<EOF
timestamp,source,target,status,protocol,duration_s,parallel_streams,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error
20260101120000,a,b,OK,TCP,10,1,0,0,8000.0,5001,40000,a,b,r,
20260101120000,b,a,OK,TCP,10,1,0,0,8000.0,5001,40000,a,b,r,
20260101120000,a,c,OK,TCP,10,1,0,0,8000.0,5001,40000,a,c,r,
20260101120000,c,a,OK,TCP,10,1,0,0,8000.0,5001,40000,a,c,r,
EOF
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    grep -q "Per-host incoming bandwidth" "$pivot" || return 1
    awk '/Per-host incoming bandwidth/,/^$/' "$pivot" | grep -q "GB/s" || {
        echo "per-host incoming section missing GB/s annotation" >&2
        awk '/Per-host incoming bandwidth/,/^$/' "$pivot" >&2
        return 1
    }
    # a's incoming should be 16000 Mbps = 2.000 GB/s.
    awk '/Per-host incoming bandwidth/,/^$/' "$pivot" | grep -qE "^  a[[:space:]]+16000\.00 Mbps[[:space:]]+\([[:space:]]*2\.000 GB/s\)" || {
        echo "expected 'a 16000.00 Mbps (2.000 GB/s)' line" >&2
        awk '/Per-host incoming bandwidth/,/^$/' "$pivot" >&2
        return 1
    }
    grep -q "Fleet aggregate bandwidth" "$pivot" || return 1
    # Fleet aggregate line should have both Mbps and GB/s.
    grep -E "Fleet aggregate.*Mbps.*GB/s" "$pivot" >/dev/null || {
        echo "fleet aggregate missing GB/s annotation" >&2
        grep -E "Fleet aggregate" "$pivot" >&2
        return 1
    }
    # Specific value: fleet total = 32000 Mbps -> 4.000 GB/s
    grep -q "4.000 GB/s" "$pivot" || {
        echo "expected 4.000 GB/s (32000 Mbps) in fleet aggregate" >&2
        grep -E "Fleet aggregate" "$pivot" >&2
        return 1
    }
}

test_make_pivot_source_bindings_section_when_bind_data_present() {
    # When iperf_results.csv has bind_iface/bind_ip values, the pivot
    # gains a "Source bindings" section listing each source's resolved
    # interface and IP. The mapping is keyed off rows where source ==
    # pair_a (the originating host) so DIRECTION_MISSING placeholders
    # from the other side's log don't clobber it.
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    cat > "$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv" <<EOF
timestamp,source,target,status,protocol,duration_s,parallel_streams,bind_iface,bind_ip,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error
20260101120000,a,b,OK,TCP,10,1,bond0,10.10.5.41,0,0,1000.0,5001,40000,a,b,r1,
20260101120000,b,a,OK,TCP,10,1,bond0,10.10.5.41,0,0,1000.0,5001,40000,a,b,r1,
20260101120000,b,a,OK,TCP,10,1,bond0,10.10.5.42,0,0,900.0,5001,40000,b,a,r2,
20260101120000,a,b,OK,TCP,10,1,bond0,10.10.5.42,0,0,900.0,5001,40000,b,a,r2,
EOF
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    grep -q "Source bindings" "$pivot" || {
        echo "expected Source bindings section" >&2; cat "$pivot" >&2; return 1
    }
    # Source 'a' is pair_a in row 1 -> iface=bond0 ip=10.10.5.41
    grep -qE "^  a[[:space:]]+iface=bond0 ip=10\.10\.5\.41$" "$pivot" || {
        echo "expected 'a iface=bond0 ip=10.10.5.41'" >&2
        grep -A 5 "Source bindings" "$pivot" >&2
        return 1
    }
    # Source 'b' is pair_a in row 3 -> iface=bond0 ip=10.10.5.42
    grep -qE "^  b[[:space:]]+iface=bond0 ip=10\.10\.5\.42$" "$pivot" || {
        echo "expected 'b iface=bond0 ip=10.10.5.42'" >&2
        grep -A 5 "Source bindings" "$pivot" >&2
        return 1
    }
}

test_make_pivot_no_source_bindings_section_when_unused() {
    # If --bind wasn't used, bind_iface/bind_ip are empty for every
    # row and the section must be omitted entirely.
    prep_csv      # the no-bind fixture
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    if grep -q "Source bindings" "$pivot"; then
        echo "Source bindings should not appear when --bind wasn't used" >&2
        grep -A 3 "Source bindings" "$pivot" >&2
        return 1
    fi
}

test_make_heatmap_requires_csv() {
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    ln -sfn "$IPERF_RUN_ID" "$RESULTS_BASE/latest"
    run_orch make-heatmap
    assert_status 1 "$RUN_RC" "should die without CSV" || return 1
}

test_make_heatmap_produces_png_or_skips_cleanly() {
    prep_csv
    # Probe matplotlib up front: skip if not installed.
    if ! python3 -c 'import matplotlib, numpy' >/dev/null 2>&1; then
        echo "    SKIP test_make_heatmap_produces_png_or_skips_cleanly: matplotlib/numpy not installed"
        return 0
    fi
    run_orch make-heatmap
    assert_status 0 "$RUN_RC" "make-heatmap should succeed when matplotlib present" || return 1
    local png="$RESULTS_BASE/$IPERF_RUN_ID/iperf_heatmap.png"
    assert_file_exists "$png" || return 1
    # Magic bytes: PNG starts with 0x89 'P' 'N' 'G'
    local sig
    sig=$(head -c 4 "$png" | od -An -c | tr -d ' \n')
    case "$sig" in
        *PNG*) ;;
        *) echo "output is not a PNG (sig=<$sig>)" >&2; return 1 ;;
    esac
    [ -f "$RESULTS_BASE/$IPERF_RUN_ID/iperf_heatmap.png" ] || return 1
}

test_make_heatmap_missing_dependency_message() {
    # The wrapper now propagates the embedded Python's exit code, so
    # we expect a non-zero status, the dep-missing diagnostic, no PNG,
    # and no false HEATMAP_BUILT=yes flag.
    if python3 -c 'import matplotlib' >/dev/null 2>&1; then
        echo "    SKIP test_make_heatmap_missing_dependency_message: matplotlib IS installed; can't simulate its absence portably"
        return 0
    fi
    prep_csv
    run_orch make-heatmap
    assert_ne 0 "$RUN_RC" "should fail when matplotlib unavailable" || return 1
    assert_contains "$RUN_OUT" "Missing Python package" \
        "expected dependency-missing diagnostic" || return 1
    [ ! -f "$RESULTS_BASE/$IPERF_RUN_ID/iperf_heatmap.png" ] || {
        echo "PNG should not exist when matplotlib is missing" >&2
        return 1
    }
}

run_test test_make_pivot_requires_csv
run_test test_make_pivot_produces_grid
run_test test_make_pivot_per_host_incoming_ranking
run_test test_make_pivot_writes_pivot_file
run_test test_make_pivot_annotates_failed_only_cells_with_attempt_count
run_test test_make_pivot_includes_per_host_incoming_bandwidth
run_test test_make_pivot_includes_fleet_aggregate_bandwidth
run_test test_make_pivot_sums_concurrent_flows
run_test test_make_pivot_averages_sequential_flows
run_test test_make_pivot_parallel_header_comes_from_csv_not_env
run_test test_make_pivot_duration_and_port_come_from_csv_not_env
run_test test_make_pivot_shows_gbs_alongside_mbps
run_test test_make_pivot_source_bindings_section_when_bind_data_present
run_test test_make_pivot_no_source_bindings_section_when_unused
run_test test_make_heatmap_requires_csv
run_test test_make_heatmap_produces_png_or_skips_cleanly
run_test test_make_heatmap_missing_dependency_message

report_tests
