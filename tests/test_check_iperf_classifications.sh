#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for cmd_check_iperf's classification logic. The worker probes
# `iperf -v` and grep's the output for "iperf version 2". Possible
# outcomes:
#   INSTALLED      - matches "iperf version 2"
#   WRONG_VERSION  - some other iperf binary (e.g. iperf3 symlink)
#   MISSING        - no `iperf` on PATH
# Plus a separate `mpstat` probe.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# Smart shim: each host gets its own response file under $FAKE_BIN.
install_classifying_ssh() {
    cat > "$FAKE_BIN/ssh" <<'SHIM'
#!/usr/bin/env bash
set -u
LOG="${FAKE_SSH_LOG:-$(dirname "$0")/calls.log}"
target=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift; [ $# -gt 0 ] && shift ;;
        -[a-zA-Z]) shift ;;
        *@*) target="$1"; shift; break ;;
        *) shift ;;
    esac
done
remote_cmd="$*"
host="${target#*@}"
printf 'ssh\t%s\t%s\n' "$host" "$remote_cmd" >> "$LOG"

case "$remote_cmd" in
    *"iperf -v"*)
        f="$FAKE_BIN/iperf_v_$host"
        if [ -f "$f" ]; then
            cat "$f"
        fi
        ;;
    *"command -v mpstat"*)
        f="$FAKE_BIN/mpstat_$host"
        if [ -f "$f" ]; then
            cat "$f"
        else
            echo "yes"
        fi
        ;;
esac
exit 0
SHIM
    chmod +x "$FAKE_BIN/ssh"
    cat > "$FAKE_BIN/scp" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
    chmod +x "$FAKE_BIN/scp"
    export FAKE_SSH_LOG="$FAKE_BIN/calls.log"
    : > "$FAKE_SSH_LOG"
}

prep_servers() {
    write_server_list "$@" >/dev/null
}

run_with_fakes() {
    PATH="$FAKE_BIN:$PATH" run_orch "$@"
}

set_iperf_v_response() {
    echo "$2" > "$FAKE_BIN/iperf_v_$1"
}
set_mpstat_response() {
    echo "$2" > "$FAKE_BIN/mpstat_$1"
}

# ---- INSTALLED ------------------------------------------------------------

test_classifies_iperf_2_1_9_as_installed() {
    install_classifying_ssh
    prep_servers h1
    set_iperf_v_response h1 "iperf version 2.1.9 (1 March 2023) pthreads"
    run_with_fakes check-iperf
    assert_status 0 "$RUN_RC" || return 1
    echo "$RUN_OUT" | grep -q "h1.*INSTALLED" || {
        echo "expected h1 to be INSTALLED" >&2; echo "$RUN_OUT" >&2; return 1
    }
}

test_classifies_iperf_2_0_x_as_installed() {
    install_classifying_ssh
    prep_servers h1
    set_iperf_v_response h1 "iperf version 2.0.13 (21 January 2019) pthreads"
    run_with_fakes check-iperf
    echo "$RUN_OUT" | grep -q "h1.*INSTALLED" || return 1
}

test_classifies_legacy_iperf_2_0_5_as_installed() {
    install_classifying_ssh
    prep_servers h1
    set_iperf_v_response h1 "iperf  version 2.0.5 (8 Jul 2010) pthreads"
    run_with_fakes check-iperf
    echo "$RUN_OUT" | grep -q "h1.*INSTALLED" || return 1
}

# ---- WRONG_VERSION (iperf3 symlinked / other binaries) -------------------

test_classifies_iperf3_as_wrong_version() {
    install_classifying_ssh
    prep_servers h1
    set_iperf_v_response h1 "iperf 3.10.1"
    run_with_fakes check-iperf
    echo "$RUN_OUT" | grep -q "h1.*WRONG_VERSION" || {
        echo "expected WRONG_VERSION for iperf3 output" >&2; echo "$RUN_OUT" >&2; return 1
    }
}

test_classifies_unknown_iperf_brand_as_wrong_version() {
    install_classifying_ssh
    prep_servers h1
    set_iperf_v_response h1 "some other iperf-like binary"
    run_with_fakes check-iperf
    echo "$RUN_OUT" | grep -q "h1.*WRONG_VERSION" || return 1
}

# ---- MISSING -------------------------------------------------------------

test_classifies_no_iperf_response_as_missing() {
    install_classifying_ssh
    prep_servers h1
    run_with_fakes check-iperf
    echo "$RUN_OUT" | grep -q "h1.*MISSING" || {
        echo "expected MISSING when iperf -v returns no output" >&2
        echo "$RUN_OUT" >&2
        return 1
    }
}

# ---- mpstat probe --------------------------------------------------------

test_mpstat_probe_yes_present() {
    install_classifying_ssh
    prep_servers h1
    set_iperf_v_response h1 "iperf version 2.1.9 pthreads"
    set_mpstat_response  h1 "yes"
    run_with_fakes check-iperf
    echo "$RUN_OUT" | grep -q "mpstat=yes" || return 1
}

test_mpstat_probe_no_absent() {
    install_classifying_ssh
    prep_servers h1
    set_iperf_v_response h1 "iperf version 2.1.9 pthreads"
    set_mpstat_response  h1 "no"
    run_with_fakes check-iperf
    echo "$RUN_OUT" | grep -q "mpstat=no" || return 1
}

# ---- Mixed mesh ---------------------------------------------------------

test_check_iperf_mixed_mesh_classifies_each_host() {
    install_classifying_ssh
    prep_servers good wrong missing
    set_iperf_v_response good    "iperf version 2.1.9 pthreads"
    set_iperf_v_response wrong   "iperf 3.10.1"
    run_with_fakes check-iperf
    echo "$RUN_OUT" | grep -q "good.*INSTALLED"        || return 1
    echo "$RUN_OUT" | grep -q "wrong.*WRONG_VERSION"   || return 1
    echo "$RUN_OUT" | grep -q "missing.*MISSING"       || return 1
}

run_test test_classifies_iperf_2_1_9_as_installed
run_test test_classifies_iperf_2_0_x_as_installed
run_test test_classifies_legacy_iperf_2_0_5_as_installed
run_test test_classifies_iperf3_as_wrong_version
run_test test_classifies_unknown_iperf_brand_as_wrong_version
run_test test_classifies_no_iperf_response_as_missing
run_test test_mpstat_probe_yes_present
run_test test_mpstat_probe_no_absent
run_test test_check_iperf_mixed_mesh_classifies_each_host

report_tests
