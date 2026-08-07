#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for matrix_agent/fleet.sh. Real SSH is faked with logging shims
# (the same FAKE_BIN pattern the orchestrator tests use), so these
# verify the exact remote invocations fleet.sh constructs without
# needing a fleet.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

AGENT="$REPO_ROOT/matrix_agent/matrix_agent.py"
FLEET="$REPO_ROOT/matrix_agent/fleet.sh"

_fleet_env() {
    # Fake ssh/scp that log their argv and succeed. ssh echoes nothing
    # (so status parsing isn't exercised here); scp copies nothing.
    export FLEET_LOG="$TEST_TMPDIR/fleet.log"
    : > "$FLEET_LOG"
    mkdir -p "$FAKE_BIN"
    for tool in ssh scp; do
        cat > "$FAKE_BIN/$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >> "\$FLEET_LOG"
exit 0
EOF
        chmod +x "$FAKE_BIN/$tool"
    done
    cat > "$TEST_TMPDIR/hosts.txt" <<EOF
alpha=10.0.0.1
beta=10.0.0.2:5299
EOF
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/hosts.txt" --rate-mbps 10 \
        -o "$TEST_TMPDIR/matrix.csv" >/dev/null
}

_run_fleet() {
    PATH="$FAKE_BIN:$PATH" "$FLEET" --matrix "$TEST_TMPDIR/matrix.csv" \
        --jobs 4 "$@" >"$TEST_TMPDIR/out" 2>&1
}

test_hosts_subcommand_lists_matrix_hosts() {
    _fleet_env
    local out; out=$(python3 "$AGENT" hosts --matrix "$TEST_TMPDIR/matrix.csv")
    assert_contains "$out" "alpha 10.0.0.1 5220" "default port applied" || return 1
    assert_contains "$out" "beta 10.0.0.2 5299" "explicit port kept" || return 1
}

test_deploy_pushes_agent_and_matrix_to_every_host() {
    _fleet_env
    _run_fleet deploy || { cat "$TEST_TMPDIR/out"; return 1; }
    local log; log=$(cat "$FLEET_LOG")
    assert_contains "$log" "mkdir -p '/var/tmp/mxa/rep'" || return 1
    assert_contains "$log" "matrix_agent.py" "agent shipped" || return 1
    assert_contains "$log" "10.0.0.1:/var/tmp/mxa/" "alpha targeted" || return 1
    assert_contains "$log" "10.0.0.2:/var/tmp/mxa/" "beta targeted" || return 1
    # One mkdir ssh + one scp per host.
    assert_eq "2" "$(grep -c '^scp ' "$FLEET_LOG")" "one scp per host" || return 1
}

test_start_passes_hostname_and_agent_flags() {
    _fleet_env
    _run_fleet start -- --protocol udp --interval 30 || { cat "$TEST_TMPDIR/out"; return 1; }
    local log; log=$(cat "$FLEET_LOG")
    assert_contains "$log" "--hostname 'alpha'" "identity pinned per host" || return 1
    assert_contains "$log" "--hostname 'beta'" || return 1
    assert_contains "$log" "--protocol udp" "agent flags forwarded" || return 1
    assert_contains "$log" "--interval 30" || return 1
    assert_contains "$log" "nohup python3 matrix_agent.py run" || return 1
}

test_rr_command_builds_matrix_and_restarts_in_rr_mode() {
    # One-shot request/response: --hosts/--pps/--send/--reply builds the
    # matrix (pps -> Mbps math) and restarts the fleet with the right
    # agent flags -- no manual gen or flag plumbing.
    _fleet_env
    local m="$TEST_TMPDIR/rrmatrix.csv"
    PATH="$FAKE_BIN:$PATH" "$FLEET" --matrix "$m" \
        --hosts "$TEST_TMPDIR/hosts.txt" --pps 4000 --send 30 --reply 500 \
        --jobs 4 rr >"$TEST_TMPDIR/out" 2>&1 || { cat "$TEST_TMPDIR/out"; return 1; }
    [ -f "$m" ] || { echo "rr did not generate the matrix"; return 1; }
    assert_contains "$(cat "$m")" "0.960" "pps math: 4000 x 30B = 0.96 Mbps" || return 1
    local log; log=$(cat "$FLEET_LOG")
    assert_contains "$log" "kill -TERM" "stops old agents first" || return 1
    assert_contains "$log" "--protocol udp" || return 1
    assert_contains "$log" "--udp-payload 30" || return 1
    assert_contains "$log" "--respond-bytes 500" || return 1
}

