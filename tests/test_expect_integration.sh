#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Integration tests that drive the *real* `expect` interpreter against a
# fake `ssh-copy-id` which emits realistic prompts. Unlike test_ssh_setup.sh
# (which stubs `expect` itself and only verifies orchestration around it),
# these tests actually execute the TCL heredoc inside _ssh_copy_id_expect
# (see iperf_orchestrator.sh: function _ssh_copy_id_expect) and assert on
# its prompt-handling, retry, and exit-status-propagation behaviour.
#
# Skips cleanly if `expect` is not installed on the test host.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# Skip the whole file when expect is unavailable. We print a clear marker
# and exit 0 so run_tests.sh treats this as a passing file.
if ! command -v expect >/dev/null 2>&1; then
    echo "  skipped: expect not installed (apt install expect / dnf install expect / brew install expect)"
    exit 0
fi

# Install:
#   - the orchestrator's normal fake ssh/scp shim (only used incidentally
#     here, but harmless),
#   - a fake ssh-copy-id whose behaviour is selected at runtime by reading
#     $FAKE_BIN/sshcopyid.mode (set by each test before invoking the
#     orchestrator). It writes everything it receives on stdin to
#     $FAKE_BIN/received.log so tests can assert on the exact bytes the
#     real expect script sent.
#   - a pre-existing SSH key pair so cmd_ssh_setup skips ssh-keygen.
install_real_expect_fakes() {
    install_fake_ssh

    cat > "$FAKE_BIN/ssh-copy-id" <<'SHIM'
#!/usr/bin/env bash
# Fake ssh-copy-id driven by mode file. Reads from stdin (pty slave)
# and writes prompts to stdout. Strips trailing CR from each line so
# tests don't have to care about pty line-ending translation.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
mode_file="$HERE/sshcopyid.mode"
log="$HERE/received.log"
mode="happy"
[ -f "$mode_file" ] && mode="$(cat "$mode_file")"

# Helper: read one line, strip trailing CR, append to received.log.
read_one() {
    local line=""
    if IFS= read -r line; then
        line="${line%$'\r'}"
        printf '%s\n' "$line" >> "$log"
        printf '%s' "$line"
        return 0
    fi
    return 1
}

case "$mode" in
    happy)
        # Plain password prompt only.
        printf "user@host's password: "
        read_one >/dev/null || exit 1
        exit 0
        ;;
    yesno_then_password)
        # First the host-key prompt, then the password prompt.
        printf 'The authenticity of host '\''x'\'' cannot be established.\n'
        printf 'Are you sure you want to continue connecting (yes/no/[fingerprint])? '
        read_one >/dev/null || exit 1
        printf "user@host's password: "
        read_one >/dev/null || exit 1
        exit 0
        ;;
    retry_then_fail)
        # First password prompt is answered, then we re-prompt to simulate
        # a bad password. The expect TCL must NOT send a second time; it
        # should detect the second prompt and exit 5 itself, which closes
        # our pty. Our subsequent read returns EOF -> we exit non-zero,
        # but expect has already reported failure first.
        printf "user@host's password: "
        read_one >/dev/null || exit 1
        printf "user@host's password: "
        # No more input will arrive -- expect exits 5 and closes the pty.
        # Read will fail with EOF; exit any non-zero.
        read_one >/dev/null || exit 1
        exit 0
        ;;
    bad_exit)
        # Answer the prompt normally, then exit with a non-zero status to
        # verify the orchestrator records the failure (i.e. exit-status
        # propagation through `catch wait` works).
        printf "user@host's password: "
        read_one >/dev/null || exit 1
        exit 7
        ;;
    *)
        echo "fake ssh-copy-id: unknown mode '$mode'" >&2
        exit 99
        ;;
esac
SHIM
    chmod +x "$FAKE_BIN/ssh-copy-id"
    : > "$FAKE_BIN/received.log"

    # Pre-create a key pair so cmd_ssh_setup's keygen branch is skipped.
    mkdir -p "$TEST_TMPDIR/home/.ssh"
    : > "$TEST_TMPDIR/home/.ssh/id_ed25519"
    : > "$TEST_TMPDIR/home/.ssh/id_ed25519.pub"
    chmod 600 "$TEST_TMPDIR/home/.ssh/id_ed25519"
    export HOME="$TEST_TMPDIR/home"
}

set_mode() {
    echo "$1" > "$FAKE_BIN/sshcopyid.mode"
}

prep_servers() {
    local src="$TEST_TMPDIR/srv.txt"
    : > "$src"
    local h
    for h in "$@"; do
        printf '%s\n' "$h" >> "$src"
    done
    PATH="$FAKE_BIN:$PATH" run_orch init "$src" >/dev/null 2>&1
}

# Run the orchestrator with our fakes prepended to PATH but NOT shadowing
# the real `expect` -- the system PATH still resolves /usr/bin/expect.
# IPERF_PROGRESS=0 keeps the parallel-hosts drainer quiet.
run_with_fakes() {
    IPERF_PROGRESS=0 PATH="$FAKE_BIN:$PATH" run_orch "$@"
}

