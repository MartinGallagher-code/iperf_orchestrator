# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `--version` flag (and `version` subcommand) that prints the program name
  and version.
- The no-args quick-start banner now points at `--help` and `--version`.

### Changed
- Minimum supported Python is now 3.9 (`requires-python = ">=3.9"`); 3.8 is
  no longer supported.
- CI runs the test suite against every supported Python (3.9 through 3.13)
  instead of only 3.12, so the declared floor is actually exercised.

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
