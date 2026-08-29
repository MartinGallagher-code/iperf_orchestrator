# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.0] - 2026-08-29

### Added
- **`export-overlay`.** Converts a run into the results format the
  [datacenter layout viewer](https://github.com/MartinGallagher-code/datacenter_visualization)
  paints over a `.dc` floor plan, so throughput lands on the racks that
  produced it: `mbps_out` / `mbps_in` per direction, `cpu_peak` /
  `cpu_softirq` / `cpu_idle_floor` per host, and `iperf_status` OK/FAIL.
  Writes `<run-dir>/iperf_overlay.tsv` by default. A direction that
  produced no number is exported as a `FAIL` verdict, never as 0 Mb/s —
  zero is a measurement, and averaging it in makes a broken link read as
  a slow one. Blank `cpu_summary.csv` cells are skipped for the same
  reason.
- **`--overlay` and friends.** `--overlay` also writes the overlay as part
  of `process` / `summarize` / `run` / `all`; `--overlay-out FILE` picks
  the destination (`-` for stdout, and the extension picks the format);
  `--overlay-format tsv|ndjson`; `--overlay-append` for the format's
  append-only workflow (every sample carries `run=<run-id>`);
  `--overlay-map FILE` and `--overlay-prefix STR` for when the server
  list and the floor plan name hosts differently; `--overlay-reduce` for
  one median sample per host per test; `--overlay-no-meta`.

## [2.1.0] - 2026-08-19

### Added
- **A plan file and `gen`.** `gen` writes `iperf_plan.conf` — the host
  list plus every setting for a run in one artifact, mirroring
  matrix_orchestrator's `matrix.csv`. Every command reads it (from
  `./iperf_plan.conf`, `--plan FILE`, or `$IPERF_PLAN`), so no flag needs
  repeating and a run is reproducible from the one file. The plan doubles
  as the server list; precedence is `CLI flag > env var > plan > default`,
  and re-running `gen` preserves settings you don't override. A `mode=`
  key (new `IPERF_MODE` env var) sets the default run mode.
- **The mx-style verb surface.** `start` (start-servers + run-tests),
  `summarize` (process + pivot + results-summary), `stop` (stop-servers
  with next-step breadcrumbs), `clean` (stop + remove `$REMOTE_DIR`
  everywhere, then *verify* nothing is left — no `--yes` needed), and
  `run` (`all` + results-summary, with `--for N` pinning total-time in
  rolling mode or per-test duration otherwise). Every step command still
  exists unchanged; the front-page help now leads with the six-verb
  workflow and `--help-advanced` carries the full surface.
