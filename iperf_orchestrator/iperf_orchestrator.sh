#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
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
# Every host runs iperf -c against every other host (one unidirectional
# iperf2 invocation per directed edge). Both directions of each pair are
# measured by running both endpoints' client invocations simultaneously;
# each log file carries exactly one direction's bytes, which keeps the
# CSV parsing unambiguous regardless of iperf2 build or -P value.
#
# Why iperf2 and not iperf3:
#   iperf3's server is single-threaded and accepts one client at a time, so
#   a full mesh of N hosts would need N iperf3 servers per host on different
#   ports. iperf2's server is multi-threaded and handles concurrent clients
#   on a single port, so we run one daemon per host on port 5001 and we're
#   done. We deliberately don't use iperf2's --full-duplex: its -y C output
#   labels per-direction vs SUM rows inconsistently across versions and -P
#   values, which made cell values unreliable. Running unidirectional pairs
#   gives us unambiguous per-direction byte counts in every log file.
# Results are gathered, parsed into CSV, pivoted, and rendered as a
# heatmap + bar chart on a single image.
#
# Quick start (key-based SSH to every host must already be configured):
#   ./iperf-orchestrator.sh --servers servers.txt all
#
# The script is stateless: nothing is persisted between invocations except
# the contents of the results directory. `status` derives state by probing
# hosts live, not from a state file.
#==============================================================================

set -u
# Note: -e is intentionally NOT set; we handle per-host failures explicitly
# so one bad host doesn't abort the whole run.

#------------------------------------------------------------------------------
# Path resolution: results live under <script-dir>/results/<run-id>/ by
# default. --output overrides the base, --run-id selects an existing run.
#------------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Program name shown in help/usage text. The pip console-script wrapper sets
# IPERF_ORCH_PROG=iperf-orchestrator so help reads cleanly; direct invocation
# falls back to $0 (the path the script was run as), unchanged.
PROG="${IPERF_ORCH_PROG:-$0}"

# Reported by --version / the version subcommand. Keep in sync with the
# version in pyproject.toml and iperf_orchestrator/__init__.py.
ORCH_VERSION="1.0.0"

#------------------------------------------------------------------------------
# Configuration (override via env vars; CLI flags below win over env vars)
#------------------------------------------------------------------------------
RESULTS_BASE="${RESULTS_BASE:-$SCRIPT_DIR/results}"
SERVER_LIST_FILE="${IPERF_SERVERS:-}"   # set by --servers, env var, or default lookup
RUN_ID="${IPERF_RUN_ID:-}"              # set by --run-id / IPERF_RUN_ID; auto-generated for create-scripts
_RUN_ID_EXPLICIT=0                      # 1 when the user asked for a specific run-id; otherwise follow 'latest'
[ -n "$RUN_ID" ] && _RUN_ID_EXPLICIT=1
REMOTE_DIR="${REMOTE_DIR:-/tmp/iperf_orchestrator}"

IPERF_PORT="${IPERF_PORT:-5001}"
IPERF_DURATION="${IPERF_DURATION:-10}"     # seconds per pair
IPERF_TOTAL_TIME="${IPERF_TOTAL_TIME:-300}"  # 'rolling' mode wall-time
IPERF_HOST_FLOWS="${IPERF_HOST_FLOWS:-1}"              # 'rolling' mode per-host concurrency

# iperf2 performance knobs forwarded to every iperf -c invocation.
# Empty = use iperf2's default; otherwise passed through verbatim.
IPERF_BANDWIDTH="${IPERF_BANDWIDTH:-}"   # -b: target rate (e.g. 100M, 1G)
IPERF_LENGTH="${IPERF_LENGTH:-}"         # -l: TCP read/write buffer (e.g. 128K)
IPERF_WINDOW="${IPERF_WINDOW:-}"         # -w: TCP window / socket buffer (e.g. 4M)
IPERF_MSS="${IPERF_MSS:-}"               # -M: TCP maximum segment size
IPERF_NO_NAGLE="${IPERF_NO_NAGLE:-0}"    # -N: disable Nagle's algorithm (1=on)
IPERF_BIND="${IPERF_BIND:-}"             # -B value. Treated as a substring search
                                         # against `ip -o -4 addr show` on each
                                         # remote host. The first matching iface's
                                         # IPv4 address is (a) passed to iperf -c -B
                                         # to bind the source side, and (b) used as
                                         # the iperf -c destination so traffic
                                         # actually rides the bound NIC even when
                                         # the SSH/login IP lives on a different
                                         # interface. Examples: "eth0", "bond",
                                         # "10.0.0", "mlx5".
IPERF_SERVER_BIND="${IPERF_SERVER_BIND:-}" # Same pattern as IPERF_BIND, but for the
                                         # daemon side: passes -B <ip> to iperf -s
                                         # so the server only accepts on that iface.
                                         # Defaults to IPERF_BIND when unset.
IPERF_STREAMS="${IPERF_STREAMS:-1}"      # parallel streams per test
# --ssh-jobs default: derived from $(nproc) so a 64-core orchestrator host
# can fan out further than a 4-core laptop. Capped at 32 to avoid
# overwhelming SSH on huge fleets without an explicit opt-in. Override
# via env var or --ssh-jobs.
_default_jobs() {
    local n
    n=$(getconf _NPROCESSORS_ONLN 2>/dev/null \
        || nproc 2>/dev/null \
        || sysctl -n hw.ncpu 2>/dev/null \
        || echo 4)
    case "$n" in ''|*[!0-9]*) n=4 ;; esac
    local d=$((n * 4))
    [ "$d" -lt 4 ]  && d=4
    [ "$d" -gt 32 ] && d=32
    echo "$d"
}
IPERF_SSH_JOBS="${IPERF_SSH_JOBS:-$(_default_jobs)}"  # max concurrent SSH/SCP fan-out

SSH_USER="${SSH_USER:-${USER:-$(id -un)}}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=30}"
# Used when we want commands that require an existing key (no password prompts):
SSH_BATCH_OPTS="$SSH_OPTS -o BatchMode=yes"

# Verbosity: 0 = quiet (errors and warnings only),
#            1 = normal (default),
#            2 = verbose (also prints every ssh/scp invocation).
# --dry-run prints SSH/SCP commands without running them.
IPERF_VERBOSITY="${IPERF_VERBOSITY:-1}"
IPERF_DRY_RUN="${IPERF_DRY_RUN:-0}"

START_DELAY="${START_DELAY:-30}"           # seconds in future for synchronized start

PYTHON_BIN="${PYTHON_BIN:-python3}"

#------------------------------------------------------------------------------
# CLI flag pre-pass
#
# Recognizes GLOBAL flags anywhere on the command line and accumulates the
# remaining positionals (subcommand + its args + any subcommand-specific
# flags) into _PARSED, preserving order. So all of these are equivalent:
#
#     orch --streams 4 run-tests rolling
#     orch run-tests --streams 4 rolling
#     orch run-tests rolling --streams 4
#
# Anything after a literal `--` is forwarded verbatim, even if flag-shaped.
# Both `--key value` and `--key=value` forms are accepted.
#------------------------------------------------------------------------------
_flag_die() { echo "iperf-orchestrator: $*" >&2; exit 2; }
_flag_need() { [ -n "${2:-}" ] || _flag_die "flag $1 requires a value"; }

# `matrix` is a pass-through to the sustained-load fleet driver
# (matrix_agent/fleet.sh), which has its own flag namespace (--matrix,
# --jobs, ...) that must not be filtered through this script's global
# flag parser. Dispatch it before the parsing loop, and only when it is
# the first argument so flag handling for every other command is
# untouched. Source checkouts only: the pip wheel ships just this script.
if [ "${1:-}" = "matrix" ]; then
    shift
    # Candidate locations: a source checkout / expanded bundle (sibling
    # matrix_agent/ dir), or matrix_agent/ dropped next to this script --
    # the latter lets a pip install opt in by copying one directory.
    _fleet=""
    for _cand in "$SCRIPT_DIR/../matrix_agent/fleet.sh" \
                 "$SCRIPT_DIR/matrix_agent/fleet.sh"; do
        if [ -f "$_cand" ]; then _fleet="$_cand"; break; fi
    done
    if [ -z "$_fleet" ]; then
        echo "$PROG: matrix tooling (matrix_agent/fleet.sh) not found; looked in:" >&2
        echo "    $SCRIPT_DIR/../matrix_agent/" >&2
        echo "    $SCRIPT_DIR/matrix_agent/" >&2
        echo "  A pip install ships only the orchestrator. Run from a source checkout" >&2
        echo "  or an expanded bundle, or copy the matrix_agent/ directory next to" >&2
        echo "  this script. See matrix_agent/README.md." >&2
        exit 1
    fi
    # Exec via bash, not directly: some transports and bundle splitters
    # drop file modes, and a lost executable bit must not break this.
    exec bash "$_fleet" "$@"
fi

_PARSED=()
_saw_subcommand=0
while [ $# -gt 0 ]; do
    case "$1" in
        --port)          _flag_need "$1" "${2:-}"; IPERF_PORT="$2"; shift 2 ;;
        --port=*)        IPERF_PORT="${1#*=}"; shift ;;
        --duration|-d)   _flag_need "$1" "${2:-}"; IPERF_DURATION="$2"; shift 2 ;;
        --duration=*)    IPERF_DURATION="${1#*=}"; shift ;;
        --streams|-P)    _flag_need "$1" "${2:-}"; IPERF_STREAMS="$2"; shift 2 ;;
        --streams=*)     IPERF_STREAMS="${1#*=}"; shift ;;
        --ssh-jobs|-j)   _flag_need "$1" "${2:-}"; IPERF_SSH_JOBS="$2"; shift 2 ;;
        --ssh-jobs=*)    IPERF_SSH_JOBS="${1#*=}"; shift ;;
        --start-delay)   _flag_need "$1" "${2:-}"; START_DELAY="$2"; shift 2 ;;
        --start-delay=*) START_DELAY="${1#*=}"; shift ;;
        --total-time)    _flag_need "$1" "${2:-}"; IPERF_TOTAL_TIME="$2"; shift 2 ;;
        --total-time=*)  IPERF_TOTAL_TIME="${1#*=}"; shift ;;
        --host-flows)    _flag_need "$1" "${2:-}"; IPERF_HOST_FLOWS="$2"; shift 2 ;;
        --host-flows=*)  IPERF_HOST_FLOWS="${1#*=}"; shift ;;
        --bandwidth|-b)  _flag_need "$1" "${2:-}"; IPERF_BANDWIDTH="$2"; shift 2 ;;
        --bandwidth=*)   IPERF_BANDWIDTH="${1#*=}"; shift ;;
        --length|-l)     _flag_need "$1" "${2:-}"; IPERF_LENGTH="$2"; shift 2 ;;
        --length=*)      IPERF_LENGTH="${1#*=}"; shift ;;
        --window|-w)     _flag_need "$1" "${2:-}"; IPERF_WINDOW="$2"; shift 2 ;;
        --window=*)      IPERF_WINDOW="${1#*=}"; shift ;;
        --mss|-M)        _flag_need "$1" "${2:-}"; IPERF_MSS="$2"; shift 2 ;;
        --mss=*)         IPERF_MSS="${1#*=}"; shift ;;
        --no-nagle|-N)   IPERF_NO_NAGLE=1; shift ;;
        --bind|-B)       _flag_need "$1" "${2:-}"; IPERF_BIND="$2"; shift 2 ;;
        --bind=*)        IPERF_BIND="${1#*=}"; shift ;;
        --server-bind)   _flag_need "$1" "${2:-}"; IPERF_SERVER_BIND="$2"; shift 2 ;;
        --server-bind=*) IPERF_SERVER_BIND="${1#*=}"; shift ;;
        --ssh-user|-u)   _flag_need "$1" "${2:-}"; SSH_USER="$2"; shift 2 ;;
        --ssh-user=*)    SSH_USER="${1#*=}"; shift ;;
        --output|-o)     _flag_need "$1" "${2:-}"; RESULTS_BASE="$2"; shift 2 ;;
        --output=*)      RESULTS_BASE="${1#*=}"; shift ;;
        -o=*)            RESULTS_BASE="${1#*=}"; shift ;;
        --run-id)        _flag_need "$1" "${2:-}"; RUN_ID="$2"; _RUN_ID_EXPLICIT=1; shift 2 ;;
        --run-id=*)      RUN_ID="${1#*=}"; _RUN_ID_EXPLICIT=1; shift ;;
        --servers|-s)    _flag_need "$1" "${2:-}"; SERVER_LIST_FILE="$2"; shift 2 ;;
        --servers=*)     SERVER_LIST_FILE="${1#*=}"; shift ;;
        -s=*)            SERVER_LIST_FILE="${1#*=}"; shift ;;
        --remote-dir)    _flag_need "$1" "${2:-}"; REMOTE_DIR="$2"; shift 2 ;;
        --remote-dir=*)  REMOTE_DIR="${1#*=}"; shift ;;
        --python)        _flag_need "$1" "${2:-}"; PYTHON_BIN="$2"; shift 2 ;;
        --python=*)      PYTHON_BIN="${1#*=}"; shift ;;
        --dry-run|-n)      IPERF_DRY_RUN=1; shift ;;
        --verbose|-v)      IPERF_VERBOSITY=2; shift ;;
        --quiet|-q)        IPERF_VERBOSITY=0; shift ;;
        --)              shift; _PARSED+=("$@"); break ;;
        -h|--help)       _PARSED+=("help"); shift ;;
        --help-advanced) _PARSED+=("help-advanced"); shift ;;
        --version)       _PARSED+=("version"); shift ;;
        # Unknown flags before any subcommand are treated as typos and
        # rejected at the top level. Once a subcommand has been seen,
        # unknown flags get forwarded so subcommand-specific flags
        # (`cleanup --yes`, etc.) survive.
        --*|-?*)
            if [ "$_saw_subcommand" = "1" ]; then
                _PARSED+=("$1"); shift
            else
                _flag_die "unknown flag: $1"
            fi
            ;;
        *)               _PARSED+=("$1"); _saw_subcommand=1; shift ;;
    esac
