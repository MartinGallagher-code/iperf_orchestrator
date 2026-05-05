#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for the path-related global flags --output, --servers,
# --remote-dir, --python, --ssh-user. Each must propagate to the right
# place(s) so that overriding it actually changes behavior.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# ---- --output -------------------------------------------------------------

test_output_flag_writes_to_chosen_path() {
    install_fake_ssh
    local custom="$TEST_TMPDIR/elsewhere/results"
    write_server_list a b >/dev/null
    PATH="$FAKE_BIN:$PATH" run_orch --output "$custom" --run-id myrun create-scripts >/dev/null
    assert_status 0 "$RUN_RC" || return 1
    [ -d "$custom/myrun" ] || { echo "missing: $custom/myrun" >&2; return 1; }
    [ -d "$custom/myrun/scripts" ] || return 1
    [ -f "$custom/myrun/scripts/run_a_myrun.sh" ] || return 1
    [ -f "$custom/myrun/scripts/run_b_myrun.sh" ] || return 1
    [ -L "$custom/latest" ] || { echo "expected latest symlink" >&2; return 1; }
    assert_eq "myrun" "$(readlink "$custom/latest")" "latest should point at myrun" || return 1
}

test_output_flag_default_results_dir_no_state_in_home() {
    install_fake_ssh
    write_server_list a b >/dev/null
    PATH="$FAKE_BIN:$PATH" run_orch --run-id myrun --output "$RESULTS_BASE" create-scripts >/dev/null
    assert_status 0 "$RUN_RC" || return 1
    # Nothing should have been written to $HOME/.iperf_orchestrator
    [ ! -e "$HOME/.iperf_orchestrator" ] || {
        echo "should NOT have created \$HOME/.iperf_orchestrator" >&2
        return 1
    }
}

test_run_id_resolves_existing_run_for_read_commands() {
    # Pre-fab two run dirs with iperf_results.csv stubs
    mkdir -p "$RESULTS_BASE/old/scripts" "$RESULTS_BASE/new/scripts"
    cat > "$RESULTS_BASE/old/iperf_results.csv" <<'EOF'
timestamp,source,target,status,protocol,duration_s,parallel_streams,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error
,a,b,OK,TCP,10,1,1000,800,0.001,5001,40000,a,b,fake,
,b,a,OK,TCP,10,1,1000,800,0.001,5001,40000,a,b,fake,
EOF
    cp "$RESULTS_BASE/old/iperf_results.csv" "$RESULTS_BASE/new/iperf_results.csv"
    ln -sfn new "$RESULTS_BASE/latest"
    run_orch --run-id old results-summary
    assert_status 0 "$RUN_RC" || return 1
}

test_read_command_uses_latest_when_no_run_id() {
    mkdir -p "$RESULTS_BASE/r1"
    cat > "$RESULTS_BASE/r1/iperf_results.csv" <<'EOF'
timestamp,source,target,status,protocol,duration_s,parallel_streams,bytes_transferred,bps,mbps,src_port,dst_port,pair_a,pair_b,filename,error
,a,b,OK,TCP,10,1,1000,800,0.001,5001,40000,a,b,fake,
EOF
    ln -sfn r1 "$RESULTS_BASE/latest"
    unset IPERF_RUN_ID
    run_orch results-summary
    assert_status 0 "$RUN_RC" "results-summary via 'latest' symlink should work" || return 1
}

test_read_command_dies_without_runs() {
    unset IPERF_RUN_ID
    rm -rf "$RESULTS_BASE"
    run_orch results-summary
    assert_status 1 "$RUN_RC" "should die when no runs exist" || return 1
    assert_contains "$RUN_OUT" "no results found" || return 1
}

# ---- --remote-dir --------------------------------------------------------

test_remote_dir_propagates_to_generated_scripts() {
    install_fake_ssh
    write_server_list a b >/dev/null
    : > "$FAKE_SSH_LOG"
    PATH="$FAKE_BIN:$PATH" run_orch --remote-dir=/var/myremote --run-id myrun create-scripts >/dev/null
    PATH="$FAKE_BIN:$PATH" run_orch --remote-dir=/var/myremote --run-id myrun distribute-scripts >/dev/null
    grep -q "mkdir -p '/var/myremote'" "$FAKE_SSH_LOG" || {
        echo "expected mkdir -p '/var/myremote' on remote" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    }
    grep -E '^scp' "$FAKE_SSH_LOG" | awk -F'\t' '{print $3}' \
        | grep -q '/var/myremote/run_iperf_a_myrun.sh' || {
        echo "expected scp dst at /var/myremote/run_iperf_a_myrun.sh" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    }
}

# ---- --ssh-user ----------------------------------------------------------

test_ssh_user_propagates_to_ssh_invocations() {
    install_fake_ssh
    write_server_list a b >/dev/null
    cat > "$FAKE_BIN/ssh" <<'SHIM'
#!/usr/bin/env bash
LOG="${FAKE_SSH_LOG}"
target=""
for arg in "$@"; do
    case "$arg" in
        *@*) target="$arg"; break ;;
    esac
done
echo "TARGET=$target" >> "$LOG"
exit 1
SHIM
    chmod +x "$FAKE_BIN/ssh"
    : > "$FAKE_SSH_LOG"
    PATH="$FAKE_BIN:$PATH" run_orch --ssh-user=alice check-servers >/dev/null
    grep -q "TARGET=alice@a" "$FAKE_SSH_LOG" || {
        echo "ssh target should be alice@a" >&2; cat "$FAKE_SSH_LOG" >&2; return 1
    }
    grep -q "TARGET=alice@b" "$FAKE_SSH_LOG" || return 1
}

# ---- --python ------------------------------------------------------------

test_python_flag_uses_alternate_interpreter() {
    local fakepy="$TEST_TMPDIR/python-wrap"
    cat > "$fakepy" <<'EOF'
#!/usr/bin/env bash
echo "PYTHON_WRAPPER_INVOKED" >&2
exec python3 "$@"
EOF
    chmod +x "$fakepy"
    mkdir -p "$RESULTS_BASE/myrun"
    cat > "$RESULTS_BASE/myrun/iperf_test_a_to_b_myrun.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,1100000000,880000000
EOF
    run_orch --run-id myrun --python "$fakepy" parse-csv
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "PYTHON_WRAPPER_INVOKED" \
        "expected the wrapper python to be invoked" || return 1
}

test_python_flag_dies_when_interpreter_missing() {
    mkdir -p "$RESULTS_BASE/myrun"
    cat > "$RESULTS_BASE/myrun/iperf_test_a_to_b_myrun.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000
EOF
    run_orch --run-id myrun --python /no/such/python parse-csv
    assert_ne 0 "$RUN_RC" "missing python should exit non-zero" || return 1
    assert_contains "$RUN_OUT" "not found" || return 1
}

# ---- multiple flags chained ---------------------------------------------

test_multiple_global_flags_take_effect_together() {
    local custom="$TEST_TMPDIR/multi"
    run_orch --output "$custom" --port=7777 --jobs=4 --duration=30 status
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "$custom" || return 1
}

run_test test_output_flag_writes_to_chosen_path
run_test test_output_flag_default_results_dir_no_state_in_home
run_test test_run_id_resolves_existing_run_for_read_commands
run_test test_read_command_uses_latest_when_no_run_id
run_test test_read_command_dies_without_runs
run_test test_remote_dir_propagates_to_generated_scripts
run_test test_ssh_user_propagates_to_ssh_invocations
run_test test_python_flag_uses_alternate_interpreter
run_test test_python_flag_dies_when_interpreter_missing
run_test test_multiple_global_flags_take_effect_together

report_tests
