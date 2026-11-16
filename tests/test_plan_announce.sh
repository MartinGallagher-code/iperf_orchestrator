#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# A plan picked up from the current directory is announced, and the
# destructive commands name the plan their settings came from (shared_tools
# IO-005; the owner chose "announce it").
#
# Every command loads ./iperf_plan.conf whenever it exists. The plan sets
# every setting, remote_dir= and ssh_user= included, so a bare `clean` in a
# directory holding someone else's plan acts on that plan's hosts and
# directory as that plan's user. IO-001 reproduced it deleting a user's
# home directory. Each test runs from a scratch directory holding such a
# plan.
#
# PLAN_ONLY=<test name> runs just that test (the mutation file,
# test_plan_announce_mutations.sh, uses it).

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# A directory holding a hostile plan: someone else's remote_dir=, user and
# hosts. REMOTE_DIR, SSH_USER and IPERF_SERVERS are unset so the plan, not
# the test environment, decides them.
hostile_plan_dir() {
    PLAN_DIR="$TEST_TMPDIR/theirs"
    mkdir -p "$PLAN_DIR"
    cat > "$PLAN_DIR/iperf_plan.conf" <<EOF
# remote_dir=$TEST_TMPDIR/victim ssh_user=victim
h1
h2
EOF
    unset REMOTE_DIR SSH_USER IPERF_SERVERS
}

# run_in DIR ARGS...: the orchestrator run from DIR, stdout and stderr
# kept apart in RUN_STDOUT / RUN_STDERR.
run_in() {
    local dir="$1"; shift
    RUN_STDOUT=$(cd "$dir" && PATH="$FAKE_BIN:$PATH" bash "$ORCH" "$@" 2>"$TEST_TMPDIR/stderr" </dev/null)
    RUN_RC=$?
    RUN_STDERR=$(cat "$TEST_TMPDIR/stderr")
}

ANNOUNCE="Using plan ./iperf_plan.conf from the current directory"

test_plan_from_the_current_directory_is_announced_on_stderr() {
    hostile_plan_dir
    install_fake_ssh
    run_in "$PLAN_DIR" status
    assert_contains "$RUN_STDERR" "$ANNOUNCE" "status should announce the plan it picked up" || return 1
    assert_not_contains "$RUN_STDOUT" "$ANNOUNCE" "the announcement belongs on stderr" || return 1
}

test_a_named_plan_is_not_announced() {
    hostile_plan_dir
    install_fake_ssh
    run_in "$PLAN_DIR" --plan ./iperf_plan.conf hints
    assert_not_contains "$RUN_STDERR" "Using plan" "--plan names it" || return 1
    RUN_STDOUT=$(cd "$PLAN_DIR" && IPERF_PLAN=./iperf_plan.conf bash "$ORCH" hints 2>"$TEST_TMPDIR/stderr")
    assert_not_contains "$(cat "$TEST_TMPDIR/stderr")" "Using plan" "IPERF_PLAN names it" || return 1
}

test_quiet_hides_the_announcement() {
    hostile_plan_dir
    run_in "$PLAN_DIR" --quiet hints
    assert_not_contains "$RUN_STDERR" "Using plan" || return 1
}

test_clean_names_the_plan_it_would_delete_from() {
    hostile_plan_dir
    install_fake_ssh
    run_in "$PLAN_DIR" clean
    assert_ne 0 "$RUN_RC" "clean without --yes off a terminal is refused" || return 1
    assert_contains "$RUN_STDERR" "$TEST_TMPDIR/victim" || return 1
    assert_contains "$RUN_STDERR" "(remote_dir=, ssh_user= and the host list from the plan ./iperf_plan.conf)" || return 1
    # --yes: the line before the delete names it too.
    run_in "$PLAN_DIR" clean --yes
    assert_contains "$RUN_STDOUT" "Stopping daemons and removing $TEST_TMPDIR/victim on every host (remote_dir=, ssh_user= and the host list from the plan ./iperf_plan.conf)" || return 1
}

test_cleanup_names_the_plan_it_would_delete_from() {
    hostile_plan_dir
    install_fake_ssh
    run_in "$PLAN_DIR" cleanup
    assert_ne 0 "$RUN_RC" "cleanup without --yes is refused" || return 1
    assert_contains "$RUN_STDERR" "(remote_dir=, ssh_user= and the host list from the plan ./iperf_plan.conf). Pass --yes" || return 1
    run_in "$PLAN_DIR" cleanup --yes
    assert_contains "$RUN_STDOUT" "(remote_dir=, ssh_user= and the host list from the plan ./iperf_plan.conf)..." || return 1
}

test_all_names_the_plan_it_will_delete_from() {
    hostile_plan_dir
    install_fake_ssh
    # --keep-going: doctor may report matplotlib missing (the Python 3.6
    # job); the line under test comes after it either way.
    run_in "$PLAN_DIR" --start-delay 0 --duration 1 all --keep-going
    assert_contains "$RUN_STDOUT" "At the end: delete REMOTE_DIR $TEST_TMPDIR/victim on every host (remote_dir=, ssh_user= and the host list from the plan ./iperf_plan.conf)" || return 1
}

# A setting given as a flag is the user's, not the plan's.
test_a_flag_is_not_attributed_to_the_plan() {
    hostile_plan_dir
    install_fake_ssh
    run_in "$PLAN_DIR" --remote-dir "$TEST_TMPDIR/mine" --ssh-user me clean
    assert_contains "$RUN_STDERR" "$TEST_TMPDIR/mine" || return 1
    assert_contains "$RUN_STDERR" "(the host list from the plan ./iperf_plan.conf)" || return 1
    assert_not_contains "$RUN_STDERR" "remote_dir=, " || return 1
}

PLAN_TESTS=(
    test_plan_from_the_current_directory_is_announced_on_stderr
    test_a_named_plan_is_not_announced
    test_quiet_hides_the_announcement
    test_clean_names_the_plan_it_would_delete_from
    test_cleanup_names_the_plan_it_would_delete_from
    test_all_names_the_plan_it_will_delete_from
    test_a_flag_is_not_attributed_to_the_plan
)
for t in "${PLAN_TESTS[@]}"; do
    [ -n "${PLAN_ONLY:-}" ] && [ "$t" != "$PLAN_ONLY" ] && continue
    run_test "$t"
done

report_tests
