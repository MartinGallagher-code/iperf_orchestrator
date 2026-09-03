#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for `create-scripts`: per-host run script generation, balanced
# load summary, and that the generated scripts are syntactically valid
# bash that uses the right targets.
#
# Generated script names embed both <host>_<run-id> so $REMOTE_DIR can
# safely live on a shared filesystem.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# Helper: scripts dir for the active RUN_ID.
scripts_dir() { echo "$RESULTS_BASE/$IPERF_RUN_ID/scripts"; }

write_servers_only() {
    write_server_list "$@" >/dev/null
}

test_create_scripts_generates_one_script_per_host() {
    write_servers_only h0 h1 h2 h3
    run_orch create-scripts
    assert_status 0 "$RUN_RC" "create-scripts should succeed" || return 1
    local sd; sd=$(scripts_dir)
    for h in h0 h1 h2 h3; do
        assert_file_exists "$sd/run_${h}_${IPERF_RUN_ID}.sh" "missing script for $h" || return 1
    done
    local n
    n=$(find "$sd" -maxdepth 1 -name "run_*_${IPERF_RUN_ID}.sh" | wc -l)
    assert_eq "4" "$n" "should generate exactly 4 scripts" || return 1
}

test_generated_scripts_are_valid_bash_syntax() {
    write_servers_only host-a host-b host-c host-d host-e
    run_orch create-scripts
    assert_status 0 "$RUN_RC" || return 1
    local s
    for s in "$(scripts_dir)"/run_*.sh; do
        bash -n "$s" || { echo "syntax error in $s" >&2; cat "$s" >&2; return 1; }
    done
}

test_generated_scripts_are_executable() {
    write_servers_only h0 h1 h2
    run_orch create-scripts
    assert_status 0 "$RUN_RC" || return 1
    local s
    for s in "$(scripts_dir)"/run_*.sh; do
        [ -x "$s" ] || { echo "$s is not executable" >&2; return 1; }
    done
}

test_generated_script_targets_are_balanced() {
    # Full-mesh client fan-out: every host targets every other host, so
    # each host runs N-1 clients and total directed edges = N*(N-1).
    # For N=5: every host has 4 targets, 20 directed tests total.
    write_servers_only alpha bravo charlie delta echo
    run_orch create-scripts
    assert_status 0 "$RUN_RC" || return 1
    assert_contains "$RUN_OUT" "Client load: min=4, max=4" \
        "expected every host to target N-1=4 peers" || return 1
    assert_contains "$RUN_OUT" "total tests=20" "20 directed edges for N=5" || return 1

    local total=0 s line
    for s in "$(scripts_dir)"/run_*.sh; do
        line=$(grep -E '^TARGETS=\(' "$s")
        local count
        count=$(echo "$line" | tr -cd '"' | wc -c)
        count=$((count / 2))
        total=$((total + count))
    done
    assert_eq "20" "$total" "sum of TARGETS across all scripts should be 20" || return 1
}

test_generated_script_does_not_target_self() {
    write_servers_only h0 h1 h2 h3
    run_orch create-scripts >/dev/null 2>&1
    local s host base
    for s in "$(scripts_dir)"/run_*.sh; do
        base=$(basename "$s" .sh)
        # filename: run_<host>_<run-id>
        host="${base#run_}"
        host="${host%_${IPERF_RUN_ID}}"
        if grep -E '^TARGETS=\(' "$s" | grep -qF "\"$host\""; then
            echo "$host appears in its own TARGETS list" >&2
            grep -E '^TARGETS=\(' "$s" >&2
            return 1
        fi
    done
}

test_generated_script_is_unidirectional_with_csv_output() {
    # The new design uses unidirectional iperf invocations (no --full-duplex)
    # and tags each log with full_duplex=0 so parse-csv emits exactly one
    # row per log.
    write_servers_only h0 h1 h2
    run_orch create-scripts >/dev/null 2>&1
    local s
    for s in "$(scripts_dir)"/run_*.sh; do
        if grep -E '^TARGETS=\( "[^"]+"' "$s" >/dev/null; then
            if grep -q -- '--full-duplex' "$s"; then
                echo "unexpected --full-duplex in $s" >&2; return 1
            fi
            grep -q 'full_duplex=0' "$s" || { echo "expected full_duplex=0 header in $s" >&2; return 1; }
            grep -q -- '-y C' "$s" || { echo "expected '-y C' in $s" >&2; return 1; }
            grep -q -- '-e' "$s" || { echo "expected '-e' in $s" >&2; return 1; }
            return 0
        fi
    done
    echo "no script had targets to inspect" >&2
    return 1
}

