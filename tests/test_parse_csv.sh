#!/usr/bin/env bash
# Tests for the embedded Python parser invoked by `parse-csv`. We
# create iperf_test_*.log fixtures in $RESULTS_DIR and invoke the
# subcommand, then assert on the output CSV's structure and values.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

prep_results_dir() {
    mkdir -p "$IPERF_DIR/results"
    echo "$IPERF_DIR/results"
}

# Helper: emit a "good" fixture log with two CSV summary lines (one per
# direction) for pair_a -> pair_b at the given Mbps each.
write_ok_log() {
    local path="$1" pair_a="$2" pair_b="$3" a_to_b_bps="$4" b_to_a_bps="$5"
    local listening_port="${6:-5001}"
    cat > "$path" <<EOF
# pair_a=$pair_a pair_b=$pair_b duration=10 port=$listening_port parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,$listening_port,3,0.0-10.0,${a_to_b_bps}0,${a_to_b_bps}
20260101120000.000,10.0.0.2,$listening_port,10.0.0.1,54321,3,0.0-10.0,${b_to_a_bps}0,${b_to_a_bps}
EOF
}

# Read CSV output via Python so we can index rows by (source, target).
# Outputs key=value lines for the requested (src,dst). Empty stdout if
# the row is missing.
csv_cell() {
    local csv="$1" src="$2" dst="$3" col="$4"
    python3 - "$csv" "$src" "$dst" "$col" <<'PY'
import csv, sys
csv_path, src, dst, col = sys.argv[1:]
with open(csv_path) as f:
    for row in csv.DictReader(f):
        if row["source"] == src and row["target"] == dst:
            print(row.get(col, ""))
            break
PY
}

csv_row_count() {
    python3 -c "
import csv, sys
with open('$1') as f:
    print(sum(1 for _ in csv.DictReader(f)))
"
}

test_parse_csv_no_logs_produces_error() {
    prep_results_dir >/dev/null
    run_orch parse-csv
    # The bash wrapper does NOT propagate the Python exit code, so
    # the overall return is 0; we instead assert the diagnostic
    # message reaches the user and that no CSV was produced.
    assert_contains "$RUN_OUT" "No log files found" || return 1
    [ ! -f "$IPERF_DIR/results/iperf_results.csv" ] || {
        echo "iperf_results.csv should not exist when there were no input logs" >&2
        return 1
    }
}

test_parse_csv_extracts_both_directions() {
    local rd; rd=$(prep_results_dir)
    # 1000 Mbps a->b, 880 Mbps b->a
    write_ok_log "$rd/iperf_test_host-a_to_host-b.log" host-a host-b 1000000000 880000000
    run_orch parse-csv
    assert_status 0 "$RUN_RC" "parse-csv should succeed" || return 1
    local csv="$rd/iperf_results.csv"
    assert_file_exists "$csv" || return 1
    # 1 file -> 2 rows (one per direction).
    local n; n=$(csv_row_count "$csv")
    assert_eq "2" "$n" "one log -> two rows" || return 1

    # a -> b should be 1000 Mbps with status OK
    local mbps status
    mbps=$(csv_cell "$csv" host-a host-b mbps)
    status=$(csv_cell "$csv" host-a host-b status)
    assert_eq "1000.0" "$mbps" "a->b mbps mismatch" || return 1
    assert_eq "OK" "$status" "a->b status should be OK" || return 1

    # b -> a should be 880 Mbps
    mbps=$(csv_cell "$csv" host-b host-a mbps)
    status=$(csv_cell "$csv" host-b host-a status)
    assert_eq "880.0" "$mbps" "b->a mbps mismatch" || return 1
    assert_eq "OK" "$status" "b->a status should be OK" || return 1
}

test_parse_csv_handles_multiple_logs() {
    local rd; rd=$(prep_results_dir)
    write_ok_log "$rd/iperf_test_a_to_b.log" a b 1000000000 900000000
    write_ok_log "$rd/iperf_test_a_to_c.log" a c 800000000  700000000
    write_ok_log "$rd/iperf_test_b_to_c.log" b c 600000000  500000000
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    local csv="$rd/iperf_results.csv"
    local n; n=$(csv_row_count "$csv")
    assert_eq "6" "$n" "3 logs -> 6 rows" || return 1
    # Spot check
    local v
    v=$(csv_cell "$csv" a b mbps); assert_eq "1000.0" "$v" "a->b mbps" || return 1
    v=$(csv_cell "$csv" b c mbps); assert_eq "600.0"  "$v" "b->c mbps" || return 1
    v=$(csv_cell "$csv" c b mbps); assert_eq "500.0"  "$v" "c->b mbps" || return 1
}

