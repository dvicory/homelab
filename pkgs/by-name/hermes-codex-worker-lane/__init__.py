"""Register the Nix-managed Codex CLI as a Hermes Kanban worker lane."""

from __future__ import annotations

import os
import json
from pathlib import Path
import subprocess
import sys

from hermes_cli import kanban_db
from hermes_cli.worker_lanes import WorkerLane, kanban_worker_identity_env
from hermes_cli.worker_catalogue import WorkerResolutionError, WorkerSpecification


_WORKER_ENV_KEYS = {
    "CODEX_EXECUTABLE",
    "CODEX_HOME",
    "GONDOLIN_EFFECT_CONTROL_SOCKET",
    "HERMES_HOME",
    "HERMES_BUNDLED_PLUGINS",
    "HERMES_WORKSPACE_HANDOFF",
    "HOME",
    "LANG",
    "LC_ALL",
    "PATH",
    "PYTHONPATH",
    "SSL_CERT_FILE",
    "TERM",
    "TMPDIR",
}

_WORKSPACE_DATA_ENV = "HERMES_BROKER_WORKSPACE_DATA"


def _isolated_worker_env(task, *, board: str | None) -> dict[str, str]:
    """Build the opaque Kanban identity contract without gateway credentials."""
    inherited = kanban_worker_identity_env(task, board=board)
    return {
        key: value
        for key, value in inherited.items()
        if key in _WORKER_ENV_KEYS or key.startswith("HERMES_KANBAN_")
    }


def _validated_workspace(workspace: str) -> Path:
    path = Path(workspace).resolve(strict=True)
    root = Path(os.environ.get("WORKSPACE_ROOT", "/home/hermes/workspace")).resolve(
        strict=True
    )
    if not path.is_dir():
        raise ValueError(f"Codex worker workspace is not a directory: {path}")
    if path != root and root not in path.parents:
        raise ValueError(f"Codex worker workspace is outside WORKSPACE_ROOT: {path}")
    return path


def _broker_workspace_id(task) -> str:
    """Resolve the durable workspace binding for a broker task run."""
    from tools.environments.gondolin import BrokerClient, broker_environment_key

    endpoint = os.environ.get("GONDOLIN_EFFECT_CONTROL_SOCKET", "").strip()
    if not endpoint:
        raise WorkerResolutionError(
            "workspace_binding_missing", "broker control socket is not configured"
        )
    client = BrokerClient(endpoint, timeout=30.0)
    try:
        status = client.authority_status(broker_environment_key(task.id))
    finally:
        client.close()
    workspace_id = status.get("workspaceId")
    if not isinstance(workspace_id, str) or not workspace_id:
        raise WorkerResolutionError(
            "workspace_binding_missing",
            "broker task run has no activated workspace binding",
        )
    return workspace_id


def _broker_work_plane(task) -> Path:
    """Map a broker task to its host-side three-plane work directory."""
    data_root = os.environ.get(_WORKSPACE_DATA_ENV, "").strip()
    if not data_root:
        raise WorkerResolutionError(
            "workspace_binding_missing",
            f"{_WORKSPACE_DATA_ENV} is not configured for broker workspaces",
        )
    root = Path(data_root).resolve(strict=True)
    work_plane = (root / _broker_workspace_id(task) / "work").resolve(strict=True)
    if root not in work_plane.parents:
        raise WorkerResolutionError(
            "workspace_binding_missing", "broker work plane escapes the data root"
        )
    if not work_plane.is_dir():
        raise WorkerResolutionError(
            "workspace_binding_missing",
            f"broker work plane is not a directory: {work_plane}",
        )
    return work_plane


def _resolved_worker_spec(task, lane: dict) -> WorkerSpecification:
    spec = getattr(task, "_worker_specification", None)
    if not isinstance(spec, WorkerSpecification):
        raise WorkerResolutionError(
            "worker_spec_missing", "Codex workers require a resolved worker specification"
        )
    if spec.runtime != "external" or spec.plugin != "codex-cli":
        raise WorkerResolutionError(
            "external_runtime_mismatch", "worker specification does not select Codex CLI"
        )
    if spec.lane != lane["name"]:
        raise WorkerResolutionError(
            "external_lane_mismatch", "registered Codex lane conflicts with worker specification"
        )
    if getattr(task, "workspace_kind", None) == "broker" and spec.provider != "broker-project":
        raise WorkerResolutionError(
            "external_provider_unsupported",
            "broker Codex workers require the broker-project provider",
        )
    sandbox = {
        "read-only": "read-only",
        "workspace-write": "workspace-write",
    }.get(spec.permission)
    if sandbox is None or sandbox != lane["sandboxMode"]:
        raise WorkerResolutionError(
            "external_permission_unsupported",
            "Codex sandbox cannot enforce the resolved permission",
        )
    expected_policy = {
        "approvalPolicy": lane["approvalPolicy"],
        "approvalReviewer": lane["approvalsReviewer"],
        "networkAccess": lane["networkAccess"],
    }
    for field, expected in expected_policy.items():
        if spec.policy.get(field) != expected:
            raise WorkerResolutionError(
                "external_policy_mismatch",
                f"Codex lane configuration conflicts with policy field {field}",
            )
    unsupported = [
        field
        for field in ("soul", "tools", "toolsets", "skills")
        if spec.agent.get(field)
    ]
    if unsupported:
        raise WorkerResolutionError(
            "external_worker_field_unsupported",
            "Codex adapter does not support agent fields: " + ", ".join(unsupported),
        )
    if spec.memory != "disabled":
        raise WorkerResolutionError(
            "external_worker_field_unsupported",
            "Codex adapter supports only disabled Hermes memory",
        )
    return spec


