#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# Values that can never be a host, path, run id or iperf value are refused
# before any host is contacted (shared_tools IO-002; the owner chose the
# character sets).
#
# Since 2.6.4 (IO-001) every value reaches a host quoted, as one literal,
# so none of these could run anything; but nothing was refused either.
# --run-id ../../x wrote its run two levels above --output, an empty
# --remote-dir was taken, and a host name holding a quote or a space
# failed only when ssh tried it. Every refusal test below failed on 2.9.0;
# the last two check that ordinary values, IPv6 in both forms among them,
# are still accepted, and that help and version still run.
#
# "No host was contacted" is checked on the stand-in ssh's calls.log,
# which records every ssh and scp. Every test runs under the plain
# stand-in and under the sandbox (run_tests.sh --sandbox).
#
# VALUE_ONLY=<test name> runs just that test (the mutation file,
# test_value_checks_mutations.sh, uses it).

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

orch() { PATH="$FAKE_BIN:$PATH" run_orch "$@"; }

two_hosts() {
    install_fake_ssh
    write_server_list h1 h2 >/dev/null
}

no_host_contacted() {
    [ ! -s "$FAKE_SSH_LOG" ] && return 0
    echo "a host was contacted:" >&2; cat "$FAKE_SSH_LOG" >&2
    return 1
}

# refused NAMES: the last run was refused at startup (exit 2), naming
# NAMES, and touched no host.
refused() {
    assert_status 2 "$RUN_RC" "should be refused: $RUN_OUT" || return 1
    assert_contains "$RUN_OUT" "$1" || return 1
    assert_contains "$RUN_OUT" "is refused" || return 1
    no_host_contacted || return 1
}

test_run_id_that_leaves_the_results_dir_is_refused() {
    two_hosts
    mkdir -p "$TEST_TMPDIR/a/b"
    RESULTS_BASE="$TEST_TMPDIR/a/b/results" orch --run-id ../../escape create-scripts
    refused "--run-id / IPERF_RUN_ID: '../../escape' is refused" || return 1
    [ ! -e "$TEST_TMPDIR/a/escape" ] || { echo "the run was written above --output" >&2; return 1; }
    [ ! -e "$TEST_TMPDIR/a/b/results/latest" ] || { echo "'latest' was pointed at it" >&2; return 1; }
}

test_run_id_outside_the_set_is_refused() {
    two_hosts
    local rid
    for rid in a/b 'nightly run' . .. 'r;x' 'r$(x)' "r'x" $'r\nx'; do
        : > "$FAKE_SSH_LOG"
        orch --run-id "$rid" check-servers
        refused "--run-id / IPERF_RUN_ID:" || { echo "run id: $rid" >&2; return 1; }
        IPERF_RUN_ID="$rid" orch check-servers
        refused "--run-id / IPERF_RUN_ID:" || { echo "IPERF_RUN_ID: $rid" >&2; return 1; }
    done
    # --run-id= names a run, and an empty one is not one.
    orch --run-id= check-servers
    refused "--run-id / IPERF_RUN_ID: '' is refused" || return 1
}

test_empty_remote_dir_is_refused() {
    two_hosts
    orch --remote-dir= check-servers
    refused "--remote-dir / REMOTE_DIR / remote_dir= in the plan: '' is refused" || return 1
}

test_remote_dir_with_a_control_character_is_refused() {
    two_hosts
    orch --remote-dir $'keep\n' check-servers
    refused "--remote-dir / REMOTE_DIR / remote_dir= in the plan: \$'keep\\n' is refused" || return 1
    REMOTE_DIR=$'a\tb' orch check-servers
    refused "--remote-dir / REMOTE_DIR" || return 1
    # From a plan: the tokens are split on whitespace, so a newline or a
    # tab cannot be in one, but any other control character can.
    unset REMOTE_DIR
    printf '# remote_dir=/tmp/a\001b\nh1\nh2\n' > "$TEST_TMPDIR/plan.conf"
    orch --plan "$TEST_TMPDIR/plan.conf" check-servers
    refused "remote_dir= in the plan: \$'/tmp/a\\001b' is refused" || return 1
}

test_ssh_user_outside_the_set_is_refused() {
    two_hosts
    local u
    for u in -oProxyCommand=x '-x' 'a b' 'a;b' 'a$(x)' "a'b" 'a/b'; do
        : > "$FAKE_SSH_LOG"
        orch --ssh-user "$u" check-servers
        refused "--ssh-user / SSH_USER / ssh_user= in the plan:" || { echo "user: $u" >&2; return 1; }
    done
    orch --ssh-user= check-servers
    refused "--ssh-user / SSH_USER / ssh_user= in the plan: '' is refused" || return 1
    unset SSH_USER
    printf '# ssh_user=-oProxyCommand=x\nh1\nh2\n' > "$TEST_TMPDIR/plan.conf"
    orch --plan "$TEST_TMPDIR/plan.conf" check-servers
    refused "ssh_user= in the plan: '-oProxyCommand=x' is refused" || return 1
}

test_iperf_value_outside_the_set_is_refused() {
    two_hosts
    local flag v
    for flag in --bandwidth --length --window --mss; do
        for v in '1g;touch x' '1g$(x)' "1g'x" '1g|x' '1g&' $'1g\tx' '1g`x`' '1g>x'; do
            : > "$FAKE_SSH_LOG"
            orch "$flag" "$v" check-servers
            refused "$flag / IPERF_" || { echo "$flag $v" >&2; return 1; }
        done
    done
    printf '# bandwidth=1g;x\nh1\nh2\n' > "$TEST_TMPDIR/plan.conf"
    orch --plan "$TEST_TMPDIR/plan.conf" check-servers
    refused "bandwidth= in the plan: '1g;x' is refused" || return 1
}

