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
#   heal        repair a partial up: probe every host and deploy+start
#               ONLY the ones without a live agent. Live agents are never
#               touched or re-deployed to, so it is cheap to repeat and
#               safe to run against a fleet already carrying traffic.
#   rr          request/response run in one shot: builds the matrix from
#               --hosts/--pps/--send, restarts the fleet in UDP mode with
#               --send-sized requests answered by --reply-sized replies
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
#   --retries N        retries per host, backed off [MXA_RETRIES, 2]
#   --connect-timeout SECONDS
#                      ssh connect timeout. Raise both of these when
#                      re-running against a fleet already under load:
#                      sshd competes with the agents for CPU, and unless
#                      --bind separates them, with the NIC too.
#                                          [MXA_CONNECT_TIMEOUT, 20]
#   --user USER        SSH user                     [SSH_USER]
#   --remote-dir DIR   working dir on hosts         [MXA_REMOTE_DIR, /var/tmp/mxa]
#   --reports DIR      local dir for collected CSVs [MXA_REPORTS, ./reports]
#   --python BIN       remote python                [MXA_PYTHON, python3]
#   --nic DEV          NIC for `prep`               [MXA_NIC]
#   --bind SPEC        put ALL matrix traffic on one NIC: interface name
#                      or address, substring-matched against
#                      `ip -o -4 addr show` (iperf-orchestrator
#                      semantics). Each host's address on that device is
#                      resolved over ssh, so senders transmit from AND
#                      connect to it, and listeners accept on it -- the
#                      data network can differ from the login network.
#                      The matrix keeps the login addresses. [IPERF_BIND]
#   --window SECONDS   summarize window             [60]
#   --tail-bytes N     bytes of each report summarize pulls (0 = whole
#                      file). Default is sized from --window and the host
#                      count, so summarize costs the same after eight
#                      hours as after eight minutes.
#   --grid DIR         summarize also writes achieved/deficit grids and
#                      an iperf_results.csv for make-pivot/make-heatmap
#   --hosts FILE       (rr) server list, one IP/name per line
#   --pps N            (rr) request packets/sec per flow
#   --send BYTES       (rr) request datagram size    [30]
#   --reply BYTES      (rr) reply datagram size      [0 = no replies]
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
BIND="${IPERF_BIND:-}"
WINDOW=60
TAIL_BYTES="${MXA_TAIL_BYTES:-}"
WORK_DIR=""
GRID=""
HOSTS_FILE=""
PPS=""
SEND=30
REPLY=0
CONNECT_TIMEOUT="${MXA_CONNECT_TIMEOUT:-20}"
RETRIES="${MXA_RETRIES:-2}"
SSH_OPTS=()   # built after option parsing, from CONNECT_TIMEOUT

log()  { echo "[fleet] $*"; }
warn() { echo "[fleet] WARN: $*" >&2; }
die()  { echo "[fleet] ERROR: $*" >&2; exit 1; }

usage() { sed -n '9,66p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

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
        --bind)       BIND="$2"; shift 2 ;;
        --window)     WINDOW="$2"; shift 2 ;;
        --tail-bytes) TAIL_BYTES="$2"; shift 2 ;;
        --connect-timeout) CONNECT_TIMEOUT="$2"; shift 2 ;;
        --retries)    RETRIES="$2"; shift 2 ;;
        --grid)       GRID="$2"; shift 2 ;;
        --hosts)      HOSTS_FILE="$2"; shift 2 ;;
        --pps)        PPS="$2"; shift 2 ;;
        --send)       SEND="$2"; shift 2 ;;
        --reply)      REPLY="$2"; shift 2 ;;
        -h|--help)    usage 0 ;;
        --)           shift; AGENT_FLAGS=("$@"); break ;;
        -*)           die "unknown option: $1 (see --help)" ;;
        *)  if [ -z "$CMD" ]; then CMD="$1"; shift; else die "unexpected argument: $1"; fi ;;
    esac
done
[ -n "$CMD" ] || usage 1