# ---- Case 1: happy path through real expect ------------------------------

test_real_expect_sends_password_on_prompt() {
    install_real_expect_fakes
    set_mode happy
    prep_servers host1
    local pwf="$TEST_TMPDIR/pw.txt"
    echo "s3cret-pw" > "$pwf"; chmod 600 "$pwf"
    run_with_fakes --password-file "$pwf" ssh-setup
    assert_status 0 "$RUN_RC" "ssh-setup should succeed end-to-end" || {
        echo "--- run output ---" >&2
        echo "$RUN_OUT" >&2
        return 1
    }
    # The fake recorded everything it received on stdin. The first (and
    # only) line should be the password.
    assert_file_exists "$FAKE_BIN/received.log" || return 1
    local first
    first="$(head -n1 "$FAKE_BIN/received.log")"
    assert_eq "s3cret-pw" "$first" "expect should have sent the password" || return 1
    grep -q '^SSH_KEYS_DISTRIBUTED=yes$' "$IPERF_DIR/state" \
        || { echo "SSH_KEYS_DISTRIBUTED not set" >&2; return 1; }
}

# ---- Case 2: host-key (yes/no) prompt is auto-answered -------------------

test_real_expect_answers_yesno_then_password() {
    install_real_expect_fakes
    set_mode yesno_then_password
    prep_servers host2
    local pwf="$TEST_TMPDIR/pw.txt"
    echo "another-pw" > "$pwf"; chmod 600 "$pwf"
    run_with_fakes --password-file "$pwf" ssh-setup
    assert_status 0 "$RUN_RC" "ssh-setup should handle yes/no + password" || {
        echo "--- run output ---" >&2
        echo "$RUN_OUT" >&2
        return 1
    }
    # received.log: line 1 = "yes", line 2 = the password.
    local n yesno pw
    n=$(wc -l < "$FAKE_BIN/received.log")
    assert_eq "2" "$n" "fake should have received exactly two lines" || {
        echo "--- received.log ---" >&2
        cat "$FAKE_BIN/received.log" >&2
        return 1
    }
    yesno="$(sed -n '1p' "$FAKE_BIN/received.log")"
    pw="$(sed -n '2p' "$FAKE_BIN/received.log")"
    assert_eq "yes" "$yesno" "expect should auto-answer yes to host-key prompt" || return 1
    assert_eq "another-pw" "$pw" "expect should send password after yes" || return 1
}

# ---- Case 3: re-prompt -> auth retry-and-fail (exit 5) -------------------

test_real_expect_fails_on_second_password_prompt() {
    install_real_expect_fakes
    set_mode retry_then_fail
    prep_servers host3
    local pwf="$TEST_TMPDIR/pw.txt"
    echo "wrong-pw" > "$pwf"; chmod 600 "$pwf"
    run_with_fakes --password-file "$pwf" ssh-setup
    # cmd_ssh_setup itself returns 0 (it summarises failures) -- but the
    # state file must NOT mark keys distributed, and the warn line must
    # name our host.
    if grep -q '^SSH_KEYS_DISTRIBUTED=yes$' "$IPERF_DIR/state" 2>/dev/null; then
        echo "SSH_KEYS_DISTRIBUTED was set despite auth failure" >&2
        echo "--- run output ---" >&2
        echo "$RUN_OUT" >&2
        return 1
    fi
    assert_contains "$RUN_OUT" "FAILED: host3" "should warn about failed host" || return 1
    # And expect must have only sent the password ONCE (the TCL guards
    # against a second send via the sent_pw flag).
    local n
    n=$(grep -c '^wrong-pw$' "$FAKE_BIN/received.log")
    assert_eq "1" "$n" "password should be sent exactly once before giving up" || {
        echo "--- received.log ---" >&2
        cat "$FAKE_BIN/received.log" >&2
        return 1
    }
}

# ---- Case 4: ssh-copy-id exit status is propagated -----------------------

test_real_expect_propagates_nonzero_exit() {
    install_real_expect_fakes
    set_mode bad_exit
    prep_servers host4
    local pwf="$TEST_TMPDIR/pw.txt"
    echo "ok-pw" > "$pwf"; chmod 600 "$pwf"
    run_with_fakes --password-file "$pwf" ssh-setup
    if grep -q '^SSH_KEYS_DISTRIBUTED=yes$' "$IPERF_DIR/state" 2>/dev/null; then
        echo "SSH_KEYS_DISTRIBUTED was set despite ssh-copy-id exit 7" >&2
        return 1
    fi
    assert_contains "$RUN_OUT" "FAILED: host4" \
        "non-zero ssh-copy-id exit must surface as a host failure" || return 1
}

run_test test_real_expect_sends_password_on_prompt
run_test test_real_expect_answers_yesno_then_password
run_test test_real_expect_fails_on_second_password_prompt
run_test test_real_expect_propagates_nonzero_exit

report_tests
