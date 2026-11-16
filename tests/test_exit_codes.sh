#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# Fleet commands exit non-zero when a host fails (shared_tools IO-008).
#
# start-servers, stop-servers, distribute-scripts, collect-results and
# cleanup used to print a WARN and exit 0 whatever happened on the hosts,
# and run-tests went on to "Mode: parallel" after distribute-scripts had
# failed on every host, ran nothing, and exited 0. A script or CI job
# calling the step commands could not tell success from failure.
#
# Each test marks h2 unreachable (the stand-in ssh exits 255 for it, as a
# real one does when it cannot connect) and checks the exit status and
# that the WARN names the host. The last test checks that nothing changes
# when every host succeeds. Every test runs under the plain stand-in ssh
# and under the sandbox (run_tests.sh --sandbox).
#
# EXIT_ONLY=<test name> runs just that test (the mutation file,
# test_exit_codes_mutations.sh, uses it).

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

orch() { PATH="$FAKE_BIN:$PATH" run_orch "$@"; }

# Two hosts, h2 unreachable.
h2_down() {
    install_fake_ssh
    write_server_list h1 h2 >/dev/null
    echo h2 > "$FAKE_BIN/unreachable"
}

test_start_servers_exits_nonzero_when_a_host_fails() {
    h2_down
    orch start-servers
    assert_ne 0 "$RUN_RC" "start-servers with h2 unreachable" || return 1
    assert_contains "$RUN_OUT" "start-servers: 1 failure(s) (h2)" || return 1
}

test_stop_servers_exits_nonzero_when_a_host_fails() {
    h2_down
    orch stop-servers
    assert_ne 0 "$RUN_RC" "stop-servers with h2 unreachable" || return 1
    assert_contains "$RUN_OUT" "stop-servers: 1 failure(s) (h2)" || return 1
}

test_stop_exits_nonzero_when_a_host_fails() {
    h2_down
    orch stop
    assert_ne 0 "$RUN_RC" "stop with h2 unreachable" || return 1
    assert_contains "$RUN_OUT" "summarize" "stop should still print its next steps" || return 1
}

test_distribute_scripts_exits_nonzero_when_a_host_fails() {
    h2_down
    orch create-scripts
    orch distribute-scripts
    assert_ne 0 "$RUN_RC" "distribute-scripts with h2 unreachable" || return 1
    assert_contains "$RUN_OUT" "distribute-scripts had 1 failure(s) (h2)" || return 1
}

test_collect_results_exits_nonzero_when_a_host_fails() {
    h2_down
    orch create-scripts
    orch collect-results
    assert_ne 0 "$RUN_RC" "collect-results with h2 unreachable" || return 1
    assert_contains "$RUN_OUT" "h2: could not connect" || return 1
    assert_contains "$RUN_OUT" "collect-results: 1 host(s) had transfer failures (h2)" || return 1
}

test_cleanup_exits_nonzero_when_a_host_fails() {
    h2_down
    orch cleanup --yes
    assert_ne 0 "$RUN_RC" "cleanup with h2 unreachable" || return 1
    assert_contains "$RUN_OUT" "cleanup: 1 failure(s) (h2)" || return 1
}

# Without its script a host cannot run the round: run-tests stops there.
test_run_tests_stops_when_distribution_fails() {
    h2_down
    orch --start-delay 0 --duration 1 run-tests parallel
    assert_ne 0 "$RUN_RC" "run-tests with h2 unreachable" || return 1
    assert_contains "$RUN_OUT" "distribute-scripts failed on 1 host(s)" || return 1
    assert_not_contains "$RUN_OUT" "Mode: parallel" "no round should start" || return 1
}

# ...unless told to keep going, as all and start can be.
test_run_tests_keep_going_runs_the_rest() {
    h2_down
    orch --start-delay 0 --duration 1 run-tests parallel --keep-going
    assert_contains "$RUN_OUT" "continuing without the host(s) that failed distribute-scripts" || return 1
    assert_contains "$RUN_OUT" "Mode: parallel" "the round should run on h1" || return 1
}

# With every host up, nothing changes: each step exits 0 and says nothing
# about failures.
test_every_step_exits_zero_when_every_host_succeeds() {
    install_fake_ssh
    write_server_list h1 h2 >/dev/null
    local step
    for step in start-servers create-scripts distribute-scripts collect-results stop-servers stop "cleanup --yes"; do
        # shellcheck disable=SC2086
        orch $step
        assert_status 0 "$RUN_RC" "$step with every host up: $RUN_OUT" || return 1
        assert_not_contains "$RUN_OUT" "failure(s)" "$step" || return 1
    done
}

EXIT_TESTS=(
    test_start_servers_exits_nonzero_when_a_host_fails
    test_stop_servers_exits_nonzero_when_a_host_fails
    test_stop_exits_nonzero_when_a_host_fails
    test_distribute_scripts_exits_nonzero_when_a_host_fails
    test_collect_results_exits_nonzero_when_a_host_fails
    test_cleanup_exits_nonzero_when_a_host_fails
    test_run_tests_stops_when_distribution_fails
    test_run_tests_keep_going_runs_the_rest
    test_every_step_exits_zero_when_every_host_succeeds
)
for t in "${EXIT_TESTS[@]}"; do
    [ -n "${EXIT_ONLY:-}" ] && [ "$t" != "$EXIT_ONLY" ] && continue
    run_test "$t"
done

report_tests
