#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# The tool stops only the iperf daemons it started, and checks that the ones
# it starts are listening (shared_tools IO-006; the owner chose: no fallback
# to the pattern).
#
# Before 2.12.0 stop-servers (and stop, clean, Ctrl-C) ran
# `pkill -f '^iperf -p PORT '`, which killed an operator's own daemon on the
# port too; start-servers ran `iperf -s -D`, which detaches before it binds,
# so a taken port "started" and exited 0; check-servers said RUNNING for any
# iperf at all; and a host without `ip` was told its --server-bind pattern
# matched nothing.
#
# Most tests use the sandbox (test_helper.bash), whose iperf stand-in keeps a
# per-host registry of daemons and stays up as a real process, and whose
# `ss` lists that registry. The last two run each host's commands on this
# machine with a stand-in iperf that really listens (python3), so the `ss`
# and /proc checks are tested against real sockets.
#
# OWN_ONLY=<test name> runs just that test (the mutation file,
# test_own_daemons_mutations.sh, uses it).

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

orch() { PATH="$FAKE_BIN:$PATH" run_orch "$@"; }

sandbox_two_hosts() {
    install_sandbox_ssh
    write_server_list h1 h2 >/dev/null
}

registry() { cat "$SANDBOX_ROOT/daemons/$1" 2>/dev/null; }
pidfile() { printf '%s/iperf_daemon_%s_%s.pid' "$REMOTE_DIR" "$1" "${2:-5001}"; }
# A pid is up while its command line is still a stand-in iperf (a zombie's
# is empty).
is_up() { case "$(ps -o args= -p "$1" 2>/dev/null)" in *iperf*) return 0 ;; esac; return 1; }

test_stop_leaves_an_operators_daemon_on_the_same_port() {
    sandbox_two_hosts
    local cmd
    for cmd in stop-servers stop "clean --yes"; do
        : > "$SANDBOX_ROOT/daemons/h1"; : > "$SANDBOX_ROOT/daemons/h2"
        sandbox_foreign_daemon h1 25101
        orch --port 25101 start-servers
        [ -n "$(registry h2)" ] || { echo "h2's own daemon did not start: $RUN_OUT" >&2; return 1; }
        # shellcheck disable=SC2086
        orch --port 25101 $cmd
        assert_contains "$(registry h1)" "iperf -p 25101 -s -D" "$cmd: the operator's daemon on h1 must survive" || return 1
        assert_eq "" "$(registry h2)" "$cmd: h2's daemon, the tool's own, is stopped" || return 1
    done
}

test_start_servers_fails_when_the_port_is_taken() {
    sandbox_two_hosts
    sandbox_foreign_daemon h1 5001
    orch start-servers
    assert_status 1 "$RUN_RC" "start-servers with h1's port taken: $RUN_OUT" || return 1
    assert_contains "$RUN_OUT" "h1: iperf -s is not listening on port 5001 (its log: listener bind failed: Address already in use)" || return 1
    assert_contains "$RUN_OUT" "start-servers: 1 failure(s) (h1)" || return 1
    [ ! -e "$(pidfile h1)" ] || { echo "h1 kept a pid file for a daemon that never listened" >&2; return 1; }
    [ -s "$(pidfile h2)" ] || { echo "h2 should have started and recorded its daemon" >&2; return 1; }
}

test_check_servers_reports_only_its_daemon_on_its_port() {
    sandbox_two_hosts
    sandbox_foreign_daemon h1 5001
    orch --port 5002 start-servers
    assert_status 0 "$RUN_RC" "start-servers on 5002: $RUN_OUT" || return 1
    orch check-servers
    assert_eq 2 "$(printf '%s\n' "$RUN_OUT" | grep -c STOPPED)" "on 5001: an operator's daemon and ours on 5002 are not it: $RUN_OUT" || return 1
    orch --port 5002 check-servers
    assert_eq 2 "$(printf '%s\n' "$RUN_OUT" | grep -cE 'RUNNING +pid [0-9]+: .*iperf -p 5002 -s$')" "on 5002: $RUN_OUT" || return 1
}

