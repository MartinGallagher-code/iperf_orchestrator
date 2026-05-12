#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for the `run-tests` subcommand and its three execution modes:
#   parallel         (sync-start, all hosts simultaneously)
#   sequential-host  (one host at a time)
#   sequential-pair  (one pair at a time, single-target arg)

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

prep_workflow() {
    install_fake_ssh
    write_server_list "$@" >/dev/null
    PATH="$FAKE_BIN:$PATH" run_orch create-scripts >/dev/null 2>&1
    PATH="$FAKE_BIN:$PATH" run_orch distribute-scripts >/dev/null 2>&1
    : > "$FAKE_SSH_LOG"
}

# Match only the run_iperf_<host>_<run-id>.sh dispatch lines.
run_iperf_dispatch_count() {
    grep -cE "run_iperf_[^[:space:]]+\.sh'[[:space:]]+[0-9]+" "$FAKE_SSH_LOG"
}

run_with_fake_path() {
    PATH="$FAKE_BIN:$PATH" run_orch "$@"
}

test_run_tests_unknown_mode_is_rejected() {
    prep_workflow alpha bravo
    run_with_fake_path run-tests gibberish
    assert_status 1 "$RUN_RC" "unknown mode should die" || return 1
    assert_contains "$RUN_OUT" "unknown mode" || return 1
}

test_run_tests_parallel_default_mode() {
    prep_workflow alpha bravo charlie
    run_with_fake_path --start-delay=0 run-tests
    assert_status 0 "$RUN_RC" "parallel mode should succeed" || return 1
    local n
    n=$(run_iperf_dispatch_count)
    assert_eq "3" "$n" "should ssh to all 3 hosts" || return 1
    [ -f "$RESULTS_BASE/$IPERF_RUN_ID/.run_mode" ] || return 1
    [ "$(cat "$RESULTS_BASE/$IPERF_RUN_ID/.run_mode")" = "parallel" ] || {
        echo "expected .run_mode=parallel" >&2; return 1
    }
}

test_run_tests_parallel_uses_synchronized_start() {
    prep_workflow a b c
    run_with_fake_path --start-delay=5 run-tests parallel
    assert_status 0 "$RUN_RC" || return 1
    local times
    times=$(grep -oE "run_iperf_[^[:space:]]+\.sh' [0-9]+" "$FAKE_SSH_LOG" | awk '{print $2}' | sort -u | wc -l)
    assert_eq "1" "$times" "all parallel invocations should share one start_time" || return 1
}

test_run_tests_sequential_host_mode() {
    prep_workflow a b c
    run_with_fake_path run-tests sequential-host
    assert_status 0 "$RUN_RC" "sequential-host should succeed" || return 1
    local n
    n=$(run_iperf_dispatch_count)
    assert_eq "3" "$n" || return 1
    if ! grep -qE "run_iperf_[^[:space:]]+\.sh' 0$" "$FAKE_SSH_LOG"; then
        echo "expected start_time=0 in sequential-host invocations" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    fi
    [ "$(cat "$RESULTS_BASE/$IPERF_RUN_ID/.run_mode")" = "sequential-host" ] || return 1
}

test_run_tests_sequential_pair_mode() {
    prep_workflow h0 h1 h2 h3
    run_with_fake_path run-tests sequential-pair
    assert_status 0 "$RUN_RC" "sequential-pair should succeed" || return 1
    local n
    n=$(run_iperf_dispatch_count)
    # Full mesh: 4 hosts -> 4*3 = 12 directed edges, one per round.
    assert_eq "12" "$n" "4 hosts -> 12 directed edges" || return 1
    if ! grep -qE "run_iperf_[^[:space:]]+\.sh' 0 '" "$FAKE_SSH_LOG"; then
        echo "expected SINGLE_TARGET arg in sequential-pair calls" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    fi
    [ "$(cat "$RESULTS_BASE/$IPERF_RUN_ID/.run_mode")" = "sequential-pair" ] || return 1
}

test_run_tests_dies_with_no_server_list() {
    install_fake_ssh
    unset IPERF_SERVERS
    PATH="$FAKE_BIN:$PATH" run_orch --servers /nope.txt run-tests parallel
    assert_ne 0 "$RUN_RC" "should fail without server list" || return 1
}

test_run_tests_writes_per_host_logs() {
    prep_workflow a b c
    run_with_fake_path --start-delay=0 run-tests parallel >/dev/null
    for h in a b c; do
        assert_file_exists "$RESULTS_BASE/$IPERF_RUN_ID/logs/run_$h.log" \
            "missing per-host log for $h" || return 1
    done
}

test_run_tests_sequential_host_runs_in_order() {
    prep_workflow first second third
    run_with_fake_path run-tests sequential-host >/dev/null
    local order
    order=$(grep -E "run_iperf_[^[:space:]]+\.sh'[[:space:]]+[0-9]+" "$FAKE_SSH_LOG" \
            | awk -F'\t' '{print $2}')
    local expected="first
second
third"
    assert_eq "$expected" "$order" "sequential-host should visit hosts in list order" || return 1
}

