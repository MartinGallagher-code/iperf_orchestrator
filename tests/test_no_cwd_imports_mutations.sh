#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# Mutation tests for tests/test_no_cwd_imports.sh (shared_tools IO-010): a
# suite that cannot fail proves nothing. Each record below undoes the fix
# for ONE step in a copy of the orchestrator -- the text as it is now
# ('---') becomes the text as it was, or as a wrong fix would make it
# ('+++') -- and runs the test that guards that step against the copy.
# The case passes only when that test FAILS.
#
# In a record, {GUARD} stands for the line each heredoc starts with and
# \n for a newline. A mutation whose '---' text is no longer in the script
# fails loudly ("no longer applies") rather than testing nothing.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

MUTATIONS=$(cat <<'TABLE'
### test_parse_csv_ignores_modules_in_cwd
--- "$PYTHON_BIN" - "$RESULTS_DIR" "$csv" "$active_list" <<'PYEOF'\n{GUARD}\n
+++ "$PYTHON_BIN" - "$RESULTS_DIR" "$csv" "$active_list" <<'PYEOF'\n
### test_parse_cpu_ignores_modules_in_cwd
--- "$PYTHON_BIN" - "$RESULTS_DIR" "$cpu_csv" "$active_list" <<'PYEOF'\n{GUARD}\n
+++ "$PYTHON_BIN" - "$RESULTS_DIR" "$cpu_csv" "$active_list" <<'PYEOF'\n
### test_make_pivot_ignores_modules_in_cwd
--- "$meta_run_at" "$meta_mode" "$meta_n_hosts" <<'PYEOF'\n{GUARD}\n
+++ "$meta_run_at" "$meta_mode" "$meta_n_hosts" <<'PYEOF'\n
### test_make_heatmap_ignores_modules_in_cwd
--- "$meta_run_at" "$meta_mode" "$meta_duration" <<'PYEOF'\n{GUARD}\n
+++ "$meta_run_at" "$meta_mode" "$meta_duration" <<'PYEOF'\n
### test_results_summary_ignores_modules_in_cwd
--- "$PYTHON_BIN" - "$csv" "$cpu_csv" "$PROG" <<'PYEOF'\n{GUARD}\n
+++ "$PYTHON_BIN" - "$csv" "$cpu_csv" "$PROG" <<'PYEOF'\n
### test_export_overlay_ignores_modules_in_cwd
--- "$peer_counts" "$IPERF_BANDWIDTH" <<'PYEOF'\n{GUARD}\n
+++ "$peer_counts" "$IPERF_BANDWIDTH" <<'PYEOF'\n
### test_doctor_ignores_modules_in_cwd
--- -c "$PY_NO_CWD; import $mod
+++ -c "import $mod
### test_absolute_pythonpath_entries_still_work
--- "$PYTHON_BIN" - "$csv" "$cpu_csv" "$PROG" <<'PYEOF'
+++ "$PYTHON_BIN" -I - "$csv" "$cpu_csv" "$PROG" <<'PYEOF'
### test_every_heredoc_starts_with_the_guard
--- "$PYTHON_BIN" - "$RESULTS_DIR" "$csv" "$active_list" <<'PYEOF'\n{GUARD}\n
+++ "$PYTHON_BIN" - "$RESULTS_DIR" "$csv" "$active_list" <<'PYEOF'\n
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
GUARD = 'import sys; sys.path[:] = [p for p in sys.path if p not in ("", ".")]  # PY_NO_CWD (IO-010)'
def expand(s):
    return s.replace("{GUARD}", GUARD).replace("\\n", "\n")
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
    local sane=test_make_pivot_ignores_modules_in_cwd
    [ "$t" = "$sane" ] && sane=test_parse_cpu_ignores_modules_in_cwd
    ORCH="$m" NOCWD_ONLY="$sane" bash "$DIR/test_no_cwd_imports.sh" > "$TEST_TMPDIR/sane.out" 2>&1 || {
        echo "the mutant for $t also breaks $sane, so it proves nothing:" >&2
        tail -n 20 "$TEST_TMPDIR/sane.out" >&2; return 1
    }
    if ORCH="$m" NOCWD_ONLY="$t" bash "$DIR/test_no_cwd_imports.sh" > "$TEST_TMPDIR/mutant.out" 2>&1; then
        echo "MUTANT SURVIVED: $t still passes with this fix reverted" >&2
        tail -n 20 "$TEST_TMPDIR/mutant.out" >&2
        return 1
    fi
    grep -q "FAIL  $t " "$TEST_TMPDIR/mutant.out" || {
        echo "$t did not run against the mutant:" >&2; cat "$TEST_TMPDIR/mutant.out" >&2; return 1
    }
}

# Every test in test_no_cwd_imports.sh has at least one mutation, and
# every mutation names a test that exists.
test_every_no_cwd_test_has_a_mutation() {
    local listed recorded
    listed=$(sed -n '/^NOCWD_TESTS=(/,/^)/p' "$DIR/test_no_cwd_imports.sh" | grep -E '^ +test_' | tr -d ' ' | sort)
    recorded=$(printf '%s\n' "$MUTATIONS" | sed -n 's/^### //p' | sort -u)
    assert_eq "$listed" "$recorded" "tests vs mutations" || return 1
}
run_test test_every_no_cwd_test_has_a_mutation

have_plotting=0
python3 -c 'import matplotlib, numpy' >/dev/null 2>&1 && have_plotting=1

n=0
while IFS= read -r t; do
    skip=0
    case "$t" in
        test_make_heatmap_ignores_modules_in_cwd|test_doctor_ignores_modules_in_cwd)
            # Those tests skip (pass) without matplotlib and numpy, so
            # their mutants would survive for the wrong reason.
            [ "$have_plotting" = 1 ] || skip=1 ;;
    esac
    if [ "$skip" = 0 ]; then
        eval "mutation_${n}_${t#test_}() { mutant_fails $n; }"
        run_test "mutation_${n}_${t#test_}"
    fi
    n=$((n + 1))
done < <(printf '%s\n' "$MUTATIONS" | sed -n 's/^### //p')

report_tests