- **`hints`.** A goal → command cheatsheet ("what is each link's true
  maximum?", "does the fabric degrade under load?"), sized to the fleet
  when a server list or plan is at hand: directed-test counts and
  wall-clock estimates per mode.
- **Partial-mesh pair grids.** `gen --grid` writes the hosts as an
  mx-style `src\dst` grid instead of a plain list: rows send, columns
  receive, a non-empty cell tests that directed pair, and blanking a
  cell skips it — matrix.csv's editing model. Every mode honors the
  grid (parallel and sequential filter their targets; rolling restricts
  each host's peer set, and a receive-only host still runs its CPU
  sampler), `status` shows each host's own expected test count, `hints`
  sizes its estimates from the enabled edges, and re-running `gen` on a
  grid plan preserves hand-blanked cells. Plain host lists and
  `servers.txt` files keep meaning full mesh everywhere.
- **`status --watch SECONDS`.** Clears and redraws the whole status
  view (probes, daemons, live progress) every SECONDS until ctrl-c,
  mirroring `mx status --watch`.
- **Live progress in `status`.** One ticker line per host for the active
  run (or `--run-id`), read from each host's own remote status file and
  per-test log count: `DONE 22/22 tests`, `RUNNING 7/22 tests` with the
  pair currently under test, `NOT-STARTED`, or `UNREACHABLE`. Works from
  a second terminal while `run-tests` blocks in the first.
- **What-next hints in `results-summary`.** After the percentile stats,
  the summary now says what the numbers mean and which command to run
  next: a below-half-median direction points at `run sequential-pair`
  isolation, a uniform mesh suggests raising the load with
  `--host-flows`/`--streams`, and hosts whose CPU peaked ≥ 85% during
  the test are flagged as possibly CPU-bound (joined from
  `cpu_summary.csv`).
- **Read the Docs integration.** `.readthedocs.yaml` and a Sphinx
  project under `docs/` publish the documentation as a searchable
  site. The version number is unchanged: nothing here ships in the
  wheel, and the tool itself is untouched.

  The site carries no prose of its own. Every page pulls its body out
  of `README.md` with a MyST `include` directive, sliced on invisible
  `<!-- docs:* -->` HTML comments above each section, so there is one
  copy of the text and the site cannot drift from the repository;
  `CHANGELOG.md` and `PUBLISHING.md` are included whole. `conf.py`
  scrapes `__version__` with a regex instead of importing the package,
  which would have dragged numpy and matplotlib into the docs build.

  Two things keep the arrangement from rotting. `tests/test_docs_sources.sh`
  (8 tests, no Sphinx needed) fails when a README section grows no
  marker, when a marker reaches no page, when an include names a marker
  that no longer exists, or when a page is missing from the toctree. A
  new `docs` CI job builds the site with `-W`, the same fail-on-warning
  setting Read the Docs uses, so a broken include fails the pull
  request rather than the post-merge build.
- A `## Documentation` section in the README covering the marker
  convention and how to build the site locally.

### Changed
- The completions (bash + zsh) and the README's configuration table
  caught up with the real CLI: retired names (`init`, `--parallel`/
  `IPERF_PARALLEL`, `--jobs`/`IPERF_JOBS`, `--flows`/`IPERF_FLOWS`,
  `--retries`, `--iperf-dir`, `status --json`, `--resume`) are gone,
  today's flags (`--streams`, `--ssh-jobs`, `--host-flows`, the iperf2
  performance knobs, `--plan`, `--for`, `--grid`, `--watch`) are in,
  and the documented `--ssh-jobs` default now matches the derived
  4×cores-capped-at-32 behavior.
- The pip wrapper no longer auto-points
  `IPERF_SERVERS` at `./servers.txt` when `./iperf_plan.conf` exists, so
  the plan's host list is not silently overridden.
- The README's `LICENSE` link is now an absolute URL. As a repo-relative
  link it resolved on GitHub but pointed at nothing once the same text
  was rendered on the docs site.

