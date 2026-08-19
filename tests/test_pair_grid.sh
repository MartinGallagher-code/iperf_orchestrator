#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for partial-mesh support: the src\dst pair grid written by
# `gen --grid`, its parsing (read_servers + _load_pair_grid), and the
# modes that honor it. Also covers `status --watch`.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# A 3-host grid with h1->h3 and h3->h1 blanked, and h3 sending only to h2.
write_grid_server_list() {
    cat > "$IPERF_SERVERS" <<'EOF'
# comment lines are fine inside a grid too
src\dst,h1,h2,h3
h1,,x,
h2,x,,x
h3,,x,
EOF
}

# ---- parsing ----------------------------------------------------------------

test_read_servers_returns_grid_header_hosts() {
    write_grid_server_list
    SERVER_LIST_FILE="$IPERF_SERVERS"
    local out; out=$(read_servers)
    assert_eq "h1
h2
h3" "$out" "grid hosts must come from the header row" || return 1
}

test_pair_enabled_honors_blank_cells() {
    write_grid_server_list
    SERVER_LIST_FILE="$IPERF_SERVERS"
    pair_enabled h1 h2 || { echo "h1->h2 should be enabled" >&2; return 1; }
    pair_enabled h1 h3 && { echo "h1->h3 should be disabled" >&2; return 1; }
    pair_enabled h3 h1 && { echo "h3->h1 should be disabled" >&2; return 1; }
    pair_enabled h2 h1 || { echo "h2->h1 should be enabled" >&2; return 1; }
    return 0
}

test_grid_tx_counts_match_rows() {
    write_grid_server_list
    SERVER_LIST_FILE="$IPERF_SERVERS"
    _load_pair_grid "$SERVER_LIST_FILE"
    assert_eq 1 "${GRID_TX_COUNT[h1]}" "h1 sends to 1 peer" || return 1
    assert_eq 2 "${GRID_TX_COUNT[h2]}" "h2 sends to 2 peers" || return 1
    assert_eq 1 "${GRID_TX_COUNT[h3]}" "h3 sends to 1 peer" || return 1
}

test_plain_list_means_full_mesh() {
    write_server_list h1 h2 h3 >/dev/null
    SERVER_LIST_FILE="$IPERF_SERVERS"
    pair_enabled h1 h3 || { echo "plain list must enable every pair" >&2; return 1; }
    return 0
}

test_grid_row_not_in_header_warns_and_is_ignored() {
    cat > "$IPERF_SERVERS" <<'EOF'
src\dst,h1,h2
h1,,x
h2,x,
h9,x,x
EOF
    SERVER_LIST_FILE="$IPERF_SERVERS"
    local out; out=$(_load_pair_grid "$SERVER_LIST_FILE" 2>&1)
    assert_contains "$out" "not a header column" || return 1
    pair_enabled h9 h1 && { echo "unknown row must not enable pairs" >&2; return 1; }
    return 0
}

# ---- gen --grid -------------------------------------------------------------

test_gen_grid_writes_full_mesh_grid() {
    write_server_list h1 h2 h3 >/dev/null
    run_orch gen --grid
    assert_status 0 "$RUN_RC" || return 1
    local plan; plan=$(cat iperf_plan.conf)
    assert_contains "$plan" 'src\dst,h1,h2,h3' || return 1
    assert_contains "$plan" 'h1,,x,x' || return 1
    assert_contains "$plan" 'h3,x,x,' || return 1
    assert_contains "$RUN_OUT" "6 enabled pair(s)" || return 1
}

test_gen_without_grid_stays_plain() {
    write_server_list h1 h2 >/dev/null
    run_orch gen
    # The prose header mentions the grid option; only the header ROW
    # (with its comma) marks an actual grid.
    assert_not_contains "$(cat iperf_plan.conf)" 'src\dst,' || return 1
}

test_regen_preserves_blanked_cells() {
    write_server_list h1 h2 h3 >/dev/null
    run_orch gen --grid
    sed -i 's/^h1,,x,x$/h1,,x,/' iperf_plan.conf
    # Re-gen from the plan itself (no --servers): the grid and its blanked
    # cell must survive, and the flag override must land.
    RUN_OUT="$(env -u IPERF_SERVERS bash "$ORCH" gen --duration 42 2>&1)"
    RUN_RC=$?
    assert_status 0 "$RUN_RC" || return 1
    local plan; plan=$(cat iperf_plan.conf)
    assert_contains "$plan" 'h1,,x,' "blanked cell must survive re-gen" || return 1
    assert_not_contains "$plan" 'h1,,x,x' || return 1
    assert_contains "$plan" "duration=42" || return 1
    assert_contains "$RUN_OUT" "5 enabled pair(s)" || return 1
}

