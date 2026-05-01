#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for `create-scripts`: per-host run script generation, balanced
# load summary, and that the generated scripts are syntactically valid
# bash that uses the right targets.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

write_and_init() {
    local src="$TEST_TMPDIR/srv.txt"
    : > "$src"
    local h
    for h in "$@"; do
        printf '%s\n' "$h" >> "$src"
    done
    run_orch init "$src" >/dev/null 2>&1
}

test_create_scripts_generates_one_script_per_host() {
    write_and_init h0 h1 h2 h3
    run_orch create-scripts
    assert_status 0 "$RUN_RC" "create-scripts should succeed" || return 1
    local scripts_dir="$IPERF_DIR/scripts"
    for h in h0 h1 h2 h3; do
        assert_file_exists "$scripts_dir/run_$h.sh" "missing script for $h" || return 1
    done
    # Exactly 4 scripts, no extras.
    local n
    n=$(find "$scripts_dir" -maxdepth 1 -name 'run_*.sh' | wc -l)
    assert_eq "4" "$n" "should generate exactly 4 scripts" || return 1
}

test_generated_scripts_are_valid_bash_syntax() {
    write_and_init host-a host-b host-c host-d host-e
    run_orch create-scripts
    assert_status 0 "$RUN_RC" || return 1
    local s
    for s in "$IPERF_DIR/scripts"/run_*.sh; do
        bash -n "$s" || {
            echo "syntax error in $s" >&2
            cat "$s" >&2
            return 1
        }
    done
}

test_generated_scripts_are_executable() {
    write_and_init h0 h1 h2
    run_orch create-scripts
    assert_status 0 "$RUN_RC" || return 1
    local s
    for s in "$IPERF_DIR/scripts"/run_*.sh; do
        [ -x "$s" ] || {
            echo "$s is not executable" >&2
            return 1
        }
    done
}

test_generated_script_targets_are_balanced() {
    # With N=5 (odd) the parity rule gives every host exactly 2 client
    # targets. The script logs that distribution. We also verify by
    # parsing the TARGETS=( ... ) line.
    write_and_init alpha bravo charlie delta echo
    run_orch create-scripts
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "Client load: min=2, max=2" \
        "expected balanced spread of 0 for N=5" || return 1
    # Total tests in the log line should equal N*(N-1)/2 = 10.
    assert_contains "$RUN_OUT" "total tests=10" "10 canonical pairs for N=5" || return 1

    # Cross-check by extracting TARGETS=(...) from each script and
    # making sure the totals add up to 10.
    local total=0 s line
    for s in "$IPERF_DIR/scripts"/run_*.sh; do
        line=$(grep -E '^TARGETS=\(' "$s")
        # Count tokens between the parens. Empty list -> 0.
        local inside
        inside="${line#TARGETS=( }"
        inside="${inside% )}"
        # Strip trailing space + paren if format differs.
        if [ -z "$inside" ] || [ "$inside" = ")" ] || [ "$line" = "TARGETS=(  )" ]; then
            continue
        fi
        local count
        count=$(echo "$line" | tr -cd '"' | wc -c)
        # Each target is wrapped in "..." so the count of " is 2*targets.
        count=$((count / 2))
        total=$((total + count))
    done
    assert_eq "10" "$total" "sum of TARGETS across all scripts should be 10" || return 1
}

test_generated_script_does_not_target_self() {
    write_and_init h0 h1 h2 h3
    run_orch create-scripts >/dev/null 2>&1
    local s host
    for s in "$IPERF_DIR/scripts"/run_*.sh; do
        host=$(basename "$s" .sh)
        host="${host#run_}"
        # The TARGETS= line must not contain the host's own name.
        if grep -E '^TARGETS=\(' "$s" | grep -qF "\"$host\""; then
            echo "$host appears in its own TARGETS list" >&2
            grep -E '^TARGETS=\(' "$s" >&2
            return 1
        fi
    done
}

test_generated_script_uses_full_duplex_and_csv_output() {
    write_and_init h0 h1 h2
    run_orch create-scripts >/dev/null 2>&1
    # Pick a script that has at least one target (some hosts may have 0).
    local s
    for s in "$IPERF_DIR/scripts"/run_*.sh; do
        if grep -E '^TARGETS=\( "[^"]+"' "$s" >/dev/null; then
            grep -q -- '--full-duplex' "$s" || {
                echo "expected --full-duplex flag in $s" >&2
                return 1
            }
            grep -q -- '-y C' "$s" || {
                echo "expected '-y C' (CSV) in $s" >&2
                return 1
            }
            grep -q -- '-e' "$s" || {
                echo "expected '-e' (enhanced) in $s" >&2
                return 1
            }
            return 0
        fi
    done
    echo "no script had targets to inspect" >&2
    return 1
}

test_generated_script_writes_pair_header() {
    write_and_init h0 h1 h2
    run_orch create-scripts >/dev/null 2>&1
    # The script writes "# pair_a=$SOURCE pair_b=$target ..." into each
    # log file -- this is what cmd_parse_csv keys on.
    local s
    for s in "$IPERF_DIR/scripts"/run_*.sh; do
        if grep -E '^TARGETS=\( "[^"]+"' "$s" >/dev/null; then
            grep -q 'pair_a=' "$s" || {
                echo "missing pair_a= header emit in $s" >&2
                return 1
            }
            grep -q 'pair_b=' "$s" || {
                echo "missing pair_b= header emit in $s" >&2
                return 1
            }
            return 0
        fi
    done
}

test_generated_script_sets_correct_constants() {
    write_and_init h0 h1
    IPERF_PORT=6000 IPERF_DURATION=15 IPERF_PARALLEL=3 \
        run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$IPERF_DIR/scripts" -name 'run_*.sh' | head -n1)
    grep -q '^PORT=6000$' "$s" || {
        echo "PORT not propagated to script" >&2
        cat "$s" >&2
        return 1
    }
    grep -q '^DURATION=15$' "$s" || return 1
    grep -q '^PARALLEL=3$' "$s" || return 1
}

test_create_scripts_sets_pipeline_state() {
    write_and_init h0 h1 h2
    run_orch create-scripts >/dev/null 2>&1
    grep -q '^SCRIPTS_CREATED=yes$' "$IPERF_DIR/state" || {
        echo "SCRIPTS_CREATED not flagged in state" >&2
        cat "$IPERF_DIR/state" >&2
        return 1
    }
}

test_generated_scripts_handle_synchronized_start() {
    write_and_init h0 h1 h2
    run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$IPERF_DIR/scripts" -name 'run_*.sh' | head -n1)
    # Synchronized start logic must compare START_TIME to current epoch
    # and sleep until then.
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
run_test test_create_scripts_sets_pipeline_state
run_test test_generated_scripts_handle_synchronized_start

report_tests