### Removed
- **`merge.sh` and `split.sh`.** The canonical copies live in
  [shared_tools](https://github.com/MartinGallagher-code/shared_tools) under
  `scripts/`, and every repository now uses those rather than keeping its
  own. Carrying a private copy is exactly how the two that once existed
  drifted apart: this repository's pair had been hardened to the v2 bundle
  format while other repositories still shipped the original 26-line
  version, and shared_tools has since moved on to v3.

  The interface differs, so this is a change and not just a move: the copy
  removed here took `-n PARTS` and produced `bundle.part1of2.txt`, while the
  canonical version takes `-m SIZE` and names parts `bundle-part1-of-N.txt`.
  A size limit is the more useful knob — the constraint is nearly always
  "the upload is refused above N bytes" rather than a part count — but any
  script using `-n` needs updating. The "Utility scripts" section of the
  README now documents the canonical interface.

  Nothing automated referenced either script, and `bundle.txt` stays
  gitignored and rebuilt on demand.

## [2.0.0] - 2026-08-12

### Removed
- **The matrix agent has moved to its own repository and tool.** The
  sustained-load emulator (`matrix_agent/matrix_agent.py`, its
  `fleet.sh` driver, and the `matrix_agent/README.md` that documented
  them) is gone from this repository, along with its two test files.
  Sustained traffic-matrix emulation and one-shot mesh sweeps had
  grown into separate tools that happened to share a checkout: they
  share no code, no state, and no release cadence, and the agent's
  field-driven release rate was dragging the orchestrator's version
  number along with it.

  Concretely, this removes:
  - the `matrix-agent` console script,
  - the `iperf-orchestrator matrix ...` pass-through subcommand,
  - the `matrix_agent` package from the wheel.

  Nothing in the sweep pipeline changes: `all`, `run-tests`,
  `parse-csv`, `parse-cpu`, `make-pivot`, `make-heatmap`,
  `collect-results`, `results-summary` and every flag and environment
  variable behave exactly as in 1.6.1. Only the matrix surface is
  withdrawn, which is why this is a major version rather than a
  minor one.

  Anyone still running `iperf-orchestrator matrix ...` should pin
  `iperf-orchestrator==1.6.1` until they have switched to the new
  standalone tool.

## [1.6.1] - 2026-08-10

### Fixed
- **Large matrices left many hosts unable to reach each other.** The
  TCP accept loop treated every `OSError` as fatal and broke out.
  `accept()` raises `EMFILE` when the process runs out of file
  descriptors -- an agent holds roughly two per peer, and a 1024 soft
  limit is still the default on many distributions -- so past a few
  hundred hosts the listener exited *for the rest of the run*. Every
  peer that had not connected yet was locked out permanently, senders
  retried into a dead listener, and the mesh sat half-connected with
  nothing in the logs to explain it.

  Descriptor exhaustion (and `ECONNABORTED`/`EINTR`/`ENOBUFS`) is
  transient, so the loop now logs once and keeps accepting; because
  senders reconnect with backoff, the mesh heals by itself once
  descriptors free up. Only a genuinely dead socket ends the loop.
- **The agent now raises its own descriptor limit.** It knows its peer
  count, so at startup it lifts `RLIMIT_NOFILE` toward the hard limit
  (`peers x 2 + 64`), which needs no privileges. When the hard limit is
  too low to cover the matrix it says so, with the number it needs and
  where to change it, instead of leaving the operator to discover
  `ulimit` from missing peers.

## [1.6.0] - 2026-08-07

### Added
- **The ticker (and therefore `status`) now shows packets as well as
  bandwidth.** A small-packet workload can be pinned on packet rate
  while idle on bandwidth, so one number without the other answers half
  the question -- and `status` only ever showed Mbps:

  ```
  ts=... tx=0.6/0.6Mbps rx=0.6/0.6Mbps tx=5000pkt/s rx=4999pkt/s
         reply=4999pkt/s/20.0Mbps total=9999pkt/s/20.6Mbps flows=1 peers=1
  ```

  In request/response mode it also carries the reply rate and the
  combined request+reply totals, matching what `summarize` reports.
  UDP only: TCP has no datagram to count.
- `rr` validates `--pps`/`--send`/`--reply` as whole numbers, explains
  the per-flow vs per-host arithmetic when `--pps` is missing, and ends
  by printing the exact `status`/`summarize`/`down` commands for the run
  it just started.
- The agent warns when `--respond-bytes` is used without `--bind`: the
  listener is then on `0.0.0.0`, so on a multi-homed host the kernel can
  pick a reply source address that differs from the one the requester
  connected to, and a connected UDP socket drops those replies silently
  (`reply=0pkt/s` with everything else healthy).

## [1.5.1] - 2026-08-07

### Fixed
- **`gen --pps --payload` below the framing floor delivered half the
  packets asked for.** A datagram carries MAGIC + a name-length byte +
  the host name + an 8-byte sequence, so it cannot be smaller than
  `13 + len(name)`; the agent pads up to that. But `gen` sized the cell
  from the *requested* payload, so the token bucket paced bytes for
  packets smaller than the ones actually sent -- measured, `--pps 20000
  --payload 8` delivered 10,666 pps. Cells are now sized from the real
  datagram, with a note when the floor applies. Longer host names raise
  the floor, so an FQDN matrix pays more per packet than an IP one.

## [1.5.0] - 2026-08-07

### Added
- **`--shards N`: several agent processes per host, to scale packet
  rate past the GIL.** One agent is one Python process, and the GIL
  serialises its sends: measured, one sender thread reaches ~90k
  packets/sec and three reach ~165k, so more threads stop helping well
  short of a million. Shard *i* now carries 1/N of every cell on port
  `base+i` and talks only to shard *i* of each peer, replicating the
  whole mesh N times at 1/N the rate so both directions scale. Two
  shards took a loopback pair from ~91k to ~241k packets/sec.

  Every `fleet.sh` command covers all shards: per-shard pidfiles and
  logs, `status` reports how many are alive, `stop`/`reload` signal all
  of them, `heal` treats a host as needing repair unless *every* shard
  is up, and `collect` pulls each shard's report.

  `summarize` sums shards back into one number per host. Each process is
  averaged over the window first and the means are added -- shards tick
  on independent clocks and their rows never line up by timestamp, so
  matching them up per-tick is not possible; time-averaging first and
  summing second is the only order that treats repeated samples and
  parallel shards correctly. Rates add; loss percentages and round-trip
  times are averaged. With one report per host the result is unchanged.

  Shards occupy ports `base .. base+N-1`, so two matrix hosts sharing an
  address need at least N between their ports. The agent refuses to
  start otherwise, rather than let one host's shard silently answer its
  neighbour's traffic -- a failure that shows up as a host receiving
  from itself.

## [1.4.2] - 2026-08-07

### Fixed
- **`summarize` now says where it put the collected reports.** Since
  1.3.2 it writes windowed copies into `<reports>/.window/` rather than
  `<reports>/`, so that a full `collect` archive is never overwritten --
  but that left `<reports>/` empty after a `summarize`, with nothing on
  screen to explain why. It now names the directory it wrote to and
  points at `collect` for full reports.

## [1.4.1] - 2026-08-07

### Added
- **Per-host packet rates in `summarize`.** The rx rows have carried
  `pps=` since 1.2.0, but the summary only ever totalled them across the
  fleet, so "how many packets is each server receiving?" meant reading
  the CSVs by hand. The per-host table now ends in a `pkt/s in|out`
  column. Both directions are receiver-side, matching the Mbps columns
  either side of them: a host's "out" packet rate is what its peers
  actually received from it, not what it claims to have sent. The column
  appears only in UDP mode -- TCP has no datagram to count, and printing
  zeros there would read as "no packets arriving".

## [1.4.0] - 2026-08-07

### Added
- **`fleet.sh heal` — repair a partial `up`.** It probes every host and
  deploys + starts only the ones without a live agent. `up` was already
  safe to repeat (`start` is pidfile-guarded, so a live agent is left
  alone), but it still re-deployed to every host — the slow part, and
  the part that competes with traffic the healthy agents are carrying.
  `heal` touches nothing that is already running: no scp, no start, no
  disturbance.

  A host that cannot be reached at all counts as needing work rather
  than as healthy, so a fleet where `up` failed on a few hosts is
  repaired by re-running `heal` until it reports nothing to do. If the
  repair itself then fails, that is reported and exits nonzero as
  usual. With `--bind`, the address map is still resolved over the full
  host list before narrowing — every agent needs an endpoint for every
  peer, not just for the hosts being repaired.

## [1.3.4] - 2026-08-07

### Fixed
- **`--bind` now puts the traffic on the bound NIC, not just its source
  address.** It pinned the sender's source address and the listeners,
  but the *destination* still came from the matrix — which is also the
  address `fleet.sh` SSHes to. When the bound device's address differs
  from the login address (separate management and data networks, the
  normal case) that produced traffic sourced from the data NIC and
  aimed at the management IP: senders showed `flows=N` with `tx=0.0`
  and every receiver showed `peers=0`, with nothing on the wire.

  `fleet.sh` now resolves each host's address *on the bound device* over
  the control path — using the same `ip -o -4 addr show` substring match
  the agent's own `--bind` uses — and hands the whole map to every
  agent. Senders connect to, and listeners accept on, the bound NIC.
  The matrix keeps the login addresses, so ssh/scp, host identity,
  `status` and `collect` are untouched. A `--bind` that matches no
  interface on some host now fails the run rather than silently falling
  back to the login address and recreating the bug. Nothing changes
  when `--bind` is absent: no probe, no map, matrix addresses stay the
  endpoints.

## [1.3.3] - 2026-08-07

### Fixed
- **Re-running `up` against a busy fleet failed hosts that worked the
  first time.** Every SSH/SCP call had an 8-second connect timeout and
  no retry, so one transient miss failed the host outright. The first
  `up` runs against idle machines; the second competes with the agents
  it started — sshd needs CPU that ~2N busy threads are holding, and
  unless `--bind` puts matrix traffic on a separate NIC, the SSH
  handshake also queues behind the test traffic. Each per-host
  operation is now retried with backoff (`--retries`, default 2; every
  operation is idempotent, and `start` is pidfile-guarded so a retry
  after a dropped connection cannot launch a second agent), the connect
  timeout is configurable and defaults to 20s (`--connect-timeout`),
  and `ServerAliveInterval`/`ServerAliveCountMax` bound a session that
  survives the handshake but then stalls. `--retries 0` restores
  fail-fast, so a genuine outage is still loud.

## [1.3.2] - 2026-08-07

### Fixed
- **A stalled reporter printed impossible rates.** The agent's tick
  scheduler advanced `next_tick` by exactly one interval, so whenever
  reporting fell behind — a starved thread at high flow counts, a
  stalled disk, a suspended process — `next_tick` stayed in the past
  and the loop fired every missed slot back to back. Each catch-up tick
  divided a real byte delta (data already sitting in socket buffers) by
  a millisecond-wide window, so the ticker reported rx far above the
  offered load while tx read 0.0, and those rows went into the report
  CSV, `summarize`, and the grids. Missed slots are now skipped rather
  than replayed, and a tick arriving inside a tenth of an interval is
  dropped instead of dividing by a sliver.

### Changed
- **`summarize`'s per-host table says why `in` and `out` disagree.** The
  two sides are different reads: `in` is a host's own rx rows (its
  matrix column, always complete), while `out` is assembled from its
  *receivers'* rx rows (its matrix row, only as complete as the reports
  collected). A downed agent therefore shrinks every one of its senders'
  `out` targets, which looked like an asymmetric matrix. Each side now
  carries the number of peers behind it, the header states how many
  hosts reported, and a note names hosts that never reported or flags
  targets that disagree with full coverage. A zero target prints `n/a`
  instead of a healthy-looking `100%`.
