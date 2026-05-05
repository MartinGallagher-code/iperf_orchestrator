#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for cmd_distribute_scripts. The worker:
#   1. mkdirs $REMOTE_DIR remotely
#   2. removes stale files matching the active <run-id>
#   3. scp's the per-host run script to $REMOTE_DIR/run_iperf_<host>_<run-id>.sh
#   4. chmods +x on the remote
# We cover all four steps and the failure path.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

prep_workflow() {
    install_fake_ssh
    write_server_list "$@" >/dev/null
    PATH="$FAKE_BIN:$PATH" run_orch create-scripts >/dev/null 2>&1
    : > "$FAKE_SSH_LOG"
}

run_with_fakes() {
    PATH="$FAKE_BIN:$PATH" run_orch "$@"
}

test_distribute_scripts_uploads_one_per_host() {
    prep_workflow alpha bravo charlie
    run_with_fakes distribute-scripts
    assert_status 0 "$RUN_RC" "distribute-scripts should succeed" || return 1
    local n
    n=$(grep -c '^scp' "$FAKE_SSH_LOG")
    assert_eq "3" "$n" "expected one scp per host" || return 1
}

test_distribute_scripts_each_destination_includes_host_and_run_id() {
    prep_workflow a b
    run_with_fakes distribute-scripts >/dev/null
    # Every scp destination should match run_iperf_<host>_<run-id>.sh
    local dests
    dests=$(grep -E '^scp' "$FAKE_SSH_LOG" | awk -F'\t' '{print $3}')
    echo "$dests" | grep -qE "/run_iperf_a_${IPERF_RUN_ID}\.sh$" || {
        echo "expected /run_iperf_a_${IPERF_RUN_ID}.sh dst" >&2
        echo "$dests" >&2
        return 1
    }
    echo "$dests" | grep -qE "/run_iperf_b_${IPERF_RUN_ID}\.sh$" || return 1
}

test_distribute_scripts_chmods_remote_script() {
    prep_workflow a b
    run_with_fakes distribute-scripts >/dev/null
    local n
    n=$(grep -c -E "^ssh"$'\t'"[^"$'\t'"]+"$'\t'".*chmod \+x" "$FAKE_SSH_LOG")
    assert_eq "2" "$n" "should chmod +x on each remote" || return 1
}

test_distribute_scripts_creates_remote_dir() {
    prep_workflow a b
    run_with_fakes distribute-scripts >/dev/null
    local n
    n=$(grep -c -E "^ssh.*mkdir -p" "$FAKE_SSH_LOG")
    assert_eq "2" "$n" "should mkdir on each remote" || return 1
}

test_distribute_scripts_removes_only_this_runs_stale_files() {
    prep_workflow a b
    run_with_fakes distribute-scripts >/dev/null
    # Worker scopes rm -f to <run-id>-suffixed files only.
    if ! grep -q -E "rm -f .*iperf_test_\*_${IPERF_RUN_ID}\.log" "$FAKE_SSH_LOG"; then
        echo "expected rm -f iperf_test_*_${IPERF_RUN_ID}.log on remote" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    fi
    if ! grep -q -E "iperf_run_\*_${IPERF_RUN_ID}\.status" "$FAKE_SSH_LOG"; then
        echo "expected stale status-file removal scoped to run-id" >&2
        return 1
    fi
}

test_distribute_scripts_dies_when_no_server_list() {
    install_fake_ssh
    unset IPERF_SERVERS
    PATH="$FAKE_BIN:$PATH" run_orch --servers /no/such.txt distribute-scripts
    assert_ne 0 "$RUN_RC" "should fail without server list" || return 1
}

test_distribute_scripts_uses_remote_dir_flag() {
    prep_workflow a b
    run_with_fakes --remote-dir=/custom/remote distribute-scripts >/dev/null
    grep -q "mkdir -p '/custom/remote'" "$FAKE_SSH_LOG" || {
        echo "expected --remote-dir to propagate to mkdir target" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    }
    grep -E '^scp' "$FAKE_SSH_LOG" | awk -F'\t' '{print $3}' \
        | grep -qE "/custom/remote/run_iperf_a_${IPERF_RUN_ID}\.sh" || {
        echo "expected scp dst at /custom/remote/run_iperf_a_${IPERF_RUN_ID}.sh" >&2
        return 1
    }
}

test_distribute_scripts_warns_when_no_per_host_script() {
    # Set up server list but DON'T run create-scripts. The worker
    # should warn for each host and the caller should report failures.
    install_fake_ssh
    write_server_list x y >/dev/null
    : > "$FAKE_SSH_LOG"
    run_with_fakes distribute-scripts
    assert_contains "$RUN_OUT" "no script for" || return 1
    assert_contains "$RUN_OUT" "failure" "should report failure(s)" || return 1
}

run_test test_distribute_scripts_uploads_one_per_host
run_test test_distribute_scripts_each_destination_includes_host_and_run_id
run_test test_distribute_scripts_chmods_remote_script
run_test test_distribute_scripts_creates_remote_dir
run_test test_distribute_scripts_removes_only_this_runs_stale_files
run_test test_distribute_scripts_dies_when_no_server_list
run_test test_distribute_scripts_uses_remote_dir_flag
run_test test_distribute_scripts_warns_when_no_per_host_script

report_tests
