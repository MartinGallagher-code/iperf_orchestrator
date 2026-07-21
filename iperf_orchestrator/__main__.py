"""Allow ``python -m iperf_orchestrator`` as an alternative to the console script."""

from .cli import main

if __name__ == "__main__":
    raise SystemExit(main())
