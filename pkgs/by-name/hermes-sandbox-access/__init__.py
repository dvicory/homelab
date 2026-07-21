"""Hermes tools and lifecycle hooks for broker-owned sandbox authority."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Any

import httpx

from tools.approval import request_tool_approval
from tools.terminal_tool import (
    clear_task_env_overrides,
    environment_key,
    register_task_authority_binding,
)


_TOOLSET = "sandbox_access"
_SESSION_ENVIRONMENTS: dict[str, str] = {}
_VALID_CHOICES = {"once", "session", "always"}
_VALID_SCOPES = {"once", "task", "conversation", "timed", "profile", "executor"}

_TASK_ENVIRONMENTS: dict[str, str] = {}

@dataclass(frozen=True)
class BrokerProblem(Exception):
    status: int
    reason: str
    detail: str
    details: dict[str, Any]

    def result(self) -> str:
        return json.dumps({
            "ok": False,
            "status": self.status,
            "reason": self.reason,
            "detail": self.detail,
            "details": self.details,
        }, sort_keys=True)

class BrokerClient:
    def __init__(self, socket_path: str | None = None) -> None:
        raw = socket_path or os.environ.get("GONDOLIN_EFFECT_CONTROL_SOCKET", "")
        if not raw or not os.path.isabs(raw):
            raise RuntimeError("GONDOLIN_EFFECT_CONTROL_SOCKET must be an absolute path")
        self._socket_path = raw

    def post(self, path: str, payload: dict[str, Any]) -> Any:
        try:
            with httpx.Client(
                transport=httpx.HTTPTransport(uds=self._socket_path),
                base_url="http://localhost",
                timeout=httpx.Timeout(30.0),
            ) as client:
                response = client.post(path, json=payload)
        except (httpx.HTTPError, OSError) as exc:
            raise BrokerProblem(503, "broker.unavailable", "sandbox broker is unavailable", {
                "cause": str(exc),
            }) from exc
        try:
            body = response.json()
        except (ValueError, json.JSONDecodeError) as exc:
            raise BrokerProblem(502, "broker.invalid_response", "sandbox broker returned invalid JSON", {}) from exc
        if response.is_error:
            if not isinstance(body, dict):
                body = {}
            raise BrokerProblem(
                response.status_code,
                str(body.get("reason") or "broker.error"),
                str(body.get("detail") or "sandbox broker rejected the request"),
                body.get("details") if isinstance(body.get("details"), dict) else {},
            )
        return body


_REQUEST_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["capabilities", "requested_scope", "rationale"],
    "properties": {
        "capabilities": {
            "type": "array",
            "minItems": 1,
            "maxItems": 16,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["kind", "scheme", "host", "address_mode"],
                "properties": {
                    "kind": {"const": "network-origin"},
                    "scheme": {"enum": ["http", "https"]},
                    "host": {"type": "string", "minLength": 1, "maxLength": 253},
                    "ports": {
                        "type": "array",
                        "minItems": 1,
                        "maxItems": 16,
                        "items": {"type": "integer", "minimum": 1, "maximum": 65535},
                    },
                    "address_mode": {"enum": ["public", "pinned-private"]},
                },
            },
        },
        "requested_scope": {"enum": sorted(_VALID_SCOPES)},
        "duration_seconds": {"type": "integer", "minimum": 1, "maximum": 3600},
        "rationale": {"type": "string", "minLength": 1, "maxLength": 2048},
    },
}

_LIST_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {},
}

_REVOKE_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["grant_id"],
    "properties": {
        "grant_id": {"type": "string", "minLength": 1, "maxLength": 256},
    },
}


def _binding_id() -> str:
    value = os.environ.get("HERMES_SANDBOX_AUTHORITY_BINDING", "").strip()
    if not value:
        raise RuntimeError("HERMES_SANDBOX_AUTHORITY_BINDING is not configured")
    return value


def _authority_context(kwargs: dict[str, Any]) -> tuple[str, str | None]:
    task_id = kwargs.get("task_id")
    session_id = kwargs.get("session_id")
    identity = session_id or task_id
    if not isinstance(identity, str) or not identity.strip():
        raise RuntimeError("sandbox authority requires a trusted task or session identity")
    register_task_authority_binding(identity, _binding_id())
    key = environment_key(
        task_id if isinstance(task_id, str) else None,
        session_id if isinstance(session_id, str) else None,
    )
    if isinstance(task_id, str) and task_id:
        _TASK_ENVIRONMENTS[task_id] = key
    if isinstance(session_id, str) and session_id:
        _SESSION_ENVIRONMENTS[session_id] = key
    return key, session_id if isinstance(session_id, str) else None


def _principal() -> str:
    return os.environ.get("HERMES_SANDBOX_APPROVAL_PRINCIPAL", "hermes-paired-user")


def _broker_capabilities(raw: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [{
        "version": 1,
        "kind": item["kind"],
        "scheme": item["scheme"],
        "host": item["host"],
        **({"ports": item["ports"]} if "ports" in item else {}),
        "addressMode": item["address_mode"],
    } for item in raw]


def _canonical_summary(prepared: dict[str, Any], rationale: str) -> str:
    requested_scope = prepared.get("requestedScope")
    session_scope = _scope_for_choice("session", requested_scope)
    lines = ["Network access request (broker verified):"]
    for capability in prepared.get("capabilities", []):
        ports = ",".join(str(port) for port in capability.get("ports", []))
        line = (
            f"- {capability.get('scheme')}://{capability.get('host')} "
            f"ports [{ports}], {capability.get('addressMode')} addresses"
        )
        pins = capability.get("pinnedAddresses") or []
        if pins:
            line += f", pinned [{', '.join(pins)}]"
        lines.append(line)
    duration = prepared.get("durationSeconds")
    lines.extend([
        f"Model-requested scope: {requested_scope}" + (f" ({duration} seconds)" if duration else ""),
        "Effect: network only; no credentials, filesystem access, or VM restart.",
        f"Choices: once=next matching request; session={session_scope}; "
        "always=all tasks for this executor until revoked or policy update.",
        f"Why (model-provided): {rationale}",
    ])
    return "\n".join(lines)


def _scope_for_choice(choice: str, requested: str) -> str:
    if choice == "once":
        return "once"
    if choice == "always":
        return "executor"
    if requested in {"once", "task", "timed"}:
        return requested
    return "conversation"


def _deny_pending(client: BrokerClient, request_id: str) -> None:
    try:
        client.post("/v1/control/access/decide", {
            "requestId": request_id,
            "decision": "deny",
            "principal": _principal(),
        })
    except BrokerProblem:
        pass


def handle_request_access(args: dict[str, Any], **kwargs: Any) -> str:
    try:
        key, _ = _authority_context(kwargs)
        client = BrokerClient()
        payload: dict[str, Any] = {
            "environmentKey": key,
            "capabilities": _broker_capabilities(args["capabilities"]),
            "requestedScope": args["requested_scope"],
            "rationale": args["rationale"],
        }
        if "duration_seconds" in args:
            payload["durationSeconds"] = args["duration_seconds"]
        prepared = client.post("/v1/control/access/prepare", payload)
        if prepared.get("state") in {"active", "existing-pending"}:
            return json.dumps({"ok": True, **prepared}, sort_keys=True)
        request_id = prepared.get("requestId")
        if prepared.get("state") != "pending" or not isinstance(request_id, str):
            raise BrokerProblem(502, "broker.invalid_response", "broker returned invalid preparation state", {})

        approval = request_tool_approval(
            "sandbox_request_access",
            _canonical_summary(prepared, args["rationale"]),
            rule_key=f"sandbox-access:{prepared.get('fingerprint', request_id)}",
        )
        choice = approval.get("choice") if isinstance(approval, dict) else None
        if not isinstance(approval, dict) or not approval.get("approved") or choice not in _VALID_CHOICES:
            _deny_pending(client, request_id)
            return json.dumps({
                "ok": False,
                "reason": "approval.denied",
                "detail": approval.get("message", "sandbox access was not approved")
                if isinstance(approval, dict) else "malformed approval response",
            }, sort_keys=True)

        scope = _scope_for_choice(choice, args["requested_scope"])
        decision: dict[str, Any] = {
            "requestId": request_id,
            "decision": "approve",
            "scope": scope,
            "principal": _principal(),
        }
        if scope == "timed" and "duration_seconds" in args:
            decision["durationSeconds"] = args["duration_seconds"]
        activated = client.post("/v1/control/access/decide", decision)
        return json.dumps({
            "ok": True,
            **activated,
            "scope": scope,
            "retry": "Retry the denied sandbox operation in the same task environment.",
        }, sort_keys=True)
    except BrokerProblem as exc:
        return exc.result()
    except (KeyError, TypeError, ValueError, RuntimeError) as exc:
        return json.dumps({"ok": False, "reason": "request.invalid", "detail": str(exc)}, sort_keys=True)


def _accessible_grants(client: BrokerClient, key: str) -> list[dict[str, Any]]:
    binding = client.post("/v1/control/authority/status", {"environmentKey": key})
    grants = client.post("/v1/control/grants/list", {})
    if not isinstance(grants, list):
        raise BrokerProblem(502, "broker.invalid_response", "broker returned invalid grant list", {})
    return [grant for grant in grants if (
        grant.get("environmentKey") == key
        or (grant.get("scope") == "profile" and grant.get("profile") == binding.get("profile"))
        or (grant.get("scope") == "executor" and grant.get("executor") == binding.get("executor"))
    )]


def handle_access_list(_args: dict[str, Any], **kwargs: Any) -> str:
    try:
        key, _ = _authority_context(kwargs)
        grants = _accessible_grants(BrokerClient(), key)
        return json.dumps({"ok": True, "grants": grants}, sort_keys=True)
    except BrokerProblem as exc:
        return exc.result()
    except RuntimeError as exc:
        return json.dumps({"ok": False, "reason": "request.invalid", "detail": str(exc)}, sort_keys=True)


def handle_access_revoke(args: dict[str, Any], **kwargs: Any) -> str:
    try:
        key, _ = _authority_context(kwargs)
        client = BrokerClient()
        accessible = {grant.get("grantId") for grant in _accessible_grants(client, key)}
        if args["grant_id"] not in accessible:
            raise BrokerProblem(404, "grant.not_found", "grant is not visible to this sandbox authority", {})
        revoked = client.post("/v1/control/grants/revoke", {
            "grantId": args["grant_id"],
            "principal": _principal(),
        })
        return json.dumps({"ok": True, "grant": revoked}, sort_keys=True)
    except BrokerProblem as exc:
        return exc.result()
    except (KeyError, RuntimeError) as exc:
        return json.dumps({"ok": False, "reason": "request.invalid", "detail": str(exc)}, sort_keys=True)


def _revoke_environment(key: str, scopes: list[str]) -> None:
    try:
        BrokerClient().post("/v1/control/grants/revoke-environment", {
            "environmentKey": key,
            "scopes": scopes,
            "principal": "hermes-lifecycle",
        })
    except (BrokerProblem, RuntimeError):
        return


def _on_session_start(**kwargs: Any) -> None:
    session_id = kwargs.get("session_id")
    if isinstance(session_id, str) and session_id:
        register_task_authority_binding(session_id, _binding_id())
        _SESSION_ENVIRONMENTS[session_id] = environment_key(None, session_id)


def _on_session_boundary(**kwargs: Any) -> None:
    session_id = kwargs.get("session_id") or kwargs.get("old_session_id")
    if not isinstance(session_id, str) or not session_id:
        return
    key = _SESSION_ENVIRONMENTS.pop(session_id, None)
    if key is not None:
        _revoke_environment(key, ["conversation"])
        for task_id, environment in list(_TASK_ENVIRONMENTS.items()):
            if environment == key:
                _TASK_ENVIRONMENTS.pop(task_id, None)
    clear_task_env_overrides(session_id)


def _on_task_completed(**kwargs: Any) -> None:
    task_id = kwargs.get("task_id")
    if not isinstance(task_id, str) or not task_id:
        return
    key = _TASK_ENVIRONMENTS.pop(task_id, None)
    if key is not None:
        _revoke_environment(key, ["task"])


def register(ctx) -> None:
    ctx.register_tool(
        name="sandbox_request_access",
        toolset=_TOOLSET,
        schema=_REQUEST_SCHEMA,
        handler=handle_request_access,
        description="Request explicit, broker-prepared sandbox capabilities through user approval.",
    )
    ctx.register_tool(
        name="sandbox_access_list",
        toolset=_TOOLSET,
        schema=_LIST_SCHEMA,
        handler=handle_access_list,
        description="List grants visible to the current sandbox authority.",
    )
    ctx.register_tool(
        name="sandbox_access_revoke",
        toolset=_TOOLSET,
        schema=_REVOKE_SCHEMA,
        handler=handle_access_revoke,
        description="Revoke one visible active sandbox grant.",
    )
    ctx.register_hook("on_session_start", _on_session_start)
    ctx.register_hook("on_session_finalize", _on_session_boundary)
    ctx.register_hook("on_session_reset", _on_session_boundary)
    ctx.register_hook("kanban_task_completed", _on_task_completed)
