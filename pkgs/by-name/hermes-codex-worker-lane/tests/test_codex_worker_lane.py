from __future__ import annotations

import importlib.util
import json
from contextlib import nullcontext
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
                    "approvalPolicy": "never",
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
    assert registered[0].allowed_workspace_kinds == frozenset({"dir", "worktree"})
    assert registered[0].default_workspace_kind == "worktree"


def test_declared_lanes_rejects_headless_approval_policy(plugin, monkeypatch):
    lane = {
        "name": "architecture-review",
        "description": "read-only architecture and code review",
        "approvalPolicy": "on-request",
        "approvalsReviewer": "user",
        "sandboxMode": "read-only",
        "networkAccess": True,
    }
    monkeypatch.setenv("CODEX_WORKER_LANES", json.dumps([lane]))
    with pytest.raises(ValueError, match="must disable approvals"):
        plugin._declared_lanes()


def test_worker_environment_does_not_forward_gateway_secrets(plugin, monkeypatch):
    monkeypatch.setattr(
        plugin,
        "kanban_worker_identity_env",
        lambda *args, **kwargs: {
            "PATH": "/bin",
            "PYTHONPATH": "/patched-hermes",
            "HERMES_KANBAN_TASK": "task-1",
            "TELEGRAM_BOT_TOKEN": "must-not-escape",
            "OPENAI_API_KEY": "must-not-escape",
        },
    )

    env = plugin._isolated_worker_env(SimpleNamespace(), board=None)

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

    worker_spec = SimpleNamespace(
        permission="workspace-write",
        policy={
            "approvalPolicy": "never",
            "approvalReviewer": "user",
            "networkAccess": False,
        },
        agent={},
    )
    command = worker._codex_command(
        tmp_path,
        tmp_path / "result.json",
        worker_spec,
    )

    assert "--ignore-user-config" in command
    assert 'default_permissions="hermes-worker"' in command
    assert 'permissions.hermes-worker.extends=":workspace"' in command
    assert not any(arg.startswith("sandbox_workspace_write.") for arg in command)


def test_codex_command_makes_read_only_policy_non_elevating(
    worker, monkeypatch, tmp_path
):
    monkeypatch.setenv("CODEX_EXECUTABLE", "/nix/store/codex/bin/codex")
    worker_spec = SimpleNamespace(
        permission="read-only",
        policy={
            "approvalPolicy": "never",
            "approvalReviewer": "user",
            "networkAccess": True,
        },
        agent={},
    )

    command = worker._codex_command(
        tmp_path,
        tmp_path / "result.json",
        worker_spec,
    )

    assert command[command.index("--ask-for-approval") + 1] == "never"
    assert "--sandbox" not in command
    assert 'permissions.hermes-worker.extends=":read-only"' in command
    assert "permissions.hermes-worker.network.enabled=true" in command
    assert 'permissions.hermes-worker.network.mode="full"' in command


def test_codex_command_rejects_missing_policy_facts(worker, monkeypatch, tmp_path):
    monkeypatch.setenv("CODEX_EXECUTABLE", "/nix/store/codex/bin/codex")
    incomplete = SimpleNamespace(
        permission="workspace-write",
        policy={},
        agent={},
    )

    with pytest.raises(RuntimeError, match="must disable approvals"):
        worker._codex_command(tmp_path, tmp_path / "result.json", incomplete)


def test_successful_worker_completes_with_changed_file_metadata(worker, monkeypatch):
    connection = object()
    completed = {}
    monkeypatch.setattr(worker.kanban_db, "connect", lambda: nullcontext(connection))
    monkeypatch.setattr(
        worker.kanban_db,
        "get_task",
        lambda conn, task_id: SimpleNamespace(status="running"),
    )
    monkeypatch.setattr(
        worker.kanban_db,
        "block_task",
        lambda *args, **kwargs: pytest.fail("successful Codex work must not block"),
    )

    def complete(conn, task_id, **kwargs):
        completed.update(task_id=task_id, **kwargs)
        return True

    monkeypatch.setattr(worker.kanban_db, "complete_task", complete)

    assert worker._finish_task(
        "task-1",
        42,
        0,
        {
            "summary": "Implemented the requested change.",
            "tests": ["unit test"],
            "remaining_issues": [],
        },
        ["src/change.py"],
        "codex",
    )
    assert completed["task_id"] == "task-1"
    assert completed["expected_run_id"] == 42
    assert completed["metadata"] == {
        "worker_lane": "codex",
        "changed_files": ["src/change.py"],
        "tests_run": ["unit test"],
        "remaining_issues": [],
        "codex_exit_code": 0,
    }