test_generated_script_writes_pair_header() {
    write_servers_only h0 h1 h2
    run_orch create-scripts >/dev/null 2>&1
    local s
    for s in "$(scripts_dir)"/run_*.sh; do
        if grep -E '^TARGETS=\( "[^"]+"' "$s" >/dev/null; then
            grep -q 'pair_a=' "$s" || return 1
            grep -q 'pair_b=' "$s" || return 1
            return 0
        fi
    done
}

test_generated_script_sets_correct_constants() {
    write_servers_only h0 h1
    IPERF_PORT=6000 IPERF_DURATION=15 IPERF_STREAMS=3 \
        run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$(scripts_dir)" -name 'run_*.sh' | head -n1)
    grep -q '^PORT=6000$' "$s" || { echo "PORT not propagated" >&2; cat "$s" >&2; return 1; }
    grep -q '^DURATION=15$' "$s" || return 1
    grep -q '^PARALLEL=3$' "$s" || return 1
    grep -q "^RUN_ID=\"$IPERF_RUN_ID\"$" "$s" || { echo "RUN_ID not embedded" >&2; return 1; }
}

test_create_scripts_sanitizes_ipv6_filenames() {
    write_servers_only '[fe80::1]' '[fe80::2]'
    run_orch create-scripts
    assert_status 0 "$RUN_RC" "create-scripts should accept bracketed IPv6" || return 1
    local sd; sd=$(scripts_dir)
    assert_file_exists "$sd/run__fe80__1__${IPERF_RUN_ID}.sh" "missing sanitized script" || return 1
    assert_file_exists "$sd/run__fe80__2__${IPERF_RUN_ID}.sh" "missing sanitized script" || return 1
    grep -qF 'SOURCE="[fe80::1]"' "$sd/run__fe80__1__${IPERF_RUN_ID}.sh" || return 1
    grep -qF 'SOURCE="[fe80::2]"' "$sd/run__fe80__2__${IPERF_RUN_ID}.sh" || return 1
    if ! grep -hqF '"[fe80::1]"' "$sd"/run__fe80__*.sh \
       || ! grep -hqF '"[fe80::2]"' "$sd"/run__fe80__*.sh; then
        echo "expected both peers' raw hostnames to appear across the two scripts" >&2
        return 1
    fi
}

test_generated_script_outputs_run_id_suffixed_filenames() {
    write_servers_only h0 h1 h2
    run_orch create-scripts >/dev/null 2>&1
    local s
    for s in "$(scripts_dir)"/run_*.sh; do
        if grep -E '^TARGETS=\( "[^"]+"' "$s" >/dev/null; then
            # Output paths must include both host and run-id.
            grep -q "iperf_test_\${SOURCE_SAFE}_to_\${target_safe}_\${RUN_ID}.log" "$s" || {
                echo "client log filename missing run-id suffix in $s" >&2
                return 1
            }
            grep -q "cpu_\${SOURCE_SAFE}_\${RUN_ID}.log" "$s" || {
                echo "cpu log filename missing run-id suffix in $s" >&2
                return 1
            }
            grep -q "iperf_run_\${SOURCE_SAFE}_\${RUN_ID}.status" "$s" || {
                echo "status filename missing run-id suffix in $s" >&2
                return 1
            }
            return 0
        fi
    done
    return 1
}

test_generated_script_includes_iperf_perf_flags() {
    write_servers_only h0 h1
    IPERF_BANDWIDTH=100M IPERF_LENGTH=128K IPERF_WINDOW=4M IPERF_MSS=1448 IPERF_NO_NAGLE=1 \
        run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$(scripts_dir)" -name 'run_*.sh' | head -n1)
    grep -q -- '-b 100M' "$s" || { echo "missing -b 100M" >&2; cat "$s" >&2; return 1; }
    grep -q -- '-l 128K' "$s" || { echo "missing -l 128K" >&2; return 1; }
    grep -q -- '-w 4M'   "$s" || { echo "missing -w 4M"   >&2; return 1; }
    grep -q -- '-M 1448' "$s" || { echo "missing -M 1448" >&2; return 1; }
    grep -q -- ' -N '    "$s" || { echo "missing -N"      >&2; return 1; }
}

