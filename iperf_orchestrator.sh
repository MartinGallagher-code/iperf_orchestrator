#!/usr/bin/env bash
#==============================================================================
# iperf-orchestrator.sh
#
# Copyright (C) 2026 Martin J. Gallagher
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
#==============================================================================
#
# Orchestrate a full-mesh iperf2 throughput test across a list of servers.
# Uses iperf2's --full-duplex mode: one TCP socket per host pair, carrying
# traffic in both directions simultaneously. Each pair is tested once
# (canonical ordering), and both directions are extracted from the single
# log file.
#
# Why iperf2 and not iperf3:
#   iperf3's server is single-threaded and accepts one client at a time, so
#   a full mesh of N hosts would need N iperf3 servers per host on different
#   ports. iperf2's server is multi-threaded and handles concurrent clients
#   on a single port, so we run one daemon per host on port 5001 and we're
#   done. iperf2's --full-duplex also gives us a true single-socket bidir
#   test, which is what you want for fabric stress testing.
# Results are gathered, parsed into CSV, pivoted, and rendered as a
# heatmap + bar chart on a single image.
#
# Quick start:
#   ./iperf-orchestrator.sh init  servers.txt
#   ./iperf-orchestrator.sh ssh-setup
#   ./iperf-orchestrator.sh all
#==============================================================================

set -u
# Note: -e is intentionally NOT set; we handle per-host failures explicitly
# so one bad host doesn't abort the whole run.

#------------------------------------------------------------------------------
# Configuration (override via env vars; CLI flags below win over env vars)
#------------------------------------------------------------------------------
IPERF_DIR="${IPERF_DIR:-$HOME/.iperf_orchestrator}"
REMOTE_DIR="${REMOTE_DIR:-/tmp/iperf_orchestrator}"

IPERF_PORT="${IPERF_PORT:-5001}"
IPERF_DURATION="${IPERF_DURATION:-10}"     # seconds per pair
IPERF_PARALLEL="${IPERF_PARALLEL:-1}"      # parallel streams per test
IPERF_JOBS="${IPERF_JOBS:-16}"             # max concurrent SSH/SCP fan-out

SSH_USER="${SSH_USER:-${USER:-$(id -un)}}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=30}"
# Used when we want commands that require an existing key (no password prompts):
SSH_BATCH_OPTS="$SSH_OPTS -o BatchMode=yes"

# Optional password sources for ssh-setup. When any of these is set, the
# script drives ssh-copy-id with `expect` instead of prompting interactively.
SSH_PASSWORD_FILE="${SSH_PASSWORD_FILE:-}"
SSH_PASSWORD_ENV="${SSH_PASSWORD_ENV:-}"
SSH_ASK_PASSWORD="${SSH_ASK_PASSWORD:-no}"

START_DELAY="${START_DELAY:-30}"           # seconds in future for synchronized start

PYTHON_BIN="${PYTHON_BIN:-python3}"

#------------------------------------------------------------------------------
# CLI flag pre-pass
#
# Consumes flags from "$@" and leaves only the subcommand + its positional
# args behind. Flags accept both "--key value" and "--key=value" forms.
# Anything after a literal "--" is passed through verbatim.
#------------------------------------------------------------------------------
_flag_die() { echo "iperf-orchestrator: $*" >&2; exit 2; }
_flag_need() { [ -n "${2:-}" ] || _flag_die "flag $1 requires a value"; }

_PARSED=()
while [ $# -gt 0 ]; do
    case "$1" in
        --port)          _flag_need "$1" "${2:-}"; IPERF_PORT="$2"; shift 2 ;;
        --port=*)        IPERF_PORT="${1#*=}"; shift ;;
        --duration|-d)   _flag_need "$1" "${2:-}"; IPERF_DURATION="$2"; shift 2 ;;
        --duration=*)    IPERF_DURATION="${1#*=}"; shift ;;
        --parallel|-P)   _flag_need "$1" "${2:-}"; IPERF_PARALLEL="$2"; shift 2 ;;
        --parallel=*)    IPERF_PARALLEL="${1#*=}"; shift ;;
        --jobs|-j)       _flag_need "$1" "${2:-}"; IPERF_JOBS="$2"; shift 2 ;;
        --jobs=*)        IPERF_JOBS="${1#*=}"; shift ;;
        --start-delay)   _flag_need "$1" "${2:-}"; START_DELAY="$2"; shift 2 ;;
        --start-delay=*) START_DELAY="${1#*=}"; shift ;;
        --ssh-user|-u)   _flag_need "$1" "${2:-}"; SSH_USER="$2"; shift 2 ;;
        --ssh-user=*)    SSH_USER="${1#*=}"; shift ;;
        --iperf-dir)     _flag_need "$1" "${2:-}"; IPERF_DIR="$2"; shift 2 ;;
        --iperf-dir=*)   IPERF_DIR="${1#*=}"; shift ;;
        --remote-dir)    _flag_need "$1" "${2:-}"; REMOTE_DIR="$2"; shift 2 ;;
        --remote-dir=*)  REMOTE_DIR="${1#*=}"; shift ;;
        --python)        _flag_need "$1" "${2:-}"; PYTHON_BIN="$2"; shift 2 ;;
        --python=*)      PYTHON_BIN="${1#*=}"; shift ;;
        --password-file)   _flag_need "$1" "${2:-}"; SSH_PASSWORD_FILE="$2"; shift 2 ;;
        --password-file=*) SSH_PASSWORD_FILE="${1#*=}"; shift ;;
        --password-env)    _flag_need "$1" "${2:-}"; SSH_PASSWORD_ENV="$2"; shift 2 ;;
        --password-env=*)  SSH_PASSWORD_ENV="${1#*=}"; shift ;;
        --ask-password)    SSH_ASK_PASSWORD=yes; shift ;;
        --)              shift; _PARSED+=("$@"); break ;;
        -h|--help)       _PARSED+=("help"); shift ;;
        --*)             _flag_die "unknown flag: $1" ;;
        *)               _PARSED+=("$1"); shift ;;
    esac
done
set -- "${_PARSED[@]}"
unset _PARSED

# Re-validate the integer flags now that env+CLI have been merged.
# Garbage values get caught here instead of silently propagating into
# generated scripts and only failing on the remote side at iperf time.
_validate_uint() {
    # _validate_uint <name> <value> <min>
    local name="$1" val="$2" min="$3"
    case "$val" in
        ''|*[!0-9]*) _flag_die "$name must be a non-negative integer (got '$val')" ;;
    esac
    [ "$val" -ge "$min" ] || _flag_die "$name must be >= $min (got $val)"
}
_validate_uint "IPERF_JOBS / --jobs"           "$IPERF_JOBS"     1
_validate_uint "IPERF_PORT / --port"           "$IPERF_PORT"     1
_validate_uint "IPERF_DURATION / --duration"   "$IPERF_DURATION" 1
_validate_uint "IPERF_PARALLEL / --parallel"   "$IPERF_PARALLEL" 1
_validate_uint "START_DELAY / --start-delay"   "$START_DELAY"    0
[ "$IPERF_PORT" -le 65535 ] || _flag_die "IPERF_PORT / --port must be <= 65535 (got $IPERF_PORT)"

# Paths derived from IPERF_DIR (computed AFTER flags so --iperf-dir works).
STATE_FILE="$IPERF_DIR/state"
SERVER_LIST_FILE="$IPERF_DIR/servers.list"
RESULTS_DIR="$IPERF_DIR/results"
LOGS_DIR="$IPERF_DIR/logs"
SCRIPTS_DIR="$IPERF_DIR/scripts"

mkdir -p "$IPERF_DIR" "$RESULTS_DIR" "$LOGS_DIR" "$SCRIPTS_DIR"

#------------------------------------------------------------------------------
# Logging
#------------------------------------------------------------------------------
ts()    { date '+%Y-%m-%d %H:%M:%S'; }
log()   { echo "[$(ts)] $*" | tee -a "$LOGS_DIR/orchestrator.log"; }
warn()  { echo "[$(ts)] WARN: $*"  | tee -a "$LOGS_DIR/orchestrator.log" >&2; }
err()   { echo "[$(ts)] ERROR: $*" | tee -a "$LOGS_DIR/orchestrator.log" >&2; }
die()   { err "$*"; exit 1; }

#------------------------------------------------------------------------------
# State (key=value file, loaded into associative array)
#------------------------------------------------------------------------------
declare -A STATE

load_state() {
    STATE=()
    [ -f "$STATE_FILE" ] || return 0
    while IFS='=' read -r k v; do
        [ -z "$k" ] && continue
        case "$k" in \#*) continue ;; esac
        STATE[$k]="$v"
    done < "$STATE_FILE"
}

save_state() {
    local tmp="$STATE_FILE.tmp"
    : > "$tmp"
    for k in "${!STATE[@]}"; do
        echo "$k=${STATE[$k]}" >> "$tmp"
    done
    mv "$tmp" "$STATE_FILE"
}

set_state() {
    load_state
    STATE[$1]="$2"
    save_state
}

get_state() {
    load_state
    echo "${STATE[$1]:-no}"
}

#------------------------------------------------------------------------------
# Server list helpers
#------------------------------------------------------------------------------
read_servers() {
    [ -f "$SERVER_LIST_FILE" ] || die "No server list. Run: $0 init <server_list_file>"
    # Strip blank lines, comments, and surrounding whitespace
    sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        "$SERVER_LIST_FILE" | grep -v '^$'
}

#------------------------------------------------------------------------------
# SSH wrappers
#------------------------------------------------------------------------------
ssh_run() {
    # ssh_run <host> <command...>
    local host="$1"; shift
    # shellcheck disable=SC2086
    ssh $SSH_BATCH_OPTS "$SSH_USER@$host" "$@"
}

ssh_run_interactive() {
    # Allows password prompts (used by ssh-setup before keys exist)
    local host="$1"; shift
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$SSH_USER@$host" "$@"
}

scp_to() {
    # scp_to <local_src> <host> <remote_dst>
    local src="$1" host="$2" dst="$3"
    # shellcheck disable=SC2086
    scp $SSH_BATCH_OPTS "$src" "$SSH_USER@$host:$dst" >/dev/null
}

scp_from() {
    # scp_from <host> <remote_src> <local_dst>
    local host="$1" src="$2" dst="$3"
    # shellcheck disable=SC2086
    scp $SSH_BATCH_OPTS "$SSH_USER@$host:$src" "$dst" >/dev/null 2>&1
}

