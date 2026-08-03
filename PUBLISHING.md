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

## Cut a release

1. **Bump the version** in `pyproject.toml` (`[project].version`) and add a
   matching entry to `CHANGELOG.md`. Follow [SemVer](https://semver.org/).

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
3. Push a tag and publish a Release (e.g. `v1.0.0`). The workflow builds,
   runs `twine check`, and publishes to PyPI.

## Continuous integration

`.github/workflows/ci.yml` runs the bash test suite (`tests/run_tests.sh`) on
every push and pull request to `main`.
