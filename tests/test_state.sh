#!/usr/bin/env bash
# Tests for the load_state / save_state / set_state / get_state helpers
# and the on-disk state file format.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

test_get_state_returns_no_for_unset_key() {
    source_orch
    local v
    v=$(get_state SOMETHING_RANDOM)
    assert_eq "no" "$v" "unset keys should default to 'no'"
}

test_set_state_then_get_state_roundtrip() {
    source_orch
    set_state FOO bar
    local v
    v=$(get_state FOO)
    assert_eq "bar" "$v"
}

test_set_state_persists_across_loads() {
    source_orch
    set_state TESTS_RUN yes
    set_state CSV_BUILT yes
    # Wipe in-memory STATE and reload from disk.
    unset STATE
    declare -gA STATE
    load_state
    assert_eq "yes" "${STATE[TESTS_RUN]}" "TESTS_RUN should persist" || return 1
    assert_eq "yes" "${STATE[CSV_BUILT]}" "CSV_BUILT should persist" || return 1
}

test_state_file_format_is_key_equals_value() {
    source_orch
    set_state HOST_COUNT 42
    set_state RUN_MODE parallel
    [ -f "$STATE_FILE" ] || { echo "state file missing" >&2; return 1; }
    grep -q '^HOST_COUNT=42$' "$STATE_FILE" || {
        echo "key=value format missing for HOST_COUNT" >&2
        cat "$STATE_FILE" >&2
        return 1
    }
    grep -q '^RUN_MODE=parallel$' "$STATE_FILE" || {
        echo "key=value format missing for RUN_MODE" >&2
        return 1
    }
}

test_load_state_skips_blank_and_comment_lines() {
    source_orch
    mkdir -p "$IPERF_DIR"
    cat > "$STATE_FILE" <<'EOF'
# this is a comment
KEY1=alpha

KEY2=beta
# another comment
EOF
    load_state
    assert_eq "alpha" "${STATE[KEY1]}" "KEY1 should be alpha" || return 1
    assert_eq "beta" "${STATE[KEY2]}" "KEY2 should be beta" || return 1
}

test_save_state_overwrites_atomically() {
    source_orch
    set_state K1 v1
    # The implementation writes to STATE_FILE.tmp then renames; verify
    # the temp file isn't left lying around after a normal save.
    [ ! -f "$STATE_FILE.tmp" ] || {
        echo "tmp file should have been renamed away" >&2
        return 1
    }
    set_state K2 v2
    [ ! -f "$STATE_FILE.tmp" ] || {
        echo "tmp file should have been renamed away after second save" >&2
        return 1
    }
    # Both keys are present.
    grep -q '^K1=v1$' "$STATE_FILE" || return 1
    grep -q '^K2=v2$' "$STATE_FILE" || return 1
}

test_set_state_overwrites_existing_key() {
    source_orch
    set_state RUN_MODE parallel
    set_state RUN_MODE sequential-pair
    local v
    v=$(get_state RUN_MODE)
    assert_eq "sequential-pair" "$v" "second set should win" || return 1
    # Make sure we don't have two RUN_MODE= lines.
    local count
    count=$(grep -c '^RUN_MODE=' "$STATE_FILE")
    assert_eq "1" "$count" "only one line per key in state file" || return 1
}

run_test test_get_state_returns_no_for_unset_key
run_test test_set_state_then_get_state_roundtrip
run_test test_set_state_persists_across_loads
run_test test_state_file_format_is_key_equals_value
run_test test_load_state_skips_blank_and_comment_lines
run_test test_save_state_overwrites_atomically
run_test test_set_state_overwrites_existing_key

report_tests
