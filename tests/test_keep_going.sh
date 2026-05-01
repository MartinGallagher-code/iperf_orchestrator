#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for the --keep-going flag in cmd_all and the failure-aware
# state-flagging that goes with it. Without --keep-going, cmd_all
# aborts on the first step with worker failures; with --keep-going,
# it logs a warning and continues.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# A reasonably full ssh shim with knobs:
#   $FAKE_BIN/unreachable  -- newline-separated list of hosts that
#                              fail every ssh call (exit 255).
#   $FAKE_BIN/iperf_running_<host> -- mark a host's daemon as running.
install_failable_ssh() {
    install_fake_ssh
    # Augment the existing shim so doctor's tool probes find what
    # they need. Doctor probes ssh, scp, ssh-copy-id, ssh-keygen.
    local tool
    for tool in scp ssh-copy-id ssh-keygen; do
        echo '#!/usr/bin/env bash' > "$FAKE_BIN/$tool"
        echo 'exit 0' >> "$FAKE_BIN/$tool"
        chmod +x "$FAKE_BIN/$tool"
    done
    # Pre-existing ssh key avoids cmd_ssh_setup's keygen path.
    mkdir -p "$TEST_TMPDIR/home/.ssh"
    : > "$TEST_TMPDIR/home/.ssh/id_ed25519"
    : > "$TEST_TMPDIR/home/.ssh/id_ed25519.pub"
    chmod 600 "$TEST_TMPDIR/home/.ssh/id_ed25519"
    export HOME="$TEST_TMPDIR/home"
}

prep_workflow() {
    install_failable_ssh
    local src="$TEST_TMPDIR/srv.txt"
    : > "$src"
    local h
    for h in "$@"; do
        printf '%s\n' "$h" >> "$src"
    done
    PATH="$FAKE_BIN:$PATH" run_orch init "$src" >/dev/null 2>&1
    : > "$FAKE_SSH_LOG"
}

run_with_fakes() {
    PATH="$FAKE_BIN:$PATH" run_orch "$@"
}

# ---- --keep-going flag parsing --------------------------------------------

test_keep_going_flag_is_recognized_by_cmd_all() {
    prep_workflow a b
    # Mark SSH already done so cmd_all doesn't try ssh-setup.
    set -- "$IPERF_DIR/state"; printf '%s\n' "SSH_KEYS_DISTRIBUTED=yes" >> "$1"
    # cmd_all consumes "--keep-going" itself; the flag pre-pass would
    # reject it as unknown unless we use `--` to terminate global
    # flag parsing first.
    run_with_fakes -- all --keep-going
    # Even with all hosts reachable, doctor will fail on missing
    # python modules; with --keep-going, it continues -> we expect
    # the "continuing because --keep-going was passed" message.
    if echo "$RUN_OUT" | grep -q "doctor reported issues" \
       && ! echo "$RUN_OUT" | grep -q "continuing because --keep-going"; then
        echo "expected --keep-going to override doctor failure" >&2
        return 1
    fi
}

test_keep_going_can_appear_before_or_after_mode() {
    prep_workflow a b c
    # `all sequential-host --keep-going`
    run_with_fakes -- all sequential-host --keep-going >/dev/null 2>&1
    grep -q '^TESTS_RUN_MODE=sequential-host$' "$IPERF_DIR/state" || {
        echo "mode=sequential-host should be honored" >&2
        cat "$IPERF_DIR/state" >&2
        return 1
    }
    # `all --keep-going parallel`
    rm -rf "$IPERF_DIR"; mkdir -p "$IPERF_DIR"
    prep_workflow a b c
    run_with_fakes -- all --keep-going parallel >/dev/null 2>&1
    grep -q '^TESTS_RUN_MODE=parallel$' "$IPERF_DIR/state" || {
        echo "mode=parallel should be honored when --keep-going precedes mode" >&2
        cat "$IPERF_DIR/state" >&2
        return 1
    }
}

test_unknown_cmd_all_argument_is_rejected() {
    prep_workflow a b
    run_with_fakes -- all bogus-mode
    assert_ne 0 "$RUN_RC" "unknown cmd_all arg should die" || return 1
    assert_contains "$RUN_OUT" "unknown argument" || return 1
}

# ---- Doctor gate ---------------------------------------------------------

test_cmd_all_dies_without_keep_going_when_doctor_fails() {
    # The test env is missing numpy/pandas/matplotlib, so doctor
    # always fails. cmd_all should die without --keep-going.
    if python3 -c 'import numpy, pandas, matplotlib' 2>/dev/null; then
        echo "    SKIP test_cmd_all_dies_without_keep_going_when_doctor_fails: full python stack installed"
        return 0
    fi
    prep_workflow a b
    run_with_fakes -- all
    assert_ne 0 "$RUN_RC" "cmd_all should die when doctor fails" || return 1
    assert_contains "$RUN_OUT" "doctor reported issues" || return 1
    # State should not advance past doctor.
    if grep -q '^IPERF_INSTALLED_CHECKED=yes$' "$IPERF_DIR/state"; then
        echo "doctor failure should have stopped cmd_all before check-iperf" >&2
        cat "$IPERF_DIR/state" >&2
        return 1
    fi
}

test_cmd_all_continues_with_keep_going_when_doctor_fails() {
    if python3 -c 'import numpy, pandas, matplotlib' 2>/dev/null; then
        echo "    SKIP test_cmd_all_continues_with_keep_going_when_doctor_fails: full python stack installed"
        return 0
    fi
    prep_workflow a b
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going >/dev/null 2>&1
    # We should reach at least IPERF_INSTALLED_CHECKED.
    grep -q '^IPERF_INSTALLED_CHECKED=yes$' "$IPERF_DIR/state" || {
        echo "expected pipeline to continue past doctor with --keep-going" >&2
        cat "$IPERF_DIR/state" >&2
        return 1
    }
}

