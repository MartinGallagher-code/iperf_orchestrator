#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests that every documented config env var is honored. The
# orchestrator declares these at the top:
#
#   IPERF_DIR, REMOTE_DIR, IPERF_PORT, IPERF_DURATION, IPERF_PARALLEL,
#   IPERF_JOBS, SSH_USER, SSH_OPTS, START_DELAY, PYTHON_BIN
#   plus SSH_PASSWORD_FILE / SSH_PASSWORD_ENV / SSH_ASK_PASSWORD
#
# We verify each one actually changes behavior (or at least is
# echoed back into help / generated artifacts) -- not just that
# it's accepted.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# ---- Direct env-var -> help banner reflection -----------------------------
# The help banner echoes every config key with its current value.

test_iperf_port_env_propagates() {
    IPERF_PORT=22222 run_orch help
    assert_contains "$RUN_OUT" "IPERF_PORT=22222" || return 1
}

test_iperf_duration_env_propagates() {
    IPERF_DURATION=99 run_orch help
    assert_contains "$RUN_OUT" "IPERF_DURATION=99" || return 1
}

test_iperf_parallel_env_propagates() {
    IPERF_PARALLEL=8 run_orch help
    assert_contains "$RUN_OUT" "IPERF_PARALLEL=8" || return 1
}

test_iperf_jobs_env_propagates() {
    IPERF_JOBS=24 run_orch help
    assert_contains "$RUN_OUT" "IPERF_JOBS=24" || return 1
}

test_ssh_user_env_propagates() {
    SSH_USER=netadmin run_orch help
    assert_contains "$RUN_OUT" "SSH_USER=netadmin" || return 1
}

test_start_delay_env_propagates() {
    START_DELAY=120 run_orch help
    assert_contains "$RUN_OUT" "START_DELAY=120" || return 1
}

test_iperf_dir_env_propagates() {
    local custom="$TEST_TMPDIR/from_env_var"
    IPERF_DIR="$custom" run_orch help
    assert_contains "$RUN_OUT" "IPERF_DIR=$custom" || return 1
}

# ---- Env var actually changes behavior in subcommands --------------------

test_iperf_port_env_propagates_into_generated_scripts() {
    local src="$TEST_TMPDIR/srv.txt"
    printf 'a\nb\n' > "$src"
    IPERF_PORT=33333 run_orch init "$src" >/dev/null 2>&1
    IPERF_PORT=33333 run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$IPERF_DIR/scripts" -name 'run_*.sh' | head -n1)
    grep -q '^PORT=33333$' "$s" || {
        echo "PORT not propagated to generated script" >&2
        return 1
    }
}

test_iperf_duration_env_propagates_into_generated_scripts() {
    local src="$TEST_TMPDIR/srv.txt"
    printf 'a\nb\n' > "$src"
    IPERF_DURATION=42 run_orch init "$src" >/dev/null 2>&1
    IPERF_DURATION=42 run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$IPERF_DIR/scripts" -name 'run_*.sh' | head -n1)
    grep -q '^DURATION=42$' "$s" || return 1
}

test_iperf_parallel_env_propagates_into_generated_scripts() {
    local src="$TEST_TMPDIR/srv.txt"
    printf 'a\nb\n' > "$src"
    IPERF_PARALLEL=7 run_orch init "$src" >/dev/null 2>&1
    IPERF_PARALLEL=7 run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$IPERF_DIR/scripts" -name 'run_*.sh' | head -n1)
    grep -q '^PARALLEL=7$' "$s" || return 1
}

test_iperf_jobs_env_caps_concurrency() {
    # IPERF_JOBS=2 with 6 sleep-1 workers should take ~3 s, not ~1.
    # NOTE: must `export` so the variable survives the source_orch
    # function call. With the `VAR=val source_orch` env-prefix form,
    # bash restores VAR to its previous value after the function
    # returns, defeating the test.
    write_server_list h1 h2 h3 h4 h5 h6 >/dev/null
    export IPERF_JOBS=2
    source_orch
    _w_sleep1() { sleep 1; }
    local start end
    start=$(date +%s)
    parallel_hosts _w_sleep1 >/dev/null
    end=$(date +%s)
    local elapsed=$((end - start))
    if [ "$elapsed" -lt 2 ] || [ "$elapsed" -gt 5 ]; then
        echo "expected ~3s with IPERF_JOBS=2, got ${elapsed}s" >&2
        return 1
    fi
}

