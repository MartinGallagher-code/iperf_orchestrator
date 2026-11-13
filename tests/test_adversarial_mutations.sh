#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# Mutation tests for tests/test_adversarial.sh (shared_tools IO-001): a
# suite that cannot fail proves nothing. Each case below reverts ONE fix
# in a copy of the orchestrator -- the line as it is now ('---') becomes
# the line as 2.6.3 had it ('+++') -- and runs the test that guards that
# fix against the copy. The case passes only when that test FAILS.
#
# A mutation whose '---' line is no longer in the script fails loudly
# ("no longer applies") rather than testing nothing: when a fix moves,
# move its mutation with it.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# One record per guarded test: '### <test>', then the line to find ('--- ')
# and what it becomes ('+++ '). Every line is matched exactly, whitespace
# included, and every occurrence is replaced.
MUTATIONS=$(cat <<'TABLE'
### test_remote_dir_quote_reaches_host_literally_in_cleanup
---     ssh_run "$host" "rm -rf '$(_sqin "$REMOTE_DIR")'"
+++     ssh_run "$host" "rm -rf '$REMOTE_DIR'"
### test_server_bind_quote_reaches_host_literally
---         BIND_RAW='$(_sqin "$IPERF_SERVER_BIND")'
+++         BIND_RAW='$IPERF_SERVER_BIND'
### test_bind_quote_reaches_host_literally_in_peer_probe
---                 BIND_RAW='$(_sqin "$pattern")'
+++                 BIND_RAW='$pattern'
### test_run_id_metacharacters_stay_literal_in_collect
---             ls iperf_test_*_$(_bare "$RUN_ID").log 2>/dev/null || true
+++             ls iperf_test_*_${RUN_ID}.log 2>/dev/null || true
### test_run_id_with_a_space_does_not_delete_files_on_the_host
---     rd=$(_sqin "$REMOTE_DIR"); rid=$(_bare "$RUN_ID")
+++     rd=$(_sqin "$REMOTE_DIR"); rid=$RUN_ID
### test_run_id_glob_does_not_delete_other_runs_logs
---     rd=$(_sqin "$REMOTE_DIR"); rid=$(_bare "$RUN_ID")
+++     rd=$(_sqin "$REMOTE_DIR"); rid=$RUN_ID
### test_status_progress_keeps_run_id_literal
---             logs=\$(ls iperf_test_$(_bare "$safe")_to_*_$(_bare "$run").log 2>/dev/null | wc -l | tr -d ' ')
+++             logs=\$(ls iperf_test_${safe}_to_*_${run}.log 2>/dev/null | wc -l | tr -d ' ')
### test_sequential_pair_target_stays_literal
---         [ -n "$target" ] && arg=" '$(_sqin "$target")'"
+++         [ -n "$target" ] && arg=" '$target'"
### test_hostile_host_reaches_iperf_as_one_literal_argument
---             _dqin_to qt "$t"
+++             qt=$t
### test_hostile_bandwidth_reaches_iperf_as_literal_words
--- -P "\$PARALLEL" $IPERF_EXTRA_ARGS_Q \$BIND_ARG -e -y C
+++ -P "\$PARALLEL" $IPERF_EXTRA_ARGS \$BIND_ARG -e -y C
### test_bandwidth_with_spaces_still_splits_into_words
--- IPERF_EXTRA_ARGS_Q=$(_iperf_extra_args_q)
+++ IPERF_EXTRA_ARGS_Q=$(_shq "$IPERF_EXTRA_ARGS")
### test_rolling_hostile_host_stays_literal
---             _dqin_to qp "$p"
+++             qp=$p
### test_rolling_hostile_bandwidth_stays_literal
--- -P $IPERF_STREAMS $IPERF_EXTRA_ARGS_Q \$BIND_ARG -y C
+++ -P $IPERF_STREAMS $IPERF_EXTRA_ARGS \$BIND_ARG -y C
### test_newline_in_run_id_cannot_add_a_line_to_run_script
--- # Run ID:      $(_cmt "$RUN_ID")
+++ # Run ID:      $RUN_ID
### test_no_fleet_command_runs_a_hostile_value
--- _sqin() { printf '%s' "${1//\'/\'\\\'\'}"; }
+++ _sqin() { printf '%s' "$1"; }
### test_ssh_destination_follows_double_dash
---     ssh $SSH_BATCH_OPTS -- "$SSH_USER@$(_ssh_host "$host")" "$@"
+++     ssh $SSH_BATCH_OPTS "$SSH_USER@$(_ssh_host "$host")" "$@"
### test_ssh_gets_bracketed_ipv6_without_brackets
---     ssh $SSH_BATCH_OPTS -- "$SSH_USER@$(_ssh_host "$host")" "$@"
+++     ssh $SSH_BATCH_OPTS -- "$SSH_USER@$host" "$@"
### test_scp_gets_bare_ipv6_in_brackets
---     scp $SSH_BATCH_OPTS -- "$src" "$SSH_USER@$(_scp_host "$host"):$dst" >/dev/null
+++     scp $SSH_BATCH_OPTS -- "$src" "$SSH_USER@$host:$dst" >/dev/null
### test_real_ssh_and_scp_reach_the_right_ipv6_host
---     scp $SSH_BATCH_OPTS -- "$src" "$SSH_USER@$(_scp_host "$host"):$dst" >/dev/null
+++     scp $SSH_BATCH_OPTS -- "$src" "$SSH_USER@$host:$dst" >/dev/null
### test_remote_path_with_shell_characters_goes_over_ssh_not_scp
---     if ! _scp_plain_path "$dst"; then
+++     if false; then
### test_collect_keeps_only_regular_run_files
---     tarout=$(tar -xzf "$tarball_local" -C "$xdir" 2>&1)
+++     tarout=$(tar -xzf "$tarball_local" -C "$RESULTS_DIR" 2>&1)
### test_collect_does_not_fetch_a_stale_tarball
---         rm -f '$tr_q'
+++         :
### test_create_scripts_fails_when_it_cannot_write_a_script
---         cat > "$script" <<EOF || die "create-scripts: could not write $script"
+++         cat > "$script" <<EOF
### test_sigterm_mid_round_stops_promptly_and_leaves_no_local_ssh
---     for j in $(jobs -p); do
+++     for j in; do
TABLE
)
export MUTATIONS

