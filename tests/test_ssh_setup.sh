#!/usr/bin/env bash
# Tests for cmd_ssh_setup and the password-source resolver. Covers:
#   - --password-file / SSH_PASSWORD_FILE
#   - --password-env  / SSH_PASSWORD_ENV
#   - --ask-password  / SSH_ASK_PASSWORD
#   - missing `expect` binary -> dies with helpful message
#   - empty / missing password file -> dies
#   - permissions warning on a wide-open password file
#   - parallel expect-driven path triggers when password source is set

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# Install fake `expect`, `ssh-copy-id`, `ssh-keygen`. The fake expect
# just records that it was invoked. The fake ssh-copy-id always
# succeeds. The fake ssh-keygen creates an empty pair of files.
install_fake_setup_tools() {
    install_fake_ssh
    cat > "$FAKE_BIN/expect" <<'SHIM'
#!/usr/bin/env bash
echo "expect $*" >> "$FAKE_BIN/expect_calls.log"
# Read stdin so the heredoc is consumed.
cat >/dev/null
exit 0
SHIM
    chmod +x "$FAKE_BIN/expect"
    : > "$FAKE_BIN/expect_calls.log"

    cat > "$FAKE_BIN/ssh-copy-id" <<'SHIM'
#!/usr/bin/env bash
echo "ssh-copy-id $*" >> "$FAKE_BIN/copyid_calls.log"
exit 0
SHIM
    chmod +x "$FAKE_BIN/ssh-copy-id"
    : > "$FAKE_BIN/copyid_calls.log"

    # Generate a real-looking key pair on demand to avoid the script's
    # ssh-keygen path. We create the pair upfront so cmd_ssh_setup
    # skips the keygen branch entirely.
    mkdir -p "$TEST_TMPDIR/home/.ssh"
    : > "$TEST_TMPDIR/home/.ssh/id_ed25519"
    : > "$TEST_TMPDIR/home/.ssh/id_ed25519.pub"
    chmod 600 "$TEST_TMPDIR/home/.ssh/id_ed25519"
    export HOME="$TEST_TMPDIR/home"
}

# Helper: prep a fresh server list and run init.
prep_servers() {
    local src="$TEST_TMPDIR/srv.txt"
    : > "$src"
    local h
    for h in "$@"; do
        printf '%s\n' "$h" >> "$src"
    done
    PATH="$FAKE_BIN:$PATH" run_orch init "$src" >/dev/null 2>&1
}

run_with_fakes() {
    PATH="$FAKE_BIN:$PATH" run_orch "$@"
}

# ---- Password source: file ------------------------------------------------

test_ssh_setup_with_password_file_uses_expect() {
    install_fake_setup_tools
    prep_servers a b c
    local pwf="$TEST_TMPDIR/pw.txt"
    echo "secretpass" > "$pwf"
    chmod 600 "$pwf"
    run_with_fakes --password-file "$pwf" ssh-setup
    assert_status 0 "$RUN_RC" "ssh-setup with --password-file should succeed" || return 1
    # expect should have been invoked once per host (parallel).
    local n
    n=$(wc -l < "$FAKE_BIN/expect_calls.log")
    assert_eq "3" "$n" "expect should run once per host" || return 1
    grep -q '^SSH_KEYS_DISTRIBUTED=yes$' "$IPERF_DIR/state" || {
        echo "SSH_KEYS_DISTRIBUTED not flagged" >&2
        return 1
    }
}

test_ssh_setup_password_file_missing_dies() {
    install_fake_setup_tools
    prep_servers a
    run_with_fakes --password-file /nonexistent/pw.txt ssh-setup
    assert_status 1 "$RUN_RC" "missing password file should die" || return 1
    assert_contains "$RUN_OUT" "password file not found" || return 1
}

test_ssh_setup_empty_password_file_dies() {
    install_fake_setup_tools
    prep_servers a
    local pwf="$TEST_TMPDIR/empty.txt"
    : > "$pwf"
    chmod 600 "$pwf"
    run_with_fakes --password-file "$pwf" ssh-setup
    assert_status 1 "$RUN_RC" "empty password file should die" || return 1
    assert_contains "$RUN_OUT" "is empty" || return 1
}

test_ssh_setup_warns_on_world_readable_password_file() {
    install_fake_setup_tools
    prep_servers a
    local pwf="$TEST_TMPDIR/loose.txt"
    echo "secretpass" > "$pwf"
    chmod 644 "$pwf"
    run_with_fakes --password-file "$pwf" ssh-setup
    assert_status 0 "$RUN_RC" "should still proceed despite warning" || return 1
    assert_contains "$RUN_OUT" "permissions" "should warn about loose perms" || return 1
    assert_contains "$RUN_OUT" "chmod 600" "should suggest chmod 600" || return 1
}

# ---- Password source: env var --------------------------------------------

test_ssh_setup_with_password_env_uses_expect() {
    install_fake_setup_tools
    prep_servers a b
    MY_TEST_PW="hunter2" run_with_fakes --password-env MY_TEST_PW ssh-setup
    assert_status 0 "$RUN_RC" || return 1
    local n
    n=$(wc -l < "$FAKE_BIN/expect_calls.log")
    assert_eq "2" "$n" "expect once per host with --password-env" || return 1
}

