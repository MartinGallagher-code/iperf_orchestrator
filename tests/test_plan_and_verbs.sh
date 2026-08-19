#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for the mx-style surface: the `gen` plan file (write, load,
# precedence), and the plan-driven verbs (start, summarize, stop, clean,
# run, hints).

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# Like run_orch, but with IPERF_SERVERS scrubbed from the environment so
# the plan file's own host list (and settings) get exercised instead of
# the test harness's exported server list.
run_orch_noenv() {
    RUN_OUT="$(env -u IPERF_SERVERS bash "$ORCH" "$@" 2>&1)"
    RUN_RC=$?
    export RUN_OUT RUN_RC
}

# ---- gen: writing the plan -------------------------------------------------

test_gen_writes_plan_with_hosts_and_settings() {
    write_server_list h1 h2 h3 >/dev/null
    run_orch gen
    assert_status 0 "$RUN_RC" "gen should succeed" || return 1
    assert_file_exists "iperf_plan.conf" || return 1
    local plan; plan=$(cat iperf_plan.conf)
    assert_contains "$plan" "h1" "plan should list host h1" || return 1
    assert_contains "$plan" "h3" "plan should list host h3" || return 1
    assert_contains "$plan" "mode=parallel" || return 1
    assert_contains "$plan" "port=5001" || return 1
    assert_contains "$plan" "duration=10" || return 1
}

test_gen_records_flag_overrides_and_mode() {
    write_server_list h1 h2 >/dev/null
    run_orch --port 9999 --duration 3 gen rolling
    assert_status 0 "$RUN_RC" "gen with flags should succeed" || return 1
    local plan; plan=$(cat iperf_plan.conf)
    assert_contains "$plan" "port=9999" || return 1
    assert_contains "$plan" "duration=3" || return 1
    assert_contains "$plan" "mode=rolling" || return 1
}

test_gen_without_server_list_dies() {
    run_orch gen
    assert_ne 0 "$RUN_RC" "gen with no server list should fail" || return 1
    assert_contains "$RUN_OUT" "no server list" || return 1
}

test_gen_rejects_unknown_argument() {
    write_server_list h1 h2 >/dev/null
    run_orch gen bogus-mode
    [ "$RUN_RC" -ne 0 ] || { echo "gen bogus-mode should fail" >&2; return 1; }
    assert_contains "$RUN_OUT" "unknown argument" || return 1
}

# ---- plan loading + precedence --------------------------------------------

test_plan_settings_become_defaults() {
    write_server_list h1 h2 >/dev/null
    run_orch --port 9876 gen
    assert_status 0 "$RUN_RC" || return 1
    # help-advanced echoes the effective config values.
    run_orch_noenv help-advanced
    assert_contains "$RUN_OUT" "IPERF_PORT=9876" "plan port should be the default" || return 1
}

test_cli_flag_beats_plan_value() {
    write_server_list h1 h2 >/dev/null
    run_orch --port 9876 gen
    run_orch_noenv --port 1234 help-advanced
    assert_contains "$RUN_OUT" "IPERF_PORT=1234" "CLI flag should beat the plan" || return 1
}

test_env_var_beats_plan_value() {
    write_server_list h1 h2 >/dev/null
    run_orch --port 9876 gen
    RUN_OUT="$(env -u IPERF_SERVERS IPERF_PORT=2222 bash "$ORCH" help-advanced 2>&1)"
    assert_contains "$RUN_OUT" "IPERF_PORT=2222" "env var should beat the plan" || return 1
}

test_plan_doubles_as_server_list() {
    write_server_list h1 h2 >/dev/null
    run_orch gen
    run_orch_noenv help-advanced
    assert_contains "$RUN_OUT" "iperf_plan.conf" "plan should serve as the server list" || return 1
}

test_regenerating_preserves_unoverridden_settings() {
    write_server_list h1 h2 >/dev/null
    run_orch --port 7777 gen
    # Second gen without flags: the existing plan's settings are this
    # invocation's defaults, so port must round-trip.
    run_orch_noenv gen
    assert_status 0 "$RUN_RC" "re-gen should succeed" || return 1
    assert_contains "$(cat iperf_plan.conf)" "port=7777" \
        "re-running gen must not lose plan settings" || return 1
}

