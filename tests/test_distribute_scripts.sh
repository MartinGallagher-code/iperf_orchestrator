#!/usr/bin/env bash
# Tests for cmd_distribute_scripts. The worker:
#   1. mkdirs $REMOTE_DIR remotely
#   2. removes any stale iperf_test_*.log / status / complete files
#   3. scp's the per-host run script to $REMOTE_DIR/run_iperf.sh
#   4. chmods +x on the remote
# We cover all four steps and the failure path.

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
    : > "$FAKE_SSH_LOG"
}

run_with_fakes() {
    PATH="$FAKE_BIN:$PATH" run_orch "$@"
}

test_distribute_scripts_uploads_one_per_host() {
    prep_workflow alpha bravo charlie
    run_with_fakes distribute-scripts
    assert_status 0 "$RUN_RC" "distribute-scripts should succeed" || return 1
    grep -q '^SCRIPTS_DISTRIBUTED=yes$' "$IPERF_DIR/state" || return 1
    # Each host should see one scp upload.
    local n
    n=$(grep -c '^scp' "$FAKE_SSH_LOG")
    assert_eq "3" "$n" "expected one scp per host" || return 1
}

test_distribute_scripts_each_destination_is_run_iperf_sh() {
    prep_workflow a b
    run_with_fakes distribute-scripts >/dev/null
    # Every scp destination should end with /run_iperf.sh (renamed
    # from the per-host script name).
    if grep -E '^scp' "$FAKE_SSH_LOG" | awk -F'\t' '{print $3}' \
        | grep -vqE '/run_iperf\.sh$'; then
        echo "expected every scp dst to end in /run_iperf.sh" >&2
        grep -E '^scp' "$FAKE_SSH_LOG" >&2
        return 1
    fi
}

test_distribute_scripts_chmods_remote_script() {
    prep_workflow a b
    run_with_fakes distribute-scripts >/dev/null
    # ssh chmod call should happen for each host.
    local n
    n=$(grep -c -E "^ssh"$'\t'"[^"$'\t'"]+"$'\t'".*chmod \+x" "$FAKE_SSH_LOG")
    assert_eq "2" "$n" "should chmod +x on each remote" || return 1
}

test_distribute_scripts_creates_remote_dir() {
    prep_workflow a b
    run_with_fakes distribute-scripts >/dev/null
    # Worker runs `mkdir -p '$REMOTE_DIR' && rm -f ...` in one ssh call.
    local n
    n=$(grep -c -E "^ssh.*mkdir -p" "$FAKE_SSH_LOG")
    assert_eq "2" "$n" "should mkdir on each remote" || return 1
}

test_distribute_scripts_removes_stale_files() {
    prep_workflow a b
    run_with_fakes distribute-scripts >/dev/null
    # Worker removes stale iperf_test_*.log + status + complete.
    if ! grep -q -E 'rm -f .*iperf_test_\*\.log' "$FAKE_SSH_LOG"; then
        echo "expected rm -f iperf_test_*.log on remote" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    fi
    if ! grep -q -E 'iperf_run_\*\.status' "$FAKE_SSH_LOG"; then
        echo "expected stale status-file removal" >&2
        return 1
    fi
}

test_distribute_scripts_dies_when_no_server_list() {
    install_fake_ssh
    # Don't init.
    run_with_fakes distribute-scripts
    assert_ne 0 "$RUN_RC" "should fail without server list" || return 1
}

test_distribute_scripts_uses_remote_dir_flag() {
    prep_workflow a b
    run_with_fakes --remote-dir=/custom/remote distribute-scripts >/dev/null
    # The worker's mkdir -p target should be the custom path.
    grep -q "mkdir -p '/custom/remote'" "$FAKE_SSH_LOG" || {
        echo "expected --remote-dir to propagate to mkdir target" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    }
    # And the scp destination should land under that path.
    grep -E '^scp' "$FAKE_SSH_LOG" | awk -F'\t' '{print $3}' \
        | grep -q '/custom/remote/run_iperf.sh' || {
        echo "expected scp dst to be /custom/remote/run_iperf.sh" >&2
        return 1
    }
}

test_distribute_scripts_warns_when_no_per_host_script() {
    # Set up server list but DON'T run create-scripts. The worker
    # should warn for each host and the caller should report failures.
    install_fake_ssh
    local src="$TEST_TMPDIR/srv.txt"
    printf 'x\ny\n' > "$src"
    PATH="$FAKE_BIN:$PATH" run_orch init "$src" >/dev/null 2>&1
    : > "$FAKE_SSH_LOG"
    run_with_fakes distribute-scripts
    # State should not flag SCRIPTS_DISTRIBUTED.
    if grep -q '^SCRIPTS_DISTRIBUTED=yes$' "$IPERF_DIR/state"; then
        echo "should NOT flag SCRIPTS_DISTRIBUTED with no scripts" >&2
        return 1
    fi
    assert_contains "$RUN_OUT" "no script for" || return 1
    assert_contains "$RUN_OUT" "failure" "should report failure(s)" || return 1
}

run_test test_distribute_scripts_uploads_one_per_host
run_test test_distribute_scripts_each_destination_is_run_iperf_sh
run_test test_distribute_scripts_chmods_remote_script
run_test test_distribute_scripts_creates_remote_dir
run_test test_distribute_scripts_removes_stale_files
run_test test_distribute_scripts_dies_when_no_server_list
run_test test_distribute_scripts_uses_remote_dir_flag
run_test test_distribute_scripts_warns_when_no_per_host_script

report_tests
