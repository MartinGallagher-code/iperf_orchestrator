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
    local src="$TEST_TMPDIR/srv.txt"
    : > "$src"
    local h
    for h in "${hosts[@]}"; do
        printf '%s\n' "$h" >> "$src"
    done
    run_orch init "$src" >/dev/null 2>&1
    # Use --duration=1 so generated scripts run for ~5s each rather
    # than the 14s default; the sampler runs DURATION+4 seconds.
    run_orch --duration=1 create-scripts >/dev/null 2>&1
}

# Run the generated script for $host in a working dir, with $FAKE_BIN
# (which has fake iperf etc.) on PATH.
run_remote_script() {
    local host="$1"; shift
    local script="$IPERF_DIR/scripts/run_${host}.sh"
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
    # Determine which host has clients (depends on parity rule).
    local script
    for h in src target1 target2; do
        if grep -E '^TARGETS=\( "[^"]+"' "$IPERF_DIR/scripts/run_$h.sh" >/dev/null; then
            script="$h"; break
        fi
    done
    [ -n "$script" ] || { echo "no host got any targets" >&2; return 1; }

    run_remote_script "$script" 0
    assert_status 0 "$?" "remote script should exit 0" || return 1
    # iperf was invoked at least once with -c <target>
    if ! grep -q -- '-c ' "$FAKE_BIN/iperf_calls.log"; then
        echo "expected at least one iperf -c invocation" >&2
        cat "$FAKE_BIN/iperf_calls.log" >&2
        return 1
    fi
    # iperf invoked with --full-duplex
    grep -q -- '--full-duplex' "$FAKE_BIN/iperf_calls.log" || {
        echo "expected --full-duplex in iperf args" >&2
        return 1
    }
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
    grep -E '^TARGETS=\( "[^"]+"' "$IPERF_DIR/scripts/run_src.sh" >/dev/null \
        || script="dst"
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
}

test_generated_script_falls_back_to_proc_stat_when_mpstat_missing() {
    install_fake_iperf
    # No fake mpstat -> fallback to /proc/stat sampling. We need
    # `command -v mpstat` to fail. Easiest: set FAKE_BIN as the ONLY
    # PATH so mpstat truly isn't found.
    generate_scripts_for src dst
    local script="src"
    grep -E '^TARGETS=\( "[^"]+"' "$IPERF_DIR/scripts/run_src.sh" >/dev/null \
        || script="dst"
    local workdir="$TEST_TMPDIR/work-fallback"
    mkdir -p "$workdir"
    cp "$IPERF_DIR/scripts/run_$script.sh" "$workdir/run_iperf.sh"
    chmod +x "$workdir/run_iperf.sh"
    # Restricted PATH: only fake bin + system core so coreutils still work
    # but mpstat is unavailable.
    PATH="$FAKE_BIN:/usr/bin:/bin" bash "$workdir/run_iperf.sh" 0 >"$workdir/out" 2>&1
    [ -f "$workdir/cpu_$script.log" ] || {
        echo "expected cpu_$script.log to be created" >&2
        return 1
    }
    grep -q '^# fallback=proc_stat' "$workdir/cpu_$script.log" || {
        echo "fallback marker not present in cpu log" >&2
        head "$workdir/cpu_$script.log" >&2
        return 1
    }
}

