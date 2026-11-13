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
ORCH="${ORCH:-$REPO_ROOT/iperf_orchestrator/iperf_orchestrator.sh}"
export REPO_ROOT ORCH

# ---- Per-test environment ---------------------------------------------------

setup_orch_env() {
    TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/iperf-orch-tests-XXXXXX")"
    export TEST_TMPDIR
    export RESULTS_BASE="$TEST_TMPDIR/results"
    export IPERF_SERVERS="$TEST_TMPDIR/servers.txt"
    # Pre-set a fixed RUN_ID so tests can predict generated filenames.
    export IPERF_RUN_ID="test-run"
    export REMOTE_DIR="$TEST_TMPDIR/remote"
    export FAKE_BIN="$TEST_TMPDIR/fakebin"
    mkdir -p "$FAKE_BIN" "$RESULTS_BASE"
    # Reset to a clean SSH user so the script's $USER/$(id -un) fallback
    # can't surprise tests that hardcode usernames.
    export SSH_USER="testuser"
    # Back-compat for tests that still reference $IPERF_DIR -- point it
    # at a sub-dir of TEST_TMPDIR so any stray writes are sandboxed.
    export IPERF_DIR="$TEST_TMPDIR/state"
    mkdir -p "$IPERF_DIR"
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

# Write a server list to the test tmpdir and (re)export IPERF_SERVERS so
# the orchestrator picks it up. Returns the resolved path on stdout.
write_server_list() {
    local out="${IPERF_SERVERS:-$TEST_TMPDIR/servers.txt}"
    mkdir -p "$(dirname "$out")"
    : > "$out"
    local h
    for h in "$@"; do
        printf '%s\n' "$h" >> "$out"
    done
    export IPERF_SERVERS="$out"
    echo "$out"
}

# Install a fake `ssh`/`scp` shim in $FAKE_BIN. Tests prepend $FAKE_BIN
# to PATH before invoking the orchestrator so its `ssh`/`scp` calls hit
# the shim.
#
# The shim records every invocation to $FAKE_BIN/calls.log and
# dispatches on a small command-pattern table. It never runs the remote
# command: `rm -rf ...` simply exits 0. A test that needs to know what a
# remote command DOES uses install_sandbox_ssh (below) instead, and
# FAKE_SSH_MODE=sandbox makes every install_fake_ssh call install the
# sandbox, so the whole suite can be run on it (run_tests.sh --sandbox).
install_fake_ssh() {
    if [ "${FAKE_SSH_MODE:-}" = "sandbox" ]; then
        install_sandbox_ssh
        return
    fi
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
# (e.g. start = mkdir + pkill + iperf -s -D + pgrep), so we match on
# the most specific signature first.
case "$remote_cmd" in
    *"iperf -p"*"-s -D"*)
        # cmd_start_servers: mkdir + iperf -p PORT -s -D.
        touch "$FAKE_BIN/iperf_running_$host"
        exit 0
        ;;
    *"pkill -f"*"^iperf -p"*)
        # cmd_stop_servers: pkill the iperf -p PORT daemon. Clear the flag.
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
    *"BIND_RAW="*"ip -o -4 addr show"*)
        # _resolve_peer_bind_ips probe: emit a per-host data-plane IP so
        # the orchestrator's PEER_BIND_IPS map gets populated. The exact
        # IP doesn't matter for these tests -- they only assert on the
        # presence of the probe and the embedded conn_ip wiring.
        h_hash=$(printf '%s' "$host" | cksum | awk '{print ($1 % 250) + 1}')
        echo "10.99.0.$h_hash"
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
        --) shift ;;
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

