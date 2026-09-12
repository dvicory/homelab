#!/usr/bin/env python3
"""Run the prod-home compute replacement acceptance scenario.

This is intentionally a real-runtime test on x86_64. It never substitutes a
fake Incus, Kubernetes, Argo, or Jellyfin API. The fixture is produced from
the evaluated x86_64 hvn-hyp1/compute-1 configuration; execution is
restricted to the designated disposable fixture-host VMs.

Recovery follows the supported control flow using the shipped implementations:
compute-guest replaces the guest, host-staged secrets are delivered,
household-bootstrap-host seeds Argo and hands off to a test-local root
Application pointing at a disposable Git origin holding verbatim canonical
Jellyfin manifests, and Argo reconciles. K3s pulls the pinned registry images
over the network. Jellyfin behavior itself is exercised through the
jellyfin_smoke helper; this driver owns only platform orchestration.

  sudo modules/tests/prod-home-replacement.py \
    --bundle /nix/store/...-compute-1-bundle \
    --fixture /tmp/compute-fixture.json \
    --repo /nix/store/...-prod-home-recovery-repo \
    --seed /nix/store/...-prod-home-test-seed \
    --smoke /tmp/jellyfin_smoke.py \
    --bootstrap-host /nix/store/...-household-bootstrap-host/bin/household-bootstrap-host \
    --helper pkgs/by-name/compute-guest/compute-guest.py
"""

from __future__ import annotations

import argparse
import base64
import copy
import fcntl
import hashlib
import importlib.util
import ipaddress
import json
import math
import os
from pathlib import Path
import platform
import secrets
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
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


