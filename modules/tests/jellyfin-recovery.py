#!/usr/bin/env python3
"""Run the disposable Incus -> NixOS K3s -> Jellyfin recovery scenario.

This is intentionally a real-runtime test.  It never substitutes a fake Incus,
Kubernetes, or Jellyfin API. The fixture is produced from evaluated host
configuration; execution is restricted to the designated disposable test VMs.

  sudo modules/tests/jellyfin-recovery.py \
    --bundle /nix/store/...-compute-1-bundle \
    --fixture /tmp/compute-fixture.json \
    --application /nix/store/...-jellyfin-kubernetes \
    --helper pkgs/by-name/compute-guest/compute-guest.py
"""

from __future__ import annotations

import argparse
import copy
import fcntl
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import platform
import re
import secrets
import shlex
import shutil
import struct
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import wave


TEST_HOSTNAME = "lima-homelab-compute-check"
COMMAND_TIMEOUT = 180
WAIT_TIMEOUT = 240


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


def quote_path(path: str) -> str:
    return urllib.parse.quote(path, safe="/")


def json_copy(value):
    return copy.deepcopy(value)


def descriptor_paths(descriptor: dict, mounts: list[dict]) -> list[Path]:
    paths = []
    for key in ("statePath", "recoveryPath", "identityPath", "mediaPath", "poolPath"):
        value = descriptor.get(key)
        if isinstance(value, str):
            paths.append(Path(value))
    for device in descriptor.get("devices", {}).values():
        for key in ("source", "path"):
            value = device.get(key)
            if isinstance(value, str) and value.startswith("/"):
                paths.append(Path(value))
    for mount in mounts:
        for key in ("what", "where"):
            value = mount.get(key)
            if isinstance(value, str) and value.startswith("/"):
                paths.append(Path(value))
    return paths


def ensure_absolute_paths(descriptor: dict, mounts: list[dict]) -> None:
    for path in descriptor_paths(descriptor, mounts):
        check(path.is_absolute(), f"fixture path is absolute: {path}")


def instance_query(project: str, name: str) -> dict | None:
    instances = query_incus("/1.0/instances?recursion=1", project=project)
    return next((instance for instance in instances if instance["name"] == name), None)


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


def preseed_conflicts(preseed: dict, descriptor: dict) -> list[str]:
    """Return absent resources; raise on a conflict before preseed mutation."""
    project = descriptor["project"]
    missing: list[str] = []
    for wanted in preseed.get("projects", []):
        actual = query_incus(f"/1.0/projects/{quote_path(wanted['name'])}")
        if actual is None:
            missing.append(f"project/{wanted['name']}")
        else:
            for key, value in wanted.get("config", {}).items():
                check(actual.get("config", {}).get(key) == value, f"project restriction {key} is conformant")
    for wanted in preseed.get("storage_pools", []):
        actual = query_incus(f"/1.0/storage-pools/{quote_path(wanted['name'])}")
        if actual is None:
            missing.append(f"storage-pool/{wanted['name']}")
        else:
            check(actual.get("driver") == wanted.get("driver"), f"storage pool {wanted['name']} uses declared driver")
            check(actual.get("config", {}).get("source") == wanted.get("config", {}).get("source"), f"storage pool {wanted['name']} source is conformant")
    for wanted in preseed.get("networks", []):
        actual = query_incus(f"/1.0/networks/{quote_path(wanted['name'])}?project=default")
        if actual is None:
            missing.append(f"network/{wanted['name']}")
        else:
            check(actual.get("type") == wanted.get("type"), f"network {wanted['name']} is a bridge")
            config = {
                key: value
                for key, value in actual.get("config", {}).items()
                if not key.startswith("volatile.") and key != "bridge.hwaddr"
            }
            check(config == wanted.get("config", {}), f"network {wanted['name']} configuration is conformant")
    for wanted in preseed.get("profiles", []):
        actual = query_incus(f"/1.0/profiles/{quote_path(wanted['name'])}", project=wanted.get("project", project))
        if actual is None:
            missing.append(f"profile/{wanted['name']}")
        else:
            check(actual.get("config") == wanted.get("config", {}), f"profile {wanted['name']} configuration is conformant")
            check(actual.get("devices") == wanted.get("devices", {}), f"profile {wanted['name']} devices are conformant")
    return missing


def systemd_escape(path: str) -> str:
    return run("systemd-escape", "--path", "--suffix=mount", path)


def yaml_config_map(name: str, value: str) -> str:
    return "\n".join(
        [
            "apiVersion: v1",
            "kind: ConfigMap",
            "metadata:",
            f"  name: {name}",
            "  namespace: jellyfin",
            "data:",
            f"  value: {value}",
            "",
        ]
    )


def write_test_wav(path: Path) -> None:
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(8_000)
        frames = bytearray()
        for index in range(8_000):
            sample = int(8_000 * math.sin(2 * math.pi * 440 * index / 8_000))
            frames.extend(struct.pack("<h", sample))
        output.writeframes(frames)


