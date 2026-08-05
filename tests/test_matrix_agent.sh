#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for matrix_agent: matrix generation, admissibility checking,
# and a real two-agent localhost run with paced TCP flows. The run test
# asserts achieved rate lands near the 40 Mbps target -- loose bounds
# because CI runners are noisy neighbors.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

AGENT="$REPO_ROOT/matrix_agent/matrix_agent.py"

# Distinct high ports per test run so parallel/leftover runs can't collide.
PORT_A=$(( 40000 + (RANDOM % 20000) ))
PORT_B=$(( PORT_A + 1 ))

_write_hosts() {
    cat > "$TEST_TMPDIR/hosts.txt" <<EOF
alpha=127.0.0.1:$PORT_A
beta=127.0.0.1:$PORT_B
EOF
}

test_gen_writes_grid_matrix() {
    _write_hosts
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/hosts.txt" --rate-mbps 40 \
        -o "$TEST_TMPDIR/matrix.csv" >/dev/null
    assert_status 0 $? "gen should succeed" || return 1
    local m; m=$(cat "$TEST_TMPDIR/matrix.csv")
    assert_contains "$m" "alpha=127.0.0.1:$PORT_A" "header keeps host token" || return 1
    assert_contains "$m" "40.000" "cells carry the rate" || return 1
    # Diagonal must be empty: the alpha row starts with the token then an
    # empty cell (alpha->alpha), then 40.000 (alpha->beta).
    assert_contains "$m" "alpha=127.0.0.1:$PORT_A,,40.000" "diagonal empty" || return 1
}

test_check_flags_inadmissible_matrix() {
    _write_hosts
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/hosts.txt" --rate-mbps 40 \
        -o "$TEST_TMPDIR/matrix.csv" >/dev/null
    # Generous caps: admissible.
    local out rc
    out=$(python3 "$AGENT" check --matrix "$TEST_TMPDIR/matrix.csv" \
        --egress-gbps 1 --ingress-gbps 1 2>&1); rc=$?
    assert_status 0 "$rc" "40 Mbps under a 1 Gbps cap should pass" || return 1
    assert_contains "$out" "admissible" || return 1
    # Absurdly small cap: violation, nonzero exit.
    out=$(python3 "$AGENT" check --matrix "$TEST_TMPDIR/matrix.csv" \
        --egress-gbps 0.001 2>&1); rc=$?
    assert_status 1 "$rc" "40 Mbps over a 1 Mbps cap should fail" || return 1
    assert_contains "$out" "VIOLATION" || return 1
}

