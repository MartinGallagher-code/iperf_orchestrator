#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# Mutation tests for tests/test_adversarial.sh (shared_tools IO-001): a
# suite that cannot fail proves nothing. Each record below reverts ONE fix
# in a copy of the orchestrator -- the text as it is now ('---') becomes
# the text as it was before the fix ('+++') -- and runs the test that
# guards that fix against the copy. The case passes only when that test
# FAILS. A test may guard several fixes, one record each.
#
# A mutation whose '---' text is no longer in the script fails loudly
# ("no longer applies") rather than testing nothing: when a fix moves,
# move its mutation with it.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# One record per fix: '### <test>', then the text to find ('--- ') and
# what it becomes ('+++ '). Matched exactly, whitespace included; every
# occurrence is replaced.
MUTATIONS=$(cat <<'TABLE'
### test_remote_dir_quote_reaches_host_literally_in_cleanup
---     ssh_run "$host" "rm -rf $(_shq "$REMOTE_DIR")"
+++     ssh_run "$host" "rm -rf '$REMOTE_DIR'"
### test_server_bind_quote_reaches_host_literally
---         BIND_RAW=$(_shq "$IPERF_SERVER_BIND")
+++         BIND_RAW='$IPERF_SERVER_BIND'
### test_bind_quote_reaches_host_literally_in_peer_probe
---                 BIND_RAW=$(_shq "$pattern")
+++                 BIND_RAW='$pattern'
### test_run_id_metacharacters_stay_literal_in_collect
---             ls iperf_test_*_$(_bare "$RUN_ID").log 2>/dev/null || true
+++             ls iperf_test_*_${RUN_ID}.log 2>/dev/null || true
### test_run_id_with_a_space_does_not_delete_files_on_the_host
---     _sqin_to rd "$REMOTE_DIR"; rid=$(_bare "$RUN_ID")
+++     _sqin_to rd "$REMOTE_DIR"; rid=$RUN_ID
### test_run_id_glob_does_not_delete_other_runs_logs
---     _sqin_to rd "$REMOTE_DIR"; rid=$(_bare "$RUN_ID")
+++     _sqin_to rd "$REMOTE_DIR"; rid=$RUN_ID
### test_status_progress_keeps_run_id_literal
---             logs=\$(ls iperf_test_$(_bare "$safe")_to_*_$(_bare "$run").log 2>/dev/null | wc -l | tr -d ' ')
+++             logs=\$(ls iperf_test_${safe}_to_*_${run}.log 2>/dev/null | wc -l | tr -d ' ')
### test_sequential_pair_target_stays_literal
---         [ -n "$target" ] && arg=" $(_shq "$target")"
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
### test_rolling_hostile_host_stays_literal_on_older_bash
---                 counts[\"\$target\"]=\$((c + 1))
+++                 counts[\"\$target\"]=\$((counts[\"\$target\"] + 1))
### test_grid_host_name_stays_literal_in_hints_on_older_bash
---                 edges=$(( edges + ${GRID_TX_COUNT[$gh]:-0} ))
+++                 edges=$(( edges + GRID_TX_COUNT[$gh] ))
### test_grid_host_name_stays_literal_in_gen_on_older_bash
---                 edges=$(( edges + ${GRID_TX_COUNT[$gh2]:-0} ))
+++                 edges=$(( edges + GRID_TX_COUNT[$gh2] ))
### test_newline_in_run_id_cannot_add_a_line_to_run_script
--- # Run ID:      $(_cmt "$RUN_ID")
+++ # Run ID:      $RUN_ID
### test_no_fleet_command_runs_a_hostile_value
--- _sqin_to() { local LC_ALL=C; printf -v "$1" '%s' "${2//\'/$_SQ_ESC}"; }
+++ _sqin_to() { printf -v "$1" '%s' "$2"; }
### test_no_fleet_command_runs_a_hostile_value
---             [ -n \"\$_line\" ] || { echo \"ERROR: $(_dqin "$host"): --server-bind: no interface matched '\$BIND_RAW'\" >&2; exit 1; }
+++             [ -n \"\$_line\" ] || { echo \"ERROR: $host: --server-bind: no interface matched '\$BIND_RAW'\" >&2; exit 1; }
### test_no_fleet_command_runs_a_hostile_value
---             echo \"[server-bind] $(_dqin "$host"): '\$BIND_RAW' -> ip=\$_ip\"
+++             echo \"[server-bind] $host: '\$BIND_RAW' -> ip=\$_ip\"
### test_no_fleet_command_runs_a_hostile_value
---             st=$(_shq "iperf_run_${safe}_${run}.status")
+++             st='iperf_run_${safe}_${run}.status'
### test_no_fleet_command_runs_a_hostile_value
---     _sqin_to hs "$host_safe"; _sqin_to rid "$RUN_ID"
+++     hs=$host_safe; rid=$RUN_ID
### test_no_fleet_command_runs_a_hostile_value
---     ssh_run "$host" "rm -f $(_shq "$tarball_remote")" 2>/dev/null || true
+++     ssh_run "$host" "rm -f '$tarball_remote'" 2>/dev/null || true
### test_no_fleet_command_runs_a_hostile_value
---         q_src=$(_dqin "$src"); q_safe=$(_dqin "$src_safe"); q_rid=$(_dqin "$RUN_ID")
+++         q_src=$(_dqin "$src"); q_safe=$src_safe; q_rid=$(_dqin "$RUN_ID")
### test_no_fleet_command_runs_a_hostile_value
---         _sqin_to rd "$REMOTE_DIR"
+++         rd=$REMOTE_DIR
### test_no_fleet_command_runs_a_hostile_value
---         ssh_run "$src" "$(_shq "$script") $start_time$arg" > "$hostlog" 2>&1 &
+++         ssh_run "$src" "'$script' $start_time$arg" > "$hostlog" 2>&1 &
### test_ssh_destination_follows_double_dash
---     ssh $SSH_BATCH_OPTS -- "$SSH_USER@$(_ssh_host "$host")" "$@"
+++     ssh $SSH_BATCH_OPTS "$SSH_USER@$(_ssh_host "$host")" "$@"
### test_ssh_gets_bracketed_ipv6_without_brackets
---     ssh $SSH_BATCH_OPTS -- "$SSH_USER@$(_ssh_host "$host")" "$@"
+++     ssh $SSH_BATCH_OPTS -- "$SSH_USER@$host" "$@"
### test_scp_gets_bare_ipv6_in_brackets
---     scp $SSH_BATCH_OPTS -- "$src" "$SSH_USER@$sh:$dst" >/dev/null
+++     scp $SSH_BATCH_OPTS -- "$src" "$SSH_USER@$host:$dst" >/dev/null
### test_real_ssh_and_scp_reach_the_right_ipv6_host
---     scp $SSH_BATCH_OPTS -- "$src" "$SSH_USER@$sh:$dst" >/dev/null
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
### test_compromised_hosts_ip_output_stays_literal
---             _dqin_to qc "${PEER_BIND_IPS[$t]:-}"
+++             qc=${PEER_BIND_IPS[$t]:-}
### test_compromised_hosts_ip_output_stays_literal
---             _dqin_to qc "${PEER_BIND_IPS[$p]:-}"
+++             qc=${PEER_BIND_IPS[$p]:-}
### test_hostile_bind_pattern_that_matches_stays_literal
--- BIND_RAW="$(_dqin "$IPERF_BIND")"
+++ BIND_RAW="$IPERF_BIND"
### test_hostile_bind_pattern_that_matches_stays_literal
---             BIND_RAW=\"$(_dqin "$IPERF_BIND")\"
+++             BIND_RAW=\"$IPERF_BIND\"
### test_extra_args_substitution_stays_literal_in_logged_cmd
--- -P \$PARALLEL $(_dqin "$IPERF_EXTRA_ARGS") \$BIND_ARG -e -y C"
+++ -P \$PARALLEL $IPERF_EXTRA_ARGS \$BIND_ARG -e -y C"
### test_extra_args_substitution_stays_literal_in_logged_cmd
--- -P $IPERF_STREAMS $(_dqin "$IPERF_EXTRA_ARGS") \$BIND_ARG -y C\"
+++ -P $IPERF_STREAMS $IPERF_EXTRA_ARGS \$BIND_ARG -y C\"
### test_collect_over_ssh_for_a_path_with_shell_characters
---     if ! _scp_plain_path "$src"; then
+++     if false; then
### test_collect_over_ssh_for_a_path_with_shell_characters
---         local cmd; cmd="cat $(_shq "$src")"
+++         local cmd; cmd="cat '$src'"
### test_scp_from_gets_bare_ipv6_in_brackets
---     scp $SSH_BATCH_OPTS -- "$SSH_USER@$sh:$src" "$dst" >/dev/null 2>&1
+++     scp $SSH_BATCH_OPTS -- "$SSH_USER@$host:$src" "$dst" >/dev/null 2>&1
### test_create_scripts_fails_when_chmod_fails
---         chmod +x "$script" || die "create-scripts: could not make $script executable"
+++         chmod +x "$script"
### test_parallel_hosts_waits_only_for_its_own_workers
---     wait "${pids[@]}"
+++     wait
### test_trailing_newline_in_remote_dir_is_kept
--- _shq()  { local __q; _sqin_to __q "$1"; printf "'%s'" "$__q"; }
+++ _shq()  { printf "'%s'" "$(_sqin "$1")"; }
### test_quoting_holds_under_bash_4_2_rules
--- _sqin_to() { local LC_ALL=C; printf -v "$1" '%s' "${2//\'/$_SQ_ESC}"; }
+++ _sqin_to() { local LC_ALL=C; printf -v "$1" '%s' "${2//\'/\'\\\'\'}"; }
### test_backtick_in_a_gbk_locale_stays_literal
---     local LC_ALL=C __q
+++     local __q
### test_collect_keeps_only_this_hosts_cpu_status_and_server_files
---             iperf_test_*_"$RUN_ID".log|"iperf_server_${host_safe}_${RUN_ID}.log"|"iperf_run_${host_safe}_${RUN_ID}.status"|"cpu_${host_safe}_${RUN_ID}.log")
+++             iperf_test_*.log|iperf_server_*.log|iperf_run_*.status|cpu_*.log)
### test_relative_remote_dir_collects
---     _sqin_to tr_q "_results_${host_safe}_${RUN_ID}.tar.gz"
+++     _sqin_to tr_q "$tarball_remote"
### test_sigterm_during_collect_in_all_still_stops_daemons
---     [ "$own_trap" = 1 ] && trap - INT TERM
+++     trap - INT TERM
### test_dry_run_shows_the_real_transport
---     local sh; sh=$(_scp_host "$host")
+++     local sh; sh=$host
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
lines = os.environ["MUTATIONS"].split("\n")
recs = []
for i, line in enumerate(lines):
    if line.startswith("### "):
        assert lines[i + 1].startswith("--- ") and lines[i + 2].startswith("+++ "), line
        recs.append((line[4:], lines[i + 1][4:], lines[i + 2][4:]))
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
    local sane=test_create_scripts_fails_when_it_cannot_write_a_script
    [ "$t" = "$sane" ] && sane=test_ssh_gets_bracketed_ipv6_without_brackets
    ORCH="$m" ADV_ONLY="$sane" bash "$DIR/test_adversarial.sh" > "$TEST_TMPDIR/sane.out" 2>&1 || {
        echo "the mutant for $t also breaks $sane, so it proves nothing:" >&2
        tail -n 20 "$TEST_TMPDIR/sane.out" >&2; return 1
    }
    if ORCH="$m" ADV_ONLY="$t" bash "$DIR/test_adversarial.sh" > "$TEST_TMPDIR/mutant.out" 2>&1; then
        echo "MUTANT SURVIVED: $t still passes with this fix reverted" >&2
        tail -n 20 "$TEST_TMPDIR/mutant.out" >&2
        return 1
    fi
    grep -q "FAIL  $t " "$TEST_TMPDIR/mutant.out" || {
        echo "$t did not run against the mutant:" >&2; cat "$TEST_TMPDIR/mutant.out" >&2; return 1
    }
}

# Every test in test_adversarial.sh has at least one mutation, and every
# mutation names a test that exists.
test_every_adversarial_test_has_a_mutation() {
    local listed recorded
    listed=$(sed -n '/^ADV_TESTS=(/,/^)/p' "$DIR/test_adversarial.sh" | grep -E '^ +test_' | tr -d ' ' | sort)
    recorded=$(printf '%s\n' "$MUTATIONS" | sed -n 's/^### //p' | sort -u)
    assert_eq "$listed" "$recorded" "tests vs mutations" || return 1
}
run_test test_every_adversarial_test_has_a_mutation

n=0
while IFS= read -r t; do
    skip=0
    case "$t" in
        test_real_ssh_and_scp_reach_the_right_ipv6_host)
            # That test skips (passes) without the OpenSSH client, so its
            # mutant would survive for the wrong reason.
            { command -v ssh && command -v scp; } >/dev/null || skip=1 ;;
        test_sigterm_mid_round_stops_promptly_and_leaves_no_local_ssh)
            # Likewise without procps (pgrep/pkill).
            { command -v pgrep && command -v pkill; } >/dev/null || skip=1 ;;
        test_backtick_in_a_gbk_locale_stays_literal)
            # Likewise without a GBK locale to build.
            { command -v localedef && [ -e /usr/share/i18n/charmaps/GBK.gz ] \
                && [ -e /usr/share/i18n/locales/zh_CN ]; } >/dev/null || skip=1 ;;
    esac
    if [ "$skip" = 0 ]; then
        eval "mutation_${n}_${t#test_}() { mutant_fails $n; }"
        run_test "mutation_${n}_${t#test_}"
    fi
    n=$((n + 1))
done < <(printf '%s\n' "$MUTATIONS" | sed -n 's/^### //p')

report_tests
