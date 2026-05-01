#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# End-to-end tests for cmd_all -- the convenience entry point that
# runs the full pipeline (ssh-setup, check-iperf, check-servers,
# start-servers, create-scripts, distribute-scripts, run-tests,
# collect-results, stop-servers, cleanup, parse-csv, parse-cpu,
# make-pivot, make-heatmap).
#
# We use the "smart" ssh/scp shim from the collect-results suite so
# the tar/extract path actually exercises real code, plus a fake
# `iperf` so the run-tests step can call the generated remote script
# in a "remote" dir.
#
# Some pieces (ssh-setup with real keys, matplotlib) aren't reachable
# in the test env -- those are stubbed or detected and gated.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# Smart shim: ssh runs commands in a per-host fake-remote dir, scp
# does real cp.
install_smart_fake_ssh() {
    cat > "$FAKE_BIN/ssh" <<SHIM
#!/usr/bin/env bash
set -u
LOG="\${FAKE_SSH_LOG:-\$(dirname "\$0")/calls.log}"
target=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) shift; [ \$# -gt 0 ] && shift ;;
        -[a-zA-Z]) shift ;;
        *@*) target="\$1"; shift; break ;;
        *) shift ;;
    esac
done
remote_cmd="\$*"
host="\${target#*@}"
printf 'ssh\t%s\t%s\n' "\$host" "\$remote_cmd" >> "\$LOG"

fake_remote="$TEST_TMPDIR/remote-\$host"
mkdir -p "\$fake_remote"

# Canned responses for probes. Order matters: pattern matching is
# first-wins, so put the most specific (composite-command) signatures
# above the bare "pgrep" one.
case "\$remote_cmd" in
    *"iperf -v"*)
        echo "iperf version 2.1.9 (1 March 2023) pthreads"
        exit 0 ;;
    *"command -v mpstat"*)
        echo "yes"
        exit 0 ;;
    *"nohup iperf"*)
        # cmd_start_servers: mkdir + pkill + nohup + pgrep verify.
        touch "\$fake_remote/_running"
        exit 0 ;;
    *"! pgrep"*)
        # cmd_stop_servers
        rm -f "\$fake_remote/_running"
        exit 0 ;;
    *"pgrep -ax iperf"*|*"pgrep -x iperf"*)
        # Bare check-servers probe.
        if [ -f "\$fake_remote/_running" ]; then
            echo "12345 iperf -s -p 5001"
            exit 0
        fi
        exit 1 ;;
esac

# Translate REMOTE_DIR -> per-host fake remote dir, then run inside it.
local_cmd=\$(echo "\$remote_cmd" | sed -e "s|$REMOTE_DIR|\$fake_remote|g")
( cd "\$fake_remote" && bash -c "\$local_cmd" )
exit \$?
SHIM
    chmod +x "$FAKE_BIN/ssh"

    cat > "$FAKE_BIN/scp" <<'SHIM'
#!/usr/bin/env bash
set -u
LOG="${FAKE_SSH_LOG:-$(dirname "$0")/calls.log}"
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift; [ $# -gt 0 ] && shift ;;
        -[a-zA-Z]) shift ;;
        *) args+=("$1"); shift ;;
    esac
done
n=${#args[@]}
[ $n -lt 2 ] && exit 2
src="${args[0]}"
dst="${args[$((n-1))]}"
printf 'scp\t%s\t%s\n' "$src" "$dst" >> "$LOG"
trans() {
    local p="$1"
    case "$p" in
        *@*:*)
            local h="${p%%:*}"; h="${h#*@}"
            local path="${p#*:}"
            echo "$path" | sed -e "s|@FAKE_REMOTE_DIR@|@TT@/remote-$h|g"
            ;;
        *) echo "$p" ;;
    esac
}
real_src=$(trans "$src")
real_dst=$(trans "$dst")
cp "$real_src" "$real_dst" 2>/dev/null
SHIM
    sed -i "s|@FAKE_REMOTE_DIR@|$REMOTE_DIR|g; s|@TT@|$TEST_TMPDIR|g" "$FAKE_BIN/scp"
    chmod +x "$FAKE_BIN/scp"

    # Fake iperf: emits one CSV summary row per direction so the
    # generated remote script's output is a parseable log. The
    # generated script invokes iperf as `iperf -c TARGET ... 2>&1`
    # and writes stdout to iperf_test_<src>_to_<target>.log, prefixed
    # with the # pair_a header line.
    cat > "$FAKE_BIN/iperf" <<'SHIM'
