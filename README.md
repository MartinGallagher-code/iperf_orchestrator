# iperf-orchestrator

[![PyPI version](https://img.shields.io/pypi/v/iperf-orchestrator.svg)](https://pypi.org/project/iperf-orchestrator/)
[![Python versions](https://img.shields.io/pypi/pyversions/iperf-orchestrator.svg)](https://pypi.org/project/iperf-orchestrator/)
[![CI](https://github.com/MartinGallagher-code/iperf_orchestrator/actions/workflows/ci.yml/badge.svg)](https://github.com/MartinGallagher-code/iperf_orchestrator/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![REUSE status](https://api.reuse.software/badge/github.com/MartinGallagher-code/iperf_orchestrator)](https://api.reuse.software/info/github.com/MartinGallagher-code/iperf_orchestrator)

A bash orchestrator for running full-mesh iperf2 throughput tests across a list of servers, collecting per-host CPU samples during the run, and producing a CSV, pivot table, and heatmap + bar chart visualization of the results.

Built primarily for **network fabric stress testing**: load every link in both directions simultaneously and find out what breaks or degrades. Also useful for one-off "is the network healthy" surveys of a fleet.

---

## Installation

### With pip (recommended)

```bash
pip install iperf-orchestrator
```

This puts an `iperf-orchestrator` command on your PATH and installs the Python
libraries the analysis steps need (`numpy`, `pandas`, `matplotlib`). Requires
`bash` and Python 3.8+ on the orchestrator host. Everywhere below, wherever you
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

The analysis steps (`make-pivot`, `make-heatmap`) still need Python 3 with
`numpy`, `pandas`, and `matplotlib` available; run `doctor` to check.

---

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

# 3. Run everything end-to-end
./iperf-orchestrator.sh --servers servers.txt all
```

Each invocation that produces results creates a fresh timestamped run directory under `./results/<run-id>/`, and a `./results/latest` symlink is updated to point at it. Analysis subcommands default to following `latest`; pass `--run-id <id>` to address an older run.

Results in `./results/<run-id>/`:
- `iperf_results.csv` — every test, both directions, fully parsed
- `cpu_summary.csv` — per-host CPU peaks during the run
- `iperf_pivot.txt` — text pivot table of throughput
- `iperf_heatmap.png` — heatmap + sorted bar chart with CPU annotations

---

## Requirements

### On the orchestrator host (where you run the script)
- bash 4+
- ssh, scp
- Python 3 with `numpy` and `matplotlib` (for the heatmap step only)
- tar, gzip

### On every server in the mesh
- **iperf2** (binary name `iperf`, *not* `iperf3`) — version 2.0.13+ recommended for `--full-duplex`
- **sysstat** providing `mpstat` (recommended) — falls back to `/proc/stat` sampling if missing
- ssh access from the orchestrator

The script's `check-iperf` subcommand verifies both iperf2 and mpstat before you start.

### Why iperf2 and not iperf3
iperf3's server is single-threaded and accepts only one client at a time. A full mesh of N hosts would need N iperf3 servers per host on different ports just to function, plus a port-assignment scheme, plus N times the firewall holes. iperf2's multi-threaded server handles concurrent clients on a single port — one daemon per host on port 5001 and you're done. iperf2's `--full-duplex` also gives you a true single-socket bidirectional test, which is what fabric stress testing actually wants.

---

## Subcommands

Key-based SSH to every host must already be configured (the orchestrator
connects non-interactively with `BatchMode=yes`).

```
SETUP:
  check-iperf            Verify iperf2 + mpstat presence on every host
  check-servers          Check which hosts have iperf -s currently running

EXECUTION:
  start-servers          Start iperf2 -s on every host (port 5001)
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

INTERNAL (run-tests calls these for you; available standalone if needed):
  create-scripts         Generate per-host client run scripts locally
  distribute-scripts     Push each host's script out

CONVENIENCE:
  all [MODE] [--keep-going]  Run the full sequence end-to-end
                             (start + run-tests + process + stop)
  status                     Probe hosts live + list available runs
  doctor                     Check local prerequisites
  help                       Common commands and flags
  help-advanced              Every command, every flag, every env var
```

The orchestrator is **stateless**: nothing persists between invocations except the contents of the results directory. `status` derives state by probing hosts directly. Server lists are passed via `--servers`/`IPERF_SERVERS`/`./servers.txt`. Each pipeline run creates a fresh `<results>/<run-id>/` directory; `<results>/latest` is updated to point at the most recent one.

### Configuration

Every setting can be supplied either as an environment variable or as a CLI flag. The CLI flag wins when both are set. Flags accept both `--flag value` and `--flag=value` forms, and may appear before the subcommand:

```bash
./iperf-orchestrator.sh --duration 60 --jobs 32 all
./iperf-orchestrator.sh -d 60 -j 32 all parallel
IPERF_DURATION=60 ./iperf-orchestrator.sh all          # env var still works
```

| Env var | Flag | Default | Purpose |
|---|---|---|---|
| `IPERF_SERVERS` | `--servers`, `-s` | `<script-dir>/servers.txt` | server list path |
| `RESULTS_BASE` | `--output`, `-o` | `<script-dir>/results` | base directory for run subdirs |
| `IPERF_RUN_ID` | `--run-id` | auto-timestamp on write; `latest` symlink on read | which run subdir to address |
| `IPERF_PORT` | `--port` | `5001` | iperf2 listening port |
| `IPERF_DURATION` | `--duration`, `-d` | `10` | seconds per test |
| `IPERF_PARALLEL` | `--parallel`, `-P` | `1` | parallel streams within each test |
| `IPERF_JOBS` | `--jobs`, `-j` | `16` | max concurrent SSH/SCP fan-out (capped concurrency) |
| `IPERF_TOTAL_TIME` | `--total-time` | `300` | rolling mode wall-time (seconds) |
| `IPERF_FLOWS` | `--flows` | `1` | rolling mode per-host concurrent flows |
| `IPERF_DRY_RUN` | `--dry-run`, `-n` | `0` | print SSH/SCP commands instead of executing |
| `IPERF_VERBOSITY` | `--verbose`/`-v`, `--quiet`/`-q` | `1` | `-v` prints every ssh/scp invocation; `-q` suppresses non-WARN/ERROR logs |
| `SSH_USER` | `--ssh-user`, `-u` | `$USER` | SSH login user |
| `START_DELAY` | `--start-delay` | `30` | seconds in the future to schedule the synchronized start |
| `REMOTE_DIR` | `--remote-dir` | `/tmp/iperf_orchestrator` | remote working dir; safe to point at a shared FS (every remote-side file embeds `<host>_<run-id>`) |
| `PYTHON_BIN` | `--python` | `python3` | Python interpreter for analysis steps |

#### `--jobs` and capped-concurrency parallel SSH

Setup and teardown subcommands (`check-iperf`, `check-servers`, `start-servers`, `distribute-scripts`, `collect-results`, `stop-servers`, `cleanup`) fan out to all hosts in parallel, capped at `IPERF_JOBS` concurrent SSH/SCP sessions. Per-host output is captured in worker buffers and replayed in server-list order so the screen output stays readable.

The default of `16` keeps the orchestrator host's SSH agent and the per-host sshd happy on most fleets. Bump it (e.g. `--jobs 64`) when you have hundreds of hosts and the orchestrator's CPU/network can absorb it; lower it if `MaxStartups` on your sshds rejects connections.

The actual `run-tests parallel` mode is *not* throttled by `--jobs` — it has to open one SSH session per host simultaneously to hit the synchronized start barrier. `--jobs` only caps the setup/teardown fan-outs.

#### SSH key setup

The orchestrator does not distribute SSH keys. Configure key-based, non-interactive SSH to every host before running it — for example with `ssh-copy-id`:

```bash
for h in $(grep -v '^#' servers.txt); do ssh-copy-id "$h"; done
```

Every connection uses `BatchMode=yes`, so any host still requiring a password will simply fail rather than prompt.

#### `--keep-going` for `all`

`all --keep-going` continues past per-host failures (a single host failing `start-servers` no longer aborts the whole pipeline). Without it, the first step that records per-host failures aborts the pipeline.

#### `--dry-run`, `--verbose`, `--quiet`

`--dry-run` prints every SSH/SCP command without executing — useful for inspecting what `all` would do before unleashing it on a fleet. `--verbose` echoes every ssh/scp invocation as it runs; `--quiet` drops normal INFO logs and keeps only WARN/ERROR.

---

## Run modes

`run-tests` (and therefore `all`) takes a mode argument that controls how the tests are scheduled. The first three modes use canonical-pair generation — each unordered pair `{A, B}` is tested exactly once, with `--full-duplex` measuring both directions concurrently on a single TCP socket. `rolling` is structured differently (see below).

| Mode | What runs concurrently | Wall-clock at N=100, DUR=10 | When to use |
|---|---|---|---|
| `parallel` (default) | all hosts launch all of their clients at once after a synchronized start | ~1 × DURATION (~50s) | fabric stress testing: load everything at once and see what breaks |
| `sequential-host` | one host at a time runs all of its clients in parallel | ~N × DURATION (~17 min) | clean numbers per host without inter-host interference |
| `sequential-pair` | exactly one connection on the wire at any moment | ~N(N-1)/2 × DURATION (~14 hr) | cleanest possible per-pair numbers; usually overkill |
| `rolling` | each host independently picks its least-tested peer, runs one short iperf, repeats for `--total-time`; up to `--flows` concurrent flows per host | bounded by `--total-time` | only practical mode at very large N: per-host load is `--flows`, independent of fleet size |

---

## How it works

### Synchronized start (`parallel` mode)
The orchestrator computes `start_time = now + START_DELAY` once locally, pushes that epoch timestamp to every host as a script argument, and each remote run-script busy-waits until that epoch before launching iperf. All hosts start within a fraction of a second of each other.

### Per-host run scripts
Generated locally with each host's targets baked in, then distributed once via scp. The remote side has no orchestration logic — it's just a target list, a synchronization barrier, mpstat in the background, and a fan-out of `iperf -c ... --full-duplex` calls (one per target, all backgrounded and `wait`-ed).

### Balanced pair assignment (the parity rule)
For an unordered pair `{A, B}` somebody has to be the iperf2 client. Naive "lex-smaller is always the client" gives terrible load imbalance: at N=100 the lex-first host runs 99 clients and the lex-last runs 0.

The fix is the **parity rule on host indices**: for indices `i, j` (positions in the sorted server list), the client is the smaller index when `(i+j)` is even, the larger when `(i+j)` is odd. Both endpoints compute the same answer independently, so no coordination is needed.

| N | spread | meaning |
|---|---|---|
| odd | 0 | every host runs exactly `(N-1)/2` clients |
| even | 1 | every host runs `(N-2)/2` or `N/2` clients |
| 100 | 1 | every host runs 49 or 50 clients (was 0..99 before) |

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
Server-list entries like `host.example.com`, `2001:db8::1`, or `user@10.0.0.1` are sanitized when used in filenames (`iperf_test_<src>_to_<dst>.log`, `cpu_<host>.log`, `run_<host>.sh`, the per-host tarballs). Slashes, colons, and `@` are replaced so the path is well-formed on every filesystem; the parser reverses the mapping when reading filenames back into the CSV. This means an IPv6 address or a `user@host` entry no longer produces broken paths or silently dropped logs.

### Heatmap auto-degradation
Cell annotations, axis labels, and figure size adapt to N:

| N | Cell labels | Axis labels | Bar value labels | Figure size |
|---|---|---|---|---|
| ≤ 30 | yes | every host | yes | scales linearly |
| 31–50 | no | every host | yes | scales linearly |
| 51–60 | no | every host (smaller font) | no | capped |
| > 60 | no | every Nth (~30 shown total) | no | capped at 36×32 inches |

At N=100 the heatmap renders as a ~280KB PNG in a few seconds, with slow hosts visible as red rows and columns.

---

## Output schema

### `iperf_results.csv` (one row per direction, two per test file)

| Column | Meaning |
|---|---|
| timestamp | iperf2's reported test time |
| source | sender host for this row's direction |
| target | receiver host for this row's direction |
| status | `OK`, `NO_HEADER`, `NO_SUMMARY`, `DIRECTION_MISSING`, `READ_ERROR` |
| protocol | `TCP` |
| duration_s, parallel_streams | from the run-script header |
| bytes_transferred, bps, mbps | the throughput numbers |
| src_port, dst_port | raw from iperf2 |
| pair_a, pair_b | the canonical pair this row came from |
| filename, error | log file and any error text |

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

### Heatmap reading
- **Rows = source** (sender direction)
- **Columns = target** (receiver direction)
- Cell `(A, B)` is the throughput when A was sending to B during the full-duplex test
- A row that's all red → that host has bad outbound
- A column that's all red → that host has bad inbound
- The bar chart underneath ranks hosts by mean outgoing Mbps with peak CPU% labeled when available

---

## Stateless mode and run directories

There is no state file. Each invocation that produces results creates a fresh `./results/<run-id>/` directory (run-id = timestamp), and `./results/latest` is updated to point at it. Read-side commands (`parse-csv`, `parse-cpu`, `make-pivot`, `make-heatmap`, `results-summary`) follow `latest` by default, or take `--run-id <id>` to address a specific run. `status` derives state by probing hosts live (running `iperf -v` and `pgrep iperf` on each).

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

`REMOTE_DIR` (default `/tmp/iperf_orchestrator`) can safely point at a shared filesystem (NFS home, GPFS, etc.). Every remote-side file the orchestrator creates embeds both the sanitized hostname and the run-id, so simultaneous runs (or back-to-back runs sharing the same `REMOTE_DIR`) never overwrite each other. `cleanup` (without `--all`) only removes files matching the active run-id, leaving prior runs untouched.

---

## Design decisions and lessons learned

This section documents *why* the script is shaped the way it is. Most of these were arrived at by hitting a real problem and fixing it.

### iperf3 was the wrong tool for full-mesh testing
The first version of this script used iperf3 with JSON output. iperf3 has nicer reporting (TCP retransmits, CPU utilization in the output, structured JSON), but its server is single-threaded and accepts one client at a time. At 100 hosts, every other host trying to connect to one server simultaneously would mostly fail with "the server is busy running a test." Working around this means running 100 iperf3 daemons per host on 100 ports, plus a port-assignment scheme, plus 100× the firewall config. We switched to iperf2 and the architecture got dramatically simpler.

### Bidirectional testing per pair
Earlier versions ran two independent tests per host pair (A→B as one test, B→A as another). With iperf2 `--full-duplex`, one TCP socket carries traffic in both directions simultaneously, both numbers come out of the same test, and you halve the test count. For fabric stress testing this is also more realistic — real-world traffic isn't strictly unidirectional and the switch buffers don't see the same patterns.

### Parity rule for client assignment
The first canonical-pair scheme used "lex-smaller host is always the client." That's correct but pathologically imbalanced — lex-first runs N-1 clients, lex-last runs 0. The parity-on-indices rule gives every host roughly (N-1)/2 clients with a max-min spread of 0 (N odd) or 1 (N even). At N=100 this turns 0..99 client load into 49..50 client load. Both endpoints compute the rule independently and agree without coordination.

### Per-host iperf parallelism
A subtle bug in early versions: `parallel` mode synchronized the *start* of each host but each host then ran its iperf3 calls in a serial `for` loop. So all hosts started at T+0, but A→B finished before A→C started. The whole point of parallel mode is to load the wire all at once; we were missing it. Fixed by backgrounding each `iperf` call with `&` and `wait`-ing for the whole batch on each host.

### CPU sampling has to run on every host, including the no-client one
With balanced pair assignment, every host has *some* client work — but if N is odd or if you customize the rule, you can end up with a host whose only role is being a server for inbound flows. That host's CPU is still doing real work (handling N/2 inbound full-duplex sockets), so it still needs to be sampled. The run-script keeps the mpstat sampler running even when its target list is empty.

### Synchronized barrier instead of locks/coordination
The first design considered something like a GPIO-style "everyone signal ready" barrier. Vastly simpler: pick a future epoch timestamp, push it to every host, each host busy-waits until then. No coordination, no failure modes around partial-readiness, no protocol to debug. Just a number.

### Tar-batched result collection
N-1 sequential scp calls per host at N=100 is ~80 minutes of pure SSH handshake overhead. One tar + one scp + one local untar per host is closer to a few minutes. Same data, ~17× faster, and the tarball naming naturally namespaces server-side log files (which were originally going to collide on extract).

### Embedded Python for analysis
The bash script runs locally only; on remote hosts the only assumption is iperf2 (and ideally mpstat). The CSV parser, pivot generator, and matplotlib renderer are embedded as heredoc Python in the orchestrator. This keeps it one file you can scp and run, no `pip install -e .` ceremony.

### Fail open, not closed, on individual hosts
`set -e` is intentionally **not** set. The orchestrator tracks failures per host and per step, warns about them, and keeps going so one bad host doesn't abort a 100-host run. Each step's success criterion is "did *enough* of it work to make the next step useful," not "did every single host succeed."

### What CPU sampling reveals
The most common surprise on first runs: the heatmap shows a host with low throughput, you assume the network is bad, then `cpu_summary.csv` shows that host pegged at 100% CPU during the test. The throughput number was measuring the CPU, not the fabric. The peak %CPU annotation on the bar chart exists to surface this immediately rather than letting you misread the heatmap.

A second common surprise: `peak_total_pct` is 30% but `peak_softirq_pct` is 100% on core 0. The box-wide CPU looks fine, but RSS is hashing every flow to the same core. This is invisible without per-core data, which is why `mpstat -P ALL` is preferred over the `/proc/stat` fallback.

---

## Limitations and known gaps

- **No automatic retry on transient SSH failures by default.** If `start-servers` fails on one host, the orchestrator reports it and moves on. Pass `--retries N` to retry each parallel-fan-out worker N extra times with linear back-off, or re-run the subcommand to pick up stragglers.
- **`sequential-pair` at N=100 takes ~14 hours.** The cleanest mode is also the slowest. If you want sequential-pair-quality numbers in less time, the right approach is round-robin tournament scheduling (pack all `N(N-1)/2` edges into ~N-1 rounds where every host has at most one flow per round). Not implemented; would be moderate complexity.
- **Heatmap above ~60 hosts loses cell labels.** This is by design — they're unreadable at that density — but it means you have to read the colormap or the CSV for exact values.
- **Asymmetric NIC speeds aren't auto-handled.** If half your fleet is 1G and half is 10G, the heatmap colormap is dominated by the 10G hosts and the 1G hosts all look very red. Acceptable for our use case ("uniform fleet"); for a heterogeneous fleet you'd want per-pair expected-bandwidth normalization.
- **No UDP testing.** Fabric stress testing usually wants TCP because that's what real workloads do; if you specifically need UDP loss/jitter measurements, the iperf invocation in the generated run script needs `-u` and the parser needs to read different CSV columns.

> **Resolved**: setup/teardown fan-out is now capped-concurrency parallel SSH (see `--jobs`); workers gain optional retries with linear back-off via `--retries`.

---

## Troubleshooting

**`check-iperf` says `WRONG_VERSION`.** Some distributions ship `iperf` as a symlink to `iperf3`. Verify with `iperf -v` on the host and install the actual iperf2 package (`apt install iperf` on Debian/Ubuntu, where `iperf` is iperf2 and `iperf3` is iperf3).

**`run-tests` finishes but logs are full of "the server is busy" errors.** Confirms an iperf3 instance is still listening on port 5001. `pkill -x iperf3` and re-run `start-servers`.

**One host's row is all NaN in the pivot.** Either it failed to start its iperf2 server, or it failed to run its client script. Check `./results/latest/logs/run_<host>.log` and `./results/latest/iperf_run_<host>_<run-id>.status`.

**Heatmap shows surprisingly low numbers everywhere.** Look at `cpu_summary.csv`. If `peak_total_pct` is near 100%, you're CPU-bound, not network-bound. Possible fixes: bigger hosts, more cores, RSS tuning, or run in `sequential-host` mode to see what each host can do without contention.

**`make-heatmap` errors out with `Missing Python package`.** `pip install matplotlib numpy` (or your distro's equivalent). Only the `make-heatmap` step needs these — the other steps work without them. Run `./iperf-orchestrator.sh doctor` to get a single report of every missing local prerequisite plus install hints.

**Every host fails with a password prompt or `Permission denied`.** The orchestrator connects with `BatchMode=yes` and never distributes keys itself. Set up key-based SSH first, e.g. `for h in $(grep -v '^#' servers.txt); do ssh-copy-id "$h"; done`.

**A run aborted halfway and I want to pick up where it left off.** `./iperf-orchestrator.sh all --resume` consults `~/.iperf_orchestrator/state` and skips the steps already marked done. If the failure was on a single flaky host and you want to barrel past it instead, add `--keep-going`.

---

## File layout

### Local: `<script-dir>/results/<run-id>/`

```
results/
  latest -> 2026-05-05_14-22-01    # symlink to most recent run
  2026-05-05_14-22-01/
    iperf_installed.txt            # check-iperf output (this run only)
    iperf_running.txt              # check-servers output (this run only)
    .run_mode                      # parallel | sequential-host | sequential-pair
    scripts/
      run_<host>_<run-id>.sh       # generated per-host run scripts
    logs/
      orchestrator.log             # everything the orchestrator did this run
      run_<host>.log               # stdout/stderr of each host's run-tests session
      run_<src>_to_<dst>.log       # sequential-pair only
    iperf_test_<src>_to_<dst>_<run-id>.log    # raw iperf2 CSV with header
    iperf_server_<host>_<run-id>.log          # server-side iperf log per host
    iperf_run_<host>_<run-id>.status          # per-host status timeline
    cpu_<host>_<run-id>.log                   # mpstat or proc_stat samples
    iperf_results.csv                          # parsed throughput data
    cpu_summary.csv                            # parsed CPU data
    iperf_pivot.txt                            # text pivot
    iperf_heatmap.png                          # heatmap + bar chart
```

### Remote: `$REMOTE_DIR/` (default `/tmp/iperf_orchestrator/`)

```
run_iperf_<host>_<run-id>.sh
iperf_test_<src>_to_<dst>_<run-id>.log
iperf_server_<host>_<run-id>.log
iperf_run_<host>_<run-id>.status
cpu_<host>_<run-id>.log
```

Hostnames are sanitized: `:`, `/`, `[`, `]`, whitespace are replaced with `_` so bracketed-IPv6 names like `[fe80::1]` produce safe filenames. The unsanitized name is preserved inside file headers (`# pair_a=...`, `# host=...`).

---

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

---

## Tests

The repository ships an extensive bash-based test suite under `tests/` covering pair assignment, parallel fan-out, the generated remote run-script, all parsers, the run-tests modes, the `doctor` command, the `--keep-going` semantics on `all`, and a long tail of edge cases.

```bash
./tests/run_tests.sh                           # everything
./tests/test_pair_assignment.sh                # one suite
```

---

## License and contribution

This project is licensed under the **GNU General Public License v3.0** (GPL-3.0). See the [LICENSE](LICENSE) file for the full text.

In short: you are free to use, modify, and redistribute this software, but any distributed derivative work must also be licensed under GPL v3 and made available in source form. The software is provided without warranty.

Contributions are welcome and, by submitting them, you agree that they will be licensed under the same GPL v3 terms.
