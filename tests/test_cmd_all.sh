#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# End-to-end tests for cmd_all -- the convenience entry point that
# runs the full pipeline (check-iperf, check-servers,
# start-servers, create-scripts, distribute-scripts, run-tests,
# collect-results, stop-servers, cleanup, parse-csv, parse-cpu,
# make-pivot, make-heatmap).
#
# Stateless mode: rather than checking state-file flags, we verify the
# expected output artifacts ended up in the active run directory.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

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

case "\$remote_cmd" in
    *"iperf -v"*)
        echo "iperf version 2.1.9 (1 March 2023) pthreads"
        exit 0 ;;
    *"command -v mpstat"*)
        echo "yes"
        exit 0 ;;
    *"iperf -s -D"*)
        touch "\$fake_remote/_running"
        exit 0 ;;
    *"! pgrep"*)
        rm -f "\$fake_remote/_running"
        exit 0 ;;
    *"pgrep -ax iperf"*|*"pgrep -x iperf"*)
        if [ -f "\$fake_remote/_running" ]; then
            echo "12345 iperf -s -p 5001"
            exit 0
        fi
        exit 1 ;;
esac

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
    write_server_list "$@" >/dev/null
    : > "$FAKE_SSH_LOG"
}

run_with_fakes() {
    PATH="$FAKE_BIN:$PATH" run_orch "$@"
}

run_dir() { echo "$RESULTS_BASE/$IPERF_RUN_ID"; }

# ---- Happy path -----------------------------------------------------------

test_cmd_all_runs_full_pipeline() {
    prep_workflow alpha bravo
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going
    local rd; rd=$(run_dir)
    [ -d "$rd" ] || { echo "no run dir" >&2; return 1; }
    # check-iperf and check-servers print to stdout (no files); verify
    # the rest of the pipeline left its artifacts.
    assert_contains "$RUN_OUT" "INSTALLED" "check-iperf should report INSTALLED" || return 1
    find "$rd/scripts" -name 'run_*.sh' | grep -q . || { echo "missing generated scripts"; return 1; }
    find "$rd/logs" -name 'run_*.log' | grep -q . || { echo "missing per-host logs"; return 1; }
    [ -f "$rd/iperf_results.csv" ]   || { echo "missing iperf_results.csv"; return 1; }
    [ -f "$rd/cpu_summary.csv" ]     || { echo "missing cpu_summary.csv"; return 1; }
    [ -f "$rd/iperf_pivot.txt" ]     || { echo "missing iperf_pivot.txt"; return 1; }
    [ -f "$rd/.run_mode" ]           || { echo "missing .run_mode marker"; return 1; }
}

test_cmd_all_produces_results_csv_and_pivot() {
    prep_workflow alpha bravo
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going >/dev/null 2>&1
    local rd; rd=$(run_dir)
    [ -f "$rd/iperf_results.csv" ] || {
        echo "no iperf_results.csv after cmd_all" >&2
        return 1
    }
    local n
    n=$(($(wc -l < "$rd/iperf_results.csv") - 1))
    if [ "$n" -lt 2 ]; then
        echo "expected at least 2 result rows, got $n" >&2
        cat "$rd/iperf_results.csv" >&2
        return 1
    fi
    [ -f "$rd/iperf_pivot.txt" ] || {
        echo "no iperf_pivot.txt" >&2
        return 1
    }
}

test_cmd_all_default_mode_is_parallel() {
    prep_workflow a b
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going >/dev/null 2>&1
    local rd; rd=$(run_dir)
    [ "$(cat "$rd/.run_mode")" = "parallel" ] || {
        echo "default mode should be parallel" >&2
        cat "$rd/.run_mode" >&2
        return 1
    }
}

test_cmd_all_accepts_alternate_mode() {
    prep_workflow a b c
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going sequential-host >/dev/null 2>&1
    local rd; rd=$(run_dir)
    [ "$(cat "$rd/.run_mode")" = "sequential-host" ] || {
        echo "expected mode=sequential-host" >&2
        cat "$rd/.run_mode" >&2
        return 1
    }
}

test_cmd_all_dies_when_no_server_list() {
    install_smart_fake_ssh
    unset IPERF_SERVERS
    PATH="$FAKE_BIN:$PATH" run_orch --servers /nope.txt all
    assert_ne 0 "$RUN_RC" "cmd_all should fail without a server list" || return 1
}

test_cmd_all_lists_results_at_end() {
    prep_workflow x y
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going >/dev/null 2>&1
    local rd; rd=$(run_dir)
    [ "$(ls -1 "$rd" | wc -l)" -gt 0 ] || {
        echo "results dir empty after cmd_all" >&2
        return 1
    }
}

test_cmd_all_prints_pivot_table_at_end() {
    prep_workflow alpha bravo
    run_with_fakes --start-delay=0 --duration=1 -- all --keep-going
    assert_contains "$RUN_OUT" "iperf2 full-mesh throughput" \
        "cmd_all should cat the pivot table to stdout after the pipeline completes" \
        || return 1
}

run_test test_cmd_all_runs_full_pipeline
run_test test_cmd_all_produces_results_csv_and_pivot
run_test test_cmd_all_default_mode_is_parallel
run_test test_cmd_all_accepts_alternate_mode
run_test test_cmd_all_dies_when_no_server_list
run_test test_cmd_all_lists_results_at_end
run_test test_cmd_all_prints_pivot_table_at_end

report_tests
