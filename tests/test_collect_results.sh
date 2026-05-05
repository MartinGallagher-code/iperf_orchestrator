#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for cmd_collect_results. The worker builds a tarball on the
# remote, scp-pulls it, and extracts into RESULTS_DIR. We use a smart
# ssh/scp shim that runs commands inside per-host pseudo-remote dirs.
#
# All filenames now embed both <host> and <run-id> so $REMOTE_DIR can
# safely live on a shared FS.

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
    sed -i "s|@FAKE_REMOTE_DIR@|$REMOTE_DIR|g" "$FAKE_BIN/scp"
    chmod +x "$FAKE_BIN/scp"

    export FAKE_SSH_LOG="$FAKE_BIN/calls.log"
    : > "$FAKE_SSH_LOG"
}

# Pre-populate a per-host fake-remote directory with realistic logs.
# Filenames must embed <host>_<run-id> -- the worker only globs files
# matching the active RUN_ID.
seed_host_logs() {
    local host="$1"
    local d="$TEST_TMPDIR/remote-$host"
    mkdir -p "$d"
    cat > "$d/iperf_test_${host}_to_peer_${IPERF_RUN_ID}.log" <<EOF
# pair_a=$host pair_b=peer duration=10 port=5001 parallel=1 test_start=1700000000
20260101120000.000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000
20260101120000.000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.0,1100000000,880000000
EOF
    : > "$d/iperf_server_${host}_${IPERF_RUN_ID}.log"
    : > "$d/iperf_run_${host}_${IPERF_RUN_ID}.status"
    : > "$d/cpu_${host}_${IPERF_RUN_ID}.log"
}

prep_workflow() {
    install_smart_fake_ssh
    write_server_list "$@" >/dev/null
    # collect-results needs a results dir already present.
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    for h in "$@"; do
        seed_host_logs "$h"
    done
    : > "$FAKE_SSH_LOG"
}

run_with_fakes() {
    PATH="$FAKE_BIN:$PATH" run_orch "$@"
}

results_dir() { echo "$RESULTS_BASE/$IPERF_RUN_ID"; }

# ---- Happy path -----------------------------------------------------------

test_collect_results_pulls_per_host_logs() {
    prep_workflow alpha bravo charlie
    run_with_fakes collect-results
    assert_status 0 "$RUN_RC" || return 1
    local n
    n=$(find "$(results_dir)" -name "iperf_test_*_${IPERF_RUN_ID}.log" | wc -l)
    assert_eq "3" "$n" "should pull one client log per host" || return 1
}

test_collect_results_pulls_renamed_server_logs() {
    prep_workflow a b
    run_with_fakes collect-results >/dev/null
    [ -f "$(results_dir)/iperf_server_a_${IPERF_RUN_ID}.log" ] || {
        echo "missing iperf_server_a_${IPERF_RUN_ID}.log" >&2; return 1; }
    [ -f "$(results_dir)/iperf_server_b_${IPERF_RUN_ID}.log" ] || {
        echo "missing iperf_server_b_${IPERF_RUN_ID}.log" >&2; return 1; }
}

test_collect_results_pulls_status_and_cpu() {
    prep_workflow a b
    run_with_fakes collect-results >/dev/null
    [ -f "$(results_dir)/iperf_run_a_${IPERF_RUN_ID}.status" ] || return 1
    [ -f "$(results_dir)/iperf_run_b_${IPERF_RUN_ID}.status" ] || return 1
    [ -f "$(results_dir)/cpu_a_${IPERF_RUN_ID}.log" ] || return 1
    [ -f "$(results_dir)/cpu_b_${IPERF_RUN_ID}.log" ] || return 1
}

test_collect_results_cleans_up_remote_tarball() {
    prep_workflow alpha
    run_with_fakes collect-results >/dev/null
    if find "$TEST_TMPDIR/remote-alpha" -name '_results_*.tar.gz' | grep -q .; then
        echo "remote tarball was not cleaned up" >&2
        ls "$TEST_TMPDIR/remote-alpha" >&2
        return 1
    fi
}

test_collect_results_cleans_up_local_tarball() {
    prep_workflow alpha bravo
    run_with_fakes collect-results >/dev/null
    if find "$(results_dir)" -name '_results_*.tar.gz' | grep -q .; then
        echo "local tarball was not cleaned up" >&2
        return 1
    fi
}

test_collect_results_dies_when_no_server_list() {
    install_smart_fake_ssh
    unset IPERF_SERVERS
    PATH="$FAKE_BIN:$PATH" run_orch --servers /nope.txt collect-results
    assert_ne 0 "$RUN_RC" "should fail without server list" || return 1
}

test_collect_results_handles_empty_remote_dir() {
    prep_workflow lone
    rm -f "$TEST_TMPDIR/remote-lone"/*
    : > "$FAKE_SSH_LOG"
    run_with_fakes collect-results
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "nothing to collect" || return 1
}

test_collect_results_uses_sanitized_hostname_in_tarball() {
    # Bracketed IPv6 hostname -> tarball uses sanitized name. The
    # pseudo-remote dir is keyed on the unsanitized hostname (matching
    # how the orchestrator addresses the host), but the files inside
    # use the sanitized form.
    install_smart_fake_ssh
    write_server_list '[fe80::1]' >/dev/null
    mkdir -p "$RESULTS_BASE/$IPERF_RUN_ID"
    local d="$TEST_TMPDIR/remote-[fe80::1]"
    mkdir -p "$d"
    : > "$d/iperf_server__fe80__1__${IPERF_RUN_ID}.log"
    : > "$d/iperf_run__fe80__1__${IPERF_RUN_ID}.status"
    : > "$d/cpu__fe80__1__${IPERF_RUN_ID}.log"
    : > "$FAKE_SSH_LOG"
    run_with_fakes collect-results >/dev/null
    grep -E "^scp" "$FAKE_SSH_LOG" \
        | awk -F'\t' '{print $2}' \
        | grep -qE "_results__fe80__1__${IPERF_RUN_ID}\.tar\.gz" || {
            echo "expected sanitized tarball name in scp src" >&2
            cat "$FAKE_SSH_LOG" >&2
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
run_test test_collect_results_uses_sanitized_hostname_in_tarball

report_tests
