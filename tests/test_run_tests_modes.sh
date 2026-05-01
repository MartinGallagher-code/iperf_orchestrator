#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for the `run-tests` subcommand and its three execution modes:
#   parallel         (sync-start, all hosts simultaneously)
#   sequential-host  (one host at a time)
#   sequential-pair  (one pair at a time, single-target arg)
#
# We don't have a real iperf2 mesh available, so we mock ssh and
# inspect what the orchestrator dispatched -- argument shape,
# concurrency, sequencing.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

prep_workflow() {
    install_fake_ssh
    local src="$TEST_TMPDIR/srv.txt"
    : > "$src"
    local h
    for h in "$@"; do
        printf '%s\n' "$h" >> "$src"
    done
    PATH="$FAKE_BIN:$PATH" run_orch init "$src" >/dev/null 2>&1
    PATH="$FAKE_BIN:$PATH" run_orch create-scripts >/dev/null 2>&1
    PATH="$FAKE_BIN:$PATH" run_orch distribute-scripts >/dev/null 2>&1
    # Reset call log so the prep phase doesn't pollute counts.
    : > "$FAKE_SSH_LOG"
}

# Match only the run_iperf.sh dispatch lines (not chmod/scp lines that
# happen to contain the script name as a path).
run_iperf_dispatch_count() {
    grep -cE "run_iperf\.sh'[[:space:]]+[0-9]+" "$FAKE_SSH_LOG"
}

run_with_fake_path() {
    PATH="$FAKE_BIN:$PATH" run_orch "$@"
}

# Count ssh invocations matching a remote-cmd pattern.
ssh_match_count() {
    local pat="$1"
    grep -c -E "^ssh"$'\t'"[^"$'\t'"]+"$'\t'".*$pat" "$FAKE_SSH_LOG" 2>/dev/null || echo 0
}

test_run_tests_unknown_mode_is_rejected() {
    prep_workflow alpha bravo
    run_with_fake_path run-tests gibberish
    assert_status 1 "$RUN_RC" "unknown mode should die" || return 1
    assert_contains "$RUN_OUT" "Unknown mode" || return 1
}

test_run_tests_parallel_default_mode() {
    prep_workflow alpha bravo charlie
    # Use very short start delay so the test doesn't actually wait.
    run_with_fake_path --start-delay=0 run-tests
    assert_status 0 "$RUN_RC" "parallel mode should succeed" || return 1
    # 3 hosts -> 3 ssh invocations of run_iperf.sh, each with the same
    # epoch timestamp.
    local n
    n=$(run_iperf_dispatch_count)
    assert_eq "3" "$n" "should ssh to all 3 hosts" || return 1
    grep -q '^TESTS_RUN_MODE=parallel$' "$IPERF_DIR/state" || {
        echo "TESTS_RUN_MODE not flagged as parallel" >&2; return 1; }
    grep -q '^TESTS_RUN=yes$' "$IPERF_DIR/state" || {
        echo "TESTS_RUN not flagged" >&2; return 1; }
}

test_run_tests_parallel_uses_synchronized_start() {
    # Every parallel invocation should pass the SAME start_time arg
    # (same epoch). We extract the second positional arg per invocation.
    prep_workflow a b c
    run_with_fake_path --start-delay=5 run-tests parallel
    assert_status 0 "$RUN_RC" || return 1
    local times
    times=$(grep -oE "run_iperf\.sh' [0-9]+" "$FAKE_SSH_LOG" | awk '{print $2}' | sort -u | wc -l)
    assert_eq "1" "$times" "all parallel invocations should share one start_time" || return 1
}

test_run_tests_sequential_host_mode() {
    prep_workflow a b c
    run_with_fake_path run-tests sequential-host
    assert_status 0 "$RUN_RC" "sequential-host should succeed" || return 1
    # All 3 hosts visited exactly once.
    local n
    n=$(run_iperf_dispatch_count)
    assert_eq "3" "$n" || return 1
    # sequential-host passes start_time=0 (no sync).
    if ! grep -qE "run_iperf\.sh' 0$" "$FAKE_SSH_LOG"; then
        echo "expected start_time=0 in sequential-host invocations" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    fi
    grep -q '^TESTS_RUN_MODE=sequential-host$' "$IPERF_DIR/state" || return 1
}

test_run_tests_sequential_pair_mode() {
    # With N=4, parity rule produces 6 canonical pairs. Each pair
    # results in one ssh invocation (the canonical client) carrying
    # the SINGLE_TARGET arg.
    prep_workflow h0 h1 h2 h3
    run_with_fake_path run-tests sequential-pair
    assert_status 0 "$RUN_RC" "sequential-pair should succeed" || return 1
    local n
    n=$(run_iperf_dispatch_count)
    assert_eq "6" "$n" "4 hosts -> 6 canonical pairs" || return 1
    # Every invocation has both the start_time arg AND a single-target
    # arg in quotes: `run_iperf.sh 0 'TARGET'`.
    if ! grep -qE "run_iperf\.sh' 0 '" "$FAKE_SSH_LOG"; then
        echo "expected SINGLE_TARGET arg in sequential-pair calls" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    fi
    grep -q '^TESTS_RUN_MODE=sequential-pair$' "$IPERF_DIR/state" || return 1
}

test_run_tests_dies_with_no_server_list() {
    install_fake_ssh
    # Don't init.
    run_with_fake_path run-tests parallel
    assert_ne 0 "$RUN_RC" "should fail without server list" || return 1
}

test_run_tests_writes_per_host_logs() {
    prep_workflow a b c
    run_with_fake_path --start-delay=0 run-tests parallel >/dev/null
    for h in a b c; do
        assert_file_exists "$IPERF_DIR/logs/run_$h.log" "missing per-host log for $h" || return 1
    done
}

test_run_tests_sequential_host_runs_in_order() {
    # The hosts should be visited in the server-list order. We inspect
    # the order of ssh invocations. (Parallel mode is unordered; this
    # only applies to sequential-host.)
    prep_workflow first second third
    run_with_fake_path run-tests sequential-host >/dev/null
    # Only inspect run_iperf.sh dispatch lines (start_time arg present).
    local order
    order=$(grep -E "run_iperf\.sh'[[:space:]]+[0-9]+" "$FAKE_SSH_LOG" \
            | awk -F'\t' '{print $2}')
    local expected="first
second
third"
    assert_eq "$expected" "$order" "sequential-host should visit hosts in list order" || return 1
}

run_test test_run_tests_unknown_mode_is_rejected
run_test test_run_tests_parallel_default_mode
run_test test_run_tests_parallel_uses_synchronized_start
run_test test_run_tests_sequential_host_mode
run_test test_run_tests_sequential_pair_mode
run_test test_run_tests_dies_with_no_server_list
run_test test_run_tests_writes_per_host_logs
run_test test_run_tests_sequential_host_runs_in_order

report_tests
