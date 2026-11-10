# Publishing to PyPI

This project ships as the `iperf-orchestrator` distribution on PyPI. The
package is a thin Python wrapper that bundles and runs the bash orchestrator;
see `pyproject.toml` for the metadata.

## Prerequisites

- Python 3.9+ with `build` and `twine`:
  ```bash
  python -m pip install --upgrade build twine
  ```

  This is the **build host** requirement, and is deliberately higher than the
  package's own `requires-python` (3.6+): current `setuptools` (>=77, needed
  for the PEP 639 license metadata), `build`, and `twine` all require 3.9+.
  The wheel they produce is `py3`-generic and installs fine on 3.6.

## The version moves in every pull request

Every change moves the version, however small: code, tests, docs or CI,
Dependabot's pull requests included. The bump belongs to the pull request,
not to a release. In the same pull request:

- **Raise the version** in all three places it is written. Follow
  [SemVer](https://semver.org/): patch for fixes, docs, tests and CI; minor
  for anything new a user can use; major only when something that worked
  stops working the way it did.
  - `pyproject.toml` (`[project].version`)
  - `iperf_orchestrator/__init__.py` (`__version__`, which the docs site
    scrapes for its title)
  - `iperf_orchestrator/iperf_orchestrator.sh` (`ORCH_VERSION`, which
    `--version` prints)
- **Add a `## [X.Y.Z] - YYYY-MM-DD` section** for it at the top of
  `CHANGELOG.md`, never an "Unreleased" one.

`tests/check_version.sh` fails if the three disagree or the changelog does
not open with that version, and `bash tests/check_version.sh origin/main`
also fails unless the version is greater than `main`'s. CI's **version** job
runs it on every pull request and every push to `main`.
`tests/test_help_and_dispatch.sh` checks the three agree as well.

Publishing is a separate step, and a person's call. A number that is never
published is fine; a change with no number is not.

## Cut a release

A release publishes a version that is already on `main`; it never bumps one.

1. **Check out the commit to publish.** `bash tests/check_version.sh` prints
   its version, which is the one that will reach PyPI.

2. **Build the distributions** (sdist + wheel) into `dist/`:
   ```bash
   rm -rf dist
   python -m build
   ```

3. **Validate the metadata** — this must pass before uploading:
   ```bash
   python -m twine check dist/*
   ```

4. **(Optional) Smoke-test the built wheel** in a throwaway virtualenv:
   ```bash
   python -m venv /tmp/iperf-orch-check
   /tmp/iperf-orch-check/bin/pip install dist/*.whl
   /tmp/iperf-orch-check/bin/iperf-orchestrator help
   ```

5. **(Optional) Upload to TestPyPI first**:
   ```bash
   python -m twine upload --repository testpypi dist/*
   pip install --index-url https://test.pypi.org/simple/ \
       --extra-index-url https://pypi.org/simple/ iperf-orchestrator
   ```

6. **Upload to PyPI**:
   ```bash
   python -m twine upload dist/*
   ```

## Automated release (recommended)

`.github/workflows/publish.yml` builds and publishes automatically whenever a
**GitHub Release is published**. It uses PyPI
[trusted publishing](https://docs.pypi.org/trusted-publishers/) (OIDC), so no
API token is stored in the repo. One-time setup:

1. On PyPI, go to the project (or "Publishing" → "Add a pending publisher")
   and add a **GitHub Actions** trusted publisher:
   - Owner: `MartinGallagher-code`
   - Repository: `iperf_orchestrator`
   - Workflow name: `publish.yml`
   - Environment name: `pypi`
2. In the GitHub repo, create an environment named `pypi` (Settings →
   Environments) if you want approval gates.
3. Push a tag for the version on `main` and publish a Release (e.g.
   `v1.0.0`). The workflow builds, runs `twine check`, and publishes to PyPI.

## Continuous integration

`.github/workflows/ci.yml` runs the bash test suite (`tests/run_tests.sh`) on
every push and pull request to `main`, and its **version** job runs
`tests/check_version.sh` (above).