_bind_aware_ssh() {
    # ssh shim that answers the --bind address query: the data network
    # (192.168.50.x) is deliberately a different subnet from the login
    # network (10.0.0.x), which is the whole point of the feature.
    cat > "$FAKE_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >> "$FLEET_LOG"
case "$*" in
    *"ip -o -4 addr show"*)
        for a in "$@"; do
            case "$a" in *10.0.0.*) echo "192.168.50.${a##*.}"; exit 0 ;; esac
        done ;;
esac
exit 0
EOF
    chmod +x "$FAKE_BIN/ssh"
}

test_bind_puts_traffic_on_the_bound_nic_not_the_login_address() {
    # --bind used to pin only the source address and the listener; the
    # destination still came from the matrix, which is also the ssh
    # target. Where the data network differs from the management network
    # that meant senders transmitted from the data NIC but connected to
    # the login IP -- flows=N with tx=0.0, peers=0 on every receiver.
    # fleet.sh now resolves each host's address on the bound device over
    # the control path and hands the whole map to every agent.
    _fleet_env
    _bind_aware_ssh
    _run_fleet --bind eth1 start || { cat "$TEST_TMPDIR/out"; return 1; }
    local log; log=$(cat "$FLEET_LOG")
    assert_contains "$log" "--bind eth1" "--bind reaches the remote agents" || return 1
    # Traffic endpoints must be the data addresses, with the matrix port
    # preserved (beta's is a non-default 5299).
    assert_contains "$log" "--map alpha=192.168.50.1:5220" "alpha mapped to its eth1 address" || return 1
    assert_contains "$log" "--map beta=192.168.50.2:5299" "beta mapped, port kept" || return 1
    # Every agent must get the whole map, not just its own entry.
    local per_host
    per_host=$(grep -c -- "--map alpha=192.168.50.1:5220" "$FLEET_LOG")
    assert_eq "2" "$per_host" "both agents receive the full map" || return 1
    # ssh/scp still go to the login addresses -- identity is untouched.
    assert_contains "$log" "10.0.0.1" "ssh still uses the login address" || return 1
    # Same via the orchestrator's env var, no flag.
    : > "$FLEET_LOG"
    IPERF_BIND=eth2 _run_fleet start || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_contains "$(cat "$FLEET_LOG")" "--bind eth2" "IPERF_BIND honored" || return 1
}

test_bind_that_matches_no_interface_fails_loudly() {
    # Silently falling back to the login address would recreate exactly
    # the bug this resolution exists to prevent, so an unresolvable
    # --bind must stop the run instead.
    _fleet_env
    cat > "$FAKE_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >> "$FLEET_LOG"
exit 0
EOF
    chmod +x "$FAKE_BIN/ssh"
    local rc=0
    _run_fleet --bind nosuch0 --retries 0 start || rc=$?
    [ "$rc" -ne 0 ] || { echo "unresolvable --bind should fail"; cat "$TEST_TMPDIR/out"; return 1; }
    assert_contains "$(cat "$TEST_TMPDIR/out")" "matched no interface" || return 1
    # And no agent may have been launched with the wrong endpoints.
    case "$(cat "$FLEET_LOG")" in
        *"nohup"*) echo "agents started despite unresolved --bind"; return 1 ;;
    esac
}

test_no_bind_leaves_endpoints_alone() {
    # Without --bind there is nothing to resolve: no ssh probe, no --map,
    # and the matrix addresses stay the traffic endpoints.
    _fleet_env
    _run_fleet start || { cat "$TEST_TMPDIR/out"; return 1; }
    local log; log=$(cat "$FLEET_LOG")
    case "$log" in
        *"--map"*)             echo "unexpected --map without --bind"; return 1 ;;
        *"ip -o -4 addr"*)     echo "unexpected bind probe without --bind"; return 1 ;;
    esac
    assert_contains "$log" "nohup" "agents still start" || return 1
}