# mutant_fails TEST: build the mutant for TEST, run TEST against it, and
# succeed only if TEST fails there.
mutant_fails() {
    local t="$1" m="$TEST_TMPDIR/mutant/iperf_orchestrator.sh"
    mkdir -p "${m%/*}"
    python3 - "$ORCH" "$m" "$t" <<'PY' || return 1
import os, sys
src, dst, test = sys.argv[1:]
old = new = None
lines = os.environ["MUTATIONS"].split("\n")
for i, line in enumerate(lines):
    if line == "### " + test:
        old, new = lines[i + 1][4:], lines[i + 2][4:]
        assert lines[i + 1].startswith("--- ") and lines[i + 2].startswith("+++ ")
        break
if old is None:
    sys.exit("no mutation recorded for " + test)
text = open(src).read()
hits = sum(1 for l in text.split("\n") if l == old) or text.count(old)
if not hits:
    sys.exit("mutation no longer applies, line not found: " + old)
open(dst, "w").write(text.replace(old, new))
PY
    chmod +x "$m"
    bash -n "$m" || { echo "the mutant for $t does not parse" >&2; return 1; }
    # A mutant that is merely broken would fail every test; one test that
    # the mutation does not touch must still pass against it.
    local sane=test_create_scripts_fails_when_it_cannot_write_a_script
    [ "$t" = "$sane" ] && sane=test_ssh_gets_bracketed_ipv6_without_brackets
    ORCH="$m" ADV_ONLY="$sane" bash "$DIR/test_adversarial.sh" > "$TEST_TMPDIR/sane.out" 2>&1 || {
        echo "the mutant for $t also breaks $sane, so it proves nothing:" >&2
        tail -n 20 "$TEST_TMPDIR/sane.out" >&2; return 1
    }
    if ORCH="$m" ADV_ONLY="$t" bash "$DIR/test_adversarial.sh" > "$TEST_TMPDIR/mutant.out" 2>&1; then
        echo "MUTANT SURVIVED: $t still passes with its fix reverted" >&2
        tail -n 20 "$TEST_TMPDIR/mutant.out" >&2
        return 1
    fi
    grep -q "FAIL  $t " "$TEST_TMPDIR/mutant.out" || {
        echo "$t did not run against the mutant:" >&2; cat "$TEST_TMPDIR/mutant.out" >&2; return 1
    }
}

# Every test in test_adversarial.sh has a mutation, and every mutation a test.
test_every_adversarial_test_has_a_mutation() {
    local listed recorded
    listed=$(sed -n '/^ADV_TESTS=(/,/^)/p' "$DIR/test_adversarial.sh" | grep -E '^ +test_' | tr -d ' ' | sort)
    recorded=$(printf '%s\n' "$MUTATIONS" | sed -n 's/^### //p' | sort)
    assert_eq "$listed" "$recorded" "tests vs mutations" || return 1
}
run_test test_every_adversarial_test_has_a_mutation

while IFS= read -r t; do
    case "$t" in
        test_real_ssh_and_scp_reach_the_right_ipv6_host)
            # That test skips (passes) without the OpenSSH client, so its
            # mutant would survive for the wrong reason.
            command -v ssh >/dev/null && command -v scp >/dev/null || continue ;;
        test_sigterm_mid_round_stops_promptly_and_leaves_no_local_ssh)
            # Likewise without procps (pgrep/pkill).
            command -v pgrep >/dev/null && command -v pkill >/dev/null || continue ;;
    esac
    eval "mutation_${t#test_}() { mutant_fails $t; }"
    run_test "mutation_${t#test_}"
done < <(printf '%s\n' "$MUTATIONS" | sed -n 's/^### //p')

report_tests