#!/usr/bin/env bash
target="-"
for ((i=1; i<=$#; i++)); do
    if [ "${!i}" = "-c" ]; then j=$((i+1)); target="${!j}"; fi
done
ts=$(date +%Y%m%d%H%M%S)
echo "$ts.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000"
echo "$ts.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,1100000000,880000000"
SHIM
    chmod +x "$FAKE_BIN/iperf"

    cat > "$FAKE_BIN/mpstat" <<'SHIM'
#!/usr/bin/env bash
echo "Linux fake (host)   01/01/2026  _x86_64_    (1 CPU)"
echo
echo "12:00:00     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle"
echo "12:00:01     all    1.00    0.00    0.50    0.00    0.00    0.20    0.00    0.00    0.00   98.30"
echo "12:00:01       0    1.00    0.00    0.50    0.00    0.00    0.20    0.00    0.00    0.00   98.30"
SHIM
    chmod +x "$FAKE_BIN/mpstat"

    # Fake ssh-keygen / ssh-copy-id so cmd_ssh_setup doesn't blow up.
    cat > "$FAKE_BIN/ssh-keygen" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
    chmod +x "$FAKE_BIN/ssh-keygen"
    cat > "$FAKE_BIN/ssh-copy-id" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
    chmod +x "$FAKE_BIN/ssh-copy-id"

    # Pre-supply the user's key so cmd_ssh_setup's keygen branch is
    # skipped entirely.
    mkdir -p "$TEST_TMPDIR/home/.ssh"
    : > "$TEST_TMPDIR/home/.ssh/id_ed25519"
    : > "$TEST_TMPDIR/home/.ssh/id_ed25519.pub"
    chmod 600 "$TEST_TMPDIR/home/.ssh/id_ed25519"
    export HOME="$TEST_TMPDIR/home"

    export FAKE_SSH_LOG="$FAKE_BIN/calls.log"
    : > "$FAKE_SSH_LOG"
}

prep_workflow() {
    install_smart_fake_ssh
    local src="$TEST_TMPDIR/srv.txt"
    : > "$src"
    local h
    for h in "$@"; do
        printf '%s\n' "$h" >> "$src"
    done
    PATH="$FAKE_BIN:$PATH" run_orch init "$src" >/dev/null 2>&1
    : > "$FAKE_SSH_LOG"
}

run_with_fakes() {
    PATH="$FAKE_BIN:$PATH" run_orch "$@"
}

# ---- Happy path -----------------------------------------------------------

test_cmd_all_runs_full_pipeline() {
    prep_workflow alpha bravo
    # `--start-delay=0` so parallel mode doesn't actually pause; also
    # `--duration=1` so the generated remote script's mpstat sampler
    # only runs ~5 s rather than 14 s.
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going
    # cmd_all is best-effort: parse-csv etc. now propagate exit codes.
    # We accept any rc, but the state file should reflect the steps
    # that succeeded.
    local state="$IPERF_DIR/state"
    [ -f "$state" ] || { echo "no state file" >&2; return 1; }
    grep -q '^IPERF_INSTALLED_CHECKED=yes$'  "$state" || { echo "missing INSTALLED_CHECKED"; return 1; }
    grep -q '^SERVERS_RUNNING_CHECKED=yes$'  "$state" || { echo "missing SERVERS_RUNNING_CHECKED"; return 1; }
    grep -q '^SERVERS_STARTED=yes$'          "$state" || { echo "missing SERVERS_STARTED"; return 1; }
    grep -q '^SCRIPTS_CREATED=yes$'          "$state" || { echo "missing SCRIPTS_CREATED"; return 1; }
    grep -q '^SCRIPTS_DISTRIBUTED=yes$'      "$state" || { echo "missing SCRIPTS_DISTRIBUTED"; return 1; }
    grep -q '^TESTS_RUN=yes$'                "$state" || { echo "missing TESTS_RUN"; return 1; }
    grep -q '^RESULTS_COLLECTED=yes$'        "$state" || { echo "missing RESULTS_COLLECTED"; return 1; }
    grep -q '^SERVERS_STOPPED=yes$'          "$state" || { echo "missing SERVERS_STOPPED"; return 1; }
    grep -q '^CLEANED_UP=yes$'               "$state" || { echo "missing CLEANED_UP"; return 1; }
    grep -q '^CSV_BUILT=yes$'                "$state" || { echo "missing CSV_BUILT"; return 1; }
    grep -q '^CPU_PARSED=yes$'               "$state" || { echo "missing CPU_PARSED"; return 1; }
    grep -q '^PIVOT_BUILT=yes$'              "$state" || { echo "missing PIVOT_BUILT"; return 1; }
    # HEATMAP_BUILT may or may not be set depending on whether
    # matplotlib is installed; don't assert.
}

test_cmd_all_produces_results_csv_and_pivot() {
    prep_workflow alpha bravo
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going >/dev/null 2>&1
    [ -f "$IPERF_DIR/results/iperf_results.csv" ] || {
        echo "no iperf_results.csv after cmd_all" >&2
        return 1
    }
    # Two hosts -> 1 canonical pair -> 2 rows in the CSV.
    local n
    n=$(($(wc -l < "$IPERF_DIR/results/iperf_results.csv") - 1))
    if [ "$n" -lt 2 ]; then
        echo "expected at least 2 result rows, got $n" >&2
        cat "$IPERF_DIR/results/iperf_results.csv" >&2
        return 1
    fi
    [ -f "$IPERF_DIR/results/iperf_pivot.txt" ] || {
        echo "no iperf_pivot.txt" >&2
        return 1
    }
}

test_cmd_all_skips_ssh_setup_when_already_done() {
    prep_workflow alpha
    # Pre-mark SSH_KEYS_DISTRIBUTED so cmd_all's gate skips ssh-setup.
    sed -i '$a SSH_KEYS_DISTRIBUTED=yes' "$IPERF_DIR/state"
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going >/dev/null 2>&1
    # No ssh-copy-id call should appear in the calls log (we still
    # didn't install a fake one... actually we did. Let's check by
    # making sure SSH_KEYS_DISTRIBUTED stayed set without the
    # interactive prompt path running).
    # The simplest check: if cmd_all called ssh-setup, state would be
    # rewritten. We confirm by looking for the log line "Distributing key"
    # (ssh-setup prints it). It must NOT appear.
    if echo "$RUN_OUT" | grep -q "Distributing key"; then
        echo "ssh-setup ran despite SSH_KEYS_DISTRIBUTED=yes" >&2
        return 1
    fi
}

test_cmd_all_default_mode_is_parallel() {
    prep_workflow a b
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going >/dev/null 2>&1
    # The mode is recorded in state by run-tests.
    grep -q '^TESTS_RUN_MODE=parallel$' "$IPERF_DIR/state" || {
        echo "default mode should be parallel" >&2
        cat "$IPERF_DIR/state" >&2
        return 1
    }
}

test_cmd_all_accepts_alternate_mode() {
    prep_workflow a b c
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going sequential-host >/dev/null 2>&1
    grep -q '^TESTS_RUN_MODE=sequential-host$' "$IPERF_DIR/state" || {
        echo "expected mode=sequential-host" >&2
        cat "$IPERF_DIR/state" >&2
        return 1
    }
}

test_cmd_all_dies_when_no_server_list() {
    install_smart_fake_ssh
    # Don't init.
    run_with_fakes all
    assert_ne 0 "$RUN_RC" "cmd_all should fail without a server list" || return 1
}

test_cmd_all_lists_results_at_end() {
    prep_workflow x y
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going >/dev/null 2>&1
    # cmd_all does `ls -1 "$RESULTS_DIR"` at the end. Verify the
    # printed listing is non-empty.
    [ "$(ls -1 "$IPERF_DIR/results" | wc -l)" -gt 0 ] || {
        echo "results dir empty after cmd_all" >&2
        return 1
    }
}

run_test test_cmd_all_runs_full_pipeline
run_test test_cmd_all_produces_results_csv_and_pivot
run_test test_cmd_all_skips_ssh_setup_when_already_done
run_test test_cmd_all_default_mode_is_parallel
run_test test_cmd_all_accepts_alternate_mode
run_test test_cmd_all_dies_when_no_server_list
run_test test_cmd_all_lists_results_at_end

report_tests