test_heal_only_touches_hosts_without_a_live_agent() {
    # `up` is already safe to repeat, but it re-deploys to every host --
    # the slow part, and the part that competes with running traffic.
    # After an `up` that failed on some hosts, `heal` must repair only
    # those and leave live agents completely alone.
    _fleet_env
    # alpha has a live agent (pidfile check succeeds); beta does not.
    cat > "$FAKE_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >> "$FLEET_LOG"
# The liveness probe is a bare `kill -0`; start's own pidfile guard
# contains one too, so match on the absence of the launch command.
case "$*" in
    *nohup*)     exit 0 ;;
    *"kill -0"*) case "$*" in *10.0.0.1*) exit 0 ;; *) exit 1 ;; esac ;;
esac
exit 0
EOF
    chmod +x "$FAKE_BIN/ssh"
    _run_fleet heal || { cat "$TEST_TMPDIR/out"; return 1; }
    local out; out=$(cat "$TEST_TMPDIR/out")
    assert_contains "$out" "1 of 2 hosts need starting" "only the dead one selected" || return 1
    assert_contains "$out" "beta" "and it is named" || return 1
    # beta gets deployed and started; alpha is not touched after the probe.
    local log; log=$(cat "$FLEET_LOG")
    assert_contains "$log" "--hostname 'beta'" "beta started" || return 1
    case "$log" in
        *"--hostname 'alpha'"*) echo "alpha was started despite running"; return 1 ;;
    esac
    # No scp to the live host -- that is the expense heal exists to avoid.
    assert_eq "1" "$(grep -c '^scp ' "$FLEET_LOG")" "only the dead host is redeployed to" || return 1
}

test_heal_is_a_noop_when_everything_runs() {
    _fleet_env
    cat > "$FAKE_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >> "$FLEET_LOG"
exit 0
EOF
    chmod +x "$FAKE_BIN/ssh"
    _run_fleet heal || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_contains "$(cat "$TEST_TMPDIR/out")" "all 2 hosts already running" || return 1
    assert_eq "0" "$(grep -c '^scp ' "$FLEET_LOG")" "nothing deployed" || return 1
    case "$(cat "$FLEET_LOG")" in
        *"nohup"*) echo "heal started an agent when none was needed"; return 1 ;;
    esac
}

test_heal_treats_an_unreachable_host_as_needing_work() {
    # An unreachable host cannot be probed. It must be selected for
    # repair rather than silently counted as healthy -- and if the repair
    # then fails, that failure is reported normally.
    _fleet_env
    cat > "$FAKE_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >> "$FLEET_LOG"
case "$*" in *10.0.0.2*) exit 255 ;; esac
exit 0
EOF
    chmod +x "$FAKE_BIN/ssh"
    local rc=0
    _run_fleet --retries 0 heal || rc=$?
    local out; out=$(cat "$TEST_TMPDIR/out")
    assert_contains "$out" "1 of 2 hosts need starting" "unreachable host selected" || return 1
    assert_contains "$out" "beta" || return 1
    [ "$rc" -ne 0 ] || { echo "a failed repair should exit nonzero"; echo "$out"; return 1; }
    assert_contains "$out" "hosts failed" "and the failure is reported" || return 1
}

test_stop_and_reload_signal_agents() {
    _fleet_env
    _run_fleet stop || { cat "$TEST_TMPDIR/out"; return 1; }
    local log; log=$(cat "$FLEET_LOG")
    assert_contains "$log" "kill -TERM" || return 1
    assert_contains "$log" "agent.pid" "stop signals via the pidfile" || return 1
    : > "$FLEET_LOG"
    _run_fleet reload || { cat "$TEST_TMPDIR/out"; return 1; }
    log=$(cat "$FLEET_LOG")
    assert_contains "$log" "kill -HUP" || return 1
    assert_contains "$log" "agent.pid" "reload signals via the pidfile" || return 1
    assert_contains "$log" "matrix.csv" "reload re-ships the matrix" || return 1
}

