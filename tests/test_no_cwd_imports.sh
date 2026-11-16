#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# The embedded Python never imports from the current directory
# (shared_tools ticket IO-010).
#
# Every analysis step runs `"$PYTHON_BIN" - ARGS <<'PYEOF'`, and `doctor`
# runs `"$PYTHON_BIN" -c "import MOD"`. Python puts the current directory
# at the front of sys.path for a script read from stdin or given with -c,
# so a glob.py or csv.py in the directory the tool is run from was
# imported in place of the standard library's: it ran, and then the step
# failed with "module 'glob' has no attribute 'glob'".
#
# Each test runs one step from a directory holding planted modules under
# the names that step imports. A planted module touches a marker file
# named after itself and then raises. The step must succeed and no marker
# may appear.
#
# NOCWD_ONLY=<test name> runs just that test (the mutation file,
# test_no_cwd_imports_mutations.sh, uses it).

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# Modules the analysis steps import that Python has not already loaded by
# the time the script runs (os, sys and io are, so a planted os.py is
# never reached either way). matplotlib and numpy are directories in the
# real thing; a planted .py file of the same name still wins over them
# when the current directory comes first.
PLANTED_MODULES="csv glob re json statistics textwrap collections matplotlib numpy"

# plant DIR: write a hostile module for every name in PLANTED_MODULES.
plant() {
    local dir="$1" mod
    mkdir -p "$dir"
    for mod in $PLANTED_MODULES; do
        cat > "$dir/$mod.py" <<EOF
open("$TEST_TMPDIR/MARK_$mod", "w").close()
raise ImportError("planted $mod.py imported from the current directory")
EOF
    done
}

# no_markers: fail, naming them, if any planted module ran.
no_markers() {
    local found
    found=$(cd "$TEST_TMPDIR" && ls MARK_* 2>/dev/null | tr '\n' ' ')
    if [ -n "$found" ]; then
        echo "planted modules ran: $found" >&2
        return 1
    fi
}

# run_from DIR ARGS...: run the orchestrator with DIR as the current
# directory (RESULTS_BASE and the server list are absolute paths).
run_from() {
    local dir="$1"; shift
    RUN_OUT="$(cd "$dir" && bash "$ORCH" "$@" 2>&1)"
    RUN_RC=$?
    export RUN_OUT RUN_RC
}

run_dir() { echo "$RESULTS_BASE/$IPERF_RUN_ID"; }

write_iperf_log() {
    local path="$1" a="$2" b="$3"
    cat > "$path" <<EOF
# pair_a=$a pair_b=$b duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,1250000000,1000000000
EOF
}

write_cpu_log() {
    local path="$1" host="$2"
    cat > "$path" <<EOF
# host=$host
# fallback=proc_stat host=$host samples=3
2026-01-01 12:00:00
cpu  100 0 50 800 0 0 5 0 0 0
2026-01-01 12:00:01
cpu  120 0 70 850 0 0 10 0 0 0
2026-01-01 12:00:02
cpu  150 0 90 900 0 0 20 0 0 0
EOF
}

write_results_csv() {
    mkdir -p "$(run_dir)"
    cat > "$(run_dir)/iperf_results.csv" <<EOF
source,target,mbps,error,filename
h1,h2,940.5,,iperf_test_h1_to_h2_${IPERF_RUN_ID}.log
h2,h1,910.25,,iperf_test_h1_to_h2_${IPERF_RUN_ID}.log
EOF
}

test_parse_csv_ignores_modules_in_cwd() {
    mkdir -p "$(run_dir)"
    write_iperf_log "$(run_dir)/iperf_test_h1_to_h2_${IPERF_RUN_ID}.log" h1 h2
    plant "$TEST_TMPDIR/cwd"
    run_from "$TEST_TMPDIR/cwd" parse-csv
    no_markers || return 1
    assert_status 0 "$RUN_RC" "parse-csv should succeed: $RUN_OUT" || return 1
    assert_file_exists "$(run_dir)/iperf_results.csv" || return 1
}

test_parse_cpu_ignores_modules_in_cwd() {
    mkdir -p "$(run_dir)"
    write_cpu_log "$(run_dir)/cpu_h1_${IPERF_RUN_ID}.log" h1
    plant "$TEST_TMPDIR/cwd"
    run_from "$TEST_TMPDIR/cwd" parse-cpu
    no_markers || return 1
    assert_status 0 "$RUN_RC" "parse-cpu should succeed: $RUN_OUT" || return 1
    assert_file_exists "$(run_dir)/cpu_summary.csv" || return 1
}

test_make_pivot_ignores_modules_in_cwd() {
    write_results_csv
    plant "$TEST_TMPDIR/cwd"
    run_from "$TEST_TMPDIR/cwd" make-pivot
    no_markers || return 1
    assert_status 0 "$RUN_RC" "make-pivot should succeed: $RUN_OUT" || return 1
    assert_file_exists "$(run_dir)/iperf_pivot.txt" || return 1
    assert_contains "$(cat "$(run_dir)/iperf_pivot.txt")" "h1" "the pivot should name the hosts" || return 1
}

