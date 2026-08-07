#!/usr/bin/env python3
"""Expose a narrowly-scoped Codex App Server client as a Hermes MCP tool."""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import Context, FastMCP
from mcp.server.session import ServerSession
from pydantic import BaseModel, Field


MCP = FastMCP(name="Hermes Codex bridge")


class ApprovalConfirmation(BaseModel):
    approved: bool = Field(
        description="Approve this exact Codex command or file change once."
    )


def _env_bool(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes", "on"}


def _env_list(name: str) -> set[str]:
    value = os.environ.get(name, "")
    return {part.strip() for part in value.split(",") if part.strip()}


def _resolve_workspace(value: str) -> Path:
    try:
        path = Path(value).expanduser().resolve(strict=True)
    except (FileNotFoundError, RuntimeError) as exc:
        raise ValueError(f"working_directory does not exist: {value}") from exc
    if not path.is_dir():
        raise ValueError(f"working_directory is not a directory: {path}")

    protected = {
        Path(candidate).resolve()
        for candidate in (
            os.environ.get("CODEX_HOME"),
            os.environ.get("HERMES_HOME"),
            os.environ.get("SECRETS_DIR"),
        )
        if candidate
    }
    for root in protected:
        if path == root or root in path.parents:
            raise ValueError(f"working_directory is a protected runtime path: {path}")
    return path


def _select_override(value: str | None, *, env_name: str, allowed_name: str) -> str | None:
    default = os.environ.get(env_name) or None
    allowed = _env_list(allowed_name)
    if value is not None and value not in allowed:
        permitted = ", ".join(sorted(allowed)) if allowed else "none"
        raise ValueError(
            f"{value!r} is not a permitted override; allowed values: {permitted}"
        )
    return value if value is not None else default


class AppServerError(RuntimeError):
    pass


class CodexAppServer:
    def __init__(self, context: Context[ServerSession, None], timeout: float):
        self.context = context
        self.timeout = timeout
        self.deadline = 0.0
        self.next_id = 1
        self.process: asyncio.subprocess.Process | None = None
        self.stderr_task: asyncio.Task[None] | None = None
        self.stderr_lines: list[str] = []
        self.summary = ""
        self.changed_files: list[str] = []
        self.commands: list[dict[str, Any]] = []
        self.errors: list[str] = []
        self.turn_status = "in_progress"
        self.thread_id: str | None = None

    async def __aenter__(self) -> "CodexAppServer":
        self.deadline = asyncio.get_running_loop().time() + self.timeout
        self.process = await asyncio.create_subprocess_exec(
            "codex",
            "app-server",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        self.stderr_task = asyncio.create_task(self._drain_stderr())
        await self.request(
            "initialize",
            {
                "clientInfo": {
                    "name": "hermes_codex_bridge",
                    "title": "Hermes Codex Bridge",
                    "version": "0.1.0",
                }
            },
        )
        await self.notify("initialized", {})
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        if self.process is not None and self.process.returncode is None:
            self.process.terminate()
            try:
                await asyncio.wait_for(self.process.wait(), timeout=5)
            except asyncio.TimeoutError:
                self.process.kill()
                await self.process.wait()
        if self.stderr_task is not None:
            await self.stderr_task

    async def _drain_stderr(self) -> None:
        assert self.process is not None and self.process.stderr is not None
        while line := await self.process.stderr.readline():
            self.stderr_lines.append(line.decode(errors="replace").rstrip())
            self.stderr_lines = self.stderr_lines[-100:]

    def _remaining(self) -> float:
        remaining = self.deadline - asyncio.get_running_loop().time()
        if remaining <= 0:
            raise TimeoutError(f"Codex task exceeded {self.timeout:.0f} seconds")
        return remaining

    async def _send(self, message: dict[str, Any]) -> None:
        assert self.process is not None and self.process.stdin is not None
        self.process.stdin.write((json.dumps(message, separators=(",", ":")) + "\n").encode())
        await self.process.stdin.drain()

    async def notify(self, method: str, params: dict[str, Any]) -> None:
        await self._send({"method": method, "params": params})

    async def _read(self) -> dict[str, Any]:
        assert self.process is not None and self.process.stdout is not None
        line = await asyncio.wait_for(self.process.stdout.readline(), timeout=self._remaining())
        if not line:
            detail = "\n".join(self.stderr_lines[-10:])
            raise AppServerError(f"Codex App Server exited unexpectedly.\n{detail}".rstrip())
        try:
            return json.loads(line)
        except json.JSONDecodeError as exc:
            raise AppServerError(f"Codex App Server emitted invalid JSON: {line!r}") from exc

    async def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        request_id = self.next_id
        self.next_id += 1
        await self._send({"method": method, "id": request_id, "params": params})
        while True:
            message = await self._read()
            if message.get("id") == request_id and ("result" in message or "error" in message):
                if "error" in message:
                    error = message["error"]
                    raise AppServerError(
                        f"Codex App Server {method} failed: {error.get('message', error)}"
                    )
                return message.get("result") or {}
            await self._handle_message(message)

    async def _approval(self, method: str, params: dict[str, Any]) -> str:
        if method == "item/commandExecution/requestApproval":
            subject = params.get("command") or "an unspecified command"
            detail = f"Codex requests permission to run in {params.get('cwd', 'unknown cwd')}:\n{subject}"
        else:
            subject = params.get("grantRoot") or "the proposed file change"
            detail = f"Codex requests permission for {subject}."
        if params.get("reason"):
            detail += f"\nReason: {params['reason']}"

        result = await self.context.elicit(
            message=detail,
            schema=ApprovalConfirmation,
        )
        if result.action == "accept":
            return "accept"
        if result.action == "cancel":
            return "cancel"
        return "decline"

    async def _handle_server_request(self, message: dict[str, Any]) -> None:
        method = message.get("method", "")
        request_id = message.get("id")
        params = message.get("params") or {}
        if method in {
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
        }:
            decision = await self._approval(method, params)
            await self._send({"id": request_id, "result": {"decision": decision}})
            return
        if method == "mcpServer/elicitation/request":
            await self._send(
                {"id": request_id, "result": {"action": "decline", "content": None, "_meta": None}}
            )
            return

        # Unknown client-side actions and permission-profile expansion are not
        # safe to guess. A JSON-RPC error makes the request fail closed.
        await self._send(
            {
                "id": request_id,
                "error": {"code": -32601, "message": f"Unsupported App Server request: {method}"},
            }
        )

    def _record_item(self, item: dict[str, Any]) -> None:
        item_type = item.get("type")
        if item_type == "agentMessage":
            self.summary = item.get("text", self.summary)
        elif item_type == "commandExecution":
            self.commands.append(
                {
                    "command": item.get("command"),
                    "cwd": item.get("cwd"),
                    "status": item.get("status"),
                    "exit_code": item.get("exitCode"),
                }
            )
        elif item_type == "fileChange":
            for change in item.get("changes") or []:
                path = change.get("path")
                if path and path not in self.changed_files:
                    self.changed_files.append(path)

    async def _handle_message(self, message: dict[str, Any]) -> None:
        if "method" in message and "id" in message:
            await self._handle_server_request(message)
            return
        method = message.get("method")
        params = message.get("params") or {}
        if method == "item/completed":
            self._record_item(params.get("item") or {})
        elif method == "error":
            error = params.get("error") or params
            self.errors.append(str(error.get("message", error)))
        elif method == "turn/completed":
            turn = params.get("turn") or {}
            self.turn_status = str(turn.get("status", "failed")).lower()

    async def run(
        self,
        *,
        prompt: str,
        cwd: Path,
        model: str | None,
        effort: str | None,
    ) -> dict[str, Any]:
        approval_policy = os.environ.get("CODEX_APPROVAL_POLICY", "on-request")
        reviewer = os.environ.get("CODEX_APPROVALS_REVIEWER", "user")
        sandbox_mode = os.environ.get("CODEX_SANDBOX_MODE", "workspace-write")
        network_access = _env_bool("CODEX_NETWORK_ACCESS", False)

        thread_params: dict[str, Any] = {
            "cwd": str(cwd),
            "approvalPolicy": approval_policy,
            "approvalsReviewer": reviewer,
            "sandbox": sandbox_mode,
        }
        if model:
            thread_params["model"] = model
        thread = await self.request("thread/start", thread_params)
        self.thread_id = thread["thread"]["id"]

        sandbox_policy: dict[str, Any]
        if sandbox_mode == "workspace-write":
            sandbox_policy = {
                "type": "workspaceWrite",
                "writableRoots": [str(cwd)],
                "networkAccess": network_access,
                "excludeTmpdirEnvVar": True,
                "excludeSlashTmp": True,
            }
        elif sandbox_mode == "read-only":
            sandbox_policy = {"type": "readOnly", "networkAccess": network_access}
        elif sandbox_mode == "danger-full-access":
            sandbox_policy = {"type": "dangerFullAccess"}
        else:
            raise ValueError(f"unsupported CODEX_SANDBOX_MODE: {sandbox_mode}")

        turn_params: dict[str, Any] = {
            "threadId": self.thread_id,
            "input": [{"type": "text", "text": prompt, "textElements": []}],
            "cwd": str(cwd),
            "approvalPolicy": approval_policy,
            "approvalsReviewer": reviewer,
            "sandboxPolicy": sandbox_policy,
        }
        if model:
            turn_params["model"] = model
        if effort:
            turn_params["effort"] = effort
        await self.request("turn/start", turn_params)

        while self.turn_status not in {"completed", "failed", "interrupted"}:
            await self._handle_message(await self._read())

        return {
            "status": self.turn_status,
            "thread_id": self.thread_id,
            "working_directory": str(cwd),
            "model": model,
            "reasoning_effort": effort,
            "summary": self.summary,
            "changed_files": self.changed_files,
            "commands_run": self.commands,
            "errors": self.errors,
        }


@MCP.tool()
async def codex_task(
    goal: str,
    working_directory: str,
    ctx: Context[ServerSession, None],
    context: str = "",
    model: str | None = None,
    reasoning_effort: str | None = None,
) -> dict[str, Any]:
    """Delegate an explicit coding task to Codex in an existing directory.

    This is for architecture design, implementation, debugging, refactoring,
    code review, and code-related verification. Architecture and review tasks
    are read-only unless the goal explicitly requests implementation. It does
    not route ordinary Hermes delegation. The directory must already exist
    inside the container. Model and effort overrides are accepted only when
    operator configuration permits them.
    """
    cwd = _resolve_workspace(working_directory)
    selected_model = _select_override(
        model, env_name="CODEX_MODEL", allowed_name="CODEX_ALLOWED_MODELS"
    )
    selected_effort = _select_override(
        reasoning_effort,
        env_name="CODEX_REASONING_EFFORT",
        allowed_name="CODEX_ALLOWED_REASONING_EFFORTS",
    )
    prompt = goal.strip()
    if context.strip():
        prompt += f"\n\nSupporting context and acceptance criteria:\n{context.strip()}"
    timeout = float(os.environ.get("CODEX_TASK_TIMEOUT", "1800"))
    async with CodexAppServer(ctx, timeout) as server:
        return await server.run(
            prompt=prompt,
            cwd=cwd,
            model=selected_model,
            effort=selected_effort,
        )


def main() -> None:
    MCP.run(transport="stdio")


if __name__ == "__main__":
    main()
