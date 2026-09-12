#!/usr/bin/env python3
"""Measure the current compute guest on a disposable x86 NixOS/ZFS host.

The scenario deliberately owns every Incus project, pool, network, and guest it
creates.  Native and overlayfs use separate guests and are run sequentially.
This is a storage compatibility check, not production deployment or recovery
acceptance.
"""

from __future__ import annotations

import argparse
import copy
import fcntl
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import time

ONE_GIB = 1 << 30
COMMAND_TIMEOUT = 180
NODE_TIMEOUT = 300
OBSERVATION_MINIMUM = 60


class ScenarioError(RuntimeError):
    """A bounded disposable-runtime assertion failed."""


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--native-bundle", required=True, type=Path)
    result.add_argument("--overlay-bundle", required=True, type=Path)
    result.add_argument("--manifests", required=True, type=Path)
    result.add_argument("--output", required=True, type=Path)
    result.add_argument("--incus", default="incus")
    result.add_argument("--pool-root", default="/var/lib/compute-storage-zfs", type=Path)
    result.add_argument("--observe-seconds", default=180, type=int)
    return result


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def write_result(directory: Path, label: str, result: subprocess.CompletedProcess[str]) -> None:
    (directory / f"{label}.stdout").write_text(result.stdout)
    (directory / f"{label}.stderr").write_text(result.stderr)
    (directory / f"{label}.status").write_text(f"{result.returncode}\n")


