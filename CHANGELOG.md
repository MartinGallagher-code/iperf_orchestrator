# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `--version` flag (and `version` subcommand) that prints the program name
  and version.
- The no-args quick-start banner now points at `--help` and `--version`.
- `tests/check_python_compat.sh`, which extracts the Python embedded in
  `iperf_orchestrator.sh` heredocs and byte-compiles it, so the supported
  interpreter floor is actually enforced rather than just declared.
- CI job that scans for post-3.6 syntax and stdlib APIs (`vermin`) and runs
  the suite under a real Python 3.6 container.

### Changed
- **Lowered the supported Python floor from 3.8 to 3.6**
  (`requires-python = ">=3.6"`), so the orchestrator host can be a stock
  RHEL/CentOS 8 or Ubuntu 18.04 box using its system interpreter. Required
  two changes: the pip wrapper no longer uses `from __future__ import
  annotations` (3.7+) or PEP 585/604 annotations, and `results-summary` uses
  `statistics.mean` instead of `statistics.fmean` (3.8+).

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

[1.0.0]: https://github.com/MartinGallagher-code/iperf_orchestrator/releases/tag/v1.0.0