class Runtime:
    def __init__(self, descriptor: dict, spec_path: Path, helper: Path, bundle: Path):
        self.descriptor = descriptor
        self.spec_path = spec_path
        self.helper = helper
        self.bundle = bundle
        self.project = descriptor["project"]
        self.instance = descriptor["instance"]
        self.mount_units: list[str] = []
        self.source_mounts: list[Path] = []
        self.loaded_nft: list[tuple[str, str]] = []
        self.retained_mounts: list[Path] = []
        self.subid_files: dict[Path, str] = {}
        self.units: list[Path] = []
        self.created_instance = False
        self.export_unit = "homelab-compute-recovery-export.service"
        self.root_unit = "homelab-compute-recovery-root.service"
        self.export_started = False
        self.optional_gaps: list[str] = []

    def incus(self, *args: str, timeout: int = COMMAND_TIMEOUT, input: str | None = None) -> str:
        return run("incus", "--force-local", "--project", self.project, *args, timeout=timeout, input=input)

    def guest(self, *args: str, timeout: int = COMMAND_TIMEOUT, user: int | None = None, check_result: bool = True) -> str:
        command = ["incus", "--force-local", "--project", self.project, "exec", self.instance]
        if user is not None:
            command.extend(["--user", str(user), "--group", str(user)])
        command.extend(["--mode=non-interactive", "--", *args])
        result = completed(*command, timeout=timeout)
        if check_result and result.returncode:
            details = (result.stderr or result.stdout).strip()
            raise ScenarioError(f"{shlex.join(command)} failed ({result.returncode}): {details}")
        return result.stdout.strip()

    def kubectl(self, *args: str, namespace: str | None = None, timeout: int = COMMAND_TIMEOUT) -> str:
        command = ["k3s", "kubectl"]
        if namespace:
            command.extend(["-n", namespace])
        command.extend(args)
        return self.guest(*command, timeout=timeout)

    def kubectl_json(self, *args: str, namespace: str | None = None):
        return json.loads(self.kubectl(*args, namespace=namespace))

    def helper_command(self, operation: str, *, spec: Path | None = None, bundle: Path | None = None, confirm: bool = False) -> list[str]:
        command = [str(self.helper)] if self.helper.suffix != ".py" else [sys.executable, str(self.helper)]
        command.extend(["--spec", str(spec or self.spec_path), operation])
        if bundle:
            command.extend(["--bundle", str(bundle)])
        if confirm:
            command.extend(["--confirm", self.instance])
        return command

    def helper_run(self, operation: str, *, spec: Path | None = None, bundle: Path | None = None, confirm: bool = False, timeout: int = 3_600) -> str:
        return run(*self.helper_command(operation, spec=spec, bundle=bundle, confirm=confirm), timeout=timeout)

    def helper_expect_failure(self, operation: str, expected: str, *, spec: Path | None = None) -> None:
        result = completed(*self.helper_command(operation, spec=spec, bundle=self.bundle, confirm=True), timeout=3_600)
        check(result.returncode != 0, f"helper refuses {expected}")

    def install_application(self, application: Path) -> None:
        # Standard image import and atomic publication to the native AddOn
        # directory. Application releases do not activate a NixOS generation.
        self.incus("file", "push", str(application / "image.tar"), f"{self.instance}/tmp/jellyfin-image.tar", timeout=600)
        self.guest("k3s", "ctr", "images", "import", "--local", "--snapshotter", "native", "/tmp/jellyfin-image.tar", timeout=600)
        self.guest("rm", "/tmp/jellyfin-image.tar")
        for member in ("retained", "workload"):
            staged = f"/tmp/jellyfin-{member}.yaml"
            self.incus("file", "push", str(application / f"{member}.yaml"), f"{self.instance}{staged}")
            self.guest("mv", staged, f"/var/lib/rancher/k3s/server/manifests/jellyfin-{member}.yaml")
        wait_for("Jellyfin deployment object", lambda: self.kubectl_json("get", "deployment/jellyfin", "-o", "json", namespace="jellyfin"))
        self.guest("rm", "-f", "/var/lib/rancher/k3s/server/manifests/jellyfin-workload.yaml.skip")
        self.kubectl("scale", "deployment/jellyfin", "--replicas=1", namespace="jellyfin")
        wait_for("independently delivered Jellyfin", self.app_ready)

    def systemctl(self, *args: str, timeout: int = COMMAND_TIMEOUT) -> str:
        return run("systemctl", *args, timeout=timeout)


    def stop_storage(self, *, remove_sources: bool = True) -> None:
        if self.export_started:
            result = completed("systemctl", "stop", self.export_unit, timeout=180)
            if result.returncode:
                print(f"WARN: export stop: {(result.stderr or result.stdout).strip()}", file=sys.stderr)
            self.export_started = False
        if self.mount_units:
            result = completed("systemctl", "stop", *self.mount_units, timeout=300)
            if result.returncode:
                print(f"WARN: mount stop: {(result.stderr or result.stdout).strip()}", file=sys.stderr)
        if remove_sources:
            for source in reversed(self.source_mounts):
                result = completed("umount", "-l", str(source), timeout=120)
                if result.returncode:
                    print(f"WARN: source unmount {source}: {(result.stderr or result.stdout).strip()}", file=sys.stderr)
            self.source_mounts.clear()

    def start_sources_and_storage(self, source_dirs: list[Path], source_temps: dict[Path, Path]) -> None:
        self.systemctl("start", self.root_unit)
        for source in source_dirs:
            source.mkdir(parents=True, exist_ok=True)
            run("mount", "--bind", str(source_temps[source]), str(source))
            self.source_mounts.append(source)
        self.systemctl("daemon-reload")
        self.systemctl("start", *self.mount_units, timeout=600)
        self.systemctl("start", self.export_unit, timeout=600)
        self.export_started = True
        check("ro" in run("findmnt", "-n", "-o", "VFS-OPTIONS", "-M", self.descriptor["mediaPath"]).split(","), "media parent is mounted read-only")
        check(run("findmnt", "-n", "-o", "FSTYPE", "-M", self.descriptor["mediaPath"]) == "tmpfs", "media parent is the declared tmpfs root")

    def app_ready(self) -> bool:
        deployment = self.kubectl_json("get", "deployment/jellyfin", "-o", "json", namespace="jellyfin")
        status = deployment.get("status", {})
        return status.get("availableReplicas", 0) == 1 and status.get("readyReplicas", 0) == 1

    def node_ready(self) -> bool:
        nodes = self.kubectl_json("get", "nodes", "-o", "json").get("items", [])
        return bool(nodes) and all(
            any(condition.get("type") == "Ready" and condition.get("status") == "True" for condition in node.get("status", {}).get("conditions", []))
            for node in nodes
        )

    def unrelated_ready(self) -> bool:
        pods = self.kubectl_json("get", "pods", "-l", "k8s-app=kube-dns", "-o", "json", namespace="kube-system")
        return any(
            any(condition.get("type") == "Ready" and condition.get("status") == "True" for condition in pod.get("status", {}).get("conditions", []))
            for pod in pods.get("items", [])
        )

    def cleanup(self) -> None:
        if self.created_instance:
            result = completed("incus", "--force-local", "--project", self.project, "stop", self.instance, "--timeout=120", timeout=180)
            if result.returncode and "not found" not in (result.stderr or result.stdout).lower():
                print(f"WARN: instance stop: {(result.stderr or result.stdout).strip()}", file=sys.stderr)
            result = completed("incus", "--force-local", "--project", self.project, "delete", self.instance, timeout=600)
            if result.returncode and "not found" not in (result.stderr or result.stdout).lower():
                print(f"WARN: instance delete: {(result.stderr or result.stdout).strip()}", file=sys.stderr)
        try:
            self.stop_storage()
        except (OSError, ScenarioError):
            pass
        completed("umount", "-l", self.descriptor["mediaPath"] + "/data", timeout=120)
        completed("umount", "-l", self.descriptor["mediaPath"], timeout=120)
        for unit in (self.export_unit, self.root_unit, *self.mount_units):
            completed("systemctl", "stop", unit, timeout=120)
        for path in self.units:
            try:
                path.unlink()
            except FileNotFoundError:
                pass
        completed("systemctl", "daemon-reload", timeout=120)
        for family, name in reversed(self.loaded_nft):
            completed("nft", "delete", "table", family, name, timeout=120)
        for path in reversed(self.retained_mounts):
            run("umount", str(path), timeout=120)
        for path, original in self.subid_files.items():
            path.write_text(original)