def _spawn_codex_worker(
    task,
    workspace: str,
    *,
    board: str | None = None,
    lane: dict,
) -> int:
    """Start one detached worker and return its PID to the dispatcher."""
    is_broker = getattr(task, "workspace_kind", None) == "broker"
    path = _broker_work_plane(task) if is_broker else _validated_workspace(workspace)
    _resolved_worker_spec(task, lane)
    env = _isolated_worker_env(task, board=board)
    if is_broker:
        # The worker subprocess maps the durable broker binding to its
        # host-side planes; it never sees the guest mount path.
        env["HERMES_WORKSPACE_HOST_PATH"] = str(path)
    if task.branch_name:
        env["HERMES_KANBAN_BRANCH"] = task.branch_name

    log_path = kanban_db.worker_log_path(task.id, board=board)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_file = log_path.open("ab")
    command = [sys.executable, str(Path(__file__).with_name("worker.py"))]
    try:
        process = subprocess.Popen(
            command,
            cwd=path,
            stdin=subprocess.DEVNULL,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )
    finally:
        # Popen duplicates the descriptor into the child. The gateway must not
        # retain one descriptor per dispatched task for its entire lifetime.
        log_file.close()
    return process.pid


def _declared_lanes() -> list[dict]:
    raw = os.environ.get("CODEX_WORKER_LANES", "").strip()
    if not raw:
        raise ValueError("CODEX_WORKER_LANES must declare at least one lane")
    try:
        lanes = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError("CODEX_WORKER_LANES is not valid JSON") from exc
    if not isinstance(lanes, list) or not lanes:
        raise ValueError("CODEX_WORKER_LANES must be a non-empty JSON list")
    normalized = []
    for lane in lanes:
        if not isinstance(lane, dict):
            raise ValueError("each CODEX_WORKER_LANES entry must be an object")
        required = {
            "name",
            "description",
            "approvalPolicy",
            "approvalsReviewer",
            "sandboxMode",
            "networkAccess",
        }
        missing = sorted(required - lane.keys())
        if missing:
            raise ValueError(f"Codex worker lane is missing fields: {', '.join(missing)}")
        if lane["sandboxMode"] not in {"read-only", "workspace-write"}:
            raise ValueError(f"unsupported sandbox for lane {lane['name']!r}")
        if lane["approvalPolicy"] not in {"untrusted", "on-request", "never"}:
            raise ValueError(f"unsupported approval policy for lane {lane['name']!r}")
        if lane["approvalsReviewer"] not in {"user", "auto_review"}:
            raise ValueError(f"unsupported approvals reviewer for lane {lane['name']!r}")
        if not isinstance(lane["networkAccess"], bool):
            raise ValueError(f"networkAccess must be boolean for lane {lane['name']!r}")
        if lane["approvalPolicy"] != "never":
            raise ValueError(
                f"detached Codex lane {lane['name']!r} must disable approvals"
            )
        workspace_kinds = lane.get("workspaceKinds", ["dir", "worktree"])
        if (
            not isinstance(workspace_kinds, list)
            or not workspace_kinds
            or any(kind not in {"dir", "worktree", "broker", "scratch"} for kind in workspace_kinds)
        ):
            raise ValueError(
                f"unsupported workspaceKinds for lane {lane['name']!r}"
            )
        lane["workspaceKinds"] = workspace_kinds
        normalized.append(lane)
    return normalized


def register(ctx) -> None:
    for lane in _declared_lanes():
        name = lane["name"]

        def spawn(task, workspace, *, board=None, _lane=lane):
            return _spawn_codex_worker(
                task,
                workspace,
                board=board,
                lane=_lane,
            )

        ctx.register_worker_lane(
            WorkerLane(
                name=name,
                kind="codex-cli",
                description=lane["description"],
                spawn_fn=spawn,
                max_concurrency=int(lane.get("maxConcurrency", 1)),
                allowed_workspace_kinds=frozenset(lane["workspaceKinds"]),
                default_workspace_kind=(
                    "broker" if "broker" in lane["workspaceKinds"] else "worktree"
                ),
            )
        )
