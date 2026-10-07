# iperf-orchestrator

[![PyPI version](https://img.shields.io/pypi/v/iperf-orchestrator.svg)](https://pypi.org/project/iperf-orchestrator/)
[![Python versions](https://img.shields.io/pypi/pyversions/iperf-orchestrator.svg)](https://pypi.org/project/iperf-orchestrator/)
[![CI](https://github.com/MartinGallagher-code/iperf_orchestrator/actions/workflows/ci.yml/badge.svg)](https://github.com/MartinGallagher-code/iperf_orchestrator/actions/workflows/ci.yml)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](https://www.gnu.org/licenses/gpl-3.0.html)
[![REUSE status](https://api.reuse.software/badge/github.com/MartinGallagher-code/iperf_orchestrator)](https://api.reuse.software/info/github.com/MartinGallagher-code/iperf_orchestrator)
[![Documentation Status](https://readthedocs.org/projects/iperf-orchestrator/badge/?version=latest)](https://iperf-orchestrator.readthedocs.io/en/latest/)

A bash orchestrator for running full-mesh iperf2 throughput tests across a list of servers, collecting per-host CPU samples during the run, and producing a CSV, pivot table, and heatmap + bar chart visualization of the results.

Built primarily for **network fabric stress testing**: load every link in both directions simultaneously and find out what breaks or degrades. Also useful for one-off "is the network healthy" surveys of a fleet.

<!-- docs:end -->

📖 **Full documentation:** [iperf-orchestrator.readthedocs.io](https://iperf-orchestrator.readthedocs.io/en/latest/) — the same content as this README, split into pages and searchable.

---

<!-- docs:installation -->
## Installation

### With pip (recommended)

```bash
pip install iperf-orchestrator
```

This puts an `iperf-orchestrator` command on your PATH and installs the Python
libraries the heatmap step needs (`numpy`, `matplotlib`). Requires
`bash` and Python 3.6+ on the orchestrator host. Everywhere below, wherever you
see `./iperf_orchestrator.sh`, you can use the `iperf-orchestrator` command
instead — e.g. `iperf-orchestrator --servers servers.txt all`. `python -m
iperf_orchestrator` also works.

When run as the installed command, results are written to `./results/` in your
current working directory (and a `./servers.txt` there is picked up
automatically if you don't pass `--servers`).

### From a source checkout

The orchestrator itself is a single self-contained bash script; you can run it
directly without installing anything:

```bash
./iperf_orchestrator/iperf_orchestrator.sh --servers servers.txt all
```

The analysis steps need Python 3.6+. Only `make-heatmap` needs third-party
packages (`numpy` and `matplotlib`); `make-pivot`, `parse-cpu`,
`collect-results` and `results-summary` are stdlib-only. Run `doctor` to check.

<!-- docs:end -->
---

<!-- docs:quick-start -->
## Quick Start

```bash
# 1. List your servers, one IP or hostname per line ('#' for comments)
cat > servers.txt <<EOF
10.0.0.10
10.0.0.11
10.0.0.12
10.0.0.13
EOF

# 2. Make sure key-based SSH to every host is already set up, e.g.
#    for h in $(grep -v '^#' servers.txt); do ssh-copy-id "$h"; done

# 3. Write the plan file once: hosts + every setting in one artifact.
#    Every later command reads it, so no flag needs repeating.
./iperf-orchestrator.sh gen --servers servers.txt

# 4. Run everything end-to-end (start + summarize + stop + clean)
./iperf-orchestrator.sh run
```

Or drive it step by step with the six core commands (mirroring
[`matrix_orchestrator`](https://github.com/MartinGallagher-code/matrix_orchestrator)'s
workflow):

| Command | What it does |
|---|---|
| `gen` | Build `iperf_plan.conf` from your server list — hosts + settings in one file. |
| `start` | Start the iperf2 daemons everywhere and run the tests. |
| `status` | One line per host: probes, daemons, and live test progress. |
| `summarize` | Collect results; render CSV, pivot, heatmap; print the summary and what to do next. |
| `stop` | Stop the daemons (test logs stay on the hosts). |
| `clean` | Stop, then delete the remote work dir everywhere — verified gone. |

Not sure what to ask for? `./iperf-orchestrator.sh hints` turns a goal into
the command that gets you there. The classic one-liner still works too:
`./iperf-orchestrator.sh --servers servers.txt all`.

Each invocation that produces results creates a fresh timestamped run directory under `./results/<run-id>/`, and a `./results/latest` symlink is updated to point at it. Analysis subcommands default to following `latest`; pass `--run-id <id>` to address an older run.

Results in `./results/<run-id>/`:
- `iperf_results.csv` — every test, both directions, fully parsed
- `cpu_summary.csv` — per-host CPU peaks during the run
- `iperf_pivot.txt` — text pivot table of throughput
- `iperf_heatmap.png` — heatmap + sorted bar chart with CPU annotations
- `iperf_overlay.tsv` — datacenter layout overlay samples (`export-overlay`, or `--overlay`)

<!-- docs:end -->
---

<!-- docs:requirements -->
## Requirements

### On the orchestrator host (where you run the script)
- bash 4+
- ssh, scp
- Python 3.6+ (stdlib only), plus `numpy` and `matplotlib` for the heatmap step
- tar, gzip

### On every server in the mesh
- **iperf2** (binary name `iperf`, *not* `iperf3`)
- **sysstat** providing `mpstat` (recommended) — falls back to `/proc/stat` sampling if missing
- **coreutils `timeout`** (recommended) — enforces the per-test time limit; without it a wedged client can stall its round
- **iproute2 `ip`** — only with `--bind` / `--server-bind`, which resolve their pattern against `ip -o -4 addr show`
- ssh access from the orchestrator

The script's `check-iperf` subcommand verifies both iperf2 and mpstat before you start.

### Why iperf2 and not iperf3
iperf3's server is single-threaded and accepts only one client at a time. A full mesh of N hosts would need N iperf3 servers per host on different ports just to function, plus a port-assignment scheme, plus N times the firewall holes. iperf2's multi-threaded server handles concurrent clients on a single port — one daemon per host on port 5001 and you're done.

<!-- docs:end -->
---

<!-- docs:subcommands -->
## Subcommands

Key-based SSH to every host must already be configured (the orchestrator
connects non-interactively with `BatchMode=yes`).

```
PLAN WORKFLOW (each verb reads the plan file, so flags never repeat):
  gen [MODE] [--grid]    Write iperf_plan.conf: host list + settings in one file;
                         --grid writes the hosts as a src\dst pair grid
  start [MODE] [--keep-going]
                         start-servers + run-tests in one verb
  status [--watch N]     Probes, daemons, and a live progress line per host;
                         --watch redraws every N seconds until ctrl-c
  summarize              process + pivot + results-summary (with what-next hints)
  stop                   stop-servers, plus the next steps spelled out
  clean                  stop + remove $REMOTE_DIR everywhere, then verify
  run [MODE] [--for N] [--keep-going]
                         all + results-summary; --for pins total-time (rolling)
                         or per-test duration (other modes)
  hints                  What you want to know -> the command that gets you there

SETUP:
  check-iperf            Verify iperf2 + mpstat presence on every host
  check-servers          Check which hosts have iperf -s currently running

EXECUTION:
  start-servers          Start iperf2 -s on every host (--port, default 5001)
  run-tests [MODE]       Run the tests. Auto-runs create-scripts and
                         distribute-scripts for non-rolling modes. MODE is
                         parallel | sequential-host | sequential-pair | rolling.
  collect-results        Pull logs back as a tar archive per host
  stop-servers           Kill iperf -s on every host
  cleanup --yes          Remove $REMOTE_DIR on every host

ANALYSIS:
  parse-csv              Parse iperf2 CSV logs into iperf_results.csv (2 rows per test)
  parse-cpu              Parse mpstat samples into cpu_summary.csv
  make-pivot             Text pivot table at iperf_pivot.txt
  make-heatmap           Heatmap + bar chart at iperf_heatmap.png
  process                = collect-results + parse-csv + parse-cpu + make-pivot + make-heatmap
  results-summary        P50/P95/min/mean/max throughput + 5 slowest pairs
  export-overlay         Render the run as datacenter layout viewer overlays:
                         throughput, relative-to-median, pair asymmetry,
                         per-host success rate and CPU

INTERNAL (run-tests calls these for you; available standalone if needed):
  create-scripts         Generate per-host client run scripts locally
  distribute-scripts     Push each host's script out

CONVENIENCE:
  all [MODE] [--keep-going]  Run the full sequence end-to-end
                             (start + run-tests + process + stop)
  status                     Probe hosts live + list available runs
  doctor                     Check local prerequisites
  help                       Common commands and flags (also -h, --help)
  help-advanced              Every command, every flag, every env var
                             (also --help-advanced)
  version                    Print the version and licence (also --version)
```

The orchestrator is **stateless**: nothing persists between invocations except the contents of the results directory. `status` derives state by probing hosts directly. Server lists are passed via `--servers`/`IPERF_SERVERS`/`./servers.txt` — or carried by the plan file. Each pipeline run creates a fresh `<results>/<run-id>/` directory; `<results>/latest` is updated to point at the most recent one.

### The plan file

`gen` writes a single plan file (default `./iperf_plan.conf`; `--plan FILE`
or `$IPERF_PLAN` override) that every other command reads, so a run is
reproducible from one artifact and no flag needs repeating:

```text
# iperf-orchestrator plan v1 -- one file drives every command
# mode=parallel
# port=5001 duration=10 streams=1 host_flows=1 total_time=300
# bandwidth= length= window= mss= no_nagle=0
# bind= server_bind=
# ssh_user=root remote_dir=/tmp/iperf_orchestrator
10.0.0.10
10.0.0.11
10.0.0.12
```

Hosts are plain lines (the plan doubles as the server list); settings ride
in the `key=value` tokens. Edit either by hand and just re-run. Precedence
is `CLI flag > env var > plan file > built-in default`, so a one-off
`--duration 60` still wins without touching the plan, and re-running `gen`
preserves any setting you don't override.

Three more keys are read if you add them by hand, though `gen` does not write
them: `ssh_jobs=`, `start_delay=` and `output=` (the results directory). Values
cannot contain whitespace. `--test-timeout`, `--single-server`, `--python`,
`--run-id` and the `--overlay-*` flags are per-run choices, not plan
settings: pass them (or their environment variables) each time.

**Partial mesh.** `gen --grid` writes the hosts as an mx-style pair grid
instead of a plain list — rows send, columns receive, and a non-empty cell
tests that directed pair:

```text
src\dst,10.0.0.10,10.0.0.11,10.0.0.12
10.0.0.10,,x,x
10.0.0.11,x,,x
10.0.0.12,,x,
```

Blank a cell to skip a direction (here `10.0.0.12` never sends to
`10.0.0.10`); blank both cells to drop the pair entirely. Every mode —
parallel, sequential, and rolling — honors the grid, `status` shows each
host's own expected test count, `hints` sizes its estimates from the
enabled edges, and re-running `gen` on a grid plan keeps your blanked
cells. A plain host list simply means full mesh, and plain `servers.txt`
files keep working everywhere.

### Configuration

Every setting can be supplied either as an environment variable or as a CLI flag. The CLI flag wins when both are set. Flags accept both `--flag value` and `--flag=value` forms, and may appear before the subcommand:

```bash
./iperf-orchestrator.sh --duration 60 --ssh-jobs 32 all
./iperf-orchestrator.sh -d 60 -j 32 all parallel
IPERF_DURATION=60 ./iperf-orchestrator.sh all          # env var still works
```

| Env var | Flag | Default | Purpose |
|---|---|---|---|
| `IPERF_PLAN` | `--plan` | `./iperf_plan.conf` when it exists | plan file written by `gen` |
| `IPERF_MODE` | *(plan `mode=` key)* | `parallel` | default run mode when none is passed |
| `IPERF_SERVERS` | `--servers`, `-s` | plan hosts, else `<script-dir>/servers.txt` | server list path |
| `RESULTS_BASE` | `--output`, `-o` | `<script-dir>/results` | base directory for run subdirs |
| `IPERF_RUN_ID` | `--run-id` | auto-timestamp on write; `latest` symlink on read | which run subdir to address |
| `IPERF_PORT` | `--port` | `5001` | iperf2 listening port |
| `IPERF_DURATION` | `--duration`, `-d` | `10` | seconds per test |
| `IPERF_TEST_TIMEOUT` | `--test-timeout` | `duration + 30` | hard cap per iperf -c, enforced with coreutils `timeout` on the remote host; `0` disables |
| `IPERF_SINGLE_SERVER` | `--single-server` | *(unset)* | sequential-host mode only: one all→one round against this host instead of the host-at-a-time sweep |
| `IPERF_STREAMS` | `--streams`, `-P` | `1` | parallel TCP streams within each test (iperf2 `-P`) |
| `IPERF_SSH_JOBS` | `--ssh-jobs`, `-j` | 4×cores, capped at 32 | max concurrent SSH/SCP fan-out (capped concurrency) |
| `IPERF_TOTAL_TIME` | `--total-time` | `300` | rolling mode wall-time (seconds) |
| `IPERF_HOST_FLOWS` | `--host-flows` | `1` | concurrent iperf processes per directed edge (parallel/sequential) or per-host concurrency cap (rolling) |
| `IPERF_BANDWIDTH` | `--bandwidth`, `-b` | *(unset)* | cap per-flow target rate, e.g. `100M`, `1G` (iperf2 `-b`) |
| `IPERF_LENGTH` | `--length`, `-l` | *(unset)* | TCP read/write buffer size, e.g. `128K` (iperf2 `-l`) |
| `IPERF_WINDOW` | `--window`, `-w` | *(unset)* | TCP window / socket buffer (iperf2 `-w`) |
| `IPERF_MSS` | `--mss`, `-M` | *(unset)* | TCP maximum segment size (iperf2 `-M`) |
| `IPERF_NO_NAGLE` | `--no-nagle`, `-N` | `0` | disable Nagle's algorithm (iperf2 `-N`) |
| `IPERF_BIND` | `--bind`, `-B` | *(unset)* | run the tests over the NIC matching this pattern instead of the login address (see the `--bind` section below) |
| `IPERF_SERVER_BIND` | `--server-bind` | the `--bind` pattern | bind each `iperf -s` daemon to its matching NIC too |
| `IPERF_DRY_RUN` | `--dry-run`, `-n` | `0` | print SSH/SCP commands instead of executing |
| `IPERF_VERBOSITY` | `--verbose`/`-v`, `--quiet`/`-q` | `1` | `-v` prints every ssh/scp invocation; `-q` suppresses non-WARN/ERROR logs |
| `SSH_USER` | `--ssh-user`, `-u` | `$USER` | SSH login user |
| `START_DELAY` | `--start-delay` | `30` | seconds in the future to schedule the synchronized start |
| `REMOTE_DIR` | `--remote-dir` | `/tmp/iperf_orchestrator` | remote working dir; every remote-side file embeds `<host>_<run-id>`, but `cleanup`, `clean`, `all` and `run` delete the whole directory (see **Shared-FS safety**) |
| `PYTHON_BIN` | `--python` | `python3` | Python interpreter for analysis steps |
| `SSH_OPTS` | *(env only)* | `-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=30` | options passed to every `ssh`/`scp` (`BatchMode=yes` is always added) |

The `--overlay-*` flags and their `IPERF_OVERLAY_*` variables are listed with
the overlays they control, under **Datacenter layout overlays**.

#### `--bind` and `--server-bind`: testing a separate data-plane NIC

Many fleets are reached over one interface — the management address in
`servers.txt` — and carry their real traffic on another. Without `--bind`,
every test dials the address in the server list, the kernel routes it over the
management interface, and the run measures the wrong NIC. `--bind PATTERN` puts
the traffic on the NIC you name:

```bash
./iperf-orchestrator.sh --bind mlx5 run        # by interface name
./iperf-orchestrator.sh --bind 10.20.0 run     # by address
./iperf-orchestrator.sh gen --bind mlx5        # or make it a plan setting
```

**Matching.** On each host, PATTERN is matched with `grep` against the lines
of `ip -o -4 addr show`, so it can name the interface or part of its address,
and the **first** matching line's IPv4 address is the one used. It is a basic
regular expression rather than a literal (a `.` matches any character), and a
pattern that matches more than one line silently takes the first — `eth1` also
matches `eth10`. Check a pattern on a host with
`ip -o -4 addr show | grep -- 'PATTERN'` before a large run.

**What it changes.**

- **Before any test starts**, the orchestrator SSHes to every host (over its
  login address, `--ssh-jobs` at a time) and resolves the pattern to that
  host's data-plane address. If any host has no matching interface, the run
  stops there and names those hosts, before a mesh of broken tests is launched.
- **Each client binds and dials the data plane.** Every `iperf -c` binds its
  source to its own host's matching address (`-B <ip>`) and connects to the
  *peer's* data-plane address rather than the peer's login address. Results
  are still labelled with the names from the server list; the address actually
  dialled is recorded as `conn_ip=` in each test log's header.
- **The daemons follow.** `--server-bind` defaults to the same pattern, so
  `start-servers` starts each `iperf -s` with `-B` set to that host's matching
  address, and it accepts connections only on that NIC. A connection routed the
  wrong way then fails loudly rather than quietly measuring the management
  network. A host with no matching interface fails `start-servers`. Give
  `--server-bind` its own pattern when the daemons should listen on a different
  NIC from the one the clients send from.
- **Everything else stays on the login address.** SSH, `scp`, `status`,
  `collect-results` and `cleanup` are unaffected; only iperf traffic moves.

Every mode honours it, `rolling` included. Both are plan settings (`bind=` and
`server_bind=`), so a plan written with `gen --bind PATTERN` applies it to
every later command. A pattern can go into the plan only if it contains no
whitespace.

**Where it shows up.** Each host's session log (`logs/run_<host>.log`, or
`logs/rolling_<host>.log` in rolling mode) carries a
`[bind] <host>: 'PATTERN' -> iface=… ip=…` line, and `-v` logs every peer's
resolved address. `iperf_results.csv` records the sending host's NIC in its
`bind_iface` and `bind_ip` columns, `iperf_pivot.txt` ends with a "Source
bindings" list, and `export-overlay` adds the `iperf_bind_iface` overlay, so a
floor plan shows which NIC each rack's traffic actually rode.

#### `--ssh-jobs` and capped-concurrency parallel SSH

Setup and teardown subcommands (`check-iperf`, `check-servers`, `start-servers`, `distribute-scripts`, `collect-results`, `stop-servers`, `cleanup`) fan out to all hosts in parallel, capped at `IPERF_SSH_JOBS` concurrent SSH/SCP sessions. Per-host output is captured in worker buffers and replayed in server-list order so the screen output stays readable.

The default is derived from the orchestrator host's core count (4× cores, floor 4, capped at 32), which keeps its SSH agent and the per-host sshd happy on most fleets. Bump it (e.g. `--ssh-jobs 64`) when you have hundreds of hosts and the orchestrator's CPU/network can absorb it; lower it if `MaxStartups` on your sshds rejects connections.

The actual `run-tests parallel` mode is *not* throttled by `--ssh-jobs` — it has to open one SSH session per host simultaneously to hit the synchronized start barrier. `--ssh-jobs` only caps the setup/teardown fan-outs.

#### SSH key setup

The orchestrator does not distribute SSH keys. Configure key-based, non-interactive SSH to every host before running it — for example with `ssh-copy-id`:

```bash
for h in $(grep -v '^#' servers.txt); do ssh-copy-id "$h"; done
```

Every connection uses `BatchMode=yes`, so any host still requiring a password will simply fail rather than prompt.

#### `--keep-going` for `all`, `run` and `start`

`all --keep-going` continues past per-host failures (a single host failing `start-servers` no longer aborts the whole pipeline). Without it, the first step that records per-host failures aborts the pipeline. `run` passes the flag through to `all`, and `start --keep-going` runs the tests even when some hosts failed to start their daemon.

#### `--dry-run`, `--verbose`, `--quiet`

`--dry-run` prints every SSH/SCP command without executing — useful for inspecting what `all` would do before unleashing it on a fleet. `--verbose` echoes every ssh/scp invocation as it runs; `--quiet` drops normal INFO logs and keeps only WARN/ERROR.

<!-- docs:end -->
---

<!-- docs:run-modes -->
## Run modes

`run-tests` (and therefore `all`) takes a mode argument that controls how the tests are scheduled. In the first three modes every host runs one one-way `iperf -c` against each of its peers, so a pair `{A, B}` is measured as two directed tests, A→B and B→A, each with its own log. `parallel` runs both at once, so every link carries traffic in both directions simultaneously; `sequential-pair` gives each direction a round of its own. `rolling` is structured differently (see below).

| Mode | What runs concurrently | Wall-clock at N=100, DUR=10 | When to use |
|---|---|---|---|
| `parallel` (default) | all hosts launch all of their clients at once after a synchronized start | ~1 × DURATION (~50s) | fabric stress testing: load everything at once and see what breaks |
| `sequential-host` | one host at a time runs all of its clients in parallel | ~N × DURATION (~17 min) | clean numbers per host without inter-host interference |
| `sequential-host --single-server HOST` | every *other* host targets just HOST, simultaneously (all→one) | ~1 × DURATION | incast: what one server's inbound looks like with the whole fleet converging on it |
| `sequential-pair` | exactly one connection on the wire at any moment | ~N(N-1) × DURATION (~28 hr) | cleanest possible per-pair numbers; usually overkill |
| `rolling` | each host independently picks its least-tested peer, runs one short iperf, repeats for `--total-time`; up to `--host-flows` concurrent flows per host | bounded by `--total-time` | only practical mode at very large N: per-host load is `--host-flows`, independent of fleet size |

Every iperf client is additionally wrapped in a hard per-test time limit
(coreutils `timeout` on the remote host, when present): iperf2's `-t` bounds
the send window, but a client that cannot connect or wedges on a dead peer
would otherwise stall the whole round. The default cap is `--duration` + 30
seconds; `--test-timeout SECONDS` overrides it, and `--test-timeout 0`
disables the cap. A test killed by the cap is reported as a `FAIL` with
`killed by test timeout` in its log.

<!-- docs:end -->
---

<!-- docs:how-it-works -->
## How it works

### Synchronized start (`parallel` mode)
The orchestrator computes `start_time = now + START_DELAY` once locally, pushes that epoch timestamp to every host as a script argument, and each remote run-script sleeps until that epoch before launching iperf. All hosts start within a fraction of a second of each other.

### Per-host run scripts
Generated locally with each host's targets baked in, then distributed once via scp. The remote side has no orchestration logic — it's just a target list, a synchronization barrier, mpstat in the background, and a fan-out of one-way `iperf -c` calls (one per target, or `--host-flows` per target, all backgrounded and `wait`-ed, each under the per-test time limit).

### One test per directed edge
Every host is the client for its own outbound directions. In a full mesh of N
hosts each one runs N-1 one-way `iperf -c` invocations — the fleet runs
N(N-1) tests in all — and every log file carries exactly one direction's
bytes. The two directions of a pair are measured by the two hosts' own clients,
so in `parallel` mode A→B and B→A run at the same moment on two TCP
connections: the link is loaded both ways, and each number is unambiguously
one direction's.

The load is even by construction: every host sends N-1 tests and receives
N-1, so at N=100 each runs 99 clients. A pair grid (`gen --grid`) enables
directions one at a time, and then each host runs exactly the tests its grid
row enables. `create-scripts` logs the resulting client load (min / max /
mean) so you can confirm the fan-out before the run starts.

### CPU sampling
Each host runs `mpstat -P ALL 1 N` in the background, started right before iperf and running for `DURATION + 4` seconds. The fallback (`/proc/stat` deltas) kicks in if mpstat isn't installed; the parser detects which format it's reading.

The bar chart annotates each host's bar with peak CPU. Three patterns to watch for:

| Pattern | What it usually means |
|---|---|
| `peak_total_pct` low but `peak_softirq_pct` high on one core | RSS isn't spreading NIC IRQs — one core is doing all the packet work |
| `peak_idle_floor_pct` near 0 but `peak_total_pct` low | One specific core is pinned (usually by softirq) while others sit idle |
| `peak_total_pct` near 100 across all hosts | True CPU bound — throughput numbers measure the CPU, not the fabric |

### Result collection
For each host, one ssh + one scp + one local untar — instead of N-1 individual scp calls. At N=100 that's roughly 300 SSH/SCP operations across the whole pipeline instead of 5,000.

### Hostname sanitization in filenames
Server-list entries like `2001:db8::1` or `[fe80::1]` are sanitized when used in filenames (`iperf_test_<src>_to_<dst>_<run-id>.log`, `cpu_<host>_<run-id>.log`, `run_<host>_<run-id>.sh`, the per-host tarballs): colons, slashes, square brackets and whitespace become `_`, so the path is well-formed on every filesystem. The real name travels in each file's header (`# pair_a=…`, `# host=…`) and the parsers read it from there, so the CSV shows hosts exactly as the server list names them, and an IPv6 address no longer produces broken paths or silently dropped logs.

### Heatmap auto-degradation
Cell annotations, axis labels, and figure size adapt to N:

| N | Cell labels | Axis labels | Bar value labels | Figure size |
|---|---|---|---|---|
| ≤ 30 | yes | every host | yes | scales linearly |
| 31–50 | no | every host | yes | scales linearly |
| 51–60 | no | every host (smaller font) | no | capped |
| > 60 | no | every Nth (~30 shown total) | no | capped at 36×32 inches |

At N=100 the heatmap renders as a ~280KB PNG in a few seconds, with slow hosts visible as red rows and columns.

<!-- docs:end -->
---

<!-- docs:output-schema -->
## Output schema

### `iperf_results.csv` (one row per directed test)

Columns appear in this order:

| Column | Meaning |
|---|---|
| timestamp | iperf2's reported test time |
| source | sender host for this row's direction |
| target | receiver host for this row's direction |
| status | `OK`, `NO_HEADER`, `NO_SUMMARY`, `DIRECTION_MISSING`, `READ_ERROR` |
| protocol | `TCP` |
| duration_s, parallel_streams | from the run-script header |
| bind_iface, bind_ip | the sending host's interface and address under `--bind`; empty without it |
| bytes_transferred, bps, mbps | the throughput numbers |
| src_port, dst_port | raw from iperf2 |
| pair_a, pair_b | the two hosts named in the log's header; `pair_a` ran the client |
| filename, error | log file and any error text |
| test_start | epoch seconds the run script stamped just before launching iperf; how `make-pivot` and the overlays tell concurrent flows from repeated probes |

### `cpu_summary.csv` (one row per host)

| Column | Meaning |
|---|---|
| host | from the cpu log filename |
| source | `mpstat` or `proc_stat` (which parser handled it) |
| n_cpus | core count (mpstat only) |
| peak_total_pct | max box-wide `100 - %idle` across samples |
| mean_total_pct | mean box-wide `100 - %idle` |
| peak_softirq_pct | max `%soft` on any single core |
| peak_softirq_cpu | which core (mpstat only) |
| peak_sys_pct | max `%sys` (box-wide) |
| peak_user_pct | max `%usr` (box-wide) |
| peak_idle_floor_pct | lowest `%idle` on any single core |
| filename | the CPU log the row was parsed from |

A CPU log that cannot be parsed still gets a row, with `source` set to
`PARSE_ERROR` and the other measurements blank.

### Heatmap reading
- **Rows = source** (sender direction)
- **Columns = target** (receiver direction)
- Cell `(A, B)` is the throughput of A's test to B (in `parallel` mode, measured while B was sending to A at the same time)
- A row that's all red → that host has bad outbound
- A column that's all red → that host has bad inbound
- The bar chart underneath ranks hosts by mean outgoing Mbps with peak CPU% labeled when available

<!-- docs:end -->
---

<!-- docs:overlays -->
## Datacenter layout overlays

A mesh test answers "which host is slow"; a floor plan answers "which rack".
`export-overlay` renders a run as overlays for the
[datacenter layout viewer](https://github.com/MartinGallagher-code/datacenter_visualization),
which paints them over a `.dc` floor plan, so the numbers land on the hardware
that produced them.

```bash
./iperf-orchestrator.sh export-overlay          # -> results/latest/iperf_overlay.tsv
./iperf-orchestrator.sh run --overlay           # write it as part of the pipeline
```

Then open the viewer with the layout and the samples:

```
http://localhost:8000/?layout=floor.dc&results=iperf_overlay.tsv
```

### The overlays

| Overlay | Per | What it is |
|---|---|---|
| `iperf_mbps_out` / `iperf_mbps_in` | direction | throughput, credited to the sender and to the receiver |
| `iperf_mbps_duplex` | host | everything that host carried at once, both directions |
| `iperf_gbytes` | host | total data carried; bytes add over time, so this is exact in every mode |
| `iperf_line_util` | direction | throughput as a % of the NIC's line rate (with `--overlay-line-rate`) |
| `iperf_achieved` | direction | throughput as a % of the `-b` rate the run asked for |
| `iperf_rel_median` | direction | that direction against the run's own median, in % |
| `iperf_asymmetry` | pair | the gap between a pair's two directions, in % of the faster one |
| `iperf_status` | direction | `OK`, `FAIL` (with the status, error text and log to open), or `NO-DATA` |
| `iperf_fail_kind` | direction | the failures only, coloured by why (`NO_SUMMARY`, `DIRECTION_MISSING`, …) |
| `iperf_ok_pct` | host | how much of that host's mesh actually measured |
| `iperf_peers` | host | how many distinct peers it exchanged data with |
| `iperf_coverage` | host | those peers as a % of the ones it was *planned* to reach |
| `iperf_tests` | host | how many directed tests it took part in |
| `iperf_state` | host | the roll call: `TESTED`, or `NO-DATA` for a host that never answered |
| `iperf_cpu_peak`, `_mean`, `_softirq`, `_sys`, `_user`, `_idle_floor` | host | from `cpu_summary.csv` |
| `iperf_bind_iface` | direction | which NIC the traffic rode, when `--bind` was used |

The three derived overlays are the ones worth opening first, because they say
things the raw Mb/s cannot:

- **`iperf_rel_median`** scores every direction against the median of the run
  it came from, so a bad link stands out at any fabric speed — 100% is normal
  here, 45% is half speed, and you do not have to know what "good" is for this
  hardware. It ships with a diverging palette pinned at 0–200%, so slower-than-
  normal and faster-than-normal read differently rather than as one ramp, and
  aggregates with `median`. That last choice matters on a mesh: every host
  talks to the slow host, so every host's *worst* direction is the one to it,
  and a `min` aggregation paints the whole floor red while hiding the host that
  is actually slow. The median distinguishes "I am slow" (all my directions
  are) from "I have a slow peer" (one is). Switch it to `min` in the viewer
  when you do want the worst link anywhere.
- **`iperf_asymmetry`** is the shape a duplex mismatch, a one-way policer or a
  congested return path makes — a pair whose two directions disagree. It is
  credited to both ends (either NIC can be the cause) and aggregates with
  `max`.
- **`iperf_ok_pct`** keeps a mostly-broken host from hiding behind its one good
  link. Sent and received directions are tallied separately and the **worse**
  side is the value, with `sent=`/`recv=` metadata naming which one failed: a
  host that receives fine and cannot send anything reads 0%, not the 50% an
  average of its two halves would suggest. Tallying both sides also means a
  receive-only host in a partial-mesh grid still gets a reading.

Every overlay arrives with units, ramp direction and a short name, and each
percentage states its real `0–100` range — an auto-scaled CPU overlay makes a
30% peak look alarming purely for being the highest number present. Sample
metadata carries the peer, the test's timestamp, which parser produced a CPU
row (`src=mpstat`), how many cores it saw, which core saturated (`core=7`),
and — on a failure — the error text and the log file to open (`err=`, `log=`).
The file header records the run id, its **mode** (a `parallel` run is the whole
fleet under load at once; `sequential-pair` is one link's uncontended maximum;
they are not comparable) and the duration/streams/protocol every sample shared,
so only a row that departs from them pays for saying so.

One measured row becomes one sample: nothing is averaged on the way out, so
the viewer's own aggregation menu does the reducing (`mean` reads as "across
peers", `max` as "the best peer", `min` as "the worst", `stdev` and `range` as
"how steady was it"). `--overlay-reduce` collapses to one median sample per
host per overlay when the raw row count matters.

### Rolling runs, and what "carried at once" means

`iperf_mbps_duplex` is the one figure that cannot be a plain sum. Parallel and
sequential modes fire a round's flows together, so those rates genuinely add;
rolling mode probes the same pair over and over, and adding those reports more
than the NIC can carry. So rows are clustered by overlapping test window,
summed inside a cluster and averaged across clusters — the same rule
`make-pivot` uses on its cells, for the same reason. A CSV with no
`test_start` cannot say what was in flight together, and there the overlay is
left out with a note on stderr rather than guessed at. `iperf_asymmetry`
compares each direction's *median* for the same reason: on a rolling run,
comparing one arbitrary probe against another turns ordinary variance into an
apparent duplex fault.

**A direction that produced no number is never exported as 0 Mb/s.** Zero is a
measurement, and averaging it in makes a broken link read as a slow one. Those
directions leave as `iperf_status=FAIL` and pull their host's `iperf_ok_pct`
down — visible on the rack, absent from the throughput math. The same holds for
blank cells in `cpu_summary.csv` (a `/proc/stat` host has no per-core columns):
skipped, not zeroed.

### Two blind spots this closes

**A host that never reported.** If a host in the server list produced no rows
at all — SSH refused, iperf2 missing, box down — it has nothing to paint, and
an element with no data on a floor plan reads as "not part of this test". That
is the one reading that is certainly wrong. Those hosts are exported as
`iperf_status=NO-DATA` with 0% coverage, so they sit on the same overlay as
every other broken host instead of disappearing.

**A fabric that is uniformly slow.** `iperf_rel_median` compares each direction
against the run's own median, which is exactly what you want when one link is
sick — and useless when *everything* is at half speed, because the median is
half speed too and every direction reads a comfortable 100%. The viewer's
auto-scaled colours hide it for the same reason. Tell the export what the NIC
is and both problems go away:

```bash
./iperf-orchestrator.sh export-overlay --overlay-line-rate 25000   # 25 GbE
```

Throughput overlays are then scaled `0..25000` (and duplex `0..50000`) instead
of to whatever this run produced, and `iperf_line_util` gives each direction as
a percentage of line rate. It is never guessed: without the flag the overlay is
absent, because a run cannot tell you what the hardware was capable of.

### Comparing two runs

Every overlay is named with a prefix (`iperf_` by default). Give two exports
different prefixes and they load into one file as separate overlays, so the
viewer shows them side by side instead of averaging them together:

```bash
./iperf-orchestrator.sh --run-id monday export-overlay \
    --overlay-out compare.tsv --overlay-test-prefix before_ --overlay-run before
./iperf-orchestrator.sh export-overlay \
    --overlay-out compare.tsv --overlay-append --overlay-test-prefix after_ --overlay-run after
```

`--overlay-run LABEL` sets the `run=` tag each sample carries, which is what
tells them apart in the inspector when they *do* share an overlay.

### Kinship with `mx export`

[`matrix_orchestrator`](https://github.com/MartinGallagher-code/matrix_orchestrator)
writes overlays into the same results file, and the two tools deliberately
answer the same questions the same way: `iperf_achieved` is `mx_achieved`
against a target rate, `iperf_coverage` is `mx_coverage`, `iperf_tests` is
`mx_intervals`, `iperf_state` is `mx_state`, and both keep per-host and
per-peer values in separate overlays so the two granularities never reduce
into each other. Numbers are written the same way too — four significant
digits, fixed notation, because `%g` turns a host's aggregate into
`1.163e+06`, which is correct and unreadable in a file people grep. Load an
`mx` export and an iperf export together and they read as one system.

### Matching hosts to the layout

Targets are the names this orchestrator tested with, and the viewer resolves
any unique suffix of an element path — so a hostname-shaped layout
(`wr12r06u15`) matches with no mapping at all, and generating `servers.txt`
from the `.dc` file is the way to keep it that way. When the two disagree
(an IP list against a hostname floor plan), map them:

```bash
cat > hosts.map <<'MAP'
10.0.0.10   wr01r01u01      # <host as tested>  <layout element>
10.0.0.11   wr01r01u02
MAP
./iperf-orchestrator.sh export-overlay --overlay-map hosts.map
```

Peers are renamed too, so the inspector stays in one namespace.
`--overlay-prefix DH1/A/` prepends a path instead, for addressing one row of a
bigger floor plan. Hosts missing from a map file keep their own name and are
reported on stderr rather than dropped.

### Appending runs

The viewer's results format is append-only: every sample carries `run=<run-id>`,
and a nightly export into one file accumulates history the viewer can aggregate
(`last` for right now, `min` for the worst night).

```bash
./iperf-orchestrator.sh export-overlay --overlay-out nightly.tsv --overlay-append
```

`--overlay-format ndjson` writes one JSON object per line instead — the same
overlays, for anything that would rather generate JSON than columns (the
extension picks it automatically, so `--overlay-out nightly.ndjson` is enough).
`--overlay-out -` writes to stdout, and `--overlay-no-meta` omits the `!test`
lines that carry units, ranges, palettes and short names.

### Steady state only: `--overlay-window`

A long rolling run spends its first minutes ramping up, and the steady state is
what belongs on the wall. `--overlay-window SECONDS` keeps only the tests that
started in the last SECONDS of the run, counting back from the last test to
start:

```bash
./iperf-orchestrator.sh export-overlay --overlay-window 600   # the last 10 minutes
```

Rows with no `test_start` cannot be placed in time, so they are kept rather
than dropped, and the file header records the window and how many earlier
tests it left out.

### Export options

Each flag has an environment variable; the flag wins when both are set.
Passing a flag that names a destination, format, map, prefix, label, window or
line rate is itself a request for the overlay, so `process --overlay-out x.tsv`
needs no separate `--overlay`. The environment variables only configure the
export: to have `process` write it, set `IPERF_OVERLAY=1` as well.

| Flag | Env var | Default | Purpose |
|---|---|---|---|
| `--overlay` | `IPERF_OVERLAY` | `0` | also write the overlay during `process` (and so `summarize`, `run`, `all`) |
| `--overlay-out FILE` | `IPERF_OVERLAY_OUT` | `<run-dir>/iperf_overlay.tsv` | destination; `-` is stdout |
| `--overlay-format FMT` | `IPERF_OVERLAY_FORMAT` | from the extension, else `tsv` | `tsv` or `ndjson` |
| `--overlay-map FILE` | `IPERF_OVERLAY_MAP` | *(unset)* | `<host> <element>` lines renaming tested hosts to layout elements |
| `--overlay-prefix STR` | `IPERF_OVERLAY_PREFIX` | *(unset)* | prepended to every target, e.g. `DH1/A/` |
| `--overlay-test-prefix STR` | `IPERF_OVERLAY_TEST_PREFIX` | `iperf_` | prefix on every overlay name, for comparing runs side by side |
| `--overlay-run LABEL` | `IPERF_OVERLAY_RUN` | the run id | the `run=` tag on every sample |
| `--overlay-window SECONDS` | `IPERF_OVERLAY_WINDOW` | `0` (the whole run) | only tests started in the last SECONDS |
| `--overlay-line-rate MBPS` | `IPERF_OVERLAY_LINE_RATE` | *(unset)* | NIC line rate: absolute throughput scales, plus `iperf_line_util` |
| `--overlay-append` | `IPERF_OVERLAY_APPEND` | `0` | append to the destination instead of replacing it |
| `--overlay-reduce` | `IPERF_OVERLAY_REDUCE` | `0` | one median sample per host per overlay |
| `--overlay-no-meta` | `IPERF_OVERLAY_META=0` | metadata on | omit the `!test` metadata lines |

<!-- docs:end -->
---

<!-- docs:run-directories -->
## Stateless mode and run directories

There is no state file. Each invocation that produces results creates a fresh `./results/<run-id>/` directory (run-id = timestamp), and `./results/latest` is updated to point at it. Read-side commands (`parse-csv`, `parse-cpu`, `make-pivot`, `make-heatmap`, `results-summary`, `export-overlay`) follow `latest` by default, or take `--run-id <id>` to address a specific run. `status` derives state by probing hosts live (running `iperf -v` and `pgrep iperf` on each).

Every subcommand is safe to re-run individually. Common workflows:

```bash
# Full pipeline (creates a new run-id)
./iperf-orchestrator.sh --servers servers.txt all

# Re-run just the analysis on the most recent run
./iperf-orchestrator.sh parse-csv
./iperf-orchestrator.sh parse-cpu
./iperf-orchestrator.sh make-pivot
./iperf-orchestrator.sh make-heatmap

# Re-render the heatmap for an older run
./iperf-orchestrator.sh --run-id 2026-05-05_14-22-01 make-heatmap

# Run two modes back-to-back; each gets its own results subdir
./iperf-orchestrator.sh --servers servers.txt all parallel
./iperf-orchestrator.sh --servers servers.txt all sequential-host
ls results/
```

### Shared-FS safety on the remotes

`REMOTE_DIR` (default `/tmp/iperf_orchestrator`) can point at a shared filesystem (NFS home, GPFS, etc.) while a run is in flight. Every remote-side file the orchestrator creates embeds both the sanitized hostname and the run-id, so hosts sharing the directory, and simultaneous or back-to-back runs, never overwrite each other's files.

**Cleanup is not scoped the same way.** `cleanup`, `clean`, and the last step of `all` and `run` all run `rm -rf "$REMOTE_DIR"` on every host. On a shared filesystem that removes the directory for everyone, including the files of any other run still using it. Give concurrent runs their own `--remote-dir`, or use `start` / `summarize` / `stop` and clean up once every run sharing the directory has finished.

<!-- docs:end -->
---

<!-- docs:design-decisions -->
## Design decisions and lessons learned

This section documents *why* the script is shaped the way it is. Most of these were arrived at by hitting a real problem and fixing it.

### iperf3 was the wrong tool for full-mesh testing
The first version of this script used iperf3 with JSON output. iperf3 has nicer reporting (TCP retransmits, CPU utilization in the output, structured JSON), but its server is single-threaded and accepts one client at a time. At 100 hosts, every other host trying to connect to one server simultaneously would mostly fail with "the server is busy running a test." Working around this means running 100 iperf3 daemons per host on 100 ports, plus a port-assignment scheme, plus 100× the firewall config. We switched to iperf2 and the architecture got dramatically simpler.

### One-way tests per directed edge, not `--full-duplex`
Earlier versions measured each pair with iperf2's `--full-duplex`: one TCP socket carrying both directions, both numbers from one test, half the test count. It did not survive iperf2's CSV output. The `-y C` reports label per-direction rows and SUM rows inconsistently across iperf2 builds and `-P` values, so the same cell could read one direction, the other, or both added together depending on which iperf2 a host had. The orchestrator now runs one unidirectional `iperf -c` per directed edge and has the two hosts of a pair test their own outbound direction at the same moment. In `parallel` mode the link still carries both directions at once, and every log holds exactly one direction's bytes whatever the iperf2 build.

### Client assignment: from the parity rule to every host a client
With one full-duplex test per pair, somebody had to be the client, and "lex-smaller host is always the client" was pathologically imbalanced — lex-first ran N-1 clients, lex-last ran 0. A parity rule on host indices fixed that (49 or 50 clients each at N=100). Moving to one test per directed edge removed the question: every host is the client for its own outbound directions, so every host runs N-1 clients and the load is even by construction.

### Per-host iperf parallelism
A subtle bug in early versions: `parallel` mode synchronized the *start* of each host but each host then ran its iperf3 calls in a serial `for` loop. So all hosts started at T+0, but A→B finished before A→C started. The whole point of parallel mode is to load the wire all at once; we were missing it. Fixed by backgrounding each `iperf` call with `&` and `wait`-ing for the whole batch on each host.

### CPU sampling has to run on every host, including the no-client one
In a full mesh every host has client work, but a pair grid can leave a host with no outbound tests at all (a blank grid row). That host's CPU is still doing real work, terminating every inbound flow, so it still needs to be sampled. The run-script keeps the mpstat sampler running even when its target list is empty.

### Synchronized barrier instead of locks/coordination
The first design considered something like a GPIO-style "everyone signal ready" barrier. Vastly simpler: pick a future epoch timestamp, push it to every host, each host sleeps until then. No coordination, no failure modes around partial-readiness, no protocol to debug. Just a number.

### Tar-batched result collection
N-1 sequential scp calls per host at N=100 is ~80 minutes of pure SSH handshake overhead. One tar + one scp + one local untar per host is closer to a few minutes. Same data, ~17× faster, and the tarball naming naturally namespaces server-side log files (which were originally going to collide on extract).

### Embedded Python for analysis
The bash script runs locally only; on remote hosts the only assumption is iperf2 (and ideally mpstat). The CSV parser, pivot generator, and matplotlib renderer are embedded as heredoc Python in the orchestrator. This keeps it one file you can scp and run, no `pip install -e .` ceremony.

### Fail open, not closed, on individual hosts
`set -e` is intentionally **not** set. The orchestrator tracks failures per host and per step, warns about them, and keeps going so one bad host doesn't abort a 100-host run. Each step's success criterion is "did *enough* of it work to make the next step useful," not "did every single host succeed."

### What CPU sampling reveals
The most common surprise on first runs: the heatmap shows a host with low throughput, you assume the network is bad, then `cpu_summary.csv` shows that host pegged at 100% CPU during the test. The throughput number was measuring the CPU, not the fabric. The peak %CPU annotation on the bar chart exists to surface this immediately rather than letting you misread the heatmap.

A second common surprise: `peak_total_pct` is 30% but `peak_softirq_pct` is 100% on core 0. The box-wide CPU looks fine, but RSS is hashing every flow to the same core. This is invisible without per-core data, which is why `mpstat -P ALL` is preferred over the `/proc/stat` fallback.

<!-- docs:end -->
---

<!-- docs:limitations -->
## Limitations and known gaps

- **No automatic retry on transient SSH failures.** If `start-servers` fails on one host, the orchestrator reports it and moves on (`all` aborts unless `--keep-going` is passed). Re-run the subcommand to pick up stragglers.
- **`sequential-pair` at N=100 takes ~28 hours.** The cleanest mode is also the slowest: it runs all `N(N-1)` directed tests one at a time. If you want sequential-pair-quality numbers in less time, the right approach is round-robin tournament scheduling (pack the `N(N-1)` directed edges into ~N-1 rounds where every host sends at most one flow and receives at most one per round). Not implemented; would be moderate complexity.
- **Heatmap above ~60 hosts loses cell labels.** This is by design — they're unreadable at that density — but it means you have to read the colormap or the CSV for exact values.
- **Asymmetric NIC speeds aren't auto-handled.** If half your fleet is 1G and half is 10G, the heatmap colormap is dominated by the 10G hosts and the 1G hosts all look very red. Acceptable for our use case ("uniform fleet"); for a heterogeneous fleet you'd want per-pair expected-bandwidth normalization.
- **No UDP testing.** Fabric stress testing usually wants TCP because that's what real workloads do; if you specifically need UDP loss/jitter measurements, the iperf invocation in the generated run script needs `-u` and the parser needs to read different CSV columns.

> **Resolved**: setup/teardown fan-out is now capped-concurrency parallel SSH (see `--ssh-jobs`).

<!-- docs:end -->
---

<!-- docs:troubleshooting -->
## Troubleshooting

**`check-iperf` says `WRONG_VERSION`.** Some distributions ship `iperf` as a symlink to `iperf3`. Verify with `iperf -v` on the host and install the actual iperf2 package (`apt install iperf` on Debian/Ubuntu, where `iperf` is iperf2 and `iperf3` is iperf3).

**`run-tests` finishes but logs are full of "the server is busy" errors.** Confirms an iperf3 instance is still listening on port 5001. `pkill -x iperf3` and re-run `start-servers`.

**One host's row is all NaN in the pivot.** Either it failed to start its iperf2 server, or it failed to run its client script. Check `./results/latest/logs/run_<host>.log` and `./results/latest/iperf_run_<host>_<run-id>.status`.

**Heatmap shows surprisingly low numbers everywhere.** Look at `cpu_summary.csv`. If `peak_total_pct` is near 100%, you're CPU-bound, not network-bound. Possible fixes: bigger hosts, more cores, RSS tuning, or run in `sequential-host` mode to see what each host can do without contention.

**`make-heatmap` errors out with `Missing Python package`.** `pip install matplotlib numpy` (or your distro's equivalent). Only the `make-heatmap` step needs these — the other steps work without them. Run `./iperf-orchestrator.sh doctor` to get a single report of every missing local prerequisite plus install hints.

**Every host fails with a password prompt or `Permission denied`.** The orchestrator connects with `BatchMode=yes` and never distributes keys itself. Set up key-based SSH first, e.g. `for h in $(grep -v '^#' servers.txt); do ssh-copy-id "$h"; done`.

**A run aborted halfway and I want to pick up where it left off.** There is no resume: the orchestrator keeps no state, and `all` always starts a fresh run. Every step is a subcommand you can re-run on its own, though. If the tests finished but the analysis did not, `summarize` (or `process`) collects and analyses the latest run, and `--run-id ID` addresses an earlier one. If the failure was one flaky host, re-run with `--keep-going` to barrel past it.

<!-- docs:end -->
---

<!-- docs:file-layout -->
## File layout

### Local: `<script-dir>/results/<run-id>/`

```
results/
  latest -> 2026-05-05_14-22-01    # symlink to most recent run
  2026-05-05_14-22-01/
    .run_mode                      # parallel | sequential-host | sequential-pair | rolling
    scripts/
      run_<host>_<run-id>.sh       # generated per-host run scripts (not rolling)
    logs/
      orchestrator.log             # everything the orchestrator did this run
      run_<host>.log               # stdout/stderr of each host's run-tests session
                                   # (sequential-pair: that host's last round)
      rolling_<host>.log           # rolling mode's per-host session instead
    iperf_test_<src>_to_<dst>_<run-id>.log    # raw iperf2 CSV with header
                                              # (_f<N> per flow with --host-flows > 1,
                                              #  _<seq> per probe in rolling mode)
    iperf_run_<host>_<run-id>.status          # per-host status timeline
    cpu_<host>_<run-id>.log                   # mpstat or proc_stat samples
    iperf_results.csv                          # parsed throughput data
    cpu_summary.csv                            # parsed CPU data
    iperf_pivot.txt                            # text pivot
    iperf_heatmap.png                          # heatmap + bar chart
    iperf_overlay.tsv                          # layout-viewer overlay samples
                                               # (export-overlay / --overlay only)
```

### Remote: `$REMOTE_DIR/` (default `/tmp/iperf_orchestrator/`)

```
run_iperf_<host>_<run-id>.sh          # the run script, as distributed
iperf_test_<src>_to_<dst>_<run-id>.log
iperf_run_<host>_<run-id>.status
cpu_<host>_<run-id>.log
```

Hostnames are sanitized: `:`, `/`, `[`, `]`, whitespace are replaced with `_` so bracketed-IPv6 names like `[fe80::1]` produce safe filenames. The unsanitized name is preserved inside file headers (`# pair_a=...`, `# host=...`).

<!-- docs:end -->
---

<!-- docs:completions -->
## Shell completions

Tab-completion stubs for the subcommand and global flags live in `completions/`:

```bash
# bash
source completions/iperf_orchestrator.bash
# or install system-wide:
sudo cp completions/iperf_orchestrator.bash /etc/bash_completion.d/

# zsh
fpath+=("$PWD/completions")
autoload -Uz compinit && compinit
```

<!-- docs:end -->
---

<!-- docs:tests -->
## Tests

The repository ships an extensive bash-based test suite under `tests/` covering pair assignment, parallel fan-out, the generated remote run-script, all parsers, the run-tests modes, the `doctor` command, the `--keep-going` semantics on `all`, and a long tail of edge cases.

```bash
./tests/run_tests.sh                           # everything
./tests/test_pair_assignment.sh                # one suite
```

<!-- docs:end -->
---

<!-- docs:documentation -->
## Documentation

The rendered documentation lives at
[iperf-orchestrator.readthedocs.io](https://iperf-orchestrator.readthedocs.io/en/latest/)
and is rebuilt by Read the Docs on every push to `main` (configuration in
`.readthedocs.yaml`).

The site has no prose of its own. Every page pulls its body straight out of
this README with a MyST `include` directive, sliced on the invisible
`<!-- docs:* -->` HTML comments that sit above each section, so there is one
copy of the text and the site cannot drift from the repository. `CHANGELOG.md`
and `PUBLISHING.md` are included whole.

To build it locally:

```bash
pip install -r docs/requirements.txt
python -m sphinx -b html -W docs docs/_build/html
```

`-W` matches the `fail_on_warning: true` that Read the Docs and CI both use.
When you add a section to this README, give it a `<!-- docs:slug -->` marker
and include the slice from a page under `docs/` — `tests/test_docs_sources.sh`
fails if you forget, and the docs build fails if a marker an include names
goes missing.

<!-- docs:end -->
---

<!-- docs:utility-scripts -->
## Utility scripts

`merge.sh` bundles a directory tree into a single text file and `split.sh`
expands it again — handy for moving the tree through a channel that only
carries plain text.

**They no longer live here.** The canonical copies are in
[shared_tools](https://github.com/MartinGallagher-code/shared_tools), under
`scripts/`. This repository used to carry its own pair, which is how the two
copies that once existed drifted apart in the first place — one repository's
copy gained features the others never saw. Use the shared ones:

```bash
git clone https://github.com/MartinGallagher-code/shared_tools
shared_tools/scripts/merge.sh bundle.txt some/dir   # bundle a tree
shared_tools/scripts/split.sh bundle.txt restored/  # expand it
```

When a transport caps the size of a single file, `-m` keeps every part under
a limit:

```bash
merge.sh -m 390K bundle.txt some/dir   # bundle-part1-of-N.txt, ...
split.sh bundle-part1-of-3.txt out/    # expand the parts in any order
```

> **Note:** the copy that used to live here took `-n PARTS` and produced
> `bundle.part1of2.txt`. The canonical version takes `-m SIZE` instead and
> names parts `bundle-part1-of-N.txt`. A size limit is the more useful knob,
> because the constraint is nearly always "the upload is refused above N
> bytes" rather than a part count — but any script or muscle memory using
> `-n` needs updating.

Parts are cut on entry boundaries, so no file is ever chopped in half and
each part is a complete, independently valid bundle with its own header and
checksums.

The bundle format inlines text files verbatim and base64-encodes binaries
(and any text file whose content would collide with the section markers).
Permissions, symlinks, empty directories and missing trailing newlines are
preserved; every file carries a sha256 that `split.sh` verifies on expansion,
and the header entry count catches a bundle truncated mid-transfer.
`split.sh` refuses bundles containing absolute or `..` paths and never passes
bundle-controlled strings to a shell.

`bundle.txt` is generated, not committed — rebuild it whenever you need one.

<!-- docs:end -->
---

<!-- docs:license -->
## License

Copyright (C) 2026 Martin J. Gallagher

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program. If not, see <https://www.gnu.org/licenses/>.

Full text: the `LICENSE` file at the repository root, or
<https://www.gnu.org/licenses/gpl-3.0.html> — SPDX identifier
`GPL-3.0-or-later`. This repository follows the
[REUSE Specification](https://reuse.software/): source files carry SPDX
copyright and licence headers, and the licence text lives in `LICENSES/`.

Contributions are welcome and, by submitting them, you agree that they will be
licensed under the same GPL-3.0-or-later terms.
