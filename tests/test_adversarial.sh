#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# Hostile input on the fleet side (shared_tools IO-001). Each test runs a
# real command against the sandbox ssh (test_helper.bash), which runs the
# remote snippets and the generated run scripts for real, one root per
# fake host, so these check what reaches a host, not only the text.
#
# The injected commands only ever `touch MARK_*`, a file name with no
# directory part, so wherever it would run it lands inside the sandbox;
# assert_no_marker looks for it anywhere under the test's temp dir.
#
# Every test here failed on 2.6.3, and tests/test_adversarial_mutations.sh
# reverts each fix in a copy of the script and shows its test failing.
# ADV_ONLY=<test name> runs just that test (the mutation file uses it).

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

orch() { PATH="$FAKE_BIN:$PATH" run_orch "$@"; }

assert_no_marker() {
    local found
    found=$(find "$TEST_TMPDIR" -name 'MARK_*' 2>/dev/null)
    [ -z "$found" ] && return 0
    printf 'INJECTED: a hostile value ran as a command (on a host, or here); marker(s):\n%s\n' "$found" >&2
    printf -- '--- orchestrator output ---\n%s\n' "${RUN_OUT:-}" >&2
    return 1
}

# The argv one sandboxed `iperf -c` got, %q-quoted, for the client run on HOST.
iperf_argv_from() { awk -F'\t' -v h="$1" '$1 == h {print $2}' "$SANDBOX_ROOT/iperf_clients.log"; }

sandbox_two_hosts() {
    install_sandbox_ssh
    write_server_list "$@" >/dev/null
}

# ---- Values pasted into ssh snippets ---------------------------------------

test_remote_dir_quote_reaches_host_literally_in_cleanup() {
    sandbox_two_hosts h1 h2
    # Relative, so each host's copy lives in its own root.
    local rd="work';touch MARK_rd;'"
    local h
    for h in h1 h2; do mkdir -p "$(sandbox_host_root "$h")/$rd" && touch "$(sandbox_host_root "$h")/$rd/f"; done
    REMOTE_DIR="$rd" orch cleanup --yes
    assert_no_marker || return 1
    for h in h1 h2; do
        [ ! -e "$(sandbox_host_root "$h")/$rd" ] || { echo "$h: the oddly named REMOTE_DIR was not removed" >&2; return 1; }
    done
}

test_server_bind_quote_reaches_host_literally() {
    sandbox_two_hosts h1 h2
    orch --server-bind "x';touch MARK_sb;'" start-servers
    assert_no_marker || return 1
    # The literal value is matched against the interfaces, finds none, and
    # says so in its own words.
    assert_contains "$RUN_OUT" "no interface matched 'x';touch MARK_sb;''" || return 1
}

test_bind_quote_reaches_host_literally_in_peer_probe() {
    sandbox_two_hosts h1 h2
    orch --bind "x';touch MARK_b;'" create-scripts
    assert_no_marker || return 1
    assert_ne 0 "$RUN_RC" "an unmatched --bind should still fail" || return 1
}

test_run_id_metacharacters_stay_literal_in_collect() {
    sandbox_two_hosts h1 h2
    local rid='r;touch MARK_rid;'
    orch --run-id "$rid" create-scripts
    mkdir -p "$REMOTE_DIR"
    orch --run-id "$rid" collect-results
    assert_no_marker
}

test_run_id_with_a_space_does_not_delete_files_on_the_host() {
    sandbox_two_hosts h1 h2
    local h
    for h in h1 h2; do mkdir -p "$(sandbox_host_root "$h")" && echo notes > "$(sandbox_host_root "$h")/run.log"; done
    REMOTE_DIR=work orch --run-id 'nightly run' create-scripts
    REMOTE_DIR=work orch --run-id 'nightly run' distribute-scripts
    assert_status 0 "$RUN_RC" "distribute-scripts" || return 1
    for h in h1 h2; do
        [ -f "$(sandbox_host_root "$h")/run.log" ] || { echo "$h: ~/run.log was deleted by the run-id glob" >&2; return 1; }
        [ -x "$(sandbox_host_root "$h")/work/run_iperf_${h}_nightly run.sh" ] || { echo "$h: run script not delivered" >&2; return 1; }
    done
}

test_run_id_glob_does_not_delete_other_runs_logs() {
    sandbox_two_hosts h1 h2
    mkdir -p "$REMOTE_DIR" && touch "$REMOTE_DIR/iperf_test_a_to_b_otherrun.log"
    orch --run-id '*' create-scripts
    orch --run-id '*' distribute-scripts
    [ -f "$REMOTE_DIR/iperf_test_a_to_b_otherrun.log" ] || { echo "another run's log was deleted" >&2; return 1; }
}