def descriptor_paths(descriptor: dict) -> list[Path]:
    paths = [Path(entry["path"]) for entry in descriptor["requiredPaths"]]
    paths.extend(Path(entry["guestPath"]) for entry in descriptor["retainedPaths"].values())
    for key in ("recoveryPath", "identityPath", "poolPath"):
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
        self.media_path = Path(descriptor["devices"]["media"]["source"])
        self.media_branches: list[Path] = []
        self.media_environment: dict[str, str] = {}
        self.media_stop = ""
        self.media_scripts: list[Path] = []
        self.media_started = False
        self.loaded_nft: list[tuple[str, str]] = []
        self.retained_mounts: list[Path] = []
        self.subid_files: dict[Path, str] = {}
        self.created_instance = False
        self.forward_proc: subprocess.Popen | None = None
        self.git_origin: GitOrigin | None = None

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

    def metrics_ready(self) -> bool:
        metrics = self.kubectl_json("get", "--raw", f"/apis/metrics.k8s.io/v1beta1/nodes/{self.instance}")
        return metrics["metadata"]["name"] == self.instance and {"cpu", "memory"} <= metrics["usage"].keys()

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

    def forward_stop(self) -> None:
        proc, self.forward_proc = self.forward_proc, None
        if proc is None:
            return
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                proc.kill()

    def stage_secrets(self, fixture: dict) -> subprocess.CompletedProcess[str]:
        # Capture all output: neither a failed producer nor its manifest may
        # print disposable credential bytes into the test log.
        root = Path(self.descriptor["devices"]["secrets"]["source"])
        try:
            return subprocess.run(
                ["/bin/sh", "-c", fixture["secretStageScript"]],
                env={**os.environ, "PATH": fixture["secretStagePath"]},
                capture_output=True, text=True, timeout=COMMAND_TIMEOUT, check=False,
            )
        finally:
            if root not in self.retained_mounts and completed("findmnt", "--mountpoint", str(root)).returncode == 0:
                self.retained_mounts.append(root)

    def check_secret_payload(self, expected: bytes) -> None:
        device = self.descriptor["devices"]["secrets"]
        root = Path(device["source"])
        manifest = root / "runtime-secrets.yaml"
        permissions = manifest.stat()
        check(run("findmnt", "-n", "-o", "FSTYPE", "-M", str(root)) == "tmpfs"
              and "ro" in run("findmnt", "-n", "-o", "VFS-OPTIONS", "-M", str(root)).split(","),
              "published credential transport remains a read-only tmpfs")
        check(permissions.st_uid == self.descriptor["idmapBase"]
              and permissions.st_gid == self.descriptor["idmapBase"]
              and permissions.st_mode & 0o7777 == 0o400,
              "published credentials are readable only by mapped guest root")
        check(manifest.read_bytes() == expected and sorted(path.name for path in root.iterdir()) == ["runtime-secrets.yaml"],
              "publication preserves the complete payload without temporary files")
        check(self.guest("sha256sum", device["path"] + "/runtime-secrets.yaml").split()[0]
              == hashlib.sha256(expected).hexdigest(),
              "guest attachment exposes the exact published credential bytes")
        check(self.guest("sh", "-ec", "test ! -r " + shlex.quote(device["path"] + "/runtime-secrets.yaml"),
                         user=751) == "",
              "unprivileged guest identity cannot read staged credentials")
        result = completed("incus", "--force-local", "--project", self.project, "exec", self.instance,
                           "--", "touch", device["path"] + "/forbidden")
        check(result.returncode != 0, "guest root cannot write through the credential attachment")

    def verify_secret_consumers(self, values: dict[str, bytes], *, fresh: bool = False) -> None:
        if fresh:
            existing = {item["metadata"]["name"] for item in self.kubectl_json("get", "namespaces", "-o", "json")["items"]}
            for namespace in sorted({entry["namespace"] for entry in self.descriptor["runtimeSecrets"].values()} - existing):
                self.kubectl("create", "namespace", namespace)

        def delivered() -> bool:
            items = self.kubectl_json("get", "secrets", "-A", "-o", "json")["items"]
            found = {(item["metadata"]["namespace"], item["metadata"]["name"]): item for item in items}
            bad = []
            for source, entry in self.descriptor["runtimeSecrets"].items():
                got = found.get((entry["namespace"], entry["name"]), {}).get("data", {}).get(entry["key"], "")
                if not got:
                    bad.append(f"{entry['namespace']}/{entry['name']}:{entry['key']} (absent)")
                elif base64.b64decode(got) != values[source]:
                    bad.append(f"{entry['namespace']}/{entry['name']}:{entry['key']} (stale)")
            # wait_for carries the last error into its timeout message, so a
            # timeout names the unmet consumers instead of staying silent.
            # Temporal evidence must travel in the message: earlier prints may
            # not survive to the visible log tail.
            if bad:
                at_sync = getattr(self, "post_sync_secrets", [])
                raise AssertionError(
                    f"unmet secret consumers: {', '.join(bad)}; "
                    f"present right after Argo sync: {at_sync}"
                )
            return True

    def start_media(self, pool: dict, root_script: str, workspace: Path) -> None:
        environment = {}
        for line in pool["environment"].splitlines():
            name, separator, value = line.partition("=")
            check(separator and name.isupper(), "media pool environment is explicit")
            environment[name] = value
        branches = [Path(branch) for branch in environment["BRANCHES"].split(":")]
        check(branches, "media pool declares branches")
        check(Path(environment["MOUNTPOINT"]) == self.media_path, "media pool targets the declared guest source")
        for branch in branches:
            branch.mkdir(parents=True, exist_ok=True)
            # Disposable tmpfs branches stand in for the host's decrypted branch
            # mounts. The cap is not a reservation: only written bytes consume
            # guest memory. It must clear mergerfs' default 4 GiB minfreespace
            # or every create fails with ENOSPC; production branches are
            # terabytes and never notice.
            run("mount", "-t", "tmpfs", "-o", "mode=0755,size=5g", "tmpfs", str(branch))
            self.media_branches.append(branch)
        self.media_environment = environment
        self.media_stop = pool["stop"]
        root_wrapper = workspace / "compute-media-root.sh"
        root_wrapper.write_text("#!/bin/sh\nset -eu\nexport PATH=" + shlex.quote(os.environ["PATH"]) + "\n" + root_script)
        root_wrapper.chmod(0o700)
        self.media_scripts.append(root_wrapper)
        for label in ("preStart", "start"):
            result = subprocess.run(shlex.split(pool[label]), env={**os.environ, **environment}, text=True, capture_output=True, timeout=COMMAND_TIMEOUT, check=False)
            check(result.returncode == 0, f"production media pool {label} succeeds: {(result.stderr or result.stdout).strip()}")
        run(str(root_wrapper))
        check(run("findmnt", "-n", "-o", "FSTYPE", "-M", str(self.media_path)) == "fuse.mergerfs", "media parent is the production pooled filesystem")
        self.media_started = True

    def stop_media(self) -> None:
        if not self.media_started:
            return
        try:
            result = subprocess.run(shlex.split(self.media_stop), env={**os.environ, **self.media_environment}, text=True, capture_output=True, timeout=COMMAND_TIMEOUT, check=False)
            check(result.returncode == 0, f"production media pool stop succeeds: {(result.stderr or result.stdout).strip()}")
        finally:
            self.media_started = False
            for branch in reversed(self.media_branches):
                completed("umount", str(branch), timeout=120)
            self.media_branches.clear()

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
        self.forward_stop()
        if self.git_origin is not None:
            self.git_origin.stop()
        if self.created_instance:
            result = completed("incus", "--force-local", "--project", self.project, "stop", self.instance, "--timeout=120", timeout=180)
            if result.returncode and "not found" not in (result.stderr or result.stdout).lower():
                print(f"WARN: instance stop: {(result.stderr or result.stdout).strip()}", file=sys.stderr)
            result = completed("incus", "--force-local", "--project", self.project, "delete", self.instance, timeout=600)
            if result.returncode and "not found" not in (result.stderr or result.stdout).lower():
                print(f"WARN: instance delete: {(result.stderr or result.stdout).strip()}", file=sys.stderr)
        try:
            self.stop_media()
        except (OSError, ScenarioError):
            pass
        completed("umount", "-l", str(self.media_path), timeout=120)
        for path in self.media_scripts:
            try:
                path.unlink()
            except FileNotFoundError:
                pass
        for family, name in reversed(self.loaded_nft):
            completed("nft", "delete", "table", family, name, timeout=120)
        for path in reversed(self.retained_mounts):
            run("umount", str(path), timeout=120)
        for path, original in self.subid_files.items():
            path.write_text(original)


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