done
set -- "${_PARSED[@]}"
unset _PARSED _saw_subcommand

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
_validate_uint "IPERF_SSH_JOBS / --ssh-jobs"           "$IPERF_SSH_JOBS"     1
_validate_uint "IPERF_PORT / --port"           "$IPERF_PORT"     1
_validate_uint "IPERF_DURATION / --duration"   "$IPERF_DURATION" 1
_validate_uint "IPERF_STREAMS / --streams"   "$IPERF_STREAMS" 1
_validate_uint "START_DELAY / --start-delay"   "$START_DELAY"    0
_validate_uint "IPERF_TOTAL_TIME / --total-time" "$IPERF_TOTAL_TIME" 1
_validate_uint "IPERF_HOST_FLOWS / --host-flows"           "$IPERF_HOST_FLOWS"      1
_validate_uint "IPERF_VERBOSITY"               "$IPERF_VERBOSITY" 0
[ "$IPERF_VERBOSITY" -le 2 ] || _flag_die "IPERF_VERBOSITY must be 0, 1, or 2 (got $IPERF_VERBOSITY)"
# Sanity-warn (don't die) on suspicious --ssh-jobs values. Past ~256 you're
# likely about to OOM the orchestrator host or saturate its FD table.
if [ "$IPERF_SSH_JOBS" -gt 256 ]; then
    echo "iperf-orchestrator: WARN: --ssh-jobs=$IPERF_SSH_JOBS is unusually high; ssh fan-out may exhaust file descriptors" >&2
fi
[ "$IPERF_PORT" -le 65535 ] || _flag_die "IPERF_PORT / --port must be <= 65535 (got $IPERF_PORT)"

# Split-NIC fleets: if --bind is set but --server-bind is not, mirror
# --bind to the server side so the daemon only accepts on the data-plane
# NIC. Otherwise a misrouted client connection would land on a daemon
# happily listening on 0.0.0.0 and we'd quietly measure the wrong NIC.
# Users who explicitly want a 0.0.0.0 listener with a bound client can
# still set --server-bind='' to opt out.
if [ -n "$IPERF_BIND" ] && [ -z "$IPERF_SERVER_BIND" ]; then
    IPERF_SERVER_BIND="$IPERF_BIND"
fi

# Build the optional iperf2 client-arg string (-b/-l/-w/-M/-N) once at
# startup. Empty if no perf knobs were set; otherwise something like
# "-b 1G -l 128K -N". Pass-through; iperf2 validates the values.
_iperf_extra_args() {
    local parts=()
    [ -n "$IPERF_BANDWIDTH" ]   && parts+=("-b" "$IPERF_BANDWIDTH")
    [ -n "$IPERF_LENGTH" ]      && parts+=("-l" "$IPERF_LENGTH")
    [ -n "$IPERF_WINDOW" ]      && parts+=("-w" "$IPERF_WINDOW")
    [ -n "$IPERF_MSS" ]         && parts+=("-M" "$IPERF_MSS")
    [ "$IPERF_NO_NAGLE" = "1" ] && parts+=("-N")
    printf '%s' "${parts[*]}"
}
IPERF_EXTRA_ARGS=$(_iperf_extra_args)

# Run ID + results directory.
#
# Each invocation that produces output writes to "$RESULTS_BASE/$RUN_ID/".
# Read-side commands (status, parse-csv, parse-cpu, make-pivot, make-heatmap,
# results-summary) default to following the "latest" symlink under
# $RESULTS_BASE if --run-id wasn't given.
#
# Auto-generation of $RUN_ID is deferred to when a write-side command first
# needs it (see _ensure_run_id), so just running `--help` or `status` or a
# read-side command never creates an empty results subdirectory.
_default_run_id() { date '+%Y-%m-%d_%H-%M-%S'; }

_ensure_run_id() {
    if [ -z "$RUN_ID" ]; then
        RUN_ID="$(_default_run_id)"
    fi
    RESULTS_DIR="$RESULTS_BASE/$RUN_ID"
    LOGS_DIR="$RESULTS_DIR/logs"
    SCRIPTS_DIR="$RESULTS_DIR/scripts"
    mkdir -p "$RESULTS_DIR" "$LOGS_DIR" "$SCRIPTS_DIR"
    # Update the latest symlink to point at this run. Best effort: a
    # non-symlink "latest" (a file or directory the user created by hand)
    # is left alone with a warning.
    local link="$RESULTS_BASE/latest"
    if [ -L "$link" ] || [ ! -e "$link" ]; then
        ln -sfn "$RUN_ID" "$link" 2>/dev/null || true
    fi
}

# Resolve $RESULTS_DIR for read-side commands. Order:
#   1. explicit --run-id <id>                -> $RESULTS_BASE/<id>
#   2. $RESULTS_BASE/latest symlink target   -> use it
#   3. else: error with a hint
_resolve_existing_run() {
    # Always follow the 'latest' symlink so each command picks up
    # whatever create-scripts most recently wrote. --run-id (set
    # _RUN_ID_EXPLICIT=1) is the only way to pin a different run.
    if [ "${_RUN_ID_EXPLICIT:-0}" = "1" ] && [ -n "$RUN_ID" ]; then
        RESULTS_DIR="$RESULTS_BASE/$RUN_ID"
    elif [ -L "$RESULTS_BASE/latest" ] || [ -d "$RESULTS_BASE/latest" ]; then
        local real
        real=$(readlink "$RESULTS_BASE/latest" 2>/dev/null || echo "latest")
        RUN_ID="$real"
        RESULTS_DIR="$RESULTS_BASE/$RUN_ID"
    else
        die "no results found at $RESULTS_BASE; run 'create-scripts' first or pass --run-id <id>"
    fi
    LOGS_DIR="$RESULTS_DIR/logs"
    SCRIPTS_DIR="$RESULTS_DIR/scripts"
    [ -d "$RESULTS_DIR" ] || die "results directory not found: $RESULTS_DIR"
    mkdir -p "$LOGS_DIR" 2>/dev/null || true
}

# Server list resolution. Priority: --servers / IPERF_SERVERS env; else
# look for "servers.txt" next to the script. Read commands also accept
# the file passed via the global flag.
_resolve_server_list() {
    if [ -z "$SERVER_LIST_FILE" ]; then
        if [ -f "$SCRIPT_DIR/servers.txt" ]; then
            SERVER_LIST_FILE="$SCRIPT_DIR/servers.txt"
        fi
    fi
}
_resolve_server_list

# Logging targets: written into the active run's logs/ dir when a write
# command has called _ensure_run_id; otherwise echoed-only. The logging
# functions below tolerate $LOGS_DIR being unset.
LOGS_DIR="${LOGS_DIR:-}"
RESULTS_DIR="${RESULTS_DIR:-}"
SCRIPTS_DIR="${SCRIPTS_DIR:-}"

#------------------------------------------------------------------------------
# Logging
#------------------------------------------------------------------------------
ts()    { date '+%Y-%m-%d %H:%M:%S'; }
_log_to_file() {
    # Append to $LOGS_DIR/orchestrator.log only if a write command has
    # established a logs directory. Read-only commands skip the file
    # write so they don't create empty directories.
    [ -n "${LOGS_DIR:-}" ] && [ -d "${LOGS_DIR}" ] || return 0
    printf '%s\n' "$1" >> "$LOGS_DIR/orchestrator.log"
}
log() {
    local line="[$(ts)] $*"
    _log_to_file "$line"
    [ "${IPERF_VERBOSITY:-1}" -ge 1 ] && echo "$line"
    return 0
}
vlog() {
    local line="[$(ts)] $*"
    _log_to_file "$line"
    [ "${IPERF_VERBOSITY:-1}" -ge 2 ] && echo "$line"
    return 0
}
warn()  { local line="[$(ts)] WARN: $*";  _log_to_file "$line"; echo "$line" >&2; }
err()   { local line="[$(ts)] ERROR: $*"; _log_to_file "$line"; echo "$line" >&2; }
die()   { err "$*"; exit 1; }

#------------------------------------------------------------------------------
# Hostname sanitization
#
# Hostnames go into filenames at many places: run_<host>.sh, run_<host>.log,
# iperf_test_<src>_to_<dst>.log, cpu_<host>.log, iperf_server_<host>.log,
# iperf_run_<host>.status. Most names round-trip fine, but bracketed IPv6
# (`[fe80::1]`) and rare hostnames containing `:` or `/` produce filenames
# that confuse glob patterns and FAT/Windows-mounted shares. We replace
# those characters with `_` for the on-disk name only -- the original
# hostname is preserved inside file headers (`# pair_a=...`, `# host=...`)
# so the analysis tooling sees the real value.
#
# Idempotent on plain DNS / IPv4 names.
#------------------------------------------------------------------------------
_sanitize_host() {
    printf '%s' "$1" | tr ':/[] \t' '_______'
}

#------------------------------------------------------------------------------
# Server list helpers
#------------------------------------------------------------------------------
read_servers() {
    if [ -z "$SERVER_LIST_FILE" ]; then
        die "no server list. Pass --servers <file> (or set IPERF_SERVERS, or place servers.txt next to the script)"
    fi
    [ -f "$SERVER_LIST_FILE" ] || die "server list not found: $SERVER_LIST_FILE"
    # Strip blank lines, comments, and surrounding whitespace
    sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        "$SERVER_LIST_FILE" | grep -v '^$'
}

# Validate the server list once, when something needs hosts. Catches
# typos / URLs / whitespace-laden hostnames before we generate scripts
# or fan out SSH connections.
_validate_server_list() {
    [ -n "$SERVER_LIST_FILE" ] && [ -f "$SERVER_LIST_FILE" ] \
        || die "no server list. Pass --servers <file> or set IPERF_SERVERS"
    local dups
    dups=$(read_servers | sort | uniq -d)
    [ -z "$dups" ] || warn "server list has duplicate hostnames: $(echo $dups)"
}

#------------------------------------------------------------------------------
# SSH wrappers
#------------------------------------------------------------------------------
ssh_run() {
    # ssh_run <host> <command...>
    local host="$1"; shift
    vlog "ssh $SSH_USER@$host: $*"
    if [ "${IPERF_DRY_RUN:-0}" = "1" ]; then
        echo "DRY-RUN ssh $SSH_USER@$host -- $*"
        return 0
    fi
    # shellcheck disable=SC2086
    ssh $SSH_BATCH_OPTS "$SSH_USER@$host" "$@"
}

scp_to() {
    # scp_to <local_src> <host> <remote_dst>
    local src="$1" host="$2" dst="$3"
    vlog "scp $src -> $SSH_USER@$host:$dst"
    if [ "${IPERF_DRY_RUN:-0}" = "1" ]; then
        echo "DRY-RUN scp $src -> $SSH_USER@$host:$dst"
        return 0
    fi
    # shellcheck disable=SC2086
    scp $SSH_BATCH_OPTS "$src" "$SSH_USER@$host:$dst" >/dev/null
}

scp_from() {
    # scp_from <host> <remote_src> <local_dst>
    local host="$1" src="$2" dst="$3"
    vlog "scp $SSH_USER@$host:$src -> $dst"
    if [ "${IPERF_DRY_RUN:-0}" = "1" ]; then
        echo "DRY-RUN scp $SSH_USER@$host:$src -> $dst"
        return 0
    fi
    # shellcheck disable=SC2086
    scp $SSH_BATCH_OPTS "$SSH_USER@$host:$src" "$dst" >/dev/null 2>&1
}