test_explicit_missing_plan_dies_for_non_gen_commands() {
    run_orch --plan "$TEST_TMPDIR/nope.conf" status
    [ "$RUN_RC" -ne 0 ] || { echo "missing --plan should fail for status" >&2; return 1; }
    assert_contains "$RUN_OUT" "plan file not found" || return 1
}

test_gen_may_name_a_plan_that_does_not_exist_yet() {
    write_server_list h1 h2 >/dev/null
    run_orch --plan "$TEST_TMPDIR/new_plan.conf" gen
    assert_status 0 "$RUN_RC" "gen should create a brand-new --plan path" || return 1
    assert_file_exists "$TEST_TMPDIR/new_plan.conf" || return 1
}

test_plan_mode_key_sets_default_run_mode() {
    write_server_list h1 h2 >/dev/null
    run_orch gen rolling
    # A dry-run through run-tests shows the mode line without SSHing.
    run_orch_noenv --dry-run run-tests
    assert_contains "$RUN_OUT" "Mode: rolling" "plan mode= should drive run-tests" || return 1
}

# ---- the verbs (function-level, via sourced stubs) -------------------------

test_start_runs_servers_then_tests_in_order() {
    cmd_start_servers() { PARALLEL_FAILED=(); echo "STUB start-servers"; }
    cmd_run_tests()     { echo "STUB run-tests mode=$1"; }
    local out; out=$(cmd_start sequential-host)
    assert_contains "$out" "STUB start-servers" || return 1
    assert_contains "$out" "STUB run-tests mode=sequential-host" || return 1
}

test_start_mode_defaults_to_plan_mode() {
    cmd_start_servers() { PARALLEL_FAILED=(); }
    cmd_run_tests()     { echo "STUB mode=$1"; }
    IPERF_MODE=rolling
    local out; out=$(cmd_start)
    assert_contains "$out" "STUB mode=rolling" || return 1
}

test_start_dies_when_daemons_fail_without_keep_going() {
    cmd_start_servers() { PARALLEL_FAILED=(h1); }
    cmd_run_tests()     { echo "STUB run-tests"; }
    local out rc
    out=$( (cmd_start) 2>&1 ); rc=$?
    [ "$rc" -ne 0 ] || { echo "cmd_start should die on daemon failures" >&2; return 1; }
    assert_not_contains "$out" "STUB run-tests" "must not run tests after failed start" || return 1
    out=$( (cmd_start --keep-going) 2>&1 ) || return 1
    assert_contains "$out" "STUB run-tests" "--keep-going should press on" || return 1
}

test_run_for_maps_to_total_time_in_rolling_mode() {
    cmd_all()             { echo "STUB all mode=$1 total=$IPERF_TOTAL_TIME dur=$IPERF_DURATION"; }
    cmd_results_summary() { :; }
    local out; out=$(cmd_run rolling --for 77)
    assert_contains "$out" "STUB all mode=rolling total=77" || return 1
}

test_run_for_maps_to_duration_in_other_modes() {
    cmd_all()             { echo "STUB all mode=$1 total=$IPERF_TOTAL_TIME dur=$IPERF_DURATION"; }
    cmd_results_summary() { :; }
    local out; out=$(cmd_run --for 5)
    assert_contains "$out" "STUB all mode=parallel" || return 1
    assert_contains "$out" "dur=5" || return 1
}

test_run_runs_summary_after_all() {
    cmd_all()             { echo "STUB all"; }
    cmd_results_summary() { echo "STUB summary"; }
    local out; out=$(cmd_run)
    assert_contains "$out" "STUB all" || return 1
    assert_contains "$out" "STUB summary" || return 1
}

test_run_rejects_non_numeric_for() {
    run_orch run --for abc
    [ "$RUN_RC" -ne 0 ] || { echo "run --for abc should fail" >&2; return 1; }
}

