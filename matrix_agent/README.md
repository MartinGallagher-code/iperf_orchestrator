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

**How to invoke it.** `fleet.sh` is not on `$PATH` — it ships inside the
package and is reached through the orchestrator's front door:

```bash
iperf-orchestrator matrix --matrix matrix.csv status     # installed wheel
bash matrix_agent/fleet.sh --matrix matrix.csv status    # source tree or bundle
```

The `./fleet.sh` and `./matrix_agent.py` examples below assume you are
*inside* `matrix_agent/`; anywhere else, use one of the two forms above.

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

# 4b. If `up` failed on a few hosts, repair just those -- live agents
#     are never touched or re-deployed to. Repeat until it says there is
#     nothing to do.
./fleet.sh --matrix matrix.csv heal

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

Re-running a command against a fleet that is *already under load* is a
different proposition from the first run: sshd competes for CPU with
~2N busy agent threads, and unless `--bind` puts matrix traffic on a
separate NIC, the SSH handshake queues behind the test traffic too. So
per-host operations are retried with backoff (`--retries`, default 2)
and the connect timeout is 20s (`--connect-timeout`). Every operation
is idempotent — `start` in particular is pidfile-guarded, so a retry
after a dropped connection reports "already running" rather than
launching a second agent. Use `--retries 0` for fail-fast when you want
a genuine outage to be loud immediately.

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

### Pinning traffic to a NIC (when the data network isn't the login network)

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

**The bound device's address does not have to be the address you log in
to.** Through `fleet.sh`, `--bind` covers both ends: it resolves each
host's address *on that device* over SSH (same substring match, run
remotely) and gives every agent the resulting map, so senders connect
to the data addresses and listeners accept on them. The matrix keeps
the login addresses, so `status`, `collect` and host identity are
unchanged. One flag, two networks:

```bash
# matrix.csv holds management IPs; all traffic rides eth1's network
./fleet.sh --matrix matrix.csv --bind eth1 up
```

This matters because binding only the *source* would aim data-NIC
traffic at management IPs — which shows up as `flows=N` with `tx=0.0`
on senders and `peers=0` everywhere, and is easy to misread as a fabric
fault. If `--bind` matches no interface on some host the run stops
rather than quietly falling back. Direct `matrix_agent.py run` has no
control path to resolve peers over, so there you still pass endpoints
yourself with `--map`.

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

The two halves of the per-host table are **not symmetric reads**, and
this trips people up when the targets disagree:

- **`in`** is the host's own rx rows — the sum of its matrix **column**.
  Always complete, because the host reported it itself.
- **`out`** is assembled from its *receivers'* rx rows — the sum of its
  matrix **row**, but only over receivers whose reports were collected.

So `in 46451/100000` next to `out .../25000` on a uniform matrix does
not mean the matrix is lopsided; it means only 3 of that host's 12
receivers reported. The `[n]` after each side is how many peers went
into it (expect `N-1`), the header says how many hosts reported, and
summarize names any host that never reported. An `out` count *above*
`N-1` means extra reports are being counted — stale agents from an
earlier run, or old `*_agent.csv` still sitting in the reports
directory. A target of zero prints `n/a`, not `100%`.

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

## Scaling packet rate past one process (`--shards`)

A single agent is one Python process, and the GIL serialises its sends:
measured, one sender thread reaches ~90k packets/sec and three reach
~165k — sublinear, and it does not get much better with more threads.
So high packet rates need more *processes*, not more threads.

`--shards N` runs N agents per host. Shard *i* carries **1/N of every
cell** on port `base+i` and talks only to shard *i* of each peer, so the
whole mesh is replicated N times at 1/N the rate and both directions
scale. Measured on loopback, 2 shards took a pair from ~91k to ~241k
packets/sec.

```bash
./fleet.sh --matrix matrix.csv --shards 4 up      # 4 agents per host
./fleet.sh --matrix matrix.csv --shards 4 status  # "shards 4/4" per host
./fleet.sh --matrix matrix.csv --shards 4 summarize
```

Every command covers all shards: `status` reports how many are alive,
`stop` and `reload` signal all of them, `heal` treats a host as needing
repair unless *every* shard is up, and `collect` pulls each shard's
report. Pass the same `--shards` to every command — it is how fleet.sh
knows how many processes to expect.

`summarize` sums shards back into one number per host. It averages each
process over the window first and adds the means, because shards tick on
independent clocks and their rows never line up by timestamp — repeated
samples average, parallel shards add.

**Ports:** shards occupy `base .. base+N-1`, so two hosts sharing an
address need at least N between their matrix ports. The agent refuses to
start rather than let one host's shard answer its neighbour's traffic.
Distinct hosts on distinct addresses are unaffected.

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

`summarize`'s per-host table ends in a `pkt/s in|out` column in UDP
mode, so per-server packet rates need no CSV digging. Both sides are
receiver-side, like the Mbps columns: a host's "out" is what its peers
actually received from it. A low `in` beside a healthy `out` on the same
host is a receive-side problem — buffer overrun, a starved reader, or a
congested ingress — not a sender that stopped.

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

Note on the smallest usable payload: a datagram carries MAGIC + a
name-length byte + the host name + an 8-byte sequence, so it cannot be
smaller than `13 + len(name)` -- 21 bytes for `10.0.0.7`, more for an
FQDN. `gen --pps` sizes cells from that real floor rather than from a
smaller requested `--payload`, and says so; before that, `--pps 20000
--payload 8` quietly delivered 10,666 pps, because the flow was paced
in bytes for packets half the size of the ones actually sent.

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

The agent lifts its own **soft** descriptor limit at startup to
`peers x 2 + 64`, so most fleets need nothing. Where the **hard** limit
is lower than that it prints the number it needs and where to raise it
— take that seriously at scale: running out of descriptors is what
makes a large mesh look half-connected, because `accept()` starts
failing while everything else keeps running.

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