#------------------------------------------------------------------------------
# Capped-concurrency parallel host fan-out
#
# parallel_hosts <worker_fn>
#   Runs <worker_fn> <host> in the background for every host in the server
#   list, with at most $IPERF_JOBS concurrent workers. Each worker's stdout
#   and stderr are captured to a per-host buffer and replayed in original
#   server-list order after all workers finish, so output stays readable
#   even when 100 hosts are running in parallel.
#
#   Workers are subshells of this script and can call log()/warn(), use
#   ssh_run / scp_to / scp_from, etc. log() still appends to the central
#   orchestrator.log in real time via tee -a (POSIX guarantees PIPE_BUF-
#   sized atomic appends), so `tail -f` shows live progress while the
#   per-worker stdout/stderr is buffered for ordered replay.
#
#   The worker's exit status is recorded; PARALLEL_FAILED is set to the
#   list of hosts whose worker exited non-zero. Caller checks that array
#   instead of a return value.
#------------------------------------------------------------------------------
parallel_hosts() {
    local fn="$1"
    local jobs="$IPERF_JOBS"
    [ "$jobs" -lt 1 ] && jobs=1

    # read_servers calls die() when the list is missing, but we invoke
    # it inside a process substitution below -- its exit only kills
    # the subshell, so the parent would silently see an empty host
    # list and falsely flag the pipeline step as completed. Check
    # the file up front so the failure surfaces.
    [ -f "$SERVER_LIST_FILE" ] || die "No server list. Run: $0 init <server_list_file>"

    local hosts=() h
    while IFS= read -r h; do
        [ -z "$h" ] && continue
        hosts+=("$h")
    done < <(read_servers)
    local n=${#hosts[@]}

    PARALLEL_FAILED=()
    [ "$n" -eq 0 ] && return 0

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/iperf-orch-XXXXXX") || die "mktemp failed"

    local i running=0
    for ((i=0; i<n; i++)); do
        if [ "$running" -ge "$jobs" ]; then
            # Block until any one worker exits, then free a slot.
            wait -n 2>/dev/null || wait
            running=$((running - 1))
        fi
        (
            "$fn" "${hosts[$i]}" > "$tmpdir/$i.out" 2>&1
            echo $? > "$tmpdir/$i.rc"
        ) &
        running=$((running + 1))
    done
    wait

    for ((i=0; i<n; i++)); do
        [ -s "$tmpdir/$i.out" ] && cat "$tmpdir/$i.out"
        local rc
        rc=$(cat "$tmpdir/$i.rc" 2>/dev/null)
        [ "${rc:-1}" -ne 0 ] && PARALLEL_FAILED+=("${hosts[$i]}")
    done
    rm -rf "$tmpdir"
}

#------------------------------------------------------------------------------
# Balanced pair assignment
#
# For each unordered pair {a, b} we need to pick exactly one endpoint to
# act as the iperf2 client. The naive "lex-smaller is always the client"
# rule gives huge load imbalance: the alphabetically-first host runs N-1
# clients, the last runs 0. Bad for fan-out, bad for the lex-first host's
# uplink, and (in parallel mode) it means the lex-first host carries far
# more outbound traffic than anyone else.
#
# The fix is the parity rule on host indices: for a pair with indices i,j,
# the client is the smaller index when i+j is even, the larger when i+j
# is odd. This guarantees every host runs roughly (N-1)/2 clients:
#   - N odd:   every host runs exactly (N-1)/2 clients (perfectly balanced)
#   - N even:  every host runs (N-2)/2 or N/2 clients (max-min spread = 1)
# At N=100 that's 49 or 50 clients per host instead of 0..99.
#
# Both endpoints of a pair use the same indices and the same rule, so they
# always agree on which one is the client. No coordination required.
#------------------------------------------------------------------------------

build_host_idx() {
    # Populates the global HOST_IDX associative array: host -> 0-based
    # index in the order the servers are listed.
    declare -gA HOST_IDX
    HOST_IDX=()
    local idx=0 h
    while IFS= read -r h; do
        [ -z "$h" ] && continue
        HOST_IDX[$h]=$idx
        idx=$((idx + 1))
    done < <(read_servers)
}

is_client_for() {
    # Returns 0 (true) if `src` is the assigned client for pair {src, dst},
    # else 1. Requires HOST_IDX to be populated (call build_host_idx first).
    local src="$1" dst="$2"
    [ "$src" = "$dst" ] && return 1
    local i="${HOST_IDX[$src]:-}"
    local j="${HOST_IDX[$dst]:-}"
    if [ -z "$i" ] || [ -z "$j" ]; then return 1; fi
    if [ $(( (i + j) % 2 )) -eq 0 ]; then
        # Even sum: smaller-index endpoint is client
        [ "$i" -lt "$j" ]
    else
        # Odd sum: larger-index endpoint is client
        [ "$i" -gt "$j" ]
    fi
}

#==============================================================================
# Subcommands
#==============================================================================

usage() {
    cat <<EOF
iperf-orchestrator.sh - full-mesh iperf2 testing across a server list

Each host pair is tested once with iperf2 --full-duplex (single TCP
socket carrying traffic in both directions). The CSV parser produces
two rows per test, one for each direction, so the heatmap is filled
symmetrically by direction but values can differ.

USAGE:
    $0 [global flags] <command> [args]

GLOBAL FLAGS (override env vars; both --flag value and --flag=value work):
    --port PORT                iperf2 listening port (default $IPERF_PORT)
    --duration, -d SECONDS     test duration per pair (default $IPERF_DURATION)
    --parallel, -P N           parallel streams within each test (default $IPERF_PARALLEL)
    --jobs, -j N               max concurrent SSH/SCP fan-out (default $IPERF_JOBS)
    --start-delay SECONDS      synchronized-start lead time (default $START_DELAY)
    --ssh-user, -u USER        SSH login user (default $SSH_USER)
    --iperf-dir PATH           local working dir (default $IPERF_DIR)
    --remote-dir PATH          remote working dir (default $REMOTE_DIR)
    --python PATH              Python interpreter (default $PYTHON_BIN)
    --password-file PATH       Read SSH password from PATH (single line; chmod 600).
                               Enables automated 'expect'-driven ssh-setup.
    --password-env VAR         Read SSH password from env var named VAR.
                               Enables automated 'expect'-driven ssh-setup.
    --ask-password             Prompt once for an SSH password and reuse it
                               for every host. Enables 'expect'-driven ssh-setup.
    -h, --help                 show this message

SETUP:
    init <server_list>     Set the server list (one IP/host per line; '#' comments OK)
    ssh-setup              Generate (if needed) and distribute SSH keys to all hosts.
                           By default prompts you per-host for the SSH password
                           (sequential). Pass --password-file / --password-env /
                           --ask-password to drive ssh-copy-id non-interactively
                           via 'expect', in parallel (capped by --jobs).
    check-iperf            Check which hosts have iperf2 installed
    check-servers          Check which hosts currently have iperf -s running

EXECUTION:
    start-servers          Start iperf2 in daemon mode on every host
    create-scripts         Generate per-host client run scripts locally
    distribute-scripts     Copy each host's run script to that host
    run-tests [MODE]       Run the tests. MODE is one of:
                             parallel         (default) all hosts launch all of
                                              their clients simultaneously after
                                              a synchronized start. Maximum mesh
                                              contention; fastest wall-clock.
                             sequential-host  hosts run one at a time; the
                                              active host fires its clients to
                                              all targets in parallel.
                             sequential-pair  exactly one connection on the wire
                                              at any moment. Cleanest per-pair
                                              numbers; takes N*(N-1)/2 * duration
                                              (canonical pairs only).
    collect-results        Pull every iperf_test_<src>_to_<dst>.log back to results/
    stop-servers           Kill iperf -s on every host
    cleanup                Remove the remote working directory on every host

ANALYSIS:
    parse-csv              Parse all .log iperf2 CSV files into results/iperf_results.csv
                           (two rows per file, one per direction)
    parse-cpu              Parse cpu_<host>.log mpstat samples into results/cpu_summary.csv
                           and print a per-host peak/mean CPU table
    make-pivot             Build a text pivot table at results/iperf_pivot.txt
    make-heatmap           Render results/iperf_heatmap.png (heatmap + bar chart)

CONVENIENCE:
    all [MODE]             Run the full sequence end-to-end (MODE is forwarded
                           to run-tests; default parallel)
    status                 Show what has been done so far
    help                   Show this message

CONFIG (env vars; CLI flags above take precedence):
    IPERF_PORT=$IPERF_PORT
    IPERF_DURATION=$IPERF_DURATION       # seconds per pair
    IPERF_PARALLEL=$IPERF_PARALLEL       # parallel streams
    IPERF_JOBS=$IPERF_JOBS               # max concurrent SSH/SCP fan-out
    SSH_USER=$SSH_USER
    START_DELAY=$START_DELAY             # seconds in future for sync start
    IPERF_DIR=$IPERF_DIR

FILES:
    Server list:  $SERVER_LIST_FILE
    State:        $STATE_FILE
    Results:      $RESULTS_DIR/
    Logs:         $LOGS_DIR/
EOF
}

#------------------------------------------------------------------------------
cmd_init() {
    local src="${1:-}"
    [ -n "$src" ] || die "Usage: $0 init <server_list_file>"
    [ -f "$src" ] || die "File not found: $src"

    cp "$src" "$SERVER_LIST_FILE"
    : > "$STATE_FILE"
    set_state SERVER_LIST_LOADED yes

    local n
    n=$(read_servers | wc -l)

    # Warn on duplicates: the script keys on hostname for HOST_IDX,
    # output paths, and per-host log files, so duplicates would
    # silently overwrite each other and skew the parity-rule load
    # balance.
    local dups
    dups=$(read_servers | sort | uniq -d)
    if [ -n "$dups" ]; then
        warn "Server list contains duplicate hostnames; per-host scripts and"
        warn "logs would overwrite each other. Duplicates:"
        while IFS= read -r d; do
            warn "  $d"
        done <<< "$dups"
    fi

    log "Initialized with $n hosts from $src -> $SERVER_LIST_FILE"
}

#------------------------------------------------------------------------------
cmd_status() {
    load_state
    echo "=== iperf-orchestrator status ==="
    echo "IPERF_DIR:       $IPERF_DIR"
    echo "Server list:     $SERVER_LIST_FILE"
    if [ -f "$SERVER_LIST_FILE" ]; then
        echo "Hosts:           $(read_servers | wc -l)"
    else
        echo "Hosts:           (no list yet)"
    fi
    echo
    echo "Pipeline state:"
    local steps=(
        SERVER_LIST_LOADED
        SSH_KEYS_DISTRIBUTED
        IPERF_INSTALLED_CHECKED
        SERVERS_RUNNING_CHECKED
        SERVERS_STARTED
        SCRIPTS_CREATED
        SCRIPTS_DISTRIBUTED
        TESTS_RUN
        RESULTS_COLLECTED
        SERVERS_STOPPED
        CLEANED_UP
        CSV_BUILT
        CPU_PARSED
        PIVOT_BUILT
        HEATMAP_BUILT
    )
    for s in "${steps[@]}"; do
        printf "  %-30s %s\n" "$s" "${STATE[$s]:-no}"
    done

    # Show per-host check results if present
    for f in "$IPERF_DIR/iperf_installed.txt" "$IPERF_DIR/iperf_running.txt"; do
        if [ -f "$f" ]; then
            echo
            echo "--- $(basename "$f") ---"
            cat "$f"
        fi
    done
}

#------------------------------------------------------------------------------
# Resolve a single SSH password from --password-file / --password-env /
# --ask-password. Echoes the password to stdout. Exits if the configured
# source is unusable.
_resolve_ssh_password() {
    if [ -n "$SSH_PASSWORD_FILE" ]; then
        [ -f "$SSH_PASSWORD_FILE" ] || die "password file not found: $SSH_PASSWORD_FILE"
        local perms=""
        perms=$(stat -c '%a' "$SSH_PASSWORD_FILE" 2>/dev/null || stat -f '%A' "$SSH_PASSWORD_FILE" 2>/dev/null || echo "")
        case "$perms" in
            ''|400|600) ;;
            *) warn "password file $SSH_PASSWORD_FILE has permissions $perms; recommend chmod 600" ;;
        esac
        local pw
        IFS= read -r pw < "$SSH_PASSWORD_FILE" || true
        [ -n "$pw" ] || die "password file $SSH_PASSWORD_FILE is empty"
        printf '%s' "$pw"
        return 0
    fi
    if [ -n "$SSH_PASSWORD_ENV" ]; then
        local val="${!SSH_PASSWORD_ENV:-}"
        [ -n "$val" ] || die "env var \$$SSH_PASSWORD_ENV is empty or unset"
        printf '%s' "$val"
        return 0
    fi
    if [ "$SSH_ASK_PASSWORD" = "yes" ]; then
        local pw
        printf "SSH password (used for all hosts): " >&2
        IFS= read -rs pw < /dev/tty
        printf '\n' >&2
        [ -n "$pw" ] || die "empty password"
        printf '%s' "$pw"
        return 0
    fi
}

