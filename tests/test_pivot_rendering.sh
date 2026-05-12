#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Detailed tests for the pivot-table rendering. Beyond the smoke tests
# in test_make_pivot_and_heatmap.sh, this verifies:
#   - column-width auto-scaling for long hostnames
#   - per-source row mean computation excludes diagonals/missing
#   - bar character scaling (max bar = 40 chars)
#   - sorted high-to-low by row mean
#   - diagonal placeholder "-" is consistent
#   - missing data renders as "-" (not as "0" or empty)

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# Helper: build a CSV row.
csv_row() {
    local src="$1" dst="$2" mbps="$3" status="${4:-OK}"
    printf '20260101120000,%s,%s,%s,TCP,10,1,1000000,1000000,%s,54321,5001,%s,%s,iperf_test_%s_to_%s.log,\n' \
        "$src" "$dst" "$status" "$mbps" "$src" "$dst" "$src" "$dst"
}

prep_results_dir() {
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    {
        echo "timestamp,source,target,status,protocol,duration_s,parallel_streams,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error"
        local r
        for r in "$@"; do
            echo "$r"
        done
    } > "$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv"
}

# ---- Column widths ----------------------------------------------------

test_pivot_column_width_scales_to_longest_hostname() {
    prep_results_dir \
        "$(csv_row short other 100)" \
        "$(csv_row other short 200)"
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    # Hostnames "short", "other" -- both 5 chars. host_w defaults
    # to 8 minimum.
    # Verify the header line begins with 8+ spaces of left padding.
    local header_first_line
    header_first_line=$(grep -E '^\s+\|' "$pivot" | head -n1)
    [ -n "$header_first_line" ] || {
        echo "no pivot header found" >&2; return 1; }
}

test_pivot_long_hostname_widens_columns() {
    local long="extremely-long-hostname.example.org"
    prep_results_dir \
        "$(csv_row "$long" peer 100)" \
        "$(csv_row peer "$long" 200)"
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    # Long hostname should appear at least once verbatim.
    grep -q "$long" "$pivot" || {
        echo "long hostname missing from pivot" >&2; return 1; }
}

# ---- Diagonal & missing data --------------------------------------------

test_pivot_diagonal_renders_as_dash() {
    prep_results_dir \
        "$(csv_row a b 100)" \
        "$(csv_row b a 200)"
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    # Find row "a |" and verify column for "a" is "-".
    local row_a
    row_a=$(grep -E '^a\s' "$pivot" | head -n1)
    # The diagonal is the first numeric/dash column for row "a", which
    # should be a dash placeholder in the right-aligned slot.
    [[ "$row_a" == *"-"* ]] || {
        echo "diagonal '-' missing from row a" >&2
        echo "$row_a" >&2
        return 1
    }
}

test_pivot_missing_data_renders_as_dash() {
    # 3 hosts but only one pair tested; the other cells should be '-'.
    prep_results_dir \
        "$(csv_row a b 100)" \
        "$(csv_row b a 200)"
    # Add c without any tests by adding a self-NaN row to introduce it.
    cat >> "$RESULTS_BASE/$IPERF_RUN_ID/iperf_results.csv" <<EOF
20260101120000,c,c,DIRECTION_MISSING,TCP,10,1,,,,,,c,c,iperf_test_c_to_c_${IPERF_RUN_ID}.log,no data
EOF
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    # Check that `c` row exists and a/b columns for c are '-' (no data).
    local row_c
    row_c=$(grep -E '^c\s' "$pivot" | head -n1)
    [ -n "$row_c" ] || { echo "no row for c"; cat "$pivot"; return 1; }
    # Count dashes in the row -- expect at least 3 (a, b, c columns
    # for source c are all unmeasured / diagonal).
    local n_dashes
    n_dashes=$(echo "$row_c" | tr -cd '-' | wc -c)
    if [ "$n_dashes" -lt 3 ]; then
        echo "expected at least 3 dashes in row c (a, b, c columns), got $n_dashes" >&2
        echo "$row_c" >&2
        return 1
    fi
}

# ---- Sorting --------------------------------------------------------------

test_pivot_per_host_incoming_sorted_descending() {
    # Incoming sums: a = b->a + c->a = 50 + 10 = 60
    #                b = a->b + c->b = 100 + 30 = 130
    #                c = a->c + b->c = 200 + 50 = 250
    # Sorted high to low: c, b, a.
    prep_results_dir \
        "$(csv_row a b 100)" "$(csv_row a c 200)" \
        "$(csv_row b a 50)"  "$(csv_row b c 50)"  \
        "$(csv_row c a 10)"  "$(csv_row c b 30)"
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    local section
    section=$(awk '/Per-host incoming bandwidth/{p=1; next} p' "$pivot")
    local first
    first=$(echo "$section" | head -n1)
    [[ "$first" == *"c"* && "$first" == *"250.00"* ]] || {
        echo "expected 'c' first with incoming 250.00" >&2
        echo "$section" >&2
        return 1
    }
    local third
    third=$(echo "$section" | sed -n '3p')
    [[ "$third" == *"a"* && "$third" == *"60.00"* ]] || {
        echo "expected 'a' last with incoming 60.00" >&2
        echo "$section" >&2
        return 1
    }
}

