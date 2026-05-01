#!/usr/bin/env bash
#
# Top-level test runner. Discovers every `test_*.sh` file in this
# directory and runs each as its own bash subprocess so a fatal error in
# one file can't take down the rest of the suite.
#
# Usage:
#   tests/run_tests.sh                  # run everything
#   tests/run_tests.sh test_state.sh    # run a single file
#   tests/run_tests.sh -v               # verbose (show test stdout)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ORCH="$REPO_ROOT/iperf_orchestrator.sh"
export REPO_ROOT ORCH

if [ ! -x "$ORCH" ]; then
    echo "ERROR: $ORCH not found or not executable" >&2
    exit 2
fi

VERBOSE=0
files=()
for arg in "$@"; do
    case "$arg" in
        -v|--verbose) VERBOSE=1 ;;
        *) files+=("$arg") ;;
    esac
done

if [ ${#files[@]} -eq 0 ]; then
    while IFS= read -r f; do
        files+=("$f")
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -name 'test_*.sh' -type f | sort)
fi

if [ ${#files[@]} -eq 0 ]; then
    echo "No test_*.sh files found in $SCRIPT_DIR" >&2
    exit 2
fi

total_files=${#files[@]}
file_pass=0
file_fail=0
failed_files=()

echo "iperf-orchestrator test suite"
echo "  orchestrator: $ORCH"
echo "  test files:   $total_files"
echo

for f in "${files[@]}"; do
    [ -f "$f" ] || f="$SCRIPT_DIR/$f"
    name="$(basename "$f")"
    echo "==> $name"
    if [ "$VERBOSE" -eq 1 ]; then
        bash "$f"
        rc=$?
    else
        out=$(bash "$f" 2>&1)
        rc=$?
        # Always print the file's pass/fail summary lines (lines that
        # start with two spaces + PASS/FAIL or the trailing report).
        printf '%s\n' "$out" | sed -n '/^    \(PASS\|FAIL\)/p; /^  ran:/,/^  failed:/p; /^  ----/p'
        if [ "$rc" -ne 0 ]; then
            # On failure show the full output so the failure is debuggable.
            echo "--- full output ---"
            printf '%s\n' "$out"
            echo "--- end ---"
        fi
    fi
    if [ "$rc" -eq 0 ]; then
        file_pass=$((file_pass+1))
    else
        file_fail=$((file_fail+1))
        failed_files+=("$name")
    fi
    echo
done

echo "========================================"
echo "Test files run:    $total_files"
echo "Test files passed: $file_pass"
echo "Test files failed: $file_fail"
if [ "$file_fail" -ne 0 ]; then
    printf '  %s\n' "${failed_files[@]}"
    exit 1
fi
exit 0
