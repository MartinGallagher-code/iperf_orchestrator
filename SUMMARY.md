# iperf Orchestrator — Development Overview

A coordinated network-throughput test harness for fleets of Linux
servers, built as a single self-contained bash script. This document
describes how the codebase is organized and how a test run flows
through the system.

## What it does

Given a list of hosts, the orchestrator:

1. Verifies SSH connectivity and that `iperf2` is installed on every
   host.
2. Starts a long-lived `iperf -p PORT -s -D` daemon on each host (one
   shared listener that the entire fleet's clients connect into).
3. Generates per-host client scripts that know which peers to test
   against (parity-based pair assignment so each canonical pair is
   tested exactly once per round).
4. Distributes those scripts to every host via SCP.
5. Runs the tests in one of three modes (parallel, sequential, or
   rolling — see *Execution modes* below).
6. Collects raw `iperf -y C` output and per-host CPU samples back to
   the orchestrator.
7. Parses the CSV output, builds a pivot table, and renders a heatmap
   PNG.

The end-state of any successful run is a self-describing directory
under `<script-dir>/results/<run-id>/` containing the raw logs, parsed
`iperf_results.csv`, `iperf_pivot.txt`, `iperf_heatmap.png`, and a
`<script-dir>/results/latest` symlink updated to point at it.

## Architecture

### Single-file script

The whole orchestrator is one file: `iperf_orchestrator/iperf_orchestrator.sh`,
approximately 3000 lines of bash with embedded Python heredocs for the
non-trivial parsing, pivoting, and rendering steps. There are no
runtime dependencies beyond what every Linux box already has:

- `bash` 4+
- `ssh`, `scp`
- `iperf2` (≥ 2.0.13 for `--full-duplex`; 2.0.14+ recommended)
- `python3` (stdlib only — no third-party packages)
- `mpstat` (optional; falls back to `/proc/stat` sampling)
- `matplotlib` is the *only* non-stdlib Python dependency, and only
  needed by `make-heatmap`. Everything else works without it.

This deliberate constraint keeps the script easy to drop onto a
freshly-imaged jump host and use immediately.

### Pip packaging

For distribution, a thin Python wrapper package
(`iperf_orchestrator/{__init__,cli,__main__}.py` + `pyproject.toml`) makes the
tool `pip install`-able. It does not reimplement anything: the console-script
entry point (`iperf-orchestrator`) locates the bundled `iperf_orchestrator.sh`
and `exec`s it via `bash`, forwarding all arguments. The wrapper's only added
behavior is resolving `RESULTS_BASE`/`servers.txt` relative to the current
working directory (rather than the install location under `site-packages`) and
setting `IPERF_ORCH_PROG` so help text shows the clean command name. `pip`
pulls in `numpy`/`pandas`/`matplotlib` as declared dependencies so the analysis
steps work out of the box.

### Stateless by design

There is no daemon, no database, no `~/.iperf_orchestrator/` directory.
Each invocation:

- Reads its server list from `--servers <file>`, `IPERF_SERVERS`, or
  the default `<script-dir>/servers.txt`.
- Resolves a *run-id* — auto-generated `YYYY-MM-DD_HH-MM-SS` for
  write-side commands, or the target of `results/latest` for read-side
  commands like `make-pivot` and `status`.
- Writes everything for that run under `results/<run-id>/`.
- Updates `results/latest` only when a *write*-side command produces
  output.

`status` derives liveness by SSH-probing every host (`iperf -v`,
`pgrep iperf`) — never by reading a state file.

### Code structure

The script is organized top-to-bottom in roughly the order things
happen during execution:

| Lines (approx) | Section |
|---|---|
| Configuration defaults (env-var driven) | 50–110 |
| CLI flag pre-pass — recognizes global flags in any position on the line | 130–200 |
| Validators (`_validate_uint`, `_validate_server_list`) | 200–230 |
| Helpers (`_iperf_extra_args`, `_ensure_run_id`, `_resolve_existing_run`, `read_servers`, `_sanitize_host`) | 230–470 |
| `parallel_hosts` — capped-concurrency SSH fan-out primitive | 470–550 |
| Pair-assignment helpers (`build_host_idx`, `is_client_for`) | 550–600 |
| `usage()` / `usage_advanced()` | 600–760 |
| Subcommand implementations: `cmd_status`, `cmd_check_iperf`, `cmd_check_servers`, `cmd_start_servers`, `cmd_create_scripts`, `cmd_distribute_scripts`, `cmd_run_tests` (with `_run_rolling` and `_run_one_round` helpers), `cmd_collect_results`, `cmd_stop_servers`, `cmd_cleanup`, `cmd_parse_csv`, `cmd_parse_cpu`, `cmd_make_pivot`, `cmd_make_heatmap`, `cmd_results_summary`, `cmd_doctor`, `cmd_process`, `cmd_all` | 760–2900 |
| Dispatcher (case statement mapping subcommand → `cmd_*`) | 2900–2970 |

Every subcommand follows the same pattern: `_resolve_existing_run` (or
`_ensure_run_id`), then either does work locally or fans out via
`parallel_hosts`.

### Concurrency model

A single primitive — `parallel_hosts <worker> <args...>` — handles
every fleet-wide operation. It iterates the server list, spawns
`<worker_fn> <host>` subshells in the background, blocks via
`wait -n` once `IPERF_SSH_JOBS` (default 16) workers are in flight,
and replays each worker's captured stderr/stdout in server-list order
once all are done.

This bounds resource use on the orchestrator host (a 1000-host fleet
doesn't open 1000 simultaneous SSH connections), and keeps screen
output deterministic — workers print into per-host buffers, not
interleaved into the terminal.

Workers are tiny one-liners by convention. For example,
`_worker_check_iperf` is essentially:

```bash
ssh_run "$host" "iperf -v 2>&1 | head -1"
```

The complexity lives in `parallel_hosts`, not in the workers.

### Shared-FS safety

Every file written on a remote host embeds both `<host_safe>` and
`<run_id>` so multiple hosts whose `$REMOTE_DIR` lives on a shared
filesystem (NFS home, parallel cluster FS) cannot overwrite each
other:

- `iperf_server_<host>_<run-id>.log` — daemon log
- `iperf_run_<host>_<run-id>.status` — script lifecycle markers
- `cpu_<host>_<run-id>.log` — mpstat output
- `iperf_test_<src>_to_<dst>_<run-id>.log` — per-pair iperf output
- `_results_<host>_<run-id>.tar.gz` — collection tarball
- `run_iperf_<host>_<run-id>.sh` — the per-host client script

`_sanitize_host` produces filename-safe tokens from awkward host
strings (IPv6 brackets, slashes, whitespace) while the *unsanitized*
hostname is preserved inside file headers (`# host=...`,
`# pair_a=...`) so the parser sees the truth.

## Execution modes

### Parallel

All hosts begin at a synchronized epoch-second `START_TIME` (typically
`now + 5s`). Each host runs `iperf -c <peer> --full-duplex -P N` in
parallel against every peer it owns under the parity-based pair
assignment. One TCP connection per pair carries traffic in both
directions concurrently, and the parser splits the two CSV summary
lines back into directional rows.

Best for: snapshot measurements of small/medium fleets where you want
fairness and a single sync point.

### Sequential

Either `sequential-host` (one host runs at a time, against all of its
peers) or `sequential-pair` (one canonical pair at a time). Same
generated scripts as parallel mode; the orchestrator just iterates
them serially instead of fanning out.

Best for: isolating per-link behavior without cross-traffic — e.g.
suspecting a switch contention issue and wanting to test pairs in
isolation.

### Rolling

Each host runs an independent loop for a configurable wall-time
window. On each iteration the host picks its *least-tested* peer
(random tiebreak), launches a unidirectional `iperf -c`, increments
that peer's counter, and continues until the window expires. Per-host
concurrency is bounded by `--host-flows N`.

This mode scales to arbitrarily large meshes. With 1000 hosts and
`--host-flows 4`, you get ~4000 concurrent flows, each going through
its own iperf process so there's no single-thread bottleneck. Each
direction is exercised when the *other* host's loop independently
picks this host.

Best for: large fleets, sustained-load measurement, and "flood the
link" runs where iperf2's `--full-duplex` single-thread bottleneck
becomes the limiting factor.

## Data flow

A complete pipeline (`./iperf_orchestrator.sh all`) looks like:

```
servers.txt ──► check-iperf ──► start-servers ──► create-scripts ──► distribute-scripts
                                                          │
                                                          ▼
                                                      run-tests
                                                          │
                                                          ▼
                                          (remote: iperf_test_*.log files)
                                                          │
                                                          ▼
                                                  collect-results
                                                          │
                                                          ▼
                                          results/<run-id>/iperf_test_*.log
                                                          │
                                                          ▼
                            ┌────────────── parse-csv ───┴─── parse-cpu ──────────┐
                            ▼                                                      ▼
                   iperf_results.csv                                       cpu_summary.csv
                            │                                                      │
                            ├──────────────► make-pivot ◄────────────────────────┤
                            │                     │                                │
                            │                     ▼                                │
                            │           iperf_pivot.txt                            │
                            │                                                      │
                            └──────────────► make-heatmap ◄───────────────────────┘
                                                  │
                                                  ▼
                                          iperf_heatmap.png
```

Each arrow is a separate subcommand the user can run independently.
`process` chains everything from `collect-results` onward; `all` runs
the entire pipeline end-to-end.

### Per-test header line

Every `iperf_test_*.log` file begins with a metadata line emitted by
the per-host generated script:

```
# pair_a=node03 pair_b=node07 run_id=2026-05-08_14-30-00 duration=60 \
  port=5001 parallel=16 bind_iface=bond0 bind_ip=10.10.5.42 test_start=...
```

The Python parser inside `cmd_parse_csv` reads this header to populate
columns of `iperf_results.csv` that aren't in iperf's own `-y C`
output (run-id, parallel-stream count, bind data). This is how
`make-pivot`'s "Source bindings" section, the run-data-based
`Parallel: N` header, and the per-pair filter against the active
`servers.txt` all stay correct without any persistent state.

### Pivot semantics

Cells are *time-averaged directional throughput*:

```
cell[src][dst] = sum(mbps_i * duration_i for all flows src→dst) / wall_time
```

`wall_time` is derived from the iperf2 timestamps in the CSV
(`max(ts) − min(ts) + max(duration)`). This formulation correctly
accounts for `--host-flows > 1` in rolling mode where multiple
concurrent flows in the same direction must *sum*, not average. For a
single-pair-single-flow parallel run it reduces to that flow's mean
Mbps.

The pivot also emits:

- **Per-source mean outgoing** — average each row excluding the
  diagonal.
- **Per-server avg total traffic (out + in)** — Mbps and GB/s.
- **Fleet aggregate bandwidth** — Mbps and GB/s.
- **Source bindings** (when `--bind` was used) — which interface and
  IP each host actually bound to.
- **Samples-per-cell summary** when rolling mode produced multiple
  samples per pair.

## Configuration surface

Every knob has both a long flag and an env-var. The env-var form is
useful when chaining multiple invocations (e.g.
`IPERF_DURATION=60 ./iperf_orchestrator.sh all`).

The flag pre-pass recognizes global flags in *any* position on the
command line, so all of these are equivalent:

```
./iperf_orchestrator.sh --streams 4 run-tests rolling
./iperf_orchestrator.sh run-tests --streams 4 rolling
./iperf_orchestrator.sh run-tests rolling --streams 4
```

Subcommand-specific flags (`cleanup --yes`, `all --keep-going`) are
parsed by the subcommand itself and may contain values that look like
global flags without conflict.

The `--bind` flag is unusual: its value is a *substring search
pattern* matched against `ip -o -4 addr show` on each remote at
iperf-launch time. The first matching line's IPv4 is what iperf2
binds to. So `--bind bond0` works across a multi-homed fleet where
every host has a different IP on its bond interface.

## Testing

The test harness lives under `tests/` — 33 test files driving the
script through every subcommand and most flag combinations.

Tests run against a fake `ssh` shim (`tests/test_helper.bash::install_fake_ssh`)
that logs every invocation to `$FAKE_SSH_LOG`, so assertions can
verify both that the right hosts were contacted and that the right
arguments were passed. There's no real network involvement.

`tests/run_tests.sh` runs every `test_*.sh` file in alphabetical
order and produces a pass/fail summary. Each test file is independent
— it can be run on its own for fast iteration on a specific area.

The CSV parser, the pivot calculator, and the heatmap renderer have
their own dedicated test files so changes to the Python heredocs are
caught immediately rather than at end-to-end runtime.

## Where to start when modifying

| Goal | Start at |
|---|---|
| Add an iperf2 client flag | `_iperf_extra_args` (line ~245), then update help text and `tests/test_run_tests_modes.sh` for the rolling case + `tests/test_create_scripts.sh` for parallel/sequential |
| Add a new subcommand | new `cmd_<name>` function, then add to the dispatcher and `usage_advanced` |
| Change an output column | the relevant Python heredoc (`cmd_parse_csv` for raw rows, `cmd_make_pivot` for the report) |
| Add a new fleet-wide operation | new `_worker_<name>` one-liner + `cmd_<name>` that calls `parallel_hosts _worker_<name>` |
| Change pair assignment | `build_host_idx` + `is_client_for` (parity rule) |
| Change rolling mode behavior | `_run_rolling` (line ~1356); the entire probe lives in one inline SSH heredoc |

## Notable invariants

- `_resolve_existing_run` always follows `results/latest` unless
  `--run-id` was *explicitly* given. This means `parse-csv` /
  `make-pivot` / `status` always describe the most recent run by
  default but are pinnable for historical analysis.
- The pivot's `Duration`, `Port`, and `Parallel` headers come from the
  modal value in `iperf_results.csv`, never from the orchestrator's
  current environment. This decouples report generation from the
  shell that produced the results.
- Filenames are sanitized (`_sanitize_host`); host strings inside file
  *headers* are not, so the parser sees the canonical name.
- Server-list filtering happens at parse time — commenting out a host
  in `servers.txt` retroactively excludes it from new pivots / heatmaps
  without re-running the test.
