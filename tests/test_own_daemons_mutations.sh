#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# Mutation tests for tests/test_own_daemons.sh (shared_tools IO-006): a
# suite that cannot fail proves nothing. Each record below undoes one part
# of the change in a copy of the orchestrator -- the text as it is now
# ('---') becomes the text as it was, or as a wrong fix would make it
# ('+++') -- and runs the test that guards that part against the copy.
# The case passes only when that test FAILS.
#
# In a record, \n stands for a newline. A mutation whose '---' text is not
# in the script exactly once fails loudly ("no longer applies") rather
# than testing nothing.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

MUTATIONS=$(cat <<'TABLE'
### test_stop_leaves_an_operators_daemon_on_the_same_port
--- : iperf-orchestrator stop-server\n
+++ : iperf-orchestrator stop-server\npkill -f '^iperf -p $IPERF_PORT ' 2>/dev/null\n
### test_start_servers_fails_when_the_port_is_taken
---     if _iolisten "$_iop"; then _ioup=1; break; else _iorc=$?; fi
+++     _ioup=1; break
### test_check_servers_reports_only_its_daemon_on_its_port
--- cd -- "$_iod" 2>/dev/null || exit 0\n[ -f "$_iopf" ] || exit 0
+++ pgrep -ax iperf | head -n1; exit 0
### test_start_servers_records_and_stop_servers_stops_its_daemon
---     kill "$_iop" 2>/dev/null || true\n    _ioi=0
+++     _ioi=0
### test_a_second_start_keeps_the_running_daemon
---     if _ioalive "$_iop"; then\n        echo "$_iohost: the iperf daemon on port $_ioport is already running (pid $_iop)"\n        exit 0\n    fi\n
+++
### test_a_stale_pid_file_is_not_trusted
--- if _ioours "$_ioa"; then\n    kill "$_iop"
+++ if :; then\n    kill "$_iop"
### test_stop_works_without_pkill_and_pgrep
--- $_DAEMON_FUNCS\n$_DAEMON_STOP"\n}
+++ pkill -f '^iperf -p $IPERF_PORT ' 2>/dev/null; true"\n}
### test_a_missing_ip_is_named
---     command -v ip >/dev/null 2>&1 \\n        || { echo "ERROR: $_iohost: --server-bind needs the 'ip' command, which is not on this host" >&2; exit 1; }\n
+++
### test_a_missing_ip_is_named
---                 command -v ip >/dev/null 2>&1 || { echo NO-IP; exit 0; }\n
+++
### test_cleanup_keeps_a_running_daemons_pid_file
--- in *'iperf -p '*) echo
+++ in *'NEVER MATCHES '*) echo
### test_listening_is_checked_with_ss_on_real_sockets
--- 'index($0, me) { n = split($4, a, ":"); if (a[n] == p) f = 1 } END { exit !f }'
+++ '{ f = 1 } END { exit !f }'
### test_listening_is_checked_through_proc_without_ss
---             ls -l "/proc/$1/fd" 2>/dev/null | grep -q "socket:\[$_ioino\]" && return 0
+++             return 0
### test_listening_is_checked_through_proc_without_ss
---         _iohp=$(printf ':%04X' "$_ioport")
+++         _iohp=$(printf ':%04x' "$_ioport")
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
        assert lines[i + 1].startswith("--- ") and lines[i + 2].startswith("+++"), line
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
    local sane=test_a_missing_ip_is_named
    [ "$t" = "$sane" ] && sane=test_check_servers_reports_only_its_daemon_on_its_port
    ORCH="$m" OWN_ONLY="$sane" bash "$DIR/test_own_daemons.sh" > "$TEST_TMPDIR/sane.out" 2>&1 || {
        echo "the mutant for $t also breaks $sane, so it proves nothing:" >&2
        tail -n 20 "$TEST_TMPDIR/sane.out" >&2; return 1
    }
    if ORCH="$m" OWN_ONLY="$t" bash "$DIR/test_own_daemons.sh" > "$TEST_TMPDIR/mutant.out" 2>&1; then
        echo "MUTANT SURVIVED: $t still passes with this part undone" >&2
        tail -n 20 "$TEST_TMPDIR/mutant.out" >&2
        return 1
    fi
    grep -q "FAIL  $t " "$TEST_TMPDIR/mutant.out" || {
        echo "$t did not run against the mutant:" >&2; cat "$TEST_TMPDIR/mutant.out" >&2; return 1
    }
}

# Every test in test_own_daemons.sh has at least one mutation, and every
# mutation names a test that exists.
test_every_own_daemon_test_has_a_mutation() {
    local listed recorded
    listed=$(sed -n '/^OWN_TESTS=(/,/^)/p' "$DIR/test_own_daemons.sh" | grep -E '^ +test_' | tr -d ' ' | sort)
    recorded=$(printf '%s\n' "$MUTATIONS" | sed -n 's/^### //p' | sort -u)
    assert_eq "$listed" "$recorded" "tests vs mutations" || return 1
}
run_test test_every_own_daemon_test_has_a_mutation

n=0
while IFS= read -r t; do
    skip=0
    case "$t" in
        # These skip (pass) without ss or /proc, so their mutants would
        # survive for the wrong reason.
        test_listening_is_checked_with_ss_on_real_sockets)
            command -v ss >/dev/null 2>&1 || skip=1 ;;
        test_listening_is_checked_through_proc_without_ss)
            [ -r /proc/net/tcp ] || skip=1 ;;
    esac
    if [ "$skip" = 0 ]; then
        eval "mutation_${n}_${t#test_}() { mutant_fails $n; }"
        run_test "mutation_${n}_${t#test_}"
    fi
    n=$((n + 1))
done < <(printf '%s\n' "$MUTATIONS" | sed -n 's/^### //p')

report_tests
