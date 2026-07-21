#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
#
# Coverage-focused tests: exercise reachable branches that the functional
# suite left uncovered -- every CLI flag form in the pre-pass, the DRY-RUN
# short-circuits in ssh_run/scp_to/scp_from, and a handful of die/warn edges.
# These assert real behaviour; they also happen to close kcov gaps.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# ---- CLI flag pre-pass: every form should parse and reach the subcommand --

test_every_flag_form_parses() {
    # (flag-with-value forms and their `=` variants). Each should parse
    # cleanly and let `help-advanced` run (rc 0), exercising the matching
    # arm of the flag pre-pass case statement.
    local forms=(
        "--total-time=5"
        "--host-flows 2" "--host-flows=2"
        "--bandwidth 100M" "--bandwidth=100M" "-b 100M"
        "--length 128K" "--length=128K" "-l 128K"
        "--window 4M" "--window=4M" "-w 4M"
        "--mss 1400" "--mss=1400" "-M 1400"
        "--no-nagle" "-N"
        "--server-bind=eth0"
        "-u someuser"
        "--output=/tmp/cov-out" "-o=/tmp/cov-out"
        "--run-id=cov-run"
        "--servers=/tmp/cov-servers" "-s=/tmp/cov-servers"
        "--remote-dir /tmp/cov-remote"
        "--python=/usr/bin/python3"
        "--start-delay 1"
    )
    local f
    for f in "${forms[@]}"; do
        # shellcheck disable=SC2086
        run_orch $f help-advanced
        assert_status 0 "$RUN_RC" "flag form '$f' should parse and exit 0" || {
            printf 'output for %q:\n%s\n' "$f" "$RUN_OUT" >&2
            return 1
        }
    done
}

test_help_advanced_as_a_flag() {
    # `--help-advanced` used as a global flag (pre-pass), not the subcommand.
    run_orch --help-advanced
    assert_status 0 "$RUN_RC" "--help-advanced flag should exit 0" || return 1
    assert_contains "$RUN_OUT" "USAGE:" || return 1
}

test_unusually_high_ssh_jobs_warns() {
    run_orch --ssh-jobs 20000 help-advanced
    assert_status 0 "$RUN_RC" "high --ssh-jobs should still succeed" || return 1
    assert_contains "$RUN_OUT" "unusually high" \
        "an unusually high --ssh-jobs should emit a warning" || return 1
}

# ---- die / warn edges ------------------------------------------------------

test_cleanup_rejects_unknown_argument() {
    run_orch cleanup --not-a-real-flag
    assert_ne 0 "$RUN_RC" "cleanup with an unknown arg should fail" || return 1
    assert_contains "$RUN_OUT" "unknown argument" || return 1
}

test_process_subcommand_dispatches() {
    # `process` with no run present dies inside cmd_process, but the
    # dispatcher arm must still be reached (not "Unknown command").
    run_orch process
    assert_not_contains "$RUN_OUT" "Unknown command" \
        "process should dispatch to cmd_process, not be rejected" || return 1
}

# ---- DRY-RUN short-circuits in ssh_run / scp_to / scp_from -----------------

test_dry_run_start_servers_prints_ssh_commands() {
    write_server_list host-a host-b >/dev/null
    run_orch --dry-run start-servers
    assert_status 0 "$RUN_RC" "dry-run start-servers should succeed" || return 1
    assert_contains "$RUN_OUT" "DRY-RUN ssh" \
        "dry-run should print the ssh command instead of running it" || return 1
}

test_dry_run_distribute_prints_scp_commands() {
    write_server_list host-a host-b >/dev/null
    # Generate real scripts locally first (dry-run only affects ssh/scp).
    run_orch create-scripts
    assert_status 0 "$RUN_RC" "create-scripts should succeed" || return 1
    run_orch --dry-run distribute-scripts
    assert_status 0 "$RUN_RC" "dry-run distribute-scripts should succeed" || return 1
    assert_contains "$RUN_OUT" "DRY-RUN scp" \
        "dry-run distribute should print the scp command" || return 1
}

