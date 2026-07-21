"""Unit tests for the pip console-script wrapper (iperf_orchestrator.cli).

Run with: python -m pytest tests/test_cli_wrapper.py
Coverage : python -m coverage run -m pytest tests/test_cli_wrapper.py
"""

import sys
from pathlib import Path

import pytest

import iperf_orchestrator
from iperf_orchestrator import cli


def test_version_is_a_string():
    assert isinstance(iperf_orchestrator.__version__, str)
    assert iperf_orchestrator.__version__


def test_script_path_points_at_bundled_script():
    p = cli.script_path()
    assert p.name == "iperf_orchestrator.sh"
    assert p.parent.name == "iperf_orchestrator"


def test_default_environment_sets_defaults(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    for var in ("RESULTS_BASE", "IPERF_ORCH_PROG", "IPERF_SERVERS"):
        monkeypatch.delenv(var, raising=False)
    env = cli._default_environment()
    assert env["IPERF_ORCH_PROG"] == "iperf-orchestrator"
    assert env["RESULTS_BASE"] == str(tmp_path / "results")
    # No servers.txt in cwd -> IPERF_SERVERS stays unset.
    assert "IPERF_SERVERS" not in env


def test_default_environment_picks_up_local_servers(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("IPERF_SERVERS", raising=False)
    (tmp_path / "servers.txt").write_text("host-a\n")
    env = cli._default_environment()
    assert env["IPERF_SERVERS"] == str(tmp_path / "servers.txt")


def test_default_environment_respects_existing_values(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("RESULTS_BASE", "/custom/results")
    monkeypatch.setenv("IPERF_ORCH_PROG", "myprog")
    monkeypatch.setenv("IPERF_SERVERS", "/my/servers.txt")
    # A local servers.txt must NOT override an explicit IPERF_SERVERS.
    (tmp_path / "servers.txt").write_text("host-a\n")
    env = cli._default_environment()
    assert env["RESULTS_BASE"] == "/custom/results"
    assert env["IPERF_ORCH_PROG"] == "myprog"
    assert env["IPERF_SERVERS"] == "/my/servers.txt"


def test_main_execs_bash_with_forwarded_args(monkeypatch):
    captured = {}

    def fake_execvpe(file, args, env):
        captured["file"] = file
        captured["args"] = args
        captured["env"] = env
        # A real exec never returns; returning here lets main() fall through.

    monkeypatch.setattr(cli.shutil, "which", lambda name: "/bin/bash")
    monkeypatch.setattr(cli.os, "execvpe", fake_execvpe)
    rc = cli.main(["run-tests", "rolling"])
    assert rc == 0
    assert captured["file"] == "/bin/bash"
    assert captured["args"][0] == "/bin/bash"
    assert captured["args"][1].endswith("iperf_orchestrator.sh")
    assert captured["args"][2:] == ["run-tests", "rolling"]
    assert captured["env"]["IPERF_ORCH_PROG"] == "iperf-orchestrator"


def test_main_defaults_argv_to_sys_argv(monkeypatch):
    captured = {}
    monkeypatch.setattr(sys, "argv", ["iperf-orchestrator", "status"])
    monkeypatch.setattr(cli.shutil, "which", lambda name: "/bin/bash")
    monkeypatch.setattr(cli.os, "execvpe", lambda f, a, e: captured.update(args=a))
    cli.main()
    assert captured["args"][2:] == ["status"]


def test_main_errors_when_script_missing(monkeypatch, capsys):
    monkeypatch.setattr(cli, "script_path", lambda: Path("/no/such/orchestrator.sh"))
    rc = cli.main([])
    assert rc == 1
    assert "not found" in capsys.readouterr().err


def test_main_errors_when_bash_missing(monkeypatch, capsys):
    monkeypatch.setattr(cli.shutil, "which", lambda name: None)
    rc = cli.main([])
    assert rc == 1
    assert "bash" in capsys.readouterr().err


def test_package_main_delegates_to_cli(monkeypatch):
    monkeypatch.setattr("iperf_orchestrator.cli.main", lambda: 7)
    assert iperf_orchestrator.main() == 7


def test_dunder_main_module_is_importable():
    import importlib

    mod = importlib.import_module("iperf_orchestrator.__main__")
    assert mod.main is cli.main
