#!/usr/bin/env python3
"""Exercise the rendered monitoring stack on a disposable compute guest.

The scenario uses real Incus, K3s, Argo, Prometheus, Alertmanager, Loki and
Alloy endpoints. It keeps only the four monitoring Applications in a local Git
origin and stages only the already-declared Grafana administration Secret.
"""

from __future__ import annotations

import argparse
import base64
from contextlib import contextmanager
import http.server
import ipaddress
import json
import os
from pathlib import Path
import platform
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


TEST_HOSTNAME = "lima-homelab-compute-check"
COMMAND_TIMEOUT = 180
WAIT_TIMEOUT = 240
ALERT_TIMEOUT = 600
ROOT_APP = "monitoring-runtime-apps"
APPLICATIONS = ("monitoring-retained", "monitoring", "loki", "alloy")


class ScenarioError(RuntimeError):
    """A failed runtime assertion or an unavailable disposable prerequisite."""


def completed(*command: str, timeout: int = COMMAND_TIMEOUT, input: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        input=input,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )


def run(*command: str, timeout: int = COMMAND_TIMEOUT, input: str | None = None) -> str:
    result = completed(*command, timeout=timeout, input=input)
    if result.returncode:
        details = (result.stderr or result.stdout).strip()
        raise ScenarioError(f"{shlex.join(command)} failed ({result.returncode}): {details}")
    return result.stdout.strip()


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"PASS: {message}", flush=True)


def wait_for(label: str, predicate, timeout: int = WAIT_TIMEOUT):
    print(f"WAIT: {label} (timeout: {timeout}s)", flush=True)
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except (OSError, ScenarioError, AssertionError, KeyError, IndexError, json.JSONDecodeError) as error:
            last_error = error
        time.sleep(2)
    suffix = f": {last_error}" if last_error else ""
    raise ScenarioError(f"timed out waiting for {label}{suffix}")


@contextmanager
def phase(name: str):
    started = time.monotonic()
    print(f"PHASE start: {name}", flush=True)
    try:
        yield
    finally:
        print(f"PHASE elapsed: {name}: {time.monotonic() - started:.2f}s", flush=True)


def query_incus(path: str, project: str | None = None):
    parsed = urllib.parse.urlsplit(path)
    parts = parsed.path.strip("/").split("/")
    named = len(parts) == 3
    if project is not None:
        projects = json.loads(run("incus", "--force-local", "query", "/1.0/projects?recursion=1"))
        if not any(item["name"] == project for item in projects):
            return None if named else []
    params = dict(urllib.parse.parse_qsl(parsed.query))
    params["recursion"] = "1"
    if project is not None:
        params["project"] = project
    collection = "/" + "/".join(parts[:2])
    items = json.loads(run("incus", "--force-local", "query", collection + "?" + urllib.parse.urlencode(params)))
    if named:
        return next((item for item in items if item["name"] == urllib.parse.unquote(parts[2])), None)
    return items


def instance_query(project: str, name: str) -> dict | None:
    instances = query_incus("/1.0/instances?recursion=1", project=project)
    return next((instance for instance in instances if instance["name"] == name), None)


def descriptor_paths(descriptor: dict) -> list[Path]:
    paths = [Path(entry["path"]) for entry in descriptor["requiredPaths"]]
    paths.extend(Path(entry["path"]) for entry in descriptor.get("retainedPaths", {}).values())
    for key in ("identityPath", "poolPath"):
        value = descriptor.get(key)
        if isinstance(value, str):
            paths.append(Path(value))
    for device in descriptor.get("devices", {}).values():
        for key in ("source", "path"):
            value = device.get(key)
            if isinstance(value, str) and value.startswith("/"):
                paths.append(Path(value))
    return paths


def ensure_absolute_paths(descriptor: dict) -> None:
    for path in descriptor_paths(descriptor):
        check(path.is_absolute(), f"fixture path is absolute: {path}")