test_start_really_launches_agents_no_pgrep_self_match() {
    # Regression: liveness once used pgrep -f, but the ssh-spawned shell's
    # own command line contains the agent's launch string, so every start
    # matched itself, reported "already running", and launched nothing
    # (status said "running" with no agent.out; collect found no reports).
    # Execute the remote commands for real -- the ssh shim runs them
    # locally -- and require an agent to actually launch, then die on stop.
    _fleet_env
    local remote="$TEST_TMPDIR/remote"
    mkdir -p "$remote"
    cat > "$FAKE_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
# Drop ssh options and the target, execute the remote command locally.
while [ $# -gt 0 ]; do
    case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac
done
shift    # the target host
exec bash -c "$*"
EOF
    cat > "$FAKE_BIN/scp" <<'EOF'
#!/usr/bin/env bash
# Copy sources to the dir behind "host:path".
srcs=(); dst=""
for a in "$@"; do
    case "$a" in -o) skip=1 ;; *) [ "${skip:-}" ] && skip= && continue
        case "$a" in -*) ;; *:*) dst="${a#*:}" ;; *) srcs+=("$a") ;; esac ;;
    esac
done
cp "${srcs[@]}" "$dst"
EOF
    chmod +x "$FAKE_BIN/ssh" "$FAKE_BIN/scp"
    # Matrix of two localhost "hosts"; only one agent must start (the
    # second start legitimately sees the first via pgrep).
    PATH="$FAKE_BIN:$PATH" "$FLEET" --matrix "$TEST_TMPDIR/matrix.csv" \
        --remote-dir "$remote" --jobs 1 up >"$TEST_TMPDIR/out" 2>&1 \
        || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_contains "$(cat "$TEST_TMPDIR/out")" "started" \
        "at least one agent must actually launch" || return 1
    local i
    for i in $(seq 1 50); do [ -s "$remote/agent.out" ] && break; sleep 0.2; done
    [ -s "$remote/agent.out" ] || { echo "agent.out missing/empty: agent never ran"; return 1; }
    # And stop must terminate it (a signal that self-matches would not).
    PATH="$FAKE_BIN:$PATH" "$FLEET" --matrix "$TEST_TMPDIR/matrix.csv" \
        --remote-dir "$remote" --jobs 1 stop >"$TEST_TMPDIR/out" 2>&1 || true
    for i in $(seq 1 50); do
        pgrep -f "matrix_agent.[p]y run" >/dev/null || break
        sleep 0.2
    done
    if pgrep -f "matrix_agent.[p]y run" >/dev/null; then
        pkill -TERM -f "matrix_agent.[p]y run" || true
        echo "agents survived fleet stop"
        return 1
    fi
}

test_summarize_pulls_only_the_report_tail() {
    # summarize used to scp every report whole. Reports grow for the life
    # of the run, so a fleet that had been up for hours spent minutes
    # copying and parsing megabytes to read the last 60 seconds. It now
    # pulls a bounded tail -- and must not overwrite the full report a
    # previous `collect` archived in --reports.
    _fleet_env
    local remote="$TEST_TMPDIR/remote2"
    mkdir -p "$remote/rep"
    local h
    for h in alpha beta; do
        {
            echo "ts,host,dir,peer,proto,target_mbps,achieved_mbps,bytes,extra"
            python3 -c "
ts = 1750000000
for i in range(20000):
    ts += 10
    print('%d,$h,rx,other,tcp,100.000,90.000,112500,' % ts)
"
        } > "$remote/rep/${h}_agent.csv"
    done
    local bytes_before; bytes_before=$(wc -c < "$remote/rep/alpha_agent.csv")
    [ "$bytes_before" -gt 500000 ] || { echo "fixture too small to be a test"; return 1; }
    # An archival full collect first; its output must survive summarize.
    local reports="$TEST_TMPDIR/reports2"
    cat > "$FAKE_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
    case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac
done
shift
exec bash -c "$*"
EOF
    cat > "$FAKE_BIN/scp" <<'EOF'
#!/usr/bin/env bash
srcs=(); dst=""
for a in "$@"; do
    case "$a" in -o) skip=1 ;; *) [ "${skip:-}" ] && skip= && continue
        case "$a" in -*) ;; *:*) [ -z "$dst" ] && srcs+=("${a#*:}") || dst="${a#*:}" ;; *) dst="$a" ;; esac ;;
    esac