test_two_agents_sustain_target_rate() {
    _write_hosts
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/hosts.txt" --rate-mbps 40 \
        -o "$TEST_TMPDIR/matrix.csv" >/dev/null
    local rep="$TEST_TMPDIR/rep"
    python3 "$AGENT" run --matrix "$TEST_TMPDIR/matrix.csv" --hostname alpha \
        --interval 1 --duration 6 --report-dir "$rep" >/dev/null 2>&1 &
    local pid_a=$!
    python3 "$AGENT" run --matrix "$TEST_TMPDIR/matrix.csv" --hostname beta \
        --interval 1 --duration 6 --report-dir "$rep" >/dev/null 2>&1 &
    local pid_b=$!
    wait "$pid_a"; local rc_a=$?
    wait "$pid_b"; local rc_b=$?
    assert_status 0 "$rc_a" "alpha agent should exit cleanly" || return 1
    assert_status 0 "$rc_b" "beta agent should exit cleanly" || return 1
    [ -f "$rep/alpha_agent.csv" ] || { echo "no alpha report"; return 1; }
    [ -f "$rep/beta_agent.csv" ]  || { echo "no beta report";  return 1; }

    # Summarize and pull the aggregate achieved rx rate. Two 40 Mbps
    # flows -> target 80; accept 40..120 so a slow runner can't flake it,
    # while still proving pacing neither stalled nor ran away.
    local out; out=$(python3 "$AGENT" summarize "$rep"/*_agent.csv --window 10)
    assert_contains "$out" "aggregate rx" || return 1
    local achieved
    achieved=$(echo "$out" | sed -n 's/^aggregate rx: \([0-9.]*\) \/ .*/\1/p')
    [ -n "$achieved" ] || { echo "could not parse achieved rate from: $out"; return 1; }
    python3 -c "import sys; v=float('$achieved'); sys.exit(0 if 40.0 <= v <= 120.0 else 1)" || {
        echo "achieved rx $achieved Mbps outside 40..120 (target 80)"
        echo "$out"
        return 1
    }
}

test_hosts_accepts_bare_ip_tokens() {
    # IP-only workflows: a plain address (optionally with :port) is a
    # complete host token -- the address doubles as the name.
    cat > "$TEST_TMPDIR/ips.txt" <<EOF
10.0.0.7
10.0.0.8:5299
EOF
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/ips.txt" --rate-mbps 10 \
        -o "$TEST_TMPDIR/ipmatrix.csv" >/dev/null
    assert_status 0 $? "gen from bare IPs should succeed" || return 1
    local out; out=$(python3 "$AGENT" hosts --matrix "$TEST_TMPDIR/ipmatrix.csv")
    assert_contains "$out" "10.0.0.7 10.0.0.7 5220" "bare IP: name=addr, default port" || return 1
    assert_contains "$out" "10.0.0.8 10.0.0.8 5299" "bare IP:port keeps port out of name" || return 1
}

test_run_auto_identifies_by_local_address() {
    # No --hostname: with an IP matrix the agent must find its own row by
    # matching addresses against local interfaces. 203.0.113.5 is
    # TEST-NET-3, never assigned locally, so 127.0.0.1 is the only match.
    cat > "$TEST_TMPDIR/ips.txt" <<EOF
127.0.0.1:$PORT_A
203.0.113.5
EOF
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/ips.txt" --rate-mbps 5 \
        -o "$TEST_TMPDIR/ipmatrix.csv" >/dev/null
    local rep="$TEST_TMPDIR/iprep" out rc
    out=$(python3 "$AGENT" run --matrix "$TEST_TMPDIR/ipmatrix.csv" \
        --interval 1 --duration 2 --report-dir "$rep" 2>&1); rc=$?
    assert_status 0 "$rc" "auto-identified run should exit cleanly" || { echo "$out"; return 1; }
    assert_contains "$out" "host=127.0.0.1" "identified as the local row" || return 1
    [ -f "$rep/127.0.0.1_agent.csv" ] || { echo "no report for auto-identified host"; return 1; }
}

test_run_rejects_ambiguous_local_addresses() {
    # Both 127.0.0.1 and 127.0.0.2 bind locally on Linux, so the agent
    # cannot pick a row on its own and must demand --hostname.
    cat > "$TEST_TMPDIR/ips.txt" <<EOF
127.0.0.1:$PORT_A
127.0.0.2:$PORT_B
EOF
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/ips.txt" --rate-mbps 5 \
        -o "$TEST_TMPDIR/ipmatrix.csv" >/dev/null
    local out rc
    out=$(python3 "$AGENT" run --matrix "$TEST_TMPDIR/ipmatrix.csv" \
        --duration 1 2>&1); rc=$?
    [ "$rc" -ne 0 ] || { echo "ambiguous local addresses should fail"; return 1; }
    assert_contains "$out" "multiple matrix hosts are local" || return 1
    assert_contains "$out" "--hostname" "tells the operator the fix" || return 1
}

test_bind_pins_traffic_iperf_orchestrator_style() {
    # --bind uses the orchestrator's semantics: substring against
    # `ip -o -4 addr show`. Where iproute2 is missing (the slim 3.6
    # container) a shim answers with the real output format, so the
    # resolution path runs everywhere; hosted runners use the real ip.
    if ! command -v ip >/dev/null 2>&1; then
        mkdir -p "$FAKE_BIN"
        printf '%s\n' '#!/usr/bin/env bash' \
            "echo '1: lo    inet 127.0.0.1/8 scope host lo'" > "$FAKE_BIN/ip"
        chmod +x "$FAKE_BIN/ip"
    fi
    _write_hosts
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/hosts.txt" --rate-mbps 5 \
        -o "$TEST_TMPDIR/matrix.csv" >/dev/null
    local out rc
    out=$(PATH="$FAKE_BIN:$PATH" python3 "$AGENT" run \
        --matrix "$TEST_TMPDIR/matrix.csv" \
        --hostname alpha --bind lo --interval 1 --duration 2 \
        --report-dir "$TEST_TMPDIR/bindrep" 2>&1); rc=$?
    assert_status 0 "$rc" "bound run should exit cleanly" || { echo "$out"; return 1; }
    assert_contains "$out" "iface=lo" "spec resolved to the interface" || return 1
    assert_contains "$out" "ip=127.0.0.1" "and to its address" || return 1
    # Same resolution via the orchestrator's env var, no flag.
    out=$(PATH="$FAKE_BIN:$PATH" IPERF_BIND=lo python3 "$AGENT" run \
        --matrix "$TEST_TMPDIR/matrix.csv" \
        --hostname alpha --interval 1 --duration 1 \
        --report-dir "$TEST_TMPDIR/bindrep" 2>&1); rc=$?
    assert_status 0 "$rc" "IPERF_BIND run should exit cleanly" || { echo "$out"; return 1; }
    assert_contains "$out" "iface=lo" "IPERF_BIND honored" || return 1
    # A spec matching nothing must fail loudly, not silently unbind.
    out=$(PATH="$FAKE_BIN:$PATH" python3 "$AGENT" run \
        --matrix "$TEST_TMPDIR/matrix.csv" \
        --hostname alpha --bind nosuchnic0 --duration 1 2>&1); rc=$?
    [ "$rc" -ne 0 ] || { echo "unmatched --bind spec should fail"; return 1; }
    assert_contains "$out" "no interface matched" || return 1
}

test_summarize_grid_feeds_sweep_tooling() {
    # --grid materializes the window aggregate as N x N grid CSVs plus an
    # orchestrator-format iperf_results.csv; prove the real make-pivot
    # consumes it, so matrix runs get the sweep's pivot/heatmap views.
    local rep="$TEST_TMPDIR/gridrep.csv" gdir="$TEST_TMPDIR/gridout"
    cat > "$rep" <<EOF
ts,host,dir,peer,proto,target_mbps,achieved_mbps,bytes,extra
1000,10.0.0.8,rx,10.0.0.7,tcp,100.000,80.000,100000000,
1000,10.0.0.7,rx,10.0.0.8,tcp,100.000,100.000,125000000,
1000,10.0.0.7,tx,10.0.0.8,tcp,100.000,99.000,124000000,
EOF
    local out rc
    out=$(python3 "$AGENT" summarize "$rep" --window 30 --grid "$gdir" 2>&1); rc=$?
    assert_status 0 "$rc" "summarize --grid should succeed" || { echo "$out"; return 1; }
    # Per-host table: receiver-side truth in both directions. 10.0.0.8
    # receives 80/100 (in 80%) and its traffic to 10.0.0.7 arrives in
    # full (out 100%); 10.0.0.7 is the mirror image.
    assert_contains "$out" "per host (rx in / tx out" "per-host table present" || return 1
    assert_contains "$out" "80.0/100.0" "deficit visible in host totals" || return 1
    host8=$(echo "$out" | grep "^  10.0.0.8 ")
    assert_contains "$host8" "( 80%)" "10.0.0.8 rx deficit" || return 1
    assert_contains "$host8" "(100%)" "10.0.0.8 tx delivered" || return 1
    assert_contains "$(cat "$gdir/achieved_grid.csv")" "10.0.0.7,,80.000" \
        "achieved grid row: src 10.0.0.7 -> dst 10.0.0.8" || return 1
    assert_contains "$(cat "$gdir/deficit_grid.csv")" "10.0.0.7,,20.000" \
        "deficit = target - achieved" || return 1
    local res; res=$(cat "$gdir/iperf_results.csv")
    assert_contains "$res" "timestamp,source,target,status" "orchestrator column layout" || return 1
    assert_contains "$res" "10.0.0.7,10.0.0.8,OK,TCP,30,1" "rx row became a sweep row" || return 1
    # The advertised commands must actually work: real make-pivot over it.
    run_orch -o "$TEST_TMPDIR" --run-id gridout make-pivot
    assert_status 0 "$RUN_RC" "make-pivot over grid output" || { echo "$RUN_OUT"; return 1; }
    [ -f "$gdir/iperf_pivot.txt" ] || { echo "no pivot written"; return 1; }
    assert_contains "$(cat "$gdir/iperf_pivot.txt")" "80.0" "achieved rate in pivot" || return 1
}

test_udp_request_response_mode() {
    # --respond-bytes: every request datagram gets a sized reply, and the
    # requester reports pps, answered fraction, and sampled RTT per flow.
    _write_hosts
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/hosts.txt" --rate-mbps 2 \
        -o "$TEST_TMPDIR/matrix.csv" >/dev/null
    local rep="$TEST_TMPDIR/rrrep"
    python3 "$AGENT" run --matrix "$TEST_TMPDIR/matrix.csv" --hostname beta \
        --protocol udp --udp-payload 60 --respond-bytes 500 \
        --interval 1 --duration 4 --report-dir "$rep" >/dev/null 2>&1 &
    local bpid=$!
    python3 "$AGENT" run --matrix "$TEST_TMPDIR/matrix.csv" --hostname alpha \
        --protocol udp --udp-payload 60 --respond-bytes 500 \
        --interval 1 --duration 4 --report-dir "$rep" >/dev/null 2>&1
    wait "$bpid" 2>/dev/null
    local tx; tx=$(grep ",tx," "$rep/alpha_agent.csv" | tail -n 1)
    assert_contains "$tx" "pps=" "tx rows carry packet rate" || return 1
    assert_contains "$tx" "resp_pct=" "answered fraction reported" || return 1
    assert_contains "$tx" "rtt_ms=" "sampled RTT reported" || return 1
    local pct; pct=$(echo "$tx" | grep -o "resp_pct=[0-9.]*" | cut -d= -f2)
    awk -v p="$pct" 'BEGIN { exit !(p >= 50) }' \
        || { echo "resp_pct too low on loopback: $pct"; return 1; }
    assert_contains "$(grep ",rx," "$rep/alpha_agent.csv" | tail -n 1)" "pps=" \
        "rx rows carry packet rate" || return 1
}

test_rates_above_17gbps_do_not_kill_flows() {
    # Regression: rates over ~17.2 Gbps overflowed the C int in the
    # SO_MAX_PACING_RATE setsockopt; CPython retried the argument as a
    # buffer and raised TypeError, killing every sender thread right
    # after connect -- tx dead, peers=0 fleet-wide. The value is now
    # packed as an explicit clamped u32.
    _write_hosts
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/hosts.txt" --rate-mbps 20000 \
        -o "$TEST_TMPDIR/matrix.csv" >/dev/null
    local rep="$TEST_TMPDIR/hirate"
    python3 "$AGENT" run --matrix "$TEST_TMPDIR/matrix.csv" --hostname beta \
        --interval 1 --duration 3 --report-dir "$rep" \
        > "$TEST_TMPDIR/hib.out" 2>&1 &
    local bpid=$!
    local out rc
    out=$(python3 "$AGENT" run --matrix "$TEST_TMPDIR/matrix.csv" --hostname alpha \
        --interval 1 --duration 3 --report-dir "$rep" 2>&1); rc=$?
    wait "$bpid" 2>/dev/null
    assert_status 0 "$rc" "high-rate run should exit cleanly" || { echo "$out"; return 1; }
    case "$out$(cat "$TEST_TMPDIR/hib.out")" in
        *"FLOW DIED"*|*Traceback*) echo "sender thread crashed:"; echo "$out"; return 1 ;;
    esac
    assert_contains "$out" "peers=1" "traffic must actually arrive" || return 1
}

test_agent_rejects_unknown_hostname() {
    _write_hosts
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/hosts.txt" --rate-mbps 10 \
        -o "$TEST_TMPDIR/matrix.csv" >/dev/null
    local out rc
    out=$(python3 "$AGENT" run --matrix "$TEST_TMPDIR/matrix.csv" \
        --hostname nosuch --duration 1 2>&1); rc=$?
    [ "$rc" -ne 0 ] || { echo "unknown hostname should fail"; return 1; }
    assert_contains "$out" "not in matrix" || return 1
}

run_test test_gen_writes_grid_matrix
run_test test_check_flags_inadmissible_matrix
run_test test_two_agents_sustain_target_rate
run_test test_hosts_accepts_bare_ip_tokens
run_test test_run_auto_identifies_by_local_address
run_test test_run_rejects_ambiguous_local_addresses
run_test test_bind_pins_traffic_iperf_orchestrator_style
run_test test_summarize_grid_feeds_sweep_tooling
run_test test_udp_request_response_mode
run_test test_rates_above_17gbps_do_not_kill_flows
run_test test_agent_rejects_unknown_hostname

report_tests