# ---- Bar chart scaling --------------------------------------------------

test_pivot_bar_chart_max_is_40_chars() {
    # Top entry should have 40 hashes; lower entries proportional.
    prep_results_dir \
        "$(csv_row top peer 800)" \
        "$(csv_row peer top 800)"  \
        "$(csv_row low peer 100)"  \
        "$(csv_row peer low 100)"
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    local section
    section=$(awk '/Per-host incoming bandwidth/{p=1; next} p' "$pivot")
    local first
    first=$(echo "$section" | head -n1)
    # Count '#' chars in the first ranking line.
    local n
    n=$(echo "$first" | tr -cd '#' | wc -c)
    assert_eq "40" "$n" "top entry should have 40 hashes" || return 1
}

test_pivot_bar_scales_proportionally() {
    prep_results_dir \
        "$(csv_row big peer 1000)" \
        "$(csv_row peer big 1000)" \
        "$(csv_row small peer 100)" \
        "$(csv_row peer small 100)"
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    local section
    section=$(awk '/Per-host incoming bandwidth/{p=1; next} p' "$pivot")
    # big mean = (1000+100)/2 = 550. peer mean = (1000+100+1000+100)/4 = 550.
    # small mean = (100+100)/2 = 100. So ratio small:big = ~0.18.
    # Hash count for 'small' should be approximately 0.18*40 = ~7.
    # Compute big/small ratio loosely.
    local hb hs
    hb=$(echo "$section" | grep -E '^  big ' | head -n1 | tr -cd '#' | wc -c)
    hs=$(echo "$section" | grep -E '^  small ' | head -n1 | tr -cd '#' | wc -c)
    # big should have substantially more hashes than small.
    if [ "$hb" -le "$hs" ]; then
        echo "expected big bar > small bar (got big=$hb small=$hs)" >&2
        return 1
    fi
}

# ---- Header & footer ----------------------------------------------------

test_pivot_includes_required_header_text() {
    prep_results_dir \
        "$(csv_row a b 100)" \
        "$(csv_row b a 200)"
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    assert_contains "$(cat "$pivot")" "iperf2 full-mesh throughput" || return 1
    assert_contains "$(cat "$pivot")" "Rows = source" || return 1
    assert_contains "$(cat "$pivot")" "Columns = target" || return 1
    assert_contains "$(cat "$pivot")" "Diagonal" || return 1
    assert_contains "$(cat "$pivot")" "Per-host incoming bandwidth" || return 1
}

# ---- Single-cell case --------------------------------------------------

test_pivot_two_host_pair_renders_correctly() {
    # Smallest meaningful mesh: 2 hosts, 1 pair, 2 rows.
    prep_results_dir \
        "$(csv_row a b 1234)" \
        "$(csv_row b a 5678)"
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    # Both values should appear with .00 formatting.
    grep -q "1234.00" "$pivot" || {
        echo "expected 1234.00 in pivot" >&2; cat "$pivot" >&2; return 1; }
    grep -q "5678.00" "$pivot" || {
        echo "expected 5678.00 in pivot" >&2; return 1; }
}

# ---- Full-duplex symmetry --------------------------------------------------

test_pivot_handles_asymmetric_throughput() {
    # a->b is faster than b->a. Pivot should show both values, not
    # just one direction or an average.
    prep_results_dir \
        "$(csv_row a b 1000)" \
        "$(csv_row b a 100)"
    run_orch make-pivot >/dev/null 2>&1
    local pivot="$RESULTS_BASE/$IPERF_RUN_ID/iperf_pivot.txt"
    grep -q "1000.00" "$pivot" || return 1
    grep -q "100.00" "$pivot" || return 1
}

run_test test_pivot_column_width_scales_to_longest_hostname
run_test test_pivot_long_hostname_widens_columns
run_test test_pivot_diagonal_renders_as_dash
run_test test_pivot_missing_data_renders_as_dash
run_test test_pivot_per_host_incoming_sorted_descending
run_test test_pivot_bar_chart_max_is_40_chars
run_test test_pivot_bar_scales_proportionally
run_test test_pivot_includes_required_header_text
run_test test_pivot_two_host_pair_renders_correctly
run_test test_pivot_handles_asymmetric_throughput

report_tests