test_summarize_shows_pivot_then_summary() {
    cmd_process()         { RESULTS_DIR="$RESULTS_BASE/test-run"; }
    cmd_results_summary() { echo "STUB summary"; }
    mkdir -p "$RESULTS_BASE/test-run"
    echo "STUB pivot table" > "$RESULTS_BASE/test-run/iperf_pivot.txt"
    local out; out=$(cmd_summarize)
    assert_contains "$out" "STUB pivot table" || return 1
    assert_contains "$out" "STUB summary" || return 1
}

# ---- stop / clean over the fake fleet --------------------------------------

test_stop_kills_daemons_and_points_at_next_steps() {
    write_server_list h1 h2 >/dev/null
    install_fake_ssh
    PATH="$FAKE_BIN:$PATH" run_orch stop
    assert_status 0 "$RUN_RC" || return 1
    grep -q "pkill" "$FAKE_SSH_LOG" || { echo "stop should pkill daemons" >&2; return 1; }
    assert_contains "$RUN_OUT" "summarize" "stop should mention summarize" || return 1
    assert_contains "$RUN_OUT" "clean" "stop should mention clean" || return 1
}

test_clean_reports_verified_removal() {
    write_server_list h1 h2 >/dev/null
    install_fake_ssh
    PATH="$FAKE_BIN:$PATH" run_orch clean
    assert_status 0 "$RUN_RC" "clean should succeed on a healthy fleet" || return 1
    assert_contains "$RUN_OUT" "CLEAN" || return 1
    assert_contains "$RUN_OUT" "no trace left" || return 1
}

test_clean_fails_loudly_when_a_host_is_left_dirty() {
    write_server_list h1 h2 >/dev/null
    install_fake_ssh
    echo h2 > "$FAKE_BIN/unreachable"
    PATH="$FAKE_BIN:$PATH" run_orch clean
    [ "$RUN_RC" -ne 0 ] || { echo "clean must fail when a host keeps leftovers" >&2; return 1; }
    assert_contains "$RUN_OUT" "LEFTOVER" || return 1
}

# ---- hints -----------------------------------------------------------------

test_hints_prints_goal_to_command_cheatsheet() {
    run_orch hints
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "What do you want to know?" || return 1
    assert_contains "$RUN_OUT" "sequential-pair" || return 1
    assert_contains "$RUN_OUT" "rolling" || return 1
}

test_hints_sizes_estimates_to_the_fleet() {
    write_server_list h1 h2 h3 h4 >/dev/null
    run_orch hints
    assert_contains "$RUN_OUT" "Sized for your fleet (4 hosts" || return 1
    assert_contains "$RUN_OUT" "12 directed tests" "4 hosts = 12 directed edges" || return 1
}

# ---- runner ----------------------------------------------------------------

run_test test_gen_writes_plan_with_hosts_and_settings
run_test test_gen_records_flag_overrides_and_mode
run_test test_gen_without_server_list_dies
run_test test_gen_rejects_unknown_argument
run_test test_plan_settings_become_defaults
run_test test_cli_flag_beats_plan_value
run_test test_env_var_beats_plan_value
run_test test_plan_doubles_as_server_list
run_test test_regenerating_preserves_unoverridden_settings
run_test test_explicit_missing_plan_dies_for_non_gen_commands
run_test test_gen_may_name_a_plan_that_does_not_exist_yet
run_test test_plan_mode_key_sets_default_run_mode
run_test test_start_runs_servers_then_tests_in_order
run_test test_start_mode_defaults_to_plan_mode
run_test test_start_dies_when_daemons_fail_without_keep_going
run_test test_run_for_maps_to_total_time_in_rolling_mode
run_test test_run_for_maps_to_duration_in_other_modes
run_test test_run_runs_summary_after_all
run_test test_run_rejects_non_numeric_for
run_test test_summarize_shows_pivot_then_summary
run_test test_stop_kills_daemons_and_points_at_next_steps
run_test test_clean_reports_verified_removal
run_test test_clean_fails_loudly_when_a_host_is_left_dirty
run_test test_hints_prints_goal_to_command_cheatsheet
run_test test_hints_sizes_estimates_to_the_fleet

report_tests