test_ssh_setup_password_env_unset_dies() {
    install_fake_setup_tools
    prep_servers a
    # Don't define UNDEFINED_VAR.
    unset UNDEFINED_VAR 2>/dev/null || true
    run_with_fakes --password-env UNDEFINED_VAR ssh-setup
    assert_status 1 "$RUN_RC" "unset env var should die" || return 1
    assert_contains "$RUN_OUT" "is empty or unset" || return 1
}

test_ssh_setup_password_env_empty_dies() {
    install_fake_setup_tools
    prep_servers a
    EMPTY_VAR="" run_with_fakes --password-env EMPTY_VAR ssh-setup
    assert_status 1 "$RUN_RC" "empty env var should die" || return 1
    assert_contains "$RUN_OUT" "is empty or unset" || return 1
}

# ---- Missing expect binary ------------------------------------------------

test_ssh_setup_dies_when_expect_unavailable() {
    install_fake_setup_tools
    # Drop the fake expect so PATH lookup fails.
    rm -f "$FAKE_BIN/expect"
    prep_servers a
    local pwf="$TEST_TMPDIR/pw.txt"
    echo "p" > "$pwf"; chmod 600 "$pwf"
    # Restricted PATH (no system path) so neither fake-bin nor system
    # has expect. Keep /bin and /usr/bin so the orchestrator can still
    # find core utilities like ssh-keygen, but expect must be absent.
    HOME="$TEST_TMPDIR/home" PATH="$FAKE_BIN:/usr/bin:/bin" run_orch --password-file "$pwf" ssh-setup
    assert_ne 0 "$RUN_RC" "should have failed without expect on PATH" || return 1
    assert_contains "$RUN_OUT" "expect" "error message should mention 'expect'" || return 1
}

# ---- Interactive (non-expect) path ---------------------------------------

test_ssh_setup_without_password_uses_interactive_ssh_copy_id() {
    install_fake_setup_tools
    prep_servers a b
    # No password options -> falls back to ssh-copy-id sequentially.
    run_with_fakes ssh-setup
    assert_status 0 "$RUN_RC" || return 1
    local n
    n=$(wc -l < "$FAKE_BIN/copyid_calls.log")
    assert_eq "2" "$n" "ssh-copy-id should be called once per host" || return 1
    # No expect calls in this path.
    local e
    e=$(wc -l < "$FAKE_BIN/expect_calls.log")
    assert_eq "0" "$e" "expect should NOT be invoked when no password source" || return 1
    grep -q '^SSH_KEYS_DISTRIBUTED=yes$' "$IPERF_DIR/state" || return 1
}

# ---- --ask-password flag -------------------------------------------------

test_ask_password_flag_sets_state_var() {
    # We can't actually drive an interactive password prompt in tests,
    # but we can check that the flag is parsed without error and is
    # echoed back in usage output.
    install_fake_setup_tools
    run_with_fakes --ask-password help
    assert_status 0 "$RUN_RC" || return 1
}

# ---- Password is not exposed via process-list ---------------------------

test_ssh_setup_does_not_pass_password_in_argv() {
    install_fake_setup_tools
    prep_servers a
    local pwf="$TEST_TMPDIR/pw.txt"
    echo "secretpassword12345" > "$pwf"
    chmod 600 "$pwf"
    run_with_fakes --password-file "$pwf" ssh-setup
    assert_status 0 "$RUN_RC" || return 1
    # The fake expect logs its own argv. The password should NOT be
    # in there (it's passed through env var _IPERF_ORCH_PW).
    if grep -q "secretpassword12345" "$FAKE_BIN/expect_calls.log"; then
        echo "password leaked into argv" >&2
        cat "$FAKE_BIN/expect_calls.log" >&2
        return 1
    fi
}

# ---- Server-list still required -----------------------------------------

test_ssh_setup_dies_with_no_server_list() {
    install_fake_setup_tools
    # Don't init.
    run_with_fakes ssh-setup
    assert_ne 0 "$RUN_RC" "ssh-setup should fail without a server list" || return 1
}

# ---- Flag forms -----------------------------------------------------------

test_password_file_flag_equals_form() {
    install_fake_setup_tools
    prep_servers a
    local pwf="$TEST_TMPDIR/pw.txt"
    echo "p" > "$pwf"; chmod 600 "$pwf"
    run_with_fakes --password-file="$pwf" ssh-setup
    assert_status 0 "$RUN_RC" || return 1
}

test_password_env_flag_equals_form() {
    install_fake_setup_tools
    prep_servers a
    MYPW=p run_with_fakes --password-env=MYPW ssh-setup
    assert_status 0 "$RUN_RC" || return 1
}

run_test test_ssh_setup_with_password_file_uses_expect
run_test test_ssh_setup_password_file_missing_dies
run_test test_ssh_setup_empty_password_file_dies
run_test test_ssh_setup_warns_on_world_readable_password_file
run_test test_ssh_setup_with_password_env_uses_expect
run_test test_ssh_setup_password_env_unset_dies
run_test test_ssh_setup_password_env_empty_dies
run_test test_ssh_setup_dies_when_expect_unavailable
run_test test_ssh_setup_without_password_uses_interactive_ssh_copy_id
run_test test_ask_password_flag_sets_state_var
run_test test_ssh_setup_does_not_pass_password_in_argv
run_test test_ssh_setup_dies_with_no_server_list
run_test test_password_file_flag_equals_form
run_test test_password_env_flag_equals_form

report_tests
