#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
# Meta-tests: the CLI's documented surface and the dispatcher must
# agree, the script must remain executable from anywhere, and the
# usage text must mention every subcommand the dispatcher knows.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

# ---- Bash syntax & safety -------------------------------------------------

test_orchestrator_passes_bash_n() {
    bash -n "$ORCH" || {
        echo "syntax check failed" >&2
        return 1
    }
}

test_orchestrator_is_executable() {
    [ -x "$ORCH" ] || {
        echo "$ORCH should be executable" >&2
        return 1
    }
}

test_orchestrator_uses_set_u() {
    grep -q '^set -u' "$ORCH" || {
        echo "expected 'set -u' near the top of the script" >&2
        return 1
    }
}

# ---- Dispatcher / docs cross-check ----------------------------------------

# Every subcommand listed in the dispatcher case-statement (line ~1846)
# is exercised here by sending it -h/--help-equivalent input or the
# full pipeline; for safety we just check it dispatches without
# exiting 2 (the "unknown command" sentinel).
test_every_documented_subcommand_is_dispatched() {
    local subcommands=(
        init status ssh-setup
        check-iperf check-servers
        start-servers create-scripts distribute-scripts
        run-tests collect-results stop-servers cleanup
        parse-csv parse-cpu make-pivot make-heatmap
        all help
    )
    local cmd
    for cmd in "${subcommands[@]}"; do
        # Fresh tmpdir so cmds that write state don't bleed.
        rm -rf "$IPERF_DIR"
        run_orch "$cmd" 2>/dev/null
        # We don't assert success (most need a server list) -- only
        # that the dispatcher did NOT print "Unknown command".
        if echo "$RUN_OUT" | grep -q "Unknown command"; then
            echo "subcommand '$cmd' was rejected as unknown" >&2
            return 1
        fi
    done
}

test_help_text_lists_every_subcommand() {
    run_orch help
    # Ground truth: scrape the dispatcher case statement for tokens
    # that look like subcommands. The dispatcher block sits between
    # `case "$cmd" in` and the next `esac`. Lines like "    foo)" and
    # "    foo|bar)" yield the leading bare-word token.
    local dispatched
    dispatched=$(sed -n '/^case "\$cmd" in/,/^esac$/p' "$ORCH" \
        | grep -oE '^[[:space:]]+[a-z][a-z0-9_-]*[)|]' \
        | sed -E 's/^[[:space:]]+//; s/[)|]$//' \
        | sort -u)
    [ -n "$dispatched" ] || {
        echo "could not extract dispatcher subcommands from script" >&2
        return 1
    }
    local cmd missing=()
    while IFS= read -r cmd; do
        # 'help' is implicit and the dispatcher also accepts -h/--help/"".
        case "$cmd" in
            help) continue ;;
        esac
        if ! echo "$RUN_OUT" | grep -q -- "$cmd"; then
            missing+=("$cmd")
        fi
    done <<< "$dispatched"
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "subcommands missing from help text:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

test_help_text_documents_every_long_flag() {
    run_orch help
    # Extract long flags from case-statement patterns specifically:
    # lines that look like "    --port)" or "    --port=*)". This
    # avoids false positives from prose comments and the SSH_OPTS
    # default-value substitution that contains "-o" tokens.
    local flags
    flags=$(grep -oE '^[[:space:]]+--[a-z][a-z0-9-]*(\|-[a-zA-Z])?(=\*)?\)' "$ORCH" \
        | grep -oE -- '--[a-z][a-z0-9-]*' \
        | sort -u)
    [ -n "$flags" ] || {
        echo "could not extract flags from script" >&2
        return 1
    }
    local f missing=()
    while IFS= read -r f; do
        # `--` is the end-of-flags sentinel, not a flag itself.
        [ "$f" = "--" ] && continue
        if ! echo "$RUN_OUT" | grep -qF -- "$f"; then
            missing+=("$f")
        fi
    done <<< "$flags"
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "flags missing from help text:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

# ---- Status / state cross-check -------------------------------------------

test_status_lists_every_pipeline_state_key() {
    # The keys printed by `status` should cover every set_state call
    # in the script. If a new state key gets added without updating
    # the status display, the user can't see it.
    local set_keys
    set_keys=$(grep -oE 'set_state [A-Z_]+' "$ORCH" | awk '{print $2}' | sort -u)
    # TESTS_RUN_MODE is a value-store (mode string), not a yes/no
    # progression flag. Excluded from the status list by design.
    set_keys=$(echo "$set_keys" | grep -v '^TESTS_RUN_MODE$')

    run_orch status
    local key missing=()
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        if ! echo "$RUN_OUT" | grep -q -E "^[[:space:]]*$key[[:space:]]"; then
            missing+=("$key")
        fi
    done <<< "$set_keys"
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "state keys not displayed in status output:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

# ---- Help text content ----------------------------------------------------

test_help_includes_all_three_run_modes() {
    run_orch help
    assert_contains "$RUN_OUT" "parallel" "should mention parallel mode" || return 1
    assert_contains "$RUN_OUT" "sequential-host" || return 1
    assert_contains "$RUN_OUT" "sequential-pair" || return 1
}

test_help_includes_files_section() {
    run_orch help
    assert_contains "$RUN_OUT" "FILES:" "should have a FILES: section" || return 1
    assert_contains "$RUN_OUT" "Server list:" || return 1
    assert_contains "$RUN_OUT" "Results:" || return 1
}

test_help_includes_setup_quickstart() {
    run_orch help
    # The README points at a 3-step quickstart we want exposed in help.
    assert_contains "$RUN_OUT" "init" "help should mention init" || return 1
    assert_contains "$RUN_OUT" "ssh-setup" "help should mention ssh-setup" || return 1
}

run_test test_orchestrator_passes_bash_n
run_test test_orchestrator_is_executable
run_test test_orchestrator_uses_set_u
run_test test_every_documented_subcommand_is_dispatched
run_test test_help_text_lists_every_subcommand
run_test test_help_text_documents_every_long_flag
run_test test_status_lists_every_pipeline_state_key
run_test test_help_includes_all_three_run_modes
run_test test_help_includes_files_section
run_test test_help_includes_setup_quickstart

report_tests
