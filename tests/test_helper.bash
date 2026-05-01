# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
#
# Shared helpers for the iperf-orchestrator test suite.
#
# Each test file sources this file, then defines test_* functions and
# calls run_test for each. The runner uses subshells so a failed
# assertion in one test doesn't abort the rest.
#
# The orchestrator script is located via $ORCH (set by run_tests.sh).
# Each test gets a fresh temp dir at $TEST_TMPDIR, with $IPERF_DIR
# pointed at a subdir so the script's mkdir-on-startup is harmless.

set -u

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ORCH="${ORCH:-$REPO_ROOT/iperf_orchestrator.sh}"
export REPO_ROOT ORCH

# ---- Per-test environment ---------------------------------------------------

setup_orch_env() {
    TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/iperf-orch-tests-XXXXXX")"
    export TEST_TMPDIR
    export IPERF_DIR="$TEST_TMPDIR/state"
    export REMOTE_DIR="$TEST_TMPDIR/remote"
    export FAKE_BIN="$TEST_TMPDIR/fakebin"
    mkdir -p "$FAKE_BIN"
    # Reset to a clean SSH user so the script's $USER/$(id -un) fallback
    # can't surprise tests that hardcode usernames.
    export SSH_USER="testuser"
}

teardown_orch_env() {
    if [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

# Source the orchestrator with a no-op subcommand so all of its function
# definitions become available in the current shell. We pass "help" so
# the dispatcher prints usage and falls off cleanly. stdout/stderr are
# redirected so the help text doesn't pollute test output.
#
# IMPORTANT: this MUST NOT be called from inside a function. The script
# does `declare -A STATE` at top level; if that runs inside a function
# scope, STATE becomes function-local and disappears when the function
# returns. The runner instead pre-sources at subshell top level (see
# run_test). This wrapper exists for tests that explicitly want to
# re-source after manipulating the environment.
source_orch() {
    # shellcheck disable=SC1090
    source "$ORCH" help >/dev/null 2>&1
}

# Run the orchestrator as a subprocess. Captures stdout+stderr to
# $RUN_OUT and exit status to $RUN_RC.
run_orch() {
    RUN_OUT="$(bash "$ORCH" "$@" 2>&1)"
    RUN_RC=$?
    export RUN_OUT RUN_RC
}

# Write a server list to the state dir.
write_server_list() {
    local out="$IPERF_DIR/servers.list"
    mkdir -p "$IPERF_DIR"
    : > "$out"
    local h
    for h in "$@"; do
        printf '%s\n' "$h" >> "$out"
    done
    echo "$out"
}

# Install a fake `ssh`/`scp` shim in $FAKE_BIN. Tests prepend $FAKE_BIN
# to PATH before invoking the orchestrator so its `ssh`/`scp` calls hit
# the shim.
#
# The shim records every invocation to $FAKE_BIN/calls.log and
# dispatches on a small command-pattern table that the test can extend
# via $FAKE_BIN/responses.
install_fake_ssh() {
    cat > "$FAKE_BIN/ssh" <<'SHIM'
#!/usr/bin/env bash
# Fake ssh: skip option args until we see a "user@host" token, then
# treat the rest of the args as the remote command. Log + dispatch.
set -u
LOG="${FAKE_SSH_LOG:-$(dirname "$0")/calls.log}"
target=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift; [ $# -gt 0 ] && shift ;;
        -[a-zA-Z])
            shift
            # Some single-letter flags take an arg, but we'll be lazy:
            # if the next token starts with - or contains @, leave it;
            # else consume.
            ;;
        *@*) target="$1"; shift; break ;;
        *) shift ;;
    esac
done
remote_cmd="$*"
host="${target#*@}"
printf 'ssh\t%s\t%s\n' "$host" "$remote_cmd" >> "$LOG"

# Per-host opt-out (e.g. mark a host as "unreachable" so commands fail).
if [ -f "$FAKE_BIN/unreachable" ] && grep -Fxq "$host" "$FAKE_BIN/unreachable"; then
    exit 255
fi

# Order matters: orchestrator commands compound several ops on one line
# (e.g. start = mkdir + pkill + nohup + pgrep), so we match on the most
# specific signature first.
case "$remote_cmd" in
    *"nohup iperf"*)
        # cmd_start_servers: mkdir + pkill + nohup iperf -s + pgrep.
        # Record this host as running for subsequent pgrep probes.
        touch "$FAKE_BIN/iperf_running_$host"
        exit 0
        ;;
    *"! pgrep"*)
        # cmd_stop_servers: pkill + sleep + ! pgrep. Clear the flag
        # then return 0 (success means no iperf running).
        rm -f "$FAKE_BIN/iperf_running_$host"
        exit 0
        ;;
    *"iperf -v"*)
        echo "iperf version 2.1.9 (1 March 2023) pthreads"
        exit 0
        ;;
    *"command -v mpstat"*)
        echo "yes"
        exit 0
        ;;
    *"pgrep -ax iperf"*|*"pgrep -x iperf"*)
        # cmd_check_servers: bare pgrep probe.
        if [ -f "$FAKE_BIN/iperf_running_$host" ]; then
            echo "12345 iperf -s -p 5001"
            exit 0
        fi
        exit 1
        ;;
    *"rm -rf "*)
        exit 0
        ;;
    *"chmod +x"*|*"mkdir -p"*)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
