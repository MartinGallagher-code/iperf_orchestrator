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
    assert_contains "$content" "iperf2 full-duplex mesh throughput" || return 1
    assert_contains "$content" "Per-source mean outgoing" || return 1
    # Numeric values should appear (1000.00, 880.00, etc.).
    assert_contains "$content" "1000.00" "expected 1000.00 in pivot" || return 1
    assert_contains "$content" "640.00"  "expected 640.00 in pivot" || return 1
    # Diagonal placeholder
    assert_contains "$content" "-" "diagonal placeholder missing" || return 1
}

test_make_pivot_per_source_mean_ranking() {
    prep_csv
    run_orch make-pivot
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    # Means: a=(1000+800)/2=900, b=(880+640)/2=760, c=(720+600)/2=660.
    # The per-source ranking is the section AFTER "Per-source mean".
    # Find the line numbers of '  a   900.00', '  b   760.00',
    # '  c   660.00' (formatted with leading two spaces by the script).
    local start
    start=$(grep -n "Per-source mean" "$pivot" | head -n1 | cut -d: -f1)
    if [ -z "$start" ]; then
        echo "ranking header not found in pivot" >&2
        cat "$pivot" >&2
        return 1
    fi
    local section
    section=$(tail -n +"$start" "$pivot")
    # First-occurring line numbers within the section.
    local pa pb pc
    pa=$(echo "$section" | grep -nE '^  a[[:space:]]' | head -n1 | cut -d: -f1)
    pb=$(echo "$section" | grep -nE '^  b[[:space:]]' | head -n1 | cut -d: -f1)
    pc=$(echo "$section" | grep -nE '^  c[[:space:]]' | head -n1 | cut -d: -f1)
    if [ -z "$pa" ] || [ -z "$pb" ] || [ -z "$pc" ]; then
        echo "ranking section missing one of a/b/c (a=<$pa> b=<$pb> c=<$pc>)" >&2
        echo "--- section ---" >&2
        echo "$section" >&2
        return 1
    fi
    if [ "$pa" -ge "$pb" ] || [ "$pb" -ge "$pc" ]; then
        echo "expected ranking order a < b < c, got line offsets: a=$pa b=$pb c=$pc" >&2
        return 1
    fi
}

test_make_pivot_writes_pivot_file() {
    prep_csv
    run_orch make-pivot >/dev/null 2>&1
    [ -f "$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt" ] || return 1
}

test_make_pivot_includes_per_server_total_traffic() {
    prep_csv
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    assert_contains "$(cat "$pivot")" "Per-server avg total traffic" \
        "pivot should have per-server total traffic section" || return 1
    assert_contains "$(cat "$pivot")" "out=" \
        "should show out= component" || return 1
    assert_contains "$(cat "$pivot")" "in=" \
        "should show in= component" || return 1
}

test_make_pivot_means_multiple_samples_per_pair() {
    # Rolling mode: same (source, target) appears multiple times. Pivot
    # should report the mean, not the last sample.
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    cat > "$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv" <<EOF
timestamp,source,target,status,protocol,duration_s,parallel_streams,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error
,a,b,OK,TCP,5,1,0,0,1000.0,5001,40000,a,b,r1,
,a,b,OK,TCP,5,1,0,0,2000.0,5001,40000,a,b,r2,
,a,b,OK,TCP,5,1,0,0,3000.0,5001,40000,a,b,r3,
EOF
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    # Mean of 1000, 2000, 3000 = 2000. Should appear; last value (3000) should not.
    grep -q "2000.00" "$pivot" || { echo "expected mean 2000.00"; cat "$pivot" >&2; return 1; }
    # Footer mentions sample count summary when any cell has > 1 sample.
    grep -q "Samples per cell" "$pivot" || { echo "expected samples summary"; return 1; }
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
run_test test_make_pivot_per_source_mean_ranking
run_test test_make_pivot_writes_pivot_file
run_test test_make_pivot_includes_per_server_total_traffic
run_test test_make_pivot_means_multiple_samples_per_pair
run_test test_make_heatmap_requires_csv
run_test test_make_heatmap_produces_png_or_skips_cleanly
run_test test_make_heatmap_missing_dependency_message

report_tests