test_generated_scripts_handle_synchronized_start() {
    write_servers_only h0 h1 h2
    run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$(scripts_dir)" -name 'run_*.sh' | head -n1)
    grep -q 'START_TIME=' "$s" || return 1
    grep -qE 'sleep .*\$\(\( START_TIME - now \)\)' "$s" || {
        echo "sync-sleep arithmetic missing in $s" >&2
        return 1
    }
}

test_generated_script_includes_bind_resolver_and_arg() {
    # --bind triggers the orchestrator-side peer-IP probe over SSH, so
    # the fake-ssh shim must be on PATH (it returns a synthetic
    # data-plane IP per host). Without it the probe dies and no scripts
    # get generated.
    install_fake_ssh
    write_servers_only h0 h1
    IPERF_BIND="bond0" PATH="$FAKE_BIN:$PATH" \
        run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$(scripts_dir)" -name 'run_*.sh' | head -n1)
    grep -q '^BIND_RAW="bond0"$' "$s" || {
        echo "BIND_RAW not embedded (bond0)" >&2; cat "$s" >&2; return 1
    }
    grep -q 'ip -o -4 addr show' "$s" || {
        echo "missing 'ip -o -4 addr show' resolver" >&2; return 1
    }
    grep -q 'grep -- "\$BIND_RAW"' "$s" || {
        echo "missing grep against BIND_RAW" >&2; return 1
    }
    grep -q 'no interface matched' "$s" || {
        echo "missing no-match error message" >&2; return 1
    }
    grep -qE 'iperf -c .*\$BIND_ARG' "$s" || {
        echo "iperf invocation does not reference \$BIND_ARG" >&2
        grep 'iperf -c' "$s" >&2
        return 1
    }
}

test_generated_script_omits_bind_when_not_set() {
    write_servers_only h0 h1
    run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$(scripts_dir)" -name 'run_*.sh' | head -n1)
    grep -q '^BIND_RAW=""$' "$s" || {
        echo "expected empty BIND_RAW when --bind not set" >&2
        grep '^BIND_RAW=' "$s" >&2
        return 1
    }
}

test_generated_script_writes_cmd_line_to_log() {
    # Each iperf_test_*.log gets a "# cmd: iperf -c ..." line written
    # before iperf runs, so an operator debugging a failed test can
    # copy-paste the exact invocation.
    write_servers_only h0 h1
    run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$(scripts_dir)" -name 'run_*.sh' | head -n1)
    grep -q '^[[:space:]]*echo "# cmd: \$cmd"' "$s" || {
        echo "expected '# cmd:' line emission" >&2; cat "$s" >&2; return 1
    }
    # The assignment may carry the optional timeout wrapper prefix
    # (${TIMEOUT_CMD:+...}) ahead of iperf; what matters is that the
    # logged command is the real invocation against $conn_ip.
    grep -qE '^[[:space:]]*cmd=".*iperf -c \$conn_ip' "$s" || {
        echo "expected cmd= assignment with iperf -c \$conn_ip" >&2
        grep '^[[:space:]]*cmd=' "$s" >&2
        return 1
    }
}

test_generated_script_traps_iperf_failure() {
    # On non-zero exit OR known iperf2 error tokens in output, the
    # script must (a) record exit_status into the log, (b) echo a
    # FAIL line and the inciting cmd to stderr (which lands in the
    # collected per-host log).
    write_servers_only h0 h1
    run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$(scripts_dir)" -name 'run_*.sh' | head -n1)
    grep -q 'connect failed' "$s" || {
        echo "missing 'connect failed' in error-token grep" >&2; return 1
    }
    grep -q 'Connection timed out' "$s" || {
        echo "missing 'Connection timed out' in error-token grep" >&2; return 1
    }
    grep -q 'No route to host' "$s" || {
        echo "missing 'No route to host' in error-token grep" >&2; return 1
    }
    grep -q '\[FAIL\]' "$s" || {
        echo "missing [FAIL] tag in error reporter" >&2; return 1
    }
    grep -q 'echo "# exit_status:' "$s" || {
        echo "missing exit_status logging" >&2; return 1
    }
}

