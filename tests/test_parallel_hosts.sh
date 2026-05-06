#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for the parallel_hosts() fan-out helper. Verifies:
#   - it iterates every host in the server list
#   - it caps concurrency to $IPERF_SSH_JOBS
#   - it captures per-host stdout+stderr
#   - it records failed hosts in PARALLEL_FAILED

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

write_servers() {
    write_server_list "$@" >/dev/null
}

test_parallel_hosts_runs_for_every_host() {
    write_servers a b c d
    source_orch
    # Worker writes its host name to a shared file.
    export PARALLEL_TEST_OUT="$TEST_TMPDIR/seen.txt"
    : > "$PARALLEL_TEST_OUT"
    _worker_record_host() {
        echo "$1" >> "$PARALLEL_TEST_OUT"
        echo "stdout-from-$1"
    }
    parallel_hosts _worker_record_host >/dev/null
    local lines
    lines=$(sort "$PARALLEL_TEST_OUT")
    assert_eq "a
b
c
d" "$lines" "every host should get a worker call" || return 1
}

test_parallel_hosts_records_failures() {
    write_servers ok1 fail1 ok2 fail2
    source_orch
    _worker_pass_or_fail() {
        case "$1" in
            fail*) return 1 ;;
            *) return 0 ;;
        esac
    }
    # Direct call (not $(...)): PARALLEL_FAILED is set in the same shell.
    parallel_hosts _worker_pass_or_fail >/dev/null
    local sorted
    sorted=$(printf '%s\n' "${PARALLEL_FAILED[@]}" | sort)
    assert_eq "fail1
fail2" "$sorted" "PARALLEL_FAILED should list both failures" || return 1
}

test_parallel_hosts_respects_jobs_cap() {
    # With IPERF_SSH_JOBS=2 and 6 hosts each sleeping 1s, total wall time
    # should be ~3s, not ~1s (would be if unconstrained) and not ~6s
    # (would be if serial).
    write_servers h1 h2 h3 h4 h5 h6
    export IPERF_SSH_JOBS=2
    source_orch
    _worker_sleep1() {
        sleep 1
        echo "done-$1"
    }
    local start end elapsed
    start=$(date +%s)
    parallel_hosts _worker_sleep1 >/dev/null
    end=$(date +%s)
    elapsed=$((end - start))
    # Allow some slop for slow CI: 2 <= elapsed <= 5
    if [ "$elapsed" -lt 2 ] || [ "$elapsed" -gt 5 ]; then
        echo "elapsed=$elapsed s, expected ~3s with jobs=2 over 6x1s workers" >&2
        return 1
    fi
}

test_parallel_hosts_captures_worker_output_in_order() {
    # The doc promises output is replayed in server-list order even if
    # workers finish out of order. We make later-listed hosts finish
    # first via shorter sleeps and check the replayed order.
    write_servers slow medium fast
    export IPERF_SSH_JOBS=8   # let them all run in parallel
    source_orch
    _worker_with_varied_speed() {
        case "$1" in
            slow)   sleep 0.6 ;;
            medium) sleep 0.3 ;;
            fast)   sleep 0.1 ;;
        esac
        echo "MARK $1"
    }
    local out
    out=$(parallel_hosts _worker_with_varied_speed)
    # Order should be slow, medium, fast (server-list order).
    local expected="MARK slow
MARK medium
MARK fast"
    assert_eq "$expected" "$out" "output should be in server-list order" || return 1
}

test_parallel_hosts_empty_list_is_noop() {
    write_servers
    source_orch
    _worker_should_not_run() {
        echo "OOPS RAN FOR $1"
        return 0
    }
    # Run in the current shell (not a $() subshell) so PARALLEL_FAILED
    # stays visible; capture stdout via a file instead.
    parallel_hosts _worker_should_not_run > "$TEST_TMPDIR/empty.out"
    local out
    out=$(cat "$TEST_TMPDIR/empty.out")
    assert_eq "" "$out" "empty server list should produce no output" || return 1
    [ "${#PARALLEL_FAILED[@]}" -eq 0 ] || {
        echo "PARALLEL_FAILED should be empty for empty list (got: ${PARALLEL_FAILED[*]})" >&2
        return 1
    }
}

test_parallel_hosts_no_failures_leaves_empty_array() {
    write_servers a b c
    source_orch
    _worker_always_ok() { return 0; }
    parallel_hosts _worker_always_ok >/dev/null
    # PARALLEL_FAILED may legitimately be unset-empty; treat that as 0.
    local n=${#PARALLEL_FAILED[@]}
    if [ "$n" -ne 0 ]; then
        echo "expected PARALLEL_FAILED empty, got $n entries: ${PARALLEL_FAILED[*]}" >&2
        return 1
    fi
}

run_test test_parallel_hosts_runs_for_every_host
run_test test_parallel_hosts_records_failures
run_test test_parallel_hosts_respects_jobs_cap
run_test test_parallel_hosts_captures_worker_output_in_order
run_test test_parallel_hosts_empty_list_is_noop
run_test test_parallel_hosts_no_failures_leaves_empty_array

report_tests