test_start_servers_records_and_stop_servers_stops_its_daemon() {
    sandbox_two_hosts
    orch start-servers
    assert_status 0 "$RUN_RC" "$RUN_OUT" || return 1
    local pid
    pid=$(cat "$(pidfile h1)" 2>/dev/null)
    assert_contains "$RUN_OUT" "h1: the iperf daemon is listening on port 5001 (pid $pid)" || return 1
    is_up "$pid" || { echo "pid $pid from the pid file is not a running iperf" >&2; return 1; }
    orch stop-servers
    assert_status 0 "$RUN_RC" "$RUN_OUT" || return 1
    ! is_up "$pid" || { echo "pid $pid is still running after stop-servers" >&2; return 1; }
    [ ! -e "$(pidfile h1)" ] || { echo "the pid file is still there" >&2; return 1; }
    assert_eq "" "$(registry h1)$(registry h2)" "no daemon left" || return 1
}

test_a_second_start_keeps_the_running_daemon() {
    sandbox_two_hosts
    orch start-servers
    local pid; pid=$(cat "$(pidfile h1)")
    orch start-servers
    assert_status 0 "$RUN_RC" "$RUN_OUT" || return 1
    assert_contains "$RUN_OUT" "h1: the iperf daemon on port 5001 is already running (pid $pid)" || return 1
    assert_eq 1 "$(registry h1 | grep -c .)" "one daemon on h1" || return 1
}

# A pid file whose pid is now some other process of the same user is not
# trusted: that process is left alone and the file goes.
test_a_stale_pid_file_is_not_trusted() {
    sandbox_two_hosts
    mkdir -p -m 700 "$REMOTE_DIR"
    sleep 60 & local other=$!
    echo "$other" > "$(pidfile h1)"
    orch check-servers
    local line; line=$(printf '%s\n' "$RUN_OUT" | grep '^h1 ')
    orch stop-servers
    local rc=$RUN_RC alive=0
    kill -0 "$other" 2>/dev/null && alive=1
    kill "$other" 2>/dev/null
    assert_contains "$line" "STOPPED" "check-servers on a stale pid file" || return 1
    assert_status 0 "$rc" "stop-servers with a stale pid file" || return 1
    assert_eq 1 "$alive" "the process the stale pid file names must not be killed" || return 1
    [ ! -e "$(pidfile h1)" ] || { echo "the stale pid file should be removed" >&2; return 1; }
}

test_stop_works_without_pkill_and_pgrep() {
    sandbox_two_hosts
    orch start-servers
    rm -f "$SANDBOX_BIN/pkill" "$SANDBOX_BIN/pgrep"
    SANDBOX_HOST_PATH=$(path_without pkill pgrep)
    export SANDBOX_HOST_PATH
    orch stop-servers
    assert_status 0 "$RUN_RC" "$RUN_OUT" || return 1
    assert_eq "" "$(registry h1)$(registry h2)" "stop-servers without pkill must still stop the daemons" || return 1
}

test_a_missing_ip_is_named() {
    sandbox_two_hosts
    rm -f "$SANDBOX_BIN/ip"
    SANDBOX_HOST_PATH=$(path_without ip)
    export SANDBOX_HOST_PATH
    orch --server-bind eth0 start-servers
    assert_status 1 "$RUN_RC" "$RUN_OUT" || return 1
    assert_contains "$RUN_OUT" "h1: --server-bind needs the 'ip' command, which is not on this host" || return 1
    assert_not_contains "$RUN_OUT" "no interface matched" || return 1
    orch --bind eth0 create-scripts
    assert_ne 0 "$RUN_RC" "$RUN_OUT" || return 1
    assert_contains "$RUN_OUT" "--bind 'eth0' needs the 'ip' command, which is not on host(s): h1 h2" || return 1
}

# cleanup would leave a running daemon with no pid file, which stop-servers
# could then never stop.
test_cleanup_keeps_a_running_daemons_pid_file() {
    sandbox_two_hosts
    orch start-servers
    orch cleanup --yes
    assert_status 1 "$RUN_RC" "$RUN_OUT" || return 1
    assert_contains "$RUN_OUT" "is still running; run stop-servers first (nothing removed)" || return 1
    [ -s "$(pidfile h1)" ] || { echo "cleanup removed a running daemon's pid file" >&2; return 1; }
    orch stop-servers
    orch cleanup --yes
    assert_status 0 "$RUN_RC" "cleanup after stop-servers: $RUN_OUT" || return 1
    [ ! -e "$REMOTE_DIR" ] || { echo "REMOTE_DIR should be gone" >&2; return 1; }
}

# ---- Real sockets ------------------------------------------------------------