test_parse_csv_missing_header_marks_no_header() {
    local rd; rd=$(prep_results_dir)
    # No leading "# pair_a=..." header line.
    cat > "$rd/iperf_test_x_to_y.log" <<'EOF'
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1000,1000
EOF
    run_orch parse-csv
    assert_status 0 "$RUN_RC" "should still produce CSV" || return 1
    local csv="$rd/iperf_results.csv"
    grep -q "NO_HEADER" "$csv" || {
        echo "expected NO_HEADER status row" >&2
        cat "$csv" >&2
        return 1
    }
}

test_parse_csv_missing_summary_marks_no_summary() {
    local rd; rd=$(prep_results_dir)
    cat > "$rd/iperf_test_x_to_y.log" <<'EOF'
# pair_a=x pair_b=y duration=10 port=5001 parallel=1 test_start=1700000000
EOF
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    local csv="$rd/iperf_results.csv"
    # Two NO_SUMMARY rows (one per direction).
    local n
    n=$(grep -c "NO_SUMMARY" "$csv")
    assert_eq "2" "$n" "should emit one NO_SUMMARY per direction" || return 1
}

test_parse_csv_propagates_iperf_error_text() {
    local rd; rd=$(prep_results_dir)
    cat > "$rd/iperf_test_x_to_y.log" <<'EOF'
# pair_a=x pair_b=y duration=10 port=5001 parallel=1 test_start=1700000000
connect failed: Connection refused
EOF
    run_orch parse-csv >/dev/null 2>&1
    local csv="$rd/iperf_results.csv"
    grep -q "Connection refused" "$csv" || {
        echo "iperf error text should appear in CSV" >&2
        cat "$csv" >&2
        return 1
    }
}

test_parse_csv_non_default_port_still_detects_directions() {
    local rd; rd=$(prep_results_dir)
    # Listening on 7777 instead of 5001.
    write_ok_log "$rd/iperf_test_a_to_b.log" a b 100000000 200000000 7777
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    local csv="$rd/iperf_results.csv"
    local v
    v=$(csv_cell "$csv" a b mbps); assert_eq "100.0" "$v" || return 1
    v=$(csv_cell "$csv" b a mbps); assert_eq "200.0" "$v" || return 1
}

test_parse_csv_skips_per_stream_lines_with_parallel_streams() {
    # With -P 4 iperf2 emits per-stream + SUM lines. The parser must
    # only keep full-duration lines. We simulate: 4 stream lines for a
    # short interval (wrong duration) plus one full-duration aggregate
    # per direction.
    local rd; rd=$(prep_results_dir)
    cat > "$rd/iperf_test_a_to_b.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,1,0.0-1.0,12500000,100000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,2,0.0-1.0,12500000,100000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,1100000000,880000000
EOF
    run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    local csv="$rd/iperf_results.csv"
    local v
    v=$(csv_cell "$csv" a b mbps)
    assert_eq "1000.0" "$v" "should pick the 0.0-10.0 aggregate, not 0.0-1.0" || return 1
}

test_parse_csv_sets_csv_built_state() {
    local rd; rd=$(prep_results_dir)
    write_ok_log "$rd/iperf_test_a_to_b.log" a b 1000000000 900000000
    run_orch parse-csv >/dev/null 2>&1
    grep -q '^CSV_BUILT=yes$' "$IPERF_DIR/state" || {
        echo "CSV_BUILT not flagged in state" >&2
        return 1
    }
}

test_parse_csv_includes_required_columns() {
    local rd; rd=$(prep_results_dir)
    write_ok_log "$rd/iperf_test_a_to_b.log" a b 1000000000 900000000
    run_orch parse-csv >/dev/null 2>&1
    local csv="$rd/iperf_results.csv"
    local header
    header=$(head -n1 "$csv")
    for col in timestamp source target status protocol mbps bps pair_a pair_b filename; do
        assert_contains "$header" "$col" "header missing column: $col" || return 1
    done
}

run_test test_parse_csv_no_logs_produces_error
run_test test_parse_csv_extracts_both_directions
run_test test_parse_csv_handles_multiple_logs
run_test test_parse_csv_missing_header_marks_no_header
run_test test_parse_csv_missing_summary_marks_no_summary
run_test test_parse_csv_propagates_iperf_error_text
run_test test_parse_csv_non_default_port_still_detects_directions
run_test test_parse_csv_skips_per_stream_lines_with_parallel_streams
run_test test_parse_csv_sets_csv_built_state
run_test test_parse_csv_includes_required_columns

report_tests