- **`summarize` no longer gets slower the longer the run lasts.**
  Reports append one row per flow per direction per interval for the
  life of the run, but only the last `--window` seconds are ever used;
  `fleet.sh summarize` was copying every report whole and parsing it
  from byte zero, so a fleet that had been up for hours spent minutes
  fetching megabytes to read the last minute. It now pulls a bounded
  tail sized from `--window` and the host count (override with
  `--tail-bytes`, `0` for the old whole-file behavior), into
  `<reports>/.window/` so an archived `collect` is never overwritten.
  `matrix_agent.py summarize --tail-bytes N` does the same by seeking,
  for direct use on archived reports, and warns when the tail is too
  small to cover the requested window rather than quietly reporting
  less time than asked for.

## [1.3.1] - 2026-08-07

### Changed
- `--version` (and the `version` subcommand) now print the copyright
  holder, license, and warranty notice in the conventional GNU layout.
  The program name and version stay alone on the first line, so anything
  parsing the version keeps working. A test pins the copyright line to
  the script's own file header so the two cannot drift.

### Fixed
- **Pivot and heatmap cells could exceed line rate**, reporting bandwidth
  that never existed. Each cell was `sum(mbps × duration) / run_wall_time`,
  where the wall clock came from parsing iperf2's own CSV timestamps. When
  those timestamps were absent or unparseable the divisor collapsed to a
  single test's duration, so every repeated probe of a pair was added as
  if it had run concurrently — a rolling run of four ~40 Gbps probes
  reported ~161 Gbps on a 200 Gbps NIC.

  Cells are now aggregated from the timing evidence itself: a cell's rows
  are clustered by *overlapping test windows*, summed within a cluster
  (those flows genuinely ran at once, e.g. `--host-flows`), and averaged
  across clusters (those are repeated probes). With no usable start times
  the fallback is the mean — summing is never the fallback. This also
  fixes rolling and sequential modes under-reporting when the divisor was
  the whole run instead of the measurement window.
