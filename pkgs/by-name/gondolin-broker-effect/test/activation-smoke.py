"""Exercise the production systemd LISTEN_FDS contract over a real Unix listener."""

import json
import os
import signal
import socket
import shutil
import sys
import tempfile
import time
from pathlib import Path


root = Path(tempfile.mkdtemp(prefix="gondolin-effect-activation-"))
execution_socket_path = root / "broker.sock"
control_socket_path = root / "control.sock"
asset_path = root / "asset"
asset_path.mkdir()
(asset_path / "manifest.json").write_text(json.dumps({"buildId": "activation-test"}))
policy = {
    "version": 1,
    "policyGeneration": 1,
    "policy": {
        "version": 1,
        "statements": [
            {"effect": "allow", "actions": ["environment.ensure"], "resources": ["*"]}
        ],
    },
    "defaultExecutor": "hermes-gateway",
    "defaultAuthorityClass": "default",
    "maxEnvironments": 1,
    "grantPolicy": {
        "allowedScopes": ["once", "task", "conversation", "timed"],
        "maxDurationSeconds": 3600,
        "denialCooldownSeconds": 300,
        "promptBudget": {"maxNewRequests": 4, "windowSeconds": 900},
    },
    "assets": {
        "default": {"path": str(asset_path), "buildId": "activation-test"}
    },
    "networkPolicies": {
        "worklane:default": {"mode": "deny-all", "destinations": []}
    },
    "worklanes": {
        "default": {
            "asset": "default",
            "memoryMiB": 256,
            "cpus": 1,
            "workspaceGuestPath": "/workspace",
            "limits": {
                "maxCommandMs": 1000,
                "maxOutputBytes": 4096,
                "maxInputBytes": 0,
                "maxFileBytes": 4096,
                "maxListEntries": 32,
                "maxConcurrentExecs": 1,
            },
        }
    },
}
policy_path = root / "policy.json"
policy_path.write_text(json.dumps(policy))

execution_listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
execution_listener.bind(str(execution_socket_path))
execution_listener.listen(16)
control_listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
control_listener.bind(str(control_socket_path))
control_listener.listen(16)

node = shutil.which("node")
if node is None:
    raise RuntimeError("node executable is unavailable")

pid = os.fork()
if pid == 0:
    try:
        execution_fd = os.dup(execution_listener.fileno())
        control_fd = os.dup(control_listener.fileno())
        os.dup2(execution_fd, 3)
        os.dup2(control_fd, 4)
        os.set_inheritable(3, True)
        os.set_inheritable(4, True)
        env = os.environ.copy()
        env.update(
            {
                "LISTEN_PID": str(os.getpid()),
                "LISTEN_FDS": "2",
                "LISTEN_FDNAMES": "execution:control",
                "GONDOLIN_EFFECT_POLICY": str(policy_path),
                "GONDOLIN_EFFECT_PROFILE": "activation-test",
                "GONDOLIN_EFFECT_STATE_DIR": str(root / "state"),
                "GONDOLIN_EFFECT_SOCKET": str(execution_socket_path),
                "GONDOLIN_EFFECT_CONTROL_SOCKET": str(control_socket_path),
            }
        )
        os.execve(
            node,
            [node, "dist/main.js"],
            env,
        )
    except BaseException as exc:  # noqa: BLE001 - fork child must report and exit
        print(f"activation child failed: {exc}", file=sys.stderr)
        os._exit(127)

execution_listener.close()
control_listener.close()

def request(socket_path: Path, route: str, body: dict | None = None) -> bytes:
    payload = b"" if body is None else json.dumps(body).encode()
    method = b"GET" if body is None else b"POST"
    headers = (
        method + b" " + route.encode() + b" HTTP/1.1\r\n"
        b"Host: localhost\r\n"
        b"Connection: close\r\n"
        + (b"" if body is None else b"Content-Type: application/json\r\nContent-Length: " + str(len(payload)).encode() + b"\r\n")
        + b"\r\n"
        + payload
    )
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(0.5)
    client.connect(str(socket_path))
    client.sendall(headers)
    chunks = []
    while True:
        chunk = client.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)
    client.close()
    return b"".join(chunks)

try:
    execution_health = b""
    for _ in range(100):
        ended, status = os.waitpid(pid, os.WNOHANG)
        if ended:
            raise RuntimeError(f"broker exited before health request: {status}")
        try:
            execution_health = request(execution_socket_path, "/v1/health")
            if execution_health:
                break
        except (
            BrokenPipeError,
            ConnectionRefusedError,
            ConnectionResetError,
            FileNotFoundError,
            TimeoutError,
        ):
            pass
        time.sleep(0.05)

    control_health = request(control_socket_path, "/v1/health")
    execution_control = request(execution_socket_path, "/v1/control/authority/status", {
        "environmentKey": "activation-environment",
    })
    control_execution = request(control_socket_path, "/v1/environments/ensure", {
        "environmentKey": "activation-environment",
    })
    bound = request(control_socket_path, "/v1/control/authority/bind", {
        "environmentKey": "activation-environment",
        "profile": "activation-test",
        "executor": "hermes-gateway",
        "authorityClass": "default",
        "policyGeneration": 1,
    })

    if b"HTTP/1.1 200" not in execution_health or b'"plane":"execution"' not in execution_health:
        raise RuntimeError(f"unexpected execution health response: {execution_health!r}")
    if b"HTTP/1.1 200" not in control_health or b'"plane":"control"' not in control_health:
        raise RuntimeError(f"unexpected control health response: {control_health!r}")
    if b"HTTP/1.1 404" not in execution_control:
        raise RuntimeError(f"control route escaped onto execution socket: {execution_control!r}")
    if b"HTTP/1.1 404" not in control_execution:
        raise RuntimeError(f"execution route escaped onto control socket: {control_execution!r}")
    if b"HTTP/1.1 200" not in bound or b'"authorityClass":"default"' not in bound:
        raise RuntimeError(f"authority bind failed: {bound!r}")
    print("systemd-style named fd activation: execution/control separation OK")
finally:
    try:
        os.kill(pid, signal.SIGTERM)
        os.waitpid(pid, 0)
    except ProcessLookupError:
        pass
    shutil.rmtree(root, ignore_errors=True)
