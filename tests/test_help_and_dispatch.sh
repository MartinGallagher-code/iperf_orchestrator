#!/usr/bin/env bash
# Smoke tests for the help/usage text and the top-level subcommand
# dispatcher.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

test_help_with_no_args_prints_usage() {
    run_orch
    assert_status 0 "$RUN_RC" "no-args invocation should exit 0" || return 1
    assert_contains "$RUN_OUT" "iperf-orchestrator.sh" "usage missing program name" || return 1
    assert_contains "$RUN_OUT" "USAGE:" "usage missing USAGE header" || return 1
    assert_contains "$RUN_OUT" "init" "usage should list init subcommand" || return 1
    assert_contains "$RUN_OUT" "run-tests" "usage should list run-tests subcommand" || return 1
    assert_contains "$RUN_OUT" "make-heatmap" "usage should list make-heatmap" || return 1
}

test_help_explicit_subcommand() {
    run_orch help
    assert_status 0 "$RUN_RC" "help subcommand should exit 0" || return 1
    assert_contains "$RUN_OUT" "USAGE:" "help should print usage" || return 1
}

test_help_dash_h_flag() {
    run_orch -h
    assert_status 0 "$RUN_RC" "-h should exit 0" || return 1
    assert_contains "$RUN_OUT" "USAGE:" "-h should print usage" || return 1
}

test_help_double_dash_help_flag() {
    run_orch --help
    assert_status 0 "$RUN_RC" "--help should exit 0" || return 1
    assert_contains "$RUN_OUT" "USAGE:" "--help should print usage" || return 1
}

test_unknown_subcommand_is_rejected() {
    run_orch this-is-not-a-real-command
    assert_status 2 "$RUN_RC" "unknown subcommand should exit 2" || return 1
    assert_contains "$RUN_OUT" "Unknown command" "should mention unknown command" || return 1
}

run_test test_help_with_no_args_prints_usage
run_test test_help_explicit_subcommand
run_test test_help_dash_h_flag
run_test test_help_double_dash_help_flag
run_test test_unknown_subcommand_is_rejected

report_tests
