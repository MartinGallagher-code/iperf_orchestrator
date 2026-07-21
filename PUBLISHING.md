# Publishing to PyPI

This project ships as the `iperf-orchestrator` distribution on PyPI. The
package is a thin Python wrapper that bundles and runs the bash orchestrator;
see `pyproject.toml` for the metadata.

## Prerequisites

- Python 3.8+ with `build` and `twine`:
  ```bash
  python -m pip install --upgrade build twine
  ```

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

## Continuous integration & coverage

`.github/workflows/ci.yml` runs the tests on every push and pull request to
`main` and reports coverage to [Codecov](https://about.codecov.io/):

- the **bash** orchestrator is measured with
  [`kcov`](https://github.com/SimonKagstrom/kcov) (built from source, since it
  is no longer packaged on Ubuntu 24.04);
- the **Python** console-script wrapper is measured with `coverage.py` via
  `pytest tests/test_cli_wrapper.py`.

Note that kcov measures *bash* lines only: the embedded Python heredocs
(parse/pivot/heatmap) and the remote-command strings sent over SSH execute in
separate interpreters/hosts and cannot be line-instrumented by a bash coverage
tool, so the reported bash percentage has a structural ceiling well below 100%.

To enable the upload, add a `CODECOV_TOKEN` repository secret (Settings →
Secrets and variables → Actions) with the token from your Codecov project. The
Codecov step does not fail CI if the token is missing, so the test job stays
green either way.
