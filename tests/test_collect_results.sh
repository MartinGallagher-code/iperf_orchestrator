#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for cmd_collect_results. The worker builds a tarball on the
# remote, scp-pulls it, and extracts into RESULTS_DIR. We use a
# smarter ssh/scp shim that actually runs the remote commands inside
# a per-host "fake remote" directory, so we exercise the real tar +
# extract path locally.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# The collect-results worker dispatches a multi-line ssh command.
# Our smarter shim recognises that pattern and runs the command
# locally inside $TEST_TMPDIR/remote-<host>/ so the tar archive
# really gets built. The scp shim copies the tarball back into
# RESULTS_DIR with a real cp. Together that gives an end-to-end
# happy-path exercise.
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

# Per-host pseudo-remote dir (mirrors what the orchestrator's
# REMOTE_DIR points at on a real machine).
fake_remote="$TEST_TMPDIR/remote-\$host"
mkdir -p "\$fake_remote"

# Translate REMOTE_DIR references in the remote command to the local
# fake-remote dir, then run the command there. This is brittle but
# enough to exercise the orchestrator's tar/list/extract logic for
# tests.
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
# Strip user@host: prefix if present (we map remote paths to local
# using the same TEST_TMPDIR/remote-<host>/ scheme as the ssh shim).
trans() {
    local p="$1"
    case "$p" in
        *@*:*)
            local host="${p%%:*}"; host="${host#*@}"
            local path="${p#*:}"
            echo "$path" | sed -e "s|@FAKE_REMOTE_DIR@|$TEST_TMPDIR/remote-$host|g"
            ;;
        *) echo "$p" ;;
    esac
}
real_src=$(trans "$src")
real_dst=$(trans "$dst")
cp "$real_src" "$real_dst" 2>/dev/null
SHIM
    # Patch the placeholder so the scp shim does the same path
    # translation that the ssh shim does.
    sed -i "s|@FAKE_REMOTE_DIR@|$REMOTE_DIR|g" "$FAKE_BIN/scp"
    chmod +x "$FAKE_BIN/scp"

    export FAKE_SSH_LOG="$FAKE_BIN/calls.log"
    : > "$FAKE_SSH_LOG"
}

# Pre-populate a per-host fake-remote directory with realistic logs.
seed_host_logs() {
    local host="$1"
    local d="$TEST_TMPDIR/remote-$host"
    mkdir -p "$d"
    # An iperf_test_* log per (host, peer) pair where this host has
    # client work. We simplify and just drop one per host.
    cat > "$d/iperf_test_${host}_to_peer.log" <<EOF
# pair_a=$host pair_b=peer duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,1100000000,880000000
EOF
    : > "$d/iperf_server.log"
    : > "$d/iperf_run_${host}.status"
    : > "$d/cpu_${host}.log"
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
    for h in "$@"; do
        seed_host_logs "$h"
    done
    : > "$FAKE_SSH_LOG"
}

run_with_fakes() {
    PATH="$FAKE_BIN:$PATH" run_orch "$@"
}

# ---- Happy path -----------------------------------------------------------

test_collect_results_pulls_per_host_logs() {
    prep_workflow alpha bravo charlie
    run_with_fakes collect-results
    assert_status 0 "$RUN_RC" || return 1
    grep -q '^RESULTS_COLLECTED=yes$' "$IPERF_DIR/state" || {
        echo "RESULTS_COLLECTED not flagged" >&2
        return 1
    }
    # We seeded one iperf_test_* log per host; expect 3 in results.
    local n
    n=$(find "$IPERF_DIR/results" -name 'iperf_test_*.log' | wc -l)
    assert_eq "3" "$n" "should pull one client log per host" || return 1
}

test_collect_results_pulls_renamed_server_logs() {
    prep_workflow a b
    run_with_fakes collect-results >/dev/null
    # Server log gets renamed to iperf_server_<host>.log to avoid
    # collisions on extract.
    [ -f "$IPERF_DIR/results/iperf_server_a.log" ] || {
        echo "missing iperf_server_a.log" >&2; return 1; }
    [ -f "$IPERF_DIR/results/iperf_server_b.log" ] || {
        echo "missing iperf_server_b.log" >&2; return 1; }
}

test_collect_results_pulls_status_and_cpu() {
    prep_workflow a b
    run_with_fakes collect-results >/dev/null
    [ -f "$IPERF_DIR/results/iperf_run_a.status" ] || return 1
    [ -f "$IPERF_DIR/results/iperf_run_b.status" ] || return 1
    [ -f "$IPERF_DIR/results/cpu_a.log" ] || return 1
    [ -f "$IPERF_DIR/results/cpu_b.log" ] || return 1
}

test_collect_results_cleans_up_remote_tarball() {
    prep_workflow alpha
    run_with_fakes collect-results >/dev/null
    # The worker should rm -f the remote tarball after extraction.
    if find "$TEST_TMPDIR/remote-alpha" -name '_results_*.tar.gz' | grep -q .; then
        echo "remote tarball was not cleaned up" >&2
        ls "$TEST_TMPDIR/remote-alpha" >&2
        return 1
    fi
}

test_collect_results_cleans_up_local_tarball() {
    prep_workflow alpha bravo
    run_with_fakes collect-results >/dev/null
    if find "$IPERF_DIR/results" -name '_results_*.tar.gz' | grep -q .; then
        echo "local tarball was not cleaned up" >&2
        return 1
    fi
}

test_collect_results_dies_when_no_server_list() {
    install_smart_fake_ssh
    run_with_fakes collect-results
    assert_ne 0 "$RUN_RC" "should fail without server list" || return 1
}

test_collect_results_handles_empty_remote_dir() {
    # Some hosts (the parity-rule "loser") have no client logs. The
    # worker must NOT count this as a failure -- it's normal.
    prep_workflow lone
    # Wipe the seeded logs to simulate an empty REMOTE_DIR.
    rm -f "$TEST_TMPDIR/remote-lone"/*
    : > "$FAKE_SSH_LOG"
    run_with_fakes collect-results
    # Empty is a "warning, not failure" path -- worker returns 0,
    # no PARALLEL_FAILED entries. State flag should still be set
    # since no host actually FAILED.
    assert_status 0 "$RUN_RC" || return 1
    grep -q '^RESULTS_COLLECTED=yes$' "$IPERF_DIR/state" || return 1
    assert_contains "$RUN_OUT" "nothing to collect" || return 1
}

test_collect_results_writes_to_results_dir_path() {
    prep_workflow a b
    run_with_fakes collect-results >/dev/null
    # Non-empty results directory.
    [ "$(ls "$IPERF_DIR/results" | wc -l)" -gt 0 ] || {
        echo "results dir empty after collect" >&2
        return 1
    }
}

run_test test_collect_results_pulls_per_host_logs
run_test test_collect_results_pulls_renamed_server_logs
run_test test_collect_results_pulls_status_and_cpu
run_test test_collect_results_cleans_up_remote_tarball
run_test test_collect_results_cleans_up_local_tarball
run_test test_collect_results_dies_when_no_server_list
run_test test_collect_results_handles_empty_remote_dir
run_test test_collect_results_writes_to_results_dir_path

report_tests
