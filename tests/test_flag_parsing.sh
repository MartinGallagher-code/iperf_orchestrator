#!/usr/bin/env bash
# Tests for the CLI flag pre-pass: --flag value vs --flag=value forms,
# unknown flags, missing values, and integer validation on --jobs.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# We can't easily inspect the internal state of a subprocess after flag
# parsing, but we *can* observe how flags get echoed back into the
# usage text (which prints the current values) and how invalid flags
# trigger early exits.

test_unknown_long_flag_rejected() {
    run_orch --not-a-real-flag
    assert_status 2 "$RUN_RC" "unknown flag should exit 2" || return 1
    assert_contains "$RUN_OUT" "unknown flag" "should mention 'unknown flag'" || return 1
}

test_flag_requiring_value_with_no_value() {
    run_orch --port
    assert_status 2 "$RUN_RC" "--port without value should exit 2" || return 1
    assert_contains "$RUN_OUT" "requires a value" "error should explain missing value" || return 1
}

test_jobs_must_be_positive_integer() {
    run_orch --jobs notanumber help
    assert_status 2 "$RUN_RC" "non-integer --jobs should exit 2" || return 1
    assert_contains "$RUN_OUT" "positive integer" "error message should explain integer requirement" || return 1
}

test_jobs_zero_is_rejected() {
    run_orch --jobs 0 help
    assert_status 2 "$RUN_RC" "zero --jobs should be rejected" || return 1
    assert_contains "$RUN_OUT" ">= 1" "should require >= 1" || return 1
}

test_jobs_negative_is_rejected() {
    # The integer validator only accepts digits, so -1 is parsed as
    # non-integer (the leading '-' fails the digit-only check).
    run_orch --jobs -1 help
    assert_status 2 "$RUN_RC" "negative --jobs should be rejected" || return 1
}

test_long_flag_with_equals() {
    # The usage text echoes the active port value. Verify --port=NNNN
    # is parsed as the value 9999.
    run_orch --port=9999 help
    assert_status 0 "$RUN_RC" "--port=N should succeed" || return 1
    assert_contains "$RUN_OUT" "IPERF_PORT=9999" "usage should reflect port=9999" || return 1
}

test_long_flag_with_space() {
    run_orch --port 8888 help
    assert_status 0 "$RUN_RC" "--port N should succeed" || return 1
    assert_contains "$RUN_OUT" "IPERF_PORT=8888" "usage should reflect port=8888" || return 1
}

test_short_flag_jobs() {
    run_orch -j 7 help
    assert_status 0 "$RUN_RC" "-j 7 should succeed" || return 1
    assert_contains "$RUN_OUT" "IPERF_JOBS=7" "usage should reflect jobs=7" || return 1
}

test_short_flag_duration() {
    run_orch -d 30 help
    assert_status 0 "$RUN_RC" "-d 30 should succeed" || return 1
    assert_contains "$RUN_OUT" "IPERF_DURATION=30" "usage should reflect duration=30" || return 1
}

test_short_flag_parallel() {
    run_orch -P 4 help
    assert_status 0 "$RUN_RC" "-P 4 should succeed" || return 1
    assert_contains "$RUN_OUT" "IPERF_PARALLEL=4" "usage should reflect parallel=4" || return 1
}

test_ssh_user_override() {
    run_orch --ssh-user=alice help
    assert_status 0 "$RUN_RC" "--ssh-user=alice should succeed" || return 1
    assert_contains "$RUN_OUT" "SSH_USER=alice" "usage should reflect ssh user" || return 1
}

test_iperf_dir_override_is_used() {
    # When --iperf-dir is given, status output should reference that dir.
    local custom="$TEST_TMPDIR/custom-iperf-dir"
    run_orch --iperf-dir "$custom" status
    assert_status 0 "$RUN_RC" "status with --iperf-dir should succeed" || return 1
    assert_contains "$RUN_OUT" "$custom" "status should mention the custom dir" || return 1
    [ -d "$custom" ] || { echo "expected $custom to be created" >&2; return 1; }
}

test_double_dash_terminates_flag_parsing() {
    # After --, remaining args go through verbatim. So `-- run-tests
    # parallel` should hit the run-tests dispatcher with mode=parallel
    # ... but with no servers, run-tests should die with "No hosts" /
    # "No server list". We just check it's not the unknown-flag exit.
    run_orch -- run-tests parallel
    # Expected to fail (no server list) but NOT with status 2 from
    # "unknown flag". The orchestrator dies with status 1 from die().
    assert_ne 2 "$RUN_RC" "should not be unknown-flag rejection" || return 1
}

test_env_var_used_when_no_flag() {
    # IPERF_PORT env var should appear in usage when no flag overrides.
    IPERF_PORT=12345 run_orch help
    assert_status 0 "$RUN_RC" "env-only invocation should succeed" || return 1
    assert_contains "$RUN_OUT" "IPERF_PORT=12345" "env IPERF_PORT should propagate" || return 1
}

test_flag_overrides_env() {
    # CLI flag wins over env var.
    IPERF_PORT=11111 run_orch --port=22222 help
    assert_status 0 "$RUN_RC" "flag override should succeed" || return 1
    assert_contains "$RUN_OUT" "IPERF_PORT=22222" "flag should override env" || return 1
    assert_not_contains "$RUN_OUT" "IPERF_PORT=11111" "env value should not leak through" || return 1
}

run_test test_unknown_long_flag_rejected
run_test test_flag_requiring_value_with_no_value
run_test test_jobs_must_be_positive_integer
run_test test_jobs_zero_is_rejected
run_test test_jobs_negative_is_rejected
run_test test_long_flag_with_equals
run_test test_long_flag_with_space
run_test test_short_flag_jobs
run_test test_short_flag_duration
run_test test_short_flag_parallel
run_test test_ssh_user_override
run_test test_iperf_dir_override_is_used
run_test test_double_dash_terminates_flag_parsing
run_test test_env_var_used_when_no_flag
run_test test_flag_overrides_env

report_tests