ROOT_APP = "recovery-test-apps"
CHILD_APPS = ("jellyfin", "jellyfin-retained")
SYNC_TIMEOUT = 1500


def rewrite_text(path: Path, replacements: dict[str, str]) -> None:
    text = path.read_text()
    for old, new in replacements.items():
        check(old in text, f"{path.name} contains replaceable {old}")
        text = text.replace(old, new)
    path.write_text(text)


class GitOrigin:
    """Disposable Git origin fixture standing in for the canonical Git remote.

    The repository holds verbatim canonical manifests; only the child
    Application repository URLs/paths and the test-local root Application are
    written at runtime. Argo speaks the real Git protocol to this origin.
    """

    def __init__(self, parent: Path, address: str):
        self.parent = parent
        self.address = address
        self.url = f"git://{address}/recovery.git"
        self.process: subprocess.Popen | None = None
    def publish(self, repo: Path) -> Path:
        work = self.parent / "work"
        if work.exists():
            shutil.rmtree(work)
        shutil.copytree(repo, work, symlinks=True)
        for child in CHILD_APPS:
            rewrite_text(work / "apps" / f"Application-{child}.yaml", {
                "repoURL: https://github.com/dvicory/homelab.git": f"repoURL: {self.url}",
                f"path: ./generated/manifests/prod-home/{child}": f"path: ./{child}",
            })
        (work / "apps" / f"Application-{ROOT_APP}.yaml").write_text(
            "apiVersion: argoproj.io/v1alpha1\n"
            "kind: Application\n"
            "metadata:\n"
            f"  name: {ROOT_APP}\n"
            "  namespace: argocd\n"
            "spec:\n"
            "  destination:\n"
            "    namespace: argocd\n"
            "    server: https://kubernetes.default.svc\n"
            "  project: default\n"
            "  source:\n"
            f"    repoURL: {self.url}\n"
            "    targetRevision: main\n"
            "    path: ./apps\n"
            "  syncPolicy:\n"
            "    automated:\n"
            "      prune: true\n"
            "      selfHeal: true\n"
            "    syncOptions:\n"
            "      - ServerSideApply=true\n"
        )
        git = ["git", "-C", str(work)]
        run(*git, "init", "-b", "main")
        run(*git, "-c", "user.email=recovery@test", "-c", "user.name=recovery", "add", "-A")
        run(*git, "-c", "user.email=recovery@test", "-c", "user.name=recovery", "commit", "-m", "recovery fixture")
        bare = self.parent / "recovery.git"
        if bare.exists():
            shutil.rmtree(bare)
        run("git", "clone", "--bare", "--", str(work), str(bare))
        return work / "apps" / f"Application-{ROOT_APP}.yaml"

    def serve(self) -> None:
        check(self.process is None or self.process.poll() is not None, "git origin is not already serving")
        self.process = subprocess.Popen(
            ["git", "daemon", "--export-all", f"--base-path={self.parent}",
             f"--listen={self.address}", "--port=9418", str(self.parent)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    def stop(self) -> None:
        proc, self.process = self.process, None
        if proc is None:
            return
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                proc.kill()


def kubectl_outer(kubeconfig: Path, *args: str, timeout: int = COMMAND_TIMEOUT) -> str:
    return run("kubectl", "--kubeconfig", str(kubeconfig), *args, timeout=timeout)


def fetch_kubeconfig(runtime: Runtime, workspace: Path) -> Path:
    """Pull the guest K3s admin kubeconfig and point it at the guest address."""
    raw = workspace / "k3s.yaml"
    runtime.incus("file", "pull", f"{runtime.instance}/etc/rancher/k3s/k3s.yaml", str(raw), timeout=120)
    text = raw.read_text()
    check("https://127.0.0.1:6443" in text, "guest kubeconfig uses the loopback server")
    kubeconfig = workspace / "kubeconfig"
    kubeconfig.write_text(text.replace("https://127.0.0.1:6443", f"https://{runtime.descriptor['address']}:6443"))
    kubeconfig.chmod(0o600)
    return kubeconfig


def run_bootstrap_host(bootstrap_host: Path, runtime: Runtime, kubeconfig: Path, seed: Path) -> None:
    """Invoke the shipped household-bootstrap-host against the fresh guest."""
    env = {**os.environ, "KUBECONFIG": str(kubeconfig), "HOUSEHOLD_BOOTSTRAP_MANIFESTS": str(seed)}
    result = subprocess.run(
        [str(bootstrap_host), str(runtime.spec_path), "--confirm", runtime.instance],
        env=env, text=True, capture_output=True, timeout=3600, check=False,
    )
    print(result.stdout, flush=True)
    if result.returncode != 0:
        raise ScenarioError(f"household-bootstrap-host failed ({result.returncode}): {result.stderr.strip()}")


def wait_argo_synced(kubeconfig: Path, names: tuple[str, ...], timeout: int = SYNC_TIMEOUT) -> None:
    def synced() -> bool:
        for name in names:
            app = json.loads(kubectl_outer(kubeconfig, "get", "application", name, "-n", "argocd", "-o", "json"))
            status = app.get("status", {})
            if status.get("sync", {}).get("status") != "Synced":
                return False
            if status.get("health", {}).get("status") != "Healthy":
                return False
        return True
    wait_for(f"Argo reconciliation of {', '.join(names)}", synced, timeout=timeout)


def forward_start(runtime: Runtime, kubeconfig: Path) -> str:
    """Forward the canonical ClusterIP service to fixture-host loopback.

    Test access only: reachability flows through the already-open K3s API
    port, so neither guest firewall rules nor manifests change for the test.
    """
    if runtime.forward_proc is not None:
        runtime.forward_stop()
    proc = subprocess.Popen(
        ["kubectl", "--kubeconfig", str(kubeconfig), "-n", "jellyfin",
         "port-forward", "svc/jellyfin", "8096:8096"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    runtime.forward_proc = proc

    def reachable() -> bool:
        try:
            with socket.create_connection(("127.0.0.1", 8096), timeout=2):
                return True
        except OSError:
            if proc.poll() is not None:
                raise ScenarioError("Jellyfin port-forward exited before becoming reachable")
            return False

    wait_for("Jellyfin port-forward", reachable, timeout=180)
    return "http://127.0.0.1:8096"

def deliver_stack(runtime: Runtime, args: argparse.Namespace, workspace: Path) -> Path:
    """Run the shipped recovery control flow on a fresh cluster.

    Returns the guest kubeconfig. The driver orchestrates shipped commands;
    it does not reimplement seed, handoff, or readiness logic. The test-local
    root Application ships inside the seed tree the wrapper is pointed at.
    """
    kubeconfig = fetch_kubeconfig(runtime, workspace)
    run_bootstrap_host(args.bootstrap_host, runtime, kubeconfig, args.seed)
    # Bisect point: if these are absent here, the shipped secret apply is
    # broken; if present here but gone later, something in Argo sync removes
    # them. Bounded to Secret identities so it stays readable on failure.
    seeding = runtime.kubectl_json("get", "secrets", "-A", "-o", "json")["items"]
    want = {(entry["namespace"], entry["name"]) for entry in runtime.descriptor["runtimeSecrets"].values()}
    have = {(item["metadata"]["namespace"], item["metadata"]["name"]) for item in seeding}
    check(want <= have, f"shipped bootstrap applies all staged Secrets (missing: {sorted(want - have)})")
    wait_argo_synced(kubeconfig, (ROOT_APP, *CHILD_APPS))
    # Post-sync snapshot, stashed for the later verify failure message:
    # only the final exception text is guaranteed visible, so temporal
    # evidence must travel in the message, not in earlier prints.
    synced = runtime.kubectl_json("get", "secrets", "-A", "-o", "json")["items"]
    runtime.post_sync_secrets = sorted(
        f"{item['metadata']['namespace']}/{item['metadata']['name']}"
        for item in synced
    )
    return kubeconfig


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


def verify_private_endpoints(runtime: Runtime) -> None:
    ports = (22, 6443)
    address = runtime.descriptor["address"]
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
            for port in (*ports, 10250):
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


def run_scenario(args: argparse.Namespace) -> None:
    # Provenance stamp: binds a run to exact scenario content. A green run
    # without this line in its log never executed this file.
    print(f"PROVENANCE scenario={hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}", flush=True)
    spec = importlib.util.spec_from_file_location("jellyfin_smoke", args.smoke)
    smoke = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(smoke)
    fixture = json.loads(args.fixture.read_text())
    descriptor = json_copy(fixture["descriptor"])
    preseed = fixture["preseed"]
    media_pool = fixture["mediaPool"]
    check("config" not in preseed, "fixture preseed omits top-level Incus host API configuration")
    check(isinstance(fixture["mediaRootScript"], str) and fixture["mediaRootScript"].strip(), "fixture contains the native media-root script")
    check(all(isinstance(media_pool[key], str) and media_pool[key].strip() for key in ("preStart", "start", "stop", "environment")), "fixture contains native media pool commands")
    ensure_absolute_paths(descriptor)
    check(args.bundle.is_dir() and str(args.bundle.resolve()).startswith("/nix/store/"), "bundle is an immutable Nix store output")
    for member in ("metadata.tar.xz", "rootfs.tar.xz", "system"):
        check((args.bundle / member).exists(), f"bundle contains {member}")
    rootfs_members = run("tar", "-tJf", str(args.bundle / "rootfs.tar.xz"), timeout=600).splitlines()
    deployed_identity_paths = {"etc/ssh/ssh_host_ed25519_key", "srv/identity/ssh_host_ed25519_key"}
    check(not any(member.removeprefix("./").lstrip("/") in deployed_identity_paths for member in rootfs_members),
          "guest root artifact contains no preinstalled runtime host identity")
    check(args.helper.is_file(), "compute helper exists")
    for member in ("apps/Application-jellyfin.yaml", "apps/Application-jellyfin-retained.yaml",
                   "jellyfin", "jellyfin-retained",
                   "canonical-bootstrap.yaml"):
        check((args.repo / member).exists(), f"canonical recovery input contains {member}")
    project = descriptor["project"]
    instance_name = descriptor["instance"]
    # The fixture host only waits for the Incus unit; the API socket
    # needs its own readiness gate before the first query.
    def incus_responsive() -> bool:
        try:
            instance_query(project, instance_name)
        except Exception:
            return False
        return True
    wait_for("Incus API", incus_responsive)
    check(instance_query(project, instance_name) is None, "disposable instance is absent before the scenario")
    missing = preseed_conflicts(preseed, descriptor)

    with tempfile.TemporaryDirectory(prefix="homelab-compute-recovery-") as temporary:
        workspace = Path(temporary)
        safe_dirs: list[Path] = []
        host_paths = {Path(entry["path"]) for entry in descriptor["requiredPaths"]}
        host_paths.update(Path(device["source"]) for device in descriptor["devices"].values()
                          if device.get("type") == "disk" and "source" in device)
        for path in sorted(host_paths):
            prepare_directory(path, safe_dirs)
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
            secret_inputs = Path("/run/agenix")
            prepare_directory(secret_inputs, safe_dirs)
            run("mount", "-t", "tmpfs", "-o", "mode=0700,size=1m", "tmpfs", str(secret_inputs))
            runtime.retained_mounts.append(secret_inputs)
            secret_root = Path(descriptor["devices"]["secrets"]["source"])
            secret_manifest = secret_root / "runtime-secrets.yaml"
            check(runtime.stage_secrets(fixture).returncode != 0, "initial missing credential inputs fail closed")
            check(not any(secret_root.iterdir())
                  and "ro" in run("findmnt", "-n", "-o", "VFS-OPTIONS", "-M", str(secret_root)).split(","),
                  "missing inputs leave an empty read-only credential transport before guest creation")
            secret_values = {source: secrets.token_urlsafe(32).encode() for source in descriptor["runtimeSecrets"]}
            check(bool(secret_values), "fixture declares runtime credential inputs")
            for source, value in secret_values.items():
                with (secret_inputs / source).open("xb") as output:
                    os.chmod(output.fileno(), 0o400)
                    output.write(value)
            check(runtime.stage_secrets(fixture).returncode == 0, "complete disposable credentials publish before guest creation")
            secret_payload = secret_manifest.read_bytes()
            prepare_directory(persist, safe_dirs)
            durable = workspace / "durable"
            durable.mkdir()
            run("mount", "--bind", str(durable), str(persist))
            runtime.retained_mounts.append(persist)
            for entry in descriptor["requiredPaths"]:
                target = Path(entry["path"])
                if target == runtime.media_path:
                    continue
                backing = persist / str(target).lstrip("/")
                backing.mkdir(parents=True)
                run("mount", "--bind", str(backing), str(target))
                runtime.retained_mounts.append(target)
                os.chown(target, entry["uid"], entry["gid"])
                os.chmod(target, int(entry["mode"], 8))
                if entry["readOnly"]:
                    run("mount", "-o", "remount,bind,ro", str(target))
            public_key = stage_identity(descriptor, Path(descriptor["identityPath"]))
            spec_path.write_text(json.dumps(descriptor, indent=2) + "\n")
            spec_path.chmod(0o400)
        except BaseException:
            runtime.cleanup()
            for path in safe_dirs:
                clear_directory(path)
            raise
        try:
            load_nftables(runtime, fixture["nftables"])
            runtime.start_media(media_pool, fixture["mediaRootScript"], workspace)
            write_test_wav(runtime.media_path / "library" / "recovery.wav")
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
                if kind == "gid":
                    # The helper also requires root coverage for every
                    # identity-mapped capability GID, not just the range.
                    for row in descriptor["idmap"]["gid"]:
                        if row["nsid"] == row["hostid"] and not any(
                                owner == "root" and int(base) <= row["hostid"] < int(base) + int(count)
                                for owner, base, count in rows):
                            staged.append(f"root:{row['hostid']}:1")
                path.write_text("\n".join(staged) + "\n")

            retained = descriptor["retainedPaths"]["jellyfin-config"]
            retained_path = Path(retained["path"])
            run("umount", str(retained_path))
            try:
                os.chown(retained_path, descriptor["idmapBase"] + retained["uid"],
                         descriptor["idmapBase"] + retained["gid"])
                runtime.helper_expect_failure("create", "unmounted retained storage")
                check(instance_query(project, instance_name) is None,
                      "missing retained mount cannot create a guest on substitute storage")
            finally:
                run("mount", "--bind", str(persist / str(retained_path).lstrip("/")), str(retained_path))
            runtime.created_instance = True
            runtime.helper_run("create", bundle=args.bundle, timeout=3_600)
            wait_for("healthy K3s node", runtime.node_ready)
            wait_for("unrelated CoreDNS availability", runtime.unrelated_ready)
            wait_for("node resource metrics", runtime.metrics_ready)
            runtime.check_secret_payload(secret_payload)
            # Change one input but remove another: no partial new credential
            # set may replace the previously published complete set.
            sources = list(secret_values)
            check(len(sources) >= 2, "fixture supports a partial credential update")
            rotated, missing_source = sources[0], sources[-1]
            rotated_value = secrets.token_urlsafe(32).encode()
            (secret_inputs / rotated).write_bytes(rotated_value)
            (secret_inputs / missing_source).unlink()
            try:
                check(runtime.stage_secrets(fixture).returncode != 0, "incomplete credential rotation fails closed")
                runtime.check_secret_payload(secret_payload)
                runtime.verify_secret_consumers(secret_values)
            finally:
                (secret_inputs / missing_source).write_bytes(secret_values[missing_source])
                (secret_inputs / missing_source).chmod(0o400)
            check(runtime.stage_secrets(fixture).returncode == 0, "complete credential rotation publishes successfully")
            secret_values[rotated] = rotated_value
            rotated_payload = secret_manifest.read_bytes()
            check(rotated_payload != secret_payload, "successful rotation changes the published payload")
            for kind in ("uid", "gid"):
                mapping = [tuple(map(int, line.split())) for line in runtime.guest("cat", f"/proc/self/{kind}_map").splitlines()]
                # The media capability is an identity-mapped hole in the
                # otherwise contiguous range; compare against the declared
                # plan rather than assuming one contiguous row.
                expected = [(row["nsid"], row["hostid"], row["range"]) for row in descriptor["idmap"][kind]]
                check(mapping == expected, f"guest {kind} mapping matches the declared ID plan")
            for name, entry in descriptor["retainedPaths"].items():
                target = Path(entry["path"])
                permissions = target.stat()
                check(permissions.st_mode & 0o7777 == int(entry["mode"], 8),
                      f"{name} has its declared retained directory permissions")
                if name == "jellyfin-config":
                    expected_mode = int(entry["mode"], 8)
                    os.chmod(target, expected_mode ^ 0o001)
                    try:
                        runtime.helper_expect_failure("inspect", "required path mode drift")
                    finally:
                        os.chmod(target, expected_mode)
                probe = entry["guestPath"] + "/.retained-permission-probe"
                result = completed(
                    "incus", "--force-local", "--project", project, "exec", instance_name,
                    "--user", str(entry["uid"]), "--group", str(entry["gid"]),
                    "--mode=non-interactive", "--", "sh", "-ec",
                    "printf retained > " + shlex.quote(probe))
                if entry["readOnly"]:
                    check(result.returncode != 0, f"{name} denies writes through its declared read-only attachment")
                else:
                    check(result.returncode == 0, f"{name} permits its declared writer")
                    written = Path(entry["path"]) / ".retained-permission-probe"
                    check(written.read_text() == "retained"
                          and written.stat().st_uid == descriptor["idmapBase"] + entry["uid"]
                          and written.stat().st_gid == descriptor["idmapBase"] + entry["gid"],
                          f"{name} retains data with the declared mapped owner")
                    written.unlink()
            origin = GitOrigin(workspace / "origin", fixture["bridgeAddress"])
            root_app = origin.publish(args.repo)
            origin.serve()
            runtime.git_origin = origin
            kubeconfig = deliver_stack(runtime, args, workspace)
            runtime.verify_secret_consumers(secret_values)
            check(runtime.app_ready(), "Argo delivers Jellyfin when the intended media source is present")
            base = forward_start(runtime, kubeconfig)
            verify_private_endpoints(runtime)

            runtime.guest("sh", "-ec", "test -r /srv/media/library/recovery.wav")
            # The Incus media attachment itself is writable host storage; the
            # read-only boundary lives at the Jellyfin workload mount.
            hosted = runtime.media_path / "library" / ".compute-recovery-probe"
            hosted.write_text("host-owned\n")
            check(hosted.read_text() == "host-owned\n", "host root owns the writable media namespace")
            hosted.unlink()
            result = completed("incus", "--force-local", "--project", project, "exec", instance_name, "--user", "751", "--group", "751", "--mode=non-interactive", "--", "sh", "-ec", "touch /srv/media/library/forbidden")
            check(result.returncode != 0, "Jellyfin identity cannot write the read-only library mount")
            # The real boundary proof runs inside the Jellyfin pod at /media,
            # not merely as a guest process holding the same UID.
            pod_write = completed("incus", "--force-local", "--project", project, "exec", instance_name,
                                  "--mode=non-interactive", "--", "k3s", "kubectl", "-n", "jellyfin",
                                  "exec", "deployment/jellyfin", "--", "sh", "-ec", "touch /media/.compute-recovery-probe")
            check(pod_write.returncode != 0, "Jellyfin pod cannot write its /media library mount")
            pod_mounts = runtime.kubectl("exec", "deployment/jellyfin", "--", "cat", "/proc/mounts", namespace="jellyfin")
            media_entries = [fields for line in pod_mounts.splitlines() if len(fields := line.split()) >= 4 and fields[1] == "/media"]
            check(bool(media_entries) and all("ro" in fields[3].split(",") for fields in media_entries),
                  "Jellyfin pod mounts /media read-only")
            mounts = runtime.kubectl_json("get", "deployment/jellyfin", "-o", "json", namespace="jellyfin")["spec"]["template"]["spec"]["containers"][0]["volumeMounts"]
            library_mount = next(mount for mount in mounts if mount["name"] == "media")
            check(library_mount.get("readOnly") is True, "Jellyfin library mount is declared read-only")
            username, password = smoke.setup_first_run(base)
            token, user_id = smoke.authenticate(base, username, password)
            smoke.ensure_music_library(base, token)
            item = wait_for("indexed real media", lambda: smoke.find_audio(base, token, user_id))
            item_id = item["Id"]
            smoke.set_played(base, token, user_id, item_id, True)
            check(smoke.is_played(base, token, user_id, item_id), "Jellyfin records meaningful playback state")
            marker = Path(descriptor["retainedPaths"]["jellyfin-config"]["path"]) / ".compute-recovery-marker"
            runtime.kubectl("exec", "deployment/jellyfin", "--",
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
                command = runtime.helper_command("inspect") + ["--lock-fd", str(lock.fileno())]
                inspected = subprocess.run(command, pass_fds=(lock.fileno(),), capture_output=True, text=True, timeout=COMMAND_TIMEOUT)
                check(inspected.returncode == 0, "inspection reuses the selected held lifecycle lock")
                with runtime.spec_path.open("r") as wrong_lock:
                    command = runtime.helper_command("inspect") + ["--lock-fd", str(wrong_lock.fileno())]
                    rejected = subprocess.run(command, pass_fds=(wrong_lock.fileno(),), capture_output=True, text=True, timeout=COMMAND_TIMEOUT)
                    check(rejected.returncode != 0, "an unrelated inherited descriptor cannot bypass lifecycle serialization")
            check(instance_query(project, instance_name)["config"]["volatile.uuid"] == original_uuid,
                  "concurrent maintenance cannot replace the guest")
            runtime.guest("nix-env", "--profile", "/nix/var/nix/profiles/system", "--set", str((args.bundle / "system").resolve()))
            runtime.guest(str((args.bundle / "system").resolve() / "bin/switch-to-configuration"), "switch", timeout=600)
            wait_for("Jellyfin after independent OS activation", runtime.app_ready)
            check(instance_query(project, instance_name)["config"]["volatile.uuid"] == original_uuid,
                  "in-place system activation preserves the guest instance")
            smoke.verify_state(base, username, password, "Recovery Media", item_id)
            bad_descriptor = json_copy(descriptor)
            bad_descriptor["publicKey"] = public_key.replace("ssh-ed25519", "ssh-ed25519-bad", 1)
            bad_spec = workspace / "bad-public.json"
            bad_spec.write_text(json.dumps(bad_descriptor) + "\n")
            bad_spec.chmod(0o400)
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
                runtime.helper_expect_failure("inspect", "unsafe effective configuration")
                runtime.helper_expect_failure("replace", "incompatible effective configuration")
            finally:
                runtime.incus("config", "unset", instance_name, "user.homelab.unsafe-drift")
            check(instance_query(project, instance_name)["config"]["volatile.uuid"] == original_uuid, "unsafe instance drift does not trigger replacement")

            before_init = runtime.guest("cat", "/proc/1/stat").split()[21]
            runtime.stop_media()
            check(runtime.node_ready(), "K3s node remains healthy during application source loss")
            check(runtime.unrelated_ready(), "unrelated workload remains available during application source loss")
            result = completed("incus", "--force-local", "--project", project, "exec", instance_name, "--mode=non-interactive", "--", "sh", "-ec", "test -e /srv/media/library/recovery.wav")
            check(result.returncode != 0, "source loss never exposes a substitute media directory")
            runtime.kubectl("delete", "pod", "-l", "app.kubernetes.io/name=jellyfin", "--wait=false", namespace="jellyfin")
            wait_for("Jellyfin to stop after source loss", lambda: not runtime.app_ready(), timeout=180)
            runtime.start_media(media_pool, fixture["mediaRootScript"], workspace)
            wait_for("Jellyfin to recover after source return", runtime.app_ready, timeout=240)
            after_init = runtime.guest("cat", "/proc/1/stat").split()[21]
            check(after_init == before_init, "source return recovers Jellyfin without a node restart")

            runtime.stop_media()
            runtime.incus("stop", instance_name, "--timeout=120")
            runtime.incus("start", instance_name)
            wait_for("healthy node boot without application media", runtime.node_ready)
            wait_for("CoreDNS availability without media", runtime.unrelated_ready)
            wait_for("Jellyfin to remain blocked without media", lambda: not runtime.app_ready(), timeout=180)
            result = completed("incus", "--force-local", "--project", project, "exec", instance_name, "--mode=non-interactive", "--", "sh", "-ec", "test -e /srv/media/library/recovery.wav")
            check(result.returncode != 0, "node boot without media does not expose a substitute directory")
            runtime.start_media(media_pool, fixture["mediaRootScript"], workspace)
            wait_for("Jellyfin after media restoration", runtime.app_ready)
            base = forward_start(runtime, kubeconfig)

            unrelated_manifest = "/tmp/compute-recovery-unrelated.yaml"
            runtime.guest("sh", "-ec", f"cat > {shlex.quote(unrelated_manifest)} <<'EOF'\n{yaml_config_map('recovery-unrelated', 'keep-me')}EOF")
            runtime.kubectl("apply", "-f", unrelated_manifest)
            runtime.guest("rm", unrelated_manifest)
            # Argo, not the test driver, owns the workload: deleting the
            # Deployment must converge back to the reconciled desired state.
            runtime.kubectl("delete", "deployment/jellyfin", namespace="jellyfin")
            wait_for("Argo self-heals the Jellyfin deployment", runtime.app_ready, timeout=600)
            unrelated = runtime.kubectl_json("get", "configmap/recovery-unrelated", "-o", "json", namespace="jellyfin")
            check(unrelated["data"]["value"] == "keep-me", "Argo reconciliation preserves unmanaged objects")
            check(marker.read_text() == "retained-state\n", "Argo reconciliation preserves retained application data")

            # Application-consistent backup/restore is separate future work. This
            # scenario proves disposable guest replacement, not same-host export
            # and restore of retained state.
            token, user_id = smoke.verify_state(base, username, password, "Recovery Media", item_id)
            runtime.helper_run("replace", bundle=args.bundle, confirm=True, timeout=3_600)
            new_instance = instance_query(project, instance_name)
            check(new_instance is not None, "helper recreates the guest instance")
            check(new_instance["config"]["volatile.uuid"] != original_uuid, "replacement has a fresh Incus instance root")
            wait_for("replacement K3s node", runtime.node_ready)
            wait_for("replacement node resource metrics", runtime.metrics_ready)
            new_cluster_token = runtime.guest("cat", "/var/lib/rancher/k3s/server/token")
            check(new_cluster_token != original_cluster_token, "replacement has fresh disposable K3s cluster state")
            runtime.check_secret_payload(secret_payload)
            check(all((secret_inputs / source).read_bytes() == value for source, value in secret_values.items()),
                  "guest recreation preserves credential inputs rather than regenerating them")
            kubeconfig = deliver_stack(runtime, args, workspace)
            runtime.verify_secret_consumers(secret_values)
            base = forward_start(runtime, kubeconfig)
            check(marker.read_text() == "retained-state\n", "guest replacement preserves retained application data")
            check(marker.stat().st_uid == marker_stat.st_uid and marker.stat().st_gid == marker_stat.st_gid and marker.stat().st_mode == marker_stat.st_mode, "guest replacement preserves retained data ownership and mode")
            smoke.verify_state(base, username, password, "Recovery Media", item_id)
            check(runtime.node_ready(), "replacement node is healthy")
            check(runtime.unrelated_ready(), "replacement keeps unrelated workload available")
            if runtime.optional_gaps:
                raise ScenarioError("Missing required coverage: " + "; ".join(runtime.optional_gaps))
        finally:
            if sys.exc_info()[0] is not None and runtime.created_instance:
                diagnostics = completed("incus", "--force-local", "--project", project, "exec", instance_name,
                                        "--", "journalctl", "-u", "k3s", "-u", "sshd", "-n", "80", "--no-pager")
                print(diagnostics.stdout or diagnostics.stderr, file=sys.stderr)
                for command in (["describe", "pods"], ["logs", "deployment/jellyfin", "--tail=100"]):
                    diagnostics = completed(
                        "incus", "--force-local", "--project", project, "exec", instance_name,
                        "--", "k3s", "kubectl", "--request-timeout=15s", "-n", "jellyfin", *command)
                    print(diagnostics.stdout or diagnostics.stderr, file=sys.stderr)
            runtime.cleanup()
            for path in safe_dirs:
                clear_directory(path)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--bundle", required=True, type=Path, help="Nix store guest bundle for the fixture architecture")
    result.add_argument("--fixture", required=True, type=Path, help="evaluated host fixture JSON")
    result.add_argument("--repo", required=True, type=Path, help="canonical recovery inputs: Jellyfin manifests")
    result.add_argument("--seed", required=True, type=Path, help="bootstrap seed tree; the shipped wrapper is pointed at it")
    result.add_argument("--smoke", required=True, type=Path, help="Jellyfin application smoke helper")
    result.add_argument("--bootstrap-host", required=True, type=Path, help="shipped household-bootstrap-host executable")
    result.add_argument("--helper", type=Path, default=Path("/run/current-system/sw/bin/compute-guest"), help="generic compute lifecycle executable or repository .py helper")
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if platform.node() not in (TEST_HOSTNAME, "fixture-host"):
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