def command(
    directory: Path,
    label: str,
    argv: list[object],
    *,
    input_text: str = "",
    timeout: int = COMMAND_TIMEOUT,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    words = [str(word) for word in argv]
    try:
        result = subprocess.run(
            words,
            input=input_text,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        result = subprocess.CompletedProcess(words, 124, "", str(error))
        write_result(directory, f"{label}.timeout", result)
        write_json(directory / f"{label}.command.json", words)
        if check:
            raise ScenarioError(f"timed out after {timeout}s: {' '.join(words)}") from error
        return result
    write_result(directory, label, result)
    write_json(directory / f"{label}.command.json", words)
    if check and result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise ScenarioError(f"command failed ({result.returncode}): {' '.join(words)}: {detail}")
    return result


def mark(output: Path, started: float, phase: str, **values: object) -> None:
    row = {"phase": phase, "elapsedSeconds": round(time.monotonic() - started, 2), **values}
    print(json.dumps(row, sort_keys=True), flush=True)
    with (output / "phases.jsonl").open("a") as stream:
        stream.write(json.dumps(row, sort_keys=True) + "\n")


def json_stdout(result: subprocess.CompletedProcess[str]) -> dict:
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ScenarioError(f"expected JSON, got: {result.stdout[:300]}") from error
    if not isinstance(value, dict):
        raise ScenarioError("expected a JSON object")
    return value


def project_command(incus: list[str], project: str, *args: object) -> list[object]:
    return [*incus, "--project", project, *args]


def guest_command(incus: list[str], project: str, *args: object) -> list[object]:
    return project_command(incus, project, "exec", "probe", "--", *args)


def kube_command(incus: list[str], project: str, *args: object) -> list[object]:
    return guest_command(incus, project, "k3s", "kubectl", "--request-timeout=15s", *args)


def pod_is_evicted(pod: dict) -> bool:
    status = pod.get("status", {})
    if status.get("reason") == "Evicted":
        return True
    for container in status.get("containerStatuses", []) + status.get("initContainerStatuses", []):
        if container.get("state", {}).get("terminated", {}).get("reason") == "Evicted":
            return True
    return False


def cri_measurement(raw: str, pod_name: str) -> dict:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return {"present": False, "matches": 0, "writableLayerBytes": 0}
    matches = []
    for entry in value.get("stats", []):
        labels = entry.get("attributes", {}).get("labels", {})
        if (
            labels.get("io.kubernetes.pod.namespace") == "jellyfin"
            and labels.get("io.kubernetes.pod.name") == pod_name
            and labels.get("io.kubernetes.container.name") == "main"
        ):
            matches.append(entry)
    usage = [
        int(entry.get("writableLayer", {}).get("usedBytes", {}).get("value", 0))
        for entry in matches
    ]
    return {
        "present": bool(matches),
        "matches": len(matches),
        "writableLayerBytes": max(usage, default=0),
    }


def summary_measurement(raw: str, pod_name: str) -> dict:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return {"present": False, "matches": 0, "ephemeralStorageBytes": 0}
    matches = [
        entry
        for entry in value.get("pods", [])
        if entry.get("podRef", {}).get("namespace") == "jellyfin"
        and entry.get("podRef", {}).get("name") == pod_name
    ]
    usage = [
        int(entry.get("ephemeral-storage", {}).get("usedBytes", 0))
        for entry in matches
    ]
    return {
        "present": bool(matches),
        "matches": len(matches),
        "ephemeralStorageBytes": max(usage, default=0),
    }


def configured_snapshotter(text: str) -> str:
    import tomllib

    return tomllib.loads(text)["plugins"]["io.containerd.cri.v1.images"]["snapshotter"]


def wait_for_node(
    incus: list[str],
    project: str, directory: Path, started: float
) -> None:
    deadline = time.monotonic() + NODE_TIMEOUT
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        result = command(
            directory,
            f"node-ready-{attempt:03d}",
            kube_command(incus, project, "get", "nodes", "-o", "json"),
            timeout=30,
            check=False,
        )
        if result.returncode == 0:
            try:
                nodes = json.loads(result.stdout).get("items", [])
            except json.JSONDecodeError:
                nodes = []
            if any(
                condition.get("type") == "Ready" and condition.get("status") == "True"
                for node in nodes
                for condition in node.get("status", {}).get("conditions", [])
            ):
                mark(directory.parent, started, "k3s-ready", project=project)
                return
        time.sleep(3)
    raise ScenarioError(f"K3s did not become ready within {NODE_TIMEOUT}s")


def wait_for_pod(
    incus: list[str], project: str, directory: Path, selector: str, timeout: int = 180
) -> dict | None:
    deadline = time.monotonic() + timeout
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        result = command(
            directory,
            f"pod-create-{attempt:03d}",
            kube_command(
                incus,
                project,
                "-n",
                "jellyfin",
                "get",
                "pods",
                "-l",
                selector,
                "-o",
                "json",
            ),
            timeout=30,
            check=False,
        )
        if result.returncode == 0:
            try:
                items = json.loads(result.stdout).get("items", [])
            except json.JSONDecodeError:
                items = []
            if items:
                return sorted(
                    items,
                    key=lambda item: item.get("metadata", {}).get("creationTimestamp", ""),
                )[-1]
        time.sleep(3)
    return None


def observe(
    incus: list[str],
    project: str,
    directory: Path,
    started: float,
    observe_seconds: int,
) -> dict:
    selector = "app.kubernetes.io/instance=jellyfin"
    deadline = time.monotonic() + 240 + observe_seconds
    healthy_since = None
    samples: list[dict] = []
    health_responses = 0
    evicted_pods: set[str] = set()
    last_pod: str | None = None
    while time.monotonic() < deadline:
        stamp = f"{len(samples):04d}"
        pod = wait_for_pod(incus, project, directory, selector, timeout=15)
        pod_name = pod.get("metadata", {}).get("name") if pod else None
        if pod_name:
            last_pod = pod_name
            write_json(directory / f"sample-{stamp}-pod.json", pod)
            if pod_is_evicted(pod):
                evicted_pods.add(pod_name)
        cri = command(
            directory,
            f"sample-{stamp}-cri",
            guest_command(incus, project, "k3s", "crictl", "stats", "-o", "json"),
            timeout=60,
            check=False,
        )
        summary = command(
            directory,
            f"sample-{stamp}-summary",
            kube_command(
                incus,
                project,
                "get",
                "--raw",
                "/api/v1/nodes/compute-1/proxy/stats/summary",
            ),
            timeout=60,
            check=False,
        )
        cri_usage = cri_measurement(cri.stdout, pod_name) if pod_name else {
            "present": False,
            "matches": 0,
            "writableLayerBytes": 0,
        }
        pod_usage = summary_measurement(summary.stdout, pod_name) if pod_name else {
            "present": False,
            "matches": 0,
            "ephemeralStorageBytes": 0,
        }
        health = {"status": None, "body": ""}
        if pod_name and pod and pod.get("status", {}).get("phase") == "Running":
            health_result = command(
                directory,
                f"sample-{stamp}-health",
                kube_command(
                    incus,
                    project,
                    "get",
                    "--raw",
                    f"/api/v1/namespaces/jellyfin/pods/{pod_name}:8096/proxy/health",
                ),
                timeout=30,
                check=False,
            )
            health = {
                "status": health_result.returncode,
                "body": health_result.stdout.strip(),
            }
            if health_result.returncode == 0 and health_result.stdout.strip().lower() == "healthy":
                health_responses += 1
                if healthy_since is None:
                    healthy_since = time.monotonic()
                    deadline = healthy_since + observe_seconds
        sample = {
            "index": len(samples),
            "elapsedSeconds": round(time.monotonic() - started, 2),
            "pod": pod_name,
            "phase": pod.get("status", {}).get("phase") if pod else None,
            "reason": pod.get("status", {}).get("reason") if pod else None,
            "cri": cri_usage,
            "podSummary": pod_usage,
            "health": health,
        }
        samples.append(sample)
        print(json.dumps({"snapshotter": directory.name, **sample}, sort_keys=True), flush=True)
        with (directory / "observations.jsonl").open("a") as stream:
            stream.write(json.dumps(sample, sort_keys=True) + "\n")
        if pod and pod.get("status", {}).get("phase") in {"Failed", "Succeeded"}:
            break
        time.sleep(5)
    events = command(
        directory,
        "events-final",
        kube_command(incus, project, "-n", "jellyfin", "get", "events", "-o", "json"),
        timeout=60,
        check=False,
    )
    try:
        event_items = json.loads(events.stdout).get("items", [])
    except json.JSONDecodeError:
        event_items = []
    evicted_pods.update(
        item.get("involvedObject", {}).get("name", "")
        for item in event_items
        if item.get("reason") == "Evicted"
    )
    evicted_pods.discard("")
    result = {
        "samples": samples,
        "sampleCount": len(samples),
        "healthResponses": health_responses,
        "evictedPods": sorted(evicted_pods),
        "lastPod": last_pod,
        "writableLayerSamples": [
            sample["cri"]["writableLayerBytes"]
            for sample in samples
            if sample["cri"]["present"]
        ],
        "ephemeralStorageSamples": [
            sample["podSummary"]["ephemeralStorageBytes"]
            for sample in samples
            if sample["podSummary"]["present"]
        ],
    }
    result["writableLayerMaxBytes"] = max(result["writableLayerSamples"], default=0)
    result["ephemeralStorageMaxBytes"] = max(result["ephemeralStorageSamples"], default=0)
    return result


def validate_overlay(observation: dict, rollout_status: int) -> None:
    if rollout_status != 0:
        raise ScenarioError("overlayfs Jellyfin Deployment rollout did not complete")
    if observation["healthResponses"] < 3:
        raise ScenarioError("overlayfs Jellyfin did not return Healthy at least three times")
    if observation["samples"][-1]["health"] != {"status": 0, "body": "Healthy"}:
        raise ScenarioError("overlayfs Jellyfin was not Healthy at the end of observation")
    if len(observation["writableLayerSamples"]) < 3 or observation["writableLayerMaxBytes"] <= 0:
        raise ScenarioError("overlayfs did not produce useful nonzero writable-layer samples")
    if not observation["ephemeralStorageSamples"]:
        raise ScenarioError("overlayfs produced no pod ephemeral-storage measurements")
    if observation["ephemeralStorageMaxBytes"] >= ONE_GIB:
        raise ScenarioError(
            f"overlayfs pod ephemeral usage reached {observation['ephemeralStorageMaxBytes']} bytes"
        )
    if observation["writableLayerMaxBytes"] >= ONE_GIB:
        raise ScenarioError(
            f"overlayfs writable-layer usage reached {observation['writableLayerMaxBytes']} bytes"
        )
    if observation["evictedPods"]:
        raise ScenarioError(f"overlayfs Jellyfin was evicted: {observation['evictedPods']}")


def cleanup_variant(
    incus: list[str], state: dict, directory: Path, started: float
) -> list[str]:
    errors: list[str] = []
    project = state["project"]
    commands: list[tuple[str, list[object], int]] = []
    if state.get("instanceCreated"):
        commands.append(("cleanup-instance", project_command(incus, project, "delete", "probe", "--force"), 120))
    if state.get("projectCreated"):
        commands.append(("cleanup-project", [*incus, "project", "delete", project, "--force"], 120))
    if state.get("poolCreated"):
        commands.append(("cleanup-pool", [*incus, "storage", "delete", state["pool"]], 120))
    if state.get("networkCreated"):
        commands.append(("cleanup-network", [*incus, "network", "delete", state["network"]], 120))
    for label, argv, timeout in commands:
        result = command(directory, label, argv, timeout=timeout, check=False)
        if result.returncode:
            errors.append(f"{label}: {result.stderr.strip() or result.stdout.strip()}")
    state["cleanupErrors"] = errors
    write_json(directory / "cleanup.json", {"commands": [name for name, _, _ in commands], "errors": errors})
    mark(directory.parent, started, "variant-cleanup", project=project, errors=errors)
    return errors


def run_variant(
    args: argparse.Namespace,
    incus: list[str],
    output: Path,
    started: float,
    snapshotter: str,
    bundle: Path,
) -> dict:
    suffix = os.urandom(4).hex()
    project = f"compute-storage-{snapshotter}-{suffix}"
    state = {
        "snapshotter": snapshotter,
        "bundle": str(bundle),
        "project": project,
        "pool": f"pool-{snapshotter}-{suffix}",
        "network": f"sp-{snapshotter}",
        "instance": "probe",
        "status": "failed",
        "projectCreated": False,
        "poolCreated": False,
        "networkCreated": False,
        "instanceCreated": False,
    }
    directory = output / snapshotter
    directory.mkdir(parents=True, exist_ok=False)
    variant_started = time.monotonic()
    try:
        if not bundle.is_dir():
            raise ScenarioError(f"guest bundle is not a directory: {bundle}")
        dataset = args.pool_root / snapshotter
        state["dataset"] = str(dataset)
        filesystem = command(directory, "backing-filesystem", ["findmnt", "-n", "-o", "FSTYPE,SOURCE,TARGET", str(dataset)])
        state["backingFilesystem"] = filesystem.stdout.strip()
        backing_fields = filesystem.stdout.split()
        if len(backing_fields) < 2 or backing_fields[0] != "zfs" or not backing_fields[1].startswith("compute-storage/"):
            raise ScenarioError(f"Incus pool source is not the disposable compute-storage ZFS dataset: {filesystem.stdout!r}")
        state["backingDataset"] = backing_fields[1]
        command(directory, "zfs-list-before", ["zfs", "list", "-H", "-o", "name,mountpoint,used,refer", backing_fields[1]])
        command(directory, "project-create", [*incus, "project", "create", project, "-c", "features.images=true", "-c", "features.profiles=true"])
        state["projectCreated"] = True
        command(
            directory,
            "pool-create",
            project_command(incus, project, "storage", "create", state["pool"], "dir", f"source={dataset}"),
        )
        state["poolCreated"] = True
        command(
            directory,
            "network-create",
            [
                *incus,
                "network",
                "create",
                state["network"],
                "ipv4.address=10.214.10.1/24" if snapshotter == "native" else "ipv4.address=10.214.11.1/24",
                "ipv4.nat=true",
                "ipv6.address=none",
            ],
        )
        state["networkCreated"] = True
        command(
            directory,
            "profile-root",
            project_command(incus, project, "profile", "device", "add", "default", "root", "disk", "path=/", f"pool={state['pool']}"),
        )
        command(
            directory,
            "profile-network",
            project_command(
                incus,
                project,
                "profile",
                "device",
                "add",
                "default",
                "eth0",
                "nic",
                "name=eth0",
                f"network={state['network']}",
            ),
        )
        mark(output, started, "image-import-start", snapshotter=snapshotter, project=project)
        command(
            directory,
            "image-import",
            project_command(incus, project, "image", "import", bundle / "metadata.tar.xz", bundle / "rootfs.tar.xz", "--alias", "probe"),
            timeout=900,
        )
        mark(output, started, "image-import-finished", snapshotter=snapshotter, project=project)
        command(
            directory,
            "instance-init",
            project_command(
                incus,
                project,
                "init",
                "probe",
                "probe",
                "-c",
                "security.nesting=true",
                "-c",
                "security.privileged=false",
                "-c",
                "security.idmap.isolated=true",
                "-c",
                "security.idmap.size=65536",
            ),
        )
        state["instanceCreated"] = True
        command(directory, "instance-start", project_command(incus, project, "start", "probe"), timeout=240)
        mark(output, started, "guest-started", snapshotter=snapshotter, project=project)
        wait_for_node(incus, project, directory, started)
        for deployment in ("coredns", "metrics-server"):
            command(
                directory,
                f"baseline-{deployment}-create",
                kube_command(incus, project, "-n", "kube-system", "wait", "--for=create", f"deployment/{deployment}", "--timeout=180s"),
                timeout=190,
            )
            command(
                directory,
                f"baseline-{deployment}-rollout",
                kube_command(incus, project, "-n", "kube-system", "rollout", "status", f"deployment/{deployment}", "--timeout=180s"),
                timeout=190,
            )
        command(directory, "k3s-version", guest_command(incus, project, "k3s", "--version"), check=False)
        command(directory, "guest-uid-map", guest_command(incus, project, "cat", "/proc/self/uid_map"), check=False)
        command(directory, "guest-gid-map", guest_command(incus, project, "cat", "/proc/self/gid_map"), check=False)
        command(directory, "guest-config", project_command(incus, project, "config", "show", "probe", "--expanded"), check=False)
        containerd = command(
            directory,
            "containerd-config",
            guest_command(incus, project, "cat", "/var/lib/rancher/k3s/agent/etc/containerd/config.toml"),
        )
        actual_snapshotter = configured_snapshotter(containerd.stdout)
        state["containerdSnapshotter"] = actual_snapshotter
        if actual_snapshotter != snapshotter:
            raise ScenarioError(f"guest containerd uses {actual_snapshotter}, expected {snapshotter}")
        architecture = command(directory, "guest-architecture", guest_command(incus, project, "uname", "-m")).stdout.strip()
        state["guestArchitecture"] = architecture
        if architecture not in {"x86_64", "amd64"}:
            raise ScenarioError(f"guest is not amd64: {architecture}")
        command(directory, "guest-kernel", guest_command(incus, project, "uname", "-a"), check=False)
        command(directory, "disk-before-image", guest_command(incus, project, "df", "-B1", "/var/lib/rancher/k3s/agent/containerd"), check=False)
        command(directory, "disk-before-image-du", guest_command(incus, project, "du", "-sx", "--block-size=1", f"/var/lib/rancher/k3s/agent/containerd/io.containerd.snapshotter.v1.{snapshotter}"), check=False)
        command(directory, "guest-fixture-dirs", guest_command(incus, project, "mkdir", "-p", "/var/tmp/storage-probe/config", "/srv/media/library"))
        command(directory, "guest-fixture-config", guest_command(incus, project, "install", "-d", "-o", "751", "-g", "751", "/var/tmp/storage-probe/config"))
        command(directory, "guest-fixture-media", guest_command(incus, project, "sh", "-c", "printf fixture > /srv/media/library/readme"))
        for manifest in sorted(args.manifests.glob("*.yaml")):
            command(
                directory,
                f"push-{manifest.stem}",
                project_command(incus, project, "file", "push", manifest, f"probe/var/tmp/storage-probe/{manifest.name}"),
            )
        deployment_path = "/var/tmp/storage-probe/Deployment-jellyfin.yaml"
        canonical = json_stdout(
            command(
                directory,
                "canonical-deployment",
                kube_command(incus, project, "create", "--dry-run=client", "--validate=false", "-f", deployment_path, "-o", "json"),
            )
        )
        write_json(directory / "canonical-deployment.json", canonical)
        image = canonical["spec"]["template"]["spec"]["containers"][0]["image"]
        state["image"] = image
        if not image.startswith("jellyfin/jellyfin:") or "@sha256:" not in image:
            raise ScenarioError(f"canonical Jellyfin image is not pinned: {image}")
        limits = copy.deepcopy(canonical["spec"]["template"]["spec"]["containers"])
        state["canonicalLimits"] = {
            container["name"]: container.get("resources", {}).get("limits", {}) for container in limits
        }
        if state["canonicalLimits"].get("main", {}).get("ephemeral-storage") != "1Gi":
            raise ScenarioError("canonical Jellyfin main container is not limited to unchanged 1Gi ephemeral storage")
        for resource in (
            "Namespace-jellyfin.yaml",
            "ConfigMap-jellyfin.yaml",
            "ServiceAccount-jellyfin.yaml",
            "Service-jellyfin.yaml",
        ):
            command(directory, f"apply-{resource}", kube_command(incus, project, "apply", "-f", f"/var/tmp/storage-probe/{resource}"))
        deployment = copy.deepcopy(canonical)
        for volume in deployment["spec"]["template"]["spec"].get("volumes", []):
            if volume.get("name") == "config":
                volume.pop("persistentVolumeClaim", None)
                volume["hostPath"] = {"path": "/var/tmp/storage-probe/config", "type": "Directory"}
        for container in deployment["spec"]["template"]["spec"]["containers"]:
            if container.get("resources", {}).get("limits", {}) != state["canonicalLimits"][container["name"]]:
                raise ScenarioError("fixture transformation changed canonical resource limits")
        write_json(directory / "fixture-deployment.json", deployment)
        pull = command(directory, "image-pull", guest_command(incus, project, "k3s", "crictl", "pull", image), timeout=900, check=False)
        state["imagePullStatus"] = pull.returncode
        command(directory, "disk-after-image", guest_command(incus, project, "df", "-B1", "/var/lib/rancher/k3s/agent/containerd"), check=False)
        command(directory, "disk-after-image-du", guest_command(incus, project, "du", "-sx", "--block-size=1", f"/var/lib/rancher/k3s/agent/containerd/io.containerd.snapshotter.v1.{snapshotter}"), check=False)
        deployment_result = command(directory, "deployment-apply", kube_command(incus, project, "apply", "-f", "-"), input_text=json.dumps(deployment), check=False)
        if deployment_result.returncode:
            raise ScenarioError(f"Jellyfin Deployment apply failed: {deployment_result.stderr.strip()}")
        state["deploymentCreated"] = True
        command(
            directory,
            "deployment-create",
            kube_command(incus, project, "-n", "jellyfin", "wait", "--for=create", "deployment/jellyfin", "--timeout=180s"),
            timeout=190,
        )
        observation = observe(incus, project, directory, started, args.observe_seconds)
        state["observation"] = observation
        write_json(directory / "observation.json", observation)
        rollout = command(
            directory,
            "deployment-rollout",
            kube_command(incus, project, "-n", "jellyfin", "rollout", "status", "deployment/jellyfin", "--timeout=10s"),
            timeout=20,
            check=False,
        )
        state["rolloutStatus"] = rollout.returncode
        if snapshotter == "overlayfs":
            validate_overlay(observation, rollout.returncode)
        state["status"] = "passed" if snapshotter == "overlayfs" else "measured"
        mark(output, started, "variant-observations-complete", snapshotter=snapshotter, project=project)
    except Exception as error:
        state["error"] = str(error)
        mark(output, started, "variant-failed", snapshotter=snapshotter, project=project, error=str(error))
    finally:
        if state.get("instanceCreated"):
            for label, argv in (
                ("final-incus-info", project_command(incus, project, "info", "probe", "--show-log")),
                ("final-k3s-journal", guest_command(incus, project, "journalctl", "-u", "k3s", "--no-pager", "-n", "300")),
                ("final-pods", kube_command(incus, project, "get", "pods", "-A", "-o", "yaml")),
                ("final-events", kube_command(incus, project, "get", "events", "-A", "-o", "yaml")),
                ("final-node", kube_command(incus, project, "get", "nodes", "-o", "yaml")),
            ):
                diagnostic = command(directory, label, argv, timeout=120, check=False)
                if state["status"] == "failed" or state.get("rolloutStatus"):
                    print(f"DIAGNOSTIC {snapshotter} {label}\n{diagnostic.stdout}\n{diagnostic.stderr}", flush=True)
        cleanup_variant(incus, state, directory, started)
        state["elapsedSeconds"] = round(time.monotonic() - variant_started, 2)
        if state["cleanupErrors"]:
            state["status"] = "failed"
        write_json(directory / "result.json", state)
    return state


def run_scenario(args: argparse.Namespace) -> int:
    if platform.node() != "fixture-host" or os.geteuid() != 0 or platform.machine() not in {"x86_64", "amd64"}:
        raise ScenarioError("run as root on the designated x86 fixture-host only")
    if args.observe_seconds < OBSERVATION_MINIMUM:
        raise ScenarioError(f"at least {OBSERVATION_MINIMUM}s of observation is required")
    if not args.native_bundle.is_dir() or not args.overlay_bundle.is_dir() or not args.manifests.is_dir():
        raise ScenarioError("guest bundles and canonical manifests must be existing directories")
    args.output.mkdir(parents=True, exist_ok=False)
    shutil.copy2(Path(__file__), args.output / "executed-driver.py")
    shutil.copytree(args.manifests, args.output / "canonical-manifests")
    lock = open("/run/compute-storage-zfs.lock", "w")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    started = time.monotonic()
    incus = [str(args.incus), "--force-local"]
    before_subuid = Path("/etc/subuid").read_bytes()
    before_subgid = Path("/etc/subgid").read_bytes()
    (args.output / "subuid-before.txt").write_bytes(before_subuid)
    (args.output / "subgid-before.txt").write_bytes(before_subgid)
    mark(args.output, started, "provenance", host=platform.node(), architecture=platform.machine(), bundleNative=str(args.native_bundle), bundleOverlay=str(args.overlay_bundle), manifests=str(args.manifests), observeSeconds=args.observe_seconds)
    command(args.output, "host-before-incus", [*incus, "list", "--all-projects", "--format=json"], check=False)
    command(args.output, "host-kernel", ["uname", "-a"], check=False)
    command(args.output, "host-kernel-release", ["uname", "-r"], check=False)
    command(args.output, "host-zfs-version", ["zfs", "version"], check=False)
    command(args.output, "host-zpool-status", ["zpool", "status"], check=False)
    command(args.output, "host-zfs-list", ["zfs", "list", "-H", "-o", "name,mountpoint,used,refer"], check=False)
    command(args.output, "host-filesystems", ["findmnt", "-R"], check=False)
    results = []
    try:
        results.append(run_variant(args, incus, args.output, started, "native", args.native_bundle))
        results.append(run_variant(args, incus, args.output, started, "overlayfs", args.overlay_bundle))
        write_json(args.output / "results.json", results)
        if results[0]["status"] != "measured":
            raise ScenarioError(f"native fixture did not complete measurements: {results[0].get('error', results[0]['cleanupErrors'])}")
        if results[-1]["status"] != "passed":
            raise ScenarioError("overlayfs did not satisfy the Jellyfin health, accounting, and eviction assertions")
        if results[-1].get("cleanupErrors"):
            raise ScenarioError(f"overlayfs cleanup failed: {results[-1]['cleanupErrors']}")
        mark(args.output, started, "observations-complete", nativeStatus=results[0]["status"], overlayStatus=results[1]["status"])
        return 0
    finally:
        command(args.output, "host-after-incus", [*incus, "list", "--all-projects", "--format=json"], check=False)
        command(args.output, "host-zfs-list-after", ["zfs", "list", "-H", "-o", "name,mountpoint,used,refer"], check=False)
        after_subuid = Path("/etc/subuid").read_bytes()
        after_subgid = Path("/etc/subgid").read_bytes()
        (args.output / "subuid-after.txt").write_bytes(after_subuid)
        (args.output / "subgid-after.txt").write_bytes(after_subgid)
        unchanged = after_subuid == before_subuid and after_subgid == before_subgid
        write_json(args.output / "cleanup-host.json", {"subordinateFilesUnchanged": unchanged})
        mark(args.output, started, "cleanup-complete", subordinateFilesUnchanged=unchanged)
        if not unchanged:
            raise ScenarioError("scenario changed /etc/subuid or /etc/subgid")


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        return run_scenario(args)
    except Exception as error:
        print(f"FAIL: {error}", flush=True)
        if args.output.exists():
            write_json(args.output / "failure.json", {"error": str(error)})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