# install_local_host [PATH]: ssh runs each command on this machine, under
# /bin/sh, with a stand-in iperf that really listens first on its PATH (then
# PATH, or the one given). The stand-in binds 127.0.0.1:PORT, or logs what
# iperf 2.1.9 logs when the port is taken and lingers, as it does.
install_local_host() {
    mkdir -p "$TEST_TMPDIR/hostbin"
    cat > "$TEST_TMPDIR/hostbin/iperf" <<'PY'
#!/usr/bin/env python3
import signal, socket, sys, time
a = sys.argv[1:]
port = int(a[a.index("-p") + 1])
s = socket.socket()
try:
    s.bind(("127.0.0.1", port))
    s.listen(5)
except OSError:
    print("listener bind failed: Address already in use", flush=True)
    time.sleep(2)
    sys.exit(0)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
end = time.time() + 120
while time.time() < end:
    time.sleep(0.2)
PY
    chmod +x "$TEST_TMPDIR/hostbin/iperf"
    cat > "$FAKE_BIN/ssh" <<EOF
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do case "\$1" in --) shift; shift; break ;; -o) shift 2 ;; *) shift ;; esac; done
printf 'ssh\t%s\n' "\$*" >> "$FAKE_BIN/calls.log"
PATH="$TEST_TMPDIR/hostbin:${1:-\$PATH}" exec /bin/sh -c "\$*"
EOF
    chmod +x "$FAKE_BIN/ssh"
    write_server_list localhost >/dev/null
}

# free_port: a port free right now, whose hex form has a letter in it, so
# that the /proc check is shown reading /proc/net/tcp's upper-case hex.
free_port() {
    python3 -c '
import socket
while True:
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close()
    if any(c in "ABCDEF" for c in "%04X" % p):
        print(p); break'
}

# listener PORT: a program that is not iperf holding PORT; prints its pid.
listener() {
    python3 -c 'import socket, sys, time; s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1); time.sleep(60)' "$1" \
        >/dev/null 2>&1 &
    echo $!
}

# The same checks with whatever the host has to look with.
real_socket_checks() {
    local p q pid other
    p=$(free_port); q=$(free_port)
    orch --port "$p" start-servers
    assert_status 0 "$RUN_RC" "start-servers on a free port: $RUN_OUT" || return 1
    pid=$(cat "$REMOTE_DIR/iperf_daemon_localhost_$p.pid")
    assert_contains "$RUN_OUT" "listening on port $p (pid $pid)" || return 1
    orch --port "$p" stop-servers
    ! is_up "$pid" || { echo "the daemon is still up after stop-servers" >&2; return 1; }
    other=$(listener "$q")
    sleep 0.5
    orch --port "$q" start-servers
    local rc=$RUN_RC out=$RUN_OUT
    kill "$other" 2>/dev/null
    assert_status 1 "$rc" "start-servers on a port another program holds: $out" || return 1
    assert_contains "$out" "not listening on port $q (its log: listener bind failed: Address already in use)" || return 1
}

test_listening_is_checked_with_ss_on_real_sockets() {
    command -v ss >/dev/null 2>&1 || { echo "(no ss: skipped)"; return 0; }
    install_local_host
    real_socket_checks
}

test_listening_is_checked_through_proc_without_ss() {
    [ -r /proc/net/tcp ] || { echo "(no /proc: skipped)"; return 0; }
    # No ss on the host's PATH, so the /proc check is the one that runs.
    install_local_host "$(path_without ss)"
    real_socket_checks
}

OWN_TESTS=(
    test_stop_leaves_an_operators_daemon_on_the_same_port
    test_start_servers_fails_when_the_port_is_taken
    test_check_servers_reports_only_its_daemon_on_its_port
    test_start_servers_records_and_stop_servers_stops_its_daemon
    test_a_second_start_keeps_the_running_daemon
    test_a_stale_pid_file_is_not_trusted
    test_stop_works_without_pkill_and_pgrep
    test_a_missing_ip_is_named
    test_cleanup_keeps_a_running_daemons_pid_file
    test_listening_is_checked_with_ss_on_real_sockets
    test_listening_is_checked_through_proc_without_ss
)
for t in "${OWN_TESTS[@]}"; do
    [ -n "${OWN_ONLY:-}" ] && [ "$t" != "$OWN_ONLY" ] && continue
    run_test "$t"
done

report_tests
