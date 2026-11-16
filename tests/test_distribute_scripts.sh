#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

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
    # Every scp goes to a temp name, .run_iperf_<host>_<run-id>.sh.<n>.tmp,
    # which is then renamed onto run_iperf_<host>_<run-id>.sh (IO-003).
    local dests
    dests=$(grep -E '^scp' "$FAKE_SSH_LOG" | awk -F'\t' '{print $3}')
    echo "$dests" | grep -qE "/\.run_iperf_a_${IPERF_RUN_ID}\.sh\.[0-9]+\.[0-9]+\.tmp$" || {
        echo "expected /.run_iperf_a_${IPERF_RUN_ID}.sh.<n>.tmp dst" >&2
        echo "$dests" >&2
        return 1
    }
    echo "$dests" | grep -qE "/\.run_iperf_b_${IPERF_RUN_ID}\.sh\.[0-9]+\.[0-9]+\.tmp$" || return 1
    local h
    for h in a b; do
        grep -E "^ssh"$'\t'"$h"$'\t'".*mv -f -- " "$FAKE_SSH_LOG" \
            | grep -qE "/run_iperf_${h}_${IPERF_RUN_ID}\.sh'$" || {
            echo "expected $h's script renamed onto run_iperf_${h}_${IPERF_RUN_ID}.sh" >&2
            cat "$FAKE_SSH_LOG" >&2
            return 1
        }
    done
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
    # Inside the test's temp dir, so the sandbox ssh (run_tests.sh
    # --sandbox) can really create it.
    local rd="$TEST_TMPDIR/custom/remote"
    run_with_fakes --remote-dir="$rd" distribute-scripts >/dev/null
    grep -F "_iod='$rd'" "$FAKE_SSH_LOG" | grep -qF "mkdir -p -m 700" || {
        echo "expected --remote-dir to propagate to mkdir target" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    }
    grep -E '^scp' "$FAKE_SSH_LOG" | awk -F'\t' '{print $3}' \
        | grep -qF "$rd/.run_iperf_a_${IPERF_RUN_ID}.sh." || {
        echo "expected scp dst at $rd/.run_iperf_a_${IPERF_RUN_ID}.sh.<tmp>" >&2
        return 1
    }
}

test_distribute_scripts_dies_without_a_run_to_resolve() {
    # Server list set but no create-scripts has been run -> no run dir
    # to resolve. distribute-scripts should die with a clear message.
    install_fake_ssh
    write_server_list x y >/dev/null
    rm -rf "$RESULTS_BASE"
    : > "$FAKE_SSH_LOG"
    run_with_fakes distribute-scripts
    assert_ne 0 "$RUN_RC" "should fail when no run exists" || return 1
    assert_contains "$RUN_OUT" "not found" || return 1
}

run_test test_distribute_scripts_uploads_one_per_host
run_test test_distribute_scripts_each_destination_includes_host_and_run_id
run_test test_distribute_scripts_chmods_remote_script
run_test test_distribute_scripts_creates_remote_dir
run_test test_distribute_scripts_removes_only_this_runs_stale_files
run_test test_distribute_scripts_dies_when_no_server_list
run_test test_distribute_scripts_uses_remote_dir_flag
run_test test_distribute_scripts_dies_without_a_run_to_resolve

report_tests