test_generated_script_uses_mpstat_when_available() {
    install_fake_iperf
    install_fake_mpstat
    generate_scripts_for src dst
    local script="src"
    grep -E '^TARGETS=\( "[^"]+"' "$IPERF_DIR/scripts/run_src.sh" >/dev/null \
        || script="dst"
    run_remote_script "$script" 0
    [ -f "$REMOTE_WORKDIR/cpu_$script.log" ] || {
        echo "expected cpu log file" >&2
        return 1
    }
    # mpstat path produces a "%idle" line; fallback uses fallback marker.
    grep -q "%idle" "$REMOTE_WORKDIR/cpu_$script.log" || {
        echo "expected mpstat output (with %idle) in cpu log" >&2
        return 1
    }
    grep -q '^# fallback=' "$REMOTE_WORKDIR/cpu_$script.log" && {
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
    grep -E '^TARGETS=\( "[^"]+"' "$IPERF_DIR/scripts/run_a.sh" >/dev/null || script="b"
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
    # Pick a script that has multiple targets; sequential-pair would
    # call it with SINGLE_TARGET and only one log should result.
    local script
    for h in h0 h1 h2 h3; do
        local n
        n=$(grep -E '^TARGETS=\(' "$IPERF_DIR/scripts/run_$h.sh" \
            | tr ' ' '\n' | grep -c '"')
        if [ "$n" -ge 4 ]; then  # at least 2 targets (4 quote chars)
            script="$h"; break
        fi
    done
    if [ -z "${script:-}" ]; then
        echo "    SKIP: no host with >=2 targets in this layout"
        return 0
    fi
    # Pick a single target that actually appears in this host's TARGETS=.
    local target
    target=$(grep -E '^TARGETS=\(' "$IPERF_DIR/scripts/run_$script.sh" \
             | tr ' ' '\n' | grep -oE '"[^"]+"' | head -n1 | tr -d '"')
    [ -n "$target" ] || { echo "could not extract a target from script" >&2; return 1; }

    run_remote_script "$script" 0 "$target"
    # Exactly one iperf_test_*.log should exist (single target).
    local n
    n=$(find "$REMOTE_WORKDIR" -maxdepth 1 -name 'iperf_test_*.log' | wc -l)
    assert_eq "1" "$n" "SINGLE_TARGET should produce exactly one log" || return 1
    [ -f "$REMOTE_WORKDIR/iperf_test_${script}_to_${target}.log" ] || {
        echo "expected file iperf_test_${script}_to_${target}.log not found" >&2
        ls "$REMOTE_WORKDIR" >&2
        return 1
    }
}

test_generated_script_writes_status_file() {
    install_fake_iperf
    install_fake_mpstat
    generate_scripts_for x y
    local script="x"
    grep -E '^TARGETS=\( "[^"]+"' "$IPERF_DIR/scripts/run_x.sh" >/dev/null || script="y"
    run_remote_script "$script" 0
    [ -f "$REMOTE_WORKDIR/iperf_run_$script.status" ] || {
        echo "missing iperf_run_$script.status" >&2
        return 1
    }
    grep -q "^.*START $script ->" "$REMOTE_WORKDIR/iperf_run_$script.status" || {
        echo "status file missing START line" >&2
        cat "$REMOTE_WORKDIR/iperf_run_$script.status" >&2
        return 1
    }
    grep -q "DONE$" "$REMOTE_WORKDIR/iperf_run_$script.status" || {
        echo "status file missing DONE line" >&2
        return 1
    }
}

test_generated_script_lone_host_writes_only_cpu_and_status() {
    # If a host has zero targets (parity rule edge case), no iperf
    # test logs are created -- only the CPU log + status file.
    install_fake_iperf
    install_fake_mpstat
    generate_scripts_for solo other
    # The lone first host has zero clients in N=2 because parity rule
    # gives the larger index the client role.
    local script
    for h in solo other; do
        if grep -qE '^TARGETS=\([[:space:]]*\)' "$IPERF_DIR/scripts/run_$h.sh"; then
            script="$h"; break
        fi
    done
    if [ -z "${script:-}" ]; then
        echo "    SKIP: no host with zero targets in this layout"
        return 0
    fi
    run_remote_script "$script" 0
    local n
    n=$(find "$REMOTE_WORKDIR" -maxdepth 1 -name 'iperf_test_*.log' | wc -l)
    assert_eq "0" "$n" "client-less host should not create test logs" || return 1
    [ -f "$REMOTE_WORKDIR/iperf_run_$script.status" ] || return 1
    [ -f "$REMOTE_WORKDIR/cpu_$script.log" ] || return 1
}

run_test test_generated_script_executes_iperf_for_each_target
run_test test_generated_script_writes_pair_header_into_log
run_test test_generated_script_falls_back_to_proc_stat_when_mpstat_missing
run_test test_generated_script_uses_mpstat_when_available
run_test test_generated_script_zero_start_time_no_sleep
run_test test_generated_script_single_target_overrides_full_list
run_test test_generated_script_writes_status_file
run_test test_generated_script_lone_host_writes_only_cpu_and_status

report_tests
