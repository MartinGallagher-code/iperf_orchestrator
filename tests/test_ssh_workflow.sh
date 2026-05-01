#!/usr/bin/env bash
# End-to-end style tests for the SSH-driven subcommands. We replace
# `ssh`/`scp` on PATH with a shim (see test_helper.bash :: install_fake_ssh)
# that records every invocation and returns canned responses for the
# probes the orchestrator runs (iperf -v, mpstat, pgrep, etc.).
#
# These tests prove the orchestrator drives the right commands at the
# right hosts -- they don't exercise real iperf2 traffic.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# Set up: fake bin on PATH, hosts initialised, and the ssh shim lives
# under FAKE_BIN.
prep_workflow() {
    install_fake_ssh
    local src="$TEST_TMPDIR/srv.txt"
    : > "$src"
    local h
    for h in "$@"; do
        printf '%s\n' "$h" >> "$src"
    done
    PATH="$FAKE_BIN:$PATH" run_orch init "$src" >/dev/null 2>&1
}

# Run the orchestrator with the fake bin first on PATH.
run_with_fake_path() {
    PATH="$FAKE_BIN:$PATH" run_orch "$@"
}

ssh_call_count() {
    local host="$1"
    grep -c -E "^ssh"$'\t'"$host"$'\t' "$FAKE_SSH_LOG" 2>/dev/null || echo 0
}

test_check_iperf_marks_hosts_installed() {
    prep_workflow alpha bravo charlie
    run_with_fake_path check-iperf
    assert_status 0 "$RUN_RC" || return 1
    # The shim returns "iperf version 2.1.9..." for `iperf -v`, so all
    # three hosts should be classed INSTALLED.
    assert_contains "$RUN_OUT" "alpha" "should mention alpha" || return 1
    assert_contains "$RUN_OUT" "INSTALLED" "should mark INSTALLED" || return 1
    # The output file should record one line per host.
    local n
    n=$(grep -c INSTALLED "$IPERF_DIR/iperf_installed.txt")
    assert_eq "3" "$n" "all three hosts should be INSTALLED in output file" || return 1
    grep -q '^IPERF_INSTALLED_CHECKED=yes$' "$IPERF_DIR/state" || {
        echo "state flag not set" >&2; return 1; }
}

test_check_iperf_handles_unreachable_host() {
    prep_workflow alpha bravo charlie
    # Mark bravo as unreachable.
    echo "bravo" >> "$FAKE_BIN/unreachable"
    run_with_fake_path check-iperf
    assert_status 0 "$RUN_RC" "subcommand should still complete" || return 1
    # bravo's iperf -v call returns nothing (ssh exit 255 + empty stdout).
    # Parser sees empty version -> MISSING.
    assert_contains "$RUN_OUT" "MISSING" "should report MISSING for unreachable host" || return 1
}

test_check_servers_reports_stopped_when_none_running() {
    prep_workflow alpha bravo
    run_with_fake_path check-servers
    assert_status 0 "$RUN_RC" || return 1
    local stopped
    stopped=$(grep -c STOPPED "$IPERF_DIR/iperf_running.txt")
    assert_eq "2" "$stopped" "both hosts should be STOPPED" || return 1
}

test_check_servers_reports_running_when_pgrep_finds_proc() {
    prep_workflow alpha bravo
    # Pre-mark bravo as having an iperf running (the shim consults
    # this flag file).
    touch "$FAKE_BIN/iperf_running_bravo"
    run_with_fake_path check-servers
    assert_status 0 "$RUN_RC" || return 1
    local running stopped
    running=$(grep -c RUNNING "$IPERF_DIR/iperf_running.txt")
    stopped=$(grep -c STOPPED "$IPERF_DIR/iperf_running.txt")
    assert_eq "1" "$running" "bravo should be RUNNING" || return 1
    assert_eq "1" "$stopped" "alpha should be STOPPED" || return 1
}

test_start_servers_marks_state() {
    prep_workflow a b c
    run_with_fake_path start-servers
    assert_status 0 "$RUN_RC" || return 1
    grep -q '^SERVERS_STARTED=yes$' "$IPERF_DIR/state" || {
        echo "SERVERS_STARTED not flagged" >&2; return 1; }
    # The shim left a flag file per host showing the daemon was
    # "started".
    for h in a b c; do
        [ -f "$FAKE_BIN/iperf_running_$h" ] || {
            echo "shim never saw start sequence for $h" >&2; return 1; }
    done
}

test_stop_servers_kills_iperf_on_each_host() {
    prep_workflow a b c
    # Pre-mark all three as running so stop has work to do.
    touch "$FAKE_BIN/iperf_running_a" "$FAKE_BIN/iperf_running_b" "$FAKE_BIN/iperf_running_c"
    run_with_fake_path stop-servers
    assert_status 0 "$RUN_RC" || return 1
    grep -q '^SERVERS_STOPPED=yes$' "$IPERF_DIR/state" || return 1
    for h in a b c; do
        [ ! -f "$FAKE_BIN/iperf_running_$h" ] || {
            echo "$h still flagged running after stop-servers" >&2; return 1; }
    done
}

test_cleanup_removes_remote_dir() {
    prep_workflow a b
    run_with_fake_path cleanup
    assert_status 0 "$RUN_RC" || return 1
    grep -q '^CLEANED_UP=yes$' "$IPERF_DIR/state" || return 1
    # Verify the rm -rf command actually got dispatched per host.
    local rm_count
    rm_count=$(grep -c "rm -rf" "$FAKE_SSH_LOG")
    assert_eq "2" "$rm_count" "rm -rf should hit each of 2 hosts" || return 1
}

test_check_iperf_uses_parallel_jobs() {
    prep_workflow a b c d e f
    # Each host triggers 2 ssh probes (iperf -v + command -v mpstat).
    # We're not asserting on timing here, just that *all* probes hit.
    run_with_fake_path check-iperf >/dev/null
    local total
    total=$(wc -l < "$FAKE_SSH_LOG")
    if [ "$total" -lt 12 ]; then
        echo "expected at least 12 ssh calls (6 hosts x 2 probes), got $total" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    fi
}

test_workflow_subcommands_are_idempotent() {
    # Running stop-servers twice should not fail just because nothing
    # is running the second time.
    prep_workflow a b
    touch "$FAKE_BIN/iperf_running_a" "$FAKE_BIN/iperf_running_b"
    run_with_fake_path stop-servers
    assert_status 0 "$RUN_RC" "first stop should succeed" || return 1
    run_with_fake_path stop-servers
    # Second call: pkill no-ops, pgrep returns nothing, the worker's
    # final test (`! pgrep` succeeds because empty), still exit 0.
    assert_status 0 "$RUN_RC" "second stop should also succeed" || return 1
}

run_test test_check_iperf_marks_hosts_installed
run_test test_check_iperf_handles_unreachable_host
run_test test_check_servers_reports_stopped_when_none_running
run_test test_check_servers_reports_running_when_pgrep_finds_proc
run_test test_start_servers_marks_state
run_test test_stop_servers_kills_iperf_on_each_host
run_test test_cleanup_removes_remote_dir
run_test test_check_iperf_uses_parallel_jobs
run_test test_workflow_subcommands_are_idempotent

report_tests
