#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for `create-scripts`: per-host run script generation, balanced
# load summary, and that the generated scripts are syntactically valid
# bash that uses the right targets.
#
# Generated script names embed both <host>_<run-id> so $REMOTE_DIR can
# safely live on a shared filesystem.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# Helper: scripts dir for the active RUN_ID.
scripts_dir() { echo "$RESULTS_BASE/$IPERF_RUN_ID/scripts"; }

write_servers_only() {
    write_server_list "$@" >/dev/null
}

test_create_scripts_generates_one_script_per_host() {
    write_servers_only h0 h1 h2 h3
    run_orch create-scripts
    assert_status 0 "$RUN_RC" "create-scripts should succeed" || return 1
    local sd; sd=$(scripts_dir)
    for h in h0 h1 h2 h3; do
        assert_file_exists "$sd/run_${h}_${IPERF_RUN_ID}.sh" "missing script for $h" || return 1
    done
    local n
    n=$(find "$sd" -maxdepth 1 -name "run_*_${IPERF_RUN_ID}.sh" | wc -l)
    assert_eq "4" "$n" "should generate exactly 4 scripts" || return 1
}

test_generated_scripts_are_valid_bash_syntax() {
    write_servers_only host-a host-b host-c host-d host-e
    run_orch create-scripts
    assert_status 0 "$RUN_RC" || return 1
    local s
    for s in "$(scripts_dir)"/run_*.sh; do
        bash -n "$s" || { echo "syntax error in $s" >&2; cat "$s" >&2; return 1; }
    done
}

test_generated_scripts_are_executable() {
    write_servers_only h0 h1 h2
    run_orch create-scripts
    assert_status 0 "$RUN_RC" || return 1
    local s
    for s in "$(scripts_dir)"/run_*.sh; do
        [ -x "$s" ] || { echo "$s is not executable" >&2; return 1; }
    done
}

test_generated_script_targets_are_balanced() {
    write_servers_only alpha bravo charlie delta echo
    run_orch create-scripts
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "Client load: min=2, max=2" \
        "expected balanced spread of 0 for N=5" || return 1
    assert_contains "$RUN_OUT" "total tests=10" "10 canonical pairs for N=5" || return 1

    local total=0 s line
    for s in "$(scripts_dir)"/run_*.sh; do
        line=$(grep -E '^TARGETS=\(' "$s")
        local count
        count=$(echo "$line" | tr -cd '"' | wc -c)
        count=$((count / 2))
        total=$((total + count))
    done
    assert_eq "10" "$total" "sum of TARGETS across all scripts should be 10" || return 1
}

test_generated_script_does_not_target_self() {
    write_servers_only h0 h1 h2 h3
    run_orch create-scripts >/dev/null 2>&1
    local s host base
    for s in "$(scripts_dir)"/run_*.sh; do
        base=$(basename "$s" .sh)
        # filename: run_<host>_<run-id>
        host="${base#run_}"
        host="${host%_${IPERF_RUN_ID}}"
        if grep -E '^TARGETS=\(' "$s" | grep -qF "\"$host\""; then
            echo "$host appears in its own TARGETS list" >&2
            grep -E '^TARGETS=\(' "$s" >&2
            return 1
        fi
    done
}

test_generated_script_uses_full_duplex_and_csv_output() {
    write_servers_only h0 h1 h2
    run_orch create-scripts >/dev/null 2>&1
    local s
    for s in "$(scripts_dir)"/run_*.sh; do
        if grep -E '^TARGETS=\( "[^"]+"' "$s" >/dev/null; then
            grep -q -- '--full-duplex' "$s" || { echo "expected --full-duplex in $s" >&2; return 1; }
            grep -q -- '-y C' "$s" || { echo "expected '-y C' in $s" >&2; return 1; }
            grep -q -- '-e' "$s" || { echo "expected '-e' in $s" >&2; return 1; }
            return 0
        fi
    done
    echo "no script had targets to inspect" >&2
    return 1
}

