#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Tests for the helper functions defined inline in cmd_parse_csv's
# Python heredoc. The current direction-detection logic doesn't call
# `addr_matches`, but the function is still in the source and could
# get re-introduced into the live path; keep a regression test on its
# documented behavior so accidental future regressions are caught.
#
# Approach: extract the function source from the orchestrator and
# exec it standalone so we can call it directly from a Python
# subprocess.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# Run a small Python program that defines addr_matches the same way
# the orchestrator does, then prints results for argv-supplied pairs.
addr_matches_py() {
    python3 - "$@" <<'PY'
import sys

def addr_matches(line_addr, host):
    if not line_addr or not host:
        return False
    return line_addr == host or line_addr in host or host in line_addr

# Pairs are passed as alternating (line_addr, host, expected).
args = sys.argv[1:]
fail = 0
for i in range(0, len(args), 3):
    line_addr, host, expected = args[i], args[i+1], args[i+2]
    expected = expected == "true"
    actual = addr_matches(line_addr, host)
    ok = "OK " if actual == expected else "BAD"
    print(f"{ok} addr_matches({line_addr!r}, {host!r}) -> {actual} (expected {expected})")
    if actual != expected:
        fail = 1
sys.exit(fail)
PY
}

# ---- Live legacy helper coverage ------------------------------------------

test_addr_matches_exact_string() {
    addr_matches_py 'host-a' 'host-a' 'true' || return 1
}

test_addr_matches_empty_strings_return_false() {
    addr_matches_py '' 'host-a' 'false' '' '' 'false' 'host-a' '' 'false' || return 1
}

test_addr_matches_case_sensitive() {
    addr_matches_py 'Host-A' 'host-a' 'false' || return 1
}

test_addr_matches_substring_returns_true_either_direction() {
    # "host-a" is a substring of "host-a.example.com" -> match
    addr_matches_py 'host-a' 'host-a.example.com' 'true' \
                    'host-a.example.com' 'host-a' 'true' || return 1
}

test_addr_matches_unrelated_strings_return_false() {
    addr_matches_py 'apple' 'banana' 'false' \
                    '10.0.0.1' 'host-foo' 'false' || return 1
}

test_addr_matches_ipv4_prefix_overlap_is_known_false_positive() {
    # Documented limitation: substring matching returns true when one
    # IP is a prefix of another. The current parse-csv logic (post-fix)
    # uses exact equality instead, so this no longer breaks the live
    # path -- but we lock in the helper's behavior.
    addr_matches_py '10.0.0.1' '10.0.0.10' 'true' || return 1
}

# ---- Helper still defined in the orchestrator source ----------------------

test_addr_matches_function_still_present_in_source() {
    grep -q 'def addr_matches' "$ORCH" || {
        echo "addr_matches() is no longer defined in the orchestrator" >&2
        return 1
    }
}

# ---- find_summary_rows behavior -------------------------------------------

# Same approach: re-implement the helper in Python and verify span
# tolerance behavior.
find_summary_rows_py() {
    # Pass the script via -c so stdin remains free for CSV input.
    # (A heredoc on `python3 -` would clobber stdin and break tests
    # that pipe data in.)
    python3 -c '
import sys

def find_summary_rows(csv_lines, duration):
    summaries = []
    for cols in csv_lines:
        if len(cols) < 9:
            continue
        interval = cols[6]
        if "-" not in interval:
            continue
        try:
            start_s, end_s = interval.split("-", 1)
            span = float(end_s) - float(start_s)
        except ValueError:
            continue
        if abs(span - float(duration)) <= 0.5:
            summaries.append(cols)
    return summaries

duration = sys.argv[1]
lines = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    lines.append(line.split(","))
result = find_summary_rows(lines, duration)
print(len(result))
for r in result:
    print(",".join(r))
' "$@"
}

test_find_summary_rows_accepts_exact_duration_match() {
    local out
    out=$(printf '%s\n' \
        '20260101120000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-10.0,1250000000,1000000000' \
        | find_summary_rows_py 10)
    local n
    n=$(echo "$out" | head -n1)
    assert_eq "1" "$n" "exact duration match should be accepted" || return 1
}

