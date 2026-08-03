#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for matrix_agent/fleet.sh. Real SSH is faked with logging shims
# (the same FAKE_BIN pattern the orchestrator tests use), so these
# verify the exact remote invocations fleet.sh constructs without
# needing a fleet.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

AGENT="$REPO_ROOT/matrix_agent/matrix_agent.py"
FLEET="$REPO_ROOT/matrix_agent/fleet.sh"

_fleet_env() {
    # Fake ssh/scp that log their argv and succeed. ssh echoes nothing
    # (so status parsing isn't exercised here); scp copies nothing.
    export FLEET_LOG="$TEST_TMPDIR/fleet.log"
    : > "$FLEET_LOG"
    mkdir -p "$FAKE_BIN"
    for tool in ssh scp; do
        cat > "$FAKE_BIN/$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >> "\$FLEET_LOG"
exit 0
EOF
        chmod +x "$FAKE_BIN/$tool"
    done
    cat > "$TEST_TMPDIR/hosts.txt" <<EOF
alpha=10.0.0.1
beta=10.0.0.2:5299
EOF
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/hosts.txt" --rate-mbps 10 \
        -o "$TEST_TMPDIR/matrix.csv" >/dev/null
}

_run_fleet() {
    PATH="$FAKE_BIN:$PATH" "$FLEET" --matrix "$TEST_TMPDIR/matrix.csv" \
        --jobs 4 "$@" >"$TEST_TMPDIR/out" 2>&1
}

test_hosts_subcommand_lists_matrix_hosts() {
    _fleet_env
    local out; out=$(python3 "$AGENT" hosts --matrix "$TEST_TMPDIR/matrix.csv")
    assert_contains "$out" "alpha 10.0.0.1 5220" "default port applied" || return 1
    assert_contains "$out" "beta 10.0.0.2 5299" "explicit port kept" || return 1
}

test_deploy_pushes_agent_and_matrix_to_every_host() {
    _fleet_env
    _run_fleet deploy || { cat "$TEST_TMPDIR/out"; return 1; }
    local log; log=$(cat "$FLEET_LOG")
    assert_contains "$log" "mkdir -p '/var/tmp/mxa/rep'" || return 1
    assert_contains "$log" "matrix_agent.py" "agent shipped" || return 1
    assert_contains "$log" "10.0.0.1:/var/tmp/mxa/" "alpha targeted" || return 1
    assert_contains "$log" "10.0.0.2:/var/tmp/mxa/" "beta targeted" || return 1
    # One mkdir ssh + one scp per host.
    assert_eq "2" "$(grep -c '^scp ' "$FLEET_LOG")" "one scp per host" || return 1
}

test_start_passes_hostname_and_agent_flags() {
    _fleet_env
    _run_fleet start -- --protocol udp --interval 30 || { cat "$TEST_TMPDIR/out"; return 1; }
    local log; log=$(cat "$FLEET_LOG")
    assert_contains "$log" "--hostname 'alpha'" "identity pinned per host" || return 1
    assert_contains "$log" "--hostname 'beta'" || return 1
    assert_contains "$log" "--protocol udp" "agent flags forwarded" || return 1
    assert_contains "$log" "--interval 30" || return 1
    assert_contains "$log" "nohup python3 matrix_agent.py run" || return 1
}

test_stop_and_reload_signal_agents() {
    _fleet_env
    _run_fleet stop || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_contains "$(cat "$FLEET_LOG")" "pkill -TERM -f 'matrix_agent.py run'" || return 1
    : > "$FLEET_LOG"
    _run_fleet reload || { cat "$TEST_TMPDIR/out"; return 1; }
    local log; log=$(cat "$FLEET_LOG")
    assert_contains "$log" "pkill -HUP -f 'matrix_agent.py run'" || return 1
    assert_contains "$log" "matrix.csv" "reload re-ships the matrix" || return 1
}

test_ssh_user_and_remote_dir_options() {
    _fleet_env
    _run_fleet --user opsuser --remote-dir /opt/mxa deploy \
        || { cat "$TEST_TMPDIR/out"; return 1; }
    local log; log=$(cat "$FLEET_LOG")
    assert_contains "$log" "opsuser@10.0.0.1" "user applied to ssh target" || return 1
    assert_contains "$log" "mkdir -p '/opt/mxa/rep'" "remote dir honored" || return 1
}

test_failed_host_is_reported_and_exit_nonzero() {
    _fleet_env
    # ssh fails for beta only.
    cat > "$FAKE_BIN/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh \$*" >> "\$FLEET_LOG"
case "\$*" in *10.0.0.2*) exit 255 ;; esac
exit 0
EOF
    chmod +x "$FAKE_BIN/ssh"
    local rc=0
    _run_fleet deploy || rc=$?
    [ "$rc" -ne 0 ] || { echo "deploy should fail when a host fails"; cat "$TEST_TMPDIR/out"; return 1; }
    assert_contains "$(cat "$TEST_TMPDIR/out")" "1/2 hosts failed" || return 1
    assert_contains "$(cat "$TEST_TMPDIR/out")" "beta" "failing host named" || return 1
}

test_orchestrator_matrix_subcommand_forwards_to_fleet() {
    _fleet_env
    # `matrix --help` through the orchestrator must reach fleet.sh's
    # usage text, proving the pre-parse dispatch fires before the
    # orchestrator's own flag validation could reject --help's friends.
    run_orch matrix --help
    assert_status 0 "$RUN_RC" "matrix --help should exit 0" || return 1
    assert_contains "$RUN_OUT" "fleet.sh" "fleet usage reached" || return 1
    assert_contains "$RUN_OUT" "summarize" || return 1
}

test_orchestrator_matrix_forwards_fleet_flags_untouched() {
    _fleet_env
    # --matrix is a fleet.sh flag the orchestrator's global parser would
    # reject; through the matrix pass-through it must work end-to-end.
    PATH="$FAKE_BIN:$PATH" run_orch matrix \
        --matrix "$TEST_TMPDIR/matrix.csv" --jobs 2 stop
    assert_status 0 "$RUN_RC" "matrix stop via orchestrator" || return 1
    assert_contains "$(cat "$FLEET_LOG")" "pkill -TERM -f 'matrix_agent.py run'" || return 1
}

run_test test_hosts_subcommand_lists_matrix_hosts
run_test test_orchestrator_matrix_subcommand_forwards_to_fleet
run_test test_orchestrator_matrix_forwards_fleet_flags_untouched
run_test test_deploy_pushes_agent_and_matrix_to_every_host
run_test test_start_passes_hostname_and_agent_flags
run_test test_stop_and_reload_signal_agents
run_test test_ssh_user_and_remote_dir_options
run_test test_failed_host_is_reported_and_exit_nonzero

report_tests
