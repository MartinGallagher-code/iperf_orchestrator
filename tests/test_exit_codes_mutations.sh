#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# Mutation tests for tests/test_exit_codes.sh (shared_tools IO-008): a
# suite that cannot fail proves nothing. Each record below undoes ONE part
# of the fix in a copy of the orchestrator -- the text as it is now
# ('---') becomes the text as it was, or as a wrong fix would make it
# ('+++') -- and runs the test that guards that part against the copy.
# The case passes only when that test FAILS. A mutation whose '---' text
# is no longer in the script fails loudly ("no longer applies") rather
# than testing nothing.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

MUTATIONS=$(cat <<'TABLE'
### test_start_servers_exits_nonzero_when_a_host_fails
---     _fleet_failed "start-servers: ${#PARALLEL_FAILED[@]} failure(s)"
+++     true
### test_stop_servers_exits_nonzero_when_a_host_fails
---     _fleet_failed "stop-servers: ${#PARALLEL_FAILED[@]} failure(s)"
+++     true
### test_stop_exits_nonzero_when_a_host_fails
---     cmd_stop_servers || rc=1
+++     cmd_stop_servers
### test_distribute_scripts_exits_nonzero_when_a_host_fails
---     _fleet_failed "distribute-scripts had ${#PARALLEL_FAILED[@]} failure(s)" || return 1
+++     true || return 1
### test_collect_results_exits_nonzero_when_a_host_fails
---         if [ "$rc" -eq 255 ]; then
+++         if false; then
### test_collect_results_exits_nonzero_when_a_host_fails
---     _fleet_failed "collect-results: ${#PARALLEL_FAILED[@]} host(s) had transfer failures"
+++     true
### test_cleanup_exits_nonzero_when_a_host_fails
---     _fleet_failed "cleanup: ${#PARALLEL_FAILED[@]} failure(s)"
+++     true
### test_run_tests_stops_when_distribution_fails
---                 die "run-tests: distribute-scripts failed on
+++                 warn "run-tests: distribute-scripts failed on
### test_run_tests_keep_going_runs_the_rest
---             --keep-going) kg=1 ;;
+++             --keep-going) ;;
### test_every_step_exits_zero_when_every_host_succeeds
---     [ "${#PARALLEL_FAILED[@]}" -eq 0 ] && return 0
+++     false && return 0
TABLE
)
export MUTATIONS

# mutant_fails N: build the mutant from record N (0-based), run its test
# against it, and succeed only if that test fails there.
mutant_fails() {
    local n="$1" m="$TEST_TMPDIR/mutant/iperf_orchestrator.sh" t
    mkdir -p "${m%/*}"
    t=$(python3 - "$ORCH" "$m" "$n" <<'PYMUT'
import os, sys
src, dst, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
def expand(s):
    return s
lines = os.environ["MUTATIONS"].split("\n")
recs = []
for i, line in enumerate(lines):
    if line.startswith("### "):
        assert lines[i + 1].startswith("--- ") and lines[i + 2].startswith("+++ "), line
        recs.append((line[4:], expand(lines[i + 1][4:]), expand(lines[i + 2][4:])))
test, old, new = recs[n]
text = open(src).read()
if old not in text:
    sys.exit("mutation no longer applies, text not found: " + old)
open(dst, "w").write(text.replace(old, new))
print(test)
PYMUT
) || return 1
    chmod +x "$m"
    bash -n "$m" || { echo "the mutant for $t does not parse" >&2; return 1; }
    # A mutant that is merely broken would fail every test; one test that
    # the mutation does not touch must still pass against it.
    local sane=test_start_servers_exits_nonzero_when_a_host_fails
    [ "$t" = "$sane" ] && sane=test_stop_servers_exits_nonzero_when_a_host_fails
    ORCH="$m" EXIT_ONLY="$sane" bash "$DIR/test_exit_codes.sh" > "$TEST_TMPDIR/sane.out" 2>&1 || {
        echo "the mutant for $t also breaks $sane, so it proves nothing:" >&2
        tail -n 20 "$TEST_TMPDIR/sane.out" >&2; return 1
    }
    if ORCH="$m" EXIT_ONLY="$t" bash "$DIR/test_exit_codes.sh" > "$TEST_TMPDIR/mutant.out" 2>&1; then
        echo "MUTANT SURVIVED: $t still passes with this fix reverted" >&2
        tail -n 20 "$TEST_TMPDIR/mutant.out" >&2
        return 1
    fi
    grep -q "FAIL  $t " "$TEST_TMPDIR/mutant.out" || {
        echo "$t did not run against the mutant:" >&2; cat "$TEST_TMPDIR/mutant.out" >&2; return 1
    }
}

# Every test in test_exit_codes.sh has at least one mutation, and every
# mutation names a test that exists.
test_every_exit_test_has_a_mutation() {
    local listed recorded
    listed=$(sed -n '/^EXIT_TESTS=(/,/^)/p' "$DIR/test_exit_codes.sh" | grep -E '^ +test_' | tr -d ' ' | sort)
    recorded=$(printf '%s\n' "$MUTATIONS" | sed -n 's/^### //p' | sort -u)
    assert_eq "$listed" "$recorded" "tests vs mutations" || return 1
}
run_test test_every_exit_test_has_a_mutation

n=0
while IFS= read -r t; do
    skip=0
    if [ "$skip" = 0 ]; then
        eval "mutation_${n}_${t#test_}() { mutant_fails $n; }"
        run_test "mutation_${n}_${t#test_}"
    fi
    n=$((n + 1))
done < <(printf '%s\n' "$MUTATIONS" | sed -n 's/^### //p')

report_tests
