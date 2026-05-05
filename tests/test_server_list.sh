#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for read_servers: blank lines, inline + standalone comments,
# leading/trailing whitespace, missing-file behavior.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

test_read_servers_strips_blank_lines() {
    source_orch
    cat > "$SERVER_LIST_FILE" <<'EOF'
host1

host2

host3
EOF
    local out
    out=$(read_servers)
    assert_eq "host1
host2
host3" "$out" "blank lines should be removed" || return 1
}

test_read_servers_strips_full_line_comments() {
    source_orch
    cat > "$SERVER_LIST_FILE" <<'EOF'
# leading comment
host1
# middle comment
host2
EOF
    local out
    out=$(read_servers)
    assert_eq "host1
host2" "$out"
}

test_read_servers_strips_inline_comments() {
    source_orch
    cat > "$SERVER_LIST_FILE" <<'EOF'
host1 # production
host2  # staging
host3#nospace
EOF
    local out
    out=$(read_servers)
    assert_eq "host1
host2
host3" "$out"
}

test_read_servers_strips_surrounding_whitespace() {
    source_orch
    # Tabs and spaces around hostnames.
    printf '   host1\n\thost2\t\nhost3   \n' > "$SERVER_LIST_FILE"
    local out
    out=$(read_servers)
    assert_eq "host1
host2
host3" "$out"
}

test_read_servers_dies_when_file_missing() {
    unset IPERF_SERVERS
    SERVER_LIST_FILE=""
    source_orch
    SERVER_LIST_FILE=""
    local out rc
    out=$(read_servers 2>&1)
    rc=$?
    assert_ne 0 "$rc" "missing file should cause non-zero exit" || return 1
    assert_contains "$out" "no server list" "should mention missing list" || return 1
}

test_read_servers_handles_ipv4_and_hostnames() {
    source_orch
    cat > "$SERVER_LIST_FILE" <<'EOF'
10.0.0.1
host-a.example.com
192.168.1.50
EOF
    local out
    out=$(read_servers)
    assert_eq "10.0.0.1
host-a.example.com
192.168.1.50" "$out"
}

test_read_servers_count_matches_input() {
    source_orch
    {
        echo "h1"
        echo "h2"
        echo "h3"
        echo "# comment"
        echo ""
        echo "h4"
    } > "$SERVER_LIST_FILE"
    local n
    n=$(read_servers | wc -l)
    assert_eq "4" "$n" "should count 4 hosts"
}

run_test test_read_servers_strips_blank_lines
run_test test_read_servers_strips_full_line_comments
run_test test_read_servers_strips_inline_comments
run_test test_read_servers_strips_surrounding_whitespace
run_test test_read_servers_dies_when_file_missing
run_test test_read_servers_handles_ipv4_and_hostnames
run_test test_read_servers_count_matches_input

report_tests
