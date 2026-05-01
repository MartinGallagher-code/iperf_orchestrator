#!/usr/bin/env bash
# Tests for `init` and `status` subcommands.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

test_init_requires_argument() {
    run_orch init
    assert_status 1 "$RUN_RC" "init with no arg should die" || return 1
    assert_contains "$RUN_OUT" "Usage:" "should show usage hint" || return 1
}

test_init_rejects_missing_file() {
    run_orch init /this/path/does/not/exist.txt
    assert_status 1 "$RUN_RC" "missing file should cause die" || return 1
    assert_contains "$RUN_OUT" "File not found" "should report missing file" || return 1
}

test_init_copies_server_list_and_sets_state() {
    local src="$TEST_TMPDIR/myservers.txt"
    cat > "$src" <<'EOF'
host-a
host-b
host-c
EOF
    run_orch init "$src"
    assert_status 0 "$RUN_RC" "init should succeed" || return 1
    assert_file_exists "$IPERF_DIR/servers.list" || return 1
    # Verify the copy is byte-identical.
    cmp -s "$src" "$IPERF_DIR/servers.list" || {
        echo "server list copy differs from source" >&2
        return 1
    }
    # State should record SERVER_LIST_LOADED=yes
    grep -q '^SERVER_LIST_LOADED=yes$' "$IPERF_DIR/state" || {
        echo "state did not record SERVER_LIST_LOADED=yes" >&2
        cat "$IPERF_DIR/state" >&2
        return 1
    }
    assert_contains "$RUN_OUT" "Initialized with 3 hosts" "log should show host count" || return 1
}

test_init_reports_correct_count_with_comments() {
    local src="$TEST_TMPDIR/myservers.txt"
    cat > "$src" <<'EOF'
# header comment
host-a
host-b   # inline note

host-c
EOF
    run_orch init "$src"
    assert_status 0 "$RUN_RC" || return 1
    # 3 real hosts despite comments + blank line.
    assert_contains "$RUN_OUT" "Initialized with 3 hosts" || return 1
}

test_init_resets_existing_state() {
    # Pre-populate state with stale flags from a previous run.
    mkdir -p "$IPERF_DIR"
    cat > "$IPERF_DIR/state" <<'EOF'
TESTS_RUN=yes
RESULTS_COLLECTED=yes
EOF
    local src="$TEST_TMPDIR/srv.txt"
    printf 'h1\nh2\n' > "$src"
    run_orch init "$src"
    assert_status 0 "$RUN_RC" || return 1
    # The stale TESTS_RUN should be wiped (init truncates state file).
    if grep -q '^TESTS_RUN=yes' "$IPERF_DIR/state"; then
        echo "init did not reset stale TESTS_RUN flag" >&2
        cat "$IPERF_DIR/state" >&2
        return 1
    fi
    grep -q '^SERVER_LIST_LOADED=yes' "$IPERF_DIR/state" || return 1
}

test_init_rejects_url_entries() {
    local src="$TEST_TMPDIR/bad.txt"
    cat > "$src" <<'EOF'
host-a
https://10.0.0.1:8080
host-c
EOF
    run_orch init "$src"
    assert_status 1 "$RUN_RC" "init should reject URL entries" || return 1
    assert_contains "$RUN_OUT" "URL not allowed" "should explain why URL was rejected" || return 1
}

test_init_rejects_path_entries() {
    local src="$TEST_TMPDIR/bad.txt"
    printf 'host-a\nfoo/bar\nhost-c\n' > "$src"
    run_orch init "$src"
    assert_status 1 "$RUN_RC" "init should reject entries with '/'" || return 1
    assert_contains "$RUN_OUT" "valid hostname" "should explain why path was rejected" || return 1
}

test_init_warns_on_too_few_hosts() {
    local src="$TEST_TMPDIR/one.txt"
    echo only-one-host > "$src"
    run_orch init "$src"
    # init accepts single-host lists (used by diagnostic subcommands) but
    # warns; the hard >=2 check happens inside run-tests.
    assert_status 0 "$RUN_RC" "init should accept N=1 with a warning" || return 1
    assert_contains "$RUN_OUT" "run-tests needs at least 2" "should warn that run-tests needs >=2" || return 1
}

test_init_accepts_bracketed_ipv6() {
    local src="$TEST_TMPDIR/v6.txt"
    printf '[fe80::1]\n[2001:db8::beef]\n' > "$src"
    run_orch init "$src"
    assert_status 0 "$RUN_RC" "init should accept bracketed IPv6" || return 1
    assert_contains "$RUN_OUT" "Initialized with 2 hosts" || return 1
}

test_status_with_no_init() {
    run_orch status
    assert_status 0 "$RUN_RC" "status should succeed even without init" || return 1
    assert_contains "$RUN_OUT" "iperf-orchestrator status" "should print header" || return 1
    assert_contains "$RUN_OUT" "no list yet" "should report missing server list" || return 1
}

test_status_shows_next_hint() {
    local src="$TEST_TMPDIR/srv.txt"
    printf 'h1\nh2\n' > "$src"
    run_orch init "$src" >/dev/null
    run_orch status
    assert_status 0 "$RUN_RC" || return 1
    # After init, the next pending step should be ssh-setup.
    assert_contains "$RUN_OUT" "Next:" "status should print 'Next:' hint" || return 1
    assert_contains "$RUN_OUT" "ssh-setup" "next hint should point at ssh-setup" || return 1
}

test_status_after_init_shows_pipeline_steps() {
    local src="$TEST_TMPDIR/srv.txt"
    printf 'h1\nh2\n' > "$src"
    run_orch init "$src"
    assert_status 0 "$RUN_RC" || return 1
    run_orch status
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "Hosts:" "should show host count line" || return 1
    assert_contains "$RUN_OUT" "SERVER_LIST_LOADED" "should list pipeline step" || return 1
    assert_contains "$RUN_OUT" "TESTS_RUN" "should list TESTS_RUN step" || return 1
    assert_contains "$RUN_OUT" "HEATMAP_BUILT" "should list HEATMAP_BUILT step" || return 1
}

run_test test_init_requires_argument
run_test test_init_rejects_missing_file
run_test test_init_copies_server_list_and_sets_state
run_test test_init_reports_correct_count_with_comments
run_test test_init_resets_existing_state
run_test test_init_rejects_url_entries
run_test test_init_rejects_path_entries
run_test test_init_warns_on_too_few_hosts
run_test test_init_accepts_bracketed_ipv6
run_test test_status_with_no_init
run_test test_status_shows_next_hint
run_test test_status_after_init_shows_pipeline_steps

report_tests
