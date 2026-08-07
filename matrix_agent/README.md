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
# 1. Host list, one token per line: name[=addr[:port]] -- bare IPs are
#    fine ('10.0.0.7', or '10.0.0.7:5299' with a port); the address then
#    doubles as the name throughout.
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

# 4. Deploy + start everywhere. fleet.sh reads the host list from the
#    matrix header -- there is no separate inventory to keep in sync.
./fleet.sh --matrix matrix.csv up

# 5. Watch and aggregate
./fleet.sh --matrix matrix.csv status | sort
./fleet.sh --matrix matrix.csv summarize        # collects CSVs, prints deficits

# 6. Change rates live, or tear down
vi matrix.csv && ./fleet.sh --matrix matrix.csv reload
./fleet.sh --matrix matrix.csv down
```

`fleet.sh` hides all the SSH fan-out (bounded concurrency, per-host
failure reporting, `--user`/`--remote-dir`/`--jobs` knobs, `prep` to set
the `fq` qdisc fleet-wide). `--jobs N` (env `MXA_JOBS`, default 64) is
how many hosts are contacted at once — raise it for large fleets, lower
it if the driver box or a bastion runs out of connections. It bounds
SSH concurrency only; the traffic's own concurrency is the matrix shape.

`summarize` only reads the last `--window` seconds, so it fetches a
bounded tail of each report rather than the whole file — its cost is the
same after eight hours as after eight minutes. `--tail-bytes N` overrides
the size (`0` = whole file); the windowed copies land in
`<reports>/.window/`, leaving anything `collect` archived intact.

Agent flags pass through after `--`:

```bash
./fleet.sh --matrix matrix.csv up -- --protocol udp --interval 30 --mss 600
```

Each agent is started with `--hostname` pinned to its matrix name, so
identity never depends on what `gethostname()` returns on the box.
Direct single-host invocation (`./matrix_agent.py run ...`) still works
for systemd deployments — see below. When the matrix is built from IP
addresses, a directly-invoked agent doesn't need `--hostname` at all: it
finds its own row by matching the matrix addresses against its local
interface addresses (and refuses to guess if more than one matches).

### Pinning traffic to a NIC

`--bind SPEC` uses the same semantics as `iperf-orchestrator --bind`:
the spec is substring-matched against `ip -o -4 addr show`, so it
accepts an interface name (`eth1`) or an address (`192.168.50.`), and
the same `IPERF_BIND` environment variable is honored. It binds the
sender source addresses and both listeners, so all matrix traffic rides
that NIC:

```bash
./fleet.sh --matrix matrix.csv --bind eth1 up   # forwarded to every agent
./matrix_agent.py run --matrix matrix.csv --bind 192.168.50.   # direct
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
`journalctl -u matrix-agent -f` is a live fleet-health ticker (and it's
what `fleet.sh status` shows, being the last line of `agent.out`):

```
ts=1786125102 tx=1999.6/2000.0Mbps rx=1987.0/2000.0Mbps flows=1 peers=1
```

Read it as **achieved/target, for this host only, over the last
interval**:

| Field | Meaning |
|---|---|
| `tx=A/T` | what this host *sent*, summed over its outbound flows, against the sum of its matrix row. Sender-side, so it's what got queued. |
| `rx=A/T` | what this host *received*, summed over peers, against the sum of its matrix column. Receiver-side — this is the number that means something. |
| `flows` | outbound flows this agent is running: one per non-zero cell in its row (`N-1` for a full mesh of N hosts). |
| `peers` | distinct senders it has actually heard from. `peers` < `flows` means some hosts aren't reaching it. |

`tx` and `rx` targets are equal only when the matrix is symmetric. `rx`
running above target isn't a real reading — the offered load bounds it —
so treat it as a bug report; the tick-scheduling bug that caused it was
fixed in 1.3.2, so check `--version` on the agents first.