test_make_heatmap_ignores_modules_in_cwd() {
    if ! python3 -c 'import matplotlib, numpy' >/dev/null 2>&1; then
        echo "    SKIP test_make_heatmap_ignores_modules_in_cwd: matplotlib/numpy not installed"
        return 0
    fi
    write_results_csv
    plant "$TEST_TMPDIR/cwd"
    run_from "$TEST_TMPDIR/cwd" make-heatmap
    no_markers || return 1
    assert_status 0 "$RUN_RC" "make-heatmap should succeed: $RUN_OUT" || return 1
}

test_results_summary_ignores_modules_in_cwd() {
    write_results_csv
    plant "$TEST_TMPDIR/cwd"
    run_from "$TEST_TMPDIR/cwd" results-summary
    no_markers || return 1
    assert_status 0 "$RUN_RC" "results-summary should succeed: $RUN_OUT" || return 1
    assert_contains "$RUN_OUT" "P50:" "should print the summary" || return 1
}

test_export_overlay_ignores_modules_in_cwd() {
    write_results_csv
    plant "$TEST_TMPDIR/cwd"
    run_from "$TEST_TMPDIR/cwd" export-overlay
    no_markers || return 1
    assert_status 0 "$RUN_RC" "export-overlay should succeed: $RUN_OUT" || return 1
}

# doctor's module probes are `python3 -c "import MOD"`, which also puts
# the current directory first. A planted numpy.py used to make doctor
# report a module it had not found (and run that file).
test_doctor_ignores_modules_in_cwd() {
    if ! python3 -c 'import matplotlib, numpy' >/dev/null 2>&1; then
        echo "    SKIP test_doctor_ignores_modules_in_cwd: matplotlib/numpy not installed"
        return 0
    fi
    plant "$TEST_TMPDIR/cwd"
    run_from "$TEST_TMPDIR/cwd" doctor
    no_markers || return 1
    assert_contains "$RUN_OUT" "OK  python -m numpy" "the real numpy should be found" || return 1
    assert_contains "$RUN_OUT" "OK  python -m matplotlib" "the real matplotlib should be found" || return 1
}

# The guard drops only the entry Python adds for the current directory. A
# PYTHONPATH the user sets is still honoured (Python makes its entries
# absolute, "." included, so it is the user's own choice of directory).
test_absolute_pythonpath_entries_still_work() {
    write_results_csv
    mkdir -p "$TEST_TMPDIR/abs"
    cat > "$TEST_TMPDIR/abs/statistics.py" <<EOF
open("$TEST_TMPDIR/ABS_USED", "w").close()
from importlib import import_module
import sys
sys.path[:] = [p for p in sys.path if p != "$TEST_TMPDIR/abs"]
del sys.modules["statistics"]
sys.modules["statistics"] = import_module("statistics")
EOF
    mkdir -p "$TEST_TMPDIR/cwd"
    RUN_OUT="$(cd "$TEST_TMPDIR/cwd" && PYTHONPATH="$TEST_TMPDIR/abs" bash "$ORCH" results-summary 2>&1)"
    RUN_RC=$?
    assert_status 0 "$RUN_RC" "results-summary should succeed: $RUN_OUT" || return 1
    assert_file_exists "$TEST_TMPDIR/ABS_USED" || return 1
}

# Every heredoc the analysis path runs starts with the guard, so a new
# step cannot be added without it.
test_every_heredoc_starts_with_the_guard() {
    local missing
    missing=$(awk '
        /<<'"'"'PYEOF'"'"'/ { want = NR + 1; at = NR; next }
        want && NR == want {
            if ($0 !~ /^import sys; sys\.path\[:\] = \[p for p in sys\.path if p not in \("", "\."\)\]/)
                print "line " at
            want = 0
        }' "$ORCH")
    if [ -n "$missing" ]; then
        echo "heredocs without the IO-010 guard as their first line: $missing" >&2
        return 1
    fi
    local n
    n=$(grep -c "<<'PYEOF'" "$ORCH")
    [ "$n" -ge 6 ] || { echo "expected at least 6 PYEOF heredocs, found $n" >&2; return 1; }
}

NOCWD_TESTS=(
    test_parse_csv_ignores_modules_in_cwd
    test_parse_cpu_ignores_modules_in_cwd
    test_make_pivot_ignores_modules_in_cwd
    test_make_heatmap_ignores_modules_in_cwd
    test_results_summary_ignores_modules_in_cwd
    test_export_overlay_ignores_modules_in_cwd
    test_doctor_ignores_modules_in_cwd
    test_absolute_pythonpath_entries_still_work
    test_every_heredoc_starts_with_the_guard
)
for t in "${NOCWD_TESTS[@]}"; do
    [ -n "${NOCWD_ONLY:-}" ] && [ "$t" != "$NOCWD_ONLY" ] && continue
    run_test "$t"
done

report_tests
