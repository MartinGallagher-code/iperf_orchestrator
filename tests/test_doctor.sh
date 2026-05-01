#!/usr/bin/env bash
# Tests for cmd_doctor and its _doctor_check_* helpers (added in
# the recent Phase 1 UX improvement). cmd_doctor probes for the
# tools and Python modules the pipeline needs and reports issues
# up front, so users don't crash 90s into `all` on a missing dep.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# Build a minimal but realistic FAKE_BIN with the four ssh tools
# present, so doctor can succeed-or-fail in a controlled way per test.
populate_fake_bin() {
    mkdir -p "$FAKE_BIN"
    local tool
    for tool in "$@"; do
        cat > "$FAKE_BIN/$tool" <<SHIM
#!/usr/bin/env bash
case "\$1" in
    --version) echo "$tool 9.9p1 (fake)" ;;
esac
exit 0
SHIM
        chmod +x "$FAKE_BIN/$tool"
    done
}

# Run doctor with a controlled PATH (FAKE_BIN only, plus /bin and
# /usr/bin so coreutils still resolve).
run_doctor() {
    PATH="$FAKE_BIN:/usr/bin:/bin" run_orch doctor
}

# ---- Output / status -----------------------------------------------------

test_doctor_prints_header() {
    populate_fake_bin ssh scp ssh-copy-id ssh-keygen
    run_doctor
    assert_contains "$RUN_OUT" "doctor: orchestrator-host prerequisites" || return 1
}

test_doctor_all_tools_present_succeeds() {
    populate_fake_bin ssh scp ssh-copy-id ssh-keygen
    run_doctor
    # The OK lines for each ssh tool should appear.
    assert_contains "$RUN_OUT" "OK  ssh" || return 1
    assert_contains "$RUN_OUT" "OK  scp" || return 1
    assert_contains "$RUN_OUT" "OK  ssh-copy-id" || return 1
    assert_contains "$RUN_OUT" "OK  ssh-keygen" || return 1
    # We don't have numpy/pandas/matplotlib in the test env, so doctor
    # WILL flag them. We only assert about the ssh tools here.
}

test_doctor_missing_ssh_is_flagged() {
    populate_fake_bin scp ssh-copy-id ssh-keygen
    # No ssh in FAKE_BIN, and our test env's PATH=$FAKE_BIN:/usr/bin:/bin --
    # ssh might still be in /usr/bin. Check if so.
    if [ -e /usr/bin/ssh ] || [ -e /bin/ssh ]; then
        echo "    SKIP test_doctor_missing_ssh_is_flagged: ssh exists in system PATH"
        return 0
    fi
    run_doctor
    assert_contains "$RUN_OUT" "MISSING ssh" || return 1
    assert_contains "$RUN_OUT" "openssh-client" || return 1
    assert_ne 0 "$RUN_RC" "doctor should exit non-zero with missing ssh" || return 1
}

test_doctor_reports_missing_count_in_summary() {
    populate_fake_bin ssh scp ssh-copy-id ssh-keygen
    run_doctor
    # The test env definitely lacks numpy/pandas/matplotlib, so the
    # warning "doctor: N issue(s) above" should appear.
    if echo "$RUN_OUT" | grep -q "doctor: all prerequisites OK"; then
        # Surprise: everything was present. Don't fail the test, just skip.
        return 0
    fi
    assert_contains "$RUN_OUT" "issue(s) above" || return 1
}

test_doctor_exits_zero_when_all_ok() {
    # Only feasible if the entire stack happens to be installed.
    if ! python3 -c 'import numpy, pandas, matplotlib' 2>/dev/null; then
        echo "    SKIP test_doctor_exits_zero_when_all_ok: numpy/pandas/matplotlib not installed"
        return 0
    fi
    populate_fake_bin ssh scp ssh-copy-id ssh-keygen
    run_doctor
    assert_status 0 "$RUN_RC" "doctor should exit 0 when nothing missing" || return 1
    assert_contains "$RUN_OUT" "all prerequisites OK" || return 1
}

# ---- Conditional expect check ------------------------------------------

test_doctor_skips_expect_check_when_no_password_source() {
    populate_fake_bin ssh scp ssh-copy-id ssh-keygen
    run_doctor
    # Without --password-* / --ask-password, the expect probe is skipped.
    if echo "$RUN_OUT" | grep -q -i "expect"; then
        echo "expect probe should not run without a password source" >&2
        echo "$RUN_OUT" >&2
        return 1
    fi
}