#------------------------------------------------------------------------------
# Capped-concurrency parallel host fan-out
#
# parallel_hosts <worker_fn>
#   Runs <worker_fn> <host> in the background for every host in the server
#   list, with at most $IPERF_SSH_JOBS concurrent workers. Each worker's stdout
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
    local jobs="$IPERF_SSH_JOBS"
    [ "$jobs" -lt 1 ] && jobs=1

    # read_servers calls die() when the list is missing, but we invoke
    # it inside a process substitution below -- its exit only kills
    # the subshell, so the parent would silently see an empty host
    # list. Check up front so the failure surfaces.
    if [ -z "$SERVER_LIST_FILE" ] || [ ! -f "$SERVER_LIST_FILE" ]; then
        die "no server list. Pass --servers <file> or set IPERF_SERVERS"
    fi

    local hosts=() h
    while IFS= read -r h; do
        [ -z "$h" ] && continue
        hosts+=("$h")
    done < <(read_servers)
    local n=${#hosts[@]}

    PARALLEL_FAILED=()
    [ "$n" -eq 0 ] && return 0

    # Cap effective parallelism at the host count; running 64 jobs for 4
    # hosts is just confusing log lines, not faster.
    if [ "$jobs" -gt "$n" ]; then
        jobs="$n"
    fi

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/iperf-orch-XXXXXX") || die "mktemp failed"

    local i running=0
    for ((i=0; i<n; i++)); do
        if [ "$running" -ge "$jobs" ]; then
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
# Peer data-plane IP resolution
#
# When the SSH/login IP differs from the iperf data-plane NIC, plain
# `iperf -c <login_ip>` either rides the wrong NIC (kernel routes the
# login IP over the management interface) or fails outright if the peer
# daemon is bound to its data-plane IP via --server-bind. The fix is to
# connect to each peer's data-plane IP directly. We discover them once,
# up front, by SSHing to every host (via its login IP) and running the
# same --bind substring against its `ip -o -4 addr show` output.
#
# Sets the global associative array PEER_BIND_IPS keyed by login-IP (as
# in servers.txt) -> data-plane IPv4. Aborts up front if any host lacks
# a matching interface so the operator can fix the pattern before we
# launch a full mesh of broken tests.
_resolve_peer_bind_ips() {
    declare -gA PEER_BIND_IPS=()
    local pattern="$1"
    [ -z "$pattern" ] && return 0

    if [ -z "$SERVER_LIST_FILE" ] || [ ! -f "$SERVER_LIST_FILE" ]; then
        die "no server list. Pass --servers <file> or set IPERF_SERVERS"
    fi

    local hosts=() h
    while IFS= read -r h; do
        [ -z "$h" ] && continue
        hosts+=("$h")
    done < <(read_servers)
    local n=${#hosts[@]}
    [ "$n" -eq 0 ] && return 0

    log "Resolving peer data-plane IPs for --bind '$pattern' (parallel x$IPERF_SSH_JOBS)..."

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/iperf-orch-bind-XXXXXX") || die "mktemp failed"

    local jobs=$IPERF_SSH_JOBS
    [ "$jobs" -gt "$n" ] && jobs=$n

    local i running=0
    for ((i=0; i<n; i++)); do
        if [ "$running" -ge "$jobs" ]; then
            wait -n 2>/dev/null || wait
            running=$((running - 1))
        fi
        (
            ssh_run "${hosts[$i]}" "
                BIND_RAW='$pattern'
                _line=\$(ip -o -4 addr show 2>/dev/null | grep -- \"\$BIND_RAW\" | head -n1)
                [ -n \"\$_line\" ] || exit 1
                echo \"\$_line\" | awk '{print \$4}' | cut -d/ -f1
            " > "$tmpdir/$i.ip" 2>/dev/null
        ) &
        running=$((running + 1))
    done
    wait

    local missing=() ip
    for ((i=0; i<n; i++)); do
        ip=$(tr -d '[:space:]' < "$tmpdir/$i.ip" 2>/dev/null)
        if [ -z "$ip" ]; then
            missing+=("${hosts[$i]}")
        else
            PEER_BIND_IPS["${hosts[$i]}"]=$ip
            vlog "  ${hosts[$i]}: '$pattern' -> $ip"
        fi
    done
    rm -rf "$tmpdir"

    if [ "${#missing[@]}" -gt 0 ]; then
        die "--bind '$pattern': no interface matched on host(s): ${missing[*]}. Check that the pattern matches a line in 'ip -o -4 addr show' on each host."
    fi
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

first_run_banner() {
    cat <<EOF
iperf-orchestrator.sh - full-mesh iperf2 testing across a server list

Quick start (key-based SSH to every host must already be set up):
    $PROG --servers servers.txt all
                                  # run the full pipeline + render heatmap.
                                  # Results land in $RESULTS_BASE/<run-id>/

The script is stateless. Re-running 'all' creates a fresh run-id; the
'latest' symlink under $RESULTS_BASE is updated each time. To re-analyze
an older run, pass --run-id <id> to parse-csv / make-pivot / make-heatmap.

Other useful commands:
    $PROG doctor             Check that local prerequisites are installed
    $PROG status             Probe hosts and list available result runs
    $PROG matrix <cmd>       Sustained traffic-matrix emulation across the
                             fleet (up/status/reload/summarize/down); see
                             matrix_agent/README.md
    $PROG --help             Common commands and flags (also: help, -h)
    $PROG help-advanced      Every command, every flag, every env var
    $PROG --version          Print the version and exit

EOF
}

usage() {
    cat <<EOF
iperf-orchestrator.sh - full-mesh iperf2 throughput tests

USAGE:
    $PROG [flags] <command> [args]

QUICK START:
    $PROG --servers servers.txt all                        # run + analyze + cleanup
    (key-based SSH to every host must already be configured)

COMMON COMMANDS:
    start-servers          Start iperf2 -s daemons on every host
    run-tests [MODE]       Run tests. MODE is one of:
                             parallel         (default) every host pairs up at once
                             rolling          random rolling probes; scales to any N
                                              (--total-time SECONDS, --host-flows N)
    process                Pull results, parse CSV/CPU, render pivot + heatmap
    stop-servers           Kill iperf2 -s daemons
    all [MODE]             start-servers + run-tests + process + stop
    status                 List runs and probe hosts live

COMMON FLAGS:
    --servers, -s FILE         server list (one host per line; '#' comments)
    --duration, -d SECONDS     duration per test (default $IPERF_DURATION)
    --total-time SECONDS       wall-time for rolling mode (default $IPERF_TOTAL_TIME)
    --host-flows N             concurrent iperf processes per directed edge.
                               In parallel/sequential modes: each (src, dst) pair
                               runs N iperf processes simultaneously, so the cell
                               aggregates N flows' bandwidth. In rolling mode:
                               caps how many concurrent iperf processes a single
                               host has in flight at once. (default $IPERF_HOST_FLOWS)
    --bandwidth, -b RATE       cap per-flow rate, e.g. 100M, 1G (iperf2 -b)
    --length, -l SIZE          TCP r/w buffer size, e.g. 128K (iperf2 -l)
    --ssh-jobs, -j N           max concurrent SSH/SCP fan-out (default $IPERF_SSH_JOBS)
    --ssh-user, -u USER        SSH login user (default $SSH_USER)
    --output, -o DIR           results directory (default $RESULTS_BASE)
    -h, --help                 show this help
    --help-advanced            show every command, every flag, every env var
    --version                  print the version and exit

Each invocation creates \$RESULTS_BASE/<run-id>/. \$RESULTS_BASE/latest tracks
the most recent run. Pass --run-id <id> to operate on an older run.
EOF
}

usage_advanced() {
    cat <<EOF
iperf-orchestrator.sh - full-mesh iperf2 testing across a server list

Each host pair is tested with iperf2; results are parsed into a CSV,
pivot table, and heatmap.

The script is stateless. Each invocation that produces output creates a
fresh \$RESULTS_BASE/<run-id>/ directory; analysis commands follow the
'latest' symlink unless --run-id is passed explicitly.

USAGE:
    $PROG [global flags] <command> [args]

GLOBAL FLAGS (override env vars; both --flag value and --flag=value work):
    --servers, -s FILE         Server list file: one IP/host per line; '#' comments OK
                               (default: \$IPERF_SERVERS env, else $SCRIPT_DIR/servers.txt)
    --output, -o DIR           Base directory for results (default $RESULTS_BASE)
    --run-id ID                Address an existing run (default: follow 'latest' symlink)
    --port PORT                iperf2 listening port (default $IPERF_PORT)
    --duration, -d SECONDS     duration per test (default $IPERF_DURATION)
    --streams, -P N            parallel streams within each test (default $IPERF_STREAMS)
    --ssh-jobs, -j N           max concurrent SSH/SCP fan-out (default $IPERF_SSH_JOBS)
    --total-time SECONDS       rolling mode wall-time (default $IPERF_TOTAL_TIME)
    --host-flows N             concurrent iperf procs per directed edge (parallel)
                               or per-host concurrency cap (rolling). (default $IPERF_HOST_FLOWS)
    --bandwidth, -b RATE       cap per-flow target rate (iperf2 -b; e.g. 100M, 1G)
    --length, -l SIZE          TCP read/write buffer size (iperf2 -l; e.g. 128K)
    --window, -w SIZE          TCP window / socket buffer (iperf2 -w; e.g. 4M)
    --mss, -M SIZE             TCP maximum segment size (iperf2 -M)
    --no-nagle, -N             disable Nagle's algorithm (iperf2 -N)
    --bind, -B PATTERN         bind iperf -c to a local interface. PATTERN is
                               substring-matched against 'ip -o -4 addr show'
                               on each remote; the first matching line's IPv4
                               is what iperf2 -B receives. Examples:
                                 -B eth0       -B bond       -B mlx5
                                 -B 10.0.0     -B 192.168
                               When set, the orchestrator also probes every
                               peer up front for the data-plane IP matching
                               PATTERN and uses that as the iperf -c
                               destination (instead of the SSH/login IP from
                               servers.txt), so traffic actually rides the
                               bound NIC even when login and data-plane IPs
                               live on different interfaces.
    --server-bind PATTERN      bind the iperf2 server side too. Same pattern
                               syntax as --bind. Defaults to the value of
                               --bind so the daemon only accepts on the
                               data-plane NIC; pass --server-bind='' to
                               keep listening on 0.0.0.0 instead.
    --dry-run, -n              print SSH/SCP commands without executing them
    --verbose, -v              also print every ssh/scp invocation
    --quiet, -q                suppress non-WARN/ERROR log lines
    --start-delay SECONDS      synchronized-start lead time (default $START_DELAY)
    --ssh-user, -u USER        SSH login user (default $SSH_USER)
    --remote-dir PATH          remote working dir (default $REMOTE_DIR)
                               Safe to point at a shared FS: filenames embed <host>_<run-id>.
    --python PATH              Python interpreter (default $PYTHON_BIN)
    -h, --help                 show the simple help
    --help-advanced            show this help
    --version                  print the version and exit

Key-based SSH to every host must be configured before use (e.g. via
ssh-copy-id); the orchestrator connects non-interactively with BatchMode.

SETUP:
    check-iperf            Check which hosts have iperf2 installed
    check-servers          Check which hosts have iperf -s currently running

EXECUTION:
    start-servers          Start iperf -p \$PORT -s -D on every host
    create-scripts         Generate per-host client run scripts (called by run-tests)
    distribute-scripts     Copy each host's run script to that host (called by run-tests)
    run-tests [MODE]       Run the tests. Auto-runs create-scripts and
                           distribute-scripts for parallel/sequential modes. MODE:
                             parallel         all hosts run simultaneously after a
                                              synchronized start (default)
                             sequential-host  hosts run one at a time
                             sequential-pair  one connection on the wire at any moment
                             rolling          each host independently picks its
                                              least-tested peer, repeats for
                                              --total-time, with --host-flows concurrent.
                                              Self-starting (no create-scripts).
    collect-results        Pull each host's logs as a tarball back into the run dir.
    stop-servers           Kill iperf -s daemons on every host.
    cleanup [--yes]        Remove \$REMOTE_DIR on every host (--yes required).

ANALYSIS:
    parse-csv              Parse iperf2 CSV logs into results/iperf_results.csv
    parse-cpu              Parse mpstat samples into results/cpu_summary.csv
    make-pivot             Render results/iperf_pivot.txt (text pivot table)
    make-heatmap           Render results/iperf_heatmap.png (heatmap + bar chart)
    process                = collect-results + parse-csv + parse-cpu + make-pivot
                             + make-heatmap.
    results-summary        Print P50/P95/min/mean/max + 5 slowest pairs from
                           iperf_results.csv.

CONVENIENCE:
    all [MODE] [--keep-going]  Run the full pipeline (doctor + start-servers +
                               run-tests + process + stop-servers + cleanup).
                               --keep-going continues past per-host failures.
    doctor                     Check local prerequisites (ssh tools, Python,
                               numpy, matplotlib) and print install hints.
    status                     Probe hosts (iperf installed? server running?) and
                               list available runs.
    help                       Show the simple help (this command's short form).
    help-advanced              Show this message.
    version                    Print the version and exit (same as --version).

SUSTAINED LOAD (source checkout only):
    matrix <cmd> [opts]        Pass-through to matrix_agent/fleet.sh: hold a
                               prescribed traffic matrix across the whole fleet
                               indefinitely (paced flows, receiver-side
                               reporting). Commands: up, status, reload,
                               collect, summarize, down, prep. All flags after
                               'matrix' belong to fleet.sh -- see
                               $PROG matrix --help and matrix_agent/README.md.

CONFIG (env vars; CLI flags above take precedence):
    IPERF_PORT=$IPERF_PORT
    IPERF_DURATION=$IPERF_DURATION
    IPERF_STREAMS=$IPERF_STREAMS
    IPERF_SSH_JOBS=$IPERF_SSH_JOBS
    IPERF_TOTAL_TIME=$IPERF_TOTAL_TIME
    IPERF_HOST_FLOWS=$IPERF_HOST_FLOWS
    IPERF_BANDWIDTH=${IPERF_BANDWIDTH:-}   # iperf2 -b (per-flow rate cap)
    IPERF_LENGTH=${IPERF_LENGTH:-}         # iperf2 -l (TCP read/write buffer)
    IPERF_WINDOW=${IPERF_WINDOW:-}         # iperf2 -w (TCP window / socket buffer)
    IPERF_MSS=${IPERF_MSS:-}               # iperf2 -M (TCP MSS)
    IPERF_NO_NAGLE=$IPERF_NO_NAGLE         # iperf2 -N (1 = disable Nagle's)
    IPERF_BIND=${IPERF_BIND:-}             # iperf2 -B (bind to local addr/iface)
    IPERF_SERVER_BIND=${IPERF_SERVER_BIND:-} # iperf2 -B for the server side
    IPERF_VERBOSITY=$IPERF_VERBOSITY     # 0=quiet, 1=normal, 2=verbose
    IPERF_DRY_RUN=$IPERF_DRY_RUN
    SSH_USER=$SSH_USER
    SSH_OPTS=$SSH_OPTS
    START_DELAY=$START_DELAY
    IPERF_SERVERS=${IPERF_SERVERS:-}
    RESULTS_BASE=$RESULTS_BASE
    REMOTE_DIR=$REMOTE_DIR

FILES:
    Server list:  ${SERVER_LIST_FILE:-(unset)}
    Results base: $RESULTS_BASE
    Latest run:   $RESULTS_BASE/latest -> ...
EOF
}

#------------------------------------------------------------------------------
# Probe hosts and list local run directories. No state file is read or
# written; everything is derived live.
cmd_status() {
    echo "Results base: $RESULTS_BASE"
    echo "Server list:  ${SERVER_LIST_FILE:-(none; pass --servers)}"
    echo
    echo "Runs:"
    if [ -d "$RESULTS_BASE" ]; then
        local latest=""
        [ -L "$RESULTS_BASE/latest" ] && latest=$(readlink "$RESULTS_BASE/latest" 2>/dev/null)
        local d found=0
        for d in "$RESULTS_BASE"/*/; do
            [ -d "$d" ] || continue
            local base="${d%/}"; base="${base##*/}"
            [ "$base" = "latest" ] && continue
            local marker=""
            [ "$base" = "$latest" ] && marker="  <- latest"
            echo "  $base$marker"
            found=1
        done
        [ "$found" = "0" ] && echo "  (none)"
    else
        echo "  (none)"
    fi
    if [ -n "$SERVER_LIST_FILE" ] && [ -f "$SERVER_LIST_FILE" ]; then
        echo
        echo "iperf2 + mpstat:"
        parallel_hosts _worker_check_iperf | sed 's/^/  /'
        echo
        echo "Daemons:"
        parallel_hosts _worker_check_servers | sed 's/^/  /'
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
    _validate_server_list
    log "Checking iperf2 + mpstat on every host..."
    parallel_hosts _worker_check_iperf
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
    _validate_server_list
    log "Checking iperf2 daemon status on port $IPERF_PORT..."
    parallel_hosts _worker_check_servers
}

#------------------------------------------------------------------------------
_worker_start_server() {
    local host="$1"
    # If --server-bind is set, the remote shell resolves the substring
    # against its own interface list and passes -B <ip> to iperf -s.
    # Failure is fatal so the operator notices a wrong pattern instead
    # of silently falling back to a 0.0.0.0 listener.
    ssh_run "$host" "
        set -e
        mkdir -p '$REMOTE_DIR'
        BIND_RAW='$IPERF_SERVER_BIND'
        BIND_FLAG=''
        if [ -n \"\$BIND_RAW\" ]; then
            _line=\$(ip -o -4 addr show 2>/dev/null | grep -- \"\$BIND_RAW\" | head -n1)
            [ -n \"\$_line\" ] || { echo \"ERROR: $host: --server-bind: no interface matched '\$BIND_RAW'\" >&2; exit 1; }
            _ip=\$(echo \"\$_line\" | awk '{print \$4}' | cut -d/ -f1)
            BIND_FLAG=\"-B \$_ip\"
            echo \"[server-bind] $host: '\$BIND_RAW' -> ip=\$_ip\"
        fi
        iperf -p $IPERF_PORT \$BIND_FLAG -s -D
    "
}

cmd_start_servers() {
    _validate_server_list
    log "Starting iperf2 -s on port $IPERF_PORT (parallel x$IPERF_SSH_JOBS)..."
    parallel_hosts _worker_start_server
    [ ${#PARALLEL_FAILED[@]} -eq 0 ] || warn "start-servers: ${#PARALLEL_FAILED[@]} failure(s)"
}

#------------------------------------------------------------------------------
cmd_create_scripts() {
    _ensure_run_id
    _validate_server_list
    log "Generating per-host client run scripts (every host as client to every peer)..."
    log "Run ID: $RUN_ID"
    # Slurp the host list into a plain array up front. Nested `while read
    # <<<` loops have produced empty inner iterations in the field that I
    # haven't been able to reproduce locally; iterating arrays sidesteps
    # the here-string mechanism entirely and is easier to reason about.
    local hosts_arr=() h
    while IFS= read -r h; do
        [ -z "$h" ] && continue
        hosts_arr+=("$h")
    done < <(read_servers)
    [ "${#hosts_arr[@]}" -gt 0 ] || die "No hosts in server list"

    # Resolve each peer's data-plane IP when --bind is set, so the
    # generated run scripts can `iperf -c <data_plane_ip>` instead of
    # connecting to the SSH/login IP (which may route over the wrong
    # NIC). No-op when --bind is unset.
    _resolve_peer_bind_ips "$IPERF_BIND"

    build_host_idx

    # Track per-host target counts so we can show the user the load
    # distribution after generation. Every host is a client to every
    # other host (one iperf invocation per directed edge), so counts
    # should be N-1 for all hosts.
    local target_counts=()
    local src

    for src in "${hosts_arr[@]}"; do
        local src_safe; src_safe=$(_sanitize_host "$src")
        local script="$SCRIPTS_DIR/run_${src_safe}_${RUN_ID}.sh"

        # Every host is a client against every other host. Each directed
        # edge (src -> dst) is its own iperf2 invocation, producing a
        # log with exactly one direction's data. This sidesteps the
        # iperf2 --full-duplex CSV reporting quirks (per-direction row
        # vs SUM-of-both-directions row) that made cell values
        # unreliable across -P values and iperf2 builds.
        local targets=() t
        for t in "${hosts_arr[@]}"; do
            [ "$t" = "$src" ] && continue
            targets+=("$t")
        done

        # Hard guard: every host must have N-1 targets. An empty list
        # means the run script will silently no-op for that source, and
        # the pivot will show '-(1)' for everything in that row -- the
        # exact failure mode we saw before this guard was added.
        local expected_targets=$(( ${#hosts_arr[@]} - 1 ))
        if [ "${#targets[@]}" -ne "$expected_targets" ]; then
            die "create-scripts: $src ended up with ${#targets[@]} target(s), expected $expected_targets. Server list: ${hosts_arr[*]}"
        fi

        target_counts+=("${#targets[@]}")

        local targets_str="" conn_ips_str=""
        for t in "${targets[@]}"; do
            targets_str+="\"$t\" "
            # Parallel array: conn IP to actually feed to iperf -c. When
            # --bind isn't set (or PEER_BIND_IPS is empty) this stays
            # empty per slot and the generated script falls back to the
            # login IP. We resolved every host in _resolve_peer_bind_ips
            # so missing entries here mean --bind wasn't set.
            conn_ips_str+="\"${PEER_BIND_IPS[$t]:-}\" "
        done

        cat > "$script" <<EOF
#!/usr/bin/env bash
# Auto-generated by iperf-orchestrator. Do not edit by hand.
# Source host: $src
# Run ID:      $RUN_ID
# Targets:     ${targets[*]}
#
# Runs one unidirectional iperf2 against each target. One iperf -c per
# directed (src -> dst) edge, producing a log with exactly one
# direction's bytes. The peer host's matching script handles the reverse
# direction, so both directions are measured simultaneously across the
# fleet. Filenames embed both host and run-id so multiple hosts whose
# \$REMOTE_DIR is on a shared filesystem (e.g. NFS home) don't overwrite
# each other.
set -u

START_TIME="\${1:-0}"
SINGLE_TARGET="\${2:-}"
SOURCE="$src"
RUN_ID="$RUN_ID"
PORT=$IPERF_PORT
DURATION=$IPERF_DURATION
PARALLEL=$IPERF_STREAMS
BIND_RAW="$IPERF_BIND"
TARGETS=( $targets_str )
# Parallel to TARGETS: the data-plane IP to feed to iperf -c. Empty
# slots fall back to the matching TARGETS entry (the SSH/login IP), so
# this is a no-op when --bind is unset.
TARGET_CONN_IPS=( $conn_ips_str )
HOST_FLOWS=$IPERF_HOST_FLOWS

cd "\$(dirname "\$0")"

# Resolve --bind. The value is a substring matched against this host's
# 'ip -o -4 addr show' output (full line, so it matches against iface
# name OR address). The first matching line's IPv4 wins.
BIND_ARG=""
BIND_IP=""
BIND_IFACE=""
if [ -n "\$BIND_RAW" ]; then
    _bind_line=\$(ip -o -4 addr show 2>/dev/null | grep -- "\$BIND_RAW" | head -n1)
    [ -n "\$_bind_line" ] || {
        echo "ERROR: \$SOURCE: no interface matched '\$BIND_RAW'" >&2
        exit 1
    }
    BIND_IFACE=\$(echo "\$_bind_line" | awk '{print \$2}')
    BIND_IP=\$(echo "\$_bind_line"    | awk '{print \$4}' | cut -d/ -f1)
    BIND_ARG="-B \$BIND_IP"
    echo "[bind] \$SOURCE: '\$BIND_RAW' -> iface=\$BIND_IFACE ip=\$BIND_IP"
fi

# Synchronized launch: wait until START_TIME (epoch seconds), if given.
if [ "\$START_TIME" -gt 0 ]; then
    now=\$(date +%s)
    if [ "\$START_TIME" -gt "\$now" ]; then
        sleep \$(( START_TIME - now ))
    fi
fi

# Pick the target list: a single target overrides the full list (used by
# sequential-pair mode, which calls this script once per pair). When a
# single target is given we still want its resolved conn IP (if --bind
# was set), so look it up in the parallel TARGETS / TARGET_CONN_IPS
# arrays and fall back to the target itself when nothing matches.
if [ -n "\$SINGLE_TARGET" ]; then
    run_targets=( "\$SINGLE_TARGET" )
    _single_conn="\$SINGLE_TARGET"
    for ((_i=0; _i<\${#TARGETS[@]}; _i++)); do
        if [ "\${TARGETS[\$_i]}" = "\$SINGLE_TARGET" ]; then
            _single_conn="\${TARGET_CONN_IPS[\$_i]:-\$SINGLE_TARGET}"
            [ -z "\$_single_conn" ] && _single_conn="\$SINGLE_TARGET"
            break
        fi
    done
    run_conn_ips=( "\$_single_conn" )
else
    run_targets=( "\${TARGETS[@]}" )
    run_conn_ips=( "\${TARGET_CONN_IPS[@]}" )
fi

# Sanitizer matching the orchestrator's _sanitize_host(). Keeps file
# names safe for IPv6 hostnames like [fe80::1] and any host with \`:\`,
# \`/\`, \`[\`, \`]\`, or whitespace. Real hostname is preserved inside
# headers (# pair_a=..., # host=...) so the parser sees the truth.
_san() { printf '%s' "\$1" | tr ':/[] \\t' '_______'; }
SOURCE_SAFE=\$(_san "\$SOURCE")
STATUS_FILE="iperf_run_\${SOURCE_SAFE}_\${RUN_ID}.status"

echo "\$(date '+%F %T') START \$SOURCE -> \${run_targets[*]}" >> "\$STATUS_FILE"

# Start CPU sampling. We want to capture the test window plus a small tail
# so the "after" baseline is visible. mpstat with -P ALL gives per-core
# breakdown; that's important because softirq load on a single hashed core
# can be the bottleneck even when the box-wide average looks fine.
#
# If mpstat isn't installed we fall back to sampling /proc/stat directly,
# which gives box-wide CPU but no per-core. The fallback file format is
# made deliberately distinguishable from mpstat's so the parser can tell
# them apart. We always prepend a "# host=<original>" line so the parser
# knows the unsanitized hostname even if the on-disk filename was
# rewritten.
SAMPLE_DURATION=\$(( DURATION + 4 ))
cpu_log="cpu_\${SOURCE_SAFE}_\${RUN_ID}.log"
cpu_pid=""

{
    echo "# host=\$SOURCE"
    if command -v mpstat >/dev/null 2>&1; then
        LC_ALL=C S_TIME_FORMAT=ISO mpstat -P ALL 1 "\$SAMPLE_DURATION" 2>&1
    else
        echo "# fallback=proc_stat host=\$SOURCE samples=\$SAMPLE_DURATION"
        for _ in \$(seq 1 "\$SAMPLE_DURATION"); do
            date '+%F %T'
            head -n1 /proc/stat
            sleep 1
        done
    fi
} > "\$cpu_log" 2>&1 &
cpu_pid=\$!

# Even hosts with no client work still receive inbound traffic from their
# peers, so we want CPU samples from them too. They skip the iperf-client
# loop but still wait for the sampler.
if [ \${#run_targets[@]} -gt 0 ]; then
    # Fire every client in parallel and wait for the whole batch. Each
    # invocation is unidirectional: the peer host's matching script
    # handles the reverse direction simultaneously, so both directions
    # are measured without iperf2 SUM-row ambiguity.
    # When HOST_FLOWS>1 we fire that many concurrent iperf processes
    # per directed edge so the cell value reflects the aggregate
    # bandwidth of N parallel flows. Each flow gets its own log; the
    # parser sums them per pair via mbps*duration / wall_time.
    # -y C gives CSV summaries; -e enables enhanced reports.
    pids=()
    for (( ti=0; ti<\${#run_targets[@]}; ti++ )); do
        target="\${run_targets[\$ti]}"
        # Connection IP: the peer's data-plane IP when --bind was set;
        # otherwise the SSH/login IP from servers.txt. We keep \$target
        # as pair_b in the header so the analysis labels match the
        # server-list hostnames (the conn IP is informational only).
        conn_ip="\${run_conn_ips[\$ti]:-\$target}"
        [ -z "\$conn_ip" ] && conn_ip="\$target"
        target_safe=\$(_san "\$target")
        echo "\$(date '+%F %T') testing -> \$target [\$conn_ip] (x\$HOST_FLOWS)" >> "\$STATUS_FILE"
        for (( flow=1; flow<=HOST_FLOWS; flow++ )); do
            if [ "\$HOST_FLOWS" -gt 1 ]; then
                out="iperf_test_\${SOURCE_SAFE}_to_\${target_safe}_f\${flow}_\${RUN_ID}.log"
            else
                out="iperf_test_\${SOURCE_SAFE}_to_\${target_safe}_\${RUN_ID}.log"
            fi
            (
                # Header line consumed by the parser. Keys are space-separated to keep parsing trivial.
                # full_duplex=0 tells parse-csv this log carries one direction only (pair_a -> pair_b).
                # conn_ip records the actual destination handed to iperf -c, which differs from pair_b
                # when the login IP and data-plane NIC live on different interfaces.
                echo "# pair_a=\$SOURCE pair_b=\$target conn_ip=\$conn_ip run_id=\$RUN_ID duration=\$DURATION port=\$PORT parallel=\$PARALLEL host_flows=\$HOST_FLOWS flow=\$flow full_duplex=0 bind_iface=\$BIND_IFACE bind_ip=\$BIND_IP test_start=\$(date +%s)" > "\$out"
                # Build the exact iperf invocation as a single string and
                # echo it into the per-test log BEFORE running. Anyone
                # debugging a failure can copy-paste this directly.
                cmd="iperf -c \$conn_ip -p \$PORT -t \$DURATION -P \$PARALLEL $IPERF_EXTRA_ARGS \$BIND_ARG -e -y C"
                echo "# cmd: \$cmd" >> "\$out"
                iperf -c "\$conn_ip" -p "\$PORT" -t "\$DURATION" -P "\$PARALLEL" $IPERF_EXTRA_ARGS \$BIND_ARG -e -y C >> "\$out" 2>&1
                rc=\$?
                # iperf2 sometimes returns 0 even when the connection failed
                # (it writes "connect failed" to stdout and exits cleanly).
                # Catch both: non-zero exit OR known error tokens in output.
                if [ "\$rc" -ne 0 ] || grep -qE 'connect failed|Connection refused|Connection timed out|bind failed|No route to host|read failed|write failed' "\$out"; then
                    err_tail=\$(grep -E 'connect failed|Connection (refused|timed out)|bind failed|No route to host|read failed|write failed' "\$out" | head -n1)
                    [ -z "\$err_tail" ] && err_tail="exit_status=\$rc"
                    echo "# exit_status: \$rc" >> "\$out"
                    # Surface failure into the per-host SSH log (which is
                    # collected back as run_<host>.log) so the operator
                    # sees the inciting command without having to grep
                    # every iperf_test_*.log.
                    echo "[FAIL] \$SOURCE -> \$target [\$conn_ip] flow=\$flow: \$err_tail" >&2
                    echo "       cmd: \$cmd" >&2
                fi
            ) &
            pids+=(\$!)
        done
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

echo "\$(date '+%F %T') DONE" >> "\$STATUS_FILE"
EOF
        chmod +x "$script"
        vlog "  created $script (targets: ${#targets[@]})"
    done

    # Summarize the client-load distribution so the user can confirm the
    # fan-out. Every host is now a client to every other host, so all
    # counts should equal N-1 and total iperf processes per host = (N-1)
    # * IPERF_HOST_FLOWS. Total directed edges across the fleet = N*(N-1)
    # and total iperf processes = N*(N-1)*IPERF_HOST_FLOWS.
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
        local total_procs=$(( sum * IPERF_HOST_FLOWS ))
        if [ "$IPERF_HOST_FLOWS" -gt 1 ]; then
            log "Client load: min=$mn, max=$mx, mean=$((mean10/10)).$((mean10%10)), edges=$sum, flows/edge=$IPERF_HOST_FLOWS, total iperf procs=$total_procs"
        else
            log "Client load: min=$mn, max=$mx, mean=$((mean10/10)).$((mean10%10)), total tests=$sum"
        fi
    fi

    vlog "All run scripts created in $SCRIPTS_DIR"
}

#------------------------------------------------------------------------------
_worker_distribute_script() {
    local host="$1"
    local host_safe; host_safe=$(_sanitize_host "$host")
    local script="$SCRIPTS_DIR/run_${host_safe}_${RUN_ID}.sh"
    local remote_name="run_iperf_${host_safe}_${RUN_ID}.sh"
    if [ ! -f "$script" ]; then
        warn "  no script for $host (run create-scripts first)"
        return 1
    fi
    # Only delete files belonging to this run-id so prior runs sharing
    # the same $REMOTE_DIR aren't collateral damage.
    local clean_glob="'$REMOTE_DIR'/iperf_test_*_${RUN_ID}.log '$REMOTE_DIR'/iperf_run_*_${RUN_ID}.status"
    if ssh_run "$host" "mkdir -p '$REMOTE_DIR' && rm -f $clean_glob" \
       && scp_to "$script" "$host" "$REMOTE_DIR/$remote_name" \
       && ssh_run "$host" "chmod +x '$REMOTE_DIR/$remote_name'"; then
        vlog "  OK: $host"
    else
        warn "  FAILED: $host"
        return 1
    fi
}

cmd_distribute_scripts() {
    _resolve_existing_run
    _validate_server_list
    [ -d "$SCRIPTS_DIR" ] || die "no generated scripts at $SCRIPTS_DIR; run create-scripts first"
    log "Distributing run scripts to each host (parallel x$IPERF_SSH_JOBS)..."
    parallel_hosts _worker_distribute_script

    if [ ${#PARALLEL_FAILED[@]} -eq 0 ]; then
        vlog "All run scripts distributed"
    else
        warn "distribute-scripts had ${#PARALLEL_FAILED[@]} failure(s)"
    fi
}

#------------------------------------------------------------------------------
# Signal handler: on Ctrl-C or SIGTERM during run-tests / cmd_all, try to
# stop the iperf daemons we spawned on every remote host so they don't
# linger. cmd_stop_servers is idempotent and parallel.
_orchestrator_signal_cleanup() {
    trap - INT TERM
    warn "interrupted; attempting to stop iperf servers on all hosts"
    # Best-effort: don't let a failure here mask the original signal.
    cmd_stop_servers || true
    exit 130
}

cmd_run_tests() {
    local mode="${1:-parallel}"
    case "$mode" in
        parallel|sequential-host|sequential-pair|rolling) ;;
        *) die "unknown mode: $mode (expected parallel|sequential-host|sequential-pair|rolling)" ;;
    esac
    # rolling is self-starting (doesn't use per-host run scripts).
    # Other modes generate + distribute the per-host scripts as part
    # of run-tests so users don't have to chain create-scripts and
    # distribute-scripts by hand.
    if [ "$mode" = "rolling" ]; then
        _ensure_run_id
        _validate_server_list
        # Rolling mode is self-starting (no create-scripts step), so it
        # needs its own peer-IP probe before _run_rolling spawns iperf.
        _resolve_peer_bind_ips "$IPERF_BIND"
    else
        cmd_create_scripts
        cmd_distribute_scripts
    fi
    trap '_orchestrator_signal_cleanup' INT TERM
    local n_hosts; n_hosts=$(read_servers | wc -l)
    [ "$n_hosts" -ge 2 ] || die "run-tests needs at least 2 hosts (got $n_hosts)"
    log "Mode: $mode  Run ID: $RUN_ID"

    case "$mode" in
        parallel)         _run_one_round "$(( $(date +%s) + START_DELAY ))" "" ;;
        sequential-host)  while IFS= read -r h; do [ -n "$h" ] && _run_one_round 0 "" "$h"; done < <(read_servers) ;;
        sequential-pair)
            # One directed iperf connection on the wire at any moment.
            # Iterates every (s, d) where s != d, so both directions of
            # each unordered pair are measured in separate rounds.
            local hosts=()
            while IFS= read -r h; do [ -n "$h" ] && hosts+=("$h"); done < <(read_servers)
            local s d
            for s in "${hosts[@]}"; do
                for d in "${hosts[@]}"; do
                    [ "$s" = "$d" ] && continue
                    _run_one_round 0 "$d" "$s"
                done
            done
            ;;
        rolling)          _run_rolling ;;
    esac

    printf '%s\n' "$mode" > "$RESULTS_DIR/.run_mode"
    trap - INT TERM
}

# Rolling probe: each host runs an independent loop for IPERF_TOTAL_TIME
# seconds. Each iteration: pick the least-tested peer (random tiebreak),
# small jitter to desync hosts, run one short iperf -c, log result. No
# global scheduler -- per-host probes are independent. Scales to any N
# because each host has at most one outbound flow at any moment.
_run_rolling() {
    log "Rolling: ${IPERF_TOTAL_TIME}s wall-time, ${IPERF_DURATION}s per test, up to ${IPERF_HOST_FLOWS} flow(s) per host"
    local hosts=()
    while IFS= read -r h; do [ -n "$h" ] && hosts+=("$h"); done < <(read_servers)
    local pids=() src
    for src in "${hosts[@]}"; do
        local peers="" peer_conn_ips_decl="declare -A PEER_CONN_IPS=( " p
        for p in "${hosts[@]}"; do
            [ "$p" = "$src" ] && continue
            peers+="\"$p\" "
            # Embed an associative-array entry per peer so the rolling
            # loop can look up the data-plane IP by name. Empty value
            # when --bind wasn't set; the loop falls back to the login IP.
            peer_conn_ips_decl+="[\"$p\"]=\"${PEER_BIND_IPS[$p]:-}\" "
        done
        peer_conn_ips_decl+=")"
        local src_safe; src_safe=$(_sanitize_host "$src")
        local hostlog="$LOGS_DIR/rolling_${src_safe}.log"
        ssh_run "$src" "
            set -u
            mkdir -p '$REMOTE_DIR'
            cd '$REMOTE_DIR'
            # Background CPU sampler running for the whole rolling window
            # (mpstat if present, /proc/stat fallback otherwise). Same
            # filename + header format as the parallel/sequential modes,
            # so parse-cpu and make-heatmap consume it unchanged.
            {
                echo \"# host=$src\"
                if command -v mpstat >/dev/null 2>&1; then
                    LC_ALL=C S_TIME_FORMAT=ISO mpstat -P ALL 1 $IPERF_TOTAL_TIME 2>&1
                else
                    echo \"# fallback=proc_stat host=$src samples=$IPERF_TOTAL_TIME\"
                    for _ in \$(seq 1 $IPERF_TOTAL_TIME); do
                        date '+%F %T'
                        head -n1 /proc/stat
                        sleep 1
                    done
                fi
            } > \"cpu_${src_safe}_$RUN_ID.log\" 2>&1 &
            # Resolve --bind once for this host. The value is a substring
            # matched against 'ip -o -4 addr show'; the first matching
            # line's IPv4 is what we bind to.
            BIND_RAW=\"$IPERF_BIND\"
            BIND_ARG=\"\"
            BIND_IP=\"\"
            BIND_IFACE=\"\"
            if [ -n \"\$BIND_RAW\" ]; then
                _bind_line=\$(ip -o -4 addr show 2>/dev/null | grep -- \"\$BIND_RAW\" | head -n1)
                [ -n \"\$_bind_line\" ] || {
                    echo \"ERROR: $src: no interface matched '\$BIND_RAW'\" >&2
                    exit 1
                }
                BIND_IFACE=\$(echo \"\$_bind_line\" | awk '{print \$2}')
                BIND_IP=\$(echo \"\$_bind_line\"    | awk '{print \$4}' | cut -d/ -f1)
                BIND_ARG=\"-B \$BIND_IP\"
                echo \"[bind] $src: '\$BIND_RAW' -> iface=\$BIND_IFACE ip=\$BIND_IP\"
            fi
            PEERS=( $peers )
            # Peer name -> data-plane IP (or empty when --bind unset).
            # The rolling loop picks targets by name (for fair-share
            # counting) but connects via the resolved conn IP.
            $peer_conn_ips_decl
            END_TIME=\$(( \$(date +%s) + $IPERF_TOTAL_TIME ))
            declare -A counts
            for t in \"\${PEERS[@]}\"; do counts[\"\$t\"]=0; done
            seq=0
            active=0
            # Startup jitter: each host begins its loop at a different
            # fraction of a second so initial target picks don't all
            # land at the same wall-clock moment across the fleet.
            sleep 0.\$((RANDOM % 1000))
            while [ \$(date +%s) -lt \$END_TIME ]; do
                # Wait for a slot if we're at the per-host concurrency cap.
                while [ \$active -ge $IPERF_HOST_FLOWS ]; do
                    wait -n 2>/dev/null || wait
                    active=\$((active - 1))
                done
                min=999999
                cands=()
                for t in \"\${PEERS[@]}\"; do
                    c=\${counts[\"\$t\"]}
                    if [ \$c -lt \$min ]; then min=\$c; cands=(\"\$t\")
                    elif [ \$c -eq \$min ]; then cands+=(\"\$t\")
                    fi
                done
                target=\${cands[\$((RANDOM % \${#cands[@]}))]}
                conn_ip=\${PEER_CONN_IPS[\"\$target\"]:-\$target}
                [ -z \"\$conn_ip\" ] && conn_ip=\"\$target\"
                target_safe=\$(printf '%s' \"\$target\" | tr ':/[] \\t' '_______')
                seq=\$((seq + 1))
                counts[\"\$target\"]=\$((counts[\"\$target\"] + 1))
                outfile=\"iperf_test_${src_safe}_to_\${target_safe}_\${seq}_$RUN_ID.log\"
                # Stagger launches and run iperf in background so multiple
                # flows can be in flight at once.
                (
                    sleep 0.\$((100 + RANDOM % 900))
                    cmd=\"iperf -c \$conn_ip -p $IPERF_PORT -t $IPERF_DURATION -P $IPERF_STREAMS $IPERF_EXTRA_ARGS \$BIND_ARG -y C\"
                    echo \"# pair_a=$src pair_b=\$target conn_ip=\$conn_ip run_id=$RUN_ID duration=$IPERF_DURATION port=$IPERF_PORT parallel=$IPERF_STREAMS bind_iface=\$BIND_IFACE bind_ip=\$BIND_IP test_start=\$(date +%s)\" > \"\$outfile\"
                    echo \"# cmd: \$cmd\" >> \"\$outfile\"
                    iperf -c \"\$conn_ip\" -p $IPERF_PORT -t $IPERF_DURATION -P $IPERF_STREAMS $IPERF_EXTRA_ARGS \$BIND_ARG -y C >> \"\$outfile\" 2>&1
                    rc=\$?
                    if [ \"\$rc\" -ne 0 ] || grep -qE 'connect failed|Connection refused|Connection timed out|bind failed|No route to host|read failed|write failed' \"\$outfile\"; then
                        err_tail=\$(grep -E 'connect failed|Connection (refused|timed out)|bind failed|No route to host|read failed|write failed' \"\$outfile\" | head -n1)
                        [ -z \"\$err_tail\" ] && err_tail=\"exit_status=\$rc\"
                        echo \"# exit_status: \$rc\" >> \"\$outfile\"
                        echo \"[FAIL] $src -> \$target [\$conn_ip] seq=\$seq: \$err_tail\" >&2
                        echo \"       cmd: \$cmd\" >&2
                    fi
                ) &
                active=\$((active + 1))
            done
            # Drain any in-flight flows before returning.
            wait
        " > "$hostlog" 2>&1 &
        pids+=("$!")
    done
    log "Launched ${#pids[@]} probes; running for ${IPERF_TOTAL_TIME}s..."
    local pid
    for pid in "${pids[@]}"; do wait "$pid" || true; done
    log "Rolling phase complete."
}

# Run one batch: each named source host invokes its remote run script with
# the given start_time and (optional) single target. With no source list,
# fan out to every host in the server list (this is what `parallel` mode
# uses). With one source, run just it (sequential-host / sequential-pair).
_run_one_round() {
    local start_time="$1" target="$2"; shift 2
    local sources=()
    if [ "$#" -gt 0 ]; then
        sources=("$@")
    else
        local h
        while IFS= read -r h; do [ -n "$h" ] && sources+=("$h"); done < <(read_servers)
    fi
    local pids=() src
    for src in "${sources[@]}"; do
        local safe; safe=$(_sanitize_host "$src")
        local hostlog="$LOGS_DIR/run_${safe}.log"
        local script="$REMOTE_DIR/run_iperf_${safe}_${RUN_ID}.sh"
        local arg=""
        [ -n "$target" ] && arg=" '$target'"
        ssh_run "$src" "'$script' $start_time$arg" > "$hostlog" 2>&1 &
        pids+=("$!")
    done
    local p
    for p in "${pids[@]}"; do wait "$p" || true; done
}

#------------------------------------------------------------------------------
_worker_collect_results() {
    local host="$1"
    local host_safe; host_safe=$(_sanitize_host "$host")
    # Tarball name uses sanitized hostname + run-id so two hosts on a
    # shared FS can write to $REMOTE_DIR concurrently without colliding.
    local tarball_remote="$REMOTE_DIR/_results_${host_safe}_${RUN_ID}.tar.gz"
    local tarball_local="$RESULTS_DIR/_results_${host_safe}_${RUN_ID}.tar.gz"

    # Files to grab are scoped to this RUN_ID so we never accidentally
    # pull files from a concurrent or older run that shares $REMOTE_DIR.
    if ! ssh_run "$host" "
        cd '$REMOTE_DIR' 2>/dev/null || exit 1
        listfile='_iperf_files_${host_safe}_${RUN_ID}.list'
        {
            ls iperf_test_*_${RUN_ID}.log 2>/dev/null || true
            ls 'iperf_server_${host_safe}_${RUN_ID}.log' 2>/dev/null || true
            ls 'iperf_run_${host_safe}_${RUN_ID}.status' 2>/dev/null || true
            ls 'cpu_${host_safe}_${RUN_ID}.log' 2>/dev/null || true
        } > \"\$listfile\"
        if [ -s \"\$listfile\" ]; then
            tar -czf '$tarball_remote' -T \"\$listfile\"
        fi
        rm -f \"\$listfile\"
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
    # Don't gate on tar's exit code -- it returns 1 on harmless warnings
    # (e.g. clock skew between hosts producing future-dated timestamps)
    # but the files are still extracted. Surface any tar output verbatim.
    local tarout
    tarout=$(tar -xzf "$tarball_local" -C "$RESULTS_DIR" 2>&1)
    if [ -n "$tarout" ]; then
        # tar warnings (e.g. clock skew) are noise but worth keeping at -v.
        vlog "  $host: $client_count client logs + server log + status (tar: $tarout)"
    else
        vlog "  $host: $client_count client logs + server log + status"
    fi
    rm -f "$tarball_local"
    ssh_run "$host" "rm -f '$tarball_remote'" 2>/dev/null || true
}

cmd_collect_results() {
    _resolve_existing_run
    _validate_server_list
    log "Collecting results from all hosts -> $RESULTS_DIR (tar-batched, parallel x$IPERF_SSH_JOBS)"
    parallel_hosts _worker_collect_results

    local total
    total=$(ls "$RESULTS_DIR"/iperf_test_*.log 2>/dev/null | wc -l)
    if [ ${#PARALLEL_FAILED[@]} -eq 0 ]; then
        log "Collected $total client logs total"
    else
        warn "collect-results: ${#PARALLEL_FAILED[@]} host(s) had transfer failures"
    fi
}

#------------------------------------------------------------------------------
_worker_stop_server() {
    ssh_run "$1" "pkill -f '^iperf -p $IPERF_PORT ' 2>/dev/null; true"
}

cmd_stop_servers() {
    _validate_server_list
    log "Stopping iperf2 servers on port $IPERF_PORT..."
    parallel_hosts _worker_stop_server
}

#------------------------------------------------------------------------------
_worker_cleanup() {
    local host="$1"
    ssh_run "$host" "rm -rf '$REMOTE_DIR'"
}

cmd_cleanup() {
    local seen_yes=0 a
    for a in "$@"; do
        case "$a" in
            --yes) seen_yes=1 ;;
            *) die "cleanup: unknown argument: $a (expected --yes)" ;;
        esac
    done
    if [ "${_IPERF_ORCH_INTERNAL:-0}" != "1" ] && [ "$seen_yes" -ne 1 ]; then
        die "cleanup will run 'rm -rf $REMOTE_DIR' on every host. Pass --yes to confirm."
    fi
    _validate_server_list
    log "Removing $REMOTE_DIR on every host..."
    parallel_hosts _worker_cleanup
    [ ${#PARALLEL_FAILED[@]} -eq 0 ] || warn "cleanup: ${#PARALLEL_FAILED[@]} failure(s)"
}

#------------------------------------------------------------------------------
cmd_parse_csv() {
    _resolve_existing_run
    local csv="$RESULTS_DIR/iperf_results.csv"
    log "Parsing iperf2 CSV logs -> $csv"
    command -v "$PYTHON_BIN" >/dev/null || die "$PYTHON_BIN not found; install Python 3"

    # If a server list is reachable, build a filter: only keep rows
    # whose pair_a/pair_b are both in the active list. Lets users
    # comment hosts out of servers.txt to drop them from the analysis
    # without re-running the test.
    local active_list=""
    if [ -n "$SERVER_LIST_FILE" ] && [ -f "$SERVER_LIST_FILE" ]; then
        active_list=$(read_servers | tr '\n' ',')
    fi

    "$PYTHON_BIN" - "$RESULTS_DIR" "$csv" "$active_list" <<'PYEOF'
import os, sys, csv, glob

results_dir, out_csv = sys.argv[1], sys.argv[2]
active = set(h for h in (sys.argv[3] if len(sys.argv) > 3 else "").split(",") if h)

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
        "bind_iface": h.get("bind_iface", ""),
        "bind_ip": h.get("bind_ip", ""),
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
    # full_duplex=0 (the new default written by cmd_create_scripts) means
    # this log is one direction only: pair_a (the iperf -c invoker) sent
    # bytes to pair_b. The reverse direction is captured in a separate
    # log produced by pair_b's matching iperf -c against pair_a. If the
    # header is missing or full_duplex=1, fall back to the legacy
    # --full-duplex two-row parse for backwards compatibility with old
    # log files.
    full_duplex = header.get("full_duplex", "1") != "0"

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
        if full_duplex:
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

    # Single-direction log (full_duplex=0): there is exactly one
    # aggregate, representing pair_a -> pair_b. If the address-matching
    # fallbacks didn't pick it up (hostname vs IP mismatch with a SUM
    # marker), assign the lone aggregate to a_to_b directly.
    if not full_duplex and a_to_b is None and len(aggregates) == 1:
        a_to_b = next(iter(aggregates.values()))

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
            "bind_iface": header.get("bind_iface", ""),
            "bind_ip": header.get("bind_ip", ""),
            "bytes_transferred": nbytes, "bps": bps_f, "mbps": mbps,
            "src_port": src_port, "dst_port": dst_port,
            "pair_a": pair_a, "pair_b": pair_b,
            "filename": base, "error": "",
        })

    emit(a_to_b, pair_a, pair_b)
    if full_duplex:
        emit(b_to_a, pair_b, pair_a)

# Filter against the current server list, if one was supplied. Drops
# rows whose pair_a or pair_b is not in the active set, so commented
# hosts in servers.txt disappear from the analysis automatically.
if active:
    before = len(rows)
    rows = [r for r in rows if r["pair_a"] in active and r["pair_b"] in active]
    dropped = before - len(rows)
    if dropped:
        print(f"Filtered {dropped} row(s) for hosts not in current servers.txt",
              file=sys.stderr)

if not rows:
    print("No log files found", file=sys.stderr)
    sys.exit(1)

cols = ["timestamp","source","target","status","protocol","duration_s",
        "parallel_streams","bind_iface","bind_ip",
        "bytes_transferred","bps","mbps",
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
    _resolve_existing_run
    local cpu_csv="$RESULTS_DIR/cpu_summary.csv"
    log "Parsing CPU sample logs -> $cpu_csv"
    command -v "$PYTHON_BIN" >/dev/null || die "$PYTHON_BIN not found"

    local n_cpu_logs
    n_cpu_logs=$(ls "$RESULTS_DIR"/cpu_*.log 2>/dev/null | wc -l)
    if [ "$n_cpu_logs" -eq 0 ]; then
        warn "No cpu_*.log files in $RESULTS_DIR (was the test run with this version of the script?)"
        return 0
    fi

    local active_list=""
    if [ -n "$SERVER_LIST_FILE" ] && [ -f "$SERVER_LIST_FILE" ]; then
        active_list=$(read_servers | tr '\n' ',')
    fi

    "$PYTHON_BIN" - "$RESULTS_DIR" "$cpu_csv" "$active_list" <<'PYEOF'
import os, sys, csv, glob, re

results_dir, out_csv = sys.argv[1], sys.argv[2]
active = set(h for h in (sys.argv[3] if len(sys.argv) > 3 else "").split(",") if h)

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

def host_from_header(path):
    """Read the first few lines looking for `# host=<original>`. The
    remote script writes this so the parser can recover the original
    hostname even when the on-disk filename has been sanitized
    (e.g. for bracketed IPv6 like [fe80::1] -> _fe80__1_)."""
    try:
        with open(path) as f:
            for _ in range(5):
                line = f.readline()
                if not line:
                    break
                if line.startswith("# host="):
                    return line[len("# host="):].strip()
    except OSError:
        pass
    return None

rows = []
for path in sorted(glob.glob(os.path.join(results_dir, "cpu_*.log"))):
    base = os.path.basename(path)
    # Prefer the embedded `# host=` header (round-trips IPv6 names
    # correctly); fall back to the filename for older logs.
    host = host_from_header(path)
    if not host:
        host = base[len("cpu_"):-len(".log")]

    summary = parse_mpstat(path) or parse_proc_stat_fallback(path)
    if summary is None:
        rows.append({c: "" for c in cols})
        rows[-1].update({"host": host, "source": "PARSE_ERROR", "filename": base})
        continue
    summary["host"] = host
    summary["filename"] = base
    rows.append(summary)

# Filter against the current server list, if one was supplied.
if active:
    before = len(rows)
    rows = [r for r in rows if r["host"] in active]
    dropped = before - len(rows)
    if dropped:
        print(f"Filtered {dropped} host(s) not in current servers.txt", file=sys.stderr)

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
}

#------------------------------------------------------------------------------
cmd_make_pivot() {
    _resolve_existing_run
    local csv="$RESULTS_DIR/iperf_results.csv"
    local pivot="$RESULTS_DIR/iperf_pivot.txt"
    [ -f "$csv" ] || die "No CSV; run: $PROG parse-csv"
    log "Building pivot table -> $pivot"

    # Metadata captured for the header. Most fields reflect the run's
    # actual recorded values (mode, duration, port, parallel-streams)
    # so a `make-pivot` invocation that doesn't pass `--duration`/`-P`
    # still describes the test that was actually run. n_hosts is taken
    # from the active server list at pivot time, since make-pivot honors
    # the current servers.txt for filtering.
    local meta_run_at meta_mode meta_n_hosts
    meta_run_at="$(date '+%F %T %z')"
    meta_mode="(unknown)"
    [ -f "$RESULTS_DIR/.run_mode" ] && meta_mode=$(cat "$RESULTS_DIR/.run_mode")
    meta_n_hosts=0
    [ -n "$SERVER_LIST_FILE" ] && [ -f "$SERVER_LIST_FILE" ] && meta_n_hosts=$(read_servers | wc -l)

    "$PYTHON_BIN" - "$csv" "$pivot" \
        "$meta_run_at" "$meta_mode" "$meta_n_hosts" <<'PYEOF'
import csv, sys
from collections import Counter, defaultdict

in_csv, out_txt = sys.argv[1], sys.argv[2]
meta_run_at, meta_mode, meta_n_hosts = sys.argv[3], sys.argv[4], sys.argv[5]

# duration / port / parallel come from the run's own data so they reflect
# what actually executed, not whatever this make-pivot invocation's env
# happens to have. We pick the modal value across rows for each.
def _modal(values):
    vs = [v for v in values if v not in (None, "", "0")]
    if not vs:
        return "?"
    return Counter(vs).most_common(1)[0][0]

_dur_vals, _port_vals, _par_vals = [], [], []
# bindings_per_src[src] = (iface, ip) — populated only when --bind was set.
# The bind metadata describes the host that *originated* the test (pair_a).
# We only credit it to that host's source-row to avoid placeholder rows
# (DIRECTION_MISSING from the other side's log) clobbering it.
bindings_per_src = {}
with open(in_csv) as _f:
    for _r in csv.DictReader(_f):
        _dur_vals.append(_r.get("duration_s", ""))
        _port_vals.append(_r.get("dst_port", ""))
        _par_vals.append(_r.get("parallel_streams", ""))
        _bi, _bp = _r.get("bind_iface", ""), _r.get("bind_ip", "")
        _src, _pa = _r.get("source", ""), _r.get("pair_a", "")
        if (_bi or _bp) and _src and _src == _pa:
            bindings_per_src[_src] = (_bi, _bp)
meta_duration = _modal(_dur_vals)
meta_port     = _modal(_port_vals)
meta_parallel = _modal(_par_vals)

mat = defaultdict(dict)    # mat[src][dst] = time-averaged directional Mbps
samples_per = defaultdict(dict)  # samples_per[src][dst] = sample count
attempts = defaultdict(lambda: defaultdict(int))  # attempts[src][dst] = total tries (incl. failures)
sources, targets = set(), set()

# iperf2 -y C timestamp parser. Format: "YYYYMMDDHHMMSS.fff" (e.g.
# "20260506191234.567"). Returns epoch seconds, or None on failure.
def _ts(s):
    # iperf2 -y C emits "YYYYMMDDHHMMSS" with an optional ".fff"
    # millisecond suffix. Keep the fractional part -- losing it can
    # underestimate `span` by up to a second per row and inflate the
    # directional-throughput cell on tightly-clustered samples.
    if not s or len(s) < 14:
        return None
    try:
        from datetime import datetime
        secs = datetime.strptime(s[:14], "%Y%m%d%H%M%S").timestamp()
        if len(s) > 15 and s[14] == ".":
            try:
                secs += float("0." + s[15:].strip())
            except ValueError:
                pass
        return secs
    except Exception:
        return None

# Cell value semantics: time-averaged directional Mbps, computed as
# sum(mbps_i * duration_i for all flows i in this direction) / run_wall_time.
# This is equivalent to total-bytes-divided-by-wall-time (since
# mbps*duration = bytes*8/1e6) and correctly captures BOTH concurrent
# flows (--host-flows>1, where multiple iperf invocations in the same
# direction sum because their bytes accumulate during the same wall
# window) AND idle gaps in the run. With --host-flows=1 and back-to-
# back tests it collapses to the per-flow mean. We also track every
# attempt (including rows with no measured throughput, i.e. failed
# iperf invocations) so blank cells can be annotated -- "-(5)" means
# 5 tries, all failed.
acc = defaultdict(lambda: defaultdict(list))
mbps_seconds = defaultdict(lambda: defaultdict(float))  # sum(mbps * duration)
ts_list = []
max_dur = 0.0
with open(in_csv) as f:
    for row in csv.DictReader(f):
        s, t = row["source"], row["target"]
        sources.add(s); targets.add(t)
        attempts[s][t] += 1
        v = row.get("mbps") or ""
        try:
            f_v = float(v) if v != "" else None
        except ValueError:
            f_v = None
        if f_v is not None:
            acc[s][t].append(f_v)
            try:
                d = float(row.get("duration_s") or "0")
            except ValueError:
                d = 0.0
            if d > 0:
                mbps_seconds[s][t] += f_v * d
                if d > max_dur:
                    max_dur = d
            tv = _ts(row.get("timestamp", ""))
            if tv is not None:
                ts_list.append(tv)

# Run wall-time = span of all timestamps + the longest single-test
# duration. For parallel / sequential-host modes (rows roughly synced)
# the span is small and wall_time ≈ max_dur. For rolling, the span
# covers the whole probe loop so wall_time ≈ --total-time.
if ts_list:
    span = max(ts_list) - min(ts_list)
    wall_time = span + max_dur if span >= 0 else max_dur
else:
    wall_time = max_dur
if wall_time <= 0:
    wall_time = 1.0  # fallback; avoids division-by-zero

for s in acc:
    for t in acc[s]:
        vs = acc[s][t]
        if vs:
            samples_per[s][t] = len(vs)
            ms = mbps_seconds[s].get(t, 0.0)
            mat[s][t] = ms / wall_time if ms > 0 else sum(vs) / len(vs)
        else:
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
    f.write(f"iperf2 full-mesh throughput (Mbps)\n")
    f.write(f"Run at:   {meta_run_at}\n")
    f.write(f"Mode:     {meta_mode}    Duration: {meta_duration}s    "
            f"Port: {meta_port}    Parallel: {meta_parallel}    Hosts: {meta_n_hosts}\n")
    f.write(f"Rows = source (sender), Columns = target (receiver)\n")
    f.write(f"Each cell = total bytes (source -> target) * 8 / run wall-time = "
            f"time-averaged\n  directional throughput. Accounts for "
            f"concurrent flows summing in the same direction.\n")
    f.write(f"Diagonal '-' = no self-test;  '-(N)' = N attempts, none successful\n\n")

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
                if v is None:
                    a = attempts.get(s, {}).get(d, 0)
                    cell = f"-({a})" if a > 0 else "-"
                    f.write(cell.rjust(num_w) + " ")
                else:
                    f.write(fmt_num(v) + " ")
                    vals.append(v)
        if vals:
            row_means[s] = sum(vals) / len(vals)
        f.write("\n")

    # Per-host *incoming* total = sum of column cells = total bytes/s
    # that host receives from every other host. We deliberately do NOT
    # report (in + out) per-host: every byte appears once as someone's
    # out and once as someone else's in, so adding them inside one host
    # double-counts at the fleet level. Reporting only incoming lets
    # each byte be counted exactly once, and sum(incoming across hosts)
    # equals the fleet aggregate by construction.
    col_sums = {}
    for d in dst_list:
        vals = [mat.get(s, {}).get(d) for s in src_list if s != d]
        vals = [v for v in vals if v is not None]
        if vals:
            col_sums[d] = sum(vals)
    # Mbps -> GB/s (decimal): Mbps / 8000. So 8000 Mbps = 1 GB/s.
    def _gbs(mbps): return mbps / 8000.0
    if col_sums:
        f.write("\nPer-host incoming bandwidth "
                "(total Mbps received, sorted high to low):\n")
        max_in = max(col_sums.values()) or 1.0
        for h, v in sorted(col_sums.items(), key=lambda kv: kv[1], reverse=True):
            bar = "#" * int(v / max_in * 40)
            f.write(f"  {h.ljust(host_w)} {v:10.2f} Mbps "
                    f"({_gbs(v):6.3f} GB/s)  {bar}\n")

    # Fleet-wide aggregate = sum of every successful (source -> target)
    # cell = sum of per-host incoming totals. This is the total
    # bytes/s moving across the mesh, each byte counted exactly once.
    all_flows = [mat.get(s, {}).get(d)
                 for s in src_list for d in dst_list if s != d]
    all_flows = [v for v in all_flows if v is not None]
    if all_flows:
        sys_total = sum(all_flows)
        n_hosts = len(all_hosts)
        per_host = sys_total / n_hosts if n_hosts else 0.0
        f.write(f"\nFleet aggregate bandwidth (sum of all directional flows): "
                f"{sys_total:.2f} Mbps  ({_gbs(sys_total):.3f} GB/s)\n")
        f.write(f"  mean per-host throughput: {per_host:.2f} Mbps "
                f"({_gbs(per_host):.3f} GB/s)   "
                f"[{len(all_flows)} flow(s) measured across {n_hosts} host(s)]\n")

    # Source bindings: only present when --bind was used.
    if bindings_per_src:
        f.write("\nSource bindings (--bind resolved per host at iperf-launch):\n")
        for src in sorted(bindings_per_src):
            iface, ip = bindings_per_src[src]
            f.write(f"  {src.ljust(host_w)} iface={iface or '?'} ip={ip or '?'}\n")

    # If any cell aggregated more than one sample (rolling mode), summarize.
    counts = [c for d in samples_per.values() for c in d.values()]
    if counts and max(counts) > 1:
        f.write(f"\nSamples per cell: min={min(counts)} max={max(counts)} "
                f"mean={sum(counts)/len(counts):.1f} (cells reflect mean of N samples)\n")

print(f"Wrote {out_txt}")
PYEOF
    local rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
}

#------------------------------------------------------------------------------
cmd_make_heatmap() {
    _resolve_existing_run
    local csv="$RESULTS_DIR/iperf_results.csv"
    local cpu_csv="$RESULTS_DIR/cpu_summary.csv"
    local png="$RESULTS_DIR/iperf_heatmap.png"
    [ -f "$csv" ] || die "No CSV; run: $PROG parse-csv"
    log "Rendering heatmap + bar chart -> $png"

    local meta_run_at meta_mode meta_duration
    meta_run_at="$(date '+%F %T %z')"
    meta_mode="(unknown)"
    [ -f "$RESULTS_DIR/.run_mode" ] && meta_mode=$(cat "$RESULTS_DIR/.run_mode")
    meta_duration="$IPERF_DURATION"

    "$PYTHON_BIN" - "$csv" "$png" "$cpu_csv" \
        "$meta_run_at" "$meta_mode" "$meta_duration" <<'PYEOF'
import csv, sys, os
from collections import defaultdict

in_csv, out_png = sys.argv[1], sys.argv[2]
cpu_csv = sys.argv[3] if len(sys.argv) > 3 else ""
meta_run_at = sys.argv[4] if len(sys.argv) > 4 else ""
meta_mode   = sys.argv[5] if len(sys.argv) > 5 else ""
meta_dur    = sys.argv[6] if len(sys.argv) > 6 else ""

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
acc = defaultdict(lambda: defaultdict(list))
mbps_seconds = defaultdict(lambda: defaultdict(float))
ts_list = []
max_dur = 0.0

def _ts(s):
    # iperf2 -y C emits "YYYYMMDDHHMMSS" with an optional ".fff"
    # millisecond suffix. Keep the fractional part -- losing it can
    # underestimate `span` by up to a second per row and inflate the
    # directional-throughput cell on tightly-clustered samples.
    if not s or len(s) < 14:
        return None
    try:
        from datetime import datetime
        secs = datetime.strptime(s[:14], "%Y%m%d%H%M%S").timestamp()
        if len(s) > 15 and s[14] == ".":
            try:
                secs += float("0." + s[15:].strip())
            except ValueError:
                pass
        return secs
    except Exception:
        return None

with open(in_csv) as f:
    for row in csv.DictReader(f):
        s, t = row["source"], row["target"]
        sources.add(s); targets.add(t)
        v = row.get("mbps") or ""
        try:
            f_v = float(v) if v != "" else None
        except ValueError:
            f_v = None
        if f_v is not None:
            acc[s][t].append(f_v)
            try:
                d = float(row.get("duration_s") or "0")
            except ValueError:
                d = 0.0
            if d > 0:
                mbps_seconds[s][t] += f_v * d
                if d > max_dur:
                    max_dur = d
            tv = _ts(row.get("timestamp", ""))
            if tv is not None:
                ts_list.append(tv)

if ts_list:
    span = max(ts_list) - min(ts_list)
    wall_time = span + max_dur if span >= 0 else max_dur
else:
    wall_time = max_dur
if wall_time <= 0:
    wall_time = 1.0

for s in acc:
    for t in acc[s]:
        vs = acc[s][t]
        if not vs:
            mat[s][t] = None
            continue
        ms = mbps_seconds[s].get(t, 0.0)
        # Time-averaged directional Mbps; concurrent flows sum naturally.
        mat[s][t] = ms / wall_time if ms > 0 else sum(vs) / len(vs)

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
title_main = f"iperf2 full-mesh throughput (Mbps)  —  {n}×{n} hosts{sub}"
if meta_run_at or meta_mode or meta_dur:
    meta_bits = []
    if meta_run_at: meta_bits.append(meta_run_at)
    if meta_mode:   meta_bits.append(f"mode={meta_mode}")
    if meta_dur:    meta_bits.append(f"duration={meta_dur}s")
    title_main = title_main + "\n" + " | ".join(meta_bits)
ax_heat.set_title(title_main)

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
}

#------------------------------------------------------------------------------
# doctor: probe orchestrator-host prerequisites (ssh tools, python +
# matplotlib stack) up front so a missing dep fails fast instead of
# crashing 90s into `all`. Returns non-zero if anything is missing.
_doctor_check_tool() {
    local tool="$1" hint="$2"
    if command -v "$tool" >/dev/null 2>&1; then
        local ver
        ver=$("$tool" --version 2>&1 | head -n1 | tr -d '\r')
        # Doctor is explicitly a diagnostic; show its findings at the
        # default verbosity even though similar per-thing OK lines
        # elsewhere are demoted to -v.
        log "  OK  $tool   ${ver:-(no --version output)}"
        return 0
    fi
    warn "  MISSING $tool   ($hint)"
    return 1
}

_doctor_check_python_module() {
    local mod="$1"
    if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
        return 1
    fi
    if "$PYTHON_BIN" -c "import $mod" 2>/dev/null; then
        local pyver
        pyver=$("$PYTHON_BIN" -c "import $mod; print(getattr($mod, '__version__', '?'))" 2>/dev/null)
        log "  OK  python -m $mod   $pyver"
        return 0
    fi
    warn "  MISSING python module '$mod'   (pip install $mod)"
    return 1
}

# results-summary: print P50/P95/min/max throughput and the slowest 5
# (host, target) pairs without opening the heatmap PNG. Reads
# results/iperf_results.csv produced by parse-csv.
cmd_results_summary() {
    _resolve_existing_run
    local csv="$RESULTS_DIR/iperf_results.csv"
    [ -f "$csv" ] || die "No CSV at $csv; run: $PROG parse-csv"
    command -v "$PYTHON_BIN" >/dev/null || die "$PYTHON_BIN not found"

    "$PYTHON_BIN" - "$csv" <<'PYEOF'
import csv, sys, statistics

in_csv = sys.argv[1]

vals = []        # (mbps, source, target)
errors = 0
with open(in_csv) as f:
    for row in csv.DictReader(f):
        v = row.get("mbps") or ""
        if v == "":
            errors += 1
            continue
        try:
            vals.append((float(v), row.get("source",""), row.get("target","")))
        except ValueError:
            errors += 1

if not vals:
    print("No measured throughput rows in", in_csv)
    sys.exit(1)

mbps = sorted(v for v,_,_ in vals)
n = len(mbps)
def pct(p):
    # nearest-rank percentile, fine for summary stats.
    k = max(0, min(n - 1, int(round(p/100 * (n - 1)))))
    return mbps[k]

print(f"Throughput summary across {n} measured directions ({errors} errored/missing)")
print(f"  min:    {mbps[0]:>10.2f} Mbps")
print(f"  P50:    {pct(50):>10.2f} Mbps")
print(f"  mean:   {statistics.mean(mbps):>10.2f} Mbps")
print(f"  P95:    {pct(95):>10.2f} Mbps")
print(f"  max:    {mbps[-1]:>10.2f} Mbps")

print()
print("Slowest 5 (source -> target):")
slowest = sorted(vals)[:5]
for v, s, t in slowest:
    print(f"  {v:>10.2f}  {s} -> {t}")
PYEOF
}

cmd_doctor() {
    log "=== doctor: orchestrator-host prerequisites ==="
    local missing=0

    _doctor_check_tool ssh          "install openssh-client" || missing=$((missing + 1))
    _doctor_check_tool scp          "install openssh-client" || missing=$((missing + 1))

    _doctor_check_tool "$PYTHON_BIN" "install python3" || missing=$((missing + 1))

    local mod
    for mod in numpy matplotlib; do
        _doctor_check_python_module "$mod" || missing=$((missing + 1))
    done

    if [ "$missing" -eq 0 ]; then
        log "doctor: all prerequisites OK"
        return 0
    fi
    warn "doctor: $missing issue(s) above"
    return 1
}

#------------------------------------------------------------------------------
# process: pull results from the fleet and render the analysis artifacts.
#   collect-results -> parse-csv -> parse-cpu -> make-pivot -> make-heatmap
cmd_process() {
    cmd_collect_results
    cmd_parse_csv
    cmd_parse_cpu
    cmd_make_pivot
    cmd_make_heatmap
}

#------------------------------------------------------------------------------
cmd_all() {
    local mode="parallel"
    local keep_going=0
    local arg
    for arg in "$@"; do
        case "$arg" in
            --keep-going)                              keep_going=1 ;;
            parallel|sequential-host|sequential-pair|rolling)  mode="$arg" ;;
            *) die "cmd_all: unknown argument: $arg (expected mode and/or --keep-going)" ;;
        esac
    done

    # Stop iperf daemons across the fleet on Ctrl-C / SIGTERM.
    trap '_orchestrator_signal_cleanup' INT TERM

    # Run doctor up front so missing local prereqs fail fast (before we
    # touch any host or even check the server list).
    if ! cmd_doctor; then
        if [ "$keep_going" = "1" ]; then
            warn "doctor reported issues; continuing because --keep-going was passed"
        else
            die "doctor reported issues; install missing tools or pass --keep-going"
        fi
    fi

    _ensure_run_id
    _validate_server_list

    log "=== Running full pipeline (run-tests mode: $mode${keep_going:+, --keep-going})  ==="
    log "Run ID: $RUN_ID"
    log "Results dir: $RESULTS_DIR"

    _all_gate() {
        local step="$1"
        if [ "${#PARALLEL_FAILED[@]}" -gt 0 ]; then
            if [ "$keep_going" = "1" ]; then
                warn "$step had ${#PARALLEL_FAILED[@]} failure(s); continuing (--keep-going)"
            else
                die "$step had ${#PARALLEL_FAILED[@]} failure(s); aborting (use --keep-going to continue, or re-run the failing step)"
            fi
        fi
    }

    cmd_check_iperf;         _all_gate check-iperf
    cmd_check_servers;       _all_gate check-servers
    cmd_start_servers;       _all_gate start-servers
    cmd_run_tests "$mode"   # also runs create-scripts + distribute-scripts internally
    cmd_process              # collect + parse-csv + parse-cpu + make-pivot + make-heatmap
    cmd_stop_servers;        _all_gate stop-servers
    _IPERF_ORCH_INTERNAL=1 cmd_cleanup
    _all_gate cleanup
    log "=== Pipeline complete ==="
    echo

    local pivot="$RESULTS_DIR/iperf_pivot.txt"
    if [ -f "$pivot" ]; then
        echo "================================ Pivot table ================================"
        cat "$pivot"
        echo "============================================================================="
        echo
    else
        warn "no pivot table found at $pivot (make-pivot may have been skipped or failed)"
    fi

    echo "Results in: $RESULTS_DIR"
    ls -1 "$RESULTS_DIR" | sed 's/^/  /'

    local png="$RESULTS_DIR/iperf_heatmap.png"
    if [ -f "$png" ]; then
        echo
        # Mac: `open`. Linux desktop: `xdg-open`. Headless: scp it back.
        if command -v xdg-open >/dev/null 2>&1; then
            echo "View the heatmap: xdg-open $png"
        elif command -v open >/dev/null 2>&1; then
            echo "View the heatmap: open $png"
        else
            echo "Heatmap rendered to: $png  (scp it to a desktop to view)"
        fi
    fi

    trap - INT TERM
}


#==============================================================================
# Dispatcher
#==============================================================================
cmd="${1:-}"
shift || true

case "$cmd" in
    "")                 first_run_banner ;;
    status)             cmd_status "$@" ;;
    check-iperf)        cmd_check_iperf ;;
    check-servers)      cmd_check_servers ;;
    start-servers)      cmd_start_servers ;;
    create-scripts)     cmd_create_scripts ;;
    distribute-scripts) cmd_distribute_scripts ;;
    run-tests)          cmd_run_tests "$@" ;;
    collect-results)    cmd_collect_results ;;
    stop-servers)       cmd_stop_servers ;;
    cleanup)            cmd_cleanup "$@" ;;
    parse-csv)          cmd_parse_csv ;;
    parse-cpu)          cmd_parse_cpu ;;
    make-pivot)         cmd_make_pivot ;;
    make-heatmap)       cmd_make_heatmap ;;
    process)            cmd_process ;;
    doctor)             cmd_doctor ;;
    results-summary)    cmd_results_summary ;;
    all)                cmd_all "$@" ;;
    help|-h|--help)     usage ;;
    help-advanced|--help-advanced) usage_advanced ;;
    version|--version)  echo "iperf-orchestrator $ORCH_VERSION" ;;
    *)                  err "Unknown command: $cmd"; usage; exit 2 ;;
esac