def materialize_units(runtime: Runtime, fixture: dict, root_script: str, workspace: Path) -> tuple[list[Path], list[Path]]:
    unit_dir = Path("/run/systemd/system")
    check(not (unit_dir / runtime.root_unit).exists(), f"root unit {runtime.root_unit} is disposable")
    check(not (unit_dir / runtime.export_unit).exists(), f"export unit {runtime.export_unit} is disposable")
    root_script_path = workspace / "compute-media-root.sh"
    root_script_path.write_text("#!/bin/sh\nset -eu\nexport PATH=" + shlex.quote(os.environ["PATH"]) + "\n" + root_script)
    root_script_path.chmod(0o700)
    export_start = workspace / "compute-media-export-start.sh"
    export_stop = workspace / "compute-media-export-stop.sh"
    export_start.write_text("#!/bin/sh\nset -eu\nexec /bin/sh -c " + shlex.quote(fixture["exportCommand"]) + "\n")
    export_stop.write_text("#!/bin/sh\nset -eu\nexec /bin/sh -c " + shlex.quote(fixture["exportStop"]) + "\n")
    export_start.chmod(0o700)
    export_stop.chmod(0o700)

    root_unit_path = unit_dir / runtime.root_unit
    root_unit_path.write_text(
        "[Unit]\n"
        "Description=Disposable compute media root\n"
        "Before=incus.service\n\n"
        "[Service]\n"
        "Type=oneshot\n"
        f"ExecStart={root_script_path}\n"
        "RemainAfterExit=yes\n"
    )
    runtime.units.append(root_unit_path)
    mount_paths: list[Path] = []
    for index, mount in enumerate(fixture["mounts"]):
        where = Path(mount["where"])
        unit_name = systemd_escape(str(where))
        unit_path = unit_dir / unit_name
        check(not unit_path.exists(), f"mount unit {unit_name} is disposable")
        after = " ".join(mount.get("after", []))
        binds_to = " ".join(mount.get("bindsTo", []))
        unit_path.write_text(
            "[Unit]\n"
            f"Description=Disposable compute source mount {index}\n"
            + (f"After={after}\n" if after else "")
            + (f"BindsTo={binds_to}\n" if binds_to else "")
            + "\n[Mount]\n"
            f"What={mount['what']}\n"
            f"Where={mount['where']}\n"
            "Type=none\n"
            f"Options={mount['options']}\n"
        )
        runtime.units.append(unit_path)
        runtime.mount_units.append(unit_name)
        mount_paths.append(where)

    export_unit_path = unit_dir / runtime.export_unit
    export_unit_path.write_text(
        "[Unit]\n"
        "Description=Disposable compute media export\n"
        f"Requires={runtime.root_unit}\n"
        f"After={runtime.root_unit} {' '.join(runtime.mount_units)}\n"
        f"BindsTo={' '.join(runtime.mount_units)}\n\n"
        "[Service]\n"
        "Type=simple\n"
        f"ExecStart={export_start}\n"
        f"ExecStop={export_stop}\n"
        "Restart=no\n"
    )
    runtime.units.append(export_unit_path)
    return [root_unit_path, export_unit_path], mount_paths


def load_nftables(runtime: Runtime, tables: list[dict]) -> None:
    for table in tables:
        family, name = table["family"], table["name"]
        existing = completed("nft", "list", "table", family, name)
        check(existing.returncode != 0, f"nftables table {family}/{name} is absent before the disposable run")
        content = table["content"].strip()
        if not content.startswith("table "):
            content = f"table {family} {name} {{\n{content}\n}}"
        run("nft", "-f", "-", input=content + "\n")
        runtime.loaded_nft.append((family, name))
        check(completed("nft", "list", "table", family, name).returncode == 0, f"nftables table {family}/{name} loaded from the fixture")


def source_paths(descriptor: dict, mounts: list[dict]) -> list[Path]:
    protected = {
        Path(descriptor["mediaPath"]),
        Path(descriptor["statePath"]),
        Path(descriptor["identityPath"]),
        Path(descriptor["recoveryPath"]),
    }
    result: list[Path] = []
    for mount in mounts:
        source = Path(mount["what"])
        if source not in protected and source not in result:
            result.append(source)
    return result


def prepare_directory(path: Path, safe_dirs: list[Path]) -> None:
    check(completed("findmnt", "--mountpoint", str(path)).returncode != 0, f"disposable path is not already mounted: {path}")
    if path.exists():
        check(path.is_dir() and not path.is_symlink(), f"disposable path is a directory: {path}")
        check(not any(path.iterdir()), f"disposable path starts empty: {path}")
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


def stage_identity(descriptor: dict, identity: Path, state: Path, recovery: Path) -> str:
    private = identity / "ssh_host_ed25519_key"
    run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(private), timeout=60)
    public = (identity / "ssh_host_ed25519_key.pub").read_text().strip()
    os.chown(identity, descriptor["idmapBase"], descriptor["idmapBase"])
    os.chmod(identity, 0o700)
    os.chown(private, descriptor["idmapBase"], descriptor["idmapBase"])
    os.chmod(private, 0o400)
    os.chown(identity / "ssh_host_ed25519_key.pub", descriptor["idmapBase"], descriptor["idmapBase"])
    os.chmod(identity / "ssh_host_ed25519_key.pub", 0o444)
    os.chown(state, descriptor["idmapBase"] + 751, descriptor["idmapBase"] + 751)
    os.chmod(state, 0o750)
    os.chown(recovery, descriptor["idmapBase"] + 751, descriptor["idmapBase"] + 751)
    os.chmod(recovery, 0o750)
    descriptor["publicKey"] = public
    return public


