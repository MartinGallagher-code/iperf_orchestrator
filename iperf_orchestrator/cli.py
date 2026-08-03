"""Console-script entry point for iperf-orchestrator.

Locates the bundled ``iperf_orchestrator.sh`` and hands off to it via
``bash``, forwarding every argument unchanged. The bash script is the single
source of truth for the CLI; this wrapper only exists so ``pip install`` can
put an ``iperf-orchestrator`` command on PATH and resolve sane defaults for
paths that would otherwise point inside the install location.
"""

import os
import shutil
import sys
from pathlib import Path
from typing import Dict, List, Optional

#: Name of the bundled orchestrator script (sits next to this module).
SCRIPT_NAME = "iperf_orchestrator.sh"


def script_path() -> Path:
    """Absolute path to the bundled bash orchestrator."""
    return Path(__file__).resolve().parent / SCRIPT_NAME


def _default_environment() -> Dict[str, str]:
    """Environment for the child process.

    When installed, this module lives under ``site-packages``; the script's
    own defaults (``RESULTS_BASE`` and the ``servers.txt`` fallback) resolve
    relative to *its* directory, which would drop results into the install
    tree. Point them at the current working directory instead, but only when
    the user hasn't already chosen a location via env var / flag.
    """
    env = dict(os.environ)
    # Show a clean program name in the script's help/usage instead of the
    # bundled site-packages path.
    env.setdefault("IPERF_ORCH_PROG", "iperf-orchestrator")
    env.setdefault("RESULTS_BASE", str(Path.cwd() / "results"))
    if not env.get("IPERF_SERVERS"):
        local_servers = Path.cwd() / "servers.txt"
        if local_servers.is_file():
            env["IPERF_SERVERS"] = str(local_servers)
    return env


def main(argv: Optional[List[str]] = None) -> int:
    """Run the bundled orchestrator, forwarding ``argv`` to it.

    Returns the script's exit status when it cannot ``exec`` (e.g. on
    platforms without ``os.execvpe``); normally ``exec`` replaces this
    process and the function does not return.
    """
    args = sys.argv[1:] if argv is None else argv

    script = script_path()
    if not script.is_file():
        sys.stderr.write(
            f"iperf-orchestrator: bundled script not found at {script}\n"
        )
        return 1

    bash = shutil.which("bash")
    if bash is None:
        sys.stderr.write(
            "iperf-orchestrator: 'bash' is required but was not found on PATH\n"
        )
        return 1

    env = _default_environment()
    cmd = [bash, str(script), *args]

    # Replace this process so signals and the exit code pass straight through.
    try:
        os.execvpe(bash, cmd, env)
    except OSError as exc:  # pragma: no cover - execvpe rarely returns
        sys.stderr.write(f"iperf-orchestrator: failed to launch bash: {exc}\n")
        return 1
    return 0  # pragma: no cover - unreachable after a successful exec


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