SHIM
    chmod +x "$FAKE_BIN/ssh"

    cat > "$FAKE_BIN/scp" <<'SHIM'
#!/usr/bin/env bash
set -u
LOG="${FAKE_SSH_LOG:-$(dirname "$0")/calls.log}"
# Skip options to find src + dst.
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift; [ $# -gt 0 ] && shift ;;
        -[a-zA-Z]) shift ;;
        *) args+=("$1"); shift ;;
    esac
done
n=${#args[@]}
[ $n -lt 2 ] && exit 2
src="${args[0]}"
dst="${args[$((n-1))]}"
printf 'scp\t%s\t%s\n' "$src" "$dst" >> "$LOG"
exit 0
SHIM
    chmod +x "$FAKE_BIN/scp"

    export FAKE_SSH_LOG="$FAKE_BIN/calls.log"
    : > "$FAKE_SSH_LOG"
}

# ---- Assertions -------------------------------------------------------------

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-values differ}"
    if [ "$expected" = "$actual" ]; then return 0; fi
    printf 'ASSERT_EQ FAILED: %s\n  expected: <%s>\n  actual:   <%s>\n' \
        "$msg" "$expected" "$actual" >&2
    return 1
}

assert_ne() {
    local left="$1" right="$2" msg="${3:-values should differ}"
    if [ "$left" != "$right" ]; then return 0; fi
    printf 'ASSERT_NE FAILED: %s (both <%s>)\n' "$msg" "$left" >&2
    return 1
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-substring missing}"
    if [[ "$haystack" == *"$needle"* ]]; then return 0; fi
    printf 'ASSERT_CONTAINS FAILED: %s\n  haystack: %s\n  needle:   <%s>\n' \
        "$msg" "$haystack" "$needle" >&2
    return 1
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-substring should be absent}"
    if [[ "$haystack" != *"$needle"* ]]; then return 0; fi
    printf 'ASSERT_NOT_CONTAINS FAILED: %s\n  needle: <%s>\n' "$msg" "$needle" >&2
    return 1
}

assert_file_exists() {
    local f="$1" msg="${2:-file missing}"
    if [ -f "$f" ]; then return 0; fi
    printf 'ASSERT_FILE_EXISTS FAILED: %s (%s)\n' "$msg" "$f" >&2
    return 1
}

assert_status() {
    local expected="$1" actual="$2" msg="${3:-exit status mismatch}"
    if [ "$expected" -eq "$actual" ]; then return 0; fi
    printf 'ASSERT_STATUS FAILED: %s expected=%d actual=%d\n' \
        "$msg" "$expected" "$actual" >&2
    return 1
}

# ---- Test runner ------------------------------------------------------------

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# run_test <fn> [args...]
# Runs the test function in a subshell with a fresh tmpdir. Pre-sources
# the orchestrator at the subshell's TOP LEVEL (not inside a function)
# so its `declare -A STATE` survives at global scope -- otherwise tests
# that rely on internal helpers (set_state, is_client_for, etc.) hit
# unbound-variable errors under set -u.
#
# Prints PASS/FAIL inline and tracks counts in the parent shell.
run_test() {
    local name="$1"; shift
    TESTS_RUN=$((TESTS_RUN+1))
    setup_orch_env
    local rc=0
    (
        set +e
        cd "$TEST_TMPDIR"
        # shellcheck disable=SC1090
        source "$ORCH" help >/dev/null 2>&1
        "$name" "$@"
    )
    rc=$?
    if [ "$rc" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED+1))
        printf '    PASS  %s\n' "$name"
    else
        TESTS_FAILED=$((TESTS_FAILED+1))
        FAILED_TESTS+=("$name")
        printf '    FAIL  %s (rc=%d)\n' "$name" "$rc"
    fi
    teardown_orch_env
}

report_tests() {
    echo
    echo "  ----------------------------------------"
    echo "  ran:    $TESTS_RUN"
    echo "  passed: $TESTS_PASSED"
    echo "  failed: $TESTS_FAILED"
    if [ "$TESTS_FAILED" -ne 0 ]; then
        printf '    %s\n' "${FAILED_TESTS[@]}"
        exit 1
    fi
    exit 0
}