def prepare_directory(path: Path, safe_dirs: list[Path]) -> None:
    check(completed("findmnt", "--mountpoint", str(path)).returncode != 0, f"disposable path is not already mounted: {path}")
    if path.exists():
        check(path.is_dir() and not path.is_symlink(), f"fixture path is a directory: {path}")
        check(not any(path.iterdir()), f"fixture path starts empty: {path}")
    else:
        path.mkdir(parents=True)
    safe_dirs.append(path)


def clear_directory(path: Path) -> None:
    if not path.is_dir() or path.is_symlink():
        return
    for child in path.iterdir():
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()


def stage_identity(descriptor: dict, identity: Path) -> str:
    private = identity / "ssh_host_ed25519_key"
    run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(private), timeout=60)
    public = (identity / "ssh_host_ed25519_key.pub").read_text().strip()
    os.chown(identity, descriptor["idmapBase"], descriptor["idmapBase"])
    os.chmod(identity, 0o700)
    os.chown(private, descriptor["idmapBase"], descriptor["idmapBase"])
    os.chmod(private, 0o400)
    os.chown(identity / "ssh_host_ed25519_key.pub", descriptor["idmapBase"], descriptor["idmapBase"])
    os.chmod(identity / "ssh_host_ed25519_key.pub", 0o444)
    descriptor["publicKey"] = public
    return public


def stage_grafana_secret(descriptor: dict, root: Path) -> None:
    entries = descriptor.get("runtimeSecrets", {})
    check(entries and all(name.startswith("monitoring--grafana-admin--") for name in entries),
          "fixture stages only declared Grafana runtime Secret keys")
    values = {name: secrets.token_urlsafe(32).encode() for name in entries}
    lines = [
        "apiVersion: v1",
        "kind: Secret",
        "metadata:",
        "  name: grafana-admin",
        "  namespace: monitoring",
        "type: Opaque",
        "data:",
    ]
    for source, value in values.items():
        key = entries[source]["key"]
        lines.append(f"  {key}: {base64.b64encode(value).decode()}")
    os.chown(root, descriptor["idmapBase"], descriptor["idmapBase"])
    os.chmod(root, 0o700)
    manifest = root / "runtime-secrets.yaml"
    manifest.write_text("\n".join(lines) + "\n")
    os.chown(manifest, descriptor["idmapBase"], descriptor["idmapBase"])
    os.chmod(manifest, 0o400)


class Runtime:
    def __init__(self, descriptor: dict, spec_path: Path, helper: Path, bundle: Path):
        self.descriptor = descriptor
        self.spec_path = spec_path
        self.helper = helper
        self.bundle = bundle
        self.project = descriptor["project"]
        self.instance = descriptor["instance"]
        self.created_instance = False
        self.mounts: list[Path] = []
        self.git_origin: GitOrigin | None = None

    def incus(self, *args: str, timeout: int = COMMAND_TIMEOUT, input: str | None = None) -> str:
        return run("incus", "--force-local", "--project", self.project, *args, timeout=timeout, input=input)

    def guest(self, *args: str, timeout: int = COMMAND_TIMEOUT, input: str | None = None) -> str:
        command = [
            "incus", "--force-local", "--project", self.project, "exec", self.instance,
            "--mode=non-interactive", "--", *args,
        ]
        result = completed(*command, timeout=timeout, input=input)
        if result.returncode:
            details = (result.stderr or result.stdout).strip()
            raise ScenarioError(f"{shlex.join(command)} failed ({result.returncode}): {details}")
        return result.stdout.strip()

    def kubectl(self, *args: str, namespace: str | None = None, timeout: int = COMMAND_TIMEOUT, input: str | None = None) -> str:
        command = ["k3s", "kubectl"]
        if namespace:
            command.extend(["-n", namespace])
        command.extend(args)
        return self.guest(*command, timeout=timeout, input=input)

    def kubectl_json(self, *args: str, namespace: str | None = None):
        return json.loads(self.kubectl(*args, namespace=namespace))

    def helper_run(self, operation: str, timeout: int = 3_600) -> str:
        return run(str(self.helper), "--spec", str(self.spec_path), operation, "--bundle", str(self.bundle), timeout=timeout)

    def cleanup(self) -> None:
        if self.git_origin is not None:
            self.git_origin.stop()
        if self.created_instance:
            result = completed(
                "incus", "--force-local", "--project", self.project,
                "stop", self.instance, "--timeout=120", timeout=180,
            )
            if result.returncode and "not found" not in (result.stderr or result.stdout).lower():
                print(f"WARN: instance stop: {(result.stderr or result.stdout).strip()}", file=sys.stderr)
            result = completed(
                "incus", "--force-local", "--project", self.project,
                "delete", self.instance, timeout=600,
            )
            if result.returncode and "not found" not in (result.stderr or result.stdout).lower():
                print(f"WARN: instance delete: {(result.stderr or result.stdout).strip()}", file=sys.stderr)
        for path in reversed(self.mounts):
            completed("umount", str(path), timeout=120)