test_status_progress_keeps_run_id_literal() {
    sandbox_two_hosts h1 h2
    mkdir -p "$REMOTE_DIR"
    orch --run-id 'r;touch MARK_st;' status
    assert_no_marker
}

test_sequential_pair_target_stays_literal() {
    sandbox_two_hosts h1 "h2';touch MARK_t;'"
    orch --start-delay 0 --duration 1 run-tests sequential-pair
    assert_no_marker
}

# ---- Values written into the generated run scripts -------------------------

test_hostile_host_reaches_iperf_as_one_literal_argument() {
    sandbox_two_hosts h1 'h2$(touch MARK_h)`touch MARK_h2`'
    orch --start-delay 0 --duration 1 run-tests parallel
    assert_no_marker || return 1
    local s
    for s in "$RESULTS_BASE/$IPERF_RUN_ID"/scripts/*.sh; do
        bash -n "$s" || { echo "generated script does not parse: $s" >&2; return 1; }
    done
    assert_contains "$(iperf_argv_from h1)" "-c h2\\\$\\(touch\\ MARK_h\\)\\\`touch\\ MARK_h2\\\`" \
        "h1 should connect to the hostile name as one literal word" || return 1
}

test_hostile_bandwidth_reaches_iperf_as_literal_words() {
    sandbox_two_hosts h1 h2
    orch --start-delay 0 --duration 1 --bandwidth '1g;touch MARK_bw;true' run-tests parallel
    assert_no_marker || return 1
    # Split on whitespace as always, but each word literal.
    assert_contains "$(iperf_argv_from h1)" "-b 1g\\;touch MARK_bw\\;true " || return 1
}

test_bandwidth_with_spaces_still_splits_into_words() {
    # No change for a value that worked: '-b "1g -N"' was always two words.
    sandbox_two_hosts h1 h2
    orch --start-delay 0 --duration 1 --bandwidth '1g -N' --length 128K run-tests parallel
    assert_contains "$(iperf_argv_from h1)" "-b 1g -N -l 128K " || return 1
    # ...and the script text is what it always was for plain values.
    grep -qF -- '-P "$PARALLEL" -b 1g -N -l 128K $BIND_ARG -e -y C' \
        "$RESULTS_BASE/$IPERF_RUN_ID/scripts/run_h1_$IPERF_RUN_ID.sh" \
        || { echo "plain values should be written exactly as before" >&2; return 1; }
}

test_rolling_hostile_host_stays_literal() {
    sandbox_two_hosts h1 'h2$(touch MARK_rh)'
    # 3s: the loop's startup jitter alone can take most of a second.
    orch --duration 1 --total-time 3 run-tests rolling
    assert_no_marker || return 1
    assert_contains "$(iperf_argv_from h1)" "-c h2\\\$\\(touch\\ MARK_rh\\)" || return 1
}

test_rolling_hostile_bandwidth_stays_literal() {
    sandbox_two_hosts h1 h2
    orch --duration 1 --total-time 3 --bandwidth '1g;touch MARK_rbw;true' run-tests rolling
    assert_no_marker || return 1
    assert_contains "$(iperf_argv_from h1)" "-b 1g\\;touch MARK_rbw\\;true " || return 1
}

# Bash before 5.2 expands an associative-array subscript a second time
# inside $((...)), so a host name's $(...) ran there even once quoted.
# BASH_COMPAT=50 makes a newer bash do the same (CI's Python 3.6 image has
# bash 5.1 and caught it); it applies to the sandboxed hosts and to the
# orchestrator itself.
test_rolling_hostile_host_stays_literal_on_older_bash() {
    sandbox_two_hosts h1 'h2$(touch MARK_rh50)'
    BASH_COMPAT=50 orch --duration 1 --total-time 3 run-tests rolling
    assert_no_marker || return 1
    assert_contains "$(iperf_argv_from h1)" "-c h2\\\$\\(touch\\ MARK_rh50\\)" || return 1
}

grid_with_hostile_host() {
    install_fake_ssh
    # No whitespace: the grid reader strips it from a row's name.
    printf '%s\n' 'src\dst,h1,h2$(:>MARK_grid)' 'h1,,x' 'h2$(:>MARK_grid),x,' > "$IPERF_SERVERS"
}

test_grid_host_name_stays_literal_in_hints_on_older_bash() {
    grid_with_hostile_host
    BASH_COMPAT=50 orch hints
    assert_no_marker || return 1
    assert_contains "$RUN_OUT" "2 directed tests" || return 1
}

test_grid_host_name_stays_literal_in_gen_on_older_bash() {
    grid_with_hostile_host
    BASH_COMPAT=50 orch gen --grid
    assert_no_marker || return 1
    assert_contains "$RUN_OUT" "2 enabled pair(s)" || return 1
}

test_newline_in_run_id_cannot_add_a_line_to_run_script() {
    sandbox_two_hosts h1 h2
    local rid=$'r\ntouch MARK_nl'
    orch --run-id "$rid" --start-delay 0 --duration 1 run-tests parallel
    assert_no_marker || return 1
    if grep -qx 'touch MARK_nl' "$RESULTS_BASE/$rid"/scripts/*.sh; then
        echo "the run id's second line became a line of the run script" >&2; return 1
    fi
}

# Every fleet command, a hostile value in every place a value goes. No
# spaces in the payloads: _sanitize_host turns a space into '_', and a
# payload that sanitizing breaks would hide a missing quote. REMOTE_DIR is
# absolute (shared by the hosts, as on NFS), so collect-results really
# collects and every step after it runs.
test_no_fleet_command_runs_a_hostile_value() {
    install_sandbox_ssh
    write_server_list h1 'h2$(>MARK_any_h2)' "h3'\$(>MARK_any_h3)'" >/dev/null
    # Quotes in pairs: a value with one quote makes a reverted '...' site a
    # syntax error rather than a command, and the test would miss it.
    export REMOTE_DIR="$TEST_TMPDIR/rd'\$(>MARK_any_rd)'x"
    local rid="r'\$(>MARK_any_rid)'q" cmd
    for cmd in check-iperf check-servers "--server-bind eth0 start-servers" \
               "--server-bind nosuch start-servers" create-scripts distribute-scripts \
               "run-tests parallel" "run-tests sequential-host" "run-tests sequential-pair" \
               "run-tests rolling" status collect-results stop-servers "cleanup --yes" clean; do
        # shellcheck disable=SC2086
        orch --run-id "$rid" --start-delay 0 --duration 1 --total-time 3 $cmd
        assert_no_marker || { echo "  (after: $cmd)" >&2; return 1; }
        if [ "$cmd" = collect-results ]; then
            # Every mode above wrote logs under this run id; any count but 0.
            assert_contains "$RUN_OUT" " client logs total" || return 1
            assert_not_contains "$RUN_OUT" "Collected 0 client logs" "collect-results must really collect" || return 1
        fi
    done
    orch --run-id "$rid" --start-delay 0 --duration 1 --single-server 'h2$(>MARK_any_h2)' run-tests sequential-host
    assert_no_marker || { echo "  (after: --single-server)" >&2; return 1; }
}

# --bind on a compromised host: the address its `ip` prints goes into every
# other host's run script (and the rolling loop) as the address to test.
test_compromised_hosts_ip_output_stays_literal() {
    sandbox_two_hosts h1 h2
    cat > "$SANDBOX_BIN/ip" <<'SHIM'
#!/usr/bin/env bash
. "$SANDBOX_BIN/.prelude"
if [ "$_host" = h2 ]; then
    echo '2: eth0    inet 10.0.0.2"$(>MARK_ip)"/24 scope global eth0'
else
    echo '2: eth0    inet 10.0.0.1/24 scope global eth0'
fi
SHIM
    orch --bind eth0 --start-delay 0 --duration 1 run-tests parallel
    assert_no_marker || return 1
    orch --bind eth0 --duration 1 --total-time 3 run-tests rolling
    assert_no_marker
}

# A --bind pattern is a grep regex, so a hostile one can still match an
# interface; then it is written into the run scripts and the rolling loop.
test_hostile_bind_pattern_that_matches_stays_literal() {
    sandbox_two_hosts h1 h2
    local pat='eth0\|$(>MARK_br)'
    orch --bind "$pat" --start-delay 0 --duration 1 run-tests parallel
    assert_no_marker || return 1
    assert_contains "$(iperf_argv_from h1)" "-B 10.99.0." "the pattern should still bind" || return 1
    orch --bind "$pat" --duration 1 --total-time 3 run-tests rolling
    assert_no_marker
}

# The iperf values also go into the logged "# cmd:" line, inside "...".
test_extra_args_substitution_stays_literal_in_logged_cmd() {
    sandbox_two_hosts h1 h2
    orch --bandwidth '1g$(>MARK_cmd)' --start-delay 0 --duration 1 run-tests parallel
    assert_no_marker || return 1
    orch --bandwidth '1g$(>MARK_cmd)' --duration 1 --total-time 3 run-tests rolling
    assert_no_marker
}

# ---- Transport --------------------------------------------------------------

test_ssh_destination_follows_double_dash() {
    install_fake_ssh
    write_server_list h1 h2 >/dev/null
    # Record ssh's argv exactly.
    cat > "$FAKE_BIN/ssh" <<'SHIM'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$FAKE_BIN/argv.log"; echo >> "$FAKE_BIN/argv.log"
SHIM
    chmod +x "$FAKE_BIN/ssh"
    SSH_USER='-oProxyCommand=touch MARK_pc' orch check-servers
    # ssh must see the user@host as the destination (after --), never as
    # an option, or the ProxyCommand would run on this machine.
    grep -q -- '-- -oProxyCommand=touch\\ MARK_pc@h1 ' "$FAKE_BIN/argv.log" \
        || { echo "destination not preceded by --:" >&2; cat "$FAKE_BIN/argv.log" >&2; return 1; }
}

test_ssh_gets_bracketed_ipv6_without_brackets() {
    install_fake_ssh
    write_server_list '[fe80::1]' 2001:db8::1 >/dev/null
    orch check-servers
    assert_contains "$(cut -f2 "$FAKE_SSH_LOG" | sort -u | tr '\n' ' ')" "fe80::1 " || return 1
    assert_not_contains "$(cut -f2 "$FAKE_SSH_LOG")" "[fe80::1]" "ssh cannot resolve a bracketed name" || return 1
}

test_scp_gets_bare_ipv6_in_brackets() {
    install_fake_ssh
    write_server_list 2001:db8::1 '[fe80::1]' >/dev/null
    orch create-scripts >/dev/null
    orch distribute-scripts
    local dsts; dsts=$(awk -F'\t' '$1 == "scp" {print $3}' "$FAKE_SSH_LOG")
    assert_contains "$dsts" "testuser@[2001:db8::1]:" "scp splits a bare IPv6 address at its first colon" || return 1
    assert_contains "$dsts" "testuser@[fe80::1]:" || return 1
}

# The same, against the real OpenSSH client when it is installed: which
# host would ssh and scp connect to? A ProxyCommand logs it and fails.
test_real_ssh_and_scp_reach_the_right_ipv6_host() {
    command -v ssh >/dev/null && command -v scp >/dev/null || { echo "(no ssh/scp: skipped)"; return 0; }
    write_server_list 2001:db8::1 '[fe80::1]' >/dev/null
    cat > "$TEST_TMPDIR/proxylog" <<'P'
#!/bin/sh
echo "$1" >> "$(dirname "$0")/proxy.log"; exit 1
P
    chmod +x "$TEST_TMPDIR/proxylog"
    printf 'ProxyCommand %s %%h\n' "$TEST_TMPDIR/proxylog" > "$TEST_TMPDIR/sshcfg"
    : > "$TEST_TMPDIR/proxy.log"
    SSH_OPTS="-F $TEST_TMPDIR/sshcfg" run_orch create-scripts >/dev/null
    SSH_OPTS="-F $TEST_TMPDIR/sshcfg" run_orch distribute-scripts
    SSH_OPTS="-F $TEST_TMPDIR/sshcfg" run_orch check-servers
    # distribute stops at its ssh step when that fails, so drive scp too.
    SSH_OPTS="-F $TEST_TMPDIR/sshcfg" SSH_USER=testuser bash -c \
        'source "$ORCH" help >/dev/null 2>&1; scp_to /dev/null 2001:db8::1 /tmp/x; scp_to /dev/null "[fe80::1]" /tmp/x' >/dev/null 2>&1
    local seen; seen=$(sort -u "$TEST_TMPDIR/proxy.log" | tr '\n' ' ')
    assert_eq "2001:db8::1 fe80::1 " "$seen" "hosts real ssh/scp tried" || return 1
}

test_remote_path_with_shell_characters_goes_over_ssh_not_scp() {
    sandbox_two_hosts h1 h2
    # scp before OpenSSH 9.0 would hand this path to the remote shell.
    local rd='work/d$(touch MARK_scp)'
    REMOTE_DIR="$rd" orch create-scripts
    REMOTE_DIR="$rd" orch distribute-scripts
    assert_status 0 "$RUN_RC" "distribute-scripts" || return 1
    assert_no_marker || return 1
    if awk -F'\t' '$1 == "scp"' "$FAKE_SSH_LOG" | grep -qF 'MARK_scp'; then
        echo "scp was given a remote path holding \$(...)" >&2; return 1
    fi
    [ -x "$(sandbox_host_root h1)/$rd/run_iperf_h1_$IPERF_RUN_ID.sh" ] \
        || { echo "run script not delivered over ssh" >&2; return 1; }
}

# ---- collect-results: what a host's tarball may put on this machine --------

test_collect_keeps_only_regular_run_files() {
    sandbox_two_hosts h1
    mkdir -p "$REMOTE_DIR" && echo ok > "$REMOTE_DIR/iperf_test_h1_to_h2_$IPERF_RUN_ID.log"
    # A compromised host: its tar hands back a tarball of its own making.
    local craft="$TEST_TMPDIR/craft"
    mkdir -p "$craft/sub"
    echo good > "$craft/iperf_test_h1_to_h2_$IPERF_RUN_ID.log"
    ln -s /etc/hostname "$craft/iperf_test_h2_to_h1_$IPERF_RUN_ID.log"
    echo forged > "$craft/iperf_pivot.txt"
    echo x > "$craft/sub/cpu_h1_$IPERF_RUN_ID.log"
    tar -czf "$TEST_TMPDIR/evil.tar.gz" -C "$craft" .
    cat > "$SANDBOX_BIN/tar" <<SHIM
#!/usr/bin/env bash
[ "\$1" = "-czf" ] && exec cp "$TEST_TMPDIR/evil.tar.gz" "\$2"
exec $(command -v tar) "\$@"
SHIM
    chmod +x "$SANDBOX_BIN/tar"
    orch create-scripts >/dev/null
    orch collect-results
    local rd="$RESULTS_BASE/$IPERF_RUN_ID"
    [ -f "$rd/iperf_test_h1_to_h2_$IPERF_RUN_ID.log" ] || { echo "the regular log was not kept" >&2; return 1; }
    [ ! -L "$rd/iperf_test_h2_to_h1_$IPERF_RUN_ID.log" ] || { echo "a symlink from the host landed in the results" >&2; return 1; }
    [ ! -e "$rd/iperf_pivot.txt" ] || { echo "the host forged iperf_pivot.txt" >&2; return 1; }
    [ ! -e "$rd/sub" ] && [ ! -e "$rd/cpu_h1_$IPERF_RUN_ID.log" ] || { echo "a directory from the host landed" >&2; return 1; }
    assert_contains "$RUN_OUT" "ignored" "should say what it left out" || return 1
}

test_collect_does_not_fetch_a_stale_tarball() {
    sandbox_two_hosts h1
    mkdir -p "$REMOTE_DIR"
    # Left by an earlier collect (or planted); nothing of this run exists.
    local old="$TEST_TMPDIR/old"; mkdir -p "$old"
    echo stale > "$old/iperf_test_h1_to_h2_$IPERF_RUN_ID.log"
    tar -czf "$REMOTE_DIR/_results_h1_$IPERF_RUN_ID.tar.gz" -C "$old" .
    orch create-scripts >/dev/null
    orch collect-results
    [ ! -e "$RESULTS_BASE/$IPERF_RUN_ID/iperf_test_h1_to_h2_$IPERF_RUN_ID.log" ] \
        || { echo "a tarball this collect did not build was fetched" >&2; return 1; }
}

# ---- Errors -------------------------------------------------------------------

test_create_scripts_fails_when_it_cannot_write_a_script() {
    install_fake_ssh
    write_server_list h1 h2 >/dev/null
    orch --run-id a/b create-scripts
    assert_ne 0 "$RUN_RC" "create-scripts wrote no script and must not report success" || return 1
    assert_contains "$RUN_OUT" "could not write" || return 1
}

# ---- Ctrl-C / SIGTERM -----------------------------------------------------------

test_sigterm_mid_round_stops_promptly_and_leaves_no_local_ssh() {
    # pgrep to count what is left, pkill to clear it up (procps; slim
    # container images lack it).
    command -v pgrep >/dev/null && command -v pkill >/dev/null || { echo "(no pgrep/pkill: skipped)"; return 0; }
    sandbox_two_hosts h1 h2
    export SANDBOX_IPERF_SECONDS=15
    PATH="$FAKE_BIN:$PATH" bash "$ORCH" --start-delay 0 --duration 1 run-tests parallel \
        > "$TEST_TMPDIR/orch.out" 2>&1 &
    local pid=$!
    # Wait until both clients are under way.
    for _ in $(seq 1 100); do
        [ "$(wc -l < "$SANDBOX_ROOT/iperf_clients.log")" -ge 2 ] && break
        sleep 0.1
    done
    local t0=$SECONDS rc
    kill -TERM "$pid"
    wait "$pid"; rc=$?
    local took=$((SECONDS - t0))
    local left; left=$(pgrep -f "$FAKE_BIN/ssh" | wc -l)
    # The remote halves (run scripts) outlive a killed ssh, as they would on
    # a real host; clear them up, scoped to this test's temp dir.
    pkill -f "$TEST_TMPDIR" 2>/dev/null
    assert_eq 130 "$rc" "exit status after SIGTERM" || { cat "$TEST_TMPDIR/orch.out" >&2; return 1; }
    [ "$took" -le 8 ] || { echo "took ${took}s to stop after SIGTERM (the round runs 15s)" >&2; return 1; }
    assert_eq 0 "$left" "local ssh processes still running after exit" || return 1
}

# ---- Added after the independent attack ------------------------------------

test_collect_over_ssh_for_a_path_with_shell_characters() {
    sandbox_two_hosts h1 h2
    export REMOTE_DIR="$TEST_TMPDIR/rd'\$(>MARK_sf)"
    orch --start-delay 0 --duration 1 run-tests parallel
    orch collect-results
    assert_no_marker || return 1
    assert_contains "$RUN_OUT" "Collected 2 client logs" || return 1
    if awk -F'\t' '$1 == "scp"' "$FAKE_SSH_LOG" | grep -qF 'MARK_sf'; then
        echo "scp was given a remote path holding \$(...)" >&2; return 1
    fi
}

test_scp_from_gets_bare_ipv6_in_brackets() {
    install_fake_ssh
    write_server_list 2001:db8::1 >/dev/null
    orch create-scripts >/dev/null
    orch collect-results
    local srcs; srcs=$(awk -F'\t' '$1 == "scp" {print $2}' "$FAKE_SSH_LOG")
    assert_contains "$srcs" "testuser@[2001:db8::1]:" "collect-results' scp of a bare IPv6 host" || return 1
}

test_create_scripts_fails_when_chmod_fails() {
    install_fake_ssh
    write_server_list h1 h2 >/dev/null
    printf '#!/bin/sh\necho "chmod: Operation not permitted" >&2\nexit 1\n' > "$FAKE_BIN/chmod"
    chmod +x "$FAKE_BIN/chmod"
    orch create-scripts
    assert_ne 0 "$RUN_RC" "create-scripts made no script executable and must not report success" || return 1
    assert_contains "$RUN_OUT" "could not make" || return 1
}

# parallel_hosts runs inside run-tests and the interrupt handler, next to
# other background jobs; it must wait for its own workers only.
test_parallel_hosts_waits_only_for_its_own_workers() {
    write_server_list h1 h2 >/dev/null
    # shellcheck disable=SC2034  # read by parallel_hosts (sourced orchestrator)
    SERVER_LIST_FILE="$IPERF_SERVERS"
    _adv_quick() { :; }
    sleep 6 &
    local other=$! t0=$SECONDS
    parallel_hosts _adv_quick
    local took=$((SECONDS - t0))
    kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
    [ "$took" -le 3 ] || { echo "parallel_hosts waited ${took}s for a job that was not its own" >&2; return 1; }
}

# "$(...)" drops trailing newlines: '/x/keep<newline>' must not become
# '/x/keep', a different directory.
test_trailing_newline_in_remote_dir_is_kept() {
    sandbox_two_hosts h1
    local root; root=$(sandbox_host_root h1)
    mkdir -p "$root/keep/data" "$root/keep"$'\n'
    REMOTE_DIR=$'keep\n' orch cleanup --yes
    [ -d "$root/keep/data" ] || { echo "cleanup deleted 'keep', not 'keep<newline>'" >&2; return 1; }
    [ ! -e "$root/keep"$'\n' ] || { echo "the named directory survived" >&2; return 1; }
}

# The orchestrator itself on bash 4.2 (CentOS 7): a literal '\'' in a
# ${var//\'/...} replacement kept its backslashes there.
test_quoting_holds_under_bash_4_2_rules() {
    sandbox_two_hosts h1 h2
    BASH_COMPAT=42 REMOTE_DIR="work';>MARK_42;#" orch cleanup --yes
    assert_no_marker || return 1
    BASH_COMPAT=42 orch --run-id "r'\$(>MARK_42r)'" create-scripts
    BASH_COMPAT=42 orch --run-id "r'\$(>MARK_42r)'" distribute-scripts
    assert_no_marker
}

# In GBK (also Big5, Shift_JIS) a backtick can be the second byte of a
# character, so a locale-aware check on the orchestrator misses it while
# a host in C or UTF-8 sees a backtick.
test_backtick_in_a_gbk_locale_stays_literal() {
    command -v localedef >/dev/null || { echo "(no localedef: skipped)"; return 0; }
    local loc="$TEST_TMPDIR/loc"; mkdir -p "$loc"
    localedef -i zh_CN -f GBK "$loc/zh_CN.GBK" >/dev/null 2>&1 \
        || { echo "(no zh_CN/GBK locale sources: skipped)"; return 0; }
    # 0x81 0x60 is one GBK character, so here both backticks hide.
    sandbox_two_hosts h1 $'h2\x81`>MARK_gbk\x81`'
    LOCPATH="$loc" LC_ALL=zh_CN.GBK SANDBOX_HOST_LC_ALL=C orch --start-delay 0 --duration 1 run-tests parallel
    assert_no_marker
}

# A compromised host's tarball may hold any test log of this run (on a
# shared REMOTE_DIR each host lists them all), but its own server log,
# status and cpu files only, and nothing of another run.
test_collect_keeps_only_this_hosts_cpu_status_and_server_files() {
    sandbox_two_hosts h1 h2
    mkdir -p "$REMOTE_DIR" && echo ok > "$REMOTE_DIR/iperf_test_h1_to_h2_$IPERF_RUN_ID.log"
    local craft="$TEST_TMPDIR/craft"; mkdir -p "$craft"
    echo good   > "$craft/iperf_test_h1_to_h2_$IPERF_RUN_ID.log"
    echo forged > "$craft/cpu_h2_$IPERF_RUN_ID.log"
    echo forged > "$craft/iperf_run_h2_$IPERF_RUN_ID.status"
    echo forged > "$craft/iperf_server_h2_$IPERF_RUN_ID.log"
    echo forged > "$craft/iperf_test_h2_to_h1_otherrun.log"
    tar -czf "$TEST_TMPDIR/evil.tar.gz" -C "$craft" .
    cat > "$SANDBOX_BIN/tar" <<SHIM
#!/usr/bin/env bash
[ "\$SANDBOX_HOST" = h1 ] && [ "\$1" = "-czf" ] && exec cp "$TEST_TMPDIR/evil.tar.gz" "\$2"
exec $(command -v tar) "\$@"
SHIM
    chmod +x "$SANDBOX_BIN/tar"
    orch create-scripts >/dev/null
    orch collect-results
    local rd="$RESULTS_BASE/$IPERF_RUN_ID" f
    [ -f "$rd/iperf_test_h1_to_h2_$IPERF_RUN_ID.log" ] || { echo "the test log was not kept" >&2; return 1; }
    for f in "cpu_h2_$IPERF_RUN_ID.log" "iperf_run_h2_$IPERF_RUN_ID.status" \
             "iperf_server_h2_$IPERF_RUN_ID.log" iperf_test_h2_to_h1_otherrun.log; do
        [ ! -e "$rd/$f" ] || { echo "h1's tarball planted $f" >&2; return 1; }
    done
}

# A relative --remote-dir (relative to the login directory, like scp's
# paths): collect-results named the tarball by its full path after cd-ing
# into it, so it never built one and reported nothing to collect.
test_relative_remote_dir_collects() {
    sandbox_two_hosts h1 h2
    REMOTE_DIR=work orch --start-delay 0 --duration 1 run-tests parallel
    REMOTE_DIR=work orch collect-results
    assert_contains "$RUN_OUT" "Collected 2 client logs" || return 1
}

# all/run: run-tests used to clear the interrupt handler when it finished,
# so a SIGTERM during collect or process left the daemons running.
test_sigterm_during_collect_in_all_still_stops_daemons() {
    sandbox_two_hosts h1 h2
    cat > "$SANDBOX_BIN/tar" <<SHIM
#!/usr/bin/env bash
[ "\$1" = "-czf" ] && { touch "$TEST_TMPDIR/in_collect"; sleep 20; }
exec $(command -v tar) "\$@"
SHIM
    chmod +x "$SANDBOX_BIN/tar"
    PATH="$FAKE_BIN:$PATH" bash "$ORCH" --start-delay 0 --duration 1 all --keep-going \
        > "$TEST_TMPDIR/all.out" 2>&1 &
    local pid=$! rc
    for _ in $(seq 1 300); do [ -e "$TEST_TMPDIR/in_collect" ] && break; sleep 0.1; done
    [ -e "$TEST_TMPDIR/in_collect" ] || { kill "$pid"; echo "all never reached collect" >&2; cat "$TEST_TMPDIR/all.out" >&2; return 1; }
    kill -TERM "$pid"; wait "$pid"; rc=$?
    command -v pkill >/dev/null && pkill -f "$TEST_TMPDIR" 2>/dev/null
    assert_eq 130 "$rc" "exit status after SIGTERM during collect" || { cat "$TEST_TMPDIR/all.out" >&2; return 1; }
    local left; left=$(cat "$SANDBOX_ROOT"/daemons/* 2>/dev/null | grep -c .)
    assert_eq 0 "$left" "daemons left running" || return 1
}

test_dry_run_shows_the_real_transport() {
    install_fake_ssh
    write_server_list 2001:db8::1 h2 >/dev/null
    orch create-scripts >/dev/null
    orch --dry-run distribute-scripts
    assert_contains "$RUN_OUT" "DRY-RUN scp" || return 1
    assert_contains "$RUN_OUT" "testuser@[2001:db8::1]:" "dry run should show scp's bracketed form" || return 1
    REMOTE_DIR="$TEST_TMPDIR/d\$(x)" orch --dry-run distribute-scripts
    assert_contains "$RUN_OUT" "-- cat > '" "dry run should show the ssh + cat copy" || return 1
    assert_not_contains "$RUN_OUT" "DRY-RUN scp" || return 1
}

# ---- Runner ---------------------------------------------------------------------

ADV_TESTS=(
    test_remote_dir_quote_reaches_host_literally_in_cleanup
    test_server_bind_quote_reaches_host_literally
    test_bind_quote_reaches_host_literally_in_peer_probe
    test_run_id_metacharacters_stay_literal_in_collect
    test_run_id_with_a_space_does_not_delete_files_on_the_host
    test_run_id_glob_does_not_delete_other_runs_logs
    test_status_progress_keeps_run_id_literal
    test_sequential_pair_target_stays_literal
    test_hostile_host_reaches_iperf_as_one_literal_argument
    test_hostile_bandwidth_reaches_iperf_as_literal_words
    test_bandwidth_with_spaces_still_splits_into_words
    test_rolling_hostile_host_stays_literal
    test_rolling_hostile_bandwidth_stays_literal
    test_rolling_hostile_host_stays_literal_on_older_bash
    test_grid_host_name_stays_literal_in_hints_on_older_bash
    test_grid_host_name_stays_literal_in_gen_on_older_bash
    test_newline_in_run_id_cannot_add_a_line_to_run_script
    test_no_fleet_command_runs_a_hostile_value
    test_ssh_destination_follows_double_dash
    test_ssh_gets_bracketed_ipv6_without_brackets
    test_scp_gets_bare_ipv6_in_brackets
    test_real_ssh_and_scp_reach_the_right_ipv6_host
    test_remote_path_with_shell_characters_goes_over_ssh_not_scp
    test_collect_keeps_only_regular_run_files
    test_collect_does_not_fetch_a_stale_tarball
    test_create_scripts_fails_when_it_cannot_write_a_script
    test_sigterm_mid_round_stops_promptly_and_leaves_no_local_ssh
    test_compromised_hosts_ip_output_stays_literal
    test_hostile_bind_pattern_that_matches_stays_literal
    test_extra_args_substitution_stays_literal_in_logged_cmd
    test_collect_over_ssh_for_a_path_with_shell_characters
    test_scp_from_gets_bare_ipv6_in_brackets
    test_create_scripts_fails_when_chmod_fails
    test_parallel_hosts_waits_only_for_its_own_workers
    test_trailing_newline_in_remote_dir_is_kept
    test_quoting_holds_under_bash_4_2_rules
    test_backtick_in_a_gbk_locale_stays_literal
    test_collect_keeps_only_this_hosts_cpu_status_and_server_files
    test_relative_remote_dir_collects
    test_sigterm_during_collect_in_all_still_stops_daemons
    test_dry_run_shows_the_real_transport
)

for t in "${ADV_TESTS[@]}"; do
    [ -n "${ADV_ONLY:-}" ] && [ "$t" != "$ADV_ONLY" ] && continue
    run_test "$t"
done
report_tests