done
cp "${srcs[@]}" "$dst"
EOF
    chmod +x "$FAKE_BIN/ssh" "$FAKE_BIN/scp"
    PATH="$FAKE_BIN:$PATH" "$FLEET" --matrix "$TEST_TMPDIR/matrix.csv" \
        --remote-dir "$remote" --reports "$reports" --jobs 2 collect \
        >"$TEST_TMPDIR/out" 2>&1 || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_eq "$bytes_before" "$(wc -c < "$reports/alpha_agent.csv")" \
        "collect must still fetch the whole report" || return 1

    PATH="$FAKE_BIN:$PATH" "$FLEET" --matrix "$TEST_TMPDIR/matrix.csv" \
        --remote-dir "$remote" --reports "$reports" --jobs 2 --window 60 \
        --tail-bytes 65536 summarize >"$TEST_TMPDIR/out" 2>&1 \
        || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_contains "$(cat "$TEST_TMPDIR/out")" "window: last 60s" \
        "summary still produced" || return 1
    # Where the copies went must be stated: they land in a dotted subdir,
    # so looking for them in --reports and finding nothing is easy.
    assert_contains "$(cat "$TEST_TMPDIR/out")" ".window/" \
        "summarize says where it put the copies" || return 1
    assert_contains "$(cat "$TEST_TMPDIR/out")" "collect" \
        "and points at collect for full reports" || return 1
    # The windowed copy is bounded and lives beside, not on top of, the
    # archived one.
    local windowed="$reports/.window/alpha_agent.csv"
    [ -s "$windowed" ] || { echo "windowed copy missing"; return 1; }
    [ "$(wc -c < "$windowed")" -lt "$bytes_before" ] \
        || { echo "summarize copied the whole file again"; return 1; }
    assert_eq "$bytes_before" "$(wc -c < "$reports/alpha_agent.csv")" \
        "summarize must not clobber the archived full report" || return 1
    # Header survived the tailing, exactly once.
    assert_eq "1" "$(grep -c '^ts,host,dir' "$windowed")" \
        "header kept, and not duplicated" || return 1
    # With no --tail-bytes the size is derived from --window and the host
    # count -- bounded, and never the whole file.
    PATH="$FAKE_BIN:$PATH" "$FLEET" --matrix "$TEST_TMPDIR/matrix.csv" \
        --remote-dir "$remote" --reports "$reports" --jobs 2 --window 60 \
        summarize >"$TEST_TMPDIR/out" 2>&1 || { cat "$TEST_TMPDIR/out"; return 1; }
    local defbytes
    defbytes=$(sed -n 's/.*collecting last \([0-9]*\)B.*/\1/p' "$TEST_TMPDIR/out")
    [ -n "$defbytes" ] && [ "$defbytes" -ge 1048576 ] && [ "$defbytes" -le 33554432 ] \
        || { echo "default tail size not in the clamped range: '$defbytes'"; return 1; }
    # --tail-bytes 0 restores whole-file behavior.
    PATH="$FAKE_BIN:$PATH" "$FLEET" --matrix "$TEST_TMPDIR/matrix.csv" \
        --remote-dir "$remote" --reports "$reports" --jobs 2 --tail-bytes 0 \
        summarize >"$TEST_TMPDIR/out" 2>&1 || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_eq "$bytes_before" "$(wc -c < "$reports/alpha_agent.csv")" \
        "--tail-bytes 0 collects the full report" || return 1
}

