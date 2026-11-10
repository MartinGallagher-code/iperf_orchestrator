# Notes for Claude

iperf-orchestrator runs full-mesh iperf2 throughput tests across a fleet of
Linux hosts over ssh and turns the results into CSV, a pivot table, a heatmap
and layout-viewer overlays. The tool is one self-contained bash script,
`iperf_orchestrator/iperf_orchestrator.sh`; the Python package around it is a
thin wrapper, published on PyPI as `iperf-orchestrator`, that puts the command
on the PATH and pulls in the analysis libraries. `README.md` is the front page
and the source of every page of the manual (`docs/`, Sphinx on Read the Docs);
`PUBLISHING.md` says how the version moves and how a release is published.

## Checks

What CI runs on every pull request into `main` and every push to it
(`.github/workflows/ci.yml` and `.github/workflows/reuse.yml`):

```bash
python -m pip install --upgrade pip numpy matplotlib
./tests/run_tests.sh                                   # test: Python 3.9-3.13

python -m pip install --upgrade vermin                 # python-floor: the 3.6 floor
./tests/check_python_compat.sh --extract-to /tmp/pyblocks
vermin --eval-annotations --violations --target=3.6 /tmp/pyblocks/*.py iperf_orchestrator/*.py
docker run --rm -v "$PWD:/w" -w /w python:3.6-slim \
    bash -euxc './tests/check_python_compat.sh && ./tests/run_tests.sh'
# (then it builds the wheel and installs it with Python 3.6's pip)

python -m pip install -r docs/requirements.txt         # docs
python -m sphinx -b html -W --keep-going docs docs/_build/html

bash tests/check_version.sh origin/main                # version
reuse lint                                             # REUSE (fsfe/reuse-action)
```

## Every task is a ticket

Everything done here goes through a ticket in `MartinGallagher-code/shared_tools`,
which keeps every project's tickets as files and moves each one Backlog → In Progress
→ Review → Done (Adversarial Test only when the owner asks). Before any change:

1. Attach `MartinGallagher-code/shared_tools` with `add_repo` and push access, and
   clone it. If a clone is already here, pull it instead
   (`git -C <shared_tools clone> pull --ff-only`): a stale clone has a stale
   `CLAUDE.md` and a stale `ticket.py`.
2. Read the "Every task is a ticket" section of its `CLAUDE.md`. It sets out what each
   column requires, and none of it is optional.
3. Open the ticket with the shared_tools clone's script, not a path in this
   repository:

   ~~~bash
   <shared_tools clone>/scripts/ticket.py new <this repository's name> "Imperative title" --request "the request, in the user's own words"
   ~~~

**Every change moves the version**, however small: a pull request into `main` raises
it in every place it is written and opens `CHANGELOG.md` with that version's own
dated section, never an "Unreleased" heading left for later. CI fails a pull request
whose version is not greater than its base branch's. This file's own section on the
version says where it is written.

The board: https://claude.ai/artifact/HrB3RpVpqGGQS7UZgZsMJm

## Every change moves the version

The owner's rule (shared_tools BN-002): **whenever this project changes, its version
changes with it**, however small the change: code, tests, docs or CI. A pull request
into `main` carries its own bump and its own `CHANGELOG.md` section, never an
"Unreleased" heading left for later.

- Patch for fixes, docs, tests and CI; minor for anything new a user can use; major
  only when something that worked stops working the way it did.
- In the same pull request: `pyproject.toml`, `iperf_orchestrator/__init__.py` and
  `ORCH_VERSION` in `iperf_orchestrator/iperf_orchestrator.sh`, and a
  `## [X.Y.Z] - YYYY-MM-DD` section at the top of `CHANGELOG.md`.
  `tests/check_version.sh` fails if any of them disagree.
- The **version** job in CI fails a pull request whose version is not greater than its
  base branch's, and a push to `main` whose version is not greater than what `main` had
  before it. If `main` moves while a pull request is open, rebase and bump again.
- Publishing is a separate step, and a person's call: a GitHub Release published by
  hand runs `.github/workflows/publish.yml`, which uploads that version to PyPI
  (`PUBLISHING.md`). A number that is never published is fine; a change with no
  number is not.