# ---- Per-step gate behavior -----------------------------------------------

test_keep_going_continues_past_per_host_failure() {
    # Mark one host unreachable. Without --keep-going, _all_gate dies
    # at the first step with PARALLEL_FAILED non-empty.
    prep_workflow good bad
    echo "bad" > "$FAKE_BIN/unreachable"
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going >/dev/null 2>&1
    # We should still flag IPERF_INSTALLED_CHECKED (the unreachable
    # host shows MISSING but the worker doesn't fail in our shim --
    # it just returns empty version, which classifies as MISSING).
    grep -q '^IPERF_INSTALLED_CHECKED=yes$' "$IPERF_DIR/state" || {
        echo "expected check-iperf to flag completion" >&2
        cat "$IPERF_DIR/state" >&2
        return 1
    }
}

test_keep_going_warning_message_appears_when_step_fails() {
    # Force start-servers to fail by making the fake ssh refuse the
    # nohup command for one host.
    prep_workflow good doomed
    # Patch the fake-ssh to fail nohup for "doomed".
    cat > "$FAKE_BIN/ssh" <<'SHIM'
#!/usr/bin/env bash
set -u
LOG="${FAKE_SSH_LOG:-$(dirname "$0")/calls.log}"
target=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift; [ $# -gt 0 ] && shift ;;
        -[a-zA-Z]) shift ;;
        *@*) target="$1"; shift; break ;;
        *) shift ;;
    esac
done
remote_cmd="$*"
host="${target#*@}"
printf 'ssh\t%s\t%s\n' "$host" "$remote_cmd" >> "$LOG"
case "$remote_cmd" in
    *"iperf -v"*) echo "iperf version 2.1.9 pthreads"; exit 0 ;;
    *"command -v mpstat"*) echo "yes"; exit 0 ;;
    *"nohup iperf"*)
        if [ "$host" = "doomed" ]; then
            exit 1   # simulate "won't start"
        fi
        exit 0
        ;;
    *"! pgrep"*) exit 0 ;;
    *"pgrep"*"iperf"*) exit 0 ;;
esac
exit 0
SHIM
    chmod +x "$FAKE_BIN/ssh"
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going
    # Continuation message expected.
    if ! echo "$RUN_OUT" | grep -q "continuing.*--keep-going"; then
        # Some steps may not fail; only assert when start-servers does.
        if echo "$RUN_OUT" | grep -q "start-servers had .* failure"; then
            echo "expected '--keep-going continuing' message after start-servers failure" >&2
            echo "$RUN_OUT" >&2
            return 1
        fi
    fi
}

test_without_keep_going_aborts_at_first_failed_step() {
    prep_workflow good doomed
    # Same patched ssh as above test.
    cat > "$FAKE_BIN/ssh" <<'SHIM'
#!/usr/bin/env bash
set -u
LOG="${FAKE_SSH_LOG:-$(dirname "$0")/calls.log}"
target=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift; [ $# -gt 0 ] && shift ;;
        -[a-zA-Z]) shift ;;
        *@*) target="$1"; shift; break ;;
        *) shift ;;
    esac
done
remote_cmd="$*"
host="${target#*@}"
printf 'ssh\t%s\t%s\n' "$host" "$remote_cmd" >> "$LOG"
case "$remote_cmd" in
    *"iperf -v"*) echo "iperf version 2.1.9 pthreads"; exit 0 ;;
    *"command -v mpstat"*) echo "yes"; exit 0 ;;
    *"nohup iperf"*)
        if [ "$host" = "doomed" ]; then
            exit 1
        fi
        exit 0
        ;;
    *"! pgrep"*) exit 0 ;;
    *"pgrep"*"iperf"*) exit 0 ;;
esac
exit 0
SHIM
    chmod +x "$FAKE_BIN/ssh"
    # Without --keep-going. Skip if doctor would fail first (no python
    # modules) -- in that case we can't reach start-servers.
    if ! python3 -c 'import numpy, pandas, matplotlib' 2>/dev/null; then
        echo "    SKIP test_without_keep_going_aborts_at_first_failed_step: doctor blocks before start-servers in this env"
        return 0
    fi
    run_with_fakes --start-delay=0 --duration=1 -- all
    assert_ne 0 "$RUN_RC" "should abort on first failed step" || return 1
}

# ---- Mode-and-flag combinations ----------------------------------------

test_cmd_all_default_keep_going_is_off() {
    # Without --keep-going, doctor failure is fatal in this env.
    if python3 -c 'import numpy, pandas, matplotlib' 2>/dev/null; then
        echo "    SKIP test_cmd_all_default_keep_going_is_off: full python stack installed"
        return 0
    fi
    prep_workflow a
    run_with_fakes -- all
    assert_ne 0 "$RUN_RC" "default cmd_all should be strict" || return 1
}

run_test test_keep_going_flag_is_recognized_by_cmd_all
run_test test_keep_going_can_appear_before_or_after_mode
run_test test_unknown_cmd_all_argument_is_rejected
run_test test_cmd_all_dies_without_keep_going_when_doctor_fails
run_test test_cmd_all_continues_with_keep_going_when_doctor_fails
run_test test_keep_going_continues_past_per_host_failure
run_test test_keep_going_warning_message_appears_when_step_fails
run_test test_without_keep_going_aborts_at_first_failed_step
run_test test_cmd_all_default_keep_going_is_off

report_tests