# ServerAlive* so a session that survives the handshake but then stalls
# behind test traffic fails in bounded time instead of hanging the run.
SSH_OPTS=(-o BatchMode=yes -o "ConnectTimeout=$CONNECT_TIMEOUT"
          -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

# rr builds its own matrix before the host list is read from it.
if [ "$CMD" = "rr" ]; then
    [ -n "$HOSTS_FILE" ] || die "rr needs --hosts <file> (one IP/name per line)"
    [ -f "$HOSTS_FILE" ] || die "hosts file not found: $HOSTS_FILE"
    [ -n "$PPS" ] || die "rr needs --pps <request packets/sec per flow>"
    python3 "$AGENT" gen --hosts "$HOSTS_FILE" --pps "$PPS" --payload "$SEND" \
        -o "$MATRIX" || die "matrix generation failed"
    AGENT_FLAGS=(--protocol udp --udp-payload "$SEND" \
                 ${REPLY:+--respond-bytes "$REPLY"} "${AGENT_FLAGS[@]}")
fi

[ -f "$MATRIX" ] || die "matrix not found: $MATRIX (--matrix)"

# Host list straight from the matrix header: "name addr port" per line.
HOST_LINES=()
while IFS= read -r line; do
    [ -n "$line" ] && HOST_LINES+=("$line")
done < <(python3 "$AGENT" hosts --matrix "$MATRIX")
[ "${#HOST_LINES[@]}" -ge 1 ] || die "no hosts in $MATRIX"

# How much of each report summarize needs to see. Reports grow for the
# life of the run (one row per flow per direction per interval), but only
# the last --window seconds are ever used, so copying and parsing from
# byte zero makes every summary slower than the one before it. Size the
# tail from the window instead: rows arrive at peers x 2 / interval per
# second at ~100 bytes each; assume a 5s interval floor, double it for
# margin, and clamp. `--tail-bytes 0` restores whole-file collection.
if [ -z "$TAIL_BYTES" ]; then
    _peers=$(( ${#HOST_LINES[@]} - 1 )); [ "$_peers" -lt 1 ] && _peers=1
    TAIL_BYTES=$(( WINDOW * _peers * 2 * 100 * 2 / 5 ))
    [ "$TAIL_BYTES" -lt 1048576 ]  && TAIL_BYTES=1048576
    [ "$TAIL_BYTES" -gt 33554432 ] && TAIL_BYTES=33554432
fi

_target() { # addr -> [user@]addr for ssh/scp
    if [ -n "$SSH_USER" ]; then echo "$SSH_USER@$1"; else echo "$1"; fi
}

# Retry one host's operation with backoff.
#
# The failure this exists for: re-running `up` on a fleet that is
# already pushing line rate. The first `up` ran against idle hosts; the
# second competes with the agents themselves -- sshd needs CPU that ~2N
# busy threads are holding, and unless --bind puts test traffic on a
# separate NIC, the SSH handshake queues behind the test traffic. A
# connect that took milliseconds on an idle host can then miss the
# timeout, and with no retry a single transient miss failed the host.
#
# Safe to retry because every per-host operation here is idempotent:
# deploy re-copies, start is pidfile-guarded (a retry after a dropped
# connection sees "already running" rather than launching a second
# agent), stop/reload/collect likewise.
_retry() {
    local fn="$1" name="$2" addr="$3" port="$4" attempt=1 delay=2
    while :; do
        "$fn" "$name" "$addr" "$port" && return 0
        [ "$attempt" -gt "$RETRIES" ] && return 1
        echo "attempt $attempt failed; retrying in ${delay}s" >&2
        sleep "$delay"
        attempt=$(( attempt + 1 ))
        delay=$(( delay * 2 ))
    done
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
          if ! _retry "$fn" "$1" "$2" "$3" 2>&1 | sed "s/^/[$1] /"; then
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

# Liveness and signaling go through a pidfile ($REMOTE_DIR/agent.pid),
# never pgrep/pkill -f: the ssh-spawned remote shell's own command line
# contains the agent's launch string, so any pattern that matches the
# agent also matches that shell. With pgrep, every start saw itself and
# said "already running" without ever launching anything; with pkill,
# stop would signal its own wrapper. PIDs have no such aliasing.

_h_start() { local name="$1" addr="$2"
    # --hostname is passed explicitly so the agent's identity always
    # matches the matrix, whatever gethostname() returns on the box.
    local flags="" extra=""
    [ -n "$BIND" ] && printf -v flags ' --bind %q' "$BIND"
    if [ "${#AGENT_FLAGS[@]}" -gt 0 ]; then
        printf -v extra ' %q' "${AGENT_FLAGS[@]}"
        flags="$flags$extra"
    fi
    ssh "${SSH_OPTS[@]}" "$(_target "$addr")" \
        "cd '$REMOTE_DIR' && if kill -0 \$(cat agent.pid 2>/dev/null) 2>/dev/null; then \
             echo 'already running'; \
         else \
             nohup $REMOTE_PY matrix_agent.py run --matrix '$(basename "$MATRIX")' \
                 --hostname '$name' --report-dir rep$flags \
                 > agent.out 2>&1 & echo \$! > agent.pid; disown; echo started; \
         fi"
}

_h_status() { local name="$1" addr="$2"
    ssh "${SSH_OPTS[@]}" "$(_target "$addr")" \
        "if cd '$REMOTE_DIR' 2>/dev/null \
             && kill -0 \$(cat agent.pid 2>/dev/null) 2>/dev/null; then \
             tail -n1 agent.out 2>/dev/null || echo running; \
         else echo NOT-RUNNING; fi"
}

_h_reload() { local name="$1" addr="$2"
    scp "${SSH_OPTS[@]}" -q "$MATRIX" "$(_target "$addr"):$REMOTE_DIR/" \
        && ssh "${SSH_OPTS[@]}" "$(_target "$addr")" \
            "cd '$REMOTE_DIR' && kill -HUP \$(cat agent.pid 2>/dev/null) 2>/dev/null \
                 && echo reloaded || { echo not-running >&2; exit 1; }"
}

_h_collect() { local name="$1" addr="$2"
    scp "${SSH_OPTS[@]}" -q "$(_target "$addr"):$REMOTE_DIR/rep/${name}_agent.csv" "$REPORTS/"
}

# summarize's collect: the header plus the last $TAIL_BYTES, so the cost
# is flat in run length. `tail -c` can land mid-row, hence the `tail -n
# +2` that drops the first line -- which is also why the header is sent
# separately. When the file is shorter than the tail that same +2 drops
# the file's own header, so there is never a duplicate.
#
# Writes into $WORK_DIR, not $REPORTS: a windowed copy must never
# overwrite the full report a previous `collect` archived.
#
# A slack margin over $TAIL_BYTES is fetched so the local copy is a
# strict superset of what summarize parses; that is what lets summarize
# tell "the tail didn't reach back far enough" from "the run is young"
# and warn instead of quietly reporting a short window.
_h_collect_tail() { local name="$1" addr="$2" f
    # Separate statement: `local` expands all its arguments before it
    # assigns any of them, so ${name} would be unset on the same line.
    f="$REMOTE_DIR/rep/${name}_agent.csv"
    if ssh "${SSH_OPTS[@]}" "$(_target "$addr")" \
           "f='$f'; [ -r \"\$f\" ] || exit 1; head -n1 \"\$f\"; \
            tail -c $(( TAIL_BYTES + 65536 )) \"\$f\" | tail -n +2" > "$WORK_DIR/.$name.part"; then
        mv "$WORK_DIR/.$name.part" "$WORK_DIR/${name}_agent.csv"
    else
        rm -f "$WORK_DIR/.$name.part"
        return 1
    fi
}

_h_stop() { local name="$1" addr="$2"
    ssh "${SSH_OPTS[@]}" "$(_target "$addr")" \
        "cd '$REMOTE_DIR' 2>/dev/null \
             && kill -TERM \$(cat agent.pid 2>/dev/null) 2>/dev/null \
             && { rm -f agent.pid; echo stopped; } || echo was-not-running"
}

_h_prep() { local name="$1" addr="$2"
    ssh "${SSH_OPTS[@]}" "$(_target "$addr")" \
        "sudo tc qdisc replace dev '$NIC' root fq && echo fq-set"
}

# ---- --bind: put the traffic on the bound NIC, not just its source ---------
#
# --bind alone only pins the *source* address and the listener. The
# destination still came from the matrix -- which is also the address
# fleet.sh SSHes to. When the bound device's address differs from the
# login address (separate management and data networks, the normal case)
# that produced traffic sourced from the data NIC but aimed at the
# management IP: senders showed `flows=N` with `tx=0.0`, receivers
# `peers=0`, and nothing on the wire.
#
# So resolve every host's address ON THE BOUND DEVICE over the control
# path, and hand the whole map to every agent as --map. Senders then
# connect to, and listeners accept on, the bound NIC. The matrix keeps
# the login addresses, so ssh/scp and host identity are untouched.
#
# Resolution deliberately runs the same `ip -o -4 addr show` substring
# match the agent's own --bind uses, so a spec that resolves here
# resolves identically there. When a host's bound address already equals
# its matrix address the map entry is a harmless no-op.
BINDMAP_DIR=""

_h_bindaddr() { local name="$1" addr="$2" port="$3" found
    found=$(ssh "${SSH_OPTS[@]}" "$(_target "$addr")" \
        "ip -o -4 addr show 2>/dev/null | grep -F -- '$BIND' | head -n1 \
         | awk '{print \$4}' | cut -d/ -f1")
    if [ -z "$found" ]; then
        echo "--bind '$BIND' matched no interface" >&2
        return 1
    fi
    printf '%s=%s:%s\n' "$name" "$found" "$port" > "$BINDMAP_DIR/$name"
}

# Build --map flags for every host from the bound device. Prepended to
# AGENT_FLAGS so an explicit --map after `--` still wins (later
# overrides are applied last).
_resolve_bind_map() {
    local line name mapped flags=()
    BINDMAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mxa-bindmap-XXXXXX")"
    log "resolving --bind '$BIND' to a per-host address on ${#HOST_LINES[@]} hosts"
    _fanout _h_bindaddr || die "could not resolve --bind '$BIND' on every host; \
fix the spec or pass explicit --map flags after --"
    for line in "${HOST_LINES[@]}"; do
        name="${line%% *}"
        mapped="$(cat "$BINDMAP_DIR/$name" 2>/dev/null || true)"
        [ -n "$mapped" ] || die "no bind address resolved for $name"
        flags+=(--map "$mapped")
    done
    rm -rf "$BINDMAP_DIR"
    AGENT_FLAGS=("${flags[@]}" ${AGENT_FLAGS[@]+"${AGENT_FLAGS[@]}"})
    log "traffic will use the '$BIND' address on each host; ssh still uses the matrix addresses"
}

# ---- commands --------------------------------------------------------------

# Only the commands that launch agents need the map; status/collect/stop
# talk over the control path and are unaffected. Resolution runs over the
# FULL host list, before `heal` narrows it: every agent needs an endpoint
# for every peer, not just for the hosts being repaired.
case "$CMD" in
    start|up|rr|heal) [ -n "$BIND" ] && _resolve_bind_map ;;
esac

# Narrow HOST_LINES to the hosts that do NOT have a live agent.
#
# `up` is already safe to repeat -- start is pidfile-guarded, so a live
# agent is left alone -- but it still re-deploys to every host, which is
# the slow part and the part that competes with running traffic. When an
# `up` fails on a few hosts, this repairs just those.
#
# A host that cannot be reached at all counts as needing work, not as an
# error: the probe never fails the fan-out. Healing it may still fail
# later, and that failure is reported then.
_select_not_running() {
    local probe_dir line name kept=()
    probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/mxa-probe-XXXXXX")"
    PROBE_DIR="$probe_dir"
    log "checking which of ${#HOST_LINES[@]} hosts need starting"
    _fanout _h_probe || true
    for line in "${HOST_LINES[@]}"; do
        name="${line%% *}"
        [ -f "$probe_dir/$name" ] || kept+=("$line")
    done
    rm -rf "$probe_dir"
    if [ "${#kept[@]}" -eq 0 ]; then
        log "all ${#HOST_LINES[@]} hosts already running; nothing to do"
        exit 0
    fi
    log "${#kept[@]} of ${#HOST_LINES[@]} hosts need starting: $(printf '%s ' "${kept[@]%% *}")"
    HOST_LINES=("${kept[@]}")
}

PROBE_DIR=""
_h_probe() { local name="$1" addr="$2"
    ssh "${SSH_OPTS[@]}" "$(_target "$addr")" \
        "kill -0 \$(cat '$REMOTE_DIR/agent.pid' 2>/dev/null) 2>/dev/null" \
        && touch "$PROBE_DIR/$name"
    return 0
}

case "$CMD" in
    deploy)    log "deploying agent + $MATRIX to ${#HOST_LINES[@]} hosts (jobs=$JOBS)"
               _fanout _h_deploy ;;
    start)     log "starting agents on ${#HOST_LINES[@]} hosts"
               _fanout _h_start ;;
    up)        log "deploying agent + $MATRIX to ${#HOST_LINES[@]} hosts (jobs=$JOBS)"
               _fanout _h_deploy
               log "starting agents"
               _fanout _h_start ;;
    heal)      _select_not_running
               log "deploying agent + $MATRIX to the ${#HOST_LINES[@]} that need it"
               _fanout _h_deploy
               log "starting agents"
               _fanout _h_start ;;
    rr)        log "request/response: ${PPS} req/s per flow, ${SEND}B requests, ${REPLY}B replies"
               log "stopping any running agents"
               _fanout _h_stop || true
               log "deploying agent + $MATRIX to ${#HOST_LINES[@]} hosts (jobs=$JOBS)"
               _fanout _h_deploy
               log "starting agents in request/response mode"
               _fanout _h_start
               log "watch with: summarize (packets line shows req+reply pps, answered %, rtt)" ;;
    status)    _fanout _h_status ;;
    reload)    log "pushing $MATRIX and reloading rates on ${#HOST_LINES[@]} hosts"
               _fanout _h_reload ;;
    collect)   mkdir -p "$REPORTS"
               log "collecting reports from ${#HOST_LINES[@]} hosts into $REPORTS/"
               _fanout _h_collect ;;
    summarize) if [ "$TAIL_BYTES" -gt 0 ]; then
                   WORK_DIR="$REPORTS/.window"
                   mkdir -p "$WORK_DIR"
                   log "collecting last ${TAIL_BYTES}B of each report from ${#HOST_LINES[@]} hosts"
                   _fanout _h_collect_tail || warn "summarizing what was collected anyway"
               else
                   WORK_DIR="$REPORTS"
                   mkdir -p "$WORK_DIR"
                   log "collecting reports from ${#HOST_LINES[@]} hosts into $REPORTS/"
                   _fanout _h_collect || warn "summarizing what was collected anyway"
               fi
               python3 "$AGENT" summarize "$WORK_DIR"/*_agent.csv --window "$WINDOW" \
                   --tail-bytes "$TAIL_BYTES" ${GRID:+--grid "$GRID"} ;;
    stop|down) log "stopping agents on ${#HOST_LINES[@]} hosts"
               _fanout _h_stop ;;
    prep)      [ -n "$NIC" ] || die "prep needs --nic <device>"
               log "setting fq qdisc on $NIC across ${#HOST_LINES[@]} hosts"
               _fanout _h_prep ;;
    *)         die "unknown command: $CMD (see --help)" ;;
esac