`summarize` turns collected reports into the deficit view: the fleet
aggregate, a per-host table (rx in / tx out, worst hosts first — both
directions from receiver-side counters, so a host's "out" is what its
peers actually got), and the worst flows. A dark *row* in the deficit
matrix is a sick sender, a dark *column* a sick receiver, a dark *block*
a congested leaf pair.

### Sweep-style views (pivot table, heatmap)

`summarize --grid DIR` additionally writes the window aggregate as
files the sweep tooling reads:

- `achieved_grid.csv` / `deficit_grid.csv` — N×N grids in the traffic
  matrix's own shape (rows sources, columns destinations, Mbit/s).
- `iperf_results.csv` — the orchestrator's own results format, so
  `make-pivot` and `make-heatmap` render a matrix run exactly like a
  sweep:

```bash
iperf-orchestrator matrix --matrix matrix.csv --grid gridout summarize
iperf-orchestrator -o . --run-id gridout make-pivot
iperf-orchestrator -o . --run-id gridout make-heatmap
```

### Finding the mesh's sustainable capacity

The sweep answers "what is each pair's maximum, one pair at a time".
The matrix can answer the question the sweep can't: **how much can all
pairs carry simultaneously**. Ramp the rates until delivery stops
keeping up — no restart needed, `reload` applies rates live:

```bash
./matrix_agent.py gen --hosts hosts.txt --rate-mbps 100 -o matrix.csv
iperf-orchestrator matrix --matrix matrix.csv up
# let it settle, then check delivery:
iperf-orchestrator matrix --matrix matrix.csv summarize     # ~100%? raise it
./matrix_agent.py gen --hosts hosts.txt --rate-mbps 200 -o matrix.csv
iperf-orchestrator matrix --matrix matrix.csv reload
# repeat (or binary-search); the knee where achieved stops tracking
# target is the fabric's sustainable all-to-all capacity, and the
# deficit grid shows exactly which rows/columns/blocks gave out first.
```

Use `--protocol udp` for a hard offered-load ramp (loss shows directly
as `loss_pct`); TCP mode shares politely under overload, so the knee
shows up as widening deficit rather than loss.

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

## Packet-rate and request/response emulation

In UDP mode each datagram is one packet, so pps = rate ÷ payload:
`cell_mbps = pps × payload_bytes × 8 / 1e6`. Reports carry `pps=` on
both tx and rx rows, and `loss_pct=` shows drops — with a deliberately
small `--rcvbuf`, that's receiver overrun, which is exactly how you find
the minimum buffer that sustains a packet rate.

`--respond-bytes N` turns the mesh transactional: every request datagram
is answered with an N-byte reply to its sender, and the requester's tx
rows gain `rpps=`/`resp_pct=`/`resp_mbps=` (replies received back:
packets, fraction, bytes) and `rtt_ms=` (sampled request→reply round
trip). The one-command front door is `rr` — give it the three numbers
that define the workload and it does the rest (pps→rate math, matrix
generation, fleet restart in UDP request/response mode):

```bash
# 10,000 requests/sec per flow, minimum-size requests, 500 B replies
fleet.sh --hosts ips.txt --pps 10000 --send 30 --reply 500 rr
fleet.sh summarize
```

`summarize`'s packets line then carries the whole story — requests and
replies each count as packets, and both directions count in the bytes:

```
packets: requests 80000/s offered, 79800/s delivered; replies 79600/s /
319.4 Mbps returned (99.7% answered, rtt ~0.412 ms); total delivered
159400 pkts/s, 338.5 Mbps
```

Note on tiny packets: our framing needs ~26 bytes (name + sequence), but
anything under ~46 bytes rides the wire in Ethernet's minimum 64-byte
frame anyway — a 30-byte payload produces the same frames and pps as a
true 10-byte app packet. Matrix cells price the *request* direction;
replies add `respond/request`-ratio times that in the reverse direction,
so budget both when checking admissibility.

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