# Drive ssh-copy-id to a single host using `expect`. Reads the password from
# the env var _IPERF_ORCH_PW so it never appears in argv (and thus not in
# `ps`). Returns 0 on success, non-zero on failure.
_ssh_copy_id_expect() {
    local host="$1"
    expect -f - "$SSH_USER" "$host" <<'EXPECT_EOF'
log_user 0
set timeout 30
set user [lindex $argv 0]
set host [lindex $argv 1]
if {![info exists env(_IPERF_ORCH_PW)]} {
    puts stderr "expect: _IPERF_ORCH_PW not set"
    exit 3
}
set password $env(_IPERF_ORCH_PW)
set sent_pw 0
spawn ssh-copy-id -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -- $user@$host
expect {
    -re {\(yes/no[^)]*\)\??} { send "yes\r"; exp_continue }
    -nocase -re {password:[ ]*$} {
        if {$sent_pw} {
            puts stderr "authentication failed for $user@$host"
            exit 5
        }
        incr sent_pw
        send -- "$password\r"
        exp_continue
    }
    -nocase "permission denied" {
        puts stderr "permission denied for $user@$host"
        exit 5
    }
    timeout { puts stderr "timeout connecting to $host"; exit 2 }
    eof {}
}
catch wait result
exit [lindex $result 3]
EXPECT_EOF
}

# Parallel worker for the expect-driven path. _IPERF_ORCH_PW must be exported
# in the parent so it's inherited by this subshell.
_worker_ssh_copy_id() {
    local host="$1"
    log "Distributing key to $host (automated via expect)"
    if _ssh_copy_id_expect "$host" >/dev/null 2>&1; then
        log "  OK: $host"
        return 0
    fi
    warn "  FAILED: $host (try manually: ssh-copy-id $SSH_USER@$host)"
    return 1
}