test_generated_script_embeds_bind_metadata_in_log_header() {
    write_servers_only h0 h1
    run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$(scripts_dir)" -name 'run_*.sh' | head -n1)
    grep -q 'bind_iface=\$BIND_IFACE' "$s" || {
        echo "log header missing bind_iface=\$BIND_IFACE" >&2; return 1
    }
    grep -q 'bind_ip=\$BIND_IP' "$s" || {
        echo "log header missing bind_ip=\$BIND_IP" >&2; return 1
    }
}

run_test test_create_scripts_generates_one_script_per_host
run_test test_generated_scripts_are_valid_bash_syntax
run_test test_generated_scripts_are_executable
run_test test_generated_script_targets_are_balanced
run_test test_generated_script_does_not_target_self
run_test test_generated_script_is_unidirectional_with_csv_output
run_test test_generated_script_writes_pair_header
run_test test_generated_script_sets_correct_constants
run_test test_create_scripts_sanitizes_ipv6_filenames
run_test test_generated_script_outputs_run_id_suffixed_filenames
run_test test_generated_script_includes_iperf_perf_flags
run_test test_generated_scripts_handle_synchronized_start
run_test test_generated_script_includes_bind_resolver_and_arg
run_test test_generated_script_omits_bind_when_not_set
run_test test_generated_script_embeds_bind_metadata_in_log_header
run_test test_generated_script_writes_cmd_line_to_log
run_test test_generated_script_traps_iperf_failure

# ---- Login-IP / data-plane NIC mismatch ----------------------------------

test_create_scripts_embeds_target_conn_ips_when_bind_set() {
    # With --bind set, the orchestrator probes every host for its
    # data-plane IP and embeds the resolved per-target IPs into the
    # generated script via the TARGET_CONN_IPS array. iperf -c then
    # connects to that IP instead of the SSH/login IP from servers.txt.
    install_fake_ssh
    write_servers_only host-a host-b host-c
    IPERF_BIND="eth0" PATH="$FAKE_BIN:$PATH" \
        run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$(scripts_dir)" -name 'run_host-a_*.sh' | head -n1)
    [ -f "$s" ] || { echo "no script generated for host-a" >&2; return 1; }
    grep -qE '^TARGET_CONN_IPS=\( "10\.99\.0\.[0-9]+" "10\.99\.0\.[0-9]+" +\)' "$s" || {
        echo "TARGET_CONN_IPS not populated with resolved IPs" >&2
        grep -E '^TARGET_CONN_IPS=' "$s" >&2; return 1
    }
    grep -q 'conn_ip="\${run_conn_ips\[\$ti\]:-\$target}"' "$s" || {
        echo "iperf loop should resolve conn_ip per target" >&2; return 1
    }
    grep -qE 'iperf -c "\$conn_ip"' "$s" || {
        echo "iperf -c should use \$conn_ip, not \$target" >&2
        grep -E 'iperf -c' "$s" >&2; return 1
    }
    grep -q 'conn_ip=\$conn_ip' "$s" || {
        echo "log header should record conn_ip" >&2; return 1
    }
}

test_create_scripts_target_conn_ips_empty_when_bind_unset() {
    # Without --bind, no probe runs and TARGET_CONN_IPS slots are empty
    # so the loop falls back to the login IP from TARGETS.
    write_servers_only h0 h1 h2
    run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$(scripts_dir)" -name 'run_h0_*.sh' | head -n1)
    grep -qE '^TARGET_CONN_IPS=\( "" "" +\)' "$s" || {
        echo "TARGET_CONN_IPS should be all-empty when --bind not set" >&2
        grep -E '^TARGET_CONN_IPS=' "$s" >&2; return 1
    }
}