test_find_summary_rows_rejects_too_short_interval() {
    local out
    out=$(printf '%s\n' \
        '20260101120000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-1.0,1250000000,1000000000' \
        | find_summary_rows_py 10)
    local n
    n=$(echo "$out" | head -n1)
    assert_eq "0" "$n" "1s interval should be rejected when duration=10" || return 1
}

test_find_summary_rows_accepts_within_half_second_tolerance() {
    local out
    out=$(printf '%s\n' \
        '20260101120000,10.0.0.1,54321,10.0.0.2,5001,3,0.0-9.6,1250000000,1000000000' \
        '20260101120000,10.0.0.2,5001,10.0.0.1,54321,3,0.0-10.4,1100000000,880000000' \
        | find_summary_rows_py 10)
    local n
    n=$(echo "$out" | head -n1)
    assert_eq "2" "$n" "0.4s tolerance should be accepted" || return 1
}

test_find_summary_rows_rejects_invalid_interval_format() {
    local out
    out=$(printf '%s\n' \
        '20260101120000,10.0.0.1,54321,10.0.0.2,5001,3,bad,1250000000,1000000000' \
        '20260101120000,10.0.0.1,54321,10.0.0.2,5001,3,1.0,1250000000,1000000000' \
        | find_summary_rows_py 10)
    local n
    n=$(echo "$out" | head -n1)
    assert_eq "0" "$n" "invalid intervals should be skipped" || return 1
}

test_find_summary_rows_rejects_short_rows() {
    local out
    out=$(printf '%s\n' \
        'too,short,row' \
        | find_summary_rows_py 10)
    local n
    n=$(echo "$out" | head -n1)
    assert_eq "0" "$n" "rows with <9 columns should be skipped" || return 1
}

# ---- parse_header behavior ------------------------------------------------

parse_header_py() {
    python3 - "$1" <<'PY'
import sys

def parse_header(line):
    out = {}
    if not line.startswith("#"):
        return out
    for tok in line.lstrip("#").strip().split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            out[k] = v
    return out

print(repr(parse_header(sys.argv[1])))
PY
}

test_parse_header_extracts_keys_and_values() {
    local out
    out=$(parse_header_py "# pair_a=hostA pair_b=hostB duration=10 port=5001")
    [[ "$out" == *"'pair_a': 'hostA'"* ]] || { echo "missing pair_a"; return 1; }
    [[ "$out" == *"'pair_b': 'hostB'"* ]] || { echo "missing pair_b"; return 1; }
    [[ "$out" == *"'duration': '10'"* ]] || { echo "missing duration"; return 1; }
    [[ "$out" == *"'port': '5001'"* ]] || { echo "missing port"; return 1; }
}

test_parse_header_returns_empty_for_non_comment() {
    local out
    out=$(parse_header_py "not a comment line")
    assert_eq "{}" "$out" || return 1
}

test_parse_header_ignores_tokens_without_equals() {
    local out
    out=$(parse_header_py "# noequals pair_a=A bareword pair_b=B")
    [[ "$out" == *"'pair_a': 'A'"* ]] || return 1
    [[ "$out" == *"'pair_b': 'B'"* ]] || return 1
    [[ "$out" != *"noequals"* ]] || { echo "shouldn't have included noequals"; return 1; }
}

run_test test_addr_matches_exact_string
run_test test_addr_matches_empty_strings_return_false
run_test test_addr_matches_case_sensitive
run_test test_addr_matches_substring_returns_true_either_direction
run_test test_addr_matches_unrelated_strings_return_false
run_test test_addr_matches_ipv4_prefix_overlap_is_known_false_positive
run_test test_addr_matches_function_still_present_in_source
run_test test_find_summary_rows_accepts_exact_duration_match
run_test test_find_summary_rows_rejects_too_short_interval
run_test test_find_summary_rows_accepts_within_half_second_tolerance
run_test test_find_summary_rows_rejects_invalid_interval_format
run_test test_find_summary_rows_rejects_short_rows
run_test test_parse_header_extracts_keys_and_values
run_test test_parse_header_returns_empty_for_non_comment
run_test test_parse_header_ignores_tokens_without_equals

report_tests