test_run_tests_rolling_mode_dispatches_per_host_loop() {
    install_fake_ssh
    write_server_list a b c >/dev/null
    run_with_fake_path --total-time 1 --duration 1 run-tests rolling
    assert_status 0 "$RUN_RC" "rolling mode should succeed" || return 1
    # One ssh per host, each carrying the inline probe script (look for END_TIME).
    local n
    n=$(grep -c "END_TIME=" "$FAKE_SSH_LOG")
    assert_eq "3" "$n" "rolling should dispatch one inline probe per host" || return 1
    [ -f "$RESULTS_BASE/$IPERF_RUN_ID/.run_mode" ] || return 1
    [ "$(cat "$RESULTS_BASE/$IPERF_RUN_ID/.run_mode")" = "rolling" ] || {
        echo "expected .run_mode=rolling" >&2; return 1
    }
}

run_test test_run_tests_unknown_mode_is_rejected
test_run_tests_rolling_passes_perf_flags_to_iperf() {
    install_fake_ssh
    write_server_list a b c >/dev/null
    IPERF_BANDWIDTH=500M IPERF_LENGTH=64K \
        run_with_fake_path --total-time 1 --duration 1 run-tests rolling
    assert_status 0 "$RUN_RC" || return 1
    grep -q -- '-b 500M' "$FAKE_SSH_LOG" || {
        echo "rolling probe should include -b 500M in iperf -c" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    }
    grep -q -- '-l 64K' "$FAKE_SSH_LOG" || {
        echo "rolling probe should include -l 64K" >&2
        return 1
    }
}

test_run_tests_rolling_passes_streams_to_iperf() {
    install_fake_ssh
    write_server_list a b c >/dev/null
    IPERF_STREAMS=4 \
        run_with_fake_path --total-time 1 --duration 1 run-tests rolling
    assert_status 0 "$RUN_RC" || return 1
    grep -qE '[-]P[[:space:]]+4' "$FAKE_SSH_LOG" || {
        echo "rolling probe should include -P 4 in iperf -c" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    }
    grep -q 'parallel=4' "$FAKE_SSH_LOG" || {
        echo "rolling probe header should report parallel=4" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    }
}

run_test test_run_tests_rolling_mode_dispatches_per_host_loop
run_test test_run_tests_rolling_passes_perf_flags_to_iperf
run_test test_run_tests_rolling_passes_streams_to_iperf
test_run_tests_rolling_embeds_bind_resolver() {
    install_fake_ssh
    write_server_list a b c >/dev/null
    IPERF_BIND="eth0" \
        run_with_fake_path --total-time 1 --duration 1 run-tests rolling
    assert_status 0 "$RUN_RC" || return 1
    grep -q 'BIND_RAW="eth0"' "$FAKE_SSH_LOG" || {
        echo "rolling probe should set BIND_RAW=\"eth0\"" >&2
        cat "$FAKE_SSH_LOG" >&2; return 1
    }
    grep -q 'ip -o -4 addr show' "$FAKE_SSH_LOG" || {
        echo "rolling probe should embed the ip-addr resolver" >&2; return 1
    }
    grep -q 'no interface matched' "$FAKE_SSH_LOG" || {
        echo "rolling probe should include the no-match error path" >&2; return 1
    }
    grep -qE 'iperf -c .*\$BIND_ARG' "$FAKE_SSH_LOG" || {
        echo "rolling iperf invocation should reference \$BIND_ARG" >&2
        grep 'iperf -c' "$FAKE_SSH_LOG" >&2; return 1
    }
}

test_run_tests_rolling_writes_cmd_and_traps_failures() {
    install_fake_ssh
    write_server_list a b >/dev/null
    run_with_fake_path --total-time 1 --duration 1 run-tests rolling
    assert_status 0 "$RUN_RC" || return 1
    grep -qE 'cmd="iperf -c \$target' "$FAKE_SSH_LOG" || {
        echo "rolling probe should build cmd= string for the log" >&2
        cat "$FAKE_SSH_LOG" >&2; return 1
    }
    grep -q 'echo "# cmd: \$cmd"' "$FAKE_SSH_LOG" || {
        echo "rolling probe should write '# cmd:' line into log" >&2; return 1
    }
    grep -q '\[FAIL\] ' "$FAKE_SSH_LOG" || {
        echo "rolling probe should surface [FAIL] on errors" >&2; return 1
    }
    grep -q 'connect failed' "$FAKE_SSH_LOG" || {
        echo "rolling probe should include error-token grep" >&2; return 1
    }
}

test_run_tests_rolling_omits_bind_when_unset() {
    install_fake_ssh
    write_server_list a b c >/dev/null
    run_with_fake_path --total-time 1 --duration 1 run-tests rolling
    assert_status 0 "$RUN_RC" || return 1
    grep -q 'BIND_RAW=""' "$FAKE_SSH_LOG" || {
        echo "rolling probe should set BIND_RAW=\"\" when --bind not given" >&2
        grep BIND_RAW "$FAKE_SSH_LOG" >&2; return 1
    }
}
run_test test_run_tests_rolling_embeds_bind_resolver
run_test test_run_tests_rolling_omits_bind_when_unset
run_test test_run_tests_rolling_writes_cmd_and_traps_failures
run_test test_run_tests_parallel_default_mode
run_test test_run_tests_parallel_uses_synchronized_start
run_test test_run_tests_sequential_host_mode
run_test test_run_tests_sequential_pair_mode
run_test test_run_tests_dies_with_no_server_list
run_test test_run_tests_writes_per_host_logs
run_test test_run_tests_sequential_host_runs_in_order

report_tests
