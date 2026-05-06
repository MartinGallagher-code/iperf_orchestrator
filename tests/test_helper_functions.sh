#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Direct unit tests for the orchestrator's small internal helpers
# that don't have a dedicated test file yet:
#
#   ts()                 timestamp formatter
#   log() / warn() / err()  logging primitives
#   die()                error+exit
#   build_host_idx       populates HOST_IDX
#   ssh_run / scp_to / scp_from  thin wrappers (sanity-only)
#   _orchestrator_signal_cleanup  signal handler (basic shape)
#
# These are mostly tiny but together they're the spine of the script.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# ---- ts() / log() / warn() / err() ---------------------------------------

test_ts_returns_iso8601_like_format() {
    source_orch
    local out
    out=$(ts)
    # Format: YYYY-MM-DD HH:MM:SS
    if ! [[ "$out" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        echo "ts() should return 'YYYY-MM-DD HH:MM:SS', got: <$out>" >&2
        return 1
    fi
}

test_log_writes_to_stdout_and_logfile() {
    source_orch
    _ensure_run_id
    local msg="hello-from-log-$$"
    log "$msg" >"$TEST_TMPDIR/log.out"
    grep -qF "$msg" "$TEST_TMPDIR/log.out" || {
        echo "log() should write to stdout" >&2; return 1; }
    grep -qF "$msg" "$LOGS_DIR/orchestrator.log" || {
        echo "log() should also append to orchestrator.log" >&2
        cat "$LOGS_DIR/orchestrator.log" >&2
        return 1
    }
}

test_warn_goes_to_stderr_and_logfile() {
    source_orch
    _ensure_run_id
    local msg="warning-from-test-$$"
    warn "$msg" 2>"$TEST_TMPDIR/warn.err"
    grep -qF "$msg" "$TEST_TMPDIR/warn.err" || {
        echo "warn() should write to stderr" >&2; return 1; }
    grep -qF "WARN: $msg" "$LOGS_DIR/orchestrator.log" || {
        echo "warn() should append to orchestrator.log with WARN: prefix" >&2
        cat "$LOGS_DIR/orchestrator.log" >&2
        return 1
    }
}

test_err_goes_to_stderr_and_logfile() {
    source_orch
    _ensure_run_id
    local msg="err-from-test-$$"
    err "$msg" 2>"$TEST_TMPDIR/err.err"
    grep -qF "$msg" "$TEST_TMPDIR/err.err" || return 1
    grep -qF "ERROR: $msg" "$LOGS_DIR/orchestrator.log" || return 1
}

test_die_exits_nonzero_and_logs_error() {
    source_orch
    _ensure_run_id
    # Must run in a subshell so the exit doesn't kill the test.
    (
        die "fatal-test-$$" 2>"$TEST_TMPDIR/die.err"
    )
    local rc=$?
    [ "$rc" -eq 1 ] || {
        echo "die should exit 1, got $rc" >&2; return 1; }
    grep -qF "fatal-test-$$" "$TEST_TMPDIR/die.err" || return 1
    grep -qF "ERROR: fatal-test-$$" "$LOGS_DIR/orchestrator.log" || return 1
}

# ---- build_host_idx -----------------------------------------------------

test_build_host_idx_populates_zero_based_indices() {
    write_server_list h0 h1 h2 h3 >/dev/null
    source_orch
    build_host_idx
    [ "${HOST_IDX[h0]}" = "0" ] || { echo "h0 -> ${HOST_IDX[h0]} != 0" >&2; return 1; }
    [ "${HOST_IDX[h1]}" = "1" ] || return 1
    [ "${HOST_IDX[h2]}" = "2" ] || return 1
    [ "${HOST_IDX[h3]}" = "3" ] || return 1
}

test_build_host_idx_skips_blank_lines() {
    cat > "$IPERF_SERVERS" <<'EOF'
host-a

host-b
EOF
    source_orch
    build_host_idx
    [ "${HOST_IDX[host-a]}" = "0" ] || return 1
    [ "${HOST_IDX[host-b]}" = "1" ] || return 1
    if [ -n "${HOST_IDX[''+]:-}" ]; then
        echo "blank line ended up in HOST_IDX" >&2
        return 1
    fi
}

test_build_host_idx_resets_on_repeated_calls() {
    write_server_list h0 h1 h2 >/dev/null
    source_orch
    build_host_idx
    # Now switch to a different list and rebuild.
    write_server_list new-a new-b >/dev/null
    build_host_idx
    [ "${HOST_IDX[new-a]}" = "0" ] || return 1
    [ "${HOST_IDX[new-b]}" = "1" ] || return 1
    # Old hosts should NOT be in the index after rebuild.
    if [ -n "${HOST_IDX[h0]:-}" ]; then
        echo "old host h0 still in HOST_IDX after rebuild" >&2
        return 1
    fi
}

# ---- _validate_uint helper (via flag harness) ---------------------------

test_validate_uint_accepts_decimal_zero_for_min_zero() {
    # START_DELAY allows 0 (sync without waiting).
    run_orch --start-delay=0 help
    assert_status 0 "$RUN_RC" || return 1
}

test_validate_uint_rejects_empty_string() {
    # `--port=` makes IPERF_PORT empty after the equals split.
    run_orch --port= help
    assert_status 2 "$RUN_RC" "empty value should be rejected" || return 1
}

test_validate_uint_rejects_huge_garbage() {
    run_orch --ssh-jobs=1abc help
    assert_status 2 "$RUN_RC" "trailing garbage should be rejected" || return 1
}

# ---- ssh_run/scp wrappers (sanity) -------------------------------------

test_ssh_run_propagates_user_and_host_to_argv() {
    install_fake_ssh
    source_orch
    # Put the fake on PATH so the bare `ssh` invocation inside ssh_run
    # resolves to our shim, not the system binary (which would fail).
    PATH="$FAKE_BIN:$PATH" SSH_USER=alice ssh_run somehost "echo hello"
    grep -E "^ssh"$'\t'"somehost" "$FAKE_SSH_LOG" >/dev/null || {
        echo "ssh_run should hit the fake shim with host=somehost" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    }
}

test_ssh_run_interactive_uses_non_batch_opts() {
    # ssh_run_interactive is identical to ssh_run except SSH_OPTS not
    # SSH_BATCH_OPTS. Both should hit the fake. Sanity check that the
    # function exists and is callable without error.
    install_fake_ssh
    source_orch
    PATH="$FAKE_BIN:$PATH" ssh_run_interactive somehost "echo from-interactive"
    grep -q "somehost" "$FAKE_SSH_LOG" || return 1
}

# ---- read_servers + ts integration --------------------------------------

test_log_includes_timestamp_prefix() {
    source_orch
    _ensure_run_id
    local msg="logfmt-$$"
    log "$msg" >"$TEST_TMPDIR/log.out"
    # Format: "[YYYY-MM-DD HH:MM:SS] msg"
    if ! grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] '"$msg"'$' \
        "$TEST_TMPDIR/log.out"; then
        echo "log line missing timestamp prefix:" >&2
        cat "$TEST_TMPDIR/log.out" >&2
        return 1
    fi
}

run_test test_ts_returns_iso8601_like_format
run_test test_log_writes_to_stdout_and_logfile
run_test test_warn_goes_to_stderr_and_logfile
run_test test_err_goes_to_stderr_and_logfile
run_test test_die_exits_nonzero_and_logs_error
run_test test_build_host_idx_populates_zero_based_indices
run_test test_build_host_idx_skips_blank_lines
run_test test_build_host_idx_resets_on_repeated_calls
run_test test_validate_uint_accepts_decimal_zero_for_min_zero
run_test test_validate_uint_rejects_empty_string
run_test test_validate_uint_rejects_huge_garbage
run_test test_ssh_run_propagates_user_and_host_to_argv
run_test test_ssh_run_interactive_uses_non_batch_opts
run_test test_log_includes_timestamp_prefix

report_tests
