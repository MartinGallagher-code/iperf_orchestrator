# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Allow ``python -m iperf_orchestrator`` as an alternative to the console script."""

from .cli import main

if __name__ == "__main__":
    raise SystemExit(main())