test_doctor_runs_expect_check_when_password_file_set() {
    populate_fake_bin ssh scp ssh-copy-id ssh-keygen
    local pwf="$TEST_TMPDIR/pw.txt"
    echo "secret" > "$pwf"
    chmod 600 "$pwf"
    PATH="$FAKE_BIN:/usr/bin:/bin" run_orch --password-file "$pwf" doctor
    # expect isn't installed in this env -> should be flagged MISSING.
    assert_contains "$RUN_OUT" "expect" "should mention expect probe" || return 1
}

test_doctor_runs_expect_check_when_ask_password_set() {
    populate_fake_bin ssh scp ssh-copy-id ssh-keygen
    PATH="$FAKE_BIN:/usr/bin:/bin" run_orch --ask-password doctor
    assert_contains "$RUN_OUT" "expect" "should mention expect probe" || return 1
}

# ---- Python module probes ------------------------------------------------

test_doctor_probes_each_required_python_module() {
    populate_fake_bin ssh scp ssh-copy-id ssh-keygen
    run_doctor
    # numpy/pandas/matplotlib should each be probed (either as OK or
    # MISSING depending on the env).
    for mod in numpy pandas matplotlib; do
        if ! echo "$RUN_OUT" | grep -q -E "(OK|MISSING) (python )?${mod}|module '$mod'"; then
            # The exact format is "OK  python -m matplotlib   X.Y" or
            # "MISSING python module 'matplotlib'".
            if ! echo "$RUN_OUT" | grep -q "$mod"; then
                echo "doctor did not probe python module '$mod'" >&2
                echo "$RUN_OUT" >&2
                return 1
            fi
        fi
    done
}

test_doctor_uses_python_bin_flag() {
    populate_fake_bin ssh scp ssh-copy-id ssh-keygen
    # Custom python interpreter wrapper that emits a marker line.
    local fakepy="$TEST_TMPDIR/python-marker"
    cat > "$fakepy" <<'EOF'
#!/usr/bin/env bash
echo "DOCTOR_PYTHON_WAS_USED" >&2
exec python3 "$@"
EOF
    chmod +x "$fakepy"
    PATH="$FAKE_BIN:/usr/bin:/bin" run_orch --python "$fakepy" doctor
    # The wrapper prints to stderr; that's captured into RUN_OUT.
    assert_contains "$RUN_OUT" "DOCTOR_PYTHON_WAS_USED" \
        "doctor should use --python interpreter for module probes" || return 1
}

# ---- Helper-level: tool found but no --version output ------------------

test_doctor_tool_without_version_flag_reports_no_version_output() {
    # Tool exists but doesn't accept --version; doctor should still
    # mark it OK (with "(no --version output)" annotation).
    populate_fake_bin ssh scp ssh-copy-id ssh-keygen
    # Replace ssh with one that ignores --version and prints nothing.
    cat > "$FAKE_BIN/ssh" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
    chmod +x "$FAKE_BIN/ssh"
    run_doctor
    assert_contains "$RUN_OUT" "OK  ssh" || return 1
    assert_contains "$RUN_OUT" "no --version output" || return 1
}

# ---- cmd_all integration -----------------------------------------------

test_cmd_all_runs_doctor_first() {
    populate_fake_bin ssh scp ssh-copy-id ssh-keygen
    # cmd_all without server list should still get to doctor (which
    # then succeeds for ssh tools, fails on python modules) before
    # dying on missing list. We just check that the doctor header
    # appears.
    PATH="$FAKE_BIN:/usr/bin:/bin" run_orch all
    # Doctor header should appear in output.
    assert_contains "$RUN_OUT" "doctor: orchestrator-host prerequisites" \
        "cmd_all should run doctor up front" || return 1
}

run_test test_doctor_prints_header
run_test test_doctor_all_tools_present_succeeds
run_test test_doctor_missing_ssh_is_flagged
run_test test_doctor_reports_missing_count_in_summary
run_test test_doctor_exits_zero_when_all_ok
run_test test_doctor_skips_expect_check_when_no_password_source
run_test test_doctor_runs_expect_check_when_password_file_set
run_test test_doctor_runs_expect_check_when_ask_password_set
run_test test_doctor_probes_each_required_python_module
run_test test_doctor_uses_python_bin_flag
run_test test_doctor_tool_without_version_flag_reports_no_version_output
run_test test_cmd_all_runs_doctor_first

report_tests