- `parse-csv` now emits `test_start`, the epoch the generated run script
  stamps immediately before invoking iperf. Overlap is decided from our
  own clock, so the analysis no longer depends on iperf2's CSV timestamp
  format. Appended last, so no existing column position shifts.

## [1.3.0] - 2026-08-05

### Added
- **`fleet.sh rr` — one-command request/response runs**: give it
  `--hosts`, `--pps`, `--send`, `--reply` and it computes the rate from
  the pps math, generates the matrix, stops any running agents, and
  restarts the fleet in UDP request/response mode.
- `gen --pps N --payload B` sizes matrix cells by packet rate instead of
  bandwidth.
- `summarize` reports the transactional picture directly: a packets line
  with requests offered/delivered, replies returned (packets **and**
  bytes — both directions count in both totals), answered %, sampled
  RTT, and combined totals; worst flows are annotated with `resp=` and
  `rtt=`. Reply bandwidth is now measured (`resp_mbps=` on tx rows), not
  inferred.

## [1.2.0] - 2026-08-05

### Added
- **UDP request/response mode**: `matrix_agent.py run --respond-bytes N`
  answers every received request datagram with an N-byte reply to its
  sender; the requester's tx rows gain `resp_pct=` (fraction of requests
  answered) and `rtt_ms=` (sampled request→reply round trip). Small
  requests with bigger replies emulate RPC/query-shaped workloads.