# ---- Sandbox ssh/scp ---------------------------------------------------------
#
# install_sandbox_ssh: the same calls.log and unreachable-host file as
# install_fake_ssh, but every remote command really runs, so a test can
# check what a snippet does and not only its text.
#
#   * Each fake host gets a root of its own, $SANDBOX_ROOT/hosts/<host>.
#     The remote command runs there as `bash -c CMD`, with HOME set to it,
#     the way ssh starts a command in the login directory. A relative
#     REMOTE_DIR therefore lands in a separate directory per host; an
#     absolute one inside the test's temp dir is shared by every host,
#     like a REMOTE_DIR on NFS.
#   * scp copies for real: a relative remote path is taken from the
#     host's root, an absolute one as given. It parses `user@host:path`
#     and `user@[v6]:path` the way OpenSSH's scp does, so a bare IPv6
#     literal is split at its first colon here too.
#   * Remote commands see stand-ins first on their PATH:
#       rm, mkdir, chmod  log every request, and refuse (exit 1, logged
#                         as *-refused) any path outside $SANDBOX_ROOT.
#       iperf             -s -D registers a daemon in a per-host registry
#                         (a second one on a taken port "detaches" and
#                         then fails, like the real one); -c logs its
#                         argv, one %q-quoted word each, to
#                         $SANDBOX_ROOT/iperf_clients.log and prints one
#                         iperf2 CSV row; -v prints a version 2 banner.
#       pkill, pgrep      act on that registry only, never on real
#                         processes.
#       ip, mpstat        canned output, instantly.
#     Every stand-in call is logged to $SANDBOX_LOG, one line each:
#     <tool> TAB <host> TAB <args, %q-quoted>.
#   * What is NOT confined: shell redirections and any other command a
#     snippet runs. Tests that inject commands use harmless markers
#     (touch a file inside the sandbox), never anything destructive.
#
# SANDBOX_IPERF_SECONDS=N makes every iperf -c sleep N seconds first
# (for interrupting a run mid-test).
install_sandbox_ssh() {
    export SANDBOX_ROOT="${SANDBOX_ROOT:-$TEST_TMPDIR}"
    export SANDBOX_BIN="$FAKE_BIN/sandbox-bin"
    export SANDBOX_LOG="$SANDBOX_ROOT/sandbox.log"
    export FAKE_SSH_LOG="$FAKE_BIN/calls.log"
    mkdir -p "$SANDBOX_BIN" "$SANDBOX_ROOT/hosts" "$SANDBOX_ROOT/daemons"
    : > "$SANDBOX_LOG"
    : > "$FAKE_SSH_LOG"
    : > "$SANDBOX_ROOT/iperf_clients.log"
    # Resolved once, so the stand-ins can hand allowed work to the real
    # tools without finding themselves first on PATH.
    local root_real real_rm real_mkdir real_chmod
    root_real=$(cd "$SANDBOX_ROOT" && pwd -P)
    real_rm=$(command -v rm); real_mkdir=$(command -v mkdir); real_chmod=$(command -v chmod)

    # Shared prelude for the stand-ins: where things are, and the
    # inside-the-sandbox test.
    cat > "$SANDBOX_BIN/.prelude" <<EOF
SANDBOX_ROOT_REAL='$root_real'
REAL_RM='$real_rm'
REAL_MKDIR='$real_mkdir'
REAL_CHMOD='$real_chmod'
FAKE_BIN='$FAKE_BIN'
_host="\${SANDBOX_HOST:-local}"
_hostkey=\$(printf '%s' "\$_host" | tr -c 'A-Za-z0-9._-' '_')
_slog() { local tool="\$1"; shift; printf '%s\t%s\t%s\n' "\$tool" "\$_host" "\$(printf '%q ' "\$@")" >> "\$SANDBOX_LOG"; }
# The daemon registry for this host. A test written for install_fake_ssh
# marks a daemon as running by touching iperf_running_<host>; read that
# as one daemon on the default port, so those tests run here unchanged.
_reg="\$SANDBOX_ROOT/daemons/\$_hostkey"
if [ -f "\$FAKE_BIN/iperf_running_\$_host" ] && [ ! -s "\$_reg" ]; then
    printf '12345\tiperf -p 5001 -s -D\n' > "\$_reg"
fi
# _inside PATH: true when PATH (resolved, need not exist) is inside the sandbox.
_inside() {
    local r
    r=\$(realpath -m -- "\$1" 2>/dev/null) || return 1
    case "\$r" in "\$SANDBOX_ROOT_REAL"|"\$SANDBOX_ROOT_REAL"/*) return 0 ;; esac
    return 1
}
EOF

    cat > "$FAKE_BIN/ssh" <<'SHIM'
#!/usr/bin/env bash
# Sandbox ssh: run the remote command for real, in a root of its own per host.
set -u
LOG="${FAKE_SSH_LOG:-$(dirname "$0")/calls.log}"
# Like OpenSSH: options until the first non-option argument (or `--`);
# that argument is the destination, the rest is the remote command.
target=""
while [ $# -gt 0 ]; do
    case "$1" in
        --) shift; target="${1:-}"; [ $# -gt 0 ] && shift; break ;;
        -[oiplFJEcmLRDWwbBeIQS]) shift; [ $# -gt 0 ] && shift ;;
        -*) shift ;;
        *) target="$1"; shift; break ;;
    esac
done
remote_cmd="$*"
host="${target#*@}"
printf 'ssh\t%s\t%s\n' "$host" "$remote_cmd" >> "$LOG"
if [ -f "$FAKE_BIN/unreachable" ] && grep -Fxq -- "$host" "$FAKE_BIN/unreachable"; then
    exit 255
fi
hostkey=$(printf '%s' "$host" | tr -c 'A-Za-z0-9._-' '_')
root="$SANDBOX_ROOT/hosts/$hostkey"
mkdir -p "$root" && cd "$root" || exit 255
# Not exec: this process stands for the local ssh client, the bash below
# for the remote side, so killing one leaves the other running -- as with
# a real ssh, whose remote command outlives a killed client.
HOME="$root" SANDBOX_HOST="$host" PATH="$SANDBOX_BIN:$PATH" bash -c "$remote_cmd"
SHIM
    chmod +x "$FAKE_BIN/ssh"

    cat > "$FAKE_BIN/scp" <<'SHIM'
#!/usr/bin/env bash
# Sandbox scp: copy for real between the local disk and a host's root.
set -u
LOG="${FAKE_SSH_LOG:-$(dirname "$0")/calls.log}"
. "$SANDBOX_BIN/.prelude"
# Like OpenSSH's scp: options until the first operand (or `--`).
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --) shift; args+=("$@"); break ;;
        -[oiPlFJScDX]) shift; [ $# -gt 0 ] && shift ;;
        -*) shift ;;
        *) args+=("$@"); break ;;
    esac
done
n=${#args[@]}
[ "$n" -lt 2 ] && exit 2
src="${args[0]}"; dst="${args[$((n-1))]}"
printf 'scp\t%s\t%s\n' "$src" "$dst" >> "$LOG"
# Split an operand the way scp does: [user@]host:path, where host may be
# a bracketed IPv6 literal; anything else is a local path.
_remote() {
    local s="$1"
    case "$s" in /*|./*|../*) return 1 ;; esac
    case "$s" in *@*) s="${s#*@}" ;; esac
    case "$s" in
        \[*\]:*) R_HOST="${s%%]:*}"; R_HOST="${R_HOST#\[}"; R_PATH="${s#*]:}" ;;
        *:*)     R_HOST="${s%%:*}";  R_PATH="${s#*:}" ;;
        *)       return 1 ;;
    esac
    if [ -f "$FAKE_BIN/unreachable" ] && grep -Fxq -- "$R_HOST" "$FAKE_BIN/unreachable"; then
        echo "ssh: connect to host $R_HOST: Connection refused" >&2; exit 255
    fi
    local key; key=$(printf '%s' "$R_HOST" | tr -c 'A-Za-z0-9._-' '_')
    local root="$SANDBOX_ROOT/hosts/$key"
    mkdir -p "$root"
    case "$R_PATH" in
        '') R_PATH="$root" ;;
        /*) ;;
        *)  R_PATH="$root/$R_PATH" ;;
    esac
    return 0
}
s_path="$src"; d_path="$dst"
if _remote "$src"; then s_path="$R_PATH"; _host="$R_HOST"; fi
if _remote "$dst"; then d_path="$R_PATH"; _host="$R_HOST"; fi
for p in "$s_path" "$d_path"; do
    if ! _inside "$p"; then
        _slog scp-refused "$p"
        echo "sandbox scp: refused $p (outside the sandbox)" >&2
        exit 1
    fi
done
_slog scp "$s_path" "$d_path"
cp -- "$s_path" "$d_path"
SHIM
    chmod +x "$FAKE_BIN/scp"

    cat > "$SANDBOX_BIN/rm" <<'SHIM'
#!/usr/bin/env bash
. "$SANDBOX_BIN/.prelude"
_slog rm "$@"
opts=() ops=() end=0
for a in "$@"; do
    if [ "$end" = 0 ] && [ "$a" = "--" ]; then end=1; continue; fi
    if [ "$end" = 0 ] && [ "${a#-}" != "$a" ] && [ "$a" != "-" ]; then opts+=("$a"); else ops+=("$a"); fi
done
rc=0 ok=()
for p in ${ops[@]+"${ops[@]}"}; do
    if [ -z "$p" ] || _inside "$p"; then ok+=("$p"); continue; fi
    _slog rm-refused "$(realpath -m -- "$p")"
    echo "sandbox rm: refused to remove $p (outside the sandbox)" >&2
    rc=1
done
if [ "${#ops[@]}" -eq 0 ] || [ "${#ok[@]}" -gt 0 ]; then
    "$REAL_RM" ${opts[@]+"${opts[@]}"} -- ${ok[@]+"${ok[@]}"} || rc=$?
fi
exit "$rc"
SHIM

    cat > "$SANDBOX_BIN/mkdir" <<'SHIM'
#!/usr/bin/env bash
. "$SANDBOX_BIN/.prelude"
_slog mkdir "$@"
opts=() ops=() end=0
while [ $# -gt 0 ]; do
    if [ "$end" = 0 ]; then
        case "$1" in
            --) end=1; shift; continue ;;
            -m) opts+=("$1" "${2:-}"); shift 2; continue ;;
            -?*) opts+=("$1"); shift; continue ;;
        esac
    fi
    ops+=("$1"); shift
done
for p in ${ops[@]+"${ops[@]}"}; do
    if [ -n "$p" ] && ! _inside "$p"; then
        _slog mkdir-refused "$(realpath -m -- "$p")"
        echo "sandbox mkdir: refused $p (outside the sandbox)" >&2
        exit 1
    fi
done
exec "$REAL_MKDIR" ${opts[@]+"${opts[@]}"} -- ${ops[@]+"${ops[@]}"}
SHIM

    cat > "$SANDBOX_BIN/chmod" <<'SHIM'
#!/usr/bin/env bash
. "$SANDBOX_BIN/.prelude"
_slog chmod "$@"
opts=() mode="" ops=() end=0
for a in "$@"; do
    if [ "$end" = 0 ] && [ "$a" = "--" ]; then end=1; continue; fi
    if [ "$end" = 0 ] && [ -z "$mode" ] && [ "${a#-}" != "$a" ] && [ "${#ops[@]}" -eq 0 ]; then
        case "$a" in -[rwxXst]*) mode="$a" ;; *) opts+=("$a") ;; esac
        continue
    fi
    if [ -z "$mode" ]; then mode="$a"; else ops+=("$a"); fi
done
for p in ${ops[@]+"${ops[@]}"}; do
    if ! _inside "$p"; then
        _slog chmod-refused "$(realpath -m -- "$p")"
        echo "sandbox chmod: refused $p (outside the sandbox)" >&2
        exit 1
    fi
done
exec "$REAL_CHMOD" ${opts[@]+"${opts[@]}"} "$mode" -- ${ops[@]+"${ops[@]}"}
SHIM

    cat > "$SANDBOX_BIN/iperf" <<'SHIM'
#!/usr/bin/env bash
. "$SANDBOX_BIN/.prelude"
_slog iperf "$@"
reg="$SANDBOX_ROOT/daemons/$_hostkey"
args=("$@"); mode=""; peer=""; port=5001; daemon=0
for ((i=0; i<${#args[@]}; i++)); do
    case "${args[$i]}" in
        -v) echo "iperf version 2.1.9 (sandbox) pthreads" >&2; exit 0 ;;
        -s) mode=server ;;
        -c) mode=client; peer="${args[$((i+1))]:-}" ;;
        -p) port="${args[$((i+1))]:-}" ;;
        -D) daemon=1 ;;
    esac
done
case "$mode" in
    server)
        [ "$daemon" = 1 ] && echo "Running Iperf Server as a daemon"
        # The real one detaches before it binds, so a taken port still
        # "succeeds" here and the daemon then dies.
        if [ -f "$reg" ] && awk -v p="$port" '{for (i=2;i<=NF;i++) if ($i=="-p" && $(i+1)==p) f=1} END{exit !f}' "$reg"; then
            echo "bind failed: Address already in use" >> "$SANDBOX_ROOT/hosts/$_hostkey.iperf_daemon.err"
            exit 0
        fi
        printf '%s\t%s\n' "$$" "iperf $*" >> "$reg"
        touch "$FAKE_BIN/iperf_running_$_host"
        exit 0 ;;
    client)
        printf '%s\t%s\n' "$_host" "$(printf '%q ' "$@")" >> "$SANDBOX_ROOT/iperf_clients.log"
        [ -n "${SANDBOX_IPERF_SECONDS:-}" ] && sleep "$SANDBOX_IPERF_SECONDS"
        echo "20260101000000,10.0.0.1,40000,$peer,$port,3,0.0-10.0,1250000000,1000000000"
        exit 0 ;;
esac
echo "iperf: sandbox stand-in does not know: $*" >&2
exit 1
SHIM

    cat > "$SANDBOX_BIN/pkill" <<'SHIM'
#!/usr/bin/env bash
# Acts on the sandbox's daemon registry only; never on a real process.
. "$SANDBOX_BIN/.prelude"
_slog pkill "$@"
full=0 pat=""
while [ $# -gt 0 ]; do
    case "$1" in
        -f) full=1 ;;
        -u|-U|-g|-G|-P|-s|-t|--signal) shift ;;
        -*) ;;
        *) pat="$1" ;;
    esac
    shift
done
reg="$SANDBOX_ROOT/daemons/$_hostkey"
[ -f "$reg" ] || exit 1
hit=1 keep=""
while IFS=$'\t' read -r pid cmdline; do
    subject="$cmdline"; [ "$full" = 1 ] || subject="${cmdline%% *}"
    if [[ "$subject" =~ $pat ]]; then
        _slog pkill-killed "$cmdline"; hit=0
    else
        keep+="$pid"$'\t'"$cmdline"$'\n'
    fi
done < "$reg"
printf '%s' "$keep" > "$reg"
[ -s "$reg" ] || rm -f "$FAKE_BIN/iperf_running_$_host"
exit "$hit"
SHIM

    cat > "$SANDBOX_BIN/pgrep" <<'SHIM'
#!/usr/bin/env bash
. "$SANDBOX_BIN/.prelude"
_slog pgrep "$@"
reg="$SANDBOX_ROOT/daemons/$_hostkey"
[ -s "$reg" ] || exit 1
tr '\t' ' ' < "$reg"
SHIM

    cat > "$SANDBOX_BIN/ip" <<'SHIM'
#!/usr/bin/env bash
. "$SANDBOX_BIN/.prelude"
_slog ip "$@"
h=$(printf '%s' "$_host" | cksum | awk '{print ($1 % 250) + 1}')
echo "1: lo    inet 127.0.0.1/8 scope host lo"
n=2
for ifc in eth0 bond0 mlx5_0; do
    echo "$n: $ifc    inet 10.99.0.$h/24 brd 10.0.0.255 scope global $ifc"
    n=$((n + 1))
done
SHIM

    cat > "$SANDBOX_BIN/mpstat" <<'SHIM'
#!/usr/bin/env bash
. "$SANDBOX_BIN/.prelude"
_slog mpstat "$@"
printf 'Linux 6.0 (sandbox) \t01/01/2026 \t_x86_64_\t(2 CPU)\n\n'
echo "00:00:00     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle"
echo "00:00:01     all    1.00    0.00    1.00    0.00    0.00    1.00    0.00    0.00    0.00   97.00"
SHIM

    chmod +x "$SANDBOX_BIN"/*
}

# sandbox_host_root HOST: the directory a sandboxed host runs in.
sandbox_host_root() {
    printf '%s/hosts/%s' "$SANDBOX_ROOT" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
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
