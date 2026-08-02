from __future__ import annotations

import importlib.util
import json
import os
import subprocess
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
            "BWRAP_EXECUTABLE": "/resolved/bwrap",
            "CODEX_WORKER_LANES": '[{"name":"codex"}]',
            "PATH": "/bin",
            "PYTHONPATH": "/patched-hermes",
            "HERMES_KANBAN_TASK": "task-1",
            "HERMES_BUNDLED_PLUGINS": "/nix/store/plugins",
            "TELEGRAM_BOT_TOKEN": "must-not-escape",
            "OPENAI_API_KEY": "must-not-escape",
        },
    )

    env = plugin._isolated_worker_env(SimpleNamespace(), board=None)

    assert env["HERMES_KANBAN_TASK"] == "task-1"
    assert env["PYTHONPATH"] == "/patched-hermes"
    assert env["BWRAP_EXECUTABLE"] == "/resolved/bwrap"
    assert env["CODEX_WORKER_LANES"] == '[{"name":"codex"}]'
    assert env["HERMES_BUNDLED_PLUGINS"] == "/nix/store/plugins"
    assert "TELEGRAM_BOT_TOKEN" not in env
    assert "OPENAI_API_KEY" not in env


def test_git_trust_is_limited_to_assigned_workspace(plugin, tmp_path):
    workspace = tmp_path / "broker-workspace" / "work"
    workspace.mkdir(parents=True)
    subprocess.run(["git", "init", "-q"], cwd=workspace, check=True)
    env = {**os.environ, "GIT_TEST_ASSUME_DIFFERENT_OWNER": "1"}

    denied = subprocess.run(
        ["git", "status", "--short"],
        cwd=workspace,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert denied.returncode == 128
    assert "dubious ownership" in denied.stderr

    plugin._allow_assigned_git_workspace(env, workspace)
    allowed = subprocess.run(
        ["git", "status", "--short"],
        cwd=workspace,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )

    assert allowed.returncode == 0
    assert env["GIT_CONFIG_COUNT"] == "1"
    assert env["GIT_CONFIG_KEY_0"] == "safe.directory"
    assert env["GIT_CONFIG_VALUE_0"] == str(workspace)
    assert "*" not in env.values()


def test_spawn_scopes_git_trust_to_resolved_work_plane(
    plugin, monkeypatch, tmp_path
):
    workspace = tmp_path / "broker-workspace" / "work"
    workspace.mkdir(parents=True)
    captured = {}
    task = SimpleNamespace(
        id="task-1",
        workspace_kind="broker",
        branch_name=None,
    )
    monkeypatch.setattr(plugin, "_broker_work_plane", lambda _task: workspace)
    monkeypatch.setattr(plugin, "_resolved_worker_spec", lambda *_args: None)
    monkeypatch.setattr(
        plugin,
        "_isolated_worker_env",
        lambda *_args, **_kwargs: {"PATH": "/bin"},
    )
    monkeypatch.setattr(
        plugin.kanban_db,
        "worker_log_path",
        lambda *_args, **_kwargs: tmp_path / "worker.log",
    )

    class Process:
        pid = 1234

    def popen(_command, **kwargs):
        captured.update(kwargs)
        return Process()

    monkeypatch.setattr(plugin.subprocess, "Popen", popen)

    assert plugin._spawn_codex_worker(task, "/unused", board="homelab", lane={}) == 1234
    assert captured["cwd"] == workspace
    assert captured["env"]["GIT_CONFIG_COUNT"] == "1"
    assert captured["env"]["GIT_CONFIG_KEY_0"] == "safe.directory"
    assert captured["env"]["GIT_CONFIG_VALUE_0"] == str(workspace)


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


def test_broker_codex_command_projects_only_canonical_workspace(worker, monkeypatch):
    monkeypatch.setenv("BWRAP_EXECUTABLE", "/nix/store/bubblewrap/bin/bwrap")
    workspace = Path("/home/hermes/broker-workspaces/task-1/work")
    codex_command = [
        "/nix/store/codex/bin/codex",
        "exec",
        "--cd",
        "/workspace/work",
    ]

    command = worker._broker_codex_command(codex_command, workspace)

    task_bind = command.index(str(workspace.parent))
    assert command[task_bind - 1 : task_bind + 2] == [
        "--bind",
        str(workspace.parent),
        "/workspace",
    ]
    storage_hide = command.index(str(workspace.parent.parent))
    assert command[storage_hide - 1 : storage_hide + 1] == [
        "--tmpfs",
        str(workspace.parent.parent),
    ]
    assert command[-len(codex_command) :] == codex_command
    assert "--unshare-user" in command
    assert "--unshare-pid" in command
    assert ["--chdir", "/workspace/work"] == command[-len(codex_command) - 2 : -len(codex_command)]


def test_broker_codex_child_environment_hides_physical_workspace(worker, monkeypatch):
    monkeypatch.setenv(
        "HERMES_WORKSPACE_HOST_PATH",
        "/home/hermes/broker-workspaces/task-1/work",
    )
    monkeypatch.setenv("GIT_CONFIG_KEY_0", "safe.directory")
    monkeypatch.setenv(
        "GIT_CONFIG_VALUE_0",
        "/home/hermes/broker-workspaces/task-1/work",
    )

    child_env = worker._codex_child_env(broker_workspace=True)

    assert "HERMES_WORKSPACE_HOST_PATH" not in child_env
    assert child_env["TERMINAL_CWD"] == "/workspace/work"
    assert child_env["HERMES_WORKSPACE_WORK_DIR"] == "/workspace/work"
    assert child_env["GIT_CONFIG_VALUE_0"] == "/workspace/work"


def test_broker_worker_requires_registered_completion_hook(worker, monkeypatch):
    discovered = []
    monkeypatch.setattr(worker, "discover_plugins", lambda: discovered.append(True))
    monkeypatch.setattr(worker, "has_hook", lambda name: False)

    with pytest.raises(
        worker.WorkerResolutionError, match="broker completion hook is not registered"
    ):
        worker._require_broker_completion_hook()

    assert discovered == [True]


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
            "outcome": "completed",
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


def test_worker_reported_blocker_does_not_complete_task(worker, monkeypatch):
    connection = object()
    blocked = {}
    monkeypatch.setattr(worker.kanban_db, "connect", lambda: nullcontext(connection))
    monkeypatch.setattr(
        worker.kanban_db,
        "get_task",
        lambda conn, task_id: SimpleNamespace(status="running"),
    )
    monkeypatch.setattr(
        worker.kanban_db,
        "complete_task",
        lambda *args, **kwargs: pytest.fail("blocked Codex work must not complete"),
    )

    def block(conn, task_id, **kwargs):
        blocked.update(task_id=task_id, **kwargs)
        return True

    monkeypatch.setattr(worker.kanban_db, "block_task", block)

    assert worker._finish_task(
        "task-1",
        42,
        0,
        {
            "outcome": "blocked",
            "summary": "Sandbox initialization failed.",
            "tests": [],
            "remaining_issues": ["No command executed."],
            "artifacts": [],
        },
        [],
        "codex-plan",
    )
    assert blocked["task_id"] == "task-1"
    assert blocked["expected_run_id"] == 42
    assert blocked["kind"] == "transient"
    assert blocked["reason"].startswith("Codex reported that the task is blocked:")


def _lane_config(**overrides):
    lane = {
        "name": "codex",
        "description": "implementation that may modify files",
        "approvalPolicy": "never",
        "approvalsReviewer": "user",
        "sandboxMode": "workspace-write",
        "networkAccess": True,
    }
    lane.update(overrides)
    return lane


def test_declared_lanes_accepts_broker_workspace_kinds(plugin, monkeypatch):
    monkeypatch.setenv(
        "CODEX_WORKER_LANES",
        json.dumps([_lane_config(workspaceKinds=["broker"])]),
    )
    registered = []
    ctx = SimpleNamespace(register_worker_lane=registered.append)

    plugin.register(ctx)

    assert registered[0].allowed_workspace_kinds == frozenset({"broker"})
    assert registered[0].default_workspace_kind == "broker"


def test_declared_lanes_rejects_unknown_workspace_kinds(plugin, monkeypatch):
    monkeypatch.setenv(
        "CODEX_WORKER_LANES",
        json.dumps([_lane_config(workspaceKinds=["broker", "nfs"])]),
    )

    with pytest.raises(ValueError, match="unsupported workspaceKinds"):
        plugin._declared_lanes()


def test_codex_command_grants_bounded_output_plane(worker, monkeypatch, tmp_path):
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
    output_plane = tmp_path / "output"
    output_plane.mkdir()

    command = worker._codex_command(
        tmp_path,
        tmp_path / "result.json",
        worker_spec,
        output_plane=output_plane,
    )

    assert f'permissions.hermes-worker.filesystem={{"{output_plane}"="write"}}' in command
    assert 'permissions.hermes-worker.extends=":workspace"' in command


def test_codex_command_read_only_broker_lane_keeps_writable_output(
    worker, monkeypatch, tmp_path
):
    # A fine-grained filesystem grant keeps the Project worktree native
    # read-only while allowing publication to the sibling output plane.
    monkeypatch.setenv("CODEX_EXECUTABLE", "/nix/store/codex/bin/codex")
    worker_spec = SimpleNamespace(
        permission="read-only",
        policy={
            "approvalPolicy": "never",
            "approvalReviewer": "user",
            "networkAccess": False,
        },
        agent={},
    )
    output_plane = tmp_path / "output"
    output_plane.mkdir()

    command = worker._codex_command(
        tmp_path,
        tmp_path / "result.json",
        worker_spec,
        output_plane=output_plane,
    )

    assert 'permissions.hermes-worker.extends=":read-only"' in command
    assert f'permissions.hermes-worker.filesystem={{"{output_plane}"="write"}}' in command


def test_validated_artifacts_selects_only_normalized_output_paths(worker):
    selected, rejected = worker._validated_artifacts(
        {
            "artifacts": [
                "output/review.md",
                "output/reports",
                "output/review.md",
                "../output/review.md",
                "/workspace/output/review.md",
                "output/../work/secret.txt",
                "work/change.py",
                "output//double.md",
                "output/",
                "",
            ]
        }
    )

    assert selected == ["output/review.md", "output/reports"]
    assert rejected == [
        "../output/review.md",
        "/workspace/output/review.md",
        "output/../work/secret.txt",
        "work/change.py",
        "output//double.md",
        "output/",
        "",
    ]


def test_finish_task_passes_artifacts_and_records_rejections(worker, monkeypatch):
    connection = object()
    completed = {}
    monkeypatch.setattr(worker.kanban_db, "connect", lambda: nullcontext(connection))
    monkeypatch.setattr(
        worker.kanban_db,
        "get_task",
        lambda conn, task_id: SimpleNamespace(status="running"),
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
            "outcome": "completed",
            "summary": "Done.",
            "tests": [],
            "remaining_issues": [],
        },
        [],
        "codex",
        artifacts=["output/review.md"],
        rejected_artifacts=["../output/review.md"],
    )
    assert completed["artifacts"] == ["output/review.md"]
    assert completed["metadata"]["rejected_artifacts"] == ["../output/review.md"]


def test_broker_work_plane_maps_binding_to_host_planes(plugin, monkeypatch, tmp_path):
    data_root = tmp_path / "data"
    work_plane = data_root / "ws-1" / "work"
    work_plane.mkdir(parents=True)
    monkeypatch.setenv("HERMES_BROKER_WORKSPACE_DATA", str(data_root))
    monkeypatch.setattr(plugin, "_broker_workspace_id", lambda task: "ws-1")

    assert plugin._broker_work_plane(SimpleNamespace(id="task-1")) == work_plane


def test_broker_work_plane_requires_data_root(plugin, monkeypatch):
    monkeypatch.delenv("HERMES_BROKER_WORKSPACE_DATA", raising=False)

    with pytest.raises(plugin.WorkerResolutionError, match="HERMES_BROKER_WORKSPACE_DATA"):
        plugin._broker_work_plane(SimpleNamespace(id="task-1"))