- Packet-rate visibility: UDP tx and rx report rows now carry `pps=`.

## [1.1.2] - 2026-08-04

### Fixed
- **Rates above ~17.2 Gbps per flow killed every sender thread.** The
  kernel-pacing call passed `SO_MAX_PACING_RATE` a bare Python int;
  past 2^31-1 bytes/sec CPython retries the argument as a buffer and
  raises `TypeError: a bytes-like object is required, not 'int'`, which
  escaped the sender loop right after connect — before the identity
  header was sent, so receivers counted nothing (`peers=0` fleet-wide)
  while `flows=` still listed the dead senders. The value is now packed
  as an explicit u32, clamped at ~34 Gbps (the app-level token bucket
  still paces the average above that).
- A sender thread that dies now prints `FLOW DIED src -> dst: <error>`
  to the agent log instead of leaving only a buried thread traceback.

## [1.1.1] - 2026-08-04

### Fixed
- **`fleet.sh` never actually started any agents.** Remote liveness checks
  used `pgrep -f 'matrix_agent.py run'`, but the ssh-spawned shell's own
  command line contains that string (it includes the launch command), so
  every `start`/`up` matched itself, reported "already running", and
  launched nothing — `status` then showed a bare "running" and
  `collect`/`summarize` failed with "No such file or directory" on every
  host. Liveness and signaling now go through `$REMOTE_DIR/agent.pid`,
  which cannot alias. A regression test executes the remote command
  strings for real and requires an agent to launch and to die on `stop`.

## [1.1.0] - 2026-08-04

### Added
- `matrix_agent/fleet.sh`: one-command fleet operations for matrix_agent
  (`up`, `status`, `reload`, `summarize`, `down`, `prep`). All SSH/SCP
  fan-out is internal, with bounded concurrency and per-host failure
  reporting; the host list comes from the matrix header via the new
  `matrix_agent.py hosts` subcommand, so the matrix file is the single
  source of truth.
- `iperf-orchestrator matrix <cmd>`: the orchestrator now forwards a
  `matrix` subcommand to `matrix_agent/fleet.sh` (source checkouts only),
  so both the sweep and the sustained-load tooling share one front door.
  Dispatched ahead of the global flag parser so fleet flags like
  `--matrix` pass through untouched.
- `--version` flag (and `version` subcommand) that prints the program name
  and version.
- The no-args quick-start banner now points at `--help` and `--version`.
- `tests/check_python_compat.sh`, which extracts the Python embedded in
  `iperf_orchestrator.sh` heredocs and byte-compiles it, so the supported
  interpreter floor is actually enforced rather than just declared.
- CI job that scans for post-3.6 syntax and stdlib APIs (`vermin`) and runs
  the suite under a real Python 3.6 container.
- `matrix_agent/`: a stdlib-only Python agent that *sustains* an all-to-all
  traffic matrix indefinitely (paced flows to every peer at prescribed
  rates, receiver-side achieved-rate reporting), for load emulation at
  scales where a full-mesh iperf sweep is impractical. Includes matrix
  generation, admissibility checking, and report summarization; see
  `matrix_agent/README.md`.
- matrix_agent works with bare-IP host lists: a plain address (optionally
  `ip:port`) is a complete host token, and a directly-invoked agent
  identifies its own matrix row by matching addresses against local
  interfaces, so `--hostname` is unnecessary for IP matrices (ambiguity
  still demands it explicitly).
- `matrix_agent.py run --bind SPEC` (and `fleet.sh --bind`, forwarded to
  every agent) pins matrix traffic to one NIC with the exact semantics of
  `iperf-orchestrator --bind`: substring match against
  `ip -o -4 addr show` (interface name or address), `IPERF_BIND`
  environment variable honored. Binds sender source addresses and both
  listeners.
- `matrix_agent.py summarize --grid DIR` (and `fleet.sh --grid`) writes
  the window aggregate as achieved/deficit N×N grid CSVs plus an
  orchestrator-format `iperf_results.csv`, so `make-pivot` and
  `make-heatmap` render matrix runs exactly like a sweep.