cmd_ssh_setup() {
    # Make sure we have a key
    local key="$HOME/.ssh/id_ed25519"
    if [ ! -f "$key" ] && [ ! -f "$HOME/.ssh/id_rsa" ]; then
        log "No SSH key found; generating $key"
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        ssh-keygen -t ed25519 -N "" -f "$key" -q
    fi

    # Resolve password source (if any). When set, we use `expect` to drive
    # ssh-copy-id non-interactively, in parallel across hosts.
    local use_expect=0
    if [ -n "$SSH_PASSWORD_FILE" ] || [ -n "$SSH_PASSWORD_ENV" ] || [ "$SSH_ASK_PASSWORD" = "yes" ]; then
        command -v expect >/dev/null 2>&1 \
            || die "automated password entry requires 'expect' (install with: apt install expect / dnf install expect / brew install expect)"
        # Export so subshells (parallel workers -> expect) inherit it.
        # Resolved once and reused for every host.
        export _IPERF_ORCH_PW
        _IPERF_ORCH_PW=$(_resolve_ssh_password)
        use_expect=1
    fi

    local failure_count=0
    if [ "$use_expect" = "1" ]; then
        log "Distributing keys in parallel (max $IPERF_JOBS concurrent)"
        parallel_hosts _worker_ssh_copy_id
        failure_count=${#PARALLEL_FAILED[@]}
        # Scrub the password from the environment.
        unset _IPERF_ORCH_PW
    else
        # Interactive fallback: must stay sequential so password prompts
        # don't collide on stdin.
        local hosts; hosts=$(read_servers)
        local host
        while IFS= read -r host; do
            [ -z "$host" ] && continue
            log "Distributing key to $host (you may be prompted for the password)"
            if ssh-copy-id -o StrictHostKeyChecking=accept-new "$SSH_USER@$host" >/dev/null 2>&1; then
                log "  OK: $host"
            else
                warn "  FAILED: $host (try manually: ssh-copy-id $SSH_USER@$host)"
                failure_count=$((failure_count + 1))
            fi
        done <<< "$hosts"
    fi

    if [ "$failure_count" -eq 0 ]; then
        set_state SSH_KEYS_DISTRIBUTED yes
        log "SSH keys distributed to all hosts"
    else
        warn "ssh-setup completed with $failure_count failure(s)"
    fi
}

#------------------------------------------------------------------------------
_worker_check_iperf() {
    local host="$1"
    # iperf2's binary is `iperf` (vs `iperf3`). Probe with -v and check
    # the version string says "version 2". Also probe mpstat -- if it's
    # missing the run-script falls back to /proc/stat, which works but
    # gives only box-wide CPU (no per-core breakdown).
    local ver mp
    ver=$(ssh_run "$host" 'iperf -v 2>&1 | head -n1' 2>/dev/null || true)
    mp=$(ssh_run "$host" 'command -v mpstat >/dev/null && echo yes || echo no' 2>/dev/null || echo "?")

    local iperf_status=""
    if [ -n "$ver" ] && echo "$ver" | grep -qE 'iperf[[:space:]]*version[[:space:]]*2'; then
        iperf_status="INSTALLED"
    elif [ -n "$ver" ]; then
        # Found something called iperf but it's not v2 (probably v3 with
        # an `iperf` symlink, or some other binary).
        iperf_status="WRONG_VERSION"
    else
        iperf_status="MISSING"
    fi

    printf "%-30s %-13s %-12s %s\n" "$host" "$iperf_status" "mpstat=$mp" "$ver"
}

cmd_check_iperf() {
    # Up-front check: parallel_hosts itself dies on a missing server
    # list, but we pipe its output through tee below, which forks
    # parallel_hosts into a subshell -- the die's exit only kills that
    # subshell and the outer command would falsely flag the step done.
    [ -f "$SERVER_LIST_FILE" ] || die "No server list. Run: $0 init <server_list_file>"
    local out="$IPERF_DIR/iperf_installed.txt"
    : > "$out"
    log "Checking iperf2 + mpstat availability on all hosts (parallel x$IPERF_JOBS)..."
    parallel_hosts _worker_check_iperf | tee -a "$out"
    set_state IPERF_INSTALLED_CHECKED yes
    log "Wrote $out"
}

#------------------------------------------------------------------------------
_worker_check_servers() {
    local host="$1"
    # `pgrep -x iperf` matches process name exactly = "iperf", which
    # excludes "iperf3". Adding -a includes the full command line.
    local result
    result=$(ssh_run "$host" "pgrep -ax iperf || true" 2>/dev/null || true)
    if [ -n "$result" ]; then
        printf "%-30s RUNNING    %s\n" "$host" "$(echo "$result" | head -n1)"
    else
        printf "%-30s STOPPED\n" "$host"
    fi
}

cmd_check_servers() {
    # See cmd_check_iperf for why we double-check here despite
    # parallel_hosts already validating the server list.
    [ -f "$SERVER_LIST_FILE" ] || die "No server list. Run: $0 init <server_list_file>"
    local out="$IPERF_DIR/iperf_running.txt"
    : > "$out"
    log "Checking iperf2 daemon status on port $IPERF_PORT (parallel x$IPERF_JOBS)..."
    parallel_hosts _worker_check_servers | tee -a "$out"
    set_state SERVERS_RUNNING_CHECKED yes
    log "Wrote $out"
}

#------------------------------------------------------------------------------
_worker_start_server() {
    local host="$1"
    # pkill -x matches the exact process name "iperf" (not "iperf3").
    # iperf2's multi-threaded server handles concurrent clients on one
    # port, so we only need a single instance per host.
    if ssh_run "$host" "
        mkdir -p '$REMOTE_DIR' &&
        pkill -x iperf 2>/dev/null; sleep 1;
        nohup iperf -s -p $IPERF_PORT > '$REMOTE_DIR/iperf_server.log' 2>&1 &
        disown || true
        sleep 1
        pgrep -x iperf >/dev/null
    "; then
        log "  OK: $host"
    else
        warn "  FAILED to start on $host"
        return 1
    fi
}

cmd_start_servers() {
    log "Starting iperf2 -s on port $IPERF_PORT on every host (parallel x$IPERF_JOBS)..."
    parallel_hosts _worker_start_server

    if [ ${#PARALLEL_FAILED[@]} -eq 0 ]; then
        set_state SERVERS_STARTED yes
        log "All iperf2 servers started"
    else
        warn "start-servers completed with ${#PARALLEL_FAILED[@]} failure(s)"
    fi
}

#------------------------------------------------------------------------------
cmd_create_scripts() {
    log "Generating per-host client run scripts (balanced pair assignment)..."
    local hosts; hosts=$(read_servers)
    [ -n "$hosts" ] || die "No hosts in server list"

    build_host_idx

    # Track per-host target counts so we can show the user the load
    # distribution after generation. With the parity rule the spread
    # should be 0 (N odd) or 1 (N even).
    local target_counts=()

    while IFS= read -r src; do
        [ -z "$src" ] && continue
        local script="$SCRIPTS_DIR/run_${src}.sh"

        # Each unordered pair is tested once, but instead of always making
        # the lex-smaller host the client (which gives a 0..N-1 imbalance),
        # we use the parity rule on host indices. Result: every host runs
        # roughly (N-1)/2 clients, max-min spread of 1 even when N is even.
        local targets=()
        while IFS= read -r t; do
            [ -z "$t" ] && continue
            [ "$t" = "$src" ] && continue
            if is_client_for "$src" "$t"; then
                targets+=("$t")
            fi
        done <<< "$hosts"

        target_counts+=("${#targets[@]}")

        local targets_str=""
        for t in "${targets[@]}"; do
            targets_str+="\"$t\" "
        done

        cat > "$script" <<EOF
#!/usr/bin/env bash
# Auto-generated by iperf-orchestrator. Do not edit by hand.
# Source host: $src
# Targets:     ${targets[*]}
#
# Runs iperf2 --full-duplex against each target. One TCP socket per pair,
# carrying traffic in both directions concurrently. The log file gets a
# small header line first so the parser doesn't have to guess which two
# hosts the test was between based on the filename alone.
set -u

START_TIME="\${1:-0}"
SINGLE_TARGET="\${2:-}"
SOURCE="$src"
PORT=$IPERF_PORT
DURATION=$IPERF_DURATION
PARALLEL=$IPERF_PARALLEL
TARGETS=( $targets_str )

cd "\$(dirname "\$0")"

# Synchronized launch: wait until START_TIME (epoch seconds), if given.
if [ "\$START_TIME" -gt 0 ]; then
    now=\$(date +%s)
    if [ "\$START_TIME" -gt "\$now" ]; then
        sleep \$(( START_TIME - now ))
    fi
fi

# Pick the target list: a single target overrides the full list (used by
# sequential-pair mode, which calls this script once per pair).
if [ -n "\$SINGLE_TARGET" ]; then
    run_targets=( "\$SINGLE_TARGET" )
else
    run_targets=( "\${TARGETS[@]}" )
fi

echo "\$(date '+%F %T') START \$SOURCE -> \${run_targets[*]}" >> "iperf_run_\${SOURCE}.status"

# Start CPU sampling. We want to capture the test window plus a small tail
# so the "after" baseline is visible. mpstat with -P ALL gives per-core
# breakdown; that's important because softirq load on a single hashed core
# can be the bottleneck even when the box-wide average looks fine.
#
# If mpstat isn't installed we fall back to sampling /proc/stat directly,
# which gives box-wide CPU but no per-core. The fallback file format is
# made deliberately distinguishable from mpstat's so the parser can tell
# them apart.
SAMPLE_DURATION=\$(( DURATION + 4 ))
cpu_log="cpu_\${SOURCE}.log"
cpu_pid=""

if command -v mpstat >/dev/null 2>&1; then
    LC_ALL=C S_TIME_FORMAT=ISO mpstat -P ALL 1 "\$SAMPLE_DURATION" \
        > "\$cpu_log" 2>&1 &
    cpu_pid=\$!
else
    {
        echo "# fallback=proc_stat host=\$SOURCE samples=\$SAMPLE_DURATION"
        for _ in \$(seq 1 "\$SAMPLE_DURATION"); do
            date '+%F %T'
            head -n1 /proc/stat
            sleep 1
        done
    } > "\$cpu_log" 2>&1 &
    cpu_pid=\$!
fi

# Even hosts with no client work still receive inbound traffic from their
# peers, so we want CPU samples from them too. They skip the iperf-client
# loop but still wait for the sampler.
if [ \${#run_targets[@]} -gt 0 ]; then
    # Fire every client in parallel and wait for the whole batch. Each
    # invocation uses --full-duplex (one socket, both directions).
    # -y C gives CSV summaries; -e enables enhanced reports.
    pids=()
    for target in "\${run_targets[@]}"; do
        out="iperf_test_\${SOURCE}_to_\${target}.log"
        echo "\$(date '+%F %T') testing <-> \$target" >> "iperf_run_\${SOURCE}.status"
        {
            # Header line consumed by the parser. Keys are space-separated to keep parsing trivial.
            echo "# pair_a=\$SOURCE pair_b=\$target duration=\$DURATION port=\$PORT parallel=\$PARALLEL test_start=\$(date +%s)"
            iperf -c "\$target" -p "\$PORT" -t "\$DURATION" -P "\$PARALLEL" --full-duplex -e -y C 2>&1
        } > "\$out" &
        pids+=(\$!)
    done

    for p in "\${pids[@]}"; do
        wait "\$p" || true
    done
fi

# Wait for the CPU sampler to finish its window. It runs for DURATION+4
# seconds so it captures a couple of post-test samples too.
if [ -n "\$cpu_pid" ]; then
    wait "\$cpu_pid" 2>/dev/null || true
fi

echo "\$(date '+%F %T') DONE" >> "iperf_run_\${SOURCE}.status"
EOF
        chmod +x "$script"
        log "  created $script (targets: ${#targets[@]})"
    done <<< "$hosts"

    # Summarize the client-load distribution so the user can confirm the
    # balancing worked. With the parity rule, max-min should be 0 or 1.
    if [ ${#target_counts[@]} -gt 0 ]; then
        local mn=${target_counts[0]} mx=${target_counts[0]} sum=0 c
        for c in "${target_counts[@]}"; do
            [ "$c" -lt "$mn" ] && mn=$c
            [ "$c" -gt "$mx" ] && mx=$c
            sum=$((sum + c))
        done
        local n=${#target_counts[@]}
        # Integer mean to one decimal: (sum*10)/n with rounding
        local mean10=$(( (sum * 10 + n / 2) / n ))
        log "Client load: min=$mn, max=$mx, mean=$((mean10/10)).$((mean10%10)), total tests=$sum"
    fi

    set_state SCRIPTS_CREATED yes
    log "All run scripts created in $SCRIPTS_DIR"
}

#------------------------------------------------------------------------------
_worker_distribute_script() {
    local host="$1"
    local script="$SCRIPTS_DIR/run_${host}.sh"
    if [ ! -f "$script" ]; then
        warn "  no script for $host (run create-scripts first)"
        return 1
    fi
    if ssh_run "$host" "mkdir -p '$REMOTE_DIR' && rm -f '$REMOTE_DIR'/iperf_test_*.log '$REMOTE_DIR'/iperf_run_*.status '$REMOTE_DIR'/iperf_run_*.complete" \
       && scp_to "$script" "$host" "$REMOTE_DIR/run_iperf.sh" \
       && ssh_run "$host" "chmod +x '$REMOTE_DIR/run_iperf.sh'"; then
        log "  OK: $host"
    else
        warn "  FAILED: $host"
        return 1
    fi
}

cmd_distribute_scripts() {
    log "Distributing run scripts to each host (parallel x$IPERF_JOBS)..."
    parallel_hosts _worker_distribute_script

    if [ ${#PARALLEL_FAILED[@]} -eq 0 ]; then
        set_state SCRIPTS_DISTRIBUTED yes
        log "All run scripts distributed"
    else
        warn "distribute-scripts had ${#PARALLEL_FAILED[@]} failure(s)"
    fi
}

#------------------------------------------------------------------------------
cmd_run_tests() {
    local mode="${1:-parallel}"
    case "$mode" in
        parallel)        _run_parallel ;;
        sequential-host) _run_sequential_host ;;
        sequential-pair) _run_sequential_pair ;;
        *) die "Unknown mode: $mode (expected: parallel | sequential-host | sequential-pair)" ;;
    esac
}

# parallel: every host runs its full test sequence at the same synchronized
# start time. Fastest wall-clock, but flows compete with each other on the
# wire so per-pair numbers will be lower than line rate.
_run_parallel() {
    local hosts; hosts=$(read_servers)
    [ -n "$hosts" ] || die "No hosts"

    local n_hosts
    n_hosts=$(echo "$hosts" | wc -l)
    local n_pairs=$(( n_hosts * (n_hosts - 1) / 2 ))

    local start_time=$(( $(date +%s) + START_DELAY ))
    local human_start
    human_start=$(date -d "@$start_time" '+%F %T' 2>/dev/null || date -r "$start_time" '+%F %T')

    # Per-host iperf2 calls are launched in parallel on the remote side, so
    # each host's wall-clock is roughly DURATION regardless of mesh size.
    local est=$(( IPERF_DURATION + START_DELAY + 10 ))
    log "Mode: parallel (canonical pairs, full-duplex)"
    log "Synchronized start at $human_start (epoch $start_time)"
    log "$n_pairs pairs tested simultaneously for ${IPERF_DURATION}s; estimated total ~${est}s"

    # Two parallel arrays instead of "$pid:$host" strings, so an IPv6
    # hostname (which contains colons) doesn't get truncated when we
    # try to recover it for the per-host log line.
    local pids=()
    local hosts_for_pids=()
    while IFS= read -r host; do
        [ -z "$host" ] && continue
        local hostlog="$LOGS_DIR/run_${host}.log"
        ssh_run "$host" "'$REMOTE_DIR/run_iperf.sh' $start_time" \
            > "$hostlog" 2>&1 &
        pids+=("$!")
        hosts_for_pids+=("$host")
    done <<< "$hosts"

    log "Launched ${#pids[@]} remote sessions; waiting for completion..."
    local failed=()
    local i p h
    for i in "${!pids[@]}"; do
        p="${pids[$i]}"
        h="${hosts_for_pids[$i]}"
        if wait "$p"; then
            log "  finished: $h"
        else
            warn "  finished with errors: $h (see $LOGS_DIR/run_${h}.log)"
            failed+=("$h")
        fi
    done

    if [ ${#failed[@]} -eq 0 ]; then
        set_state TESTS_RUN yes
        set_state TESTS_RUN_MODE parallel
        log "All hosts completed (parallel)"
    else
        warn "run-tests had ${#failed[@]} failure(s); collect-results will still try"
    fi
}

# sequential-host: hosts run their full sequences one at a time. Each host's
# numbers are clean (no other host is generating traffic), but a single host
# is still pushing on multiple targets back-to-back, so any cross-target
# interference within that host's stack still exists.
_run_sequential_host() {
    local hosts; hosts=$(read_servers)
    [ -n "$hosts" ] || die "No hosts"

    local n
    n=$(echo "$hosts" | wc -l)
    local est_per_host=$(( IPERF_DURATION + 5 ))
    local est_total=$(( n * est_per_host ))
    log "Mode: sequential-host (canonical pairs, full-duplex)"
    log "$n hosts; each runs its canonical-client tests in parallel for ${IPERF_DURATION}s; estimated total ~${est_total}s"

    local i=0
    local failed=()
    while IFS= read -r host; do
        [ -z "$host" ] && continue
        i=$((i + 1))
        log "[$i/$n] running on $host (~${est_per_host}s)..."
        local hostlog="$LOGS_DIR/run_${host}.log"
        if ssh_run "$host" "'$REMOTE_DIR/run_iperf.sh' 0" > "$hostlog" 2>&1; then
            log "  finished: $host"
        else
            warn "  finished with errors: $host (see $hostlog)"
            failed+=("$host")
        fi
    done <<< "$hosts"

    if [ ${#failed[@]} -eq 0 ]; then
        set_state TESTS_RUN yes
        set_state TESTS_RUN_MODE sequential-host
        log "All hosts completed (sequential-host)"
    else
        warn "sequential-host had ${#failed[@]} failure(s); collect-results will still try"
    fi
}

# sequential-pair: exactly one full-duplex connection on the wire at any
# moment. Cleanest per-pair numbers. Iterates canonical pairs only -- each
# test loads both directions, so we don't need to revisit the pair from
# the other side. Total tests = N*(N-1)/2.
_run_sequential_pair() {
    local hosts; hosts=$(read_servers)
    [ -n "$hosts" ] || die "No hosts"

    build_host_idx
    local host_arr=()
    while IFS= read -r h; do
        [ -z "$h" ] && continue
        host_arr+=("$h")
    done <<< "$hosts"

    local n=${#host_arr[@]}
    local total=$(( n * (n - 1) / 2 ))
    local est=$(( total * (IPERF_DURATION + 2) ))
    log "Mode: sequential-pair (balanced pair assignment, full-duplex)"
    log "$total tests, one at a time; estimated total ~${est}s"

    local i=0
    local failed=()
    for src in "${host_arr[@]}"; do
        for dst in "${host_arr[@]}"; do
            # Same parity rule used by create-scripts: visit each pair
            # once, with src as the client iff is_client_for says so.
            is_client_for "$src" "$dst" || continue
            i=$((i + 1))
            local pairlog="$LOGS_DIR/run_${src}_to_${dst}.log"
            log "[$i/$total] $src <-> $dst"
            if ssh_run "$src" "'$REMOTE_DIR/run_iperf.sh' 0 '$dst'" > "$pairlog" 2>&1; then
                :
            else
                warn "  failed: $src <-> $dst (see $pairlog)"
                failed+=("$src<->$dst")
            fi
        done
    done

    if [ ${#failed[@]} -eq 0 ]; then
        set_state TESTS_RUN yes
        set_state TESTS_RUN_MODE sequential-pair
        log "All pairs completed (sequential-pair)"
    else
        warn "sequential-pair had ${#failed[@]} failure(s); collect-results will still try"
    fi
}

#------------------------------------------------------------------------------
_worker_collect_results() {
    local host="$1"
    local tarball_remote="$REMOTE_DIR/_results_${host}.tar.gz"
    local tarball_local="$RESULTS_DIR/_results_${host}.tar.gz"

    # Build the tarball remotely. iperf_test_*.log filenames already
    # include the source host so they don't collide on extract; the
    # server log gets a host suffix to disambiguate. The status file
    # is already host-named.
    #
    # The last canonical host has no client logs; we still want its
    # server log and status file, so we tolerate iperf_test_*.log
    # matching nothing.
    if ! ssh_run "$host" "
        cd '$REMOTE_DIR' 2>/dev/null || exit 1
        cp iperf_server.log iperf_server_${host}.log 2>/dev/null || true
        {
            ls iperf_test_*.log 2>/dev/null || true
            ls iperf_server_${host}.log 2>/dev/null || true
            ls iperf_run_${host}.status 2>/dev/null || true
            ls cpu_${host}.log 2>/dev/null || true
        } > _iperf_files.list
        if [ -s _iperf_files.list ]; then
            tar -czf '$tarball_remote' -T _iperf_files.list
        fi
        rm -f _iperf_files.list iperf_server_${host}.log
        test -f '$tarball_remote'
    " 2>/dev/null; then
        warn "  $host: nothing to collect (empty REMOTE_DIR or tar failed)"
        return 0  # empty is normal for the lex-last host; not a failure
    fi

    if ! scp_from "$host" "$tarball_remote" "$tarball_local"; then
        warn "  $host: scp of tarball failed"
        return 1
    fi

    local client_count
    client_count=$(tar -tzf "$tarball_local" 2>/dev/null | grep -c '^iperf_test_' || true)
    if tar -xzf "$tarball_local" -C "$RESULTS_DIR" 2>/dev/null; then
        log "  $host: $client_count client logs + server log + status"
    else
        warn "  $host: local extraction failed"
        rm -f "$tarball_local"
        return 1
    fi

    rm -f "$tarball_local"
    ssh_run "$host" "rm -f '$tarball_remote'" 2>/dev/null || true
}

cmd_collect_results() {
    log "Collecting results from all hosts -> $RESULTS_DIR (tar-batched, parallel x$IPERF_JOBS)"
    parallel_hosts _worker_collect_results

    local total
    total=$(ls "$RESULTS_DIR"/iperf_test_*.log 2>/dev/null | wc -l)
    if [ ${#PARALLEL_FAILED[@]} -eq 0 ]; then
        set_state RESULTS_COLLECTED yes
        log "Collected $total client logs total"
    else
        warn "collect-results: ${#PARALLEL_FAILED[@]} host(s) had transfer failures"
    fi
}

#------------------------------------------------------------------------------
_worker_stop_server() {
    local host="$1"
    if ssh_run "$host" "pkill -x iperf 2>/dev/null; sleep 0.5; ! pgrep -x iperf >/dev/null"; then
        log "  stopped: $host"
    else
        warn "  $host still has iperf running"
        return 1
    fi
}

cmd_stop_servers() {
    log "Stopping iperf2 servers on every host (parallel x$IPERF_JOBS)..."
    parallel_hosts _worker_stop_server
    if [ ${#PARALLEL_FAILED[@]} -eq 0 ]; then
        set_state SERVERS_STOPPED yes
    else
        warn "stop-servers had ${#PARALLEL_FAILED[@]} failure(s)"
    fi
}

#------------------------------------------------------------------------------
_worker_cleanup() {
    local host="$1"
    if ssh_run "$host" "rm -rf '$REMOTE_DIR'"; then
        log "  cleaned: $host"
    else
        warn "  cleanup failed: $host"
        return 1
    fi
}

cmd_cleanup() {
    log "Removing $REMOTE_DIR on every host (parallel x$IPERF_JOBS)..."
    parallel_hosts _worker_cleanup
    if [ ${#PARALLEL_FAILED[@]} -eq 0 ]; then
        set_state CLEANED_UP yes
    else
        warn "cleanup had ${#PARALLEL_FAILED[@]} failure(s)"
    fi
}

#------------------------------------------------------------------------------
cmd_parse_csv() {
    local csv="$RESULTS_DIR/iperf_results.csv"
    log "Parsing iperf2 CSV logs -> $csv"
    command -v "$PYTHON_BIN" >/dev/null || die "$PYTHON_BIN not found; install Python 3"

    "$PYTHON_BIN" - "$RESULTS_DIR" "$csv" <<'PYEOF'
import os, sys, csv, glob

results_dir, out_csv = sys.argv[1], sys.argv[2]

# Each iperf2 --full-duplex log has the structure:
#
#   # pair_a=A pair_b=B duration=10 port=5001 parallel=1 test_start=...
#   <iperf2 CSV summary lines>
#
# iperf2's CSV format (-y C -e), one summary row per direction per stream:
#   timestamp,src_addr,src_port,dst_addr,dst_port,transfer_id,
#     interval,bytes,bits_per_second[,extra fields with -e]
#
# In --full-duplex mode iperf2 emits two summary lines for the aggregate
# (one per direction). Each line's source_address tells us which host's
# traffic that line measured. We map back to (pair_a, pair_b) by matching
# the source_address to one of the two ends.

def parse_header(line):
    """Parse '# key=value key=value ...' into a dict."""
    out = {}
    if not line.startswith("#"):
        return out
    for tok in line.lstrip("#").strip().split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            out[k] = v
    return out

def addr_matches(line_addr, host):
    """iperf2 may report an IP even if we identified the host by hostname.
    Be lenient: exact match or substring either way."""
    if not line_addr or not host:
        return False
    return line_addr == host or line_addr in host or host in line_addr

def find_summary_rows(csv_lines, duration):
    """Return CSV rows that look like aggregate summaries (full-duration
    intervals). With -P > 1 iperf2 also emits per-stream lines plus a SUM
    line; we want the aggregates."""
    summaries = []
    for cols in csv_lines:
        if len(cols) < 9:
            continue
        interval = cols[6]
        # interval looks like "0.0000-10.0000" or "0.0-10.0"
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

def make_blank_row(pair_a, pair_b, src, dst, base, status, error="", header=None):
    h = header or {}
    return {
        "timestamp": "", "source": src, "target": dst, "status": status,
        "protocol": "TCP", "duration_s": h.get("duration", ""),
        "parallel_streams": h.get("parallel", ""),
        "bytes_transferred": "", "bps": "", "mbps": "",
        "src_port": "", "dst_port": "",
        "pair_a": pair_a, "pair_b": pair_b,
        "filename": base, "error": error,
    }

rows = []
for path in sorted(glob.glob(os.path.join(results_dir, "iperf_test_*.log"))):
    base = os.path.basename(path)

    try:
        with open(path) as f:
            raw = f.read()
    except Exception as e:
        rows.append(make_blank_row("", "", "", "", base, "READ_ERROR", f"{type(e).__name__}: {e}"))
        continue

    lines = raw.splitlines()
    header = {}
    csv_lines = []
    for line in lines:
        if line.startswith("#"):
            header.update(parse_header(line))
            continue
        if not line.strip():
            continue
        # iperf2 may emit error/info text that ends up in the log. Identify
        # real CSV rows by structure: enough fields and an interval like
        # "X.X-Y.Y" at index 6. Don't filter on cols[0].isdigit() -- iperf2
        # 2.1.9+ prefixes timestamps with a timezone offset like "+0000:".
        cols = line.split(",")
        if len(cols) >= 9 and "-" in cols[6]:
            try:
                start_s, end_s = cols[6].split("-", 1)
                float(start_s); float(end_s)
                csv_lines.append(cols)
            except ValueError:
                pass

    pair_a = header.get("pair_a", "")
    pair_b = header.get("pair_b", "")
    duration = header.get("duration", "10")
    try:
        listening_port = int(header.get("port", "5001"))
    except ValueError:
        listening_port = 5001

    if not pair_a or not pair_b:
        rows.append(make_blank_row(pair_a, pair_b, "", "", base, "NO_HEADER",
                                   "Log file is missing the # pair_a=... header"))
        continue

    # Look for any iperf error text in the body (no socket, refused, etc.)
    err_text = ""
    for line in lines:
        s = line.lower()
        if "error" in s or "failed" in s or "refused" in s:
            err_text = line.strip()[:200]
            break

    summaries = find_summary_rows(csv_lines, duration)
    if not summaries:
        rows.append(make_blank_row(pair_a, pair_b, pair_a, pair_b, base,
                                   "NO_SUMMARY",
                                   err_text or "No full-duration summary line found"))
        rows.append(make_blank_row(pair_a, pair_b, pair_b, pair_a, base,
                                   "NO_SUMMARY",
                                   err_text or "No full-duration summary line found"))
        continue

    # Direction detection. In --full-duplex CSV iperf2 emits, per
    # direction:
    #   -P 1:    one summary row.
    #   -P N>1:  N per-stream rows + one SUM row (transfer_id='-1',
    #            and src_port='SUM' in newer iperf2 builds).
    # The row whose source port equals the listening port is the
    # server-as-sender direction (pair_b -> pair_a); the other is
    # client-as-sender (pair_a -> pair_b).
    #
    # Algorithm:
    #   1. Group summaries by source address. Each group corresponds
    #      to one direction.
    #   2. From each group pick ONE aggregate row: the SUM row if
    #      present (-P > 1), otherwise the single per-stream row
    #      (-P 1), otherwise the row with the highest bps.
    #   3. Classify aggregates by source port == listening_port.
    #   4. For aggregates with a non-numeric src_port (SUM marker),
    #      fall back to EXACT pair_a/pair_b address match. Substring
    #      matching is intentionally NOT used here -- it gives false
    #      positives for IP prefixes (e.g. "10.0.0.1" is a substring
    #      of "10.0.0.10").
    def _is_sum_row(cols):
        # Newer iperf2: src_port is the literal "SUM" / "-1".
        # Either way, transfer_id == "-1" marks the aggregate.
        return cols[5] == "-1" or cols[2] in ("SUM", "-1")

    def _pick_aggregate(group):
        for r in group:
            if _is_sum_row(r):
                return r
        if len(group) == 1:
            return group[0]
        # Multiple per-stream rows without an explicit SUM marker:
        # the aggregate has bps >= any single stream's, so pick max.
        def _bps(r):
            try:
                return float(r[8])
            except (ValueError, IndexError):
                return 0.0
        return max(group, key=_bps)

    groups = {}
    for cols in summaries:
        groups.setdefault(cols[1], []).append(cols)
    aggregates = {addr: _pick_aggregate(rows) for addr, rows in groups.items()}

    listening_aggs = []   # source port == listening_port -> server-as-sender
    ephemeral_aggs = []   # source port != listening_port (but numeric)
    unknown_aggs   = []   # source port not numeric (SUM marker)
    for addr, agg in aggregates.items():
        sp = agg[2]
        if sp.isdigit():
            if int(sp) == listening_port:
                listening_aggs.append((addr, agg))
            else:
                ephemeral_aggs.append((addr, agg))
        else:
            unknown_aggs.append((addr, agg))

    a_to_b = None  # pair_a (client) -> pair_b (server)
    b_to_a = None  # pair_b (server) -> pair_a (client)

    # Best path: exactly 1 listening + 1 ephemeral, the standard layout.
    if len(listening_aggs) == 1:
        b_to_a = listening_aggs[0][1]
    if len(ephemeral_aggs) == 1:
        a_to_b = ephemeral_aggs[0][1]

    # Both directions ephemeral (some non-standard iperf2 builds):
    # disambiguate via exact pair_a/pair_b address match, then by
    # listed order. Substring matching is intentionally avoided here
    # because IP prefixes give false positives (e.g. "10.0.0.1" is a
    # substring of "10.0.0.10").
    if a_to_b is None and b_to_a is None and len(ephemeral_aggs) == 2:
        for addr, agg in ephemeral_aggs:
            if addr == pair_a and a_to_b is None:
                a_to_b = agg
            elif addr == pair_b and b_to_a is None:
                b_to_a = agg
        if a_to_b is None and b_to_a is None:
            a_to_b = ephemeral_aggs[0][1]
            b_to_a = ephemeral_aggs[1][1]

    # SUM-marker rows (port unknown): classify by exact address.
    for addr, agg in unknown_aggs:
        if addr == pair_a and a_to_b is None:
            a_to_b = agg
        elif addr == pair_b and b_to_a is None:
            b_to_a = agg

    # Final fallback: still both unset but we have ≥2 aggregates.
    # Assign positionally so the row count stays correct (caller still
    # sees both directions, even if labels could be swapped).
    if a_to_b is None and b_to_a is None and len(aggregates) >= 2:
        addrs = list(aggregates.keys())
        a_to_b = aggregates[addrs[0]]
        b_to_a = aggregates[addrs[1]]

    def emit(direction_cols, src, dst):
        if direction_cols is None:
            rows.append(make_blank_row(pair_a, pair_b, src, dst, base,
                                       "DIRECTION_MISSING",
                                       err_text or "iperf2 did not report this direction",
                                       header))
            return
        ts        = direction_cols[0]
        src_addr  = direction_cols[1]
        src_port  = direction_cols[2]
        dst_addr  = direction_cols[3]
        dst_port  = direction_cols[4]
        nbytes    = direction_cols[7]
        bps       = direction_cols[8]
        try:
            bps_f = float(bps)
            mbps = round(bps_f / 1e6, 3)
        except ValueError:
            bps_f, mbps = "", ""
        rows.append({
            "timestamp": ts, "source": src, "target": dst, "status": "OK",
            "protocol": "TCP",
            "duration_s": header.get("duration", ""),
            "parallel_streams": header.get("parallel", ""),
            "bytes_transferred": nbytes, "bps": bps_f, "mbps": mbps,
            "src_port": src_port, "dst_port": dst_port,
            "pair_a": pair_a, "pair_b": pair_b,
            "filename": base, "error": "",
        })

    emit(a_to_b, pair_a, pair_b)
    emit(b_to_a, pair_b, pair_a)

if not rows:
    print("No log files found", file=sys.stderr)
    sys.exit(1)

cols = ["timestamp","source","target","status","protocol","duration_s",
        "parallel_streams","bytes_transferred","bps","mbps",
        "src_port","dst_port","pair_a","pair_b","filename","error"]

with open(out_csv, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=cols)
    w.writeheader()
    w.writerows(rows)

ok = sum(1 for r in rows if r["status"] == "OK")
print(f"Wrote {len(rows)} rows ({ok} OK) from {len(set(r['filename'] for r in rows))} log files to {out_csv}")
PYEOF
    local rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    set_state CSV_BUILT yes
}

#------------------------------------------------------------------------------
# cmd_parse_cpu: parse cpu_<host>.log files into cpu_summary.csv
#
# Output columns per host:
#   host, n_cpus, peak_total_pct, mean_total_pct,
#   peak_softirq_pct, peak_softirq_cpu,
#   peak_sys_pct, peak_user_pct, peak_idle_floor_pct,
#   source ("mpstat" or "proc_stat" fallback)
#
# Reading these:
#   - peak_total_pct = max box-wide CPU usage during the test
#       (100 - %idle averaged across all cores at that sample)
#   - peak_softirq_pct = max softirq% on any single core during the test
#       (high values here usually mean RSS isn't spreading the NIC IRQs)
#   - peak_idle_floor_pct = lowest %idle on any single core
#       (a single-core saturation flag even when box-wide CPU looks fine)
#------------------------------------------------------------------------------
cmd_parse_cpu() {
    local cpu_csv="$RESULTS_DIR/cpu_summary.csv"
    log "Parsing CPU sample logs -> $cpu_csv"
    command -v "$PYTHON_BIN" >/dev/null || die "$PYTHON_BIN not found"

    local n_cpu_logs
    n_cpu_logs=$(ls "$RESULTS_DIR"/cpu_*.log 2>/dev/null | wc -l)
    if [ "$n_cpu_logs" -eq 0 ]; then
        warn "No cpu_*.log files in $RESULTS_DIR (was the test run with this version of the script?)"
        return 0
    fi

    "$PYTHON_BIN" - "$RESULTS_DIR" "$cpu_csv" <<'PYEOF'
import os, sys, csv, glob, re

results_dir, out_csv = sys.argv[1], sys.argv[2]

def parse_mpstat(path):
    """Parse `mpstat -P ALL 1 N` output. Returns dict of summary stats or
    None if the file doesn't look like mpstat output."""
    with open(path) as f:
        lines = f.readlines()

    # Detect the column layout from the first header line we find.
    header = None
    for line in lines:
        # Header has "CPU" and "%idle"
        if re.search(r'\bCPU\b', line) and '%idle' in line:
            header = line.split()
            break
    if not header:
        return None

    # Map column name -> index in the data rows. The first column is the
    # timestamp, the second is "CPU", then the metric columns. Header
    # tokens after "CPU" line up with the metric columns of the data row
    # *starting from the third token* (timestamp + CPU + metrics).
    #
    # Example header tokens: ['Time', 'CPU', '%usr', '%nice', '%sys',
    #                         '%iowait', '%irq', '%soft', '%steal',
    #                         '%guest', '%gnice', '%idle']
    metric_names = header[2:]
    def col_index(name):
        try:
            return 2 + metric_names.index(name)
        except ValueError:
            return None

    idx_idle = col_index('%idle')
    idx_soft = col_index('%soft')
    idx_sys  = col_index('%sys')
    idx_usr  = col_index('%usr')
    if idx_idle is None:
        return None

    # Walk the file sample by sample. A sample = one block of lines that
    # starts with a header line and is followed by "all" + per-core rows
    # for the same timestamp.
    samples = []   # list of (timestamp, {cpu_id: {col: float}})
    current_ts = None
    current_rows = {}
    seen_cpus = set()

    def flush_sample():
        if current_ts is not None and current_rows:
            samples.append((current_ts, dict(current_rows)))

    for line in lines:
        s = line.strip()
        if not s:
            continue
        # Skip the global "Linux ..." banner and the trailing "Average:" block
        if s.startswith('Linux '):
            continue
        if s.startswith('Average:'):
            break

        toks = line.split()
        if len(toks) < len(header):
            continue

        # Header row repeats per sample -- detect by seeing '%idle' in toks
        if '%idle' in toks:
            flush_sample()
            current_ts = toks[0]
            current_rows = {}
            continue

        cpu_label = toks[1]
        try:
            metrics = {name: float(toks[2 + i]) for i, name in enumerate(metric_names)}
        except (ValueError, IndexError):
            continue

        # We track the timestamp from the data row in case the header
        # format ever changes.
        if current_ts is None:
            current_ts = toks[0]
        current_rows[cpu_label] = metrics
        if cpu_label != 'all':
            seen_cpus.add(cpu_label)

    flush_sample()

    if not samples:
        return None

    n_cpus = len(seen_cpus) if seen_cpus else 1

    # Compute summaries
    total_pcts = []
    peak_softirq = 0.0
    peak_softirq_cpu = ""
    peak_sys = 0.0
    peak_user = 0.0
    lowest_idle_per_core = 100.0
    saw_percore = False  # only emit per-core metrics if we actually saw per-core rows

    for ts, rows in samples:
        all_row = rows.get('all')
        if all_row:
            total_pcts.append(100.0 - all_row.get('%idle', 100.0))
            peak_sys = max(peak_sys, all_row.get('%sys', 0.0))
            peak_user = max(peak_user, all_row.get('%usr', 0.0))

        # Per-core checks
        for cpu_label, metrics in rows.items():
            if cpu_label == 'all':
                continue
            saw_percore = True
            soft = metrics.get('%soft', 0.0)
            if soft > peak_softirq:
                peak_softirq = soft
                peak_softirq_cpu = cpu_label
            idle = metrics.get('%idle', 100.0)
            if idle < lowest_idle_per_core:
                lowest_idle_per_core = idle

    peak_total = max(total_pcts) if total_pcts else 0.0
    mean_total = sum(total_pcts) / len(total_pcts) if total_pcts else 0.0

    return {
        "n_cpus": n_cpus,
        "peak_total_pct":   round(peak_total, 2),
        "mean_total_pct":   round(mean_total, 2),
        # Leave per-core fields blank when no per-core rows were seen,
        # so they aren't misread as "softirq=0, idle floor=100" when in
        # reality the data wasn't measured.
        "peak_softirq_pct":     round(peak_softirq, 2)         if saw_percore else "",
        "peak_softirq_cpu":     peak_softirq_cpu               if saw_percore else "",
        "peak_sys_pct":         round(peak_sys, 2),
        "peak_user_pct":        round(peak_user, 2),
        "peak_idle_floor_pct":  round(lowest_idle_per_core, 2) if saw_percore else "",
        "source": "mpstat",
    }

def parse_proc_stat_fallback(path):
    """Parse the /proc/stat fallback. Each sample is a date line + the
    'cpu  ...' aggregate line. We compute deltas between samples. No
    per-core data, so per-core fields stay blank."""
    with open(path) as f:
        text = f.read()

    if "fallback=proc_stat" not in text:
        return None

    cpu_lines = [l for l in text.splitlines() if l.startswith("cpu ")]
    if len(cpu_lines) < 2:
        return None

    # /proc/stat fields after "cpu": user nice system idle iowait irq
    # softirq steal guest guest_nice
    samples = []
    for line in cpu_lines:
        parts = line.split()
        try:
            vals = [int(x) for x in parts[1:]]
        except ValueError:
            continue
        # Pad to 10 if older kernel
        while len(vals) < 10:
            vals.append(0)
        samples.append(vals)

    total_pcts = []
    peak_sys = 0.0
    peak_user = 0.0
    for prev, cur in zip(samples, samples[1:]):
        diff = [c - p for c, p in zip(cur, prev)]
        total = sum(diff)
        if total <= 0:
            continue
        idle = diff[3]
        sys_t = diff[2]
        user = diff[0]
        total_pcts.append(100.0 * (total - idle) / total)
        peak_sys = max(peak_sys, 100.0 * sys_t / total)
        peak_user = max(peak_user, 100.0 * user / total)

    if not total_pcts:
        return None

    return {
        "n_cpus": "",
        "peak_total_pct":   round(max(total_pcts), 2),
        "mean_total_pct":   round(sum(total_pcts) / len(total_pcts), 2),
        "peak_softirq_pct": "",
        "peak_softirq_cpu": "",
        "peak_sys_pct":     round(peak_sys, 2),
        "peak_user_pct":    round(peak_user, 2),
        "peak_idle_floor_pct": "",
        "source": "proc_stat",
    }

cols = ["host","source","n_cpus","peak_total_pct","mean_total_pct",
        "peak_softirq_pct","peak_softirq_cpu","peak_sys_pct","peak_user_pct",
        "peak_idle_floor_pct","filename"]

rows = []
for path in sorted(glob.glob(os.path.join(results_dir, "cpu_*.log"))):
    base = os.path.basename(path)
    # cpu_<host>.log
    host = base[len("cpu_"):-len(".log")]

    summary = parse_mpstat(path) or parse_proc_stat_fallback(path)
    if summary is None:
        rows.append({c: "" for c in cols})
        rows[-1].update({"host": host, "source": "PARSE_ERROR", "filename": base})
        continue
    summary["host"] = host
    summary["filename"] = base
    rows.append(summary)

with open(out_csv, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=cols)
    w.writeheader()
    w.writerows(rows)

print(f"Wrote {len(rows)} host CPU summaries to {out_csv}")

# Also print a quick textual summary, sorted by peak total pct desc.
ranked = sorted(
    [r for r in rows if isinstance(r.get("peak_total_pct"), (int, float))],
    key=lambda r: r["peak_total_pct"], reverse=True
)
if ranked:
    print()
    print(f"{'host':<25} {'src':<10} {'cpus':>5} {'peak%':>7} {'mean%':>7} "
          f"{'peakSoft%':>9} {'peakSys%':>9} {'minIdle%':>9}")
    for r in ranked:
        print(f"{r['host']:<25} {r['source']:<10} {str(r['n_cpus']):>5} "
              f"{r['peak_total_pct']:>7} {r['mean_total_pct']:>7} "
              f"{str(r['peak_softirq_pct']):>9} {str(r['peak_sys_pct']):>9} "
              f"{str(r['peak_idle_floor_pct']):>9}")
PYEOF
    local rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    set_state CPU_PARSED yes
}

#------------------------------------------------------------------------------
cmd_make_pivot() {
    local csv="$RESULTS_DIR/iperf_results.csv"
    local pivot="$RESULTS_DIR/iperf_pivot.txt"
    [ -f "$csv" ] || die "No CSV; run: $0 parse-csv"
    log "Building pivot table -> $pivot"

    "$PYTHON_BIN" - "$csv" "$pivot" <<'PYEOF'
import csv, sys
from collections import defaultdict

in_csv, out_txt = sys.argv[1], sys.argv[2]

mat = defaultdict(dict)   # mat[src][dst] = mbps
sources, targets = set(), set()

with open(in_csv) as f:
    for row in csv.DictReader(f):
        s, t = row["source"], row["target"]
        sources.add(s); targets.add(t)
        v = row.get("mbps") or ""
        try:
            mat[s][t] = float(v) if v != "" else None
        except ValueError:
            mat[s][t] = None

# Use the union, sorted, so rows and columns line up regardless of which
# side a host appeared on.
all_hosts = sorted(sources | targets)
src_list = all_hosts
dst_list = all_hosts

# Column width: enough for the longest hostname or a number like "9999.99"
host_w = max([8] + [len(h) for h in all_hosts])
num_w  = max(host_w, 9)

def fmt_num(v):
    if v is None:
        return "-".rjust(num_w)
    return f"{v:>{num_w}.2f}"

with open(out_txt, "w") as f:
    f.write(f"iperf2 full-duplex mesh throughput (Mbps)\n")
    f.write(f"Rows = source (sender), Columns = target (receiver)\n")
    f.write(f"Each cell from a single full-duplex test that measured both directions concurrently.\n")
    f.write(f"Diagonal '-' = no self-test\n\n")

    # Header
    f.write(" " * host_w + " | ")
    f.write(" ".join(h.rjust(num_w) for h in dst_list))
    f.write("\n")
    # Separator
    f.write("-" * host_w + "-+-")
    f.write("-" * (len(dst_list) * (num_w + 1) - 1))
    f.write("\n")

    row_means = {}
    for s in src_list:
        f.write(s.ljust(host_w) + " | ")
        vals = []
        for d in dst_list:
            if s == d:
                f.write("-".rjust(num_w) + " ")
            else:
                v = mat.get(s, {}).get(d)
                f.write(fmt_num(v) + " ")
                if v is not None:
                    vals.append(v)
        if vals:
            row_means[s] = sum(vals) / len(vals)
        f.write("\n")

    f.write("\nPer-source mean outgoing Mbps (sorted high to low):\n")
    for h, m in sorted(row_means.items(), key=lambda kv: kv[1], reverse=True):
        bar = "#" * int(m / max(row_means.values()) * 40) if row_means else ""
        f.write(f"  {h.ljust(host_w)} {m:9.2f}  {bar}\n")

print(f"Wrote {out_txt}")
PYEOF
    local rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    set_state PIVOT_BUILT yes
}

#------------------------------------------------------------------------------
cmd_make_heatmap() {
    local csv="$RESULTS_DIR/iperf_results.csv"
    local cpu_csv="$RESULTS_DIR/cpu_summary.csv"
    local png="$RESULTS_DIR/iperf_heatmap.png"
    [ -f "$csv" ] || die "No CSV; run: $0 parse-csv"
    log "Rendering heatmap + bar chart -> $png"

    "$PYTHON_BIN" - "$csv" "$png" "$cpu_csv" <<'PYEOF'
import csv, sys, os
from collections import defaultdict

in_csv, out_png = sys.argv[1], sys.argv[2]
cpu_csv = sys.argv[3] if len(sys.argv) > 3 else ""

# Load CPU peaks per host if cpu_summary.csv is available. Used to overlay
# "peak X%" annotations on the bar chart.
cpu_peaks = {}
if cpu_csv and os.path.exists(cpu_csv):
    try:
        with open(cpu_csv) as f:
            for row in csv.DictReader(f):
                v = row.get("peak_total_pct", "")
                if v == "" or v is None:
                    continue
                try:
                    cpu_peaks[row["host"]] = float(v)
                except ValueError:
                    pass
    except Exception:
        pass

try:
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.gridspec import GridSpec
    from matplotlib.colors import LinearSegmentedColormap
except ImportError as e:
    print(f"Missing Python package: {e}. Install with: pip install matplotlib numpy", file=sys.stderr)
    sys.exit(2)

mat = defaultdict(dict)
sources, targets = set(), set()
with open(in_csv) as f:
    for row in csv.DictReader(f):
        s, t = row["source"], row["target"]
        sources.add(s); targets.add(t)
        v = row.get("mbps") or ""
        try:
            mat[s][t] = float(v) if v != "" else None
        except ValueError:
            mat[s][t] = None

hosts = sorted(sources | targets)
n = len(hosts)
if n == 0:
    print("No data to plot", file=sys.stderr); sys.exit(1)

# Build numeric matrix; diagonal = NaN (no self-test)
M = np.full((n, n), np.nan)
for i, s in enumerate(hosts):
    for j, t in enumerate(hosts):
        if i == j:
            continue
        v = mat.get(s, {}).get(t)
        if v is not None:
            M[i, j] = v

# Per-source mean (ignoring NaN). Used both for sorting the bar chart
# and for coloring the bars on the same scale as the heatmap.
import warnings
with warnings.catch_warnings():
    warnings.simplefilter("ignore", category=RuntimeWarning)
    src_means = np.nanmean(M, axis=1)

# Red -> Yellow -> Green, low to high
cmap = LinearSegmentedColormap.from_list(
    "ryg", ["#c0392b", "#f1c40f", "#27ae60"]
)
cmap.set_bad(color="#dddddd")  # diagonals / missing

vmin = float(np.nanmin(M))
vmax = float(np.nanmax(M))
if vmin == vmax:
    vmax = vmin + 1.0   # avoid degenerate scale

# Layout/style adapts to mesh size. The heatmap is rendered at any N, but
# we degrade visual elements that stop being useful past certain thresholds:
#   - cell value annotations: drop above N=30 (too small to read)
#   - axis tick labels: thin out above N=60 (too crammed)
#   - figure size: capped so the PNG stays a sane size at huge N
annotate_cells   = n <= 30
heat_label_every = 1 if n <= 60 else max(1, n // 30)
heat_fontsize    = 10 if n <= 30 else (8 if n <= 60 else 6)
bar_label_every  = 1 if n <= 60 else max(1, n // 30)
bar_value_labels = n <= 50

fig_w = min(36, max(8, 0.55 * n + 4))
fig_h = min(32, max(8, 0.5  * n + 5))
hspace = 0.65 if n <= 30 else (0.4 if n <= 60 else 0.25)

fig = plt.figure(figsize=(fig_w, fig_h))
gs = GridSpec(2, 2, height_ratios=[3, 2], width_ratios=[40, 1],
              hspace=hspace, wspace=0.05)

ax_heat = fig.add_subplot(gs[0, 0])
ax_cbar = fig.add_subplot(gs[0, 1])
ax_bar  = fig.add_subplot(gs[1, 0])

# --- Heatmap ---
im = ax_heat.imshow(M, cmap=cmap, vmin=vmin, vmax=vmax, aspect="auto")

if heat_label_every == 1:
    tick_pos = list(range(n))
    tick_lab = hosts
else:
    tick_pos = list(range(0, n, heat_label_every))
    tick_lab = [hosts[i] for i in tick_pos]
ax_heat.set_xticks(tick_pos)
ax_heat.set_yticks(tick_pos)
ax_heat.set_xticklabels(tick_lab, rotation=45, ha="right", fontsize=heat_fontsize)
ax_heat.set_yticklabels(tick_lab, fontsize=heat_fontsize)
ax_heat.set_xlabel("Target (receiver direction)")
ax_heat.set_ylabel("Source (sender direction)")
sub = "" if annotate_cells else f"  (cell labels suppressed for readability at N={n})"
ax_heat.set_title(f"iperf2 full-duplex mesh throughput (Mbps)  —  {n}×{n} hosts{sub}")

if annotate_cells:
    for i in range(n):
        for j in range(n):
            if i == j or np.isnan(M[i, j]):
                ax_heat.text(j, i, "—", ha="center", va="center",
                             color="#666", fontsize=8)
            else:
                v = M[i, j]
                norm = (v - vmin) / (vmax - vmin)
                txt_color = "white" if (norm < 0.25 or norm > 0.75) else "black"
                ax_heat.text(j, i, f"{v:.0f}", ha="center", va="center",
                             color=txt_color, fontsize=8)

fig.colorbar(im, cax=ax_cbar, label="Mbps")

# --- Bar chart, sorted high to low, same colormap ---
order = np.argsort(-np.nan_to_num(src_means, nan=-np.inf))
ordered_hosts  = [hosts[i] for i in order]
ordered_means  = src_means[order]

# Drop hosts with no data (all-NaN sources)
keep = ~np.isnan(ordered_means)
ordered_hosts = [h for h, k in zip(ordered_hosts, keep) if k]
ordered_means = ordered_means[keep]

bar_colors = cmap((ordered_means - vmin) / (vmax - vmin))
xs = np.arange(len(ordered_hosts))
ax_bar.bar(xs, ordered_means, color=bar_colors, edgecolor="black", linewidth=0.5)

if bar_label_every == 1:
    ax_bar.set_xticks(xs)
    ax_bar.set_xticklabels(ordered_hosts, rotation=45, ha="right",
                           fontsize=heat_fontsize)
else:
    bar_tick_pos = list(range(0, len(ordered_hosts), bar_label_every))
    bar_tick_lab = [ordered_hosts[i] for i in bar_tick_pos]
    ax_bar.set_xticks(bar_tick_pos)
    ax_bar.set_xticklabels(bar_tick_lab, rotation=45, ha="right",
                           fontsize=heat_fontsize)

ax_bar.set_ylabel("Mean outgoing Mbps")
ax_bar.grid(axis="y", linestyle=":", alpha=0.5)

# Add headroom above the tallest bar so the value labels (and CPU annotation
# when present) don't collide with the chart title.
if bar_value_labels and len(ordered_means) > 0:
    headroom = 1.18 if cpu_peaks else 1.10
    ax_bar.set_ylim(0, max(ordered_means) * headroom)

if bar_value_labels:
    for x, v, h in zip(xs, ordered_means, ordered_hosts):
        cpu = cpu_peaks.get(h)
        if cpu is not None:
            label = f"{v:.0f}\n{cpu:.0f}% CPU"
        else:
            label = f"{v:.0f}"
        ax_bar.text(x, v, label, ha="center", va="bottom", fontsize=8)

# Bar chart subtitle hint when CPU data is present
if cpu_peaks:
    ax_bar.set_title("Hosts ranked by mean outgoing throughput "
                     "(high → low; second number = peak %CPU during test)",
                     pad=10)
else:
    ax_bar.set_title("Hosts ranked by mean outgoing throughput (high → low)",
                     pad=10)

# Empty axis below the colorbar to keep alignment clean
ax_bar_cbar = fig.add_subplot(gs[1, 1])
ax_bar_cbar.axis("off")

plt.savefig(out_png, dpi=150, bbox_inches="tight")
print(f"Wrote {out_png}")
PYEOF
    local rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    set_state HEATMAP_BUILT yes
}

#------------------------------------------------------------------------------
cmd_all() {
    local mode="${1:-parallel}"
    log "=== Running full pipeline (run-tests mode: $mode) ==="
    [ "$(get_state SSH_KEYS_DISTRIBUTED)" = "yes" ] || cmd_ssh_setup
    cmd_check_iperf
    cmd_check_servers
    cmd_start_servers
    cmd_create_scripts
    cmd_distribute_scripts
    cmd_run_tests "$mode"
    cmd_collect_results
    cmd_stop_servers
    cmd_cleanup
    cmd_parse_csv
    cmd_parse_cpu
    cmd_make_pivot
    cmd_make_heatmap
    log "=== Pipeline complete ==="
    echo
    echo "Results in: $RESULTS_DIR"
    ls -1 "$RESULTS_DIR" | sed 's/^/  /'
}

#==============================================================================
# Dispatcher
#==============================================================================
cmd="${1:-help}"
shift || true

case "$cmd" in
    init)               cmd_init "$@" ;;
    status)             cmd_status ;;
    ssh-setup)          cmd_ssh_setup ;;
    check-iperf)        cmd_check_iperf ;;
    check-servers)      cmd_check_servers ;;
    start-servers)      cmd_start_servers ;;
    create-scripts)     cmd_create_scripts ;;
    distribute-scripts) cmd_distribute_scripts ;;
    run-tests)          cmd_run_tests "$@" ;;
    collect-results)    cmd_collect_results ;;
    stop-servers)       cmd_stop_servers ;;
    cleanup)            cmd_cleanup ;;
    parse-csv)          cmd_parse_csv ;;
    parse-cpu)          cmd_parse_cpu ;;
    make-pivot)         cmd_make_pivot ;;
    make-heatmap)       cmd_make_heatmap ;;
    all)                cmd_all "$@" ;;
    help|-h|--help|"")  usage ;;
    *)                  err "Unknown command: $cmd"; usage; exit 2 ;;
esac