test_create_scripts_dies_when_peer_bind_pattern_unmatched() {
    # If the bind probe finds nothing on a host, abort up front so the
    # operator fixes the pattern before we generate a full mesh of
    # broken tests.
    install_fake_ssh
    # Override the shim so the probe returns empty output.
    cat > "$FAKE_BIN/ssh" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
    chmod +x "$FAKE_BIN/ssh"
    write_servers_only h0 h1
    IPERF_BIND="nosuch" PATH="$FAKE_BIN:$PATH" run_orch create-scripts
    assert_ne 0 "$RUN_RC" "create-scripts should die when bind probe fails" || return 1
    assert_contains "$RUN_OUT" "no interface matched" \
        "error should explain the unmatched pattern" || return 1
}

run_test test_create_scripts_embeds_target_conn_ips_when_bind_set
run_test test_create_scripts_target_conn_ips_empty_when_bind_unset
run_test test_create_scripts_dies_when_peer_bind_pattern_unmatched

# ---- per-test time limit -------------------------------------------------

test_generated_script_caps_each_test_by_default() {
    # iperf2's -t bounds the send window, but a client that cannot connect
    # sits past it, so every invocation is wrapped in coreutils timeout.
    # The default cap is duration + 30.
    write_servers_only h0 h1
    IPERF_DURATION=10 run_orch create-scripts >/dev/null 2>&1
    local s
    s=$(find "$(scripts_dir)" -name 'run_*.sh' | head -n1)
    grep -q '^TEST_TIMEOUT=40$' "$s" || {
        echo "expected TEST_TIMEOUT=40 (duration 10 + 30)" >&2
        grep '^TEST_TIMEOUT=' "$s" >&2; return 1
    }
    grep -q 'TIMEOUT_CMD="timeout \${TEST_TIMEOUT}s"' "$s" || {
        echo "expected the timeout wrapper to be built" >&2
        grep 'TIMEOUT_CMD' "$s" >&2; return 1
    }
    grep -qE '^[[:space:]]*\$TIMEOUT_CMD iperf -c "\$conn_ip"' "$s" || {
        echo "expected iperf -c to run under \$TIMEOUT_CMD" >&2
        grep 'iperf -c' "$s" >&2; return 1
    }
    # A cap that fired must be legible in the log, not just an exit code.
    grep -q 'killed by test timeout' "$s" || {
        echo "expected a timeout-specific failure message" >&2; return 1
    }
}

test_generated_script_honors_explicit_test_timeout() {
    write_servers_only h0 h1
    run_orch --test-timeout 5 create-scripts >/dev/null 2>&1
    local s
    s=$(find "$(scripts_dir)" -name 'run_*.sh' | head -n1)
    grep -q '^TEST_TIMEOUT=5$' "$s" || {
        echo "expected --test-timeout 5 to reach the script" >&2
        grep '^TEST_TIMEOUT=' "$s" >&2; return 1
    }
}

test_generated_script_test_timeout_zero_disables_the_cap() {
    # 0 means "no cap": the wrapper stays empty, so iperf runs unwrapped.
    write_servers_only h0 h1
    run_orch --test-timeout 0 create-scripts >/dev/null 2>&1
    local s
    s=$(find "$(scripts_dir)" -name 'run_*.sh' | head -n1)
    grep -q '^TEST_TIMEOUT=0$' "$s" || {
        echo "expected TEST_TIMEOUT=0" >&2; grep '^TEST_TIMEOUT=' "$s" >&2; return 1
    }
    # The guard is evaluated on the remote host, so the script must still
    # carry it -- what matters is that 0 takes the empty branch there.
    grep -q 'if \[ "\$TEST_TIMEOUT" -gt 0 \]' "$s" || {
        echo "expected the cap to be guarded on TEST_TIMEOUT > 0" >&2; return 1
    }
}

test_test_timeout_rejects_garbage() {
    write_servers_only h0 h1
    run_orch --test-timeout abc create-scripts
    assert_ne 0 "$RUN_RC" "non-numeric --test-timeout should die" || return 1
    assert_contains "$RUN_OUT" "non-negative integer" || return 1
}

run_test test_generated_script_caps_each_test_by_default
run_test test_generated_script_honors_explicit_test_timeout
run_test test_generated_script_test_timeout_zero_disables_the_cap
run_test test_test_timeout_rejects_garbage

report_tests
