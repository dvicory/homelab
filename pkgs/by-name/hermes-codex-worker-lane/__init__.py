"""Register the Nix-managed Codex CLI as a Hermes Kanban worker lane."""

from __future__ import annotations

import os
import json
from pathlib import Path
import subprocess
import sys

from hermes_cli import kanban_db
from hermes_cli.worker_lanes import WorkerLane, kanban_worker_env


_WORKER_ENV_KEYS = {
    "CODEX_EXECUTABLE",
    "CODEX_HOME",
    "CODEX_MODEL",
    "CODEX_REASONING_EFFORT",
    "HOME",
    "HERMES_HOME",
    "LANG",
    "LC_ALL",
    "PATH",
    "PYTHONPATH",
    "SSL_CERT_FILE",
    "TERM",
    "TMPDIR",
}


def _isolated_worker_env(task, workspace: str, *, board: str | None) -> dict[str, str]:
    """Build the Kanban contract without forwarding gateway credentials."""
    inherited = kanban_worker_env(task, workspace, board=board)
    return {
        key: value
        for key, value in inherited.items()
        if key in _WORKER_ENV_KEYS
        or key.startswith("HERMES_KANBAN_")
        or key == "TERMINAL_CWD"
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


def _spawn_codex_worker(
    task,
    workspace: str,
    *,
    board: str | None = None,
    lane: dict,
) -> int:
    """Start one detached worker and return its PID to the dispatcher."""
    path = _validated_workspace(workspace)
    env = _isolated_worker_env(task, str(path), board=board)
    env["HERMES_PROFILE"] = lane["name"]
    env["CODEX_APPROVAL_POLICY"] = lane["approvalPolicy"]
    env["CODEX_APPROVALS_REVIEWER"] = lane["approvalsReviewer"]
    env["CODEX_SANDBOX_MODE"] = lane["sandboxMode"]
    env["CODEX_NETWORK_ACCESS"] = str(lane["networkAccess"]).lower()
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
                spawn_fn=spawn,
                max_concurrency=int(lane.get("maxConcurrency", 1)),
            )
        )