test_generated_script_writes_pair_header() {
    write_servers_only h0 h1 h2
    run_orch create-scripts >/dev/null 2>&1
    local s
    for s in "$(scripts_dir)"/run_*.sh; do
        if grep -E '^TARGETS=\( "[^"]+"' "$s" >/dev/null; then
            grep -q 'pair_a=' "$s" || return 1
            grep -q 'pair_b=' "$s" || return 1
            return 0
        fi
    done
}

test_generated_script_sets_correct_constants() {
    write_servers_only h0 h1
    IPERF_PORT=6000 IPERF_DURATION=15 IPERF_STREAMS=3 \
        run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$(scripts_dir)" -name 'run_*.sh' | head -n1)
    grep -q '^PORT=6000$' "$s" || { echo "PORT not propagated" >&2; cat "$s" >&2; return 1; }
    grep -q '^DURATION=15$' "$s" || return 1
    grep -q '^PARALLEL=3$' "$s" || return 1
    grep -q "^RUN_ID=\"$IPERF_RUN_ID\"$" "$s" || { echo "RUN_ID not embedded" >&2; return 1; }
}

test_create_scripts_sanitizes_ipv6_filenames() {
    write_servers_only '[fe80::1]' '[fe80::2]'
    run_orch create-scripts
    assert_status 0 "$RUN_RC" "create-scripts should accept bracketed IPv6" || return 1
    local sd; sd=$(scripts_dir)
    assert_file_exists "$sd/run__fe80__1__${IPERF_RUN_ID}.sh" "missing sanitized script" || return 1
    assert_file_exists "$sd/run__fe80__2__${IPERF_RUN_ID}.sh" "missing sanitized script" || return 1
    grep -qF 'SOURCE="[fe80::1]"' "$sd/run__fe80__1__${IPERF_RUN_ID}.sh" || return 1
    grep -qF 'SOURCE="[fe80::2]"' "$sd/run__fe80__2__${IPERF_RUN_ID}.sh" || return 1
    if ! grep -hqF '"[fe80::1]"' "$sd"/run__fe80__*.sh \
       || ! grep -hqF '"[fe80::2]"' "$sd"/run__fe80__*.sh; then
        echo "expected both peers' raw hostnames to appear across the two scripts" >&2
        return 1
    fi
}

test_generated_script_outputs_run_id_suffixed_filenames() {
    write_servers_only h0 h1 h2
    run_orch create-scripts >/dev/null 2>&1
    local s
    for s in "$(scripts_dir)"/run_*.sh; do
        if grep -E '^TARGETS=\( "[^"]+"' "$s" >/dev/null; then
            # Output paths must include both host and run-id.
            grep -q "iperf_test_\${SOURCE_SAFE}_to_\${target_safe}_\${RUN_ID}.log" "$s" || {
                echo "client log filename missing run-id suffix in $s" >&2
                return 1
            }
            grep -q "cpu_\${SOURCE_SAFE}_\${RUN_ID}.log" "$s" || {
                echo "cpu log filename missing run-id suffix in $s" >&2
                return 1
            }
            grep -q "iperf_run_\${SOURCE_SAFE}_\${RUN_ID}.status" "$s" || {
                echo "status filename missing run-id suffix in $s" >&2
                return 1
            }
            return 0
        fi
    done
    return 1
}

test_generated_scripts_handle_synchronized_start() {
    write_servers_only h0 h1 h2
    run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$(scripts_dir)" -name 'run_*.sh' | head -n1)
    grep -q 'START_TIME=' "$s" || return 1
    grep -qE 'sleep .*\$\(\( START_TIME - now \)\)' "$s" || {
        echo "sync-sleep arithmetic missing in $s" >&2
        return 1
    }
}

run_test test_create_scripts_generates_one_script_per_host
run_test test_generated_scripts_are_valid_bash_syntax
run_test test_generated_scripts_are_executable
run_test test_generated_script_targets_are_balanced
run_test test_generated_script_does_not_target_self
run_test test_generated_script_uses_full_duplex_and_csv_output
run_test test_generated_script_writes_pair_header
run_test test_generated_script_sets_correct_constants
run_test test_create_scripts_sanitizes_ipv6_filenames
run_test test_generated_script_outputs_run_id_suffixed_filenames
run_test test_generated_scripts_handle_synchronized_start

report_tests