test_ssh_user_and_remote_dir_options() {
    _fleet_env
    _run_fleet --user opsuser --remote-dir /opt/mxa deploy \
        || { cat "$TEST_TMPDIR/out"; return 1; }
    local log; log=$(cat "$FLEET_LOG")
    assert_contains "$log" "opsuser@10.0.0.1" "user applied to ssh target" || return 1
    assert_contains "$log" "mkdir -p '/opt/mxa/rep'" "remote dir honored" || return 1
}

test_transient_ssh_failure_is_retried() {
    # Re-running `up` against a fleet already at line rate is where this
    # bites: sshd competes with the agents for CPU (and, without --bind,
    # for the NIC), so a connect that was instant on an idle host can
    # miss the timeout. With no retry a single transient miss failed the
    # host -- "connection errors the second time that I didn't get the
    # first". ssh here fails once per host, then succeeds.
    _fleet_env
    cat > "$FAKE_BIN/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh \$*" >> "\$FLEET_LOG"
# One counter file per target host: fail the first attempt only.
# The target carries the SSH user the harness exports, so match on the
# address anywhere in the argument, not as a prefix.
target=\$(for a in "\$@"; do case "\$a" in *10.0.0.*) echo "\${a##*@}"; break ;; esac; done)
c="$TEST_TMPDIR/attempts.\$target"
n=\$(cat "\$c" 2>/dev/null || echo 0)
echo \$((n + 1)) > "\$c"
[ "\$n" -eq 0 ] && { echo "ssh: connect to host \$target port 22: Connection timed out" >&2; exit 255; }
exit 0
EOF
    chmod +x "$FAKE_BIN/ssh"
    local rc=0
    _run_fleet --retries 2 deploy || rc=$?
    assert_status 0 "$rc" "a transient failure must not fail the host" \
        || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_contains "$(cat "$TEST_TMPDIR/out")" "retrying" "retry is announced" || return 1
    assert_contains "$(cat "$TEST_TMPDIR/out")" "OK on all 2 hosts" || return 1
    # Both hosts must have been tried twice: once failing, once not.
    assert_eq "2" "$(cat "$TEST_TMPDIR/attempts.10.0.0.1")" "alpha retried once" || return 1
    assert_eq "2" "$(cat "$TEST_TMPDIR/attempts.10.0.0.2")" "beta retried once" || return 1
    # --retries 0 must restore fail-fast, so a real outage is still loud.
    rm -f "$TEST_TMPDIR"/attempts.*
    rc=0
    _run_fleet --retries 0 deploy || rc=$?
    [ "$rc" -ne 0 ] || { echo "--retries 0 should fail fast"; return 1; }
    assert_contains "$(cat "$TEST_TMPDIR/out")" "2/2 hosts failed" || return 1
}

test_connect_timeout_is_configurable() {
    _fleet_env
    _run_fleet --connect-timeout 45 deploy || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_contains "$(cat "$FLEET_LOG")" "ConnectTimeout=45" "timeout forwarded" || return 1
    : > "$FLEET_LOG"
    _run_fleet deploy || { cat "$TEST_TMPDIR/out"; return 1; }
    local log; log=$(cat "$FLEET_LOG")
    assert_contains "$log" "ConnectTimeout=20" "default raised from the old 8s" || return 1
    assert_contains "$log" "ServerAliveInterval" "stalled sessions time out" || return 1
}

test_failed_host_is_reported_and_exit_nonzero() {
    _fleet_env
    # ssh fails for beta only.
    cat > "$FAKE_BIN/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh \$*" >> "\$FLEET_LOG"
case "\$*" in *10.0.0.2*) exit 255 ;; esac
exit 0
EOF
    chmod +x "$FAKE_BIN/ssh"
    local rc=0
    _run_fleet deploy || rc=$?
    [ "$rc" -ne 0 ] || { echo "deploy should fail when a host fails"; cat "$TEST_TMPDIR/out"; return 1; }
    assert_contains "$(cat "$TEST_TMPDIR/out")" "1/2 hosts failed" || return 1
    assert_contains "$(cat "$TEST_TMPDIR/out")" "beta" "failing host named" || return 1
}