class GitOrigin:
    def __init__(self, parent: Path, address: str):
        self.parent = parent
        self.address = address
        self.url = f"git://{address}/monitoring.git"
        self.process: subprocess.Popen | None = None

    def publish(self, repo: Path) -> None:
        work = self.parent / "work"
        if work.exists():
            shutil.rmtree(work)
        shutil.copytree(repo, work, symlinks=True)
        for name in APPLICATIONS:
            path = work / "apps" / f"Application-{name}.yaml"
            text = path.read_text()
            text = text.replace(
                "repoURL: https://github.com/dvicory/homelab.git",
                f"repoURL: {self.url}",
            )
            text = text.replace(
                f"path: ./generated/manifests/prod-home/{name}",
                f"path: ./{name}",
            )
            path.write_text(text)
        git = ["git", "-C", str(work)]
        run(*git, "init", "-b", "main")
        run(*git, "-c", "user.email=monitoring@test", "-c", "user.name=monitoring", "add", "-A")
        run(*git, "-c", "user.email=monitoring@test", "-c", "user.name=monitoring", "commit", "-m", "monitoring fixture")
        bare = self.parent / "monitoring.git"
        if bare.exists():
            shutil.rmtree(bare)
        run("git", "clone", "--bare", "--", str(work), str(bare))

    def serve(self) -> None:
        self.process = subprocess.Popen(
            ["git", "daemon", "--export-all", f"--base-path={self.parent}",
             f"--listen={self.address}", "--port=9418", str(self.parent)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            wait_for("fixture Git origin", self.reachable, timeout=60)
        except BaseException:
            self.stop()
            raise

    def reachable(self) -> bool:
        try:
            with socket.create_connection((self.address, 9418), timeout=2):
                return True
        except OSError:
            return False

    def stop(self) -> None:
        process, self.process = self.process, None
        if process is None:
            return
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()

class PortForward:
    def __init__(self, kubeconfig: Path, namespace: str, service: str, local: int, remote: int):
        self.kubeconfig = kubeconfig
        self.namespace = namespace
        self.service = service
        self.local = local
        self.remote = remote
        self.process: subprocess.Popen | None = None

    def start(self) -> None:
        self.process = subprocess.Popen(
            ["kubectl", "--kubeconfig", str(self.kubeconfig), "-n", self.namespace,
             "port-forward", f"svc/{self.service}", f"{self.local}:{self.remote}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        wait_for(f"port-forward {self.service}", self.reachable, timeout=120)

    def reachable(self) -> bool:
        try:
            with socket.create_connection(("127.0.0.1", self.local), timeout=2):
                return True
        except OSError:
            if self.process is not None and self.process.poll() is not None:
                raise ScenarioError(f"port-forward {self.service} exited before becoming reachable")
            return False

    def stop(self) -> None:
        process, self.process = self.process, None
        if process is None:
            return
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()


class AlertReceiver:
    def __init__(self, address: str, port: int):
        records: list[dict] = []
        lock = threading.Lock()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                if self.path != "/alertmanager":
                    self.send_response(404)
                    self.end_headers()
                    return
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                try:
                    payload = json.loads(body)
                except json.JSONDecodeError:
                    self.send_response(400)
                    self.end_headers()
                    return
                with lock:
                    records.append(payload)
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"ok\n")

            def log_message(self, *_args):
                return

        self.server = http.server.ThreadingHTTPServer((address, port), Handler)
        self.records = records
        self.lock = lock
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def has(self, status: str, labels: dict[str, str]) -> bool:
        with self.lock:
            payloads = list(self.records)
        return any(
            payload.get("status") == status
            and any(all(alert.get("labels", {}).get(key) == value for key, value in labels.items())
                    for alert in payload.get("alerts", []))
            for payload in payloads
        )

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=30)


def fetch_kubeconfig(runtime: Runtime, workspace: Path) -> Path:
    raw = workspace / "k3s.yaml"
    runtime.incus("file", "pull", f"{runtime.instance}/etc/rancher/k3s/k3s.yaml", str(raw), timeout=120)
    text = raw.read_text()
    check("https://127.0.0.1:6443" in text, "guest kubeconfig uses the loopback server")
    kubeconfig = workspace / "kubeconfig"
    kubeconfig.write_text(text.replace("https://127.0.0.1:6443", f"https://{runtime.descriptor['address']}:6443"))
    kubeconfig.chmod(0o600)
    return kubeconfig


def run_bootstrap_host(bootstrap_host: Path, runtime: Runtime, kubeconfig: Path, seed: Path) -> None:
    env = {
        **os.environ,
        "KUBECONFIG": str(kubeconfig),
        "HOUSEHOLD_BOOTSTRAP_MANIFESTS": str(seed),
    }
    with phase("household-bootstrap-host"):
        process = subprocess.Popen(
            [
                "timeout",
                "--kill-after=30s",
                "3600s",
                str(bootstrap_host),
                str(runtime.spec_path),
                "--confirm",
                runtime.instance,
            ],
            env=env,
        )
        status = process.wait()
    if status:
        raise ScenarioError(f"household-bootstrap-host failed ({status})")


def wait_argo_synced(kubeconfig: Path, names: tuple[str, ...], timeout: int = 1_800) -> None:
    expected = set(names)

    def synced() -> bool:
        applications = json.loads(
            kubectl_outer(kubeconfig, "get", "applications", "-n", "argocd", "-o", "json")
        ).get("items", [])
        actual = {item.get("metadata", {}).get("name") for item in applications}
        if actual != expected:
            return False
        return all(
            item.get("status", {}).get("sync", {}).get("status") == "Synced"
            and item.get("status", {}).get("health", {}).get("status") == "Healthy"
            for item in applications
        )

    wait_for(f"Argo reconciliation of {', '.join(names)}", synced, timeout=timeout)


def http_json(base: str, path: str) -> dict | list:
    request = urllib.request.Request(base + path, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            body = response.read()
    except urllib.error.HTTPError as error:
        raise ScenarioError(f"HTTP {error.code} from {path}") from error
    return json.loads(body)
def http_ready(base: str, path: str) -> bool:
    request = urllib.request.Request(base + path)
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            return response.status == 200
    except urllib.error.HTTPError:
        return False


 


def service_forwards(kubeconfig: Path) -> list[PortForward]:
    forwards = [
        PortForward(kubeconfig, "monitoring", "monitoring-prometheus", 19090, 9090),
        PortForward(kubeconfig, "monitoring", "monitoring-alertmanager", 19093, 9093),
        PortForward(kubeconfig, "monitoring", "loki", 13100, 3100),
        PortForward(kubeconfig, "monitoring", "alloy", 12345, 12345),
    ]
    try:
        for forward in forwards:
            forward.start()
        wait_for("Prometheus readiness", lambda: http_ready("http://127.0.0.1:19090", "/-/ready"))
        wait_for("Alertmanager readiness", lambda: http_ready("http://127.0.0.1:19093", "/-/ready"))
        wait_for("Loki readiness", lambda: http_ready("http://127.0.0.1:13100", "/ready"))
        wait_for("Alloy readiness", lambda: http_ready("http://127.0.0.1:12345", "/-/ready"))
    except BaseException:
        for forward in reversed(forwards):
            forward.stop()
        raise
    return forwards


def prometheus_query(query: str) -> list[dict]:
    encoded = urllib.parse.urlencode({"query": query})
    response = http_json("http://127.0.0.1:19090", f"/api/v1/query?{encoded}")
    check(response.get("status") == "success", f"Prometheus query succeeds: {query}")
    return response["data"]["result"]


def prometheus_targets() -> list[dict]:
    response = http_json("http://127.0.0.1:19090", "/api/v1/targets?state=active")
    check(response.get("status") == "success", "Prometheus active target API succeeds")
    return response["data"]["activeTargets"]


def labels_selector(labels: dict[str, str]) -> str:
    def quote(value: str) -> str:
        return value.replace("\\", "\\\\").replace('"', '\\"')

    return ",".join(f'{key}="{quote(value)}"' for key, value in labels.items())


def target_for(targets: list[dict], labels: dict[str, str]) -> dict | None:
    return next(
        (
            target for target in targets
            if all(target.get("labels", {}).get(key) == value for key, value in labels.items())
        ),
        None,
    )


def matching_alert(labels: dict[str, str], *, state: str | None = None) -> bool:
    query = 'ALERTS{' + labels_selector({**labels, **({"alertstate": state} if state else {})}) + '}'
    return bool(prometheus_query(query))


def alertmanager_active(labels: dict[str, str]) -> bool:
    alerts = http_json("http://127.0.0.1:19093", "/api/v2/alerts?active=true&silenced=false&inhibited=false")
    return any(
        all(alert.get("labels", {}).get(key) == value for key, value in labels.items())
        and alert.get("status", {}).get("state") == "active"
        for alert in alerts
    )


def loki_has_line(pod: str, line: str) -> bool:
    query = f'{{namespace="monitoring",pod="{pod}",container="probe"}} |= "{line}"'
    params = urllib.parse.urlencode({
        "query": query,
        "limit": "100",
        "start": str((time.time_ns() - 600_000_000_000)),
        "end": str(time.time_ns()),
        "direction": "forward",
    })
    response = http_json("http://127.0.0.1:13100", f"/loki/api/v1/query_range?{params}")
    if response.get("status") != "success":
        return False
    for result in response.get("data", {}).get("result", []):
        stream = result.get("stream", {})
        if {
            "namespace": "monitoring",
            "pod": pod,
            "container": "probe",
            "app": "monitoring-log-probe",
        }.items() <= stream.items():
            if any(entry[1] == line for entry in result.get("values", [])):
                return True
    return False


def block_target(runtime: Runtime, instance: str) -> str:
    try:
        host, port_text = instance.rsplit(":", 1)
        target_ip = ipaddress.IPv4Address(host)
        port = int(port_text, 10)
    except (ValueError, ipaddress.AddressValueError) as error:
        raise ScenarioError(f"selected kubelet target is not an IPv4 address and port: {instance}") from error
    check(1 <= port <= 65_535, f"selected kubelet target port is valid: {port}")
    table = f"monitoring_runtime_{secrets.token_hex(8)}"
    target = f"ip daddr {target_ip} tcp dport {port} drop"
    rules = [
        f"table inet {table} {{",
        " chain input {",
        "  type filter hook input priority -100; policy accept;",
        f"  {target}",
        " }",
        " chain output {",
        "  type filter hook output priority -100; policy accept;",
        f"  {target}",
        " }",
        " chain forward {",
        "  type filter hook forward priority -100; policy accept;",
        f"  {target}",
        " }",
        "}",
    ]
    runtime.guest("nft", "-f", "-", input="\n".join(rules) + "\n")
    return table


def restore_target(runtime: Runtime, table: str) -> None:
    runtime.guest("nft", "delete", "table", "inet", table)


def run_scenario(args: argparse.Namespace) -> None:
    check(platform.machine() == "x86_64", "fixture architecture is x86_64")
    check(platform.node() in (TEST_HOSTNAME, "fixture-host"), "driver runs on the disposable fixture host")
    check(os.geteuid() == 0, "driver runs as root")
    fixture = json.loads(args.fixture.read_text())
    descriptor = fixture["descriptor"]
    ensure_absolute_paths(descriptor)
    check(set(descriptor.get("runtimeSecrets", {})) == {
        "monitoring--grafana-admin--admin-user",
        "monitoring--grafana-admin--admin-password",
    }, "fixture descriptor contains only the declared Grafana runtime Secret")
    check(args.bundle.is_dir() and str(args.bundle.resolve()).startswith("/nix/store/"), "guest bundle is an immutable Nix store output")
    check(args.repo.is_dir() and args.seed.is_dir(), "monitoring Git source and bootstrap seed are present")

    project = descriptor["project"]
    instance = descriptor["instance"]
    wait_for("Incus API", lambda: query_incus("/1.0/instances?recursion=1", project=project) is not None)
    check(instance_query(project, instance) is None, "disposable instance is absent before the scenario")

    with tempfile.TemporaryDirectory(prefix="homelab-monitoring-runtime-") as temporary:
        workspace = Path(temporary)
        safe_dirs: list[Path] = []
        spec_path = workspace / "compute.json"
        runtime: Runtime = Runtime(descriptor, spec_path, args.helper, args.bundle)
        receiver: AlertReceiver | None = None
        forwards: list[PortForward] = []
        kubeconfig: Path | None = None
        probe_name: str | None = None
        nft_table: str | None = None
        try:
            pool_path = Path(descriptor["poolPath"])
            host_paths = {Path(entry["path"]) for entry in descriptor["requiredPaths"]}
            host_paths.update(
                Path(device["source"])
                for device in descriptor.get("devices", {}).values()
                if device.get("type") == "disk" and device.get("source")
            )
            for path in sorted(host_paths):
                if path != pool_path:
                    prepare_directory(path, safe_dirs)

            secret_root = Path(descriptor["devices"]["secrets"]["source"])
            stage_grafana_secret(descriptor, secret_root)
            safe_dirs.append(secret_root)

            persist = Path("/persist")
            prepare_directory(persist, safe_dirs)
            durable = workspace / "durable"
            durable.mkdir()
            run("mount", "--bind", str(durable), str(persist))
            runtime.mounts.append(persist)

            for entry in descriptor["requiredPaths"]:
                target = Path(entry["path"])
                backing = durable / str(target).lstrip("/")
                backing.mkdir(parents=True)
                run("mount", "--bind", str(backing), str(target))
                runtime.mounts.append(target)
                os.chown(target, entry["uid"], entry["gid"])
                os.chmod(target, int(entry["mode"], 8))
                if entry["readOnly"]:
                    run("mount", "-o", "remount,bind,ro", str(target))

            identity = Path(descriptor["identityPath"])
            stage_identity(descriptor, identity)
            spec_path = workspace / "compute.json"
            spec_path.write_text(json.dumps(descriptor, indent=2) + "\n")
            spec_path.chmod(0o400)

            preseed = (
                "env",
                f"PATH={fixture['preseedPath']}",
                *shlex.split(fixture["preseedCommand"]),
            )
            run(*preseed, timeout=600)
            runtime.created_instance = True
            runtime.helper_run("create")
            def healthy_node() -> bool:
                items = runtime.kubectl_json("get", "nodes", "-o", "json").get("items", [])
                return bool(items) and all(
                    any(
                        condition.get("type") == "Ready" and condition.get("status") == "True"
                        for condition in item.get("status", {}).get("conditions", [])
                    )
                    for item in items
                )

            wait_for("healthy K3s node", healthy_node)

            receiver = AlertReceiver(fixture["bridgeAddress"], 18080)
            receiver.start()
            origin = GitOrigin(workspace / "origin", fixture["bridgeAddress"])
            origin.publish(args.repo)
            origin.serve()
            runtime.git_origin = origin
            kubeconfig = fetch_kubeconfig(runtime, workspace)
            run_bootstrap_host(args.bootstrap_host, runtime, kubeconfig, args.seed)
            wait_argo_synced(kubeconfig, (ROOT_APP, *APPLICATIONS))

            forwards = service_forwards(kubeconfig)
            baseline: dict = {}

            def healthy_baseline() -> bool:
                healthy = prometheus_query('up{job="kubelet"}')
                if not healthy or any(sample["value"][1] != "1" for sample in healthy):
                    return False
                inventory = prometheus_query("kube_node_info")
                if not inventory:
                    return False
                selected = next(
                    (
                        target for target in prometheus_targets()
                        if target.get("labels", {}).get("job") == "kubelet"
                        and target.get("health") == "up"
                        and target.get("labels", {}).get("instance")
                    ),
                    None,
                )
                if selected is None or not selected.get("discoveredLabels", {}):
                    return False
                baseline.update(healthy=healthy, inventory=inventory, selected=selected)
                return True

            wait_for("healthy Prometheus targets and kube_node_info", healthy_baseline, timeout=300)
            healthy = baseline["healthy"]
            inventory = baseline["inventory"]
            selected = baseline["selected"]
            check(healthy and all(sample["value"][1] == "1" for sample in healthy),
                  "Prometheus reports healthy discovered kubelet targets")
            check(inventory, "Prometheus reports kube_node_info for the disposable node")
            target_labels = {
                key: selected["labels"][key]
                for key in ("job", "instance", "metrics_path")
                if key in selected["labels"]
            }
            discovered = selected["discoveredLabels"]
            check(discovered, "selected kubelet target retains Kubernetes discovery labels")
            target_instance = selected["labels"]["instance"]

            probe_name = f"monitoring-log-probe-{secrets.token_hex(5)}"
            line = f"monitoring-runtime-{secrets.token_hex(16)}"
            probe = {
                "apiVersion": "v1",
                "kind": "Pod",
                "metadata": {
                    "name": probe_name,
                    "namespace": "monitoring",
                    "labels": {
                        "app.kubernetes.io/name": "monitoring-log-probe",
                        "monitoring.homelab/test": line,
                    },
                },
                "spec": {
                    "automountServiceAccountToken": False,
                    "restartPolicy": "Never",
                    "containers": [{
                        "name": "probe",
                        "image": "busybox:1.36.1",
                        "command": ["sh", "-ec", f"printf '%s\\n' {shlex.quote(line)}; sleep 600"],
                    }],
                },
            }
            kubectl_outer(kubeconfig, "apply", "-f", "-", input=json.dumps(probe))
            kubectl_outer(kubeconfig, "wait", "--for=condition=Ready", f"pod/{probe_name}", "--timeout=180s", "-n", "monitoring")
            wait_for("Alloy forwards the exact disposable pod log", lambda: loki_has_line(probe_name, line), timeout=300)
            check(loki_has_line(probe_name, line), "Loki exposes the exact pod log line with Alloy labels")

            with phase("kubelet outage and MetricsTargetUnavailable delivery"):
                nft_table = block_target(runtime, target_instance)
                def target_down() -> bool:
                    current = target_for(prometheus_targets(), target_labels)
                    check(current is not None, "kubelet target remains discovered during outage")
                    check(current.get("discoveredLabels", {}) == discovered, "kubelet discovery labels remain unchanged during outage")
                    return current.get("health") == "down" and prometheus_query(
                        "up{" + labels_selector(target_labels) + "}"
                    )[0]["value"][1] == "0"

                wait_for("selected kubelet target to report down", target_down, timeout=300)
                alert_labels = {
                    "alertname": "MetricsTargetUnavailable",
                    **{key: target_labels[key] for key in ("job", "instance")},
                }
                wait_for(
                    "MetricsTargetUnavailable firing in Prometheus",
                    lambda: matching_alert(alert_labels, state="firing"),
                    timeout=ALERT_TIMEOUT,
                )
                wait_for(
                    "MetricsTargetUnavailable firing in Alertmanager",
                    lambda: alertmanager_active(alert_labels),
                    timeout=ALERT_TIMEOUT,
                )
                wait_for(
                    "firing Alertmanager webhook delivery",
                    lambda: receiver.has("firing", alert_labels),
                    timeout=ALERT_TIMEOUT,
                )
                check(matching_alert(alert_labels, state="firing"), "Prometheus exposes MetricsTargetUnavailable firing")
                check(alertmanager_active(alert_labels), "Alertmanager exposes MetricsTargetUnavailable firing")
                check(receiver.has("firing", alert_labels),
                      "local receiver captured a firing MetricsTargetUnavailable webhook")

            with phase("kubelet restoration and resolved delivery"):
                check(nft_table is not None, "outage firewall table is owned before restoration")
                restore_target(runtime, nft_table)
                nft_table = None
                wait_for(
                    "selected kubelet target to recover",
                    lambda: (
                        (current := target_for(prometheus_targets(), target_labels)) is not None
                        and current.get("health") == "up"
                        and prometheus_query("up{" + labels_selector(target_labels) + "}")[0]["value"][1] == "1"
                    ),
                    timeout=300,
                )
                wait_for(
                    "MetricsTargetUnavailable absent from Prometheus",
                    lambda: not matching_alert(alert_labels),
                    timeout=ALERT_TIMEOUT,
                )
                wait_for(
                    "MetricsTargetUnavailable absent from Alertmanager",
                    lambda: not alertmanager_active(alert_labels),
                    timeout=ALERT_TIMEOUT,
                )
                wait_for(
                    "resolved Alertmanager webhook delivery",
                    lambda: receiver.has("resolved", alert_labels),
                    timeout=ALERT_TIMEOUT,
                )
                check(not matching_alert(alert_labels), "Prometheus clears MetricsTargetUnavailable after recovery")
                check(not alertmanager_active(alert_labels), "Alertmanager clears MetricsTargetUnavailable after recovery")
                check(receiver.has("resolved", alert_labels),
                      "local receiver captured a resolved MetricsTargetUnavailable webhook")
        except BaseException:
            if runtime is not None:
                try:
                    print(runtime.kubectl("get", "applications", "-A", "-o", "wide"), file=sys.stderr)
                    print(runtime.kubectl("get", "pods", "-A", "-o", "wide"), file=sys.stderr)
                except (OSError, ScenarioError):
                    pass
            raise
        finally:
            if runtime is not None and nft_table is not None:
                try:
                    restore_target(runtime, nft_table)
                except (OSError, ScenarioError) as error:
                    print(f"WARN: failed to restore owned nft table {nft_table}: {error}", file=sys.stderr)
            if kubeconfig is not None and probe_name:
                try:
                    kubectl_outer(
                        kubeconfig,
                        "delete",
                        "pod",
                        probe_name,
                        "--ignore-not-found",
                        "--wait=false",
                        "-n",
                        "monitoring",
                    )
                except (OSError, ScenarioError):
                    pass
            for forward in reversed(forwards):
                forward.stop()
            if receiver is not None:
                receiver.stop()
            if runtime is not None:
                runtime.cleanup()
            for path in reversed(safe_dirs):
                clear_directory(path)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--bundle", required=True, type=Path)
    result.add_argument("--fixture", required=True, type=Path)
    result.add_argument("--repo", required=True, type=Path)
    result.add_argument("--seed", required=True, type=Path)
    result.add_argument("--bootstrap-host", required=True, type=Path)
    result.add_argument("--helper", required=True, type=Path)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        with phase("monitoring-runtime-scenario"):
            run_scenario(args)
    except (AssertionError, OSError, ScenarioError, KeyError, ValueError, StopIteration, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PASS: monitoring runtime scenario completed on disposable x86_64 runtime", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
