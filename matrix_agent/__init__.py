# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
"""matrix_agent: sustain an all-to-all traffic matrix indefinitely.

Shipped inside the iperf-orchestrator wheel so `iperf-orchestrator
matrix ...` and the `matrix-agent` console command work out of the box
from a pip install. The implementation lives in ``matrix_agent.py``
(one stdlib-only file) plus ``fleet.sh`` (the SSH fan-out driver).
"""

__all__ = ["main"]


def main():
    # Imported lazily so ``import matrix_agent`` stays cheap.
    from .matrix_agent import main as _main
    import sys
    return _main(sys.argv[1:])