# ---- the modes honor the grid ----------------------------------------------

test_create_scripts_respects_grid() {
    write_grid_server_list
    run_orch create-scripts
    assert_status 0 "$RUN_RC" "create-scripts must accept uneven grid counts" || return 1
    local s1="$RESULTS_BASE/test-run/scripts/run_h1_test-run.sh"
    local s2="$RESULTS_BASE/test-run/scripts/run_h2_test-run.sh"
    assert_file_exists "$s1" || return 1
    assert_contains "$(grep '^TARGETS=' "$s1")" '( "h2"  )' "h1 sends only to h2" || return 1
    assert_contains "$(grep '^TARGETS=' "$s2")" '"h1" "h3"' "h2 sends to h1 and h3" || return 1
}

test_create_scripts_allows_receive_only_host() {
    cat > "$IPERF_SERVERS" <<'EOF'
src\dst,h1,h2
h1,,x
h2,,
EOF
    run_orch create-scripts
    assert_status 0 "$RUN_RC" "a 0-target grid row must not die" || return 1
    local s2="$RESULTS_BASE/test-run/scripts/run_h2_test-run.sh"
    assert_file_exists "$s2" "receive-only host still gets a script (CPU sampler)" || return 1
    assert_contains "$(grep '^TARGETS=' "$s2")" 'TARGETS=(  )' || return 1
}

test_rolling_dry_run_restricts_peers() {
    write_grid_server_list
    run_orch --dry-run --total-time 1 run-tests rolling
    assert_status 0 "$RUN_RC" || return 1
    local l1="$RESULTS_BASE/test-run/logs/rolling_h1.log"
    assert_file_exists "$l1" || return 1
    assert_contains "$(cat "$l1")" 'PEERS=( "h2"' "h1 rolls only against h2" || return 1
    assert_not_contains "$(cat "$l1")" '"h3"' "h1 must not roll against h3" || return 1
}

test_hints_sizes_from_enabled_edges() {
    write_grid_server_list
    run_orch hints
    assert_contains "$RUN_OUT" "4 directed tests" "grid enables 4 of 6 edges" || return 1
}

# ---- status --watch ---------------------------------------------------------

test_status_watch_requires_numeric_value() {
    run_orch status --watch abc
    [ "$RUN_RC" -ne 0 ] || { echo "--watch abc should fail" >&2; return 1; }
}

test_status_rejects_unknown_argument() {
    run_orch status --json
    [ "$RUN_RC" -ne 0 ] || { echo "status --json should fail" >&2; return 1; }
    assert_contains "$RUN_OUT" "unknown argument" || return 1
}

test_status_watch_redraws_until_interrupted() {
    # No server list -> each draw is instant. 5s window at 1s cadence must
    # produce at least two headers before timeout(1) kills the loop.
    RUN_OUT="$(env -u IPERF_SERVERS timeout 5 bash "$ORCH" status --watch 1 2>&1)"
    local n
    n=$(printf '%s\n' "$RUN_OUT" | grep -c "ctrl-c to stop")
    [ "$n" -ge 2 ] || { echo "expected >=2 redraws, saw $n" >&2; return 1; }
}

# ---- runner ----------------------------------------------------------------

run_test test_read_servers_returns_grid_header_hosts
run_test test_pair_enabled_honors_blank_cells
run_test test_grid_tx_counts_match_rows
run_test test_plain_list_means_full_mesh
run_test test_grid_row_not_in_header_warns_and_is_ignored
run_test test_gen_grid_writes_full_mesh_grid
run_test test_gen_without_grid_stays_plain
run_test test_regen_preserves_blanked_cells
run_test test_create_scripts_respects_grid
run_test test_create_scripts_allows_receive_only_host
run_test test_rolling_dry_run_restricts_peers
run_test test_hints_sizes_from_enabled_edges
run_test test_status_watch_requires_numeric_value
run_test test_status_rejects_unknown_argument
run_test test_status_watch_redraws_until_interrupted

report_tests
