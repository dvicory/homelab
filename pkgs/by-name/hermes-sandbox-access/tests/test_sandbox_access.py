from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
from types import SimpleNamespace

import pytest


PLUGIN_ROOT = Path(__file__).parents[1]


def _load_plugin():
    name = "hermes_sandbox_access_plugin"
    spec = importlib.util.spec_from_file_location(name, PLUGIN_ROOT / "__init__.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def plugin(monkeypatch):
    module = _load_plugin()
    monkeypatch.setenv("HERMES_SANDBOX_AUTHORITY_BINDING", "qa-default-authority")
    monkeypatch.setenv("GONDOLIN_EFFECT_CONTROL_SOCKET", "/run/test/control.sock")
    monkeypatch.setenv("HERMES_SANDBOX_APPROVAL_PRINCIPAL", "model-selected")
    monkeypatch.setattr(module, "register_task_authority_binding", lambda identity, binding: None)
    monkeypatch.setattr(module, "environment_key", lambda task_id=None, session_id=None: "authority-test")
    return module


class FakeClient:
    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def post(self, path, payload):
        self.calls.append((path, payload))
        response = self.responses[path]
        return response(payload) if callable(response) else response


def proposal(scope="task"):
    return {
        "capabilities": [{
            "kind": "network-origin",
            "scheme": "https",
            "host": "API.EXAMPLE.COM",
            "address_mode": "public",
        }],
        "requested_scope": scope,
        "rationale": "Needed for the vendor API",
    }


def prepared():
    return {
        "state": "pending",
        "requestId": "request-1",
        "fingerprint": "fingerprint-1",
        "requestedScope": "task",
        "durationSeconds": None,
        "capabilities": [{
            "version": 1,
            "kind": "network-origin",
            "scheme": "https",
            "host": "api.example.com",
            "ports": [443],
            "addressMode": "public",
            "pinnedAddresses": [],
        }],
        "grantIds": [],
    }


def test_broker_prepares_before_approval_and_decision_uses_only_request_id(plugin, monkeypatch):
    client = FakeClient({
        "/v1/control/access/prepare": prepared(),
        "/v1/control/access/decide": {
            "state": "approved",
            "requestId": "request-1",
            "grantIds": ["grant-1"],
        },
    })
    prompts = []
    monkeypatch.setattr(plugin, "BrokerClient", lambda: client)
    monkeypatch.setattr(plugin, "request_tool_approval", lambda tool, reason, **kwargs: (
        prompts.append((tool, reason, kwargs)) or {"approved": True, "choice": "session"}
    ))

    result = json.loads(plugin.handle_request_access(proposal(), task_id="turn-1", session_id="session-1"))

    assert result["ok"] is True
    assert result["scope"] == "task"
    assert [path for path, _ in client.calls] == [
        "/v1/control/access/prepare",
        "/v1/control/access/decide",
    ]
    decision = client.calls[1][1]
    assert decision == {
        "requestId": "request-1",
        "decision": "approve",
        "scope": "task",
        "principal": "paired-user",
    }
    assert "capabilities" not in decision
    assert "https://api.example.com ports [443], public addresses" in prompts[0][1]
    assert "Effect: network only; no credentials, filesystem access, or VM restart." in prompts[0][1]
    assert "Choices: once=next matching request; session=task." in prompts[0][1]
    assert "Why (model-provided): Needed for the vendor API" in prompts[0][1]
    assert prompts[0][2] == {
        "rule_key": "sandbox-access:fingerprint-1",
        "allow_permanent": False,
    }


def test_permanent_choice_is_unavailable_and_fails_closed(plugin, monkeypatch):
    client = FakeClient({
        "/v1/control/access/prepare": prepared(),
        "/v1/control/access/decide": {"state": "denied", "requestId": "request-1", "grantIds": []},
    })
    monkeypatch.setattr(plugin, "BrokerClient", lambda: client)
    monkeypatch.setattr(plugin, "request_tool_approval", lambda *args, **kwargs: {
        "approved": True,
        "choice": "always",
    })

    result = json.loads(plugin.handle_request_access(proposal(), session_id="session-1"))

    assert result["ok"] is False
    assert result["reason"] == "approval.denied"
    assert client.calls[1] == (
        "/v1/control/access/decide",
        {"requestId": "request-1", "decision": "deny", "principal": "paired-user"},
    )
    assert plugin._REQUEST_SCHEMA["parameters"]["properties"]["requested_scope"]["enum"] == ["once", "task"]


def test_denial_is_recorded_and_malformed_approval_fails_closed(plugin, monkeypatch):
    client = FakeClient({
        "/v1/control/access/prepare": prepared(),
        "/v1/control/access/decide": {"state": "denied", "requestId": "request-1", "grantIds": []},
    })
    monkeypatch.setattr(plugin, "BrokerClient", lambda: client)
    monkeypatch.setattr(plugin, "request_tool_approval", lambda *args, **kwargs: {"approved": True})

    result = json.loads(plugin.handle_request_access(proposal(), session_id="session-1"))

    assert result["ok"] is False
    assert result["reason"] == "approval.denied"
    assert client.calls[1] == (
        "/v1/control/access/decide",
        {"requestId": "request-1", "decision": "deny", "principal": "paired-user"},
    )


def test_prepare_failure_never_invokes_approval(plugin, monkeypatch):
    class RejectingClient:
        def post(self, _path, _payload):
            raise plugin.BrokerProblem(400, "capability.invalid", "unsafe origin", {})

    monkeypatch.setattr(plugin, "BrokerClient", RejectingClient)
    monkeypatch.setattr(plugin, "request_tool_approval", lambda *args, **kwargs: pytest.fail("approval invoked"))

    result = json.loads(plugin.handle_request_access(proposal(), session_id="session-1"))

    assert result["reason"] == "capability.invalid"


def test_existing_pending_does_not_open_duplicate_prompt(plugin, monkeypatch):
    pending = prepared()
    pending["state"] = "existing-pending"
    client = FakeClient({"/v1/control/access/prepare": pending})
    monkeypatch.setattr(plugin, "BrokerClient", lambda: client)
    monkeypatch.setattr(plugin, "request_tool_approval", lambda *args, **kwargs: pytest.fail("approval invoked"))

    result = json.loads(plugin.handle_request_access(proposal(), session_id="session-1"))

    assert result["state"] == "existing-pending"
    assert len(client.calls) == 1


def test_list_and_revoke_expose_only_current_or_matching_remembered_grants(plugin, monkeypatch):
    grants = [
        {"grantId": "current", "environmentKey": "authority-test", "scope": "task", "state": "active"},
        {"grantId": "remembered", "environmentKey": "other", "scope": "executor", "executor": "hermes-gateway", "state": "active"},
        {"grantId": "hidden", "environmentKey": "other", "scope": "executor", "executor": "codex", "state": "active"},
    ]
    client = FakeClient({
        "/v1/control/authority/status": {
            "profile": "hermes-qa",
            "executor": "hermes-gateway",
            "policyDigest": "a" * 64,
            "generation": 2,
            "state": "active",
        },
        "/v1/control/grants/list": grants,
        "/v1/control/grants/revoke": lambda payload: next(item for item in grants if item["grantId"] == payload["grantId"]),
    })
    monkeypatch.setattr(plugin, "BrokerClient", lambda: client)

    listed = json.loads(plugin.handle_access_list({}, session_id="session-1"))
    revoked = json.loads(plugin.handle_access_revoke({"grant_id": "remembered"}, session_id="session-1"))
    hidden = json.loads(plugin.handle_access_revoke({"grant_id": "hidden"}, session_id="session-1"))

    assert [item["grantId"] for item in listed["grants"]] == ["current", "remembered"]
    assert listed["authority"]["policyDigest"] == "a" * 64
    assert listed["authority"]["generation"] == 2
    assert revoked["ok"] is True
    assert hidden["reason"] == "grant.not_found"


def test_registration_exposes_only_explicit_tools_and_lifecycle_hooks(plugin):
    context = SimpleNamespace(tools=[], hooks=[])
    context.register_tool = lambda **kwargs: context.tools.append(kwargs)
    context.register_hook = lambda name, handler: context.hooks.append((name, handler))

    plugin.register(context)

    assert [tool["name"] for tool in context.tools] == [
        "sandbox_request_access",
        "sandbox_access_list",
        "sandbox_access_revoke",
    ]
    assert {name for name, _ in context.hooks} == {
        "on_session_start",
        "on_session_finalize",
        "on_session_reset",
        "kanban_task_completed",
    }


def test_registration_uses_openai_function_schema_envelopes(plugin):
    context = SimpleNamespace(tools=[], hooks=[])
    context.register_tool = lambda **kwargs: context.tools.append(kwargs)
    context.register_hook = lambda name, handler: context.hooks.append((name, handler))

    plugin.register(context)

    definitions = {tool["name"]: tool["schema"] for tool in context.tools}
    request = definitions["sandbox_request_access"]
    assert set(request) == {"description", "parameters"}
    assert request["parameters"]["properties"]["capabilities"]["items"]["properties"]["address_mode"] == {
        "enum": ["public", "pinned-private"],
    }
    assert request["parameters"]["required"] == ["capabilities", "requested_scope", "rationale"]
    assert definitions["sandbox_access_list"]["parameters"]["properties"] == {}
    assert definitions["sandbox_access_revoke"]["parameters"]["required"] == ["grant_id"]
