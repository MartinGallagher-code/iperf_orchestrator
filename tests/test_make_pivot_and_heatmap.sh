#!/usr/bin/env bash
# Tests for `make-pivot` (text pivot table) and `make-heatmap` (PNG
# render). The heatmap test requires matplotlib + numpy; if missing,
# the heatmap test is skipped (treated as pass with a SKIP note).

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

prep_csv() {
    # Build a small results CSV manually so we don't rely on parse-csv.
    mkdir -p "$IPERF_DIR/results"
    cat > "$IPERF_DIR/results/iperf_results.csv" <<'EOF'
timestamp,source,target,status,protocol,duration_s,parallel_streams,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error
20260101120000,a,b,OK,TCP,10,1,1250000000,1000000000,1000.0,54321,5001,a,b,iperf_test_a_to_b.log,
20260101120000,b,a,OK,TCP,10,1,1100000000,880000000,880.0,5001,54321,a,b,iperf_test_a_to_b.log,
20260101120000,a,c,OK,TCP,10,1,1000000000,800000000,800.0,54322,5001,a,c,iperf_test_a_to_c.log,
20260101120000,c,a,OK,TCP,10,1,900000000,720000000,720.0,5001,54322,a,c,iperf_test_a_to_c.log,
20260101120000,b,c,OK,TCP,10,1,800000000,640000000,640.0,54323,5001,b,c,iperf_test_b_to_c.log,
20260101120000,c,b,OK,TCP,10,1,750000000,600000000,600.0,5001,54323,b,c,iperf_test_b_to_c.log,
EOF
}

test_make_pivot_requires_csv() {
    run_orch make-pivot
    assert_status 1 "$RUN_RC" "should die without CSV" || return 1
    assert_contains "$RUN_OUT" "No CSV" || return 1
}

test_make_pivot_produces_grid() {
    prep_csv
    run_orch make-pivot
    assert_status 0 "$RUN_RC" || return 1
    local pivot="$IPERF_DIR/results/iperf_pivot.txt"
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
    local pivot="$IPERF_DIR/results/iperf_pivot.txt"
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

test_make_pivot_sets_state() {
    prep_csv
    run_orch make-pivot >/dev/null 2>&1
    grep -q '^PIVOT_BUILT=yes$' "$IPERF_DIR/state" || return 1
}

test_make_heatmap_requires_csv() {
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
    local png="$IPERF_DIR/results/iperf_heatmap.png"
    assert_file_exists "$png" || return 1
    # Magic bytes: PNG starts with 0x89 'P' 'N' 'G'
    local sig
    sig=$(head -c 4 "$png" | od -An -c | tr -d ' \n')
    case "$sig" in
        *PNG*) ;;
        *) echo "output is not a PNG (sig=<$sig>)" >&2; return 1 ;;
    esac
    grep -q '^HEATMAP_BUILT=yes$' "$IPERF_DIR/state" || return 1
}

test_make_heatmap_missing_dependency_message() {
    # The orchestrator's bash wrapper does not propagate the embedded
    # Python's exit code, so the overall return is 0 even when the
    # render fails. We instead assert the user-facing diagnostic
    # message and that no PNG was produced.
    if python3 -c 'import matplotlib' >/dev/null 2>&1; then
        echo "    SKIP test_make_heatmap_missing_dependency_message: matplotlib IS installed; can't simulate its absence portably"
        return 0
    fi
    prep_csv
    run_orch make-heatmap
    assert_contains "$RUN_OUT" "Missing Python package" \
        "expected dependency-missing diagnostic" || return 1
    [ ! -f "$IPERF_DIR/results/iperf_heatmap.png" ] || {
        echo "PNG should not exist when matplotlib is missing" >&2
        return 1
    }
}

run_test test_make_pivot_requires_csv
run_test test_make_pivot_produces_grid
run_test test_make_pivot_per_source_mean_ranking
run_test test_make_pivot_sets_state
run_test test_make_heatmap_requires_csv
run_test test_make_heatmap_produces_png_or_skips_cleanly
run_test test_make_heatmap_missing_dependency_message

report_tests
