#!/usr/bin/env bash
# Tests for the path-related global flags --iperf-dir, --remote-dir,
# --python, --ssh-user. Each must propagate to the right place(s) so
# that overriding it actually changes behavior, not just env state.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# ---- --iperf-dir ----------------------------------------------------------

test_iperf_dir_creates_subdirs() {
    local custom="$TEST_TMPDIR/elsewhere/iperf"
    run_orch --iperf-dir "$custom" status >/dev/null 2>&1
    assert_status 0 "$RUN_RC" || return 1
    [ -d "$custom" ] || { echo "missing: $custom" >&2; return 1; }
    [ -d "$custom/results" ] || return 1
    [ -d "$custom/logs" ] || return 1
    [ -d "$custom/scripts" ] || return 1
}

test_iperf_dir_state_writes_to_chosen_path() {
    local custom="$TEST_TMPDIR/elsewhere/iperf"
    local src="$TEST_TMPDIR/srv.txt"
    echo h1 > "$src"
    run_orch --iperf-dir "$custom" init "$src"
    [ -f "$custom/state" ] || {
        echo "state file should be in custom dir" >&2
        return 1
    }
    grep -q '^SERVER_LIST_LOADED=yes$' "$custom/state" || return 1
    # Default location should NOT have been touched.
    [ ! -d "$IPERF_DIR" ] || \
        [ ! -f "$IPERF_DIR/state" ] || {
        echo "default IPERF_DIR should not have a state file" >&2
        return 1
    }
}

test_iperf_dir_status_consistent_across_invocations() {
    local custom="$TEST_TMPDIR/altdir"
    local src="$TEST_TMPDIR/srv.txt"
    printf 'a\nb\n' > "$src"
    run_orch --iperf-dir "$custom" init "$src" >/dev/null 2>&1
    run_orch --iperf-dir "$custom" create-scripts >/dev/null 2>&1
    run_orch --iperf-dir "$custom" status
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "$custom" "status should show custom path" || return 1
    assert_contains "$RUN_OUT" "SCRIPTS_CREATED                yes" || return 1
    # Generated scripts also live there.
    [ -f "$custom/scripts/run_a.sh" ] || return 1
}

# ---- --remote-dir --------------------------------------------------------

test_remote_dir_propagates_to_generated_scripts() {
    local src="$TEST_TMPDIR/srv.txt"
    printf 'a\nb\n' > "$src"
    run_orch init "$src" >/dev/null 2>&1
    run_orch --remote-dir=/var/myremote create-scripts >/dev/null 2>&1
    # Generated script writes its log file relative to the dir it was
    # cd'd into. cmd_distribute_scripts puts the script under
    # $REMOTE_DIR/run_iperf.sh. Let's verify the dispatcher uses the
    # custom path.
    install_fake_ssh
    : > "$FAKE_SSH_LOG"
    PATH="$FAKE_BIN:$PATH" run_orch --remote-dir=/var/myremote distribute-scripts >/dev/null
    grep -q "mkdir -p '/var/myremote'" "$FAKE_SSH_LOG" || {
        echo "expected mkdir -p '/var/myremote' on remote" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    }
    grep -E '^scp' "$FAKE_SSH_LOG" | awk -F'\t' '{print $3}' \
        | grep -q '/var/myremote/run_iperf.sh' || {
        echo "expected scp dst at /var/myremote/run_iperf.sh" >&2
        return 1
    }
}

# ---- --ssh-user ----------------------------------------------------------

test_ssh_user_propagates_to_ssh_invocations() {
    local src="$TEST_TMPDIR/srv.txt"
    printf 'a\nb\n' > "$src"
    run_orch init "$src" >/dev/null 2>&1
    install_fake_ssh
    : > "$FAKE_SSH_LOG"
    PATH="$FAKE_BIN:$PATH" run_orch --ssh-user=alice check-servers >/dev/null
    # The fake-ssh log records the host (no user prefix in tab field).
    # We verify by looking at the ssh argv shape via a side inspection:
    # the orchestrator's ssh_run uses "$SSH_USER@$host". Our shim
    # parses and only stores host -- but our test below checks the
    # process commandline differently: re-install a shim that records
    # the FULL target.
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
exit 1   # simulate "no iperf running" so check-servers completes quickly
SHIM
    chmod +x "$FAKE_BIN/ssh"
    : > "$FAKE_SSH_LOG"
    PATH="$FAKE_BIN:$PATH" run_orch --ssh-user=alice check-servers >/dev/null
    grep -q "TARGET=alice@a" "$FAKE_SSH_LOG" || {
        echo "ssh target should be alice@a" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    }
    grep -q "TARGET=alice@b" "$FAKE_SSH_LOG" || {
        echo "ssh target should be alice@b" >&2
        return 1
    }
}

# ---- --python ------------------------------------------------------------

test_python_flag_uses_alternate_interpreter() {
    # Make a wrapper that sets a marker env var visible to the launched
    # python. We then assert on the marker via stdout.
    local fakepy="$TEST_TMPDIR/python-wrap"
    cat > "$fakepy" <<'EOF'
#!/usr/bin/env bash
echo "PYTHON_WRAPPER_INVOKED" >&2
exec python3 "$@"
EOF
    chmod +x "$fakepy"
    mkdir -p "$IPERF_DIR/results"
    cat > "$IPERF_DIR/results/iperf_test_a_to_b.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,1100000000,880000000
EOF
    run_orch --python "$fakepy" parse-csv
    assert_status 0 "$RUN_RC" || return 1
    # The wrapper writes its marker to stderr; that's captured by run_orch.
    assert_contains "$RUN_OUT" "PYTHON_WRAPPER_INVOKED" \
        "expected the wrapper python to be invoked" || return 1
}

test_python_flag_dies_when_interpreter_missing() {
    mkdir -p "$IPERF_DIR/results"
    cat > "$IPERF_DIR/results/iperf_test_a_to_b.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000
EOF
    run_orch --python /no/such/python parse-csv
    assert_ne 0 "$RUN_RC" "missing python should exit non-zero" || return 1
    assert_contains "$RUN_OUT" "not found" || return 1
}

# ---- multiple flags chained ---------------------------------------------

test_multiple_global_flags_take_effect_together() {
    local custom="$TEST_TMPDIR/multi"
    run_orch --iperf-dir "$custom" --port=7777 --jobs=4 --duration=30 status
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "$custom" || return 1
    # Status output also dumps the help banner snippet showing values.
    # We exercised one path -- just validate that the directory creation
    # happened with the requested IPERF_DIR.
    [ -d "$custom" ] || return 1
}

run_test test_iperf_dir_creates_subdirs
run_test test_iperf_dir_state_writes_to_chosen_path
run_test test_iperf_dir_status_consistent_across_invocations
run_test test_remote_dir_propagates_to_generated_scripts
run_test test_ssh_user_propagates_to_ssh_invocations
run_test test_python_flag_uses_alternate_interpreter
run_test test_python_flag_dies_when_interpreter_missing
run_test test_multiple_global_flags_take_effect_together

report_tests
