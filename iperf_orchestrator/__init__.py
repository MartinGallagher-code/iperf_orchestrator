"""iperf-orchestrator: full-mesh iperf2 throughput testing across a fleet.

The tool itself is a self-contained bash script (``iperf_orchestrator.sh``,
shipped alongside this module). This package provides the pip-installable
wrapper that puts an ``iperf-orchestrator`` command on your PATH and pulls in
the Python libraries the analysis steps need.
"""

__version__ = "1.4.0"

__all__ = ["__version__", "main"]


def main() -> "int":
    # Imported lazily so ``import iperf_orchestrator`` stays cheap.
    from .cli import main as _main

    return _main()
