#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# End-to-end behavior tests for the generated remote run_iperf.sh.
# We actually execute the generated script with a fake `iperf` binary
# (and optionally a fake `mpstat`) so its run-time behavior -- not
# just its source text -- gets exercised.
#
# The fake iperf records its argv and emits a plausible CSV summary
# back to stdout; the script captures that into its log file. We can
# then assert on the recorded args and the log contents.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# Build a fake iperf in $FAKE_BIN. It writes its argv to a per-call
# log and emits one CSV summary row to stdout (which the generated
# run_iperf.sh redirects into iperf_test_<src>_to_<dst>.log).
install_fake_iperf() {
    mkdir -p "$FAKE_BIN"
    cat > "$FAKE_BIN/iperf" <<'SHIM'
#!/usr/bin/env bash
echo "iperf $*" >> "$FAKE_BIN/iperf_calls.log"
# Emit one bogus-but-parseable CSV summary line.
target="-"
for ((i=1; i<=$#; i++)); do
    if [ "${!i}" = "-c" ]; then j=$((i+1)); target="${!j}"; fi
done
ts=$(date +%Y%m%d%H%M%S)
echo "$ts.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000"
SHIM
    chmod +x "$FAKE_BIN/iperf"
    : > "$FAKE_BIN/iperf_calls.log"
}

# Fake mpstat that produces a single ISO-time sample. Optional.
install_fake_mpstat() {
    cat > "$FAKE_BIN/mpstat" <<'SHIM'
#!/usr/bin/env bash
echo "Linux fake (host)   01/01/2026  _x86_64_    (1 CPU)"
echo
echo "12:00:00     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle"
echo "12:00:01     all    1.00    0.00    0.50    0.00    0.00    0.20    0.00    0.00    0.00   98.30"
SHIM
    chmod +x "$FAKE_BIN/mpstat"
}

# Generate the run scripts via the real orchestrator, then return the
# path of the generated script for the named host.
generate_scripts_for() {
    local hosts=("$@")
    write_server_list "${hosts[@]}" >/dev/null
    run_orch --duration=1 create-scripts >/dev/null 2>&1
}

scripts_dir() { echo "$RESULTS_BASE/$IPERF_RUN_ID/scripts"; }

# Run the generated script for $host in a working dir, with $FAKE_BIN
# (which has fake iperf etc.) on PATH.
run_remote_script() {
    local host="$1"; shift
    local script="$(scripts_dir)/run_${host}_${IPERF_RUN_ID}.sh"
    [ -f "$script" ] || { echo "missing script for $host" >&2; return 2; }
    local workdir="$TEST_TMPDIR/work-$host"
    mkdir -p "$workdir"
    # The script does `cd "$(dirname "$0")"` first, so we copy it to
    # the workdir as run_iperf.sh (which is what distribute-scripts
    # would have done on a real host).
    cp "$script" "$workdir/run_iperf.sh"
    chmod +x "$workdir/run_iperf.sh"
    PATH="$FAKE_BIN:$PATH" bash "$workdir/run_iperf.sh" "$@" >"$workdir/stdout" 2>"$workdir/stderr"
    local rc=$?
    REMOTE_WORKDIR="$workdir"
    return $rc
}

test_generated_script_executes_iperf_for_each_target() {
    install_fake_iperf
    generate_scripts_for src target1 target2
    # Full-mesh fan-out: every host has every other host as a target,
    # so any script will do.
    local script="src"
    run_remote_script "$script" 0
    assert_status 0 "$?" "remote script should exit 0" || return 1
    # iperf was invoked at least once with -c <target>
    if ! grep -q -- '-c ' "$FAKE_BIN/iperf_calls.log"; then
        echo "expected at least one iperf -c invocation" >&2
        cat "$FAKE_BIN/iperf_calls.log" >&2
        return 1
    fi
    # iperf must NOT be invoked with --full-duplex (we use unidirectional
    # tests now to keep CSV parsing unambiguous).
    if grep -q -- '--full-duplex' "$FAKE_BIN/iperf_calls.log"; then
        echo "unexpected --full-duplex in iperf args" >&2
        return 1
    fi
    # iperf invoked with -y C
    grep -q -- '-y C' "$FAKE_BIN/iperf_calls.log" || {
        echo "expected -y C in iperf args" >&2
        return 1
    }
}

test_generated_script_writes_pair_header_into_log() {
    install_fake_iperf
    generate_scripts_for src dst
    local script="src"
    run_remote_script "$script" 0
    # Look for a "# pair_a=..." header in any of the generated logs.
    if ! grep -hE '^# pair_a=' "$REMOTE_WORKDIR"/iperf_test_*.log >/dev/null 2>&1; then
        echo "no log file contained the pair_a header" >&2
        ls "$REMOTE_WORKDIR" >&2
        return 1
    fi
    # And it must contain the source host's name + a target.
    grep -qE "^# pair_a=$script pair_b=" "$REMOTE_WORKDIR"/iperf_test_*.log \
        || { echo "header missing or malformed" >&2; return 1; }
    # Single-direction marker is present.
    grep -q 'full_duplex=0' "$REMOTE_WORKDIR"/iperf_test_*.log \
        || { echo "expected full_duplex=0 in log header" >&2; return 1; }
}

test_generated_script_falls_back_to_proc_stat_when_mpstat_missing() {
    install_fake_iperf
    # No fake mpstat -> fallback to /proc/stat sampling. We need
    # `command -v mpstat` to fail. Easiest: set FAKE_BIN as the ONLY
    # PATH so mpstat truly isn't found.
    generate_scripts_for src dst
    local script="src"
    local workdir="$TEST_TMPDIR/work-fallback"
    mkdir -p "$workdir"
    cp "$(scripts_dir)/run_${script}_${IPERF_RUN_ID}.sh" "$workdir/run_iperf.sh"
    chmod +x "$workdir/run_iperf.sh"
    # Restricted PATH: only fake bin + system core so coreutils still work
    # but mpstat is unavailable.
    PATH="$FAKE_BIN:/usr/bin:/bin" bash "$workdir/run_iperf.sh" 0 >"$workdir/out" 2>&1
    [ -f "$workdir/cpu_${script}_${IPERF_RUN_ID}.log" ] || {
        echo "expected cpu_${script}_${IPERF_RUN_ID}.log to be created" >&2
        return 1
    }
    grep -q '^# fallback=proc_stat' "$workdir/cpu_${script}_${IPERF_RUN_ID}.log" || {
        echo "fallback marker not present in cpu log" >&2
        head "$workdir/cpu_${script}_${IPERF_RUN_ID}.log" >&2
        return 1
    }
}

test_generated_script_uses_mpstat_when_available() {
    install_fake_iperf
    install_fake_mpstat
    generate_scripts_for src dst
    local script="src"
    run_remote_script "$script" 0
    [ -f "$REMOTE_WORKDIR/cpu_${script}_${IPERF_RUN_ID}.log" ] || {
        echo "expected cpu log file" >&2
        return 1
    }
    # mpstat path produces a "%idle" line; fallback uses fallback marker.
    grep -q "%idle" "$REMOTE_WORKDIR/cpu_${script}_${IPERF_RUN_ID}.log" || {
        echo "expected mpstat output (with %idle) in cpu log" >&2
        return 1
    }
    grep -q '^# fallback=' "$REMOTE_WORKDIR/cpu_${script}_${IPERF_RUN_ID}.log" && {
        echo "should NOT have fallback marker when mpstat is on PATH" >&2
        return 1
    }
    return 0
}

test_generated_script_zero_start_time_no_sleep() {
    install_fake_iperf
    install_fake_mpstat
    generate_scripts_for a b
    local script="a"
    local before after
    before=$(date +%s)
    run_remote_script "$script" 0
    after=$(date +%s)
    local elapsed=$((after - before))
    # Should complete in well under 5s; the sleep window is 0.
    if [ "$elapsed" -gt 5 ]; then
        echo "script ran $elapsed s with START_TIME=0; expected near 0" >&2
        return 1
    fi
}

test_generated_script_single_target_overrides_full_list() {
    install_fake_iperf
    install_fake_mpstat
    generate_scripts_for h0 h1 h2 h3
    # Full mesh: every host has 3 targets, so any host works for the
    # SINGLE_TARGET test.
    local script="h0"
    # Pick a single target that actually appears in this host's TARGETS=.
    local target
    target=$(grep -E '^TARGETS=\(' "$(scripts_dir)/run_${script}_${IPERF_RUN_ID}.sh" \
             | tr ' ' '\n' | grep -oE '"[^"]+"' | head -n1 | tr -d '"')
    [ -n "$target" ] || { echo "could not extract a target from script" >&2; return 1; }

    run_remote_script "$script" 0 "$target"
    # Exactly one iperf_test_*.log should exist (single target).
    local n
    n=$(find "$REMOTE_WORKDIR" -maxdepth 1 -name 'iperf_test_*.log' | wc -l)
    assert_eq "1" "$n" "SINGLE_TARGET should produce exactly one log" || return 1
    [ -f "$REMOTE_WORKDIR/iperf_test_${script}_to_${target}_${IPERF_RUN_ID}.log" ] || {
        echo "expected file iperf_test_${script}_to_${target}_${IPERF_RUN_ID}.log not found" >&2
        ls "$REMOTE_WORKDIR" >&2
        return 1
    }
}

test_generated_script_writes_status_file() {
    install_fake_iperf
    install_fake_mpstat
    generate_scripts_for x y
    local script="x"
    run_remote_script "$script" 0
    [ -f "$REMOTE_WORKDIR/iperf_run_${script}_${IPERF_RUN_ID}.status" ] || {
        echo "missing iperf_run_${script}_${IPERF_RUN_ID}.status" >&2
        return 1
    }
    grep -q "^.*START $script ->" "$REMOTE_WORKDIR/iperf_run_${script}_${IPERF_RUN_ID}.status" || {
        echo "status file missing START line" >&2
        cat "$REMOTE_WORKDIR/iperf_run_${script}_${IPERF_RUN_ID}.status" >&2
        return 1
    }
    grep -q "DONE$" "$REMOTE_WORKDIR/iperf_run_${script}_${IPERF_RUN_ID}.status" || {
        echo "status file missing DONE line" >&2
        return 1
    }
}

run_test test_generated_script_executes_iperf_for_each_target
run_test test_generated_script_writes_pair_header_into_log
run_test test_generated_script_falls_back_to_proc_stat_when_mpstat_missing
run_test test_generated_script_uses_mpstat_when_available
run_test test_generated_script_zero_start_time_no_sleep
run_test test_generated_script_single_target_overrides_full_list
run_test test_generated_script_writes_status_file

report_tests
