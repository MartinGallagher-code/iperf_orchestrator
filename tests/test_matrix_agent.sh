#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for matrix_agent: matrix generation, admissibility checking,
# and a real two-agent localhost run with paced TCP flows. The run test
# asserts achieved rate lands near the 40 Mbps target -- loose bounds
# because CI runners are noisy neighbors.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

AGENT="$REPO_ROOT/matrix_agent/matrix_agent.py"

# Distinct high ports per test run so parallel/leftover runs can't collide.
PORT_A=$(( 40000 + (RANDOM % 20000) ))
PORT_B=$(( PORT_A + 1 ))

_write_hosts() {
    cat > "$TEST_TMPDIR/hosts.txt" <<EOF
alpha=127.0.0.1:$PORT_A
beta=127.0.0.1:$PORT_B
EOF
}

test_gen_writes_grid_matrix() {
    _write_hosts
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/hosts.txt" --rate-mbps 40 \
        -o "$TEST_TMPDIR/matrix.csv" >/dev/null
    assert_status 0 $? "gen should succeed" || return 1
    local m; m=$(cat "$TEST_TMPDIR/matrix.csv")
    assert_contains "$m" "alpha=127.0.0.1:$PORT_A" "header keeps host token" || return 1
    assert_contains "$m" "40.000" "cells carry the rate" || return 1
    # Diagonal must be empty: the alpha row starts with the token then an
    # empty cell (alpha->alpha), then 40.000 (alpha->beta).
    assert_contains "$m" "alpha=127.0.0.1:$PORT_A,,40.000" "diagonal empty" || return 1
}

test_check_flags_inadmissible_matrix() {
    _write_hosts
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/hosts.txt" --rate-mbps 40 \
        -o "$TEST_TMPDIR/matrix.csv" >/dev/null
    # Generous caps: admissible.
    local out rc
    out=$(python3 "$AGENT" check --matrix "$TEST_TMPDIR/matrix.csv" \
        --egress-gbps 1 --ingress-gbps 1 2>&1); rc=$?
    assert_status 0 "$rc" "40 Mbps under a 1 Gbps cap should pass" || return 1
    assert_contains "$out" "admissible" || return 1
    # Absurdly small cap: violation, nonzero exit.
    out=$(python3 "$AGENT" check --matrix "$TEST_TMPDIR/matrix.csv" \
        --egress-gbps 0.001 2>&1); rc=$?
    assert_status 1 "$rc" "40 Mbps over a 1 Mbps cap should fail" || return 1
    assert_contains "$out" "VIOLATION" || return 1
}

test_two_agents_sustain_target_rate() {
    _write_hosts
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/hosts.txt" --rate-mbps 40 \
        -o "$TEST_TMPDIR/matrix.csv" >/dev/null
    local rep="$TEST_TMPDIR/rep"
    python3 "$AGENT" run --matrix "$TEST_TMPDIR/matrix.csv" --hostname alpha \
        --interval 1 --duration 6 --report-dir "$rep" >/dev/null 2>&1 &
    local pid_a=$!
    python3 "$AGENT" run --matrix "$TEST_TMPDIR/matrix.csv" --hostname beta \
        --interval 1 --duration 6 --report-dir "$rep" >/dev/null 2>&1 &
    local pid_b=$!
    wait "$pid_a"; local rc_a=$?
    wait "$pid_b"; local rc_b=$?
    assert_status 0 "$rc_a" "alpha agent should exit cleanly" || return 1
    assert_status 0 "$rc_b" "beta agent should exit cleanly" || return 1
    [ -f "$rep/alpha_agent.csv" ] || { echo "no alpha report"; return 1; }
    [ -f "$rep/beta_agent.csv" ]  || { echo "no beta report";  return 1; }

    # Summarize and pull the aggregate achieved rx rate. Two 40 Mbps
    # flows -> target 80; accept 40..120 so a slow runner can't flake it,
    # while still proving pacing neither stalled nor ran away.
    local out; out=$(python3 "$AGENT" summarize "$rep"/*_agent.csv --window 10)
    assert_contains "$out" "aggregate rx" || return 1
    local achieved
    achieved=$(echo "$out" | sed -n 's/^aggregate rx: \([0-9.]*\) \/ .*/\1/p')
    [ -n "$achieved" ] || { echo "could not parse achieved rate from: $out"; return 1; }
    python3 -c "import sys; v=float('$achieved'); sys.exit(0 if 40.0 <= v <= 120.0 else 1)" || {
        echo "achieved rx $achieved Mbps outside 40..120 (target 80)"
        echo "$out"
        return 1
    }
}

test_agent_rejects_unknown_hostname() {
    _write_hosts
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/hosts.txt" --rate-mbps 10 \
        -o "$TEST_TMPDIR/matrix.csv" >/dev/null
    local out rc
    out=$(python3 "$AGENT" run --matrix "$TEST_TMPDIR/matrix.csv" \
        --hostname nosuch --duration 1 2>&1); rc=$?
    [ "$rc" -ne 0 ] || { echo "unknown hostname should fail"; return 1; }
    assert_contains "$out" "not in matrix" || return 1
}

run_test test_gen_writes_grid_matrix
run_test test_check_flags_inadmissible_matrix
run_test test_two_agents_sustain_target_rate
run_test test_agent_rejects_unknown_hostname

report_tests