test_orchestrator_matrix_subcommand_forwards_to_fleet() {
    _fleet_env
    # `matrix --help` through the orchestrator must reach fleet.sh's
    # usage text, proving the pre-parse dispatch fires before the
    # orchestrator's own flag validation could reject --help's friends.
    run_orch matrix --help
    assert_status 0 "$RUN_RC" "matrix --help should exit 0" || return 1
    assert_contains "$RUN_OUT" "fleet.sh" "fleet usage reached" || return 1
    assert_contains "$RUN_OUT" "summarize" || return 1
}

test_orchestrator_matrix_forwards_fleet_flags_untouched() {
    _fleet_env
    # --matrix is a fleet.sh flag the orchestrator's global parser would
    # reject; through the matrix pass-through it must work end-to-end.
    PATH="$FAKE_BIN:$PATH" run_orch matrix \
        --matrix "$TEST_TMPDIR/matrix.csv" --jobs 2 stop
    assert_status 0 "$RUN_RC" "matrix stop via orchestrator" || return 1
    assert_contains "$(cat "$FLEET_LOG")" "kill -TERM" || return 1
    assert_contains "$(cat "$FLEET_LOG")" "agent.pid" "stop via pidfile through orchestrator" || return 1
}

test_matrix_dispatch_survives_lost_executable_bit() {
    # Some transports and bundle splitters drop file modes; the
    # pass-through must exec via bash rather than relying on +x.
    _fleet_env
    local tree="$TEST_TMPDIR/tree"
    mkdir -p "$tree"
    cp -r "$REPO_ROOT/iperf_orchestrator" "$REPO_ROOT/matrix_agent" "$tree/"
    chmod 644 "$tree/matrix_agent/fleet.sh"
    local out rc
    out=$(bash "$tree/iperf_orchestrator/iperf_orchestrator.sh" matrix --help 2>&1); rc=$?
    assert_status 0 "$rc" "matrix must work without exec bit on fleet.sh" || return 1
    assert_contains "$out" "fleet.sh" "fleet usage reached" || return 1
}

test_matrix_dispatch_reports_missing_tooling_clearly() {
    _fleet_env
    local tree="$TEST_TMPDIR/lonely"
    mkdir -p "$tree"
    cp -r "$REPO_ROOT/iperf_orchestrator" "$tree/"   # no matrix_agent/ at all
    local out rc
    out=$(bash "$tree/iperf_orchestrator/iperf_orchestrator.sh" matrix up 2>&1); rc=$?
    [ "$rc" -ne 0 ] || { echo "missing tooling should exit nonzero"; return 1; }
    assert_contains "$out" "matrix_agent/fleet.sh" "names what is missing" || return 1
    assert_contains "$out" "broken or partial install" || return 1
    assert_contains "$out" "force-reinstall" "gives the remedy" || return 1
}

run_test test_hosts_subcommand_lists_matrix_hosts
run_test test_orchestrator_matrix_subcommand_forwards_to_fleet
run_test test_orchestrator_matrix_forwards_fleet_flags_untouched
run_test test_matrix_dispatch_survives_lost_executable_bit
run_test test_matrix_dispatch_reports_missing_tooling_clearly
run_test test_deploy_pushes_agent_and_matrix_to_every_host
run_test test_start_passes_hostname_and_agent_flags
run_test test_start_really_launches_agents_no_pgrep_self_match
run_test test_rr_command_builds_matrix_and_restarts_in_rr_mode
run_test test_bind_puts_traffic_on_the_bound_nic_not_the_login_address
run_test test_bind_that_matches_no_interface_fails_loudly
run_test test_no_bind_leaves_endpoints_alone
run_test test_heal_only_touches_hosts_without_a_live_agent
run_test test_heal_is_a_noop_when_everything_runs
run_test test_heal_treats_an_unreachable_host_as_needing_work
run_test test_stop_and_reload_signal_agents
run_test test_summarize_pulls_only_the_report_tail
run_test test_ssh_user_and_remote_dir_options
run_test test_transient_ssh_failure_is_retried
run_test test_connect_timeout_is_configurable
run_test test_failed_host_is_reported_and_exit_nonzero

report_tests