- `summarize` prints a per-host table between the fleet aggregate and the
  worst flows: rx in / tx out totals (achieved/target), worst hosts
  first, both directions from receiver-side counters (`--top-hosts`).

### Added
- `merge.sh -n PARTS` splits the bundle over several files
  (`bundle.part1of2.txt`, …) for transports that cap the size of a single
  file. Parts are cut on entry boundaries and balanced by byte size, so each
  one is a complete, independently valid bundle that `split.sh` expands in
  any order into the same destination.

### Changed
- **Lowered the supported Python floor to 3.6** (`requires-python = ">=3.6"`),
  so the orchestrator host can be a stock RHEL/CentOS 8 or Ubuntu 18.04 box
  using its system interpreter. Required two changes: the pip wrapper no
  longer uses `from __future__ import annotations` (3.7+) or PEP 585/604
  annotations, and `results-summary` uses `statistics.mean` instead of
  `statistics.fmean` (3.8+).

  This supersedes the unreleased 3.9 floor, which briefly raised the minimum
  on the way to this release. The motivation there — that a declared floor CI
  never runs is not a real floor — is kept and extended: the version matrix
  below still runs, and the floor itself is now exercised too.
- CI runs the bash test suite against every Python the hosted runners provide
  (3.9 through 3.13) instead of only 3.12, and additionally exercises the 3.6
  floor in a container, so the declared minimum is verified rather than
  assumed.
- `merge.sh` / `split.sh` replaced with the hardened v2 bundle format shared
  with the meridian_commander project: per-file sha256 verified on expansion,
  preserved permissions, symlinks, empty directories and missing trailing
  newlines, a header entry count that detects truncated bundles, and a
  `split.sh` that rejects absolute/`..` paths and never passes
  bundle-controlled strings to a shell.
- `bundle.txt` is no longer committed. It is a generated snapshot of the tree,
  now gitignored and rebuilt on demand with `./merge.sh`.

### Fixed
- **pip installs now ship the matrix tooling.** The wheel includes the
  `matrix_agent` package (agent + `fleet.sh`), so `iperf-orchestrator
  matrix <cmd>` works out of the box, and a `matrix-agent` console command
  is installed alongside `iperf-orchestrator`. Previously `matrix` was
  source-checkout-only and a pip user hit "matrix tooling not found".
- `iperf-orchestrator matrix` no longer requires the executable bit on
  `matrix_agent/fleet.sh` (some transports and bundle splitters drop file
  modes); the pass-through execs via `bash`. Its "not found" error now
  distinguishes genuinely missing tooling, lists the paths searched, and
  explains the pip-install case with a remedy. A `matrix_agent/` directory
  placed next to the installed script is now also honored.

### Removed
- `pandas` as a declared dependency, and from the `doctor` probes. Nothing in
  the project has ever imported it; only `make-heatmap` needs third-party
  packages, and it uses `numpy` and `matplotlib`.

## [1.0.0] - 2026-07-21

First packaged release.

### Added
- **pip installable**: `pip install iperf-orchestrator` installs an
  `iperf-orchestrator` console command (and `python -m iperf_orchestrator`).
  A thin Python wrapper bundles and execs the bash orchestrator; `numpy`,
  `pandas`, and `matplotlib` are pulled in automatically for the analysis
  steps.
- When run as the installed command, results and the `servers.txt` fallback
  resolve against the current working directory instead of the install
  location.

### Changed
- The orchestrator script now lives at `iperf_orchestrator/iperf_orchestrator.sh`
  inside the package (still runnable directly from a source checkout).

### Removed
- The `ssh-setup` key-sharing capability and its password-source flags
  (`--password-file`, `--password-env`, `--ask-password`). Key-based,
  non-interactive SSH to every host is now a prerequisite you configure
  yourself (for example with `ssh-copy-id`).

[1.6.1]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.6.1
[1.6.0]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.6.0
[1.5.1]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.5.1
[1.5.0]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.5.0
[1.4.2]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.4.2
[1.4.1]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.4.1
[1.4.0]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.4.0
[1.3.4]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.3.4
[1.3.3]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.3.3
[1.3.2]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.3.2
[1.3.1]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.3.1
[1.3.0]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.3.0
[1.2.0]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.2.0
[1.1.2]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.1.2
[1.1.1]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.1.1
[1.1.0]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.1.0
[1.0.0]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.0.0
