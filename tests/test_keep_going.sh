#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for the --keep-going flag in cmd_all. Without --keep-going,
# cmd_all aborts on the first step with worker failures; with it, it
# logs a warning and continues. (--resume was removed in the stateless
# refactor; cmd_all now generates a fresh run-id every invocation.)

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

install_failable_ssh() {
    install_fake_ssh
    local tool
    for tool in scp ssh-keygen; do
        echo '#!/usr/bin/env bash' > "$FAKE_BIN/$tool"
        echo 'exit 0' >> "$FAKE_BIN/$tool"
        chmod +x "$FAKE_BIN/$tool"
    done
    mkdir -p "$TEST_TMPDIR/home/.ssh"
    : > "$TEST_TMPDIR/home/.ssh/id_ed25519"
    : > "$TEST_TMPDIR/home/.ssh/id_ed25519.pub"
    chmod 600 "$TEST_TMPDIR/home/.ssh/id_ed25519"
    export HOME="$TEST_TMPDIR/home"
}

prep_workflow() {
    install_failable_ssh
    write_server_list "$@" >/dev/null
    : > "$FAKE_SSH_LOG"
}

run_with_fakes() {
    PATH="$FAKE_BIN:$PATH" run_orch "$@"
}

run_dir() { echo "$RESULTS_BASE/$IPERF_RUN_ID"; }

# ---- --keep-going flag parsing --------------------------------------------

test_keep_going_flag_is_recognized_by_cmd_all() {
    prep_workflow a b
    run_with_fakes -- all --keep-going
    if echo "$RUN_OUT" | grep -q "doctor reported issues" \
       && ! echo "$RUN_OUT" | grep -q "continuing because --keep-going"; then
        echo "expected --keep-going to override doctor failure" >&2
        return 1
    fi
}

test_keep_going_can_appear_before_or_after_mode() {
    prep_workflow a b c
    run_with_fakes -- all sequential-host --keep-going >/dev/null 2>&1
    [ "$(cat "$(run_dir)/.run_mode" 2>/dev/null)" = "sequential-host" ] || {
        echo "mode=sequential-host should be honored" >&2
        return 1
    }
    # Second invocation with flags in opposite order: needs a fresh run-id.
    rm -rf "$RESULTS_BASE"
    prep_workflow a b c
    run_with_fakes -- all --keep-going parallel >/dev/null 2>&1
    [ "$(cat "$(run_dir)/.run_mode" 2>/dev/null)" = "parallel" ] || {
        echo "mode=parallel should be honored when --keep-going precedes mode" >&2
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
    if python3 -c 'import numpy, matplotlib' 2>/dev/null; then
        echo "    SKIP test_cmd_all_dies_without_keep_going_when_doctor_fails: full python stack installed"
        return 0
    fi
    prep_workflow a b
    run_with_fakes -- all
    assert_ne 0 "$RUN_RC" "cmd_all should die when doctor fails" || return 1
    assert_contains "$RUN_OUT" "doctor reported issues" || return 1
    # Pipeline should NOT have reached check-iperf -> no INSTALLED line.
    if echo "$RUN_OUT" | grep -q "INSTALLED"; then
        echo "doctor failure should have stopped cmd_all before check-iperf" >&2
        return 1
    fi
}

test_cmd_all_continues_with_keep_going_when_doctor_fails() {
    if python3 -c 'import numpy, matplotlib' 2>/dev/null; then
        echo "    SKIP test_cmd_all_continues_with_keep_going_when_doctor_fails: full python stack installed"
        return 0
    fi
    prep_workflow a b
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going
    # Pipeline should reach check-iperf -> "INSTALLED" appears in output.
    assert_contains "$RUN_OUT" "INSTALLED" \
        "expected pipeline to continue past doctor with --keep-going" || return 1
}

# ---- Per-step gate behavior -----------------------------------------------

test_keep_going_continues_past_per_host_failure() {
    prep_workflow good bad
    echo "bad" > "$FAKE_BIN/unreachable"
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going
    assert_contains "$RUN_OUT" "INSTALLED" \
        "expected check-iperf to run and report INSTALLED" || return 1
}

run_test test_keep_going_flag_is_recognized_by_cmd_all
run_test test_keep_going_can_appear_before_or_after_mode
run_test test_unknown_cmd_all_argument_is_rejected
run_test test_cmd_all_dies_without_keep_going_when_doctor_fails
run_test test_cmd_all_continues_with_keep_going_when_doctor_fails
run_test test_keep_going_continues_past_per_host_failure

report_tests
