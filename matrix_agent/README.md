<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# matrix_agent — sustained all-to-all traffic emulation

Where the orchestrator *sweeps* a mesh (test every pair once, analyze
afterwards), `matrix_agent` *sustains* one: every host holds a paced flow
to every other host at a prescribed rate, indefinitely, and reports
achieved throughput every interval. Use it to emulate an application's
expected traffic matrix and watch whether the fabric delivers it — for
an hour or for a month.

Single stdlib-only Python file, 3.6+. No iperf involved.

## Why this scales where the sweep doesn't

A sweep must saturate pairs, so its cost is O(N²·duration). The agent's
flows are **rate-limited to the matrix entry**, and at scale those rates
are small: 1000 hosts targeting 20 Gb/s egress each is ~20 Mb/s per
flow. Holding 999 paced connections in and 999 out is ~2,000 sockets per
host — routine for the kernel. Pacing is belt-and-braces: an app-level
token bucket bounds the average rate everywhere, and on Linux
`SO_MAX_PACING_RATE` smooths each flow at the kernel level (best with
the `fq` qdisc: `tc qdisc replace dev <nic> root fq`).

Receiver-side counters are the ground truth. Under congestion, sender
counters only show what TCP queued, not what the fabric delivered.

## Quick start (any two hosts, or one)

```bash
# 1. Host list, one token per line: name[=addr[:port]]
cat > hosts.txt <<EOF
hostA
hostB
EOF

# 2. Uniform matrix: every pair at 200 Mbps
./matrix_agent.py gen --hosts hosts.txt --rate-mbps 200 -o matrix.csv
#    ...or size it by per-host egress budget instead:
./matrix_agent.py gen --hosts hosts.txt --egress-gbps 16 -o matrix.csv

# 3. Sanity-check the matrix against NIC capacity BEFORE blaming the network
./matrix_agent.py check --matrix matrix.csv --egress-gbps 25 --ingress-gbps 25

# 4. Run one agent per host (copy matrix.csv + this script everywhere)
./matrix_agent.py run --matrix matrix.csv --report-dir /var/tmp/mxa
# each agent auto-identifies via gethostname(); override with --hostname

# 5. Aggregate the reports (pull the CSVs back however you like)
./matrix_agent.py summarize reports/*_agent.csv --window 60
```

The matrix is a plain grid CSV — rows are sources, columns are
destinations, cells are Mbit/s. Hand-edit it for non-uniform patterns;
`gen` is just a starting point. Send the agents `SIGHUP` to pick up rate
changes live without dropping connections.

## What the reports contain

One CSV per agent (`<host>_agent.csv`), one row per flow per interval:

```
ts,host,dir,peer,proto,target_mbps,achieved_mbps,bytes,extra
```

`dir=rx` rows are the truth (what actually arrived); `dir=tx` rows add
`reconnects=` so flapping paths stand out. In UDP mode `extra` carries
`loss_pct=` per peer, computed from sequence numbers. Each agent also
prints a one-line aggregate per interval to stdout — under systemd,
`journalctl -u matrix-agent -f` is a live fleet-health ticker.

`summarize` turns collected reports into the deficit view: aggregate
achieved vs. target and the worst flows. A dark *row* in the deficit
matrix is a sick sender, a dark *column* a sick receiver, a dark *block*
a congested leaf pair.

## Packet and buffer tuning

The rate matrix says *how much*; these knobs say *what the traffic looks
like on the wire*:

| Flag | Effect |
|---|---|
| `--udp-payload BYTES` | UDP datagram size (default 1400). Above the MTU exercises IP fragmentation; ~8900 emulates jumbo-frame apps. |
| `--mss BYTES` | `TCP_MAXSEG`: caps TCP segment size — the closest thing TCP has to packet-size control. Small values emulate chatty small-packet workloads and stress packets-per-second rather than bytes-per-second. |
| `--chunk-bytes BYTES` | Fixed application write size (default: auto-sized for ~10 writes/sec). With `--nodelay`, small chunks emulate message-oriented senders. |
| `--nodelay` | `TCP_NODELAY`: disable Nagle, so small writes hit the wire as small packets instead of coalescing. |
| `--sndbuf BYTES` / `--rcvbuf BYTES` | `SO_SNDBUF` / `SO_RCVBUF` per socket. Setting them disables kernel autotuning (and Linux doubles the value you set) — useful for emulating apps with fixed buffers or bounding memory at high flow counts. |

Example — emulate a small-message RPC-ish workload at the same rates:

```bash
./matrix_agent.py run --matrix matrix.csv --mss 600 --chunk-bytes 1200 --nodelay
```

Note the interaction with rates: constrained buffers/MSS can make a flow
*unable* to reach its target — that deficit showing up in the reports is
signal, not error.

## TCP vs UDP is a semantic choice

- `--protocol tcp` (default) emulates an **elastic** application: under
  congestion flows share politely and you measure achieved goodput.
- `--protocol udp` emulates an **inelastic** offered load: the rate
  stays fixed whether the fabric likes it or not, and you measure loss
  directly. Truer to "the app will send this much regardless".

## Running it forever

A minimal systemd unit:

```ini
[Unit]
Description=matrix_agent sustained traffic emulation
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 /opt/mxa/matrix_agent.py run \
    --matrix /opt/mxa/matrix.csv --report-dir /var/tmp/mxa --interval 10
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
LimitNOFILE=16384

[Setup]
# On each host, once:  tc qdisc replace dev <nic> root fq
```

At N=1000, raise `LimitNOFILE` (each agent holds ~2N sockets) and give
the matrix file to every host (it's ~N² cells; at 1000 hosts a few MB).

## Testing on one machine

`--map name=addr:port` overrides a host's address, so a whole "fleet"
can live on localhost ports — that's how `tests/test_matrix_agent.sh`
exercises it, and it's handy for trying a matrix shape before deploying:

```bash
./matrix_agent.py run --matrix m.csv --hostname a --map a=127.0.0.1:5221 --map b=127.0.0.1:5222 &
./matrix_agent.py run --matrix m.csv --hostname b --map a=127.0.0.1:5221 --map b=127.0.0.1:5222 &
```

## Caveats

- **Admissibility first.** If row/column sums exceed NIC capacity — or
  the fabric's oversubscribed core can't carry the aggregate — the
  emulation "fails" by design. `check` catches the NIC-level cases;
  fabric-level admissibility needs your topology and is on you.
- Rates are per-flow token buckets; aggregate per-host precision is the
  sum of per-flow precision (~±2% each at defaults, better with `fq`).
- One TCP 5-tuple rides one ECMP path. With hundreds of flows per host
  this spreads well by itself, but a *single* pair's number is one
  path's number, not the fabric's.
- Reports grow ~1 row per flow per interval; at 1000 hosts × 10s that's
  ~86 MB/host/day of CSV. Rotate or lengthen `--interval` for long runs.
