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
    # The responder is given a longer duration than the requester on
    # purpose: with equal durations beta exits first (it starts first),
    # and alpha's final interval then honestly records zero replies --
    # which the assertions below, reading the last tx row, would read as
    # a broken reply path.
    python3 "$AGENT" run --matrix "$TEST_TMPDIR/matrix.csv" --hostname beta \
        --protocol udp --udp-payload 60 --respond-bytes 500 \
        --interval 1 --duration 8 --report-dir "$rep" >/dev/null 2>&1 &
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
    # summarize surfaces the transactional numbers: request+reply packet
    # totals (both directions count), reply bytes, answered %, and RTT.
    local sum; sum=$(python3 "$AGENT" summarize "$rep"/*.csv --window 10)
    assert_contains "$sum" "packets: requests" "packets line present" || return 1
    assert_contains "$sum" "replies" || return 1
    assert_contains "$sum" "answered" || return 1
    assert_contains "$sum" "total delivered" "req+reply totals" || return 1
    assert_contains "$sum" "resp=" "worst flows annotated" || return 1
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

test_stalled_reporter_does_not_burst_impossible_rates() {
    # Regression: when the reporter fell behind (starved thread at high
    # flow counts, stalled disk, suspended process), next_tick advanced
    # by one interval and stayed in the past, so the loop fired every
    # missed slot back to back. Each catch-up tick divided a real byte
    # delta -- data already sitting in socket buffers -- by a
    # millisecond-wide window, printing rates far above the target and
    # writing them into the report CSV, which then poisoned summarize
    # and the grids. SIGSTOP reproduces the stall deterministically.
    _write_hosts
    python3 "$AGENT" gen --hosts "$TEST_TMPDIR/hosts.txt" --rate-mbps 200 \
        -o "$TEST_TMPDIR/matrix.csv" >/dev/null
    local rep="$TEST_TMPDIR/stallrep"
    # --interval 2, not 1: report timestamps have one-second resolution,
    # so at interval 1 two honest ticks can drift into the same second
    # and look like a burst.
    python3 "$AGENT" run --matrix "$TEST_TMPDIR/matrix.csv" --hostname beta \
        --interval 2 --duration 20 --report-dir "$rep" \
        > "$TEST_TMPDIR/stall_b.out" 2>&1 &
    local bpid=$!
    python3 "$AGENT" run --matrix "$TEST_TMPDIR/matrix.csv" --hostname alpha \
        --interval 2 --duration 20 --report-dir "$rep" \
        > "$TEST_TMPDIR/stall_a.out" 2>&1 &
    local apid=$!
    sleep 4
    kill -STOP "$apid"; sleep 8; kill -CONT "$apid"
    wait "$apid" "$bpid" 2>/dev/null
    local ticks; ticks=$(grep '^ts=' "$TEST_TMPDIR/stall_a.out" || true)
    [ -n "$ticks" ] || { echo "no ticker output"; cat "$TEST_TMPDIR/stall_a.out"; return 1; }
    # No tick may claim more than the 200 Mbps target (plus slack): a
    # rate above the offered load can only come from a bad divisor.
    local bad
    bad=$(echo "$ticks" | awk -F'rx=' '{split($2,a,"/"); if (a[1]+0 > 400) print}')
    [ -z "$bad" ] || { echo "impossible rx rate after stall:"; echo "$bad"; return 1; }
    # And the stall must not produce a burst of same-second ticks. The
    # bug replayed every missed slot, so a burst is many ticks deep;
    # three in one second is unreachable by drift at this interval.
    local burst
    burst=$(echo "$ticks" | awk '{c[$1]++} END {for (t in c) if (c[t] >= 3) print t, c[t]}')
    [ -z "$burst" ] || { echo "catch-up tick burst at: $burst"; echo "$ticks"; return 1; }
}

test_summarize_tail_bytes_matches_full_parse() {
    # Reports append for the life of the run but only --window seconds
    # are ever used, so summarize can seek instead of parsing from byte
    # zero. The windowed read must agree with the full read exactly, and
    # must warn -- not silently under-report -- when the tail is too
    # small to cover the requested window.
    local big="$TEST_TMPDIR/bulk_agent.csv"
    python3 - "$big" <<'PY'
import sys
p = sys.argv[1]
with open(p, "w") as f:
    f.write("ts,host,dir,peer,proto,target_mbps,achieved_mbps,bytes,extra\n")
    ts = 1750000000
    for i in range(4000):            # ~4000 intervals of history
        ts += 10
        for peer in ("p1", "p2"):
            f.write("%d,h1,rx,%s,tcp,1000.000,900.000,1125000,\n" % (ts, peer))
            f.write("%d,h1,tx,%s,tcp,1000.000,950.000,1187500,reconnects=0\n" % (ts, peer))
PY
    local full tail
    full=$(python3 "$AGENT" summarize "$big" --window 60 2>/dev/null)
    tail=$(python3 "$AGENT" summarize "$big" --window 60 --tail-bytes 65536 2>/dev/null)
    assert_eq "$full" "$tail" "tail read must match a full parse" || return 1
    # A window wider than the tail covers must say so.
    local warn
    warn=$(python3 "$AGENT" summarize "$big" --window 40000 --tail-bytes 4096 2>&1 >/dev/null)
    assert_contains "$warn" "tail-bytes" "short tail must warn, not under-report" || return 1
    # ...and the full read of the same window must not warn.
    warn=$(python3 "$AGENT" summarize "$big" --window 40000 2>&1 >/dev/null)
    case "$warn" in *tail-bytes*) echo "full parse should not warn: $warn"; return 1 ;; esac
}

test_summarize_explains_mismatched_in_out_targets() {
    # A host's "in" target is its matrix column, read from its own rx
    # rows. Its "out" target is its matrix row, assembled from its
    # *receivers'* rx rows -- so it is only as complete as the set of
    # reports collected. When an agent is down its senders' "out"
    # targets silently shrink (in 285/300 but out 190/200 for the same
    # uniform matrix), which reads as an asymmetric matrix unless the
    # summary says which host is missing.
    local d="$TEST_TMPDIR/mismatch"
    mkdir -p "$d"
    python3 - "$d" <<'PY'
import os, sys
d = sys.argv[1]
hosts = ["a", "b", "c", "dead"]
ts = 1750000000
for h in hosts:
    if h == "dead":            # agent down: no report collected
        continue
    with open(os.path.join(d, "%s_agent.csv" % h), "w") as f:
        f.write("ts,host,dir,peer,proto,target_mbps,achieved_mbps,bytes,extra\n")
        for i in range(6):
            for p in hosts:
                if p != h:
                    f.write("%d,%s,rx,%s,tcp,100.000,95.000,118750,\n"
                            % (ts + i * 10, h, p))
PY
    local out
    out=$(python3 "$AGENT" summarize "$d"/*_agent.csv --window 60 2>&1)
    assert_contains "$out" "3 of 4 hosts reporting" "coverage stated" || return 1
    assert_contains "$out" "never reported (dead)" "the silent host is named" || return 1
    # The peer counts that produce each side must be visible.
    assert_contains "$out" "in    285.0/300.0" "in is the full column" || return 1
    assert_contains "$out" "out    190.0/200.0" "out is short by the dead host" || return 1
    # A zero target is missing data, not a healthy 100%.
    case "$out" in *"0.0/0.0      (100%)"*) echo "zero target shown as 100%"; return 1 ;; esac
    assert_contains "$out" "n/a" "zero target reads n/a" || return 1
}

test_summarize_reports_per_host_packet_rates() {
    # "How many packets is each server receiving?" -- the rx rows carry
    # pps in UDP mode, but summarize only ever totalled them fleet-wide.
    # Both directions come from receiver-side counters, so a host's "out"
    # packet rate is what its peers actually received from it.
    local d="$TEST_TMPDIR/pph"
    mkdir -p "$d"
    python3 - "$d" <<'PY'
import os, sys
d = sys.argv[1]
hosts = ["h1", "h2", "h3"]
ts = 1750000000
for h in hosts:
    with open(os.path.join(d, "%s_agent.csv" % h), "w") as f:
        f.write("ts,host,dir,peer,proto,target_mbps,achieved_mbps,bytes,extra\n")
        for i in range(6):
            for p in hosts:
                if p == h:
                    continue
                # h3 receives far fewer packets than the others.
                pps = 40000 if h != "h3" else 12000
                f.write("%d,%s,rx,%s,udp,500.000,480.000,600000,pps=%d\n"
                        % (ts + i * 10, h, p, pps))
PY
    local out; out=$(python3 "$AGENT" summarize "$d"/*_agent.csv --window 60 2>&1)
    assert_contains "$out" "pkt/s in|out" "packet columns announced" || return 1
    # h1 receives 2 x 40000 in; its peers received 40000 + 12000 = 52000 out.
    assert_contains "$out" "80000|52000" "h1/h2 in and out packet rates" || return 1
    # h3 is the starved receiver: 2 x 12000 in, but sends fine (2 x 40000).
    assert_contains "$out" "24000|80000" "h3's inbound deficit is visible" || return 1

    # TCP has no datagram to count, so the columns must be absent rather
    # than printing zeros that would read as "no packets arriving".
    local t="$TEST_TMPDIR/pph_tcp"
    mkdir -p "$t"
    {
        echo "ts,host,dir,peer,proto,target_mbps,achieved_mbps,bytes,extra"
        echo "1750000010,h1,rx,h2,tcp,500.000,480.000,600000,"
    } > "$t/h1_agent.csv"
    out=$(python3 "$AGENT" summarize "$t"/*_agent.csv --window 60 2>&1)
    case "$out" in *"pkt/s"*) echo "packet columns shown for TCP"; return 1 ;; esac
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
run_test test_stalled_reporter_does_not_burst_impossible_rates
run_test test_summarize_tail_bytes_matches_full_parse
run_test test_summarize_explains_mismatched_in_out_targets
run_test test_summarize_reports_per_host_packet_rates
run_test test_agent_rejects_unknown_hostname

report_tests
