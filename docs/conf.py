# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
"""Sphinx configuration for the iperf-orchestrator documentation.

The documentation is a thin shell around the files that already live at
the repository root: every page pulls its body out of README.md (or
CHANGELOG.md / PUBLISHING.md) with an `include` directive, so there is
exactly one copy of the prose and the site cannot drift from the repo.

This file is built by Read the Docs on a modern Python, not by the
orchestrator's own 3.6 floor -- it is tooling, never shipped in the
wheel, and `tests/check_python_compat.sh` does not scan it.
"""

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# -- Project information ----------------------------------------------------

project = "iperf-orchestrator"
author = "Martin J. Gallagher"
copyright = "2026, Martin J. Gallagher"  # noqa: A001 (Sphinx expects this name)


def _read_version():
    """Scrape __version__ without importing the package.

    Importing would drag in numpy/matplotlib, which the docs build has no
    reason to install. The regex is anchored so it can only match the one
    assignment the release process updates.
    """
    init = (REPO_ROOT / "iperf_orchestrator" / "__init__.py").read_text()
    match = re.search(r'^__version__ = "([^"]+)"', init, re.MULTILINE)
    if not match:
        raise RuntimeError("could not find __version__ in iperf_orchestrator/__init__.py")
    return match.group(1)


release = _read_version()
version = ".".join(release.split(".")[:2])

# -- General configuration --------------------------------------------------

extensions = [
    "myst_parser",
    "sphinx_copybutton",
]

# The repo is written in Markdown; there is no reStructuredText source.
source_suffix = {".md": "markdown"}

myst_enable_extensions = [
    "colon_fence",
    "deflist",
    "fieldlist",
]

# Give every heading down to <h3> a stable anchor so cross-page links
# (and links from outside) can target a specific subsection.
myst_heading_anchors = 3

exclude_patterns = ["_build", "Thumbs.db", ".DS_Store"]

# -- HTML output ------------------------------------------------------------

html_theme = "furo"
html_title = "iperf-orchestrator %s" % release
html_static_path = ["_static"]

html_theme_options = {
    "source_repository": "https://github.com/MartinGallagher-code/iperf_orchestrator/",
    "source_branch": "main",
    "source_directory": "docs/",
}
