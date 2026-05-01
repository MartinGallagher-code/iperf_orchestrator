#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for build_host_idx + is_client_for. The script's docstring
# promises:
#   - For every unordered pair {a,b} exactly one of (a is client of b)
#     and (b is client of a) is true.
#   - Per-host client load is balanced: spread of 0 (N odd) or 1 (N even).

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# Helper: given a list of hostnames passed as args, write the server
# list, source the script, build the host index. Outputs nothing.
setup_hosts() {
    write_server_list "$@" >/dev/null
    source_orch
    build_host_idx
}

test_is_client_self_returns_false() {
    setup_hosts h0 h1 h2
    if is_client_for h0 h0; then
        echo "is_client_for(h0,h0) should be false" >&2
        return 1
    fi
}

test_is_client_returns_false_for_unknown_host() {
    setup_hosts h0 h1 h2
    if is_client_for h0 ghost; then
        echo "unknown dst should not be client" >&2
        return 1
    fi
    if is_client_for ghost h0; then
        echo "unknown src should not be client" >&2
        return 1
    fi
}

test_each_pair_has_exactly_one_client() {
    local hosts=(a b c d e f g)
    setup_hosts "${hosts[@]}"
    local i j a b ac bc
    for ((i = 0; i < ${#hosts[@]}; i++)); do
        for ((j = i + 1; j < ${#hosts[@]}; j++)); do
            a="${hosts[i]}"
            b="${hosts[j]}"
            ac=0; bc=0
            is_client_for "$a" "$b" && ac=1
            is_client_for "$b" "$a" && bc=1
            local sum=$((ac + bc))
            if [ "$sum" -ne 1 ]; then
                echo "pair {$a,$b}: expected exactly one client, got ac=$ac bc=$bc" >&2
                return 1
            fi
        done
    done
}

# Compute (min, max, sum) of client counts per host.
client_load_stats() {
    local n_hosts=$1; shift
    local hosts=("$@")
    local min=999999 max=0 sum=0 c i j
    for ((i = 0; i < n_hosts; i++)); do
        c=0
        for ((j = 0; j < n_hosts; j++)); do
            [ "$i" -eq "$j" ] && continue
            if is_client_for "${hosts[i]}" "${hosts[j]}"; then
                c=$((c + 1))
            fi
        done
        sum=$((sum + c))
        [ "$c" -lt "$min" ] && min=$c
        [ "$c" -gt "$max" ] && max=$c
    done
    echo "$min $max $sum"
}

test_balanced_load_n_odd() {
    # N=5: every host should run exactly (N-1)/2 = 2 clients.
    local hosts=(a b c d e)
    setup_hosts "${hosts[@]}"
    local stats
    stats=$(client_load_stats 5 "${hosts[@]}")
    read -r mn mx sum <<<"$stats"
    assert_eq "2" "$mn" "min should be 2 for N=5" || return 1
    assert_eq "2" "$mx" "max should be 2 for N=5" || return 1
    # Total clients across all hosts == total canonical pairs == N*(N-1)/2 = 10.
    assert_eq "10" "$sum" "total client count should equal N*(N-1)/2 for N=5" || return 1
}

test_balanced_load_n_even() {
    # N=6: per-host should be 2 or 3 with spread of exactly 1.
    local hosts=(a b c d e f)
    setup_hosts "${hosts[@]}"
    local stats
    stats=$(client_load_stats 6 "${hosts[@]}")
    read -r mn mx sum <<<"$stats"
    local spread=$((mx - mn))
    if [ "$spread" -gt 1 ]; then
        echo "spread for N=6 should be at most 1, got mn=$mn mx=$mx" >&2
        return 1
    fi
    # Total = 6*5/2 = 15
    assert_eq "15" "$sum" "total should equal 15 for N=6" || return 1
}

test_balanced_load_large_mesh() {
    # N=20 (even): spread <= 1, total = N*(N-1)/2 = 190
    local hosts=()
    local i
    for i in $(seq 1 20); do
        hosts+=("h$i")
    done
    setup_hosts "${hosts[@]}"
    local stats
    stats=$(client_load_stats 20 "${hosts[@]}")
    read -r mn mx sum <<<"$stats"
    local spread=$((mx - mn))
    if [ "$spread" -gt 1 ]; then
        echo "N=20 spread should be <= 1, got mn=$mn mx=$mx" >&2
        return 1
    fi
    assert_eq "190" "$sum" "total should be 190 for N=20" || return 1
}

test_two_hosts_minimal_case() {
    setup_hosts h0 h1
    # Pair (0,1): 0+1 odd -> larger index is client -> h1 is client of h0.
    local h0_client=0 h1_client=0
    is_client_for h0 h1 && h0_client=1
    is_client_for h1 h0 && h1_client=1
    assert_eq "0" "$h0_client" "h0 should NOT be client of h1 (parity rule, indices 0+1=odd)" || return 1
    assert_eq "1" "$h1_client" "h1 SHOULD be client of h0" || return 1
}

run_test test_is_client_self_returns_false
run_test test_is_client_returns_false_for_unknown_host
run_test test_each_pair_has_exactly_one_client
run_test test_balanced_load_n_odd
run_test test_balanced_load_n_even
run_test test_balanced_load_large_mesh
run_test test_two_hosts_minimal_case

report_tests