def api_request(base: str, method: str, path: str, *, token: str | None = None, payload=None, expected: tuple[int, ...] = (200,), read_body: bool = True, headers: dict[str, str] | None = None):
    request_headers = {
        "Accept": "application/json",
        "X-Emby-Authorization": 'MediaBrowser Client="homelab-compute-recovery", Device="integration", DeviceId="homelab-compute-recovery", Version="1.0"',
    }
    if token:
        request_headers["X-MediaBrowser-Token"] = token
    if headers:
        request_headers.update(headers)
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
        request_headers["Content-Type"] = "application/json"
    request = urllib.request.Request(base + path, data=data, headers=request_headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read() if read_body else b""
            status = response.status
    except urllib.error.HTTPError as error:
        body = error.read()
        status = error.code
    if status not in expected:
        text = body.decode(errors="replace")[:500]
        raise ScenarioError(f"Jellyfin {method} {path} returned HTTP {status}: {text}")
    if not body:
        return status, None
    try:
        return status, json.loads(body)
    except json.JSONDecodeError:
        return status, body


def api_bytes(base: str, path: str, token: str, expected: tuple[int, ...] = (200,)) -> bytes:
    request = urllib.request.Request(
        base + path,
        headers={
            "Accept": "*/*",
            "X-MediaBrowser-Token": token,
            "X-Emby-Authorization": 'MediaBrowser Client="homelab-compute-recovery", Device="integration", DeviceId="homelab-compute-recovery", Version="1.0"',
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            status = response.status
            body = response.read(64 * 1024)
    except urllib.error.HTTPError as error:
        raise ScenarioError(f"Jellyfin media request {path} returned HTTP {error.code}") from error
    if status not in expected:
        raise ScenarioError(f"Jellyfin media request {path} returned HTTP {status}")
    return body


def verify_private_endpoints(runtime: Runtime) -> None:
    address = runtime.descriptor["address"]
    ports = (22, 6443, 30096)
    for port in ports:
        try:
            with socket.create_connection((address, port), timeout=3):
                pass
        except OSError as error:
            diagnostics = runtime.guest("journalctl", "-u", "sshd", "-u", "compute-ssh-host-key-check", "--no-pager")
            raise ScenarioError(f"Host cannot reach {address}:{port}: {error}\n{diagnostics}") from error
        print(f"PASS: host can reach private endpoint {port}", flush=True)
    namespace, host_link, peer_link = "compute-test-peer", "compute-test-h", "compute-test-p"
    check(not os.path.lexists(f"/run/netns/{namespace}"), "network test namespace is unused")
    check(completed("ip", "link", "show", host_link).returncode != 0, "network test interface is unused")
    bridge = ipaddress.ip_interface(runtime.descriptor["networkConfig"]["ipv4.address"])
    peer_address = str(bridge.network[-2])
    check(peer_address not in (address, str(bridge.ip)), "network probe address is distinct")
    probe = "import socket,sys; socket.create_connection((sys.argv[1],int(sys.argv[2])),2).close()"
    run("ip", "netns", "add", namespace)
    try:
        run("ip", "link", "add", host_link, "type", "veth", "peer", "name", peer_link)
        run("ip", "link", "set", peer_link, "netns", namespace)
        run("ip", "link", "set", host_link, "master", runtime.descriptor["network"])
        run("ip", "link", "set", host_link, "up")
        run("ip", "-n", namespace, "link", "set", "lo", "up")
        run("ip", "-n", namespace, "link", "set", peer_link, "up")
        run("ip", "-n", namespace, "address", "add", f"{peer_address}/{bridge.network.prefixlen}", "dev", peer_link)
        for origin in ("same-bridge", "routed"):
            gateway = str(bridge.ip) if origin == "same-bridge" else "198.18.0.1"
            run("ip", "netns", "exec", namespace, "ping", "-c", "1", "-W", "2", gateway)
            for port in ports:
                result = completed("ip", "netns", "exec", namespace, "python3", "-c", probe, address, str(port))
                check(result.returncode != 0, f"{origin} peer cannot reach private endpoint {port}")
            if origin == "same-bridge":
                run("ip", "link", "set", host_link, "nomaster")
                run("ip", "address", "add", "198.18.0.1/30", "dev", host_link)
                run("ip", "-n", namespace, "address", "flush", "dev", peer_link)
                run("ip", "-n", namespace, "address", "add", "198.18.0.2/30", "dev", peer_link)
                run("ip", "-n", namespace, "route", "add", str(bridge.network), "via", "198.18.0.1")
    finally:
        completed("ip", "link", "delete", host_link)
        completed("ip", "netns", "delete", namespace)


def setup_jellyfin(runtime: Runtime) -> tuple[str, str, str, str]:
    address = runtime.descriptor["address"]
    base = f"http://{address}:30096"
    wait_for("Jellyfin HTTP health", lambda: api_request(base, "GET", "/health", expected=(200,), read_body=False))
    username = "recovery-admin"
    password = secrets.token_urlsafe(24)
    api_request(base, "POST", "/Startup/Configuration", payload={"ServerName": "compute-recovery", "UICulture": "en-US", "MetadataCountryCode": "US", "PreferredMetadataLanguage": "en"}, expected=(204, 200))
    api_request(base, "GET", "/Startup/User", expected=(200,))
    api_request(base, "POST", "/Startup/User", payload={"Name": username, "Password": password}, expected=(204, 200))
    api_request(base, "POST", "/Startup/RemoteAccess", payload={"EnableRemoteAccess": False, "EnableAutomaticPortMapping": False}, expected=(204, 200))
    api_request(base, "POST", "/Startup/Complete", payload={}, expected=(204, 200))
    auth_status, auth = api_request(base, "POST", "/Users/AuthenticateByName", payload={"Username": username, "Pw": password}, expected=(200,))
    del auth_status
    token = auth["AccessToken"]
    user_id = auth["User"]["Id"]
    library_query = urllib.parse.urlencode({"name": "Recovery Media", "collectionType": "music", "refreshLibrary": "true"})
    api_request(base, "POST", f"/Library/VirtualFolders?{library_query}", token=token, payload={"LibraryOptions": {"PathInfos": [{"Path": "/media"}]}}, expected=(204, 200))
    wait_for(
        "configured Jellyfin library",
        lambda: any(folder.get("Name") == "Recovery Media" and "/media" in folder.get("Locations", []) for folder in api_request(base, "GET", "/Library/VirtualFolders", token=token, expected=(200,))[1]),
    )
    return base, username, password, token + ":" + user_id


def find_audio(base: str, token: str, user_id: str) -> dict | None:
    query = urllib.parse.urlencode({"Recursive": "true", "IncludeItemTypes": "Audio", "Fields": "Path,MediaSources,UserData"})
    _, result = api_request(base, "GET", f"/Users/{user_id}/Items?{query}", token=token, expected=(200,))
    items = result.get("Items", [])
    return next((item for item in items if item.get("Path", "").endswith("recovery.wav")), None)


def verify_api_state(base: str, username: str, password: str, expected_library: str, expected_item: str) -> tuple[str, str]:
    _, auth = api_request(base, "POST", "/Users/AuthenticateByName", payload={"Username": username, "Pw": password}, expected=(200,))
    token = auth["AccessToken"]
    user_id = auth["User"]["Id"]
    status, _ = api_request(base, "GET", "/Startup/Configuration", expected=tuple(range(400, 600)))
    check(400 <= status < 600, "replacement does not expose the Jellyfin setup endpoint")
    _, folders = api_request(base, "GET", "/Library/VirtualFolders", token=token, expected=(200,))
    folder = next((folder for folder in folders if folder.get("Name") == expected_library), None)
    check(folder is not None and "/media" in folder.get("Locations", []), "replacement retains the configured Jellyfin library")
    _, item = api_request(base, "GET", f"/Users/{user_id}/Items/{expected_item}?Fields=Path,UserData", token=token, expected=(200,))
    check(item.get("Path", "").endswith("recovery.wav"), "replacement retains the indexed media item")
    check(item.get("UserData", {}).get("Played") is True, "replacement retains the recorded playback state")
    body = api_bytes(base, f"/Audio/{expected_item}/stream?static=true", token)
    check(body.startswith(b"RIFF") and body[8:12] == b"WAVE", "authorized client consumes the retained WAV media")
    return token, user_id


def run_scenario(args: argparse.Namespace) -> None:
    fixture = json.loads(args.fixture.read_text())
    descriptor = json_copy(fixture["descriptor"])
    preseed = fixture["preseed"]
    mounts = fixture["mounts"]
    check("config" not in preseed, "fixture preseed omits top-level Incus host API configuration")
    check(isinstance(fixture["rootScript"], str) and fixture["rootScript"].strip(), "fixture contains the native media-root script")
    check(isinstance(fixture["exportCommand"], str) and fixture["exportCommand"].strip(), "fixture contains the native media export command")
    check(isinstance(fixture["exportStop"], str) and fixture["exportStop"].strip(), "fixture contains the native media export stop command")
    check(isinstance(mounts, list) and mounts, "fixture contains native source mount declarations")
    ensure_absolute_paths(descriptor, mounts)
    check(args.bundle.is_dir() and str(args.bundle.resolve()).startswith("/nix/store/"), "bundle is an immutable Nix store output")
    for member in ("metadata.tar.xz", "rootfs.tar.xz", "system"):
        check((args.bundle / member).exists(), f"bundle contains {member}")
    check(args.helper.is_file(), "compute helper exists")
    for member in ("image.tar", "image-reference", "retained.yaml", "workload.yaml"):
        check((args.application / member).exists(), f"application artifact contains {member}")
    project = descriptor["project"]
    instance_name = descriptor["instance"]
    check(instance_query(project, instance_name) is None, "disposable instance is absent before the scenario")
    missing = preseed_conflicts(preseed, descriptor)

    with tempfile.TemporaryDirectory(prefix="homelab-compute-recovery-") as temporary:
        workspace = Path(temporary)
        safe_dirs: list[Path] = []
        source_temps: dict[Path, Path] = {}
        for key in ("statePath", "recoveryPath", "identityPath", "mediaPath"):
            prepare_directory(Path(descriptor[key]), safe_dirs)
        for source in source_paths(descriptor, mounts):
            prepare_directory(source, safe_dirs)
            source_temps[source] = workspace / ("source-" + hashlib.sha256(str(source).encode()).hexdigest()[:12])
            source_temps[source].mkdir()
        check(source_temps, "fixture identifies at least one disposable media source")
        first_source = next(iter(source_temps))
        write_test_wav(source_temps[first_source] / "recovery.wav")
        spec_path = workspace / "compute.json"
        runtime = Runtime(descriptor, spec_path, args.helper, args.bundle)
        # Native preseed validates recursive bind sources; the production
        # host prepares retained directories and the media parent first.
        if missing:
            run("incus", "--force-local", "admin", "init", "--preseed", input=json.dumps(preseed) + "\n", timeout=600)
            check(not preseed_conflicts(preseed, descriptor), "native Incus preseed creates all missing declared resources")
        else:
            print("PASS: existing Incus project/network/profile/pool are conformant and borrowed", flush=True)
        try:
            persist = Path("/persist")
            prepare_directory(persist, safe_dirs)
            durable = workspace / "durable"
            durable.mkdir()
            run("mount", "--bind", str(durable), str(persist))
            runtime.retained_mounts.append(persist)
            for key in ("statePath", "identityPath", "recoveryPath"):
                target = Path(descriptor[key])
                backing = persist / str(target).lstrip("/")
                backing.mkdir(parents=True)
                run("mount", "--bind", str(backing), str(target))
                runtime.retained_mounts.append(target)
            public_key = stage_identity(descriptor, Path(descriptor["identityPath"]), Path(descriptor["statePath"]), Path(descriptor["recoveryPath"]))
            spec_path.write_text(json.dumps(descriptor, indent=2) + "\n")
        except BaseException:
            runtime.cleanup()
            for path in safe_dirs:
                clear_directory(path)
            raise
        try:
            materialize_units(runtime, fixture, fixture["rootScript"], workspace)
            run("systemctl", "daemon-reload", timeout=120)
            load_nftables(runtime, fixture["nftables"])
            runtime.start_sources_and_storage(list(source_temps), source_temps)
            check(public_key == descriptor["publicKey"], "descriptor public identity is the disposable staged key")
            # Lima reserves a very large range for its login user. Carve the
            # fixture's range out temporarily; never weaken the helper's check.
            start = descriptor["idmapBase"]
            end = start + descriptor["idmapSize"]
            for kind in ("uid", "gid"):
                path = Path("/etc/sub" + kind)
                original = path.read_text()
                rows = [line.split(":") for line in original.splitlines() if line and not line.startswith("#")]
                if not any(owner == "lima" for owner, _, _ in rows):
                    continue
                runtime.subid_files[path] = original
                staged = []
                for owner, base, count in rows:
                    lower, upper = int(base), int(base) + int(count)
                    if owner == "lima" and lower < end and upper > start:
                        # usermod refuses the logged-in Lima user; this VM is
                        # disposable and cleanup restores both original files.
                        if lower < start:
                            staged.append(f"lima:{lower}:{start - lower}")
                        if upper > end:
                            staged.append(f"lima:{end}:{upper - end}")
                    else:
                        staged.append(f"{owner}:{base}:{count}")
                if not any(owner == "root" and int(base) <= start and int(base) + int(count) >= end
                           for owner, base, count in rows):
                    staged.append(f"root:{start}:{end - start}")
                path.write_text("\n".join(staged) + "\n")

            runtime.created_instance = True
            runtime.helper_run("create", bundle=args.bundle, timeout=3_600)
            wait_for("healthy K3s node", runtime.node_ready)
            wait_for("unrelated CoreDNS availability", runtime.unrelated_ready)
            for kind in ("uid", "gid"):
                mapping = [tuple(map(int, line.split())) for line in runtime.guest("cat", f"/proc/self/{kind}_map").splitlines()]
                check(mapping == [(0, descriptor["idmapBase"], descriptor["idmapSize"])],
                      f"guest {kind} mapping uses the declared non-root host range")
            check(all(item["metadata"]["namespace"] != "jellyfin"
                      for item in runtime.kubectl_json("get", "deployments", "-A", "-o", "json")["items"]),
                  "guest starts without a bundled Jellyfin deployment")
            runtime.install_application(args.application)
            check(runtime.app_ready(), "Jellyfin starts when the intended media source is present")
            verify_private_endpoints(runtime)

            media_probe = runtime.guest("sh", "-ec", "test -r /srv/media/data/recovery.wav")
            del media_probe
            result = completed("incus", "--force-local", "--project", project, "exec", instance_name, "--mode=non-interactive", "--", "sh", "-ec", "touch /srv/media/data/forbidden")
            check(result.returncode != 0, "guest media write is denied at the Incus read-only boundary")
            result = completed("touch", str(Path(descriptor["mediaPath"]) / "data" / "forbidden"))
            check(result.returncode != 0, "host root cannot write through the read-only media export")
            result = completed("incus", "--force-local", "--project", project, "exec", instance_name, "--mode=non-interactive", "--", "sh", "-ec", "mount -o remount,rw /srv/media")
            check(result.returncode != 0, "guest root cannot remount the media attachment read-write")
            result = completed("incus", "--force-local", "--project", project, "exec", instance_name, "--user", "751", "--group", "751", "--mode=non-interactive", "--", "sh", "-ec", "touch /srv/media/data/forbidden")
            check(result.returncode != 0, "Jellyfin identity cannot write read-only media")

            base, username, password, auth_identity = setup_jellyfin(runtime)
            token, user_id = auth_identity.split(":", 1)
            item = wait_for("indexed real media", lambda: find_audio(base, token, user_id))
            item_id = item["Id"]
            api_request(base, "POST", f"/Users/{user_id}/PlayedItems/{item_id}", token=token, expected=(204, 200))
            _, played = api_request(base, "GET", f"/Users/{user_id}/Items/{item_id}?Fields=Path,UserData", token=token, expected=(200,))
            check(played.get("UserData", {}).get("Played") is True, "Jellyfin records meaningful playback state")
            marker = Path(descriptor["statePath"]) / ".compute-recovery-marker"
            runtime.kubectl("exec", "deployment/jellyfin", "-c", "jellyfin", "--",
                            "sh", "-ec", "printf 'retained-state\\n' > /config/.compute-recovery-marker",
                            namespace="jellyfin")
            marker_stat = marker.stat()
            check(marker.read_text() == "retained-state\n" and marker_stat.st_uid == descriptor["idmapBase"] + 751,
                  "Jellyfin writes retained application data as its declared mapped identity")

            original_uuid = query_incus(f"/1.0/instances/{quote_path(instance_name)}", project=project)["config"]["volatile.uuid"]
            original_cluster_token = runtime.guest("cat", "/var/lib/rancher/k3s/server/token")
            runtime.helper_run("create", bundle=args.bundle)
            check(instance_query(project, instance_name)["config"]["volatile.uuid"] == original_uuid,
                  "repeated creation preserves the existing guest")
            with Path(f"/run/lock/compute-{project}-{instance_name}.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                runtime.helper_expect_failure("replace", "concurrent maintenance")
            check(instance_query(project, instance_name)["config"]["volatile.uuid"] == original_uuid,
                  "concurrent maintenance cannot replace the guest")
            runtime.guest("nix-env", "--profile", "/nix/var/nix/profiles/system", "--set", str((args.bundle / "system").resolve()))
            runtime.guest(str((args.bundle / "system").resolve() / "bin/switch-to-configuration"), "switch", timeout=600)
            wait_for("Jellyfin after independent OS activation", runtime.app_ready)
            check(instance_query(project, instance_name)["config"]["volatile.uuid"] == original_uuid,
                  "in-place system activation preserves the guest instance")
            verify_api_state(base, username, password, "Recovery Media", item_id)
            bad_descriptor = json_copy(descriptor)
            bad_descriptor["publicKey"] = public_key.replace("ssh-ed25519", "ssh-ed25519-bad", 1)
            bad_spec = workspace / "bad-public.json"
            bad_spec.write_text(json.dumps(bad_descriptor) + "\n")
            runtime.helper_expect_failure("replace", "declared public identity", spec=bad_spec)
            check(instance_query(project, instance_name)["config"]["volatile.uuid"] == original_uuid, "mismatched identity does not mutate the instance")
            public_path = Path(descriptor["identityPath"]) / "ssh_host_ed25519_key.pub"
            trusted_public = public_path.read_text()
            other_key = workspace / "other-identity"
            run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(other_key))
            runtime.guest("systemctl", "stop", "sshd.service")
            public_path.write_text(other_key.with_suffix(".pub").read_text())
            try:
                runtime.guest("sh", "-ec",
                              "if systemctl start sshd.service; then exit 1; fi; ! systemctl is-active --quiet sshd.service")
                check(runtime.node_ready(), "mismatched staged identity blocks SSH without stopping Kubernetes")
            finally:
                public_path.write_text(trusted_public)
                runtime.guest("systemctl", "start", "sshd.service")
            private = Path(descriptor["identityPath"]) / "ssh_host_ed25519_key"
            missing_private = private.with_name("ssh_host_ed25519_key.missing")
            runtime.guest("systemctl", "stop", "sshd.service")
            private.rename(missing_private)
            try:
                runtime.helper_expect_failure("replace", "No such file")
                runtime.guest("sh", "-ec",
                              "if systemctl start sshd.service; then exit 1; fi; ! systemctl is-active --quiet sshd.service")
                check(not private.exists() and runtime.node_ready(),
                      "missing identity blocks SSH without generating a key or stopping Kubernetes")
            finally:
                missing_private.rename(private)
                runtime.guest("systemctl", "start", "sshd.service")
            check(instance_query(project, instance_name)["config"]["volatile.uuid"] == original_uuid, "missing identity does not mutate the instance")
            runtime.incus("config", "set", instance_name, "user.homelab.unsafe-drift", "true")
            try:
                runtime.helper_expect_failure("replace", "incompatible effective configuration")
            finally:
                runtime.incus("config", "unset", instance_name, "user.homelab.unsafe-drift")
            check(instance_query(project, instance_name)["config"]["volatile.uuid"] == original_uuid, "unsafe instance drift does not trigger replacement")

            before_init = runtime.guest("cat", "/proc/1/stat").split()[21]
            run("umount", "-l", str(first_source))
            runtime.source_mounts.remove(first_source)
            wait_for("native source-loss shutdown",
                     lambda: completed("systemctl", "is-active", runtime.export_unit).returncode != 0)
            check(runtime.node_ready(), "K3s node remains healthy during application source loss")
            check(runtime.unrelated_ready(), "unrelated workload remains available during application source loss")
            result = completed("incus", "--force-local", "--project", project, "exec", instance_name, "--mode=non-interactive", "--", "sh", "-ec", "test -e /srv/media/data/recovery.wav")
            check(result.returncode != 0, "source loss never exposes a substitute media directory")
            runtime.kubectl("delete", "pod", "-l", "app.kubernetes.io/name=jellyfin", "--wait=false", namespace="jellyfin")
            wait_for("Jellyfin to stop after source loss", lambda: not runtime.app_ready(), timeout=180)
            runtime.stop_storage()
            runtime.start_sources_and_storage(list(source_temps), source_temps)
            wait_for("Jellyfin to recover after source return", runtime.app_ready, timeout=240)
            after_init = runtime.guest("cat", "/proc/1/stat").split()[21]
            check(after_init == before_init, "source return recovers Jellyfin without a node restart")

            runtime.stop_storage()
            runtime.incus("stop", instance_name, "--timeout=120")
            runtime.incus("start", instance_name)
            wait_for("healthy node boot without application media", runtime.node_ready)
            wait_for("CoreDNS availability without media", runtime.unrelated_ready)
            wait_for("Jellyfin to remain blocked without media", lambda: not runtime.app_ready(), timeout=180)
            result = completed("incus", "--force-local", "--project", project, "exec", instance_name, "--mode=non-interactive", "--", "sh", "-ec", "test -e /srv/media/data/recovery.wav")
            check(result.returncode != 0, "node boot without media does not expose a substitute directory")
            runtime.start_sources_and_storage(list(source_temps), source_temps)
            wait_for("Jellyfin after media restoration", runtime.app_ready)

            disposable_manifest = "/var/lib/rancher/k3s/server/manifests/compute-recovery-disposable.yaml"
            unrelated_manifest = "/var/lib/rancher/k3s/server/manifests/compute-recovery-unrelated.yaml"
            runtime.guest("sh", "-ec", f"cat > {shlex.quote(unrelated_manifest)} <<'EOF'\n{yaml_config_map('recovery-unrelated', 'keep-me')}EOF\ncat > {shlex.quote(disposable_manifest)} <<'EOF'\n{yaml_config_map('recovery-disposable', 'remove-me')}EOF")
            wait_for("native AddOn objects", lambda: runtime.kubectl("get", "configmap/recovery-disposable", namespace="jellyfin") or True)
            runtime.guest("sh", "-ec", f"cat > {shlex.quote(disposable_manifest)} <<'EOF'\nEOF")
            wait_for("native AddOn pruning", lambda: not any(
                item["metadata"]["name"] == "recovery-disposable"
                for item in runtime.kubectl_json("get", "configmaps", "-o", "json", namespace="jellyfin")["items"]))
            unrelated = runtime.kubectl_json("get", "configmap/recovery-unrelated", "-o", "json", namespace="jellyfin")
            check(unrelated["data"]["value"] == "keep-me", "native AddOn pruning preserves an unrelated object and its data")
            check(marker.read_text() == "retained-state\n", "native AddOn pruning preserves retained application data")
            runtime.guest("rm", "-f", disposable_manifest, unrelated_manifest)

            # Exercise the explicit maintenance procedure, not a production
            # application-aware guest manager.
            checkpoint = Path(descriptor["recoveryPath"]) / "checkpoint"
            state = Path(descriptor["statePath"])
            required = int(run("du", "-sb", str(state)).split()[0])
            check(shutil.disk_usage(checkpoint.parent).free >= 3 * required + 1024**3,
                  "space exists for complete checkpoint and preserved restore copies")
            with Path(f"/run/lock/compute-{project}-{instance_name}.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                runtime.guest("touch", "/var/lib/rancher/k3s/server/manifests/jellyfin-workload.yaml.skip")
                runtime.kubectl("scale", "deployment/jellyfin", "--replicas=0", namespace="jellyfin")
                wait_for("no application pods before checkpoint", lambda: not runtime.kubectl_json(
                    "get", "pods", "-l", "app.kubernetes.io/name=jellyfin", "-o", "json", namespace="jellyfin")["items"])
                running = json.loads(runtime.guest("k3s", "crictl", "ps", "-o", "json"))["containers"]
                check(not any(c.get("labels", {}).get("io.kubernetes.pod.namespace") == "jellyfin" for c in running),
                      "runtime has no application writer before copying retained state")
                checkpoint.mkdir(mode=0o700)
                run("nix-store", "--add-root", str(checkpoint / "application"), "--indirect", "--realise", str(args.application))
                run("cp", "-a", "--reflink=auto", str(state), str(checkpoint / "config"), timeout=600)
                run("sync", "-f", str(checkpoint))
                (checkpoint / "complete").touch()
                run("sync", "-f", str(checkpoint))
                runtime.guest("rm", "/var/lib/rancher/k3s/server/manifests/jellyfin-workload.yaml.skip")
                runtime.kubectl("scale", "deployment/jellyfin", "--replicas=1", namespace="jellyfin")
            wait_for("application after checkpoint", runtime.app_ready)
            # A real post-checkpoint state change must be undone by paired restore.
            token, user_id = verify_api_state(base, username, password, "Recovery Media", item_id)
            api_request(base, "DELETE", f"/Users/{user_id}/PlayedItems/{item_id}", token=token, expected=(204, 200))
            _, changed = api_request(base, "GET", f"/Users/{user_id}/Items/{item_id}?Fields=UserData", token=token, expected=(200,))
            check(changed.get("UserData", {}).get("Played") is False, "post-checkpoint playback state differs")
            with Path(f"/run/lock/compute-{project}-{instance_name}.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                run("test", "-f", str(checkpoint / "complete"))
                run("nix-store", "--realise", str(checkpoint / "application"))
                required = int(run("du", "-sb", str(checkpoint / "config")).split()[0])
                live = int(run("du", "-sb", str(state)).split()[0])
                check(shutil.disk_usage(checkpoint.parent).free >= required + live + 1024**3,
                      "space exists for restore and displaced live data")
                runtime.guest("touch", "/var/lib/rancher/k3s/server/manifests/jellyfin-workload.yaml.skip")
                runtime.kubectl("scale", "deployment/jellyfin", "--replicas=0", namespace="jellyfin")
                wait_for("no application pods before restore", lambda: not runtime.kubectl_json(
                    "get", "pods", "-l", "app.kubernetes.io/name=jellyfin", "-o", "json", namespace="jellyfin")["items"])
                check(not runtime.guest("k3s", "crictl", "ps", "--label", "io.kubernetes.pod.namespace=jellyfin", "-q").strip(),
                      "runtime has no application writer before restore")
                runtime.incus("stop", instance_name, "--timeout=120")
                displaced = checkpoint.parent / "displaced"
                run("cp", "-a", "--reflink=auto", str(state), str(displaced), timeout=600)
                run("sync", "-f", str(displaced))
                for child in state.iterdir():
                    if child.is_dir() and not child.is_symlink():
                        shutil.rmtree(child)
                    else:
                        child.unlink()
                run("cp", "-a", "--reflink=auto", str(checkpoint / "config") + "/.", str(state), timeout=600)
                run("sync", "-f", str(state))
                runtime.incus("start", instance_name)
                wait_for("node after explicit data restore", runtime.node_ready)
                runtime.install_application((checkpoint / "application").resolve())
            verify_api_state(base, username, password, "Recovery Media", item_id)
            runtime.helper_run("replace", bundle=args.bundle, confirm=True, timeout=3_600)
            new_instance = instance_query(project, instance_name)
            check(new_instance is not None, "helper recreates the guest instance")
            check(new_instance["config"]["volatile.uuid"] != original_uuid, "replacement has a fresh Incus instance root")
            wait_for("replacement K3s node", runtime.node_ready)
            new_cluster_token = runtime.guest("cat", "/var/lib/rancher/k3s/server/token")
            check(new_cluster_token != original_cluster_token, "replacement has fresh disposable K3s cluster state")
            runtime.install_application(args.application)
            check(marker.read_text() == "retained-state\n", "guest replacement preserves retained application data")
            check(marker.stat().st_uid == marker_stat.st_uid and marker.stat().st_gid == marker_stat.st_gid and marker.stat().st_mode == marker_stat.st_mode, "guest replacement preserves retained data ownership and mode")
            verify_api_state(base, username, password, "Recovery Media", item_id)
            check(runtime.node_ready(), "replacement node is healthy")
            check(runtime.unrelated_ready(), "replacement keeps unrelated workload available")
            if runtime.optional_gaps:
                raise ScenarioError("Missing required coverage: " + "; ".join(runtime.optional_gaps))
        finally:
            if sys.exc_info()[0] is not None and runtime.created_instance:
                diagnostics = completed("incus", "--force-local", "--project", project, "exec", instance_name,
                                        "--", "journalctl", "-u", "k3s", "-u", "sshd", "-n", "80", "--no-pager")
                print(diagnostics.stdout or diagnostics.stderr, file=sys.stderr)
                for command in (["describe", "pods"], ["logs", "deployment/jellyfin", "-c", "jellyfin", "--tail=100"]):
                    diagnostics = completed(
                        "incus", "--force-local", "--project", project, "exec", instance_name,
                        "--", "k3s", "kubectl", "--request-timeout=15s", "-n", "jellyfin", *command)
                    print(diagnostics.stdout or diagnostics.stderr, file=sys.stderr)
            runtime.cleanup()
            for path in safe_dirs:
                clear_directory(path)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--bundle", required=True, type=Path, help="Nix store guest bundle matching the test host architecture")
    result.add_argument("--fixture", required=True, type=Path, help="evaluated host fixture JSON")
    result.add_argument("--application", required=True, type=Path, help="independent Jellyfin Kubernetes release artifact")
    result.add_argument("--helper", type=Path, default=Path("/run/current-system/sw/bin/compute-guest"), help="generic compute lifecycle executable or repository .py helper")
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if platform.node() not in (TEST_HOSTNAME, "compute-recovery"):
        parser().error("refusing to run outside a designated disposable compute test host")
    if os.geteuid() != 0:
        parser().error("run as root inside the disposable Linux guest")
    if not args.fixture.is_file():
        parser().error(f"fixture does not exist: {args.fixture}")
    if not args.bundle.is_dir():
        parser().error(f"bundle does not exist: {args.bundle}")
    try:
        run_scenario(args)
    except (AssertionError, OSError, ScenarioError, KeyError, ValueError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PASS: compute recovery scenario completed on disposable runtime", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
