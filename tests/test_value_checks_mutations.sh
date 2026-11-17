#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# Mutation tests for tests/test_value_checks.sh (shared_tools IO-002): a
# suite that cannot fail proves nothing. Each record below undoes one part
# of the checks in a copy of the orchestrator -- the text as it is now
# ('---') becomes the text as it was, or as a wrong fix would make it
# ('+++') -- and runs the test that guards that part against the copy.
# The case passes only when that test FAILS. The records for the last two
# tests go the other way: they refuse too much.
#
# In a record, \n stands for a newline. A mutation whose '---' text is no
# longer in the script fails loudly ("no longer applies") rather than
# testing nothing.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

MUTATIONS=$(cat <<'TABLE'
### test_run_id_that_leaves_the_results_dir_is_refused
---             ''|.|..|*[!A-Za-z0-9._-]*)
+++             ''|.|..|*[!A-Za-z0-9._/-]*)
### test_run_id_outside_the_set_is_refused
---             ''|.|..|*[!A-Za-z0-9._-]*)
+++             ''|*[!A-Za-z0-9._-]*)
### test_empty_remote_dir_is_refused
---         ''|*[[:cntrl:]]*)
+++         *[[:cntrl:]]*)
### test_remote_dir_with_a_control_character_is_refused
---         ''|*[[:cntrl:]]*)
+++         '')
### test_ssh_user_outside_the_set_is_refused
---         ''|-*|*[!A-Za-z0-9._@-]*)
+++         ''|*[!A-Za-z0-9._@-]*)
### test_iperf_value_outside_the_set_is_refused
---         *[!A-Za-z0-9.,:+\ -]*)
+++         *[[:cntrl:]]*)
### test_single_server_outside_the_set_is_refused
---     if [ -n "$IPERF_SINGLE_SERVER" ] && ! _host_ok "$IPERF_SINGLE_SERVER"; then
+++     if false; then
### test_host_outside_the_set_is_refused
---     case "$h" in ''|*[!A-Za-z0-9._:%-]*) return 1 ;; esac
+++     case "$h" in '') return 1 ;; esac
### test_status_checks_the_server_list_before_asking_hosts
---     if [ -n "$SERVER_LIST_FILE" ] && [ -f "$SERVER_LIST_FILE" ]; then\n        _validate_server_list\n    fi\n    while :; do
+++     while :; do
### test_gen_refuses_to_write_a_plan_with_a_bad_host
---     _validate_server_list\n\n    # If the input is already a grid
+++ \n    # If the input is already a grid
### test_ordinary_values_are_still_accepted
---     case "$h" in ''|*[!A-Za-z0-9._:%-]*) return 1 ;; esac
+++     case "$h" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
### test_ordinary_values_are_still_accepted
---     case "$h" in \[*\]) h="${h#\[}"; h="${h%\]}" ;; esac
+++     :
### test_ordinary_values_are_still_accepted
---         ''|-*|*[!A-Za-z0-9._@-]*)
+++         ''|-*|*[!A-Za-z0-9._-]*)
### test_ordinary_values_are_still_accepted
---         *[!A-Za-z0-9.,:+\ -]*)
+++         *[!A-Za-z0-9.,:+-]*)
### test_ordinary_values_are_still_accepted
---         ''|*[[:cntrl:]]*)
+++         ''|*[[:cntrl:]]*|*' '*)
### test_ordinary_values_are_still_accepted
---             ''|.|..|*[!A-Za-z0-9._-]*)
+++             ''|-*|.|..|*[!A-Za-z0-9._-]*)
### test_help_and_version_run_whatever_is_set
---     ""|help|-h|--help|help-advanced|--help-advanced|version|--version) ;;\n    *) _validate_values ;;
+++     "") ;;\n    *) _validate_values ;;
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
    return s.replace("\\n", "\n")
lines = os.environ["MUTATIONS"].split("\n")
recs = []
for i, line in enumerate(lines):
    if line.startswith("### "):
        assert lines[i + 1].startswith("--- ") and lines[i + 2].startswith("+++ "), line
        recs.append((line[4:], expand(lines[i + 1][4:]), expand(lines[i + 2][4:])))
test, old, new = recs[n]
text = open(src).read()
if text.count(old) != 1:
    sys.exit("mutation no longer applies, text not found exactly once: " + old)
open(dst, "w").write(text.replace(old, new))
print(test)
PYMUT
) || return 1
    chmod +x "$m"
    bash -n "$m" || { echo "the mutant for $t does not parse" >&2; return 1; }
    # A mutant that is merely broken would fail every test; one test that
    # the mutation does not touch must still pass against it.
    local sane=test_empty_remote_dir_is_refused
    case "$t" in test_empty_remote_dir_is_refused|test_ordinary_values_are_still_accepted)
        sane=test_single_server_outside_the_set_is_refused ;;
    esac
    ORCH="$m" VALUE_ONLY="$sane" bash "$DIR/test_value_checks.sh" > "$TEST_TMPDIR/sane.out" 2>&1 || {
        echo "the mutant for $t also breaks $sane, so it proves nothing:" >&2
        tail -n 20 "$TEST_TMPDIR/sane.out" >&2; return 1
    }
    if ORCH="$m" VALUE_ONLY="$t" bash "$DIR/test_value_checks.sh" > "$TEST_TMPDIR/mutant.out" 2>&1; then
        echo "MUTANT SURVIVED: $t still passes with this part of the checks undone" >&2
        tail -n 20 "$TEST_TMPDIR/mutant.out" >&2
        return 1
    fi
    grep -q "FAIL  $t " "$TEST_TMPDIR/mutant.out" || {
        echo "$t did not run against the mutant:" >&2; cat "$TEST_TMPDIR/mutant.out" >&2; return 1
    }
}

# Every test in test_value_checks.sh has at least one mutation, and every
# mutation names a test that exists.
test_every_value_test_has_a_mutation() {
    local listed recorded
    listed=$(sed -n '/^VALUE_TESTS=(/,/^)/p' "$DIR/test_value_checks.sh" | grep -E '^ +test_' | tr -d ' ' | sort)
    recorded=$(printf '%s\n' "$MUTATIONS" | sed -n 's/^### //p' | sort -u)
    assert_eq "$listed" "$recorded" "tests vs mutations" || return 1
}
run_test test_every_value_test_has_a_mutation

n=0
while IFS= read -r t; do
    eval "mutation_${n}_${t#test_}() { mutant_fails $n; }"
    run_test "mutation_${n}_${t#test_}"
    n=$((n + 1))
done < <(printf '%s\n' "$MUTATIONS" | sed -n 's/^### //p')

report_tests
