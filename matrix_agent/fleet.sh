#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
#
# fleet.sh -- drive matrix_agent across a whole fleet with one command.
# All SSH/SCP fan-out lives in here; the host list comes straight from
# the matrix header, so the matrix file is the single source of truth.
#
# Usage: fleet.sh [OPTIONS] COMMAND [-- AGENT-FLAGS...]
#
# Commands:
#   deploy      push matrix_agent.py + the matrix to every host
#   start       launch one agent per host (nohup; survives this session)
#   up          deploy + start
#   status      one line per host: latest ticker line, or NOT-RUNNING
#   reload      push the (edited) matrix and SIGHUP every agent
#   collect     pull every host's report CSV into --reports
#   summarize   collect, then print the fleet deficit summary
#   stop        SIGTERM every agent
#   down        alias for stop
#   prep        set the fq qdisc on --nic on every host (needs sudo)
#
# Options (env var equivalents in brackets):
#   --matrix FILE      traffic matrix               [MXA_MATRIX, matrix.csv]
#   --jobs N           SSH fan-out concurrency      [MXA_JOBS, 64]
#   --user USER        SSH user                     [SSH_USER]
#   --remote-dir DIR   working dir on hosts         [MXA_REMOTE_DIR, /var/tmp/mxa]
#   --reports DIR      local dir for collected CSVs [MXA_REPORTS, ./reports]
#   --python BIN       remote python                [MXA_PYTHON, python3]
#   --nic DEV          NIC for `prep`               [MXA_NIC]
#   --window SECONDS   summarize window             [60]
#
# Anything after `--` is passed to `matrix_agent.py run` verbatim, e.g.:
#   fleet.sh --matrix m.csv up -- --protocol udp --interval 30 --mss 600

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT="$SCRIPT_DIR/matrix_agent.py"

MATRIX="${MXA_MATRIX:-matrix.csv}"
JOBS="${MXA_JOBS:-64}"
REMOTE_DIR="${MXA_REMOTE_DIR:-/var/tmp/mxa}"
REPORTS="${MXA_REPORTS:-reports}"
SSH_USER="${SSH_USER:-}"
REMOTE_PY="${MXA_PYTHON:-python3}"
NIC="${MXA_NIC:-}"
WINDOW=60
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)

log()  { echo "[fleet] $*"; }
warn() { echo "[fleet] WARN: $*" >&2; }
die()  { echo "[fleet] ERROR: $*" >&2; exit 1; }

usage() { sed -n '9,37p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

AGENT_FLAGS=()
CMD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --matrix)     MATRIX="$2"; shift 2 ;;
        --jobs)       JOBS="$2"; shift 2 ;;
        --user)       SSH_USER="$2"; shift 2 ;;
        --remote-dir) REMOTE_DIR="$2"; shift 2 ;;
        --reports)    REPORTS="$2"; shift 2 ;;
        --python)     REMOTE_PY="$2"; shift 2 ;;
        --nic)        NIC="$2"; shift 2 ;;
        --window)     WINDOW="$2"; shift 2 ;;
        -h|--help)    usage 0 ;;
        --)           shift; AGENT_FLAGS=("$@"); break ;;
        -*)           die "unknown option: $1 (see --help)" ;;
        *)  if [ -z "$CMD" ]; then CMD="$1"; shift; else die "unexpected argument: $1"; fi ;;
    esac
done
[ -n "$CMD" ] || usage 1
[ -f "$MATRIX" ] || die "matrix not found: $MATRIX (--matrix)"

# Host list straight from the matrix header: "name addr port" per line.
HOST_LINES=()
while IFS= read -r line; do
    [ -n "$line" ] && HOST_LINES+=("$line")
done < <(python3 "$AGENT" hosts --matrix "$MATRIX")
[ "${#HOST_LINES[@]}" -ge 1 ] || die "no hosts in $MATRIX"

_target() { # addr -> [user@]addr for ssh/scp
    if [ -n "$SSH_USER" ]; then echo "$SSH_USER@$1"; else echo "$1"; fi
}

# Run "$fn name addr port" for every host, at most $JOBS at a time.
# Per-host output is prefixed with the host name; failures are collected
# and reported at the end, and set the exit status.
_fanout() {
    local fn="$1" faildir pids=() names=() line
    faildir="$(mktemp -d "${TMPDIR:-/tmp}/mxa-fleet-XXXXXX")"
    for line in "${HOST_LINES[@]}"; do
        while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 0.05; done
        # shellcheck disable=SC2086  -- intentional word split: name addr port
        ( set -- $line
          if ! "$fn" "$1" "$2" "$3" 2>&1 | sed "s/^/[$1] /"; then
              touch "$faildir/$1"
          fi ) &
        pids+=($!)
    done
    wait
    local fails
    fails=$(ls -1 "$faildir" 2>/dev/null | wc -l)
    if [ "$fails" -gt 0 ]; then
        warn "$fails/${#HOST_LINES[@]} hosts failed: $(ls -1 "$faildir" | head -20 | tr '\n' ' ')"
        rm -rf "$faildir"
        return 1
    fi
    rm -rf "$faildir"
    log "OK on all ${#HOST_LINES[@]} hosts"
}