test_single_server_outside_the_set_is_refused() {
    two_hosts
    orch --single-server 'h2$(x)' --start-delay 0 --duration 1 run-tests sequential-host
    refused "--single-server / IPERF_SINGLE_SERVER: 'h2\$(x)' is refused" || return 1
}

# Every command that contacts hosts checks the list first, and names every
# entry it refuses.
test_host_outside_the_set_is_refused() {
    install_fake_ssh
    write_server_list h1 'http://h2' 'h3 h4' "h'5" 'me@h6' '[h7' 'h8$(x)' >/dev/null
    local cmd
    for cmd in check-servers check-iperf start-servers create-scripts distribute-scripts \
               "run-tests parallel" collect-results stop-servers "cleanup --yes" "clean --yes" status; do
        : > "$FAKE_SSH_LOG"
        # shellcheck disable=SC2086
        orch --start-delay 0 --duration 1 $cmd
        assert_ne 0 "$RUN_RC" "$cmd with a bad host" || return 1
        assert_contains "$RUN_OUT" "not a host name or address: 'http://h2', 'h3 h4', 'h'5', 'me@h6', '[h7', 'h8\$(x)' (a host is" "$cmd" || return 1
        assert_contains "$RUN_OUT" "No host was contacted." "$cmd" || return 1
        no_host_contacted || { echo "$cmd" >&2; return 1; }
    done
}

# status asks every host too, so it checks the list as the others do.
test_status_checks_the_server_list_before_asking_hosts() {
    install_fake_ssh
    write_server_list h1 'h2 h3' >/dev/null
    orch status
    assert_status 1 "$RUN_RC" "status with a bad host" || return 1
    assert_contains "$RUN_OUT" "not a host name or address: 'h2 h3'" || return 1
    no_host_contacted || return 1
}

test_gen_refuses_to_write_a_plan_with_a_bad_host() {
    install_fake_ssh
    write_server_list h1 'h2;x' >/dev/null
    orch --plan "$TEST_TMPDIR/new.conf" gen
    assert_ne 0 "$RUN_RC" "gen with a bad host" || return 1
    assert_contains "$RUN_OUT" "not a host name or address: 'h2;x'" || return 1
    [ ! -e "$TEST_TMPDIR/new.conf" ] || { echo "gen wrote the plan anyway" >&2; return 1; }
}

# Nothing an ordinary fleet uses is refused.
test_ordinary_values_are_still_accepted() {
    install_fake_ssh
    write_server_list h1 node-01.example.com 10.0.0.1 2001:db8::1 '[2001:db8::2]' \
        'fe80::1%eth0' '[fe80::1%eth0]' under_score >/dev/null
    local rd="$TEST_TMPDIR/remote dir é" rid
    for rid in 2026-11-16_21-45-17 nightly.v2 -leading-dash; do
        : > "$FAKE_SSH_LOG"
        orch --run-id "$rid" --remote-dir "$rd" --ssh-user a.b@corp \
            --bandwidth '1g -N' --length 128K --window 4M --mss 1460 check-servers
        assert_status 0 "$RUN_RC" "run id $rid: $RUN_OUT" || return 1
        assert_not_contains "$RUN_OUT" "refused" || return 1
        grep -q 'fe80::1%eth0' "$FAKE_SSH_LOG" || { echo "the hosts were not asked" >&2; cat "$FAKE_SSH_LOG" >&2; return 1; }
    done
    orch --bandwidth 1m,2m --ssh-user svc-iperf_2 --single-server '[2001:db8::2]' \
        --start-delay 0 --duration 1 --dry-run run-tests sequential-host
    assert_not_contains "$RUN_OUT" "refused" "$RUN_OUT" || return 1
}

# help and version show what is set rather than refuse it.
test_help_and_version_run_whatever_is_set() {
    local c
    for c in help --help help-advanced version --version; do
        SSH_USER='John Smith' orch --run-id ../x --bandwidth '1g;x' $c
        assert_status 0 "$RUN_RC" "$c: $RUN_OUT" || return 1
    done
    SSH_USER='John Smith' orch help
    assert_contains "$RUN_OUT" "John Smith" "help shows the value it would refuse" || return 1
}

VALUE_TESTS=(
    test_run_id_that_leaves_the_results_dir_is_refused
    test_run_id_outside_the_set_is_refused
    test_empty_remote_dir_is_refused
    test_remote_dir_with_a_control_character_is_refused
    test_ssh_user_outside_the_set_is_refused
    test_iperf_value_outside_the_set_is_refused
    test_single_server_outside_the_set_is_refused
    test_host_outside_the_set_is_refused
    test_status_checks_the_server_list_before_asking_hosts
    test_gen_refuses_to_write_a_plan_with_a_bad_host
    test_ordinary_values_are_still_accepted
    test_help_and_version_run_whatever_is_set
)
for t in "${VALUE_TESTS[@]}"; do
    [ -n "${VALUE_ONLY:-}" ] && [ "$t" != "$VALUE_ONLY" ] && continue
    run_test "$t"
done

report_tests