test_remote_dir_env_propagates_to_distribute() {
    install_fake_ssh
    local src="$TEST_TMPDIR/srv.txt"
    printf 'a\n' > "$src"
    PATH="$FAKE_BIN:$PATH" run_orch init "$src" >/dev/null 2>&1
    PATH="$FAKE_BIN:$PATH" run_orch create-scripts >/dev/null 2>&1
    : > "$FAKE_SSH_LOG"
    REMOTE_DIR=/from-env-var/remote PATH="$FAKE_BIN:$PATH" run_orch distribute-scripts >/dev/null
    grep -q "/from-env-var/remote" "$FAKE_SSH_LOG" || {
        echo "REMOTE_DIR env var not honored in distribute-scripts" >&2
        cat "$FAKE_SSH_LOG" >&2
        return 1
    }
}

test_python_bin_env_uses_alternate_interpreter() {
    local fakepy="$TEST_TMPDIR/python-marker"
    cat > "$fakepy" <<'EOF'
#!/usr/bin/env bash
echo "PY_ENV_MARKER" >&2
exec python3 "$@"
EOF
    chmod +x "$fakepy"
    mkdir -p "$IPERF_DIR/results"
    cat > "$IPERF_DIR/results/iperf_test_a_to_b.log" <<'EOF'
# pair_a=a pair_b=b duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,1100000000,880000000
EOF
    PYTHON_BIN="$fakepy" run_orch parse-csv
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "PY_ENV_MARKER" \
        "expected PYTHON_BIN env var to take effect" || return 1
}

# ---- SSH_OPTS env var --------------------------------------------------

test_ssh_opts_env_var_default_is_safe() {
    # The default contains StrictHostKeyChecking=accept-new which is
    # a sane new-host policy. Make sure that default appears in help.
    run_orch help
    # SSH_OPTS isn't echoed in the help text directly (only the keys
    # that get echoed are the user-tunable ones), but we can check
    # the default by sourcing the orchestrator.
    source_orch
    assert_contains "$SSH_OPTS" "StrictHostKeyChecking=accept-new" \
        "default SSH_OPTS should accept-new" || return 1
}

test_ssh_opts_env_override_is_used() {
    # Override SSH_OPTS via export (not env-prefix; see the comment in
    # test_iperf_jobs_env_caps_concurrency) and confirm it's reflected
    # in the script's internal vars after sourcing.
    export SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5"
    source_orch
    [ "$SSH_OPTS" = "-o BatchMode=yes -o ConnectTimeout=5" ] || {
        echo "SSH_OPTS env override not honored" >&2
        echo "got: $SSH_OPTS" >&2
        return 1
    }
}

# ---- Multiple env vars together ----------------------------------------

test_all_env_vars_set_at_once_dont_collide() {
    # Smoke test: every env var set together should still work.
    IPERF_PORT=11111 \
    IPERF_DURATION=20 \
    IPERF_PARALLEL=4 \
    IPERF_JOBS=8 \
    SSH_USER=netuser \
    START_DELAY=60 \
    REMOTE_DIR=/some/where \
    run_orch help
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "IPERF_PORT=11111" || return 1
    assert_contains "$RUN_OUT" "IPERF_DURATION=20" || return 1
    assert_contains "$RUN_OUT" "IPERF_JOBS=8" || return 1
    assert_contains "$RUN_OUT" "SSH_USER=netuser" || return 1
}

# ---- Validation also applies to env-only invocation -------------------

test_env_var_invalid_int_is_rejected() {
    IPERF_PORT=garbage run_orch help
    assert_status 2 "$RUN_RC" "garbage IPERF_PORT env var should be rejected" || return 1
}

test_env_var_zero_jobs_is_rejected() {
    IPERF_JOBS=0 run_orch help
    assert_status 2 "$RUN_RC" "IPERF_JOBS=0 env var should be rejected" || return 1
}

run_test test_iperf_port_env_propagates
run_test test_iperf_duration_env_propagates
run_test test_iperf_parallel_env_propagates
run_test test_iperf_jobs_env_propagates
run_test test_ssh_user_env_propagates
run_test test_start_delay_env_propagates
run_test test_iperf_dir_env_propagates
run_test test_iperf_port_env_propagates_into_generated_scripts
run_test test_iperf_duration_env_propagates_into_generated_scripts
run_test test_iperf_parallel_env_propagates_into_generated_scripts
run_test test_iperf_jobs_env_caps_concurrency
run_test test_remote_dir_env_propagates_to_distribute
run_test test_python_bin_env_uses_alternate_interpreter
run_test test_ssh_opts_env_var_default_is_safe
run_test test_ssh_opts_env_override_is_used
run_test test_all_env_vars_set_at_once_dont_collide
run_test test_env_var_invalid_int_is_rejected
run_test test_env_var_zero_jobs_is_rejected

report_tests
