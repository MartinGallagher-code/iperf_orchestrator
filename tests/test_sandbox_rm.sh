#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# The sandbox `rm` stand-in (install_sandbox_ssh in test_helper.bash)
# behaves like rm -f for a missing operand (shared_tools IO-011).
#
# In the sandbox both hosts share one REMOTE_DIR, and `clean` runs on
# them at once. When one host removed the directory while the other's
# shell was still inside it, the other's `rm -f -- _iperf_files_*.list`
# (an unmatched glob, so the literal name) reached the stand-in, whose
# realpath could not resolve a relative path with the current directory
# gone; it refused, and that host reported LEFTOVER. A real rm -f does
# nothing for a missing operand, so test_adversarial.sh's
# test_clean_removes_the_tools_own_files_and_the_dir failed about one
# run in three.
#
# SANDBOX_RM_ONLY=<test name> runs just that test, and SANDBOX_HELPER
# names the helper to source; the mutation test below uses both.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "${SANDBOX_HELPER:-$DIR/test_helper.bash}"

# sandbox_rm ARGS...: the stand-in, as a remote command on host h1 runs it.
sandbox_rm() { PATH="$SANDBOX_BIN:$PATH" SANDBOX_HOST=h1 rm "$@"; }

# The race, made deterministic: the shell's current directory is removed
# before rm -f is given a relative name in it.
test_rm_f_of_a_missing_name_in_a_removed_directory_succeeds() {
    install_sandbox_ssh
    local d="$TEST_TMPDIR/remote" out rc
    mkdir -p "$d"
    out=$(cd "$d" && rmdir "$d" && sandbox_rm -f -- '_iperf_files_*.list' 'run_iperf_*.sh' 2>&1)
    rc=$?
    assert_status 0 "$rc" "rm -f of missing names: $out" || return 1
    assert_not_contains "$out" "refused" || return 1
}

test_rm_f_of_a_missing_absolute_path_succeeds() {
    install_sandbox_ssh
    local out rc
    out=$(sandbox_rm -f -- "$TEST_TMPDIR/remote/nothing-here" 2>&1)
    rc=$?
    assert_status 0 "$rc" "rm -f of a missing path: $out" || return 1
}

# The point of the stand-in is unchanged: it never removes a file outside
# the sandbox, -f or not.
test_rm_still_refuses_an_existing_file_outside_the_sandbox() {
    install_sandbox_ssh
    local outside out rc
    outside=$(mktemp -d "${TMPDIR:-/tmp}/iperf-orch-outside-XXXXXX")
    : > "$outside/keep"
    out=$(sandbox_rm -f -- "$outside/keep" 2>&1)
    rc=$?
    local survived=0
    [ -e "$outside/keep" ] && survived=1
    rm -rf "$outside"
    assert_status 1 "$rc" "rm -f of a file outside the sandbox" || return 1
    assert_contains "$out" "outside the sandbox" || return 1
    assert_eq 1 "$survived" "the file outside the sandbox must survive" || return 1
}

test_rm_f_still_removes_a_file_inside_the_sandbox() {
    install_sandbox_ssh
    local d="$TEST_TMPDIR/remote" rc
    mkdir -p "$d"
    : > "$d/cpu_h1.log"
    (cd "$d" && sandbox_rm -f -- cpu_h1.log 'iperf_test_*.log')
    rc=$?
    assert_status 0 "$rc" "rm -f inside the sandbox" || return 1
    [ ! -e "$d/cpu_h1.log" ] || { echo "cpu_h1.log was not removed" >&2; return 1; }
}

# Without -f a missing operand is still an error, as with a real rm.
test_rm_without_f_of_a_missing_name_still_fails() {
    install_sandbox_ssh
    local d="$TEST_TMPDIR/remote" rc
    mkdir -p "$d"
    (cd "$d" && sandbox_rm -- not-there) >/dev/null 2>&1
    rc=$?
    assert_ne 0 "$rc" "rm of a missing name without -f" || return 1
}

# A suite that cannot fail proves nothing: with the fix taken out of a
# copy of the helper, the race test fails.
test_the_race_test_fails_without_the_fix() {
    local mutant="$TEST_TMPDIR/test_helper.bash"
    python3 - "$DIR/test_helper.bash" "$mutant" <<'PYMUT' || return 1
import sys
src, dst = sys.argv[1], sys.argv[2]
old = '    if [ "$force" = 1 ] && [ ! -e "$p" ] && [ ! -L "$p" ]; then continue; fi\n'
text = open(src).read()
if text.count(old) != 1:
    sys.exit("mutation no longer applies, text not found: " + old)
open(dst, "w").write(text.replace(old, ""))
PYMUT
    local t=test_rm_f_of_a_missing_name_in_a_removed_directory_succeeds out
    if out=$(SANDBOX_HELPER="$mutant" SANDBOX_RM_ONLY="$t" bash "$DIR/test_sandbox_rm.sh" 2>&1); then
        echo "MUTANT SURVIVED: $t passes without the fix" >&2; echo "$out" >&2; return 1
    fi
    assert_contains "$out" "FAIL  $t " "the race test should have run and failed" || return 1
    # And the mutant is not merely broken: the outside-file test passes.
    SANDBOX_HELPER="$mutant" SANDBOX_RM_ONLY=test_rm_still_refuses_an_existing_file_outside_the_sandbox \
        bash "$DIR/test_sandbox_rm.sh" >/dev/null 2>&1 \
        || { echo "the mutant also breaks an unrelated test, so it proves nothing" >&2; return 1; }
}

SANDBOX_RM_TESTS=(
    test_rm_f_of_a_missing_name_in_a_removed_directory_succeeds
    test_rm_f_of_a_missing_absolute_path_succeeds
    test_rm_still_refuses_an_existing_file_outside_the_sandbox
    test_rm_f_still_removes_a_file_inside_the_sandbox
    test_rm_without_f_of_a_missing_name_still_fails
    test_the_race_test_fails_without_the_fix
)
for t in "${SANDBOX_RM_TESTS[@]}"; do
    [ -n "${SANDBOX_RM_ONLY:-}" ] && [ "$t" != "$SANDBOX_RM_ONLY" ] && continue
    run_test "$t"
done

report_tests