test_dry_run_collect_results_prints_scp_commands() {
    write_server_list host-a host-b >/dev/null
    # collect-results resolves an existing run dir; create it.
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    run_orch --dry-run collect-results
    assert_contains "$RUN_OUT" "DRY-RUN scp" \
        "dry-run collect-results should print the scp command" || return 1
}

test_distribute_warns_when_script_missing() {
    write_server_list host-a host-b >/dev/null
    # No create-scripts run -> every host lacks a script -> warn per host.
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID/scripts"
    run_orch distribute-scripts
    assert_contains "$RUN_OUT" "no script for" \
        "distribute should warn when a host has no generated script" || return 1
}

# ---- doctor: the all-present success path ---------------------------------

test_doctor_reports_all_ok_with_full_stack() {
    # Fake ssh/scp so the tool probes pass, and a fake python whose module
    # imports succeed, so doctor takes its "all prerequisites OK" branch
    # (and the per-module OK branch) regardless of the host's real Python.
    local tool
    for tool in ssh scp; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/$tool"
        chmod +x "$FAKE_BIN/$tool"
    done
    cat > "$FAKE_BIN/fakepy" <<'PYSHIM'
#!/usr/bin/env bash
# Minimal python stand-in: --version prints, and any `-c "import ..."`
# (with or without a trailing print) succeeds so doctor sees the module.
case "$1" in
    --version) echo "Python 3.12.0 (fake)"; exit 0 ;;
    -c) shift
        case "$1" in
            *print*) echo "9.9.9" ;;
        esac
        exit 0 ;;
esac
exit 0
PYSHIM
    chmod +x "$FAKE_BIN/fakepy"
    PATH="$FAKE_BIN:/usr/bin:/bin" run_orch --python "$FAKE_BIN/fakepy" doctor
    assert_status 0 "$RUN_RC" "doctor should exit 0 when everything is present" || {
        printf '%s\n' "$RUN_OUT" >&2; return 1; }
    assert_contains "$RUN_OUT" "all prerequisites OK" || return 1
}

# ---- run-id auto-generation ------------------------------------------------

test_missing_run_id_is_auto_generated() {
    write_server_list host-a host-b >/dev/null
    # With no IPERF_RUN_ID, a write command must synthesize a default run-id.
    unset IPERF_RUN_ID
    run_orch create-scripts
    assert_status 0 "$RUN_RC" "create-scripts should succeed and mint a run-id" || return 1
    # A fresh run dir (not the fixed "test-run") should have appeared.
    local n
    n=$(find "$RESULTS_BASE" -maxdepth 1 -type d ! -name results ! -name latest | wc -l)
    [ "$n" -ge 1 ] || { echo "expected an auto-generated run dir under $RESULTS_BASE" >&2; return 1; }
}

# ---- parallel_hosts refuses to run without a server list ------------------

test_no_server_list_is_rejected() {
    # setup_orch_env points IPERF_SERVERS at a path that doesn't exist yet.
    run_orch check-iperf
    assert_ne 0 "$RUN_RC" "commands should fail with no server list" || return 1
    assert_contains "$RUN_OUT" "no server list" || return 1
}

# ---- run-tests validates the mode argument --------------------------------

test_run_tests_accepts_valid_mode() {
    write_server_list host-a host-b >/dev/null
    # rolling mode is self-starting; --dry-run keeps it from touching hosts.
    run_orch --dry-run --total-time 1 run-tests rolling
    # The mode must be accepted (no "unknown mode" rejection).
    assert_not_contains "$RUN_OUT" "unknown mode" || return 1
}

run_test test_every_flag_form_parses
run_test test_help_advanced_as_a_flag
run_test test_unusually_high_ssh_jobs_warns
run_test test_cleanup_rejects_unknown_argument
run_test test_process_subcommand_dispatches
run_test test_dry_run_start_servers_prints_ssh_commands
run_test test_dry_run_distribute_prints_scp_commands
run_test test_dry_run_collect_results_prints_scp_commands
run_test test_distribute_warns_when_script_missing
run_test test_doctor_reports_all_ok_with_full_stack
run_test test_missing_run_id_is_auto_generated
run_test test_no_server_list_is_rejected
run_test test_run_tests_accepts_valid_mode

report_tests
