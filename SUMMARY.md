# iperf Orchestrator — Project Summary

## What the product does

`iperf_orchestrator` is a single bash script that turns a fleet of Linux
servers into a coordinated network-throughput test harness. Given a list
of hosts, it pushes a small client script to each one, runs synchronized
or rolling iperf2 tests across the full mesh, collects the raw results
back, and produces a human-readable pivot table, a heatmap image, and a
CSV for downstream analysis.

It is intended for the work that infrastructure and platform teams
regularly need to do but rarely have a clean tool for:

- **Verifying a new datacenter buildout** — confirming that every rack
  can talk to every other rack at line rate before customer workloads
  arrive.
- **Diagnosing tenant complaints** — "Cluster X is slow." A 60-second
  full-mesh run produces a pivot showing which specific source/target
  pairs are degraded.
- **Validating NIC, kernel, or fabric changes** — measuring throughput
  before and after firmware updates, MTU changes, or driver upgrades.
- **Capacity planning at scale** — a single test run characterizes the
  achievable bandwidth across a 100- or 1000-host mesh.

The deliverable is one self-contained script with no runtime
dependencies beyond the standard system tools (`bash`, `ssh`, `iperf2`,
Python 3) already present on every server. There is no daemon, no
database, no web service, and no persistent state — every run produces
a self-describing directory of results that can be archived or shared
as-is.

### Core design properties

- **Stateless**: each invocation produces a timestamped results
  directory under `<script-dir>/results/`. A `latest` symlink always
  points at the most recent run. Nothing is cached in `$HOME` or in
  hidden state files.
- **Capped concurrency**: SSH/SCP fan-out is bounded so a 1000-host
  fleet does not overwhelm the orchestrator host's connection limits.
- **Shared-FS safe**: every remote file embeds both hostname and run-id,
  so multiple hosts whose `$REMOTE_DIR` lives on a shared filesystem
  (NFS home, parallel cluster FS) cannot overwrite each other.
- **Three execution modes** suiting different scales and needs:
  - **Parallel** — every host runs simultaneously after a synchronized
    start. Best for small/medium fleets and "snapshot" measurements.
  - **Sequential** — one host (or one pair) at a time. Useful when you
    want to isolate per-link behavior without cross-traffic.
  - **Rolling** — each host independently picks its least-tested peer
    in a loop, for a configurable wall-time window. Scales to fleets
    of arbitrary size and produces high statistical density.

## Work completed in this engagement

The session began with a request to validate the current product state
and ended with a series of correctness, usability, and observability
improvements. All changes are merged to `main` and tested.

### Correctness fixes

| Issue | Fix |
|---|---|
| Rolling-mode tests ignored the `--streams` setting and ran with a single TCP stream regardless of what the user requested. | Rolling probe now correctly threads the configured stream count into `iperf -c -P N`. |
| Global command-line flags placed *after* the subcommand were silently dropped (e.g. `run-tests rolling --streams 4` had no effect). | Argument parser now recognizes global flags in any position on the command line, while still rejecting unknown flags before any subcommand is named. |
| The pivot table's reported "Parallel streams" value was read from the orchestrator's environment at report-generation time, not from the actual run. Reports were misleading whenever pivot was generated separately from the test run. | The pivot now reads duration, port, and parallel-streams directly from the recorded run data, so the report always matches what was actually executed. |

### New features

| Feature | Why it matters |
|---|---|
| **GB/s shown alongside Mbps** in per-server total-traffic and fleet-aggregate sections of the pivot. | Multi-Gbps modern fleets produce 5- and 6-digit Mbps numbers that are hard to read at a glance. The GB/s column makes "is this near line rate for a 100 GbE NIC" answerable instantly. |
| **`--bind` / `-B` flag** for binding iperf clients to a specific local interface. The flag accepts a search pattern (e.g. `eth0`, `bond`, `mlx5`, `10.0.0`) and resolves it on each remote host independently to that host's matching interface IP. | Multi-homed servers (storage networks, dedicated test fabrics, separate management vs data planes) need to direct test traffic over a specific NIC. A single search pattern works across the fleet even though each host has different IPs. |
| **Bind resolution surfaced in three places**: per-host startup banner in the log, embedded in every iperf result file's header, and a "Source bindings" section in the pivot table showing which interface and IP each host bound to. | Auditability — when a result is unexpected, the operator can immediately confirm whether traffic actually went out the intended interface, with no need to re-run with extra logging. |

### Quality

- The test suite covers 33 test files with approximately 250 individual
  cases, all passing.
- Two regression tests were added during this engagement specifically
  for the rolling-mode `-P` propagation and for global-flag-after-
  subcommand parsing, locking in the fixes against future changes.
- Every commit was driven by either a user-reported defect or a
  user-requested capability — there was no speculative refactoring.

## Status

| Item | State |
|---|---|
| Production readiness | Ready for use |
| Test coverage | 33 test files, all passing |
| Documentation | In-tree help text (`--help`, `--help-advanced`) reflects current behavior |
| Outstanding work | None requested |

The script lives at the repository root as `iperf_orchestrator.sh`. Run
`./iperf_orchestrator.sh --help` for a quick-start, or
`--help-advanced` for the full flag surface and environment-variable
reference.
