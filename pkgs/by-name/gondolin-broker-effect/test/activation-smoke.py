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
socket_path = root / "broker.sock"
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

listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(str(socket_path))
listener.listen(16)

node = shutil.which("node")
if node is None:
    raise RuntimeError("node executable is unavailable")

pid = os.fork()
if pid == 0:
    try:
        os.dup2(listener.fileno(), 3)
        os.set_inheritable(3, True)
        if listener.fileno() != 3:
            listener.close()
        env = os.environ.copy()
        env.update(
            {
                "LISTEN_PID": str(os.getpid()),
                "LISTEN_FDS": "1",
                "GONDOLIN_EFFECT_POLICY": str(policy_path),
                "GONDOLIN_EFFECT_PROFILE": "activation-test",
                "GONDOLIN_EFFECT_STATE_DIR": str(root / "state"),
                "GONDOLIN_EFFECT_SOCKET": str(socket_path),
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

listener.close()
try:
    response = b""
    for _ in range(100):
        ended, status = os.waitpid(pid, os.WNOHANG)
        if ended:
            raise RuntimeError(f"broker exited before health request: {status}")
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(0.2)
            client.connect(str(socket_path))
            client.sendall(
                b"GET /v1/health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
            )
            chunks = []
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
            client.close()
            if chunks:
                response = b"".join(chunks)
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
    if b"HTTP/1.1 200" not in response or b'{"status":"ok"}' not in response:
        raise RuntimeError(f"unexpected health response: {response!r}")
    print("systemd-style fd 3 activation: HTTP health OK")
finally:
    try:
        os.kill(pid, signal.SIGTERM)
        os.waitpid(pid, 0)
    except ProcessLookupError:
        pass
    shutil.rmtree(root, ignore_errors=True)