# ---- per-host operations ---------------------------------------------------

_h_deploy() { local name="$1" addr="$2"
    ssh "${SSH_OPTS[@]}" "$(_target "$addr")" "mkdir -p '$REMOTE_DIR/rep'" \
        && scp "${SSH_OPTS[@]}" -q "$AGENT" "$MATRIX" "$(_target "$addr"):$REMOTE_DIR/"
}

_h_start() { local name="$1" addr="$2"
    # --hostname is passed explicitly so the agent's identity always
    # matches the matrix, whatever gethostname() returns on the box.
    local flags=""
    [ "${#AGENT_FLAGS[@]}" -gt 0 ] && printf -v flags ' %q' "${AGENT_FLAGS[@]}"
    ssh "${SSH_OPTS[@]}" "$(_target "$addr")" \
        "cd '$REMOTE_DIR' && if pgrep -f 'matrix_agent.py run' >/dev/null; then \
             echo 'already running'; \
         else \
             nohup $REMOTE_PY matrix_agent.py run --matrix '$(basename "$MATRIX")' \
                 --hostname '$name' --report-dir rep$flags \
                 > agent.out 2>&1 & disown; echo started; \
         fi"
}

_h_status() { local name="$1" addr="$2"
    ssh "${SSH_OPTS[@]}" "$(_target "$addr")" \
        "if pgrep -f 'matrix_agent.py run' >/dev/null; then \
             tail -n1 '$REMOTE_DIR/agent.out' 2>/dev/null || echo running; \
         else echo NOT-RUNNING; fi"
}

_h_reload() { local name="$1" addr="$2"
    scp "${SSH_OPTS[@]}" -q "$MATRIX" "$(_target "$addr"):$REMOTE_DIR/" \
        && ssh "${SSH_OPTS[@]}" "$(_target "$addr")" \
            "pkill -HUP -f 'matrix_agent.py run' && echo reloaded"
}

_h_collect() { local name="$1" addr="$2"
    scp "${SSH_OPTS[@]}" -q "$(_target "$addr"):$REMOTE_DIR/rep/${name}_agent.csv" "$REPORTS/"
}

_h_stop() { local name="$1" addr="$2"
    ssh "${SSH_OPTS[@]}" "$(_target "$addr")" \
        "pkill -TERM -f 'matrix_agent.py run' && echo stopped || echo was-not-running"
}

_h_prep() { local name="$1" addr="$2"
    ssh "${SSH_OPTS[@]}" "$(_target "$addr")" \
        "sudo tc qdisc replace dev '$NIC' root fq && echo fq-set"
}

# ---- commands --------------------------------------------------------------

case "$CMD" in
    deploy)    log "deploying agent + $MATRIX to ${#HOST_LINES[@]} hosts (jobs=$JOBS)"
               _fanout _h_deploy ;;
    start)     log "starting agents on ${#HOST_LINES[@]} hosts"
               _fanout _h_start ;;
    up)        log "deploying agent + $MATRIX to ${#HOST_LINES[@]} hosts (jobs=$JOBS)"
               _fanout _h_deploy
               log "starting agents"
               _fanout _h_start ;;
    status)    _fanout _h_status ;;
    reload)    log "pushing $MATRIX and reloading rates on ${#HOST_LINES[@]} hosts"
               _fanout _h_reload ;;
    collect)   mkdir -p "$REPORTS"
               log "collecting reports from ${#HOST_LINES[@]} hosts into $REPORTS/"
               _fanout _h_collect ;;
    summarize) mkdir -p "$REPORTS"
               log "collecting reports from ${#HOST_LINES[@]} hosts into $REPORTS/"
               _fanout _h_collect || warn "summarizing what was collected anyway"
               python3 "$AGENT" summarize "$REPORTS"/*_agent.csv --window "$WINDOW" ;;
    stop|down) log "stopping agents on ${#HOST_LINES[@]} hosts"
               _fanout _h_stop ;;
    prep)      [ -n "$NIC" ] || die "prep needs --nic <device>"
               log "setting fq qdisc on $NIC across ${#HOST_LINES[@]} hosts"
               _fanout _h_prep ;;
    *)         die "unknown command: $CMD (see --help)" ;;
esac
