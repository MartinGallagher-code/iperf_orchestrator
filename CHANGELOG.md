# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.1.2]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.1.2
[1.1.1]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.1.1
[1.1.0]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.1.0
[1.0.0]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.0.0
