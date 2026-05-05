#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for the `status` subcommand and server-list validation. The
# `init` subcommand was removed: server lists are now passed via
# --servers / IPERF_SERVERS, and status probes hosts live instead of
# reading a state file.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

test_status_with_no_servers() {
    unset IPERF_SERVERS
    run_orch status
    assert_status 0 "$RUN_RC" "status should succeed without a server list" || return 1
    assert_contains "$RUN_OUT" "iperf-orchestrator status" "should print header" || return 1
    assert_contains "$RUN_OUT" "(none; pass --servers)" || return 1
}

test_status_lists_existing_runs() {
    mkdir -p "$RESULTS_BASE/2026-05-01_10-00-00"
    mkdir -p "$RESULTS_BASE/2026-05-02_11-00-00"
    ln -sfn 2026-05-02_11-00-00 "$RESULTS_BASE/latest"
    run_orch status
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "2026-05-01_10-00-00" || return 1
    assert_contains "$RUN_OUT" "2026-05-02_11-00-00" || return 1
    assert_contains "$RUN_OUT" "<- latest" "should mark latest run" || return 1
}

test_status_probes_hosts_when_servers_provided() {
    install_fake_ssh
    write_server_list a b >/dev/null
    PATH="$FAKE_BIN:$PATH" run_orch status
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "Hosts (live probe)" || return 1
    # The shim makes iperf -v report version 2, so both hosts INSTALLED.
    assert_contains "$RUN_OUT" "INSTALLED" || return 1
}

test_status_json_emits_object() {
    mkdir -p "$RESULTS_BASE/run-x"
    ln -sfn run-x "$RESULTS_BASE/latest"
    run_orch status --json
    assert_status 0 "$RUN_RC" || return 1
    case "$RUN_OUT" in
        '{'*'}') ;;
        *) echo "not a JSON object: $RUN_OUT" >&2; return 1 ;;
    esac
    assert_contains "$RUN_OUT" '"results_base"' || return 1
    assert_contains "$RUN_OUT" '"runs":["run-x"]' || return 1
    assert_contains "$RUN_OUT" '"latest":"run-x"' || return 1
}

test_run_tests_dies_without_server_list() {
    unset IPERF_SERVERS
    # Override default fallback by pointing the script away from a real
    # servers.txt next to it. We do this by passing an explicit
    # --servers to a path that doesn't exist.
    run_orch --servers /nope/missing.txt run-tests
    assert_status 1 "$RUN_RC" "should die without a server list" || return 1
}

test_invalid_server_list_rejected_at_run_tests() {
    local src="$TEST_TMPDIR/bad.txt"
    cat > "$src" <<'EOF'
host-a
https://10.0.0.1:8080
host-c
EOF
    run_orch --servers "$src" run-tests
    assert_status 1 "$RUN_RC" "should reject URL entries" || return 1
    assert_contains "$RUN_OUT" "URL not allowed" || return 1
}

test_invalid_server_list_rejected_with_path_entries() {
    local src="$TEST_TMPDIR/bad.txt"
    printf 'host-a\nfoo/bar\nhost-c\n' > "$src"
    run_orch --servers "$src" run-tests
    assert_status 1 "$RUN_RC" "should reject entries with '/'" || return 1
    assert_contains "$RUN_OUT" "valid hostname" || return 1
}

test_run_tests_accepts_bracketed_ipv6() {
    install_fake_ssh
    local src="$TEST_TMPDIR/v6.txt"
    printf '[fe80::1]\n[2001:db8::beef]\n' > "$src"
    PATH="$FAKE_BIN:$PATH" run_orch --servers "$src" --start-delay 0 create-scripts >/dev/null
    assert_status 0 "$RUN_RC" "should accept bracketed IPv6" || return 1
}

run_test test_status_with_no_servers
run_test test_status_lists_existing_runs
run_test test_status_probes_hosts_when_servers_provided
run_test test_status_json_emits_object
run_test test_run_tests_dies_without_server_list
run_test test_invalid_server_list_rejected_at_run_tests
run_test test_invalid_server_list_rejected_with_path_entries
run_test test_run_tests_accepts_bracketed_ipv6

report_tests
