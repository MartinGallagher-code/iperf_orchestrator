#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

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
        status
        check-iperf check-servers
        start-servers create-scripts distribute-scripts
        run-tests collect-results stop-servers cleanup
        parse-csv parse-cpu make-pivot make-heatmap
        all help version
    )
    local cmd
    for cmd in "${subcommands[@]}"; do
        rm -rf "$RESULTS_BASE"
        run_orch "$cmd" 2>/dev/null
        if echo "$RUN_OUT" | grep -q "Unknown command"; then
            echo "subcommand '$cmd' was rejected as unknown" >&2
            return 1
        fi
    done
}

test_help_text_lists_every_subcommand() {
    run_orch help-advanced
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
    run_orch help-advanced
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

# ---- Help text content ----------------------------------------------------

test_help_includes_all_three_run_modes() {
    run_orch help-advanced
    assert_contains "$RUN_OUT" "parallel" "should mention parallel mode" || return 1
    assert_contains "$RUN_OUT" "sequential-host" || return 1
    assert_contains "$RUN_OUT" "sequential-pair" || return 1
}

test_help_includes_files_section() {
    run_orch help-advanced
    assert_contains "$RUN_OUT" "FILES:" "should have a FILES: section" || return 1
    assert_contains "$RUN_OUT" "Server list:" || return 1
    assert_contains "$RUN_OUT" "Results base:" || return 1
}

test_help_includes_setup_quickstart() {
    run_orch help-advanced
    assert_contains "$RUN_OUT" "start-servers" "help should mention start-servers" || return 1
    assert_contains "$RUN_OUT" "--servers" "help should mention --servers flag" || return 1
}

# ---- README and completions cross-check -----------------------------------
#
# The help text is generated next to the parser, so it rarely falls behind.
# The README and the completion files live elsewhere and did: --overlay-window
# never reached the README, and the bash completion missed six flags. These
# hold every surface to the parser itself.

# Long flags the pre-pass parser accepts, one per line (same scrape as the
# help-text test above).
_parser_long_flags() {
    grep -oE '^[[:space:]]+--[a-z][a-z0-9-]*(\|-[a-zA-Z])?(=\*)?\)' "$ORCH" \
        | grep -oE -- '--[a-z][a-z0-9-]*' \
        | sort -u
}

# _flags_missing_from FILE: print each parser flag FILE never mentions as a
# whole word (so --overlay is not satisfied by --overlay-out).
_flags_missing_from() {
    local file="$1" f
    while IFS= read -r f; do
        grep -qE -- "${f}([^a-z0-9-]|\$)" "$file" || echo "$f"
    done < <(_parser_long_flags)
}

test_readme_documents_every_long_flag() {
    local missing
    missing=$(_flags_missing_from "$REPO_ROOT/README.md")
    [ -z "$missing" ] || {
        echo "flags the parser accepts but README.md never mentions:" >&2
        printf '  %s\n' $missing >&2
        return 1
    }
}

test_bash_completion_offers_every_long_flag() {
    local missing
    missing=$(_flags_missing_from "$REPO_ROOT/completions/iperf_orchestrator.bash")
    [ -z "$missing" ] || {
        echo "flags missing from completions/iperf_orchestrator.bash:" >&2
        printf '  %s\n' $missing >&2
        return 1
    }
}

test_zsh_completion_offers_every_long_flag() {
    local missing
    missing=$(_flags_missing_from "$REPO_ROOT/completions/_iperf_orchestrator")
    [ -z "$missing" ] || {
        echo "flags missing from completions/_iperf_orchestrator:" >&2
        printf '  %s\n' $missing >&2
        return 1
    }
}

test_readme_documents_every_plan_key() {
    # Every key _load_plan_settings accepts must be findable as `key=` in
    # the README, or it is a setting nobody can discover.
    local keys k missing=()
    keys=$(sed -n '/^_load_plan_settings()/,/^}/p' "$ORCH" \
        | grep -oE '^[[:space:]]+[a-z_]+\)[[:space:]]+_plan_default' \
        | grep -oE '[a-z_]+' | grep -v '^_plan_default$')
    [ -n "$keys" ] || { echo "could not extract plan keys from script" >&2; return 1; }
    while IFS= read -r k; do
        grep -qE "(^|[^a-z_])${k}=" "$REPO_ROOT/README.md" || missing+=("$k")
    done <<< "$keys"
    [ "${#missing[@]}" -eq 0 ] || {
        echo "plan keys missing from README.md:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    }
}

test_readme_output_schema_lists_every_csv_column() {
    # Both CSV writers declare their columns as a literal `cols = [...]`
    # list; every name in them must appear in the README's output-schema
    # section (bind_iface, bind_ip and test_start once did not).
    local schema cols c missing=()
    schema=$(sed -n '/^<!-- docs:output-schema -->$/,/^<!-- docs:end -->$/p' \
        "$REPO_ROOT/README.md")
    [ -n "$schema" ] || { echo "no docs:output-schema section in README.md" >&2; return 1; }
    cols=$(awk '/^cols = \[/{grab=1} grab{print} grab && /\]/{grab=0}' "$ORCH" \
        | grep -oE '"[a-z_]+"' | tr -d '"' | sort -u)
    [ -n "$cols" ] || { echo "could not extract CSV columns from script" >&2; return 1; }
    while IFS= read -r c; do
        echo "$schema" | grep -qE "(^|[^a-z_])${c}([^a-z_]|\$)" || missing+=("$c")
    done <<< "$cols"
    [ "${#missing[@]}" -eq 0 ] || {
        echo "CSV columns missing from the README output schema:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    }
}

run_test test_orchestrator_passes_bash_n
run_test test_orchestrator_is_executable
run_test test_orchestrator_uses_set_u
run_test test_every_documented_subcommand_is_dispatched
run_test test_help_text_lists_every_subcommand
run_test test_help_text_documents_every_long_flag
run_test test_help_includes_all_three_run_modes
run_test test_help_includes_files_section
run_test test_help_includes_setup_quickstart
run_test test_readme_documents_every_long_flag
run_test test_bash_completion_offers_every_long_flag
run_test test_zsh_completion_offers_every_long_flag
run_test test_readme_documents_every_plan_key
run_test test_readme_output_schema_lists_every_csv_column

report_tests
