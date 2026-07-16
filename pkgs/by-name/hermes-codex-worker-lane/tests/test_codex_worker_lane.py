from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest


PLUGIN_ROOT = Path(__file__).parents[1]


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def plugin():
    return _load_module("codex_worker_lane_plugin", PLUGIN_ROOT / "__init__.py")


@pytest.fixture
def worker():
    return _load_module("codex_worker_lane_worker", PLUGIN_ROOT / "worker.py")


def test_declared_lanes_rejects_unsafe_sandbox(plugin, monkeypatch):
    monkeypatch.setenv(
        "CODEX_WORKER_LANES",
        json.dumps(
            [
                {
                    "name": "codex",
                    "description": "implementation that may modify files",
                    "approvalPolicy": "on-request",
                    "approvalsReviewer": "auto_review",
                    "sandboxMode": "danger-full-access",
                    "networkAccess": False,
                }
            ]
        ),
    )

    with pytest.raises(ValueError, match="unsupported sandbox"):
        plugin._declared_lanes()


def test_register_passes_description_to_worker_lane(plugin, monkeypatch):
    monkeypatch.setenv(
        "CODEX_WORKER_LANES",
        json.dumps(
            [
                {
                    "name": "architecture-review",
                    "description": "read-only architecture and code review",
                    "approvalPolicy": "on-request",
                    "approvalsReviewer": "auto_review",
                    "sandboxMode": "read-only",
                    "networkAccess": False,
                    "maxConcurrency": 1,
                }
            ]
        ),
    )
    registered = []
    ctx = SimpleNamespace(register_worker_lane=registered.append)

    plugin.register(ctx)

    assert len(registered) == 1
    assert registered[0].name == "architecture-review"
    assert registered[0].description == "read-only architecture and code review"


def test_worker_environment_does_not_forward_gateway_secrets(plugin, monkeypatch):
    monkeypatch.setattr(
        plugin,
        "kanban_worker_env",
        lambda *args, **kwargs: {
            "PATH": "/bin",
            "PYTHONPATH": "/patched-hermes",
            "HERMES_KANBAN_TASK": "task-1",
            "TERMINAL_CWD": "/workspace",
            "TELEGRAM_BOT_TOKEN": "must-not-escape",
            "OPENAI_API_KEY": "must-not-escape",
        },
    )

    env = plugin._isolated_worker_env(SimpleNamespace(), "/workspace", board=None)

    assert env["HERMES_KANBAN_TASK"] == "task-1"
    assert env["PYTHONPATH"] == "/patched-hermes"
    assert "TELEGRAM_BOT_TOKEN" not in env
    assert "OPENAI_API_KEY" not in env


def test_workspace_must_be_below_declared_root(plugin, monkeypatch, tmp_path):
    root = tmp_path / "workspace"
    project = root / "projects" / "example"
    outside = tmp_path / "outside"
    project.mkdir(parents=True)
    outside.mkdir()
    monkeypatch.setenv("WORKSPACE_ROOT", str(root))

    assert plugin._validated_workspace(str(project)) == project
    with pytest.raises(ValueError, match="outside WORKSPACE_ROOT"):
        plugin._validated_workspace(str(outside))


def test_codex_command_enforces_declared_headless_policy(worker, monkeypatch, tmp_path):
    monkeypatch.setenv("CODEX_EXECUTABLE", "/nix/store/codex/bin/codex")
    monkeypatch.setenv("CODEX_APPROVAL_POLICY", "on-request")
    monkeypatch.setenv("CODEX_APPROVALS_REVIEWER", "auto_review")
    monkeypatch.setenv("CODEX_SANDBOX_MODE", "workspace-write")
    monkeypatch.setenv("CODEX_NETWORK_ACCESS", "false")

    command = worker._codex_command(tmp_path, tmp_path / "result.json")

    assert "--ignore-user-config" in command
    assert "workspace-write" in command
    assert 'approvals_reviewer="auto_review"' in command
    assert "sandbox_workspace_write.network_access=false" in command
