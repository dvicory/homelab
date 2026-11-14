"""Opt-in native x86_64 stock DT qualification; never use an existing cluster.

Admission: free public GitHub ubuntu-26.04, >=4 CPUs/16GiB nominal RAM,
>=10GiB currently available RAM, >=30GiB free disk, privileged local Docker.
No KVM. Images come from the rendered service, production policy enforcer and
monitoring Alertmanager, plus the source-selected K3s release. No host paths are mounted.
Only the fixed JSON receipt escapes the private temporary directory.
"""
import argparse
import hashlib
import http.client
import io
import json
import os
import pwd
import grp
import re
from pathlib import Path
import platform
import secrets
import selectors
import shutil
import signal
import stat
import sys
import subprocess
import tempfile
import tarfile
from datetime import datetime, timezone
import time
from types import SimpleNamespace
import urllib.parse
import ssl
import socket

from playwright.sync_api import sync_playwright
import uuid

import yaml
import dependency_track_sync as sync

REQUIRED_CHECKS = [
    "stock-bootstrap-restricted-role-and-scram",
    "exact-root-failure-notifier-uid705-refusal-and-independent-null-receiver-events",
    "exact-credential-projection-rotation-and-missing-key-refusal",
    "same-guest-root-broker-uid705-file-key-without-kubeconfig",
    "anonymous-and-invalid-key-refused-authenticated-project-created",
    "api-database-management-deny-exact-fixture-api-admission-then-deny",
    "real-producer-restricted-refresh-repeat-and-refusals-retain-last-good",
    "restore-phase-restart-retains-project-key-and-keyset",
    "offline-backup-destroy-restore-retains-auth-uuid-keyset-and-evidence",
    "retained-secret-ciphertext-cold-restore-same-id-wrong-key-refusal-and-exact-recovery",
    "restore-refuses-missing-keyset-and-privileged-role-then-recovers",
    "restore-refuses-malformed-nonempty-keyset-without-rewrite-then-recovers",
    "restore-refuses-missing-database-version-without-reinitializing",
    "native-root-access-policy-bootstrap-restore-and-pod-uid-readmission",
    "native-trusted-browser-public-pkce-admin-denial-logout-and-group-removal",
]

MALFORMED_KEYSET = b"fixture-malformed-nonempty-keyset\n"
STORAGE_CATEGORIES = ("archive", "acquisitions", "origins", "artifacts")
SAFE_ERROR_SIGNATURES = {
    "permission-denied": b"permission denied",
    "permission-error": b"permissionerror",
    "nix-daemon-denied": b"not allowed to connect to the nix daemon",
    "api-unauthorized": b"http 401",
    "api-forbidden": b"http 403",
    "source-policy-refused": b"trusted source policy",
    "producer-unavailable": b"no completed trusted producer run",
    "producer-plan-incompatible": b"unsupported or unbounded security plan",
    "producer-stale": b"stale or future-dated",
    "producer-declaration-absent": b"configured target ids are absent",
    "refresh-incomplete": b"refresh has missing or failed targets",
    "api-keyset-protobuf-invalid": b"invalidprotocolbufferexception",
    "api-keyset-json-invalid": b"jsonparseexception",
    "nix-build-refused": b"not permitted to build",
    "runner-capability-refused": b"operation not permitted",
    "api-keyset-crypto-invalid": b"generalsecurityexception",
    "api-keyset-authentication-invalid": b"aeadbadtagexception",
    "api-configuration-invalid": b"configexception",
    "out-of-memory": b"outofmemoryerror",
    "database-password-refused": b"password authentication failed",
    "connection-refused": b"connection refused",
    "dns-resolution-failed": b"could not resolve",
    "cri-cli-dispatch-refused": b"no help topic for 'crictl'",
}
SAFE_CONTAINER_REASONS = {
    "Completed", "Error", "OOMKilled", "CrashLoopBackOff", "ContainerCannotRun",
    "RunContainerError", "CreateContainerConfigError", "InvalidImageName", "ErrImagePull",
    "ImagePullBackOff", "ErrImageNeverPull", "CreateContainerError", "PodInitializing", "ContainerCreating",
    "StartError", "DeadlineExceeded", "Unschedulable", "Evicted", "Shutdown", "NodeLost",
}


class QualificationFailure(ValueError):
    """Only explicitly constructed fixture identifiers may enter public diagnostics."""

    def __init__(self, reason, *, operation="fixture-observation", exit_code=None):
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,95}", reason):
            raise ValueError("unsafe-qualification-reason")
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", operation):
            raise ValueError("unsafe-qualification-operation")
        self.reason = reason
        self.operation = operation
        self.exit_code = exit_code
        super().__init__(reason)


def safe_error_categories(data):
    lowered = data.lower()
    return [category for category, signature in SAFE_ERROR_SIGNATURES.items() if signature in lowered]


def retained_tree(root):
    result = {}
    for path in [root, *sorted(root.rglob("*"))]:
        info = path.lstat()
        if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
            raise QualificationFailure("retained-evidence-is-not-regular")
        digest = None
        if stat.S_ISREG(info.st_mode):
            with path.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
        result[str(path.relative_to(root))] = [
            info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), digest]
    return result


def extract_retained_tree(archive, root):
    if os.geteuid() != 0 or root.is_symlink() or not root.is_dir() or any(root.iterdir()):
        raise QualificationFailure("retained-extraction-requires-root-and-empty-directory")
    with tarfile.open(archive, "r:") as source:
        members = source.getmembers()
        paths = [Path(member.name) for member in members]
        if (len(members) > 8192 or len(set(paths)) != len(paths)
                or sum(member.size for member in members) > 256 * 1024 * 1024
                or any(path.is_absolute() or ".." in path.parts for path in paths)
                or any(not (member.isdir() or member.isreg()) or member.mode & 0o7022
                       for member in members)):
            raise QualificationFailure("unsafe-retained-evidence-archive")
        source.extractall(root, members=members, numeric_owner=True, filter="tar")


def safe_failure(error, phase):
    if isinstance(error, QualificationFailure):
        result = {"phase": phase, "operation": error.operation, "reason": error.reason}
        if type(error.exit_code) is int:
            result["exitCode"] = error.exit_code
        return result
    if isinstance(error, sync.ApiError):
        return {"phase": phase, "operation": "stock-api-query", "reason": "api-http-refused",
                "httpStatus": error.status}
    reason = "unclassified-exception"
    for kind, category in ((json.JSONDecodeError, "invalid-json"), (KeyError, "field-missing"),
                           (TypeError, "field-type"), (AttributeError, "field-type"),
                           (RecursionError, "depth-limit"), (OSError, "file-or-process-access"),
                           (ValueError, "field-value"), (subprocess.TimeoutExpired, "command-timeout")):
        if isinstance(error, kind):
            reason = category
            break
    result = {"phase": phase, "operation": "fixture-observation", "reason": reason,
              "exceptionType": type(error).__name__}
    trace = error.__traceback__
    while trace is not None:
        if trace.tb_frame.f_code.co_filename == __file__:
            result["origin"] = {"line": trace.tb_lineno, "function": trace.tb_frame.f_code.co_name}
        trace = trace.tb_next
    return result


def image_refs(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "image":
                if not isinstance(child, str) or "@sha256:" not in child:
                    raise ValueError("unpinned-image")
                yield child
            else:
                yield from image_refs(child)
    elif isinstance(value, list):
        for child in value:
            yield from image_refs(child)


def source_inputs(settings):
    paths = [Path(settings[key]) for key in ("bootstrap", "restore", "retained", "identityInitial")]
    paths += sorted(Path(settings["networkPolicy"]).glob("*.yaml"))
    digest = hashlib.sha256()
    objects = []
    for path in paths:
        raw = path.read_bytes()
        digest.update(len(raw).to_bytes(8, "big"))
        digest.update(raw)
        objects.extend(yaml.safe_load_all(raw))
    for raw in (Path(settings["credentialStage"]).read_bytes(), Path(settings["brokerPortGuard"]).read_bytes(),
                Path(settings["failureNotifier"]).read_bytes(),
                Path(settings["accessPolicy"]).read_bytes(),
                Path(settings["accessBroker"]).read_bytes(),
                json.dumps([settings["identityDesired"], settings["provisionImage"],
                            settings["provisionImageDrv"], settings["chromium"]], sort_keys=True).encode(),
                json.dumps([settings["sync"], settings["qualificationTargets"], settings["failureHost"],
                            settings["alertmanager"]], sort_keys=True).encode()):
        digest.update(len(raw).to_bytes(8, "big"))
        digest.update(raw)
    return digest.hexdigest(), set(image_refs(objects)) | set(image_refs({"image": settings["alertmanager"]["image"]}))


def failure_labels(settings, event_id):
    return {"alertname": "DependencyTrackInventoryRefreshFailed", "source": "systemd",
            "namespace": "dependency-track", "severity": "warning",
            "host": settings["failureHost"], "event_id": event_id}


def validate_report(report, settings, producer_branch="main"):
    """Offline verification of bounded native witnesses against this app's source."""
    section = "identity-and-completeness"
    def require(condition):
        if not condition:
            raise QualificationFailure("report-" + section, operation="report-validation")

    require(isinstance(report, dict) and report.get("status") == "passed" and "failure" not in report)
    require(report.get("scenario") == "dependency-track-stock-recovery")
    require(report.get("architecture") == settings["system"] == "x86_64-linux")
    require(bool(re.fullmatch(r"homelab-dt-[0-9a-f]{32}", report.get("fixture", ""))))
    require(report.get("checks") == REQUIRED_CHECKS and len(set(report["checks"])) == len(REQUIRED_CHECKS))
    digest, images = source_inputs(settings)
    require(report.get("sourceDigest") == digest)
    section = "image-architecture-and-source-version"
    node = report.get("k3sImage", {})
    require(node.get("tag") == settings["image"])
    require(bool(re.fullmatch(r"rancher/k3s@sha256:[0-9a-f]{64}", node.get("reference", ""))))
    require(bool(re.fullmatch(r"sha256:[0-9a-f]{64}", node.get("configDigest", ""))))
    expected_images = sorted(images | {node["reference"]})
    require(report.get("images") == expected_images)
    require(report.get("imageArchitectures") == {image: "amd64" for image in expected_images})
    runtime_digests = report.get("runtimeManifestDigests", {})
    require(set(runtime_digests) == images)
    for image, digests in runtime_digests.items():
        require(isinstance(digests, list) and all(
            isinstance(value, str) and bool(re.fullmatch(r"sha256:[0-9a-f]{64}", value)) for value in digests))
        require(image.rsplit("@", 1)[1] in digests)
    versions = report.get("versions", {})
    require(set(versions) == {"server", "embeddedClient", "sourceClient"})
    require(all(value == "v" + settings["k3sVersion"] for value in versions.values()))
    require(report.get("k3sVersion") == settings["k3sVersion"])
    section = "runner-admission"
    host = report.get("host", {})
    require(host.get("architecture") in ("x86_64", "amd64") and host.get("ubuntu") == "26.04")
    for key, minimum in (("cpus", 4), ("totalMemoryBytes", 14 * 1024**3),
                         ("availableMemoryBytes", 10 * 1024**3), ("freeDiskBytes", 30 * 1024**3)):
        require(type(host.get(key)) is int and host[key] >= minimum)
    observed = report.get("observed", {})
    section = "authentication-boundaries"
    authentication = observed.get("authentication", {})
    for name in ("anonymous", "invalidKey", "oldDefault"):
        code = authentication.get(name)
        require(type(code) is int and code in (401, 403))
    code = authentication.get("adminLogin")
    require(type(code) is int and 200 <= code < 300)
    section = "database-role-restrictions"
    require(observed.get("roleSafe") == "t" and observed.get("superuserPasswordDisabled") == "t")
    require(observed.get("forbiddenSqlStates") == ["42501"] * 3)
    for key, expected in (("invalidDatabasePasswordExit", 2), ("uid", 705), ("kubeconfigReadExit", 1),
                          ("cliUid", 705), ("cliKubeconfigReadExit", 1), ("brokerPort", 1022)):
        require(type(observed.get(key)) is int and observed[key] == expected)
    require(observed.get("cliGroups") == [705] and all(type(group) is int for group in observed["cliGroups"]))
    section = "state-and-credential-retention"
    for key in ("keyFileMatches", "projectUuidValid", "restartProjectMatches", "restartKeysetMatches",
                "backupDestroyedAndRestored", "restoreProjectMatches", "restoreKeysetMatches",
                "canonicalEvidenceMatches", "missingKeysetUnchanged", "missingPostgresUnchanged",
                "refreshRetainedAcrossRestart", "refreshRetainedAcrossBackupRestore"):
        require(observed.get(key) is True)
    section = "retained-secret-ciphertext-recovery"
    ciphertext = observed.get("retainedCiphertext", {})
    require(type(ciphertext.get("createStatus")) is int and ciphertext["createStatus"] == 201)
    for name in ("beforeBackup", "afterColdRestore", "afterOriginalKeyRestore"):
        consumer = ciphertext.get(name, {})
        require(type(consumer.get("status")) is int and consumer["status"] == 200)
        require(consumer.get("connection") == "SKIPPED")
        require(consumer.get("referenceExists") is True and consumer.get("recordUnchanged") is True)
    wrong = ciphertext.get("validWrongKey", {})
    for field in ("keyIdsUnchanged", "keyMaterialChanged", "wrongBytesUnchanged", "podReady",
                  "authenticatedProjectMatches", "referenceExists", "recordUnchanged"):
        require(wrong.get(field) is True)
    for field in ("initGuardExit", "startupProbeExit", "readinessProbeExit"):
        require(type(wrong.get(field)) is int and wrong[field] == 0)
    require(type(wrong.get("apiVersionStatus")) is int and wrong["apiVersionStatus"] == 200)
    require(type(wrong.get("status")) is int and 500 <= wrong["status"] < 600)
    require(ciphertext.get("exactOriginalBytesRestored") is True)
    require(ciphertext.get("authenticatedProjectRecovered") is True)
    section = "malformed-nonempty-keyset-restore"
    malformed = observed.get("malformedKeyset", {})
    require(malformed.get("nonemptyGuardExit") == 0 and type(malformed.get("nonemptyGuardExit")) is int)
    require(malformed.get("initGuardExit") == 0 and type(malformed.get("initGuardExit")) is int)
    require(malformed.get("applicationRunning") is True and malformed.get("podReady") is False)
    require(malformed.get("cryptoInitializationRejected") is True)
    require(malformed.get("startupProbeFailureObserved") is True)
    for field in ("managementStartedExit", "managementReadyExit"):
        require(type(malformed.get(field)) is int and malformed[field] == 0)
    for field in ("apiVersionExit", "startupProbeExit", "readinessProbeExit"):
        require(type(malformed.get(field)) is int and 0 < malformed[field] < 126)
    require(malformed.get("corruptBytesUnchanged") is True and malformed.get("originalRestored") is True)
    require(malformed.get("authenticatedProjectRecovered") is True)
    section = "network-separation"
    require(observed.get("network") == {
        "default": "connection-refused", "admitted": "http-unauthorized",
        "management": "connection-refused", "removed": "connection-refused", "databaseExit": 2,
    })
    require(type(observed["network"]["databaseExit"]) is int)
    section = "restore-container-refusals"
    refused = observed.get("refusedExits", {})
    require(set(refused) == {"require-restored-api-keyset", "require-restricted-database-role", "postgres"})
    require(all(type(code) is int and 0 < code < 256 for code in refused.values()))
    section = "reserved-port-boundary"
    require(observed.get("hostPortBoundaryUnchanged") is True)
    boundary = observed.get("guestPortBoundary", {})
    require(boundary == {"value": 1024} and type(boundary["value"]) is int)
    guard = observed.get("reservedPortGuard", {})
    require(guard.get("script") == settings["brokerPortGuard"])
    require(type(guard.get("unreservedExit")) is int and 0 < guard["unreservedExit"] < 256)
    require(type(guard.get("reservedExit")) is int and guard["reservedExit"] == 0)
    require(observed.get("ingestorPermissions") == ["BOM_UPLOAD", "PORTFOLIO_MANAGEMENT", "VIEW_PORTFOLIO"])
    require(type(observed.get("restrictedAdminStatus")) is int and observed["restrictedAdminStatus"] in (401, 403))
    projection = observed.get("credentialProjection", {})
    section = "credential-projection"
    require(projection.get("script") == settings["credentialStage"])
    require(projection.get("rotatedApiKey") is True and projection.get("rotatedGithubToken") is True)
    require(type(projection.get("missingKeyExit")) is int and 0 < projection["missingKeyExit"] < 256)
    require(projection.get("lastGoodPreserved") is True)
    for generation in ("first", "second"):
        native = projection.get(generation, {})
        require(native.get("valuesMatched") is True and native.get("modes") == [0o400, 0o400])
        require(native.get("owners") == [0, 0] and type(native.get("uid705ReadExit")) is int and native["uid705ReadExit"] != 0)
        require(all(type(value) is int for value in native["modes"] + native["owners"]))
    section = "root-failure-notification"
    notification = observed.get("failureNotification", {})
    require(type(notification.get("uid705Exit")) is int and 0 < notification["uid705Exit"] < 256)
    require(notification.get("uid705CreatedNoEvents") is True)
    require(notification.get("rootExits") == [0, 0]
            and all(type(code) is int for code in notification["rootExits"]))
    require(notification.get("privateRuntime") is True and notification.get("annotationsSafe") is True)
    require(notification.get("proxyProcessesRemoved") is True and notification.get("runtimeRemoved") is True)
    require(notification.get("resources") == settings["alertmanager"]["resources"])
    events = notification.get("events", [])
    groups = notification.get("groups", [])
    require(isinstance(events, list) and len(events) == 2 and isinstance(groups, list) and len(groups) == 2)
    event_ids = []
    for labels in events:
        require(isinstance(labels, dict))
        event_id = labels.get("event_id", "")
        require(isinstance(event_id, str) and bool(re.fullmatch(
            r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", event_id)))
        require(labels == failure_labels(settings, event_id))
        event_ids.append(event_id)
    require(len(set(event_ids)) == 2)
    for group in groups:
        require(isinstance(group, dict) and set(group) == {"labels", "receiver", "eventIds"})
        require(group["receiver"] == settings["alertmanager"]["eventRoute"]["receiver"])
        require(isinstance(group["eventIds"], list) and len(group["eventIds"]) == 1)
        require(group["labels"] == {"alertname": "DependencyTrackInventoryRefreshFailed",
                                    "event_id": group["eventIds"][0]})
    require(sorted(group["eventIds"][0] for group in groups) == sorted(event_ids))
    refresh = report.get("refresh", {})
    section = "producer-refresh-policy"
    require(refresh.get("executable") == settings["sync"])
    require(refresh.get("repository") == settings["repository"] == "dvicory/homelab")
    require(refresh.get("branch") == producer_branch)
    require(refresh.get("mainProducerQualified") is (producer_branch == "main"))
    require(refresh.get("deployment") == "unobserved")
    for key in ("firstExitCode", "repeatExitCode", "recoveryExitCode", "postRestoreExitCode"):
        require(type(refresh.get(key)) is int and refresh[key] == 0)
    wanted = {target["id"]: target for target in settings["qualificationTargets"].values()}
    snapshots = [refresh.get(key, {}) for key in ("first", "repeat", "recovered", "postRestore")]
    require(refresh.get("repeatStorageGrowthBytes") == {
        category: snapshots[1]["storage"][category]["bytes"] - snapshots[0]["storage"][category]["bytes"]
        for category in STORAGE_CATEGORIES
    })
    require(all(type(value) is int for value in refresh["repeatStorageGrowthBytes"].values()))
    require(snapshots[0]["storage"]["artifacts"] == snapshots[1]["storage"]["artifacts"])
    first = snapshots[0]
    require(type(refresh.get("pinnedRun")) is int and refresh["pinnedRun"] == first.get("producer", {}).get("run"))
    for snapshot in snapshots:
        require(bool(re.fullmatch(r"[0-9a-f]{64}", snapshot.get("stableIdentity", ""))))
        require(snapshot.get("stableIdentity") == first.get("stableIdentity"))
        require(snapshot.get("refreshStatus") == "complete")
        require(type(snapshot.get("expectedCount")) is int and snapshot["expectedCount"] >= 2)
        require(type(snapshot.get("excludedCount")) is int and snapshot["excludedCount"] == snapshot["expectedCount"] - 2)
        producer = snapshot.get("producer", {})
        require(producer == first.get("producer"))
        require(producer.get("repository") == settings["repository"] and producer.get("branch") == producer_branch)
        require(bool(re.fullmatch(r"[0-9a-f]{40}", producer.get("sha", ""))))
        require(type(producer.get("run")) is int and producer["run"] > 0)
        require(producer.get("workflow") == sync.security_artifacts.WORKFLOW)
        require(producer.get("event") in sync.security_artifacts.EVENTS)
        completed = datetime.fromisoformat(producer["completedAt"].replace("Z", "+00:00"))
        observed_at = datetime.fromisoformat(snapshot["observedAt"])
        require(completed.tzinfo is not None and observed_at.tzinfo is not None)
        require(0 <= (observed_at - completed).total_seconds() <= 604800)
        section = "retained-storage-measurements"
        storage = snapshot.get("storage", {})
        require(set(storage) == set(STORAGE_CATEGORIES))
        for category in storage.values():
            require(set(category) == {"files", "bytes"})
            require(all(type(value) is int and value >= 0 for value in category.values()))
        require(storage["artifacts"]["files"] >= 3 and storage["artifacts"]["bytes"] > 0)
        section = "refresh-target-identity-and-coverage"
        targets = snapshot.get("targets", {})
        require(set(targets) == set(wanted) and targets == first.get("targets"))
        all_projects = []
        for declaration_id, declaration in wanted.items():
            target = targets[declaration_id]
            require(target.get("declaration") == declaration)
            projects = target.get("projectUuids", {})
            streams = {"native", "language"} if declaration["kind"] == "nix" else {"image"}
            require(streams <= set(projects))
            all_projects += [target.get("collectionUuid"), *projects.values()]
            require(set(target.get("componentCounts", {})) == set(projects))
            require(set(target.get("componentIdentityDigests", {})) == set(projects))
            for stream in projects:
                count = target["componentCounts"][stream]
                require(type(count) is int and count >= (1 if stream in ("native", "image") else 0))
                require(bool(re.fullmatch(r"[0-9a-f]{64}", target["componentIdentityDigests"][stream])))
            revision = target.get("softwareRevision")
            require(isinstance(revision, list) and len(revision) == 2 and all(isinstance(value, str) for value in revision))
            require(sync.identity(revision) == target.get("revisionId"))
            if declaration["kind"] == "nix":
                sync.security_artifacts.store_paths(revision)
                require(revision[0].endswith(".drv") and not revision[1].endswith(".drv"))
            else:
                require(bool(re.fullmatch(r"[^\s@]+@sha256:[0-9a-f]{64}", revision[0])))
                require(revision[1] == declaration["ociPlatform"])
            for key in ("revisionId", "currentIdentity", "historyIdentity", "originalSealSha256"):
                require(bool(re.fullmatch(r"[0-9a-f]{64}", target.get(key, ""))))
            require(type(target.get("historyCount")) is int and target["historyCount"] >= 0)
            seals = target.get("receiptSeals", [])
            require(isinstance(seals, list) and len(seals) > 0 and len(set(seals)) == len(seals))
            require(all(isinstance(seal, str) and re.fullmatch(r"[0-9a-f]{64}", seal) for seal in seals))
            require(target["originalSealSha256"] in seals)
            require(bool(re.fullmatch(r"[0-9a-f]{24}", target.get("inventoryKey", ""))))
            require(bool(re.fullmatch(r"[0-9a-f]{40}", target.get("originalSourceRevision", ""))))
            require(target.get("requestedByRevision") == producer["sha"])
            require(bool(re.fullmatch(r"sha256:[0-9a-f]{64}", target.get("artifactDigest", ""))))
            require(type(target.get("artifactId")) is int and target["artifactId"] > 0)
            require(type(target.get("retainedFileCount")) is int and target["retainedFileCount"] >= (8 if declaration["kind"] == "nix" else 2))
            require(target.get("originalProducer") == {
                "GITHUB_REPOSITORY": settings["repository"],
                "GITHUB_WORKFLOW_REF": settings["repository"] + "/" + producer["workflow"] + "@refs/heads/" + producer_branch,
                "GITHUB_REF": "refs/heads/" + producer_branch, "GITHUB_EVENT_NAME": producer["event"], "GITHUB_SHA": producer["sha"],
            })
            origin = target.get("origin")
            if declaration["kind"] == "nix":
                require(isinstance(origin, dict) and origin.get("sourceRevision") == producer["sha"])
                require(origin.get("inventoryKey") == target["inventoryKey"] and origin.get("completeCoverage") is False)
                for key in ("reportSha256", "bomSha256"):
                    require(bool(re.fullmatch(r"[0-9a-f]{64}", origin.get(key, ""))))
                counts = origin.get("counts", {})
                require(all(type(value) is int and value >= 0 for value in counts.values()))
                require(counts.get("origins", 0) > 0 and counts.get("tracedOrigins", 0) > 0 and counts.get("matchedComponents", 0) > 0)
                require(counts.get("matchedComponents", 0) + counts.get("unknownComponents", 0) == counts.get("components"))
            else:
                require(origin is None)
        require(len(set(all_projects)) == len(all_projects))
        require(all(isinstance(project, str) and str(uuid.UUID(project)) == project for project in all_projects))
    negatives = refresh.get("negatives", [])
    require([item.get("reason") for item in negatives] == ["source-policy", "stale-producer", "absent-target"])
    for negative in negatives:
        require(type(negative.get("exitCode")) is int and 0 < negative["exitCode"] < 256)
        require(negative.get("lastGoodPreserved") is True)
        require(negative.get("coverageStatus") == ("complete" if negative["reason"] == "source-policy" else "failed-unknown"))
    section = "native-access-policy"
    policy = observed.get("accessPolicy", {})
    for key in ("beforeAdmissionGateway", "freshRestoreGateway", "badBootstrapCredentialGateway",
                "badRestoreCredentialGateway", "recreatedPodGateway"):
        require(type(policy.get(key)) is int and policy[key] in (502, 503, 504))
    require(policy.get("admittedGateway") == 401 and type(policy["admittedGateway"]) is int)
    require(policy.get("defaultLoginRefusal") == "INVALID_CREDENTIALS")
    require(policy.get("healthyReconciliationPreserved") is True
            and policy.get("successAndFailureSessionLogout") is True)
    bindings = policy.get("alternatePrivilegedBindings", {})
    require(isinstance(bindings, dict) and set(bindings) == {
        "ACCESS_MANAGEMENT", "ACCESS_MANAGEMENT_CREATE", "ACCESS_MANAGEMENT_UPDATE"})
    require(all(type(status) is int and status in (502, 503, 504) for status in bindings.values()))
    for key in ("uid705PolicyExit", "uid705BrokerReadExit"):
        require(type(policy.get(key)) is int and 0 < policy[key] < 256)
    for key in ("bootstrapPodUID", "previousPodUID", "recreatedPodUID", "validatedPodUID", "finalPodUID"):
        require(isinstance(policy.get(key), str) and str(uuid.UUID(policy[key])) == policy[key])
    require(policy["bootstrapPodUID"] != policy["recreatedPodUID"])
    require(policy["previousPodUID"] != policy["recreatedPodUID"] and policy.get("finalPodAdmitted") is True)
    require(policy["recreatedPodUID"] == policy["validatedPodUID"])
    section = "native-browser-oidc"
    oidc = observed.get("nativeOidc", {})
    require(observed.get("frontendReadOnlyRoot") is True and observed.get("frontendReadOnlyConfig") is True)
    require(oidc.get("pkceCallback") is True)
    for key, status in (("administratorStatus", 200), ("localLogoutStatus", 401),
                        ("unmappedStatus", 403), ("nonmemberStatus", 403),
                        ("existingSessionAfterGroupRemoval", 200), ("removedGroupReloginStatus", 403),
                        ("afterNegativeRecoveryStatus", 200)):
        require(type(oidc.get(key)) is int and oidc[key] == status)
    for key in ("wrongAudienceStatus", "wrongIssuerStatus"):
        require(type(oidc.get(key)) is int and oidc[key] in (401, 403))
    permissions = oidc.get("administratorPermissions", [])
    require(isinstance(permissions, list) and permissions == sorted(set(permissions))
            and {"ACCESS_MANAGEMENT", "SYSTEM_CONFIGURATION", "VIEW_PORTFOLIO"} <= set(permissions)
            and all(isinstance(permission, str) and re.fullmatch(r"[A-Z_]+", permission)
                    for permission in permissions))
    helper = observed.get("fixtureHelper", {})
    require(helper.get("productionReceipt") is False
            and helper.get("sourceArchive") == settings["provisionImage"]
            and helper.get("producerDrv") == settings["provisionImageDrv"])
    require(isinstance(helper.get("configDigest"), str)
            and bool(re.fullmatch(r"sha256:[0-9a-f]{64}", helper["configDigest"]))
            and helper["configDigest"] == helper.get("runtimeConfigDigest"))
    require(isinstance(helper.get("archiveSha256"), str)
            and bool(re.fullmatch(r"[0-9a-f]{64}", helper["archiveSha256"])))
    section = "cleanup-and-safe-operation-evidence"
    operations = report.get("operations", [])
    require(isinstance(operations, list) and 0 < len(operations) <= 24)
    for operation in operations:
        require(set(operation) == {"phase", "operation", "exitCode", "errorCategories"})
        require(bool(re.fullmatch(r"[a-z][a-z0-9-]{0,63}", operation["operation"])))
        require(bool(re.fullmatch(r"[a-z][a-z0-9-]{0,63}", operation["phase"])))
        require(type(operation["exitCode"]) is int and -255 <= operation["exitCode"] < 256)
        require(isinstance(operation["errorCategories"], list)
                and len(operation["errorCategories"]) == len(set(operation["errorCategories"]))
                and set(operation["errorCategories"]) <= set(SAFE_ERROR_SIGNATURES))
    require(report.get("cleanup") is True)
    cleanup = report.get("cleanupWitness", {})
    require(set(cleanup) == {"containerRemoved", "networkRemoved", "volumesRemoved", "credentialsRemoved",
                             "identityRemoved", "failureProxyRemoved", "alertmanagerRemoved",
                             "nativeProcessesRemoved"})
    require(all(value is True for value in cleanup.values()))



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--settings", required=True, type=Path)
    parser.add_argument("--docker-context")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--check-report", type=Path)
    parser.add_argument("--admit-disposable-github-runner", action="store_true")
    parser.add_argument("--producer-branch", default="main")
    parser.add_argument("--github-token-file", type=Path)
    args = parser.parse_args()
    settings = json.loads(args.settings.read_text())
    if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_./-]*", args.producer_branch)
            or ".." in args.producer_branch or "//" in args.producer_branch):
        parser.error("Requires an explicit trusted producer branch")
    if args.check_report:
        try:
            if args.report or args.admit_disposable_github_runner or args.docker_context or args.github_token_file:
                raise QualificationFailure("report-mode-only", operation="report-validation")
            if args.check_report.stat().st_size > 65536:
                raise QualificationFailure("report-size-limit", operation="report-validation")
            validate_report(json.loads(args.check_report.read_text()), settings, args.producer_branch)
        except (OSError, ValueError, TypeError, KeyError, AttributeError, RecursionError) as error:
            print(json.dumps({"status": "refused", **safe_failure(error, "report-validation")}, sort_keys=True))
            return 1
        print("Dependency-Track report accepted")
        return 0
    if not args.report or not args.docker_context:
        parser.error("Runtime requires --report and --docker-context")
    if os.geteuid() != 0:
        parser.error("The admitted fixture requires root-owned private Kubernetes credentials")
    if not args.github_token_file:
        parser.error("Runtime requires a CI-supplied read-only --github-token-file")
    args.github_token_file = args.github_token_file.absolute()
    credential_info = args.github_token_file.lstat()
    if (not stat.S_ISREG(credential_info.st_mode) or credential_info.st_mode & 0o077
            or not 0 < credential_info.st_size <= 65536):
        parser.error("CI token must be a private bounded regular file")
    # An explicit flag is not a bypass for local/shared/production runtimes.
    if not (args.admit_disposable_github_runner and os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
            and os.environ.get("RUNNER_OS") == "Linux" and os.environ.get("RUNNER_ARCH") == "X64"
            and platform.machine().lower() in ("x86_64", "amd64")):
        parser.error("Requires an admitted disposable GitHub-hosted native x86_64 runner")
    release = dict(line.split("=", 1) for line in Path("/etc/os-release").read_text().splitlines() if "=" in line)
    if release.get("ID", "").strip('"') != "ubuntu" or release.get("VERSION_ID", "").strip('"') != "26.04":
        parser.error("Requires the admitted ubuntu-26.04 image")
    meminfo = {line.split(":")[0]: int(line.split()[1]) * 1024 for line in Path("/proc/meminfo").read_text().splitlines()}
    if len(os.sched_getaffinity(0)) < 4 or meminfo["MemTotal"] < 14 * 1024**3 or meminfo["MemAvailable"] < 10 * 1024**3:
        parser.error("Requires >=4 available CPUs, 16GiB nominal RAM and >=10GiB currently available RAM")
    if shutil.disk_usage(tempfile.gettempdir()).free < 30 * 1024**3:
        parser.error("Requires >=30GiB free temporary disk")
    credential_directory = Path("/run/dependency-track-sync-credentials")
    staged_directory = Path("/srv/secrets")
    if any(os.path.lexists(path) for path in (credential_directory, staged_directory)):
        parser.error("Fixture refuses pre-existing credential/staging paths")
    for lookup in (pwd.getpwuid, grp.getgrgid):
        try:
            lookup(705)
        except KeyError:
            pass
        else:
            parser.error("Fixture refuses an existing UID or GID705")
    os.umask(0o077)
    receipt = {"scenario": "dependency-track-stock-recovery", "architecture": "x86_64-linux",
               "status": "failed", "checks": [], "cleanup": False,
               "limitations": ["Isolated service with two public desired/reference inventories; not deployed or production recovery proof",
                               "Offline same-node PostgreSQL18 physical backup, not PITR or cross-version restore",
                               "No advisory bulk import, fleet sizing or production credential enrollment",
                               "Fixture-only API ingress overlay proves packet enforcement, not an admitted fleet route",
                               "Local PV capacities are declarations, not filesystem quotas; tiny fixture does not prove production disk sizing"]}
    receipt["limitations"].append("Exact projection/getter/rotation and705 transport only; envelope reconciler and systemd lifecycle are not executed")
    receipt["limitations"].append("Storage counts are logical regular-file bytes per retained path, not physical allocation or a capacity proof")
    receipt["limitations"].append("Exact root notifier with null receivers only; no systemd sandbox/lifecycle or provider delivery proof")
    receipt["limitations"].append("Disposable source-built helper is not a verified production helper release or release-authority bypass")
    receipt["limitations"].append("Native trusted fixture HTTPS only; no production Gateway, enrollment, instantaneous IdP revocation or systemd lifecycle claim")
    receipt["limitations"].append("Wrong issuer uses another real client's discovery/keys; refusal does not isolate issuer versus signature validation order")
    receipt["limitations"].append("One synthetic retained managed SECRET consumed by disabled stock email test; no SMTP, all-secret or production readiness claim")
    receipt.update(sourceDigest=source_inputs(settings)[0], http=[], observed={"forbiddenSqlStates": [], "refusedExits": {}},
                   cleanupWitness={"containerRemoved": False, "networkRemoved": False, "volumesRemoved": False, "credentialsRemoved": False},
                   host={"architecture": platform.machine().lower(), "ubuntu": release["VERSION_ID"].strip('"'),
                         "cpus": len(os.sched_getaffinity(0)), "totalMemoryBytes": meminfo["MemTotal"],
                         "availableMemoryBytes": meminfo["MemAvailable"],
                         "freeDiskBytes": shutil.disk_usage(tempfile.gettempdir()).free})
    observed = receipt["observed"]
    output = args.report.open("x", encoding="utf-8")
    os.chmod(args.report, 0o644)
    token = uuid.uuid4().hex
    name = "homelab-dt-" + token
    account_name = "homelab-dt-" + token[:12]
    receipt["fixture"] = name
    network = name + "-network"
    phase = "transport"
    forward = None
    host_forward = None
    host_api_port = None
    created = False
    network_created = False
    owned_host_paths = []
    account_user_owned = False
    account_group_owned = False
    ingestor_temporary = None
    notifier_groups = set()
    alertmanager_created = False
    oidc_processes = []
    policy_initialized = False
    notification_canary = uuid.uuid4().hex
    host_port_boundary = int(Path("/proc/sys/net/ipv4/ip_unprivileged_port_start").read_text())
    success = False
    with tempfile.TemporaryDirectory(prefix="homelab-dt-") as directory:
        work = Path(directory)
        work.chmod(0o700)
        (work / "docker").mkdir(mode=0o700)
        (work / "tmp").mkdir(mode=0o700)
        env = {"PATH": os.defpath, "HOME": str(work), "LANG": "C.UTF-8",
               "DOCKER_CONFIG": str(work / "docker"), "TMPDIR": str(work / "tmp"),
               "NIX_CONFIG": "experimental-features = nix-command flakes\naccept-flake-config = false\nallow-import-from-derivation = false\nbuilders = "}
        docker = [settings["docker"]]

        def run(command, *, data=None, timeout=60, check=True, user=None, environment=None, operation=None):
            if operation is None:
                operation = {
                    settings["credentialStage"]: "credential-projection",
                    settings["brokerPortGuard"]: "reserved-port-guard",
                    settings["failureNotifier"]: "root-failure-notification",
                    settings["sync"]: "inventory-refresh",
                    settings["kubectl"]: "kubernetes-command",
                    settings["unshare"]: "isolated-network-namespace",
                    settings["nsenter"]: "owned-node-network-namespace",
                    settings["useradd"]: "create-fixture-user",
                    settings["groupadd"]: "create-fixture-group",
                    settings["userdel"]: "remove-fixture-user",
                    settings["groupdel"]: "remove-fixture-group",
                    settings["id"]: "fixture-identity",
                    settings["cat"]: "credential-read-boundary",
                }.get(command[0], "host-command")
            try:
                if user is None:
                    result = subprocess.run(command, input=data, capture_output=True,
                                            env=env if environment is None else environment, timeout=timeout)
                else:
                    process = subprocess.Popen(command, stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,
                                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                               env=env if environment is None else environment,
                                               user=user, group=user, extra_groups=[], start_new_session=True)
                    try:
                        stdout, stderr = process.communicate(data, timeout=timeout)
                    except BaseException:
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        process.communicate()
                        raise
                    result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
            except subprocess.TimeoutExpired:
                raise QualificationFailure("command-timeout", operation=operation) from None
            except OSError as error:
                reason = {
                    2: "executable-missing", 13: "command-permission-denied", 24: "open-file-limit",
                    28: "disk-full", 30: "read-only-filesystem",
                }.get(error.errno, "command-launch-failed")
                raise QualificationFailure(reason, operation=operation) from None
            history = receipt.setdefault("operations", [])
            history.append({"phase": phase, "operation": operation, "exitCode": result.returncode,
                            "errorCategories": safe_error_categories(result.stderr[:1024 * 1024])})
            del history[:-24]
            if len(result.stdout) + len(result.stderr) > 1024 * 1024:
                raise QualificationFailure("response-size-limit", operation=operation, exit_code=result.returncode)
            if check and result.returncode:
                raise QualificationFailure("command-failed", operation=operation, exit_code=result.returncode)
            return result

        def d(*command, **kw):
            verb = command[0] if command and command[0] in {
                "context", "info", "pull", "image", "network", "create", "start", "inspect",
                "exec", "cp", "rm", "volume",
            } else "command"
            kw.setdefault("operation", "docker-" + verb)
            return run([*docker, *command], **kw)

        def resource_absent(kind, identity):
            listing = d(kind, "ls", *(["--all"] if kind == "container" else []),
                        "--format", "{{.Names}}" if kind == "container" else "{{.Name}}", check=False)
            return listing.returncode == 0 and identity.encode() not in listing.stdout.splitlines()

        def k(*command, **kw):
            verb = next((part for part in command if part in {
                "apply", "get", "wait", "scale", "rollout", "exec", "patch", "delete", "logs", "version",
            }), "command")
            kw.setdefault("operation", "kubernetes-" + verb)
            if "KUBECONFIG" in env:
                return run([settings["kubectl"], "--context", name, "--request-timeout=15s", *command], **kw)
            return d("exec", "-i", name, "kubectl", "--kubeconfig", "/etc/rancher/k3s/k3s.yaml",
                     "--request-timeout=15s", *command, **kw)

        def apply(objects):
            return k("apply", "-f", "-", data=json.dumps(objects).encode())

        def native(*command, **kw):
            verb = command[0] if command and command[0] in {
                "cat", "test", "mv", "cp", "sh", "tar", "mkdir", "rm", "chmod", "chown", "id", "stat",
            } else "command"
            kw.setdefault("operation", "node-" + verb)
            return d("exec", name, *command, **kw)

        def wait(predicate, seconds=180, *, reason="convergence-timeout"):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if predicate():
                    return
                time.sleep(2)
            raise QualificationFailure(reason)

        def deployment(component, replicas):
            k("-n", "dependency-track", "scale", "deployment/dependency-track-" + component,
              "--replicas=" + str(replicas))
            if replicas:
                if component == "api":
                    wait(lambda: api_pod_ready(), seconds=620, reason="api-container-not-ready")
                    if policy_initialized:
                        reconcile_access()
                else:
                    k("-n", "dependency-track", "rollout", "status", "deployment/dependency-track-" + component,
                      "--timeout=600s", timeout=620)
            else:
                k("-n", "dependency-track", "wait", "--for=delete", "pod",
                  "-l", "app.kubernetes.io/name=dependency-track-" + component,
                  "--timeout=120s", timeout=140)

        def pg(sql, *, application=False, check=True):
            command = 'exec psql -XAt -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -U postgres -d dtrack'
            if application:
                command = 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -XAt -h 127.0.0.1 -U dtrack -d dtrack -v ON_ERROR_STOP=1 -v VERBOSITY=verbose'
            return k("-n", "dependency-track", "exec", "-i", "deployment/dependency-track-postgres", "--",
                     "/bin/sh", "-ec", command, data=sql.encode(), check=check, operation="postgresql-query")

        def check(label):
            receipt["checks"].append(label)

        def capture_failure_diagnostics():
            """Read only this owned fixture; never publish messages, logs, arguments or bodies."""
            diagnostics = {"pods": [], "collectionErrors": []}
            receipt["diagnostics"] = diagnostics
            if not created:
                return
            try:
                inspected = d("inspect", name, check=False, timeout=20)
                if inspected.returncode:
                    diagnostics["collectionErrors"].append({
                        "operation": "docker-inspect", "reason": "command-failed", "exitCode": inspected.returncode,
                    })
                    return
                node = json.loads(inspected.stdout)[0]
                if node.get("Config", {}).get("Labels", {}).get("verification.homelab/fixture") != token:
                    diagnostics["collectionErrors"].append({"operation": "docker-inspect", "reason": "ownership-refused"})
                    return
                state = node.get("State", {})
                diagnostics["node"] = {
                    "state": state.get("Status") if state.get("Status") in {
                        "created", "running", "paused", "restarting", "removing", "exited", "dead",
                    } else "unknown",
                    "oomKilled": state.get("OOMKilled") is True,
                    "exitCode": state.get("ExitCode") if type(state.get("ExitCode")) is int else None,
                    "errorCategories": safe_error_categories(str(state.get("Error", "")).encode()),
                }
                if not state.get("Running"):
                    return
                response = k("get", "pods", "--all-namespaces", "-o", "json", check=False, timeout=20)
                if response.returncode:
                    diagnostics["collectionErrors"].append({
                        "operation": "kubernetes-get", "reason": "command-failed", "exitCode": response.returncode,
                    })
                    return
                source_objects = json.loads(Path(settings["bootstrap"]).read_text())["items"]
                source_objects += [yaml.safe_load(path.read_text()) for path in sorted(Path(settings["networkPolicy"]).glob("*.yaml"))]
                source_objects += alertmanager_objects()
                allowed_containers = {"coredns", "client"}
                allowed_workloads = {"kube-dns"}
                for resource in source_objects:
                    if resource.get("kind") not in {"Deployment", "DaemonSet"}:
                        continue
                    allowed_workloads.add(resource["metadata"]["name"])
                    spec = resource.get("spec", {}).get("template", {}).get("spec", {})
                    allowed_containers.update(container["name"] for container in
                                              spec.get("containers", []) + spec.get("initContainers", []))
                for pod in json.loads(response.stdout).get("items", [])[:24]:
                    metadata = pod.get("metadata", {})
                    labels = metadata.get("labels", {})
                    workload = next((value for value in labels.values() if value in allowed_workloads), None)
                    if workload is None:
                        continue
                    status = pod.get("status", {})
                    summary = {
                        "workload": workload,
                        "phase": status.get("phase") if status.get("phase") in {
                            "Pending", "Running", "Succeeded", "Failed", "Unknown",
                        } else "Unknown",
                        "containers": [],
                    }
                    diagnostics["pods"].append(summary)
                    for container in (status.get("initContainerStatuses", []) + status.get("containerStatuses", []))[:12]:
                        if container.get("name") not in allowed_containers:
                            continue
                        item = {"name": container["name"], "ready": container.get("ready") is True,
                                "restartCount": container.get("restartCount") if type(container.get("restartCount")) is int else None}
                        summary["containers"].append(item)
                        for field in ("state", "lastState"):
                            for kind in ("waiting", "running", "terminated"):
                                value = container.get(field, {}).get(kind)
                                if value is None:
                                    continue
                                item[field] = {"kind": kind}
                                if value.get("reason") in SAFE_CONTAINER_REASONS:
                                    item[field]["reason"] = value["reason"]
                                for key in ("exitCode", "signal"):
                                    if type(value.get(key)) is int:
                                        item[field][key] = value[key]
                    if metadata.get("namespace") == "dependency-track" and workload == "dependency-track-api":
                        logs = k("-n", "dependency-track", "logs", metadata["name"], "-c", "api",
                                 "--tail=80", "--limit-bytes=32768", check=False, timeout=20)
                        summary["apiErrorCategories"] = safe_error_categories(logs.stdout[:32768])
            except Exception as error:
                diagnostics["collectionErrors"].append(safe_failure(error, "diagnostic-collection"))

        def stop_host_forward():
            nonlocal host_forward
            if host_forward is not None:
                host_forward.terminate()
                try:
                    host_forward.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    host_forward.kill()
                    host_forward.wait(timeout=10)
                host_forward.stdout.close()
                host_forward = None

        def start_host_forward():
            nonlocal host_forward, host_api_port
            stop_host_forward()
            binding = (str(host_api_port) if host_api_port else "") + ":8080"
            host_forward = subprocess.Popen([
                settings["kubectl"], "--context", name, "-n", "dependency-track", "port-forward",
                "--address=127.0.0.1", "service/dependency-track-api", binding,
            ], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
            with selectors.DefaultSelector() as selector:
                selector.register(host_forward.stdout, selectors.EVENT_READ)
                if not selector.select(30):
                    raise QualificationFailure("host-port-forward-unavailable")
                match = re.fullmatch(rb"Forwarding from 127\.0\.0\.1:([0-9]+) -> 8080\n", host_forward.stdout.readline(1024))
                if not match:
                    raise QualificationFailure("host-port-forward-unavailable")
                port = int(match[1])
                if host_api_port is not None and port != host_api_port:
                    raise QualificationFailure("host-port-forward-origin-changed")
                host_api_port = port

        def stop_forward():
            nonlocal forward
            stop_host_forward()
            if forward is not None:
                if forward.poll() is None:
                    native("sh", "-ec", 'test ! -s /run/fixture-dt-broker.pid || kill -TERM "$(cat /run/fixture-dt-broker.pid)"', check=False)
                forward.terminate()
                try:
                    forward.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    forward.kill()
                    forward.wait(timeout=10)
                forward.stdout.close()
                forward = None

        def start_forward():
            nonlocal forward
            stop_forward()
            run([settings["nsenter"], "--target", str(node["State"]["Pid"]), "--net", "--", settings["brokerPortGuard"]])
            # The production transport: root owns the fixed same-guest broker;
            # UID705 gets localhost HTTP, never its Kubernetes credential.
            command = (
                "echo $$ > /run/fixture-dt-broker.pid; "
                "exec kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "
                "--namespace dependency-track port-forward --address 127.0.0.1 "
                "service/dependency-track-api 1022:8080"
            )
            forward = subprocess.Popen([*docker, "exec", name, "sh", "-ec", command],
                                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
            with selectors.DefaultSelector() as selector:
                selector.register(forward.stdout, selectors.EVENT_READ)
                if not selector.select(30):
                    raise QualificationFailure("port-forward-unavailable")
                if forward.stdout.readline(1024) != b"Forwarding from 127.0.0.1:1022 -> 8080\n":
                    raise QualificationFailure("port-forward-unavailable")
                observed["brokerPort"] = 1022
            if host_api_port is not None:
                start_host_forward()

        def api(path, *, method="GET", body=None, bearer=None, key=None, form=False, expected=None, record=True):
            headers = {"Host": "localhost", "Connection": "close"}
            if bearer:
                headers["Authorization"] = "Bearer " + bearer
            if key:
                headers["X-Api-Key"] = key
            payload = b""
            if body is not None:
                payload = (urllib.parse.urlencode(body) if form else json.dumps(body)).encode()
                headers["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
            headers["Content-Length"] = str(len(payload))
            request = (method + " /api" + path + " HTTP/1.1\r\n" +
                       "\r\n".join(k + ": " + v for k, v in headers.items()) + "\r\n\r\n").encode() + payload
            # Disposable importer identity can reach the same-guest broker,
            # without a host port, kubeconfig mount or network-policy exemption.
            raw = run([
                settings["nsenter"], "--target", str(node["State"]["Pid"]), "--net", "--",
                sys.executable, "-I", "-c",
                "import os,socket,sys; os.setgroups([]); os.setgid(705); os.setuid(705)\n"
                "with socket.create_connection(('127.0.0.1',1022),timeout=15) as connection:\n"
                " connection.sendall(sys.stdin.buffer.read())\n"
                " while block := connection.recv(65536): sys.stdout.buffer.write(block)\n",
            ], data=request, operation="uid705-same-guest-http").stdout
            with http.client.HTTPResponse(SimpleNamespace(makefile=lambda mode: io.BytesIO(raw))) as response:
                response.begin()
                observed["lastHttpStatus"] = response.status
                accepted = 200 <= response.status < 300 if expected is None else response.status in expected
                if record or not accepted:
                    route = re.sub(r"/[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}(?=/|$)", "/{uuid}", path)
                    if record:
                        receipt["http"].append([method, route, response.status])
                    if not accepted:
                        receipt["httpFailure"] = {"method": method, "route": route, "status": response.status}
                if not accepted:
                    raise QualificationFailure("unexpected-http-status")
                return response.read(1024 * 1024)

        def pod_ip(component):
            pods = json.loads(k("-n", "dependency-track", "get", "pod", "-l",
                                "app.kubernetes.io/name=dependency-track-" + component, "-o", "json").stdout)
            if len(pods["items"]) != 1:
                raise QualificationFailure("unexpected-pod-population")
            return pods["items"][0]["status"]["podIP"]

        def api_pod():
            pods = json.loads(k("-n", "dependency-track", "get", "pod", "-l",
                                "app.kubernetes.io/name=dependency-track-api", "-o", "json").stdout)["items"]
            pods = [pod for pod in pods if not pod["metadata"].get("deletionTimestamp")]
            return pods[0] if len(pods) == 1 else None

        def api_pod_ready():
            pod = api_pod()
            desired = json.loads(k("-n", "dependency-track", "get",
                                   "deployment/dependency-track-api", "-o", "json").stdout)
            return bool(pod and pod.get("status", {}).get("phase") == "Running"
                        and pod["status"].get("containerStatuses")
                        and pod["spec"]["containers"][0].get("env", [])
                            == desired["spec"]["template"]["spec"]["containers"][0].get("env", [])
                        and all(container["ready"] for container in pod["status"]["containerStatuses"]))

        def admitted():
            pod = api_pod()
            return bool(pod and any(condition["type"] == "security.homelab/access-policy-ready"
                                    and condition["status"] == "True"
                                    for condition in pod.get("status", {}).get("conditions", [])))

        def reconcile_access(*, succeeds=True):
            was_forwarding = forward is not None
            stop_forward()
            runtime = work / "access-policy"
            runtime.mkdir(mode=0o700, exist_ok=True)
            policy_env = {**env, "KUBECONFIG": str(work / "policy-kubeconfig"),
                          "RUNTIME_DIRECTORY": str(runtime)}
            broker = subprocess.Popen([settings["nsenter"], "--target", str(node["State"]["Pid"]),
                "--net", "--", settings["accessBroker"]], stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, env={**policy_env,
                    "RUNTIME_DIRECTORY": "/run/dependency-track-sync-api-tunnel"}, start_new_session=True)
            oidc_processes.append(broker)
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(broker.stdout, selectors.EVENT_READ)
                    if not selector.select(60) or broker.stdout.readline(1024) != b"Forwarding from 127.0.0.1:1022 -> 8080\n":
                        raise QualificationFailure("source-broker-identity-unavailable")
                result = run([settings["nsenter"], "--target", str(node["State"]["Pid"]), "--net", "--",
                              settings["accessPolicy"]], timeout=180, check=False,
                             environment=policy_env, operation="root-access-policy")
                if (result.returncode == 0) != succeeds:
                    raise QualificationFailure("access-policy-unexpected-result")
                wait(lambda: admitted() == succeeds, reason="access-policy-gate-mismatch")
                return result
            finally:
                if broker.poll() is None:
                    os.killpg(broker.pid, signal.SIGTERM)
                try:
                    broker.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(broker.pid, signal.SIGKILL)
                    broker.wait(timeout=10)
                broker.stdout.close()
                if was_forwarding:
                    start_forward()

        def endpoints_ready():
            slices = json.loads(k("-n", "dependency-track", "get", "endpointslices",
                                  "-l", "kubernetes.io/service-name=dependency-track-api", "-o", "json").stdout)
            return any(endpoint.get("conditions", {}).get("ready") is True
                       for item in slices["items"] for endpoint in item.get("endpoints", []))

        def trusted_https(host, path, *, method="GET", data=None, headers=None):
            trust = ssl.create_default_context(cafile=str(work / "oidc" / "ca.crt"))
            connection = http.client.HTTPSConnection(host, context=trust, timeout=20)
            connection.sock = trust.wrap_socket(socket.create_connection(("127.0.0.1", 443), timeout=20),
                                                server_hostname=host)
            try:
                connection.request(method, path, body=data, headers=headers or {})
                response = connection.getresponse()
                return response.status, response.read(1024 * 1024), response.getheaders()
            finally:
                connection.close()

        def gateway_closed():
            wait(lambda: not endpoints_ready(), reason="unadmitted-endpoint-published")
            status, _, _ = trusted_https("api.dt-fixture.invalid", "/api/v1/project")
            if status not in (502, 503, 504):
                raise QualificationFailure("unadmitted-gateway-accessible")
            return status

        def policy_phase(bootstrap_phase):
            # Mutate only the source-owned desired phase, never a learned command or URL.
            k("-n", "dependency-track", "patch", "configmap/dependency-track-access-policy",
              "--type=merge", "--patch-file=/dev/stdin", data=json.dumps({"data": {"policy.json":
              json.dumps({"schema": 1, "bootstrap": bootstrap_phase,
                          "oidcGroup": settings["oidcGroup"]})}}).encode())

        def oidc_setup():
            """Existing native gateway fixture conventions: own CA, stock Kanidm,
            source desired state and genuine public wrapper; no production images forged."""
            ca = work / "oidc"
            ca.mkdir(mode=0o700)
            run([settings["openssl"], "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                 "-days", "2", "-subj", "/CN=DT fixture CA", "-addext",
                 "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                 "-keyout", str(ca / "ca.key"), "-out", str(ca / "ca.crt")])
            run([settings["openssl"], "req", "-new", "-newkey", "rsa:2048", "-nodes",
                 "-subj", "/CN=idm.dt-fixture.invalid", "-keyout", str(ca / "tls.key"),
                 "-out", str(ca / "tls.csr")])
            (ca / "tls.ext").write_text("subjectAltName=DNS:idm.dt-fixture.invalid,DNS:dt.dt-fixture.invalid,DNS:api.dt-fixture.invalid\nextendedKeyUsage=serverAuth\n")
            run([settings["openssl"], "x509", "-req", "-in", str(ca / "tls.csr"),
                 "-CA", str(ca / "ca.crt"), "-CAkey", str(ca / "ca.key"), "-CAcreateserial",
                 "-days", "2", "-extfile", str(ca / "tls.ext"), "-out", str(ca / "tls.crt")])
            for namespace in ("identity", "gateway"):
                apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": namespace}})
                apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"namespace": namespace,
                       "name": "kanidm-tls"}, "stringData": {
                       "tls.crt": (ca / "tls.crt").read_text(), "tls.key": (ca / "tls.key").read_text()}})
                apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"namespace": namespace,
                       "name": "fixture-ca"}, "data": {"ca.crt": (ca / "ca.crt").read_text()}})
            initial = json.loads(Path(settings["identityInitial"]).read_text())
            for obj in initial["items"]:
                if obj["kind"] == "Deployment":
                    spec = obj["spec"]["template"]["spec"]
                    spec["securityContext"]["fsGroup"] = 1000
                    spec["volumes"] = [{"name": "data", "emptyDir": {}} if volume["name"] == "data"
                                       else volume for volume in spec["volumes"]]
            apply(initial)
            k("-n", "identity", "rollout", "status", "deployment/kanidm", "--timeout=300s", timeout=320)
            # The production rewrite mechanism with only the reserved fixture issuer.
            apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"namespace": "kube-system",
                   "name": "coredns-custom"}, "data": {"kanidm.override":
                   "rewrite name exact idm.dt-fixture.invalid kanidm.identity.svc.cluster.local\n"}})
            k("-n", "kube-system", "rollout", "restart", "deployment/coredns")
            k("-n", "kube-system", "rollout", "status", "deployment/coredns", "--timeout=120s", timeout=140)
            recovered = json.loads(k("-n", "identity", "exec", "deployment/kanidm", "--",
                "/sbin/kanidmd", "scripting", "recover-account", "idm_admin", "-c",
                "/etc/kanidm/server.toml").stdout)
            if recovered.get("status") != "ok":
                raise QualificationFailure("fixture-idm-recovery-refused")
            apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"namespace": "identity",
                   "name": "kanidm-provision"}, "stringData": {"idm-admin-password": recovered["output"]}})
            desired = settings["identityDesired"]
            state = json.loads(desired["state.json"])
            # Public source registration only; no confidential app secret publication
            # or real fleet identities in this disposable qualification population.
            client = state["systems"]["oauth2"]["dependency-track"]
            state["systems"]["oauth2"] = {"dependency-track": client}
            state["systems"]["oauth2"]["fixture-wrong-issuer"] = {
                **client, "displayName": "Fixture issuer rejection"}
            state["persons"] = {"fixture-administrator": {"displayName": "Fixture administrator",
                                 "mailAddresses": ["administrator@dt-fixture.invalid"]},
                                "fixture-nonmember": {"displayName": "Fixture nonmember",
                                 "mailAddresses": ["nonmember@dt-fixture.invalid"]}}
            fixture_clients = [entry for entry in json.loads(desired["clients.json"])
                               if entry["name"] == "dependency-track"]
            fixture_clients.append({**fixture_clients[0], "name": "fixture-wrong-issuer"})
            fixture_desired = {**desired, "state.json": json.dumps(state),
                "members.json": json.dumps(["fixture-administrator"]),
                "clients.json": json.dumps(fixture_clients)}
            apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"namespace": "identity",
                   "name": "kanidm-provision"}, "data": fixture_desired})
            # The local image is genuine derivation output, never assigned a fake
            # production receipt/digest. Record and verify its actual config identity.
            with tarfile.open(settings["provisionImage"]) as archive:
                manifest = json.load(archive.extractfile("manifest.json"))
                if len(manifest) != 1 or settings["provisionImageRef"] not in manifest[0]["RepoTags"]:
                    raise QualificationFailure("fixture-helper-archive-reference-mismatch")
                config_bytes = archive.extractfile(manifest[0]["Config"]).read()
                helper_digest = "sha256:" + hashlib.sha256(config_bytes).hexdigest()
                if json.loads(config_bytes)["architecture"] != "amd64":
                    raise QualificationFailure("fixture-helper-architecture-mismatch")
            with Path(settings["provisionImage"]).open("rb") as archive:
                archive_digest = hashlib.file_digest(archive, "sha256").hexdigest()
            d("cp", settings["provisionImage"], name + ":/run/fixture-helper.tar", timeout=600)
            native("/bin/ctr", "--address", "/run/k3s/containerd/containerd.sock",
                   "--namespace", "k8s.io", "images", "import", "/run/fixture-helper.tar", timeout=600)
            apply({"apiVersion": "batch/v1", "kind": "Job", "metadata": {"namespace": "identity",
                   "name": "fixture-public-provision"}, "spec": {"backoffLimit": 0, "template": {
                   "metadata": {"labels": {"app.kubernetes.io/name": "kanidm-provision"}},
                   "spec": {"restartPolicy": "Never", "automountServiceAccountToken": False,
                   "securityContext": {"runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000},
                   "containers": [{"name": "provision", "image": settings["provisionImageRef"],
                   "imagePullPolicy": "Never", "env": [
                       {"name": "KANIDM_URL", "value": "https://idm.dt-fixture.invalid"},
                       {"name": "KANIDM_ADMIN_GROUP", "value": settings["oidcGroup"]},
                       {"name": "HOME", "value": "/work"},
                       {"name": "TMPDIR", "value": "/work"},
                       {"name": "SSL_CERT_FILE", "value": "/fixture-ca/ca.crt"}],
                   "volumeMounts": [{"name": mount, "mountPath": path, "readOnly": mount != "work"}
                       for mount, path in (("desired", "/desired"), ("credentials", "/credentials"),
                                           ("work", "/work"), ("fixture-ca", "/fixture-ca"))]}],
                   "volumes": [{"name": "desired", "configMap": {"name": "kanidm-provision"}},
                       {"name": "credentials", "secret": {"secretName": "kanidm-provision"}},
                       {"name": "work", "emptyDir": {"medium": "Memory"}},
                       {"name": "fixture-ca", "configMap": {"name": "fixture-ca"}}]}}}})
            k("-n", "identity", "wait", "--for=condition=Complete", "job/fixture-public-provision",
              "--timeout=600s", timeout=620)
            helpers = json.loads(k("-n", "identity", "get", "pods", "-l",
                "job-name=fixture-public-provision", "-o", "json").stdout)["items"]
            if len(helpers) != 1:
                raise QualificationFailure("fixture-helper-execution-population")
            execution = helpers[0]["status"]["containerStatuses"][0]
            actual_helper = json.loads(native("/bin/crictl",
                "--runtime-endpoint=unix:///run/k3s/containerd/containerd.sock",
                "--image-endpoint=unix:///run/k3s/containerd/containerd.sock",
                "inspecti", "-o", "json", execution["imageID"]).stdout)["status"]["id"]
            if actual_helper != helper_digest or execution["state"]["terminated"]["exitCode"] != 0:
                raise QualificationFailure("fixture-helper-runtime-config-mismatch")
            observed["fixtureHelper"] = {"configDigest": helper_digest, "runtimeConfigDigest": actual_helper,
                "archiveSha256": archive_digest, "sourceArchive": settings["provisionImage"],
                "producerDrv": settings["provisionImageDrv"],
                "productionReceipt": False}
            # Trust only this fixture CA in Java and Chromium, never disable TLS.
            run([settings["keytool"], "-importcert", "-noprompt", "-alias", "fixture",
                 "-file", str(ca / "ca.crt"), "-keystore", str(ca / "truststore"),
                 "-storepass", "fixture-trust-only"])
            import base64
            apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"namespace": "dependency-track",
                   "name": "fixture-java-trust"}, "data": {"truststore":
                   base64.b64encode((ca / "truststore").read_bytes()).decode()}})
            nss = work / ".pki" / "nssdb"
            nss.mkdir(mode=0o700, parents=True)
            run([settings["certutil"], "-N", "--empty-password", "-d", "sql:" + str(nss)])
            run([settings["certutil"], "-A", "-d", "sql:" + str(nss), "-n", "fixture",
                 "-t", "C,,", "-i", str(ca / "ca.crt")])
            frontend_image = next(obj["spec"]["template"]["spec"]["containers"][0]["image"]
                for obj in bootstrap["items"] if obj["kind"] == "Deployment"
                and obj["metadata"]["name"] == "dependency-track-frontend")
            servers = []
            for host, backend in (("dt", "http://dependency-track-frontend.dependency-track.svc:8080"),
                                  ("api", "http://dependency-track-api.dependency-track.svc:8080"),
                                  ("idm", "https://kanidm.identity.svc:443")):
                servers.append("server { listen 8443 ssl; server_name " + host +
                    ".dt-fixture.invalid; ssl_certificate /tls/tls.crt; ssl_certificate_key /tls/tls.key; "
                    "location / { proxy_pass " + backend + "; proxy_set_header Host $host; proxy_connect_timeout 2s; "
                    "proxy_ssl_verify on; proxy_ssl_trusted_certificate /ca/ca.crt; "
                    "proxy_ssl_server_name on; proxy_ssl_name idm.dt-fixture.invalid; }}")
            apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"namespace": "gateway",
                   "name": "fixture-gateway"}, "data": {"nginx.conf":
                   "pid /tmp/nginx.pid; events {} http { access_log off; "
                   "client_body_temp_path /tmp/client_temp; proxy_temp_path /tmp/proxy_temp; "
                   + "".join(servers) + "}"}})
            apply({"apiVersion": "v1", "kind": "Pod", "metadata": {"namespace": "gateway",
                   "name": "fixture-gateway", "labels": {"gateway.envoyproxy.io/owning-gateway-name": "household",
                       "gateway.envoyproxy.io/owning-gateway-namespace": "gateway"}},
                   "spec": {"automountServiceAccountToken": False, "containers": [{"name": "gateway",
                   "image": frontend_image, "command": ["/usr/sbin/nginx", "-c", "/fixture/nginx.conf",
                   "-g", "daemon off;"], "volumeMounts": [
                       {"name": mount, "mountPath": path, "readOnly": True}
                       for mount, path in (("config", "/fixture"), ("tls", "/tls"), ("ca", "/ca"))]}],
                   "volumes": [{"name": "config", "configMap": {"name": "fixture-gateway"}},
                               {"name": "tls", "secret": {"secretName": "kanidm-tls"}},
                               {"name": "ca", "configMap": {"name": "fixture-ca"}}]}})
            k("-n", "gateway", "wait", "--for=condition=Ready", "pod/fixture-gateway", "--timeout=120s", timeout=140)
            with socket.socket() as reserved:
                reserved.bind(("127.0.0.1", 443))
            process = subprocess.Popen([settings["kubectl"], "--context", name, "-n", "gateway",
                "port-forward", "--address=127.0.0.1", "pod/fixture-gateway", "443:8443"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
            oidc_processes.append(process)
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                if not selector.select(30) or process.stdout.readline(1024) != b"Forwarding from 127.0.0.1:443 -> 8443\n":
                    raise QualificationFailure("fixture-https-forward-unavailable")
            return recovered["output"]

        def private_restore():
            objects = json.loads(Path(settings["restore"]).read_text())
            for obj in objects["items"]:
                if obj["kind"] == "Deployment" and obj["metadata"]["name"] == "dependency-track-api":
                    spec = obj["spec"]["template"]["spec"]
                    spec["volumes"].append({"name": "fixture-trust",
                                            "secret": {"secretName": "fixture-java-trust"}})
                    container = spec["containers"][0]
                    container["volumeMounts"].append({"name": "fixture-trust", "mountPath": "/fixture-trust",
                                                     "readOnly": True})
                    next(entry for entry in container["env"] if entry["name"] == "EXTRA_JAVA_OPTIONS")["value"] += (
                        " -Djavax.net.ssl.trustStore=/fixture-trust/truststore"
                        " -Djavax.net.ssl.trustStorePassword=fixture-trust-only")
            return objects

        def qualify_browser(recovery_password, admin_bearer):
            idm, ui = "https://idm.dt-fixture.invalid", "https://dt.dt-fixture.invalid"
            proof, captured = {}, {}

            def idm_api(method, path, body=None, bearer=None, session=None, expected=200):
                headers = {"Content-Type": "application/json"}
                if bearer:
                    headers["Authorization"] = "Bearer " + bearer
                if session:
                    headers["X-KANIDM-AUTH-SESSION-ID"] = session
                status, raw, returned = trusted_https("idm.dt-fixture.invalid", path, method=method,
                    data=None if body is None else json.dumps(body).encode(), headers=headers)
                if status != expected:
                    raise QualificationFailure("native-idm-api-unexpected-status")
                return (json.loads(raw) if raw else None,
                        next((value for key, value in returned
                              if key.lower() == "x-kanidm-auth-session-id"), session))

            _, session = idm_api("POST", "/v1/auth", {"step": {"init": "idm_admin"}})
            _, session = idm_api("POST", "/v1/auth", {"step": {"begin": "password"}}, session=session)
            state, _ = idm_api("POST", "/v1/auth",
                              {"step": {"cred": {"password": recovery_password}}}, session=session)
            idm_admin = state["state"]["success"]

            def credential(page, challenge, create):
                return page.evaluate("""async ({challenge, create}) => {
                  const publicKey = create
                    ? PublicKeyCredential.parseCreationOptionsFromJSON(challenge.publicKey)
                    : PublicKeyCredential.parseRequestOptionsFromJSON(challenge.publicKey);
                  return (create ? await navigator.credentials.create({publicKey})
                                 : await navigator.credentials.get({publicKey})).toJSON();
                }""", {"challenge": challenge, "create": create})

            def enroll(page, person):
                intent, _ = idm_api("GET", f"/v1/person/{person}/_credential/_update_intent/600",
                                    bearer=idm_admin)
                update, _ = idm_api("POST", "/v1/credential/_exchange_intent", intent["token"])
                session_token, _ = update
                status, _ = idm_api("POST", "/v1/credential/_update", ["passkeyinit", session_token])
                registration = credential(page, status["mfaregstate"]["Passkey"], True)
                status, _ = idm_api("POST", "/v1/credential/_update",
                    [{"passkeyfinish": ["Fixture verified passkey", registration]}, session_token])
                if not status["can_commit"] or status["warnings"]:
                    raise QualificationFailure("fixture-passkey-not-committable")
                idm_api("POST", "/v1/credential/_commit", session_token)

            def native_login(page, person):
                state, session = idm_api("POST", "/v1/auth", {"step": {"init": person}})
                if "passkey" not in state["state"]["choose"]:
                    raise QualificationFailure("fixture-native-passkey-absent")
                state, session = idm_api("POST", "/v1/auth", {"step": {"begin": "passkey"}}, session=session)
                challenge = next(item["passkey"] for item in state["state"]["continue"] if "passkey" in item)
                assertion = credential(page, challenge, False)
                state, _ = idm_api("POST", "/v1/auth", {"step": {"cred": {"passkey": assertion}}}, session=session)
                token = state["state"]["success"]
                identity, _ = idm_api("GET", "/v1/self", bearer=token)
                if identity["youare"]["attrs"]["name"] != [person]:
                    raise QualificationFailure("fixture-native-actor-mismatch")
                return token

            def observe(request):
                parsed = urllib.parse.urlsplit(request.url)
                if parsed.path == "/ui/oauth2":
                    captured["authorization"] = urllib.parse.parse_qs(parsed.query)
                if parsed.path == "/static/oidc-callback.html" and "code=" in parsed.query:
                    captured["callback"] = True
                if parsed.path == "/api/v1/user/oidc/login" and request.method == "POST":
                    captured["oidc"] = {key: values[0] for key, values in
                                        urllib.parse.parse_qs(request.post_data).items()}

            def observe_response(response):
                if urllib.parse.urlsplit(response.url).path == "/api/v1/user/oidc/login":
                    captured["loginStatus"] = response.status
                    if response.status == 200:
                        captured["session"] = response.text()

            def sign_in(page, person, *, denied=False):
                captured.clear()
                page.goto(ui + "/login")
                page.evaluate("() => { localStorage.clear(); sessionStorage.clear(); }")
                page.reload()
                page.get_by_role("button", name="Kanidm").click()
                deadline = time.monotonic() + 60
                while "authorization" not in captured:
                    if time.monotonic() >= deadline:
                        raise QualificationFailure("native-browser-authorization-absent")
                    page.wait_for_timeout(50)
                page.wait_for_function("() => (location.hostname === 'idm.dt-fixture.invalid' && (document.querySelector('#username') !== null || document.querySelector(\"form[action='/ui/oauth2/consent']\") !== null || location.pathname === '/ui/oauth2/resume')) || document.querySelector('.app-header') !== null || document.querySelector('.modal.show') !== null")
                if (urllib.parse.urlsplit(page.url).hostname == "idm.dt-fixture.invalid"
                        and page.locator("#username").is_visible()):
                    page.locator("#username").fill(person)
                    page.locator("form[action='/ui/login/begin'] button[type=submit]").click()
                page.wait_for_function("() => location.hostname === 'dt.dt-fixture.invalid' || document.querySelector(\"form[action='/ui/oauth2/consent']\") !== null || location.pathname === '/ui/oauth2/resume'")
                if denied:
                    page.wait_for_url("**/ui/oauth2/resume")
                    return
                consent = page.locator("form[action='/ui/oauth2/consent'] button[type=submit]")
                if consent.count():
                    consent.click()
                page.wait_for_url(ui + "/**")
                page.wait_for_function("() => !location.pathname.includes('oidc-callback')")
                page.wait_for_function("() => document.querySelector('.app-header') !== null || document.querySelector('.modal.show') !== null")
                if captured.get("loginStatus") != 200 or not captured.get("session"):
                    raise QualificationFailure("native-browser-dt-login-refused")
                query = captured.get("authorization", {})
                if (query.get("client_id") != ["dependency-track"]
                        or query.get("response_type") != ["code"]
                        or query.get("code_challenge_method") != ["S256"]
                        or not query.get("code_challenge") or not captured.get("callback")):
                    raise QualificationFailure("native-browser-pkce-callback-absent")
                return captured["session"]

            with sync_playwright() as playwright:
                browser = playwright.chromium.launch(executable_path=settings["chromium"], headless=True,
                    env={**os.environ, **env}, args=["--host-resolver-rules=MAP *.dt-fixture.invalid 127.0.0.1",
                        "--disable-background-networking", "--disable-component-update", "--no-proxy-server"])
                try:
                    for person in ("fixture-administrator", "fixture-nonmember"):
                        context = browser.new_context()
                        try:
                            context.set_default_timeout(60000)
                            context.route("**/*", lambda route: route.continue_()
                                if urllib.parse.urlsplit(route.request.url).hostname in {
                                    "idm.dt-fixture.invalid", "dt.dt-fixture.invalid", "api.dt-fixture.invalid"}
                                else route.abort())
                            context.on("request", observe)
                            context.on("response", observe_response)
                            page = context.new_page()
                            cdp = context.new_cdp_session(page)
                            cdp.send("WebAuthn.enable", {"enableUI": False})
                            cdp.send("WebAuthn.addVirtualAuthenticator", {"options": {
                                "protocol": "ctap2", "transport": "internal", "hasResidentKey": True,
                                "hasUserVerification": True, "isUserVerified": True,
                                "automaticPresenceSimulation": True}})
                            page.goto(idm + "/ui/login")
                            enroll(page, person)
                            native_token = native_login(page, person)
                            if person == "fixture-nonmember":
                                sign_in(page, person, denied=True)
                                idm_api("GET", "/oauth2/authorise?" + urllib.parse.urlencode(
                                    captured["authorization"], doseq=True), bearer=native_token, expected=403)
                                proof["nonmemberStatus"] = 403
                                continue
                            session_token = sign_in(page, person)
                            proof["pkceCallback"] = True
                            if json.loads(api("/v1/user/self", bearer=session_token, record=False))["username"] != person:
                                raise QualificationFailure("native-dt-actor-mismatch")
                            permissions = json.loads(api("/v1/user/self/permissions", bearer=session_token, record=False))
                            catalog = json.loads(api("/v1/permission", bearer=admin_bearer, record=False))
                            wanted = sorted(permission["name"] for permission in catalog)
                            if sorted(permissions) != wanted:
                                raise QualificationFailure("native-dt-admin-permissions-mismatch")
                            proof.update(administratorPermissions=wanted, administratorStatus=200)
                            original_tokens = dict(captured["oidc"])
                            page.locator(".fa-user-circle-o").click()
                            with page.expect_response(lambda response:
                                    urllib.parse.urlsplit(response.url).path == "/api/v1/user/logout") as logged_out:
                                page.locator(".fa-sign-out").click()
                            if logged_out.value.status not in (200, 204):
                                raise QualificationFailure("native-browser-logout-refused")
                            page.wait_for_url(ui + "/login")
                            api("/v1/user/self", bearer=session_token, expected=(401,), record=False)
                            proof["localLogoutStatus"] = observed["lastHttpStatus"]
                            group = next(group for group in json.loads(api("/v1/oidc/group",
                                bearer=admin_bearer, record=False)) if group["name"] == settings["oidcGroup"])
                            team = next(team for team in json.loads(api("/v1/oidc/group/" + group["uuid"] +
                                "/team", bearer=admin_bearer, record=False)) if team["name"] == "Administrators")
                            api("/v1/oidc/group/" + group["uuid"] + "/team/" + team["uuid"] + "/mapping",
                                method="DELETE", bearer=admin_bearer, record=False)
                            unmapped = sign_in(page, person)
                            if json.loads(api("/v1/user/self/permissions", bearer=unmapped, record=False)):
                                raise QualificationFailure("native-unmapped-human-has-permissions")
                            api("/v1/configProperty", bearer=unmapped, expected=(403,), record=False)
                            proof["unmappedStatus"] = observed["lastHttpStatus"]
                            api("/v1/user/logout", method="POST", bearer=unmapped, record=False)
                            reconcile_access()
                            session_token = sign_in(page, person)
                            idm_api("PUT", "/v1/group/" + settings["oidcGroup"] + "/_attr/member", [], bearer=idm_admin)
                            api("/v1/user/self", bearer=session_token, record=False)
                            proof["existingSessionAfterGroupRemoval"] = observed["lastHttpStatus"]
                            api("/v1/user/logout", method="POST", bearer=session_token, record=False)
                            sign_in(page, person, denied=True)
                            idm_api("GET", "/oauth2/authorise?" + urllib.parse.urlencode(
                                captured["authorization"], doseq=True), bearer=native_token, expected=403)
                            proof["removedGroupReloginStatus"] = 403
                            idm_api("PUT", "/v1/group/" + settings["oidcGroup"] + "/_attr/member",
                                    ["fixture-administrator"], bearer=idm_admin)
                        finally:
                            context.close()
                finally:
                    browser.close()
            # Genuine previously accepted signed ID token, independently
            # mismatching the server's expected audience and issuer; no fake JWT.
            for variable, value, key in (
                    ("DT_OIDC_CLIENT_ID", "fixture-wrong-audience", "wrongAudienceStatus"),
                    ("DT_OIDC_ISSUER", "https://idm.dt-fixture.invalid/oauth2/openid/fixture-wrong-issuer",
                     "wrongIssuerStatus")):
                changed = private_restore()
                container = next(obj["spec"]["template"]["spec"]["containers"][0]
                    for obj in changed["items"] if obj["kind"] == "Deployment"
                    and obj["metadata"]["name"] == "dependency-track-api")
                next(entry for entry in container["env"] if entry["name"] == variable)["value"] = value
                stop_forward()
                apply(changed)
                deployment("api", 1)
                start_forward()
                api("/v1/user/oidc/login", method="POST", form=True, body=original_tokens,
                    expected=(401, 403), record=False)
                proof[key] = observed["lastHttpStatus"]
            stop_forward()
            apply(private_restore())
            deployment("api", 1)
            start_forward()
            recovered = api("/v1/user/oidc/login", method="POST", form=True, body=original_tokens,
                            record=False).decode()
            proof["afterNegativeRecoveryStatus"] = observed["lastHttpStatus"]
            api("/v1/user/logout", method="POST", bearer=recovered, record=False)
            observed["nativeOidc"] = proof

        def alertmanager_objects():
            labels = {"app.kubernetes.io/name": "fixture-alertmanager"}
            return [
                {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "monitoring"}},
                {"apiVersion": "v1", "kind": "ConfigMap",
                 "metadata": {"name": "fixture-alertmanager", "namespace": "monitoring"},
                 "data": {"alertmanager.yaml": json.dumps(settings["alertmanager"]["config"])}},
                {"apiVersion": "v1", "kind": "Service",
                 "metadata": {"name": "alertmanager", "namespace": "monitoring"},
                 "spec": {"selector": labels, "ports": [{"name": "http", "port": 9093, "targetPort": 9093}]}},
                {"apiVersion": "apps/v1", "kind": "Deployment",
                 "metadata": {"name": "fixture-alertmanager", "namespace": "monitoring"},
                 "spec": {"replicas": 1, "selector": {"matchLabels": labels},
                          "template": {"metadata": {"labels": labels}, "spec": {
                              "automountServiceAccountToken": False, "enableServiceLinks": False,
                              "securityContext": {"runAsNonRoot": True, "runAsUser": 65534, "runAsGroup": 65534,
                                                  "fsGroup": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
                              "containers": [{
                                  "name": "alertmanager", "image": settings["alertmanager"]["image"],
                                  "imagePullPolicy": "Never",
                                  "args": ["--config.file=/etc/alertmanager/alertmanager.yaml",
                                           "--storage.path=/alertmanager", "--web.listen-address=:9093",
                                           "--cluster.listen-address="],
                                  "securityContext": {"allowPrivilegeEscalation": False,
                                                      "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
                                  "resources": settings["alertmanager"]["resources"],
                                  "ports": [{"name": "http", "containerPort": 9093}],
                                  "readinessProbe": {"httpGet": {"path": "/-/ready", "port": 9093},
                                                     "periodSeconds": 2},
                                  "volumeMounts": [{"name": "config", "mountPath": "/etc/alertmanager", "readOnly": True},
                                                   {"name": "data", "mountPath": "/alertmanager"}],
                              }],
                              "volumes": [{"name": "config", "configMap": {"name": "fixture-alertmanager"}},
                                          {"name": "data", "emptyDir": {"sizeLimit": "16Mi"}}],
                          }}}}
            ]

        def notifier_group_alive(group):
            try:
                os.killpg(group, 0)
                return True
            except ProcessLookupError:
                return False

        def root_notification(runtime):
            process = subprocess.Popen([settings["failureNotifier"]], stdin=subprocess.DEVNULL,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       env={**env, "RUNTIME_DIRECTORY": str(runtime),
                                            "HOMELAB_NOTIFICATION_PRIVATE_CANARY": notification_canary},
                                       start_new_session=True)
            notifier_groups.add(process.pid)
            try:
                code = process.wait(timeout=45)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
                if not notifier_group_alive(process.pid):
                    notifier_groups.discard(process.pid)
            if process.pid in notifier_groups:
                raise QualificationFailure("failure-notification-proxy-survived")
            return code

        def qualify_failure_notification():
            nonlocal alertmanager_created
            alertmanager_created = True
            apply({"apiVersion": "v1", "kind": "List", "items": alertmanager_objects()})
            k("-n", "monitoring", "rollout", "status", "deployment/fixture-alertmanager",
              "--timeout=180s", timeout=200)
            proxy = "/api/v1/namespaces/monitoring/services/http:alertmanager:9093/proxy"

            def query(path):
                return json.loads(k("get", "--raw=" + proxy + path).stdout)

            pods = json.loads(k("-n", "monitoring", "get", "pods", "-l",
                                "app.kubernetes.io/name=fixture-alertmanager", "-o", "json").stdout)["items"]
            if len(pods) != 1:
                raise QualificationFailure("failure-notification-pod-population")
            resources = pods[0]["spec"]["containers"][0]["resources"]
            if query("/api/v2/alerts") != []:
                raise QualificationFailure("failure-notification-fixture-not-empty")
            root_exits = []
            with tempfile.TemporaryDirectory(prefix="failure-notifier-", dir=work) as runtime_directory:
                runtime = Path(runtime_directory)
                runtime.chmod(0o700)
                private_runtime = runtime.stat().st_uid == 0 and stat.S_IMODE(runtime.stat().st_mode) == 0o700
                refused = run([settings["failureNotifier"]], user=705, check=False,
                              environment={**env, "RUNTIME_DIRECTORY": str(runtime)})
                no_events = query("/api/v2/alerts") == []
                if refused.returncode == 0 or not no_events or not private_runtime:
                    raise QualificationFailure("failure-notification-uid705-boundary")
                for index in range(2):
                    event_runtime = runtime / str(index)
                    event_runtime.mkdir(mode=0o700)
                    (event_runtime / "private-context").write_text(notification_canary)
                    root_exits.append(root_notification(event_runtime))
                    if root_exits[-1] != 0:
                        raise QualificationFailure("failure-notification-root-send-failed")
                wait(lambda: len(query("/api/v2/alerts/groups")) == 2, seconds=30,
                     reason="failure-notification-group-convergence-timeout")
                alerts = query("/api/v2/alerts")
                groups = query("/api/v2/alerts/groups")
                if not isinstance(alerts, list) or len(alerts) != 2 or not isinstance(groups, list) or len(groups) != 2:
                    raise QualificationFailure("failure-notification-independent-events-missing")
                events = []
                if notification_canary in json.dumps(alerts):
                    raise QualificationFailure("failure-notification-private-context-leaked")
                for alert in alerts:
                    labels = alert["labels"]
                    event_id = labels.get("event_id", "")
                    annotations = alert.get("annotations")
                    if (not isinstance(event_id, str) or not re.fullmatch(
                            r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", event_id)
                            or labels != failure_labels(settings, event_id)
                            or not isinstance(annotations, dict) or set(annotations) != {"summary"}
                            or not isinstance(annotations["summary"], str) or len(annotations["summary"]) > 1024):
                        raise QualificationFailure("failure-notification-unsafe-event")
                    events.append(labels)
                grouped = []
                for group in groups:
                    labels = group["labels"]
                    member_ids = [alert["labels"].get("event_id") for alert in group["alerts"]]
                    if (len(member_ids) != 1 or member_ids[0] not in [event["event_id"] for event in events]
                            or labels != {"alertname": "DependencyTrackInventoryRefreshFailed", "event_id": member_ids[0]}
                            or group["receiver"] != {"name": settings["alertmanager"]["eventRoute"]["receiver"]}
                            or group["alerts"][0]["labels"] != failure_labels(settings, member_ids[0])):
                        raise QualificationFailure("failure-notification-event-group-mismatch")
                    grouped.append({"labels": labels, "receiver": group["receiver"]["name"], "eventIds": member_ids})
            observed["failureNotification"] = {
                "uid705Exit": refused.returncode, "uid705CreatedNoEvents": no_events,
                "rootExits": root_exits, "privateRuntime": private_runtime, "annotationsSafe": True,
                "events": events, "groups": grouped, "resources": resources,
                "proxyProcessesRemoved": all(not notifier_group_alive(group) for group in notifier_groups),
                "runtimeRemoved": not runtime.exists(),
            }
            k("delete", "namespace", "monitoring", "--wait=true", "--timeout=120s", timeout=140)
            remaining = json.loads(k("get", "namespaces", "-o", "json").stdout)["items"]
            receipt["cleanupWitness"]["alertmanagerRemoved"] = all(item["metadata"]["name"] != "monitoring" for item in remaining)
            if not receipt["cleanupWitness"]["alertmanagerRemoved"]:
                raise QualificationFailure("failure-notification-resources-survived")
            check("exact-root-failure-notifier-uid705-refusal-and-independent-null-receiver-events")

        def project_credentials(api_key, github_value):
            apply({"apiVersion": "v1", "kind": "Secret",
                   "metadata": {"namespace": "dependency-track", "name": "dependency-track-sync"},
                   "stringData": {"api-key": api_key, "github-token": github_value}})
            if credential_directory not in owned_host_paths:
                for path in (credential_directory, staged_directory):
                    path.mkdir(mode=0o700)
                    owned_host_paths.append(path)
                marker = staged_directory / "runtime-secrets.commit"
                marker.write_text("isolated fixture: Secret supplied directly to the native API\n")
                marker.chmod(0o400)
            run([settings["credentialStage"]], timeout=60)
            expected = {"api-key": api_key.encode(), "github-token": github_value.encode()}
            for key_name, value in expected.items():
                path = credential_directory / key_name
                info = path.lstat()
                if (not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o400
                        or info.st_uid != 0 or info.st_gid != 0 or path.read_bytes() != value):
                    raise QualificationFailure("credential-projection-identity-or-permissions")
            refused = run([settings["cat"], str(credential_directory / "api-key")], user=705, check=False)
            if refused.returncode == 0:
                raise QualificationFailure("root-projection-readable-by-ingestor")
            return {"valuesMatched": all((credential_directory / key_name).read_bytes() == value for key_name, value in expected.items()),
                    "modes": [stat.S_IMODE((credential_directory / key_name).stat().st_mode) for key_name in expected],
                    "owners": [(credential_directory / key_name).stat().st_uid for key_name in expected],
                    "uid705ReadExit": refused.returncode}

        def refresh_snapshot(state_directory, stock, *, complete=True):
            database = sync.load(state_directory / "state.json")
            if database.get("sourcePolicy") != {"repository": settings["repository"], "branch": args.producer_branch}:
                raise QualificationFailure("refresh-source-policy-mismatch")
            if complete and database.get("refresh", {}).get("status") != "complete":
                raise QualificationFailure("refresh-not-complete")
            wanted = {target["id"]: target for target in settings["qualificationTargets"].values()}
            expected = {entry["source"]["id"]: (target, entry) for target, entry in database["expected"].items()
                        if entry["source"]["id"] in wanted}
            if set(expected) != set(wanted) or len(database["targets"]) != 2:
                raise QualificationFailure("refresh-did-not-retain-exact-admitted-targets")

            def inside(value):
                path = Path(value)
                if path.is_symlink() or not path.resolve(strict=True).is_relative_to(state_directory.resolve()):
                    raise QualificationFailure("refresh-evidence-escaped-state")
                return path

            identities = {}
            summaries = {}
            producer = None
            for declaration_id, declaration in wanted.items():
                target, expected_entry = expected[declaration_id]
                record = database["targets"][target]
                for source in (expected_entry["source"], record["source"]):
                    if any(source.get(key) != value for key, value in declaration.items()):
                        raise QualificationFailure("refresh-broadened-admitted-declaration")
                if complete and (expected_entry.get("coverage") != "complete-inventory" or record.get("pending")):
                    raise QualificationFailure("refresh-selected-target-incomplete")
                current = record["current"]
                if set(current["complete"]) != set(current["projects"]) or set(current["hashes"]) != set(current["projects"]):
                    raise QualificationFailure("refresh-stream-coverage-incomplete")
                required_streams = {"native", "language"} if declaration["kind"] == "nix" else {"image"}
                if not required_streams <= set(current["projects"]):
                    raise QualificationFailure("refresh-required-stream-absent")
                acquisition = record["acquisition"]
                evidence = inside(acquisition["evidence"])
                source_receipt = sync.load(evidence / "source.json")
                native_run = source_receipt["run"]
                admitted_producer = sync.security_artifacts.trusted_run(native_run, settings["repository"], args.producer_branch)
                if (source_receipt["producer"] != admitted_producer or acquisition["run"] != native_run["id"]
                        or acquisition["sha"] != native_run["head_sha"] or acquisition["branch"] != args.producer_branch
                        or acquisition["repository"] != settings["repository"] or native_run["status"] != "completed"):
                    raise QualificationFailure("refresh-run-source-identity-mismatch")
                source_identity = {
                    "repository": settings["repository"], "branch": args.producer_branch,
                    "sha": native_run["head_sha"], "run": native_run["id"],
                    "workflow": native_run["path"], "event": native_run["event"],
                    "conclusion": native_run["conclusion"], "completedAt": native_run["updated_at"],
                }
                if producer is not None and producer != source_identity:
                    raise QualificationFailure("refresh-targets-joined-different-runs")
                producer = source_identity
                artifact = acquisition["artifact"]
                if sync.load(inside(evidence / (target + "-artifact.json"))) != artifact:
                    raise QualificationFailure("refresh-retained-artifact-receipt-mismatch")
                artifact_run = artifact["workflow_run"]
                archive_zip = inside(state_directory / "artifacts" / (str(artifact["id"]) + ".zip"))
                if (artifact_run["id"] != native_run["id"] or artifact_run["head_sha"] != native_run["head_sha"]
                        or artifact_run["head_branch"] != args.producer_branch
                        or artifact["digest"] != "sha256:" + sync.security_artifacts.digest(archive_zip)
                        or archive_zip.stat().st_size != artifact["size_in_bytes"]):
                    raise QualificationFailure("refresh-retained-artifact-api-digest-mismatch")
                plan_artifact = source_receipt["planArtifact"]
                plan_zip = inside(state_directory / "artifacts" / (str(plan_artifact["id"]) + ".zip"))
                if (plan_artifact["digest"] != "sha256:" + sync.security_artifacts.digest(plan_zip)
                        or plan_zip.stat().st_size != plan_artifact["size_in_bytes"]):
                    raise QualificationFailure("refresh-retained-plan-api-digest-mismatch")
                for archived in record["receipts"]:
                    archived = inside(archived)
                    manifest = sync.load(archived / "complete.json")
                    sync.security_artifacts.verify(archived, manifest["inventoryKey"])
                    if sync.security_artifacts.digest(archived / "complete.json") != archived.name:
                        raise QualificationFailure("refresh-original-seal-changed")
                archived = inside(current["archive"])
                manifest = sync.load(archived / "complete.json")
                sync.security_artifacts.verify(archived, manifest["inventoryKey"], admitted_producer)
                project = stock.request("GET", "project/" + record["collection"])
                if (project["uuid"] != record["collection"] or project.get("active") is not True
                        or project.get("collectionLogic") != "AGGREGATE_LATEST_VERSION_CHILDREN"):
                    raise QualificationFailure("refresh-collection-identity-mismatch")
                component_counts = {}
                component_identities = {}
                api_identities = {"collection": project["uuid"], "leaves": {}}
                for stream, project_id in current["projects"].items():
                    leaf = stock.request("GET", "project/" + project_id)
                    if (leaf["uuid"] != project_id or leaf.get("active") is not True or leaf.get("isLatest") is not True
                            or (leaf.get("parent") or {}).get("uuid") != record["collection"]):
                        raise QualificationFailure("refresh-current-project-not-active-or-stable")
                    api_identities["leaves"][stream] = {key: leaf.get(key) for key in
                        ("uuid", "name", "version", "description", "active", "isLatest", "collectionLogic")}
                    properties = {item["propertyName"]: item["propertyValue"]
                                  for item in stock.request("GET", "project/" + project_id + "/property")
                                  if item["groupName"] == sync.GROUP}
                    required_properties = {
                        "deployment": "unobserved", "source_scope": declaration["state"],
                        "inventory_key": manifest["inventoryKey"], "import_sha256": current["hashes"][stream],
                        "archive_seal_sha256": archived.name,
                    }
                    if any(properties.get(key) != value for key, value in required_properties.items()):
                        raise QualificationFailure("refresh-api-source-scope-or-original-seal-mismatch")
                    api_identities["leaves"][stream]["sourceProperties"] = required_properties
                    components = {}
                    for page in range(1, 501):
                        items = stock.request("GET", "component/project/" + project_id + "?" +
                                              urllib.parse.urlencode({"pageSize": 100, "pageNumber": page}))
                        if not isinstance(items, list) or len(items) > 100:
                            raise QualificationFailure("refresh-component-page-shape")
                        for component in items:
                            component_id = str(uuid.UUID(component["uuid"]))
                            if component_id in components:
                                raise QualificationFailure("refresh-component-pagination-repeated")
                            components[component_id] = {key: component.get(key) for key in
                                ("uuid", "purl", "group", "name", "version", "bomRef")}
                        if len(items) < 100:
                            break
                    else:
                        raise QualificationFailure("refresh-component-pagination-bound")
                    if stream in ("native", "image") and not components:
                        raise QualificationFailure("refresh-empty-positive-component-coverage")
                    component_counts[stream] = len(components)
                    component_identities[stream] = sync.identity(components)
                origin = record.get("origins", {}).get("current")
                origin_summary = None
                if declaration["kind"] == "nix":
                    if not origin or record["origins"]["lastAttempt"]["status"] != "complete":
                        raise QualificationFailure("refresh-host-origin-evidence-absent")
                    directory = inside(origin["directory"])
                    origin_report = sync.load(directory / "origins.json")
                    if (origin["project"] != current["projects"]["native"]
                            or origin["originalArchive"] != current["archive"]
                            or origin["inventoryKey"] != manifest["inventoryKey"]
                            or origin["source"]["revision"] != native_run["head_sha"]
                            or origin["source"]["flake"] != "github:dvicory/homelab/" + native_run["head_sha"]
                            or origin_report["root"] != {key: record["source"][key] for key in ("drvPath", "outPath")}
                            or sync.security_artifacts.digest(directory / "origins.json") != origin["reportSha256"]
                            or sync.security_artifacts.digest(directory / "native-origins.cdx.json") != origin["bomSha256"]
                            or origin_report["coverage"]["complete"] is not False
                            or origin_report["counts"]["tracedOrigins"] <= 0):
                        raise QualificationFailure("refresh-origin-seal-root-or-source-mismatch")
                    properties = {item["propertyName"]: item["propertyValue"]
                                  for item in stock.request("GET", "project/" + current["projects"]["native"] + "/property")
                                  if item["groupName"] == sync.GROUP}
                    if (properties.get("origin_report_sha256") != origin["reportSha256"]
                            or properties.get("origin_bom_sha256") != origin["bomSha256"]
                            or json.loads(properties.get("origin_source", "null")) != origin["source"]):
                        raise QualificationFailure("refresh-origin-api-receipt-mismatch")
                    origin_summary = {
                        "reportSha256": origin["reportSha256"], "bomSha256": origin["bomSha256"],
                        "counts": origin_report["counts"], "completeCoverage": origin_report["coverage"]["complete"],
                        "sourceRevision": origin["source"]["revision"], "inventoryKey": origin["inventoryKey"],
                    }
                retained_origin = {key: value for key, value in (origin or {}).items() if key != "completedAt"}
                identities[declaration_id] = {
                    "collection": record["collection"], "current": current, "history": record["history"],
                    "receipts": record["receipts"], "origin": retained_origin, "api": api_identities,
                    "components": component_identities,
                }
                summaries[declaration_id] = {
                    "declaration": declaration, "collectionUuid": record["collection"], "projectUuids": current["projects"],
                    "componentCounts": component_counts, "componentIdentityDigests": component_identities,
                    "revisionId": current["revisionId"], "currentIdentity": sync.identity(current),
                    "softwareRevision": current["revision"],
                    "historyCount": len(record["history"]), "historyIdentity": sync.identity(record["history"]),
                    "receiptSeals": [Path(path).name for path in record["receipts"]],
                    "originalSealSha256": archived.name, "inventoryKey": manifest["inventoryKey"],
                    "originalProducer": manifest["producer"], "originalSourceRevision": record["source"]["sourceRevision"],
                    "requestedByRevision": record["source"].get("requestedByRevision", record["source"]["sourceRevision"]),
                    "artifactDigest": artifact["digest"], "artifactId": artifact["id"],
                    "retainedFileCount": len(manifest["files"]), "origin": origin_summary,
                }
            storage = {}
            for category in STORAGE_CATEGORIES:
                files = []
                for path in (state_directory / category).rglob("*"):
                    if path.is_symlink():
                        raise QualificationFailure("refresh-evidence-storage-symlink")
                    if path.is_file():
                        files.append(path)
                storage[category] = {"files": len(files), "bytes": sum(path.stat().st_size for path in files)}
            return {"stableIdentity": sync.identity(identities), "producer": producer, "targets": summaries,
                    "observedAt": datetime.now(timezone.utc).isoformat(), "expectedCount": len(database["expected"]),
                    "excludedCount": len(database["refresh"].get("excluded", [])),
                    "refreshStatus": database["refresh"]["status"], "storage": storage}

        def interrupted(signum, frame):
            raise QualificationFailure("interrupted")

        signal.signal(signal.SIGTERM, interrupted)
        signal.signal(signal.SIGINT, interrupted)
        try:
            guard_results = []
            for boundary in (0, 1024):
                result = run([
                    settings["unshare"], "--net", "--", settings["bash"], "-ec",
                    'printf "%s" "$1" > /proc/sys/net/ipv4/ip_unprivileged_port_start; exec "$2"',
                    "isolated-port-guard", str(boundary), settings["brokerPortGuard"],
                ], check=False)
                guard_results.append(result.returncode)
            observed["reservedPortGuard"] = {
                "script": settings["brokerPortGuard"], "unreservedExit": guard_results[0], "reservedExit": guard_results[1],
            }
            if guard_results[0] == 0 or guard_results[1] != 0:
                raise QualificationFailure("source-reserved-port-guard-boundary-failed")
            # Same local Unix transport and empty Docker auth config as _kubernetes-api.
            context = json.loads(run([*docker, "context", "inspect", args.docker_context]).stdout)[0]
            endpoint = context["Endpoints"]["docker"]["Host"]
            if not endpoint.startswith("unix:///") or "\n" in endpoint:
                raise QualificationFailure("nonlocal-docker-transport")
            docker += ["--host", endpoint, "--config", str(work / "docker")]
            info = json.loads(d("info", "--format", "{{json .}}").stdout)
            if info["Architecture"] not in ("x86_64", "amd64") or info["NCPU"] < 4 or info["MemTotal"] < 14 * 1024**3:
                raise QualificationFailure("non-native-docker")
            phase = "image-fetch"
            bootstrap = json.loads(Path(settings["bootstrap"]).read_text())
            policies = [yaml.safe_load(p.read_text()) for p in sorted(Path(settings["networkPolicy"]).glob("*.yaml"))]
            images = source_inputs(settings)[1]
            d("pull", "--platform", "linux/amd64", settings["image"], timeout=600)
            inspected = json.loads(d("image", "inspect", settings["image"]).stdout)[0]
            resolved = sorted({
                "rancher/k3s@" + ref.split("@", 1)[1]
                for ref in inspected["RepoDigests"]
                if ref.split("@", 1)[0] in ("rancher/k3s", "docker.io/rancher/k3s")
                and re.fullmatch(r"sha256:[0-9a-f]{64}", ref.split("@", 1)[-1])
            })
            if len(resolved) != 1:
                raise QualificationFailure("k3s-image-identity-unavailable")
            node_image = resolved[0]
            receipt["images"] = sorted(images | {node_image})
            receipt["k3sVersion"] = settings["k3sVersion"]
            receipt["k3sImage"] = {"tag": settings["image"], "reference": node_image, "configDigest": inspected["Id"]}
            for image in sorted(images):
                d("pull", "--platform", "linux/amd64", image, timeout=600)
            receipt["imageArchitectures"] = {}
            for image in receipt["images"]:
                image_info = json.loads(d("image", "inspect", image).stdout)[0]
                receipt["imageArchitectures"][image] = image_info["Architecture"]
                if image_info["Architecture"] != "amd64":
                    raise QualificationFailure("image-architecture-mismatch")
            phase = "cluster-setup"
            network_created = True
            d("network", "create", "--label", "verification.homelab/fixture=" + token, network)
            created = True
            d("create", "--platform", "linux/amd64", "--privileged", "--name", name,
              "--label", "verification.homelab/fixture=" + token, "--network", network,
              "--sysctl", "net.ipv4.ip_unprivileged_port_start=1024",
              "--publish", "127.0.0.1::6443", "--memory=10g", "--cpus=4", node_image, "server", "--node-name", "compute-1",
              "--disable", "traefik", "--disable", "servicelb", "--disable", "metrics-server",
              "--disable", "local-storage", "--disable-network-policy", "--kube-proxy-arg=proxy-mode=nftables")
            d("start", name)
            wait(lambda: k("get", "--raw=/readyz", check=False, timeout=20).returncode == 0)
            version = json.loads(k("get", "--raw=/version").stdout)["gitVersion"]
            versions = json.loads(k("version", "-o", "json").stdout)
            if version != "v" + settings["k3sVersion"] or versions["clientVersion"]["gitVersion"] != version:
                raise QualificationFailure("cluster-version-mismatch")
            receipt["versions"] = {"server": version, "embeddedClient": versions["clientVersion"]["gitVersion"]}
            node = json.loads(d("inspect", name).stdout)[0]
            if node.get("Config", {}).get("Labels", {}).get("verification.homelab/fixture") != token or not node["State"]["Running"]:
                raise QualificationFailure("owned-node-namespace-identity-mismatch")
            observed["guestPortBoundary"] = {
                "value": int(native("cat", "/proc/sys/net/ipv4/ip_unprivileged_port_start").stdout),
            }
            if observed["guestPortBoundary"]["value"] != 1024:
                raise QualificationFailure("guest-reserved-port-boundary-not-enforced")
            ports = node["NetworkSettings"]["Ports"]["6443/tcp"]
            if len(ports) != 1 or ports[0]["HostIp"] != "127.0.0.1":
                raise QualificationFailure("nonlocal-kubernetes-endpoint")
            node_port = int(ports[0]["HostPort"])
            original = yaml.safe_load(native("cat", "/etc/rancher/k3s/k3s.yaml").stdout)
            kubeconfig = {
                "apiVersion": "v1", "kind": "Config", "current-context": name,
                "clusters": [{"name": name, "cluster": {
                    "server": "https://127.0.0.1:" + str(node_port),
                    "certificate-authority-data": original["clusters"][0]["cluster"]["certificate-authority-data"]}}],
                "contexts": [{"name": name, "context": {"cluster": name, "user": name}}],
                "users": [{"name": name, "user": {key: original["users"][0]["user"][key]
                           for key in ("client-certificate-data", "client-key-data")}}],
            }
            policy_kubeconfig = json.loads(json.dumps(kubeconfig))
            policy_kubeconfig["clusters"][0]["cluster"]["server"] = "https://127.0.0.1:6443"
            (work / "policy-kubeconfig").write_text(yaml.safe_dump(policy_kubeconfig))
            (work / "policy-kubeconfig").chmod(0o600)
            config_path = work / "kubeconfig"
            config_path.write_text(yaml.safe_dump(kubeconfig))
            config_path.chmod(0o600)
            env["KUBECONFIG"] = str(config_path)
            versions = json.loads(k("version", "-o", "json").stdout)
            if versions["clientVersion"]["gitVersion"] != version or versions["serverVersion"]["gitVersion"] != version:
                raise QualificationFailure("source-client-server-version-mismatch")
            receipt["versions"]["sourceClient"] = versions["clientVersion"]["gitVersion"]
            # Docker save reconstructs manifests and can lose the original pinned index reference.
            # Pull through the actual CRI instead; never invent an alias for different manifest bytes.
            phase = "runtime-image-fetch"
            # The released OCI image embeds cmd/server, not the extracting cmd/k3s launcher.
            # Its Linux `k3s crictl` path retains "crictl" in os.Args; use the registered multicall alias.
            image_runtime = ("/bin/crictl", "--runtime-endpoint=unix:///run/k3s/containerd/containerd.sock",
                             "--image-endpoint=unix:///run/k3s/containerd/containerd.sock")
            receipt["runtimeManifestDigests"] = {}
            for image in sorted(images):
                native(*image_runtime, "pull", image, timeout=600, operation="cri-image-pull")
                status = json.loads(native(*image_runtime, "inspecti", "-o", "json", image,
                                           operation="cri-image-inspect").stdout)["status"]
                digests = sorted({reference.rsplit("@", 1)[-1] for reference in status.get("repoDigests", [])
                                  if re.fullmatch(r"sha256:[0-9a-f]{64}", reference.rsplit("@", 1)[-1])})
                if image.rsplit("@", 1)[1] not in digests:
                    raise QualificationFailure("runtime-image-source-digest-mismatch")
                receipt["runtimeManifestDigests"][image] = digests
            phase = "cluster-setup"
            native("mkdir", "-p", "/var/run/netns")
            native("mount", "--rbind", "/var/run/netns", "/var/run/netns")
            native("mount", "--make-rshared", "/var/run/netns")
            apply({"apiVersion": "v1", "kind": "List", "items": policies})
            k("-n", "kube-system", "rollout", "status", "daemonset/kube-network-policies",
              "--timeout=180s", timeout=200)
            phase = "stock-bootstrap"
            native("mkdir", "-p", "/srv/dependency-track/postgres", "/srv/dependency-track/api", "/srv/dependency-track/evidence")
            native("chown", "70:70", "/srv/dependency-track/postgres")
            native("chown", "1000:0", "/srv/dependency-track/api")
            native("chown", "705:705", "/srv/dependency-track/evidence")
            native("chmod", "0700", "/srv/dependency-track/postgres", "/srv/dependency-track/api", "/srv/dependency-track/evidence")
            apply(json.loads(Path(settings["retained"]).read_text()))
            password = secrets.token_hex(32)
            secret = {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "dependency-track-postgres", "namespace": "dependency-track"},
                      "stringData": {"password": password}}
            apply(secret)
            apply(bootstrap)
            # Expose only the source restore peer rules inside this fixture so
            # readiness, rather than staged production routes, is the variable.
            for obj in json.loads(Path(settings["restore"]).read_text())["items"]:
                if obj["kind"] == "NetworkPolicy" and obj["metadata"]["name"] in {
                        "dependency-track-api", "dependency-track-frontend"}:
                    apply(obj)
            recovery_password = oidc_setup()
            for component in ("postgres", "api", "frontend"):
                deployment(component, 1)
            phase = "native-access-bootstrap"
            if os.path.lexists("/run/dependency-track-sync-api-tunnel"):
                raise QualificationFailure("fixture-broker-runtime-already-exists")
            Path("/run/dependency-track-sync-api-tunnel").mkdir(mode=0o700)
            owned_host_paths.append(Path("/run/dependency-track-sync-api-tunnel"))
            policy_proof = {"bootstrapPodUID": api_pod()["metadata"]["uid"]}
            policy_proof["beforeAdmissionGateway"] = gateway_closed()
            new_password = secrets.token_urlsafe(36)
            apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"namespace": "dependency-track",
                   "name": "dependency-track-admin"}, "stringData": {"password": new_password}})
            # Desired restore must never default-bootstrap a fresh database.
            policy_phase(False)
            reconcile_access(succeeds=False)
            policy_proof["freshRestoreGateway"] = gateway_closed()
            policy_phase(True)
            reconcile_access()
            policy_initialized = True
            wait(endpoints_ready, reason="validated-endpoint-unpublished")
            policy_proof["admittedGateway"] = trusted_https("api.dt-fixture.invalid", "/api/v1/project")[0]
            if policy_proof["admittedGateway"] != 401:
                raise QualificationFailure("validated-gateway-unexpected-status")
            # Nondefault recovery mismatches fail closed even when bootstrap was
            # requested; a restored nondefault password is never reset.
            apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"namespace": "dependency-track",
                   "name": "dependency-track-admin"}, "stringData": {"password": secrets.token_urlsafe(36)}})
            reconcile_access(succeeds=False)
            policy_proof["badBootstrapCredentialGateway"] = gateway_closed()
            policy_phase(False)
            reconcile_access(succeeds=False)
            policy_proof["badRestoreCredentialGateway"] = gateway_closed()
            apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"namespace": "dependency-track",
                   "name": "dependency-track-admin"}, "stringData": {"password": new_password}})
            reconcile_access()
            before = next(condition for condition in api_pod()["status"]["conditions"]
                          if condition["type"] == "security.homelab/access-policy-ready")
            reconcile_access()
            after = next(condition for condition in api_pod()["status"]["conditions"]
                         if condition["type"] == "security.homelab/access-policy-ready")
            if before["lastTransitionTime"] != after["lastTransitionTime"] or not admitted():
                raise QualificationFailure("healthy-admission-was-dropped")
            policy_proof["healthyReconciliationPreserved"] = True
            policy_proof["uid705PolicyExit"] = run([settings["accessPolicy"]], user=705,
                check=False, environment={**env, "RUNTIME_DIRECTORY": str(work / "access-policy")}).returncode
            policy_proof["uid705BrokerReadExit"] = run(
                [settings["cat"], "/run/dependency-track-sync-api-tunnel/pod.json"],
                user=705, check=False).returncode
            if not policy_proof["uid705PolicyExit"] or not policy_proof["uid705BrokerReadExit"]:
                raise QualificationFailure("ingestor-gained-root-access-policy-authority")
            observed["accessPolicy"] = policy_proof
            phase = "stock-bootstrap"
            role = pg("SELECT rolcanlogin AND NOT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls) FROM pg_roles WHERE rolname='dtrack';").stdout.strip()
            observed["roleSafe"] = role.decode("ascii")
            if role != b"t":
                raise QualificationFailure("unsafe-role")
            observed["superuserPasswordDisabled"] = pg("SELECT passwd IS NULL FROM pg_shadow WHERE usename='postgres';").stdout.strip().decode("ascii")
            if observed["superuserPasswordDisabled"] != "t":
                raise QualificationFailure("superuser-password-retained")
            for sql in ("CREATE ROLE fixture_forbidden;", "CREATE DATABASE fixture_forbidden;", "SELECT pg_read_file('/etc/passwd');"):
                refused = pg(sql, application=True, check=False)
                states = re.findall(rb"ERROR:\s+([0-9A-Z]{5}):", refused.stderr)
                observed["forbiddenSqlStates"].extend(state.decode("ascii") for state in states)
                if refused.returncode == 0 or b"42501" not in refused.stderr:
                    raise QualificationFailure("application-role-not-restricted")
            bad_password = k("-n", "dependency-track", "exec", "deployment/dependency-track-postgres", "--",
                             "/bin/sh", "-ec", "PGPASSWORD=fixture-invalid-password psql -XAt -h 127.0.0.1 -U dtrack -d dtrack -v VERBOSITY=verbose -c 'SELECT 1'", check=False)
            observed["invalidDatabasePasswordExit"] = bad_password.returncode
            if bad_password.returncode == 0 or b"password authentication failed" not in bad_password.stderr:
                raise QualificationFailure("invalid-database-password-accepted")
            check("stock-bootstrap-restricted-role-and-scram")
            phase = "root-failure-notification"
            qualify_failure_notification()
            phase = "stock-bootstrap"
            start_forward()
            observed["authentication"] = {}
            api("/v1/project", expected=(401, 403))
            observed["authentication"]["anonymous"] = observed["lastHttpStatus"]
            api("/v1/project", key="fixture-invalid-key", expected=(401, 403))
            observed["authentication"]["invalidKey"] = observed["lastHttpStatus"]
            old_default = api("/v1/user/login", method="POST", form=True,
                body={"username": "admin", "password": "admin"}, expected=(401,))
            if old_default != b"INVALID_CREDENTIALS":
                raise QualificationFailure("default-admin-not-precisely-refused")
            policy_proof["defaultLoginRefusal"] = old_default.decode()
            observed["authentication"]["oldDefault"] = observed["lastHttpStatus"]
            bearer = api("/v1/user/login", method="POST", form=True,
                         body={"username": "admin", "password": new_password}).decode()
            observed["authentication"]["adminLogin"] = observed["lastHttpStatus"]
            teams = json.loads(api("/v1/team", bearer=bearer))
            if not any(team["name"] == "Administrators" for team in teams):
                raise QualificationFailure("stock-administrator-team-absent")
            ingestor = json.loads(api("/v1/team", method="PUT", body={"name": "isolated-qualification-ingestor"},
                                     bearer=bearer, record=False))
            permissions = ["BOM_UPLOAD", "PORTFOLIO_MANAGEMENT", "VIEW_PORTFOLIO"]
            for permission in permissions:
                api("/v1/permission/" + permission + "/team/" + ingestor["uuid"], method="POST",
                    bearer=bearer, record=False)
            assigned = json.loads(api("/v1/team/" + ingestor["uuid"], bearer=bearer, record=False))
            observed["ingestorPermissions"] = sorted(permission["name"] for permission in assigned["permissions"])
            if observed["ingestorPermissions"] != permissions:
                raise QualificationFailure("ingestor-permission-boundary")
            key = json.loads(api("/v1/team/" + ingestor["uuid"] + "/key", method="PUT", bearer=bearer))["key"]
            first_projection = project_credentials(key, secrets.token_urlsafe(36))
            first_projected_values = {name: (credential_directory / name).read_bytes() for name in ("api-key", "github-token")}
            key = json.loads(api("/v1/team/" + ingestor["uuid"] + "/key", method="PUT", bearer=bearer, record=False))["key"]
            projected_github = secrets.token_urlsafe(36)
            second_projection = project_credentials(key, projected_github)
            last_good_projection = {name: (credential_directory / name).read_bytes() for name in ("api-key", "github-token")}
            k("-n", "dependency-track", "patch", "secret/dependency-track-sync", "--type=json",
              "-p", '[{"op":"remove","path":"/data/github-token"}]')
            missing_projection = run([settings["credentialStage"]], timeout=60, check=False)
            retained_projection = all((credential_directory / name).read_bytes() == value for name, value in last_good_projection.items())
            if missing_projection.returncode == 0 or not retained_projection:
                raise QualificationFailure("missing-secret-key-did-not-preserve-projection")
            import base64
            k("-n", "dependency-track", "patch", "secret/dependency-track-sync", "--type=merge",
              "--patch-file=/dev/stdin", data=json.dumps({"data": {"github-token": base64.b64encode(projected_github.encode()).decode()}}).encode())
            observed["credentialProjection"] = {
                "script": settings["credentialStage"], "first": first_projection, "second": second_projection,
                "rotatedApiKey": last_good_projection["api-key"] != first_projected_values["api-key"],
                "rotatedGithubToken": last_good_projection["github-token"] != first_projected_values["github-token"],
                "missingKeyExit": missing_projection.returncode, "lastGoodPreserved": retained_projection,
            }
            api("/v1/team", key=key, expected=(401, 403), record=False)
            observed["restrictedAdminStatus"] = observed["lastHttpStatus"]
            check("exact-credential-projection-rotation-and-missing-key-refusal")
            d("exec", "-i", name, "sh", "-ec",
              "install -d -m 0700 -o 705 -g 705 /run/fixture-ingestor-credentials; "
              "umask 077; cat > /run/fixture-ingestor-credentials/api-key; "
              "chown 705:705 /run/fixture-ingestor-credentials/api-key; chmod 0400 /run/fixture-ingestor-credentials/api-key",
              data=key.encode())
            file_key = d("exec", "--user", "705:705", name, "cat", "/run/fixture-ingestor-credentials/api-key").stdout.decode()
            observed["keyFileMatches"] = file_key == key
            key = file_key
            observed["uid"] = int(d("exec", "--user", "705:705", name, "id", "-u").stdout)
            observed["kubeconfigReadExit"] = d("exec", "--user", "705:705", name, "sh", "-ec", "test -r /etc/rancher/k3s/k3s.yaml", check=False).returncode
            if not observed["keyFileMatches"] or observed["uid"] != 705 or observed["kubeconfigReadExit"] != 1:
                raise QualificationFailure("importer-credential-boundary-failed")
            check("same-guest-root-broker-uid705-file-key-without-kubeconfig")
            project = json.loads(api("/v1/project", method="PUT", key=key,
                                     body={"name": "isolated-retained-fixture", "version": "1", "active": True}))
            project_uuid = str(uuid.UUID(project["uuid"]))
            observed["projectUuidValid"] = project_uuid == project["uuid"]
            check("anonymous-and-invalid-key-refused-authenticated-project-created")
            phase = "packet-policy"
            client_image = next(obj["spec"]["template"]["spec"]["containers"][0]["image"] for obj in bootstrap["items"]
                                if obj["kind"] == "Deployment" and obj["metadata"]["name"] == "dependency-track-postgres")
            apply({"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "fixture-client", "namespace": "dependency-track", "labels": {"qualification": "client"}},
                   "spec": {"automountServiceAccountToken": False, "containers": [{"name": "client", "image": client_image,
                             "command": ["/bin/sh", "-c", "sleep 3600"]}]}})
            k("-n", "dependency-track", "wait", "--for=condition=Ready", "pod/fixture-client", "--timeout=120s", timeout=140)
            target = pod_ip("api")

            def connection(port=8080):
                probe = k("-n", "dependency-track", "exec", "fixture-client", "--", "/bin/sh", "-c",
                          'wget -S -T 3 -O /dev/null "http://$1:$2/api/v1/project"', "sh", target, str(port), check=False)
                diagnostic = probe.stdout + probe.stderr
                if b"HTTP/1.1 401" in diagnostic or b"HTTP/1.0 401" in diagnostic:
                    return "http-unauthorized"
                if probe.returncode != 0 and (b"timed out" in diagnostic.lower() or b"connection refused" in diagnostic.lower()):
                    return "connection-refused"
                raise QualificationFailure("unexpected-network-result")

            wait(lambda: connection() == "connection-refused", 30)
            observed["network"] = {"default": connection()}
            overlay = {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
                       "metadata": {"name": "fixture-only-api-ingress", "namespace": "dependency-track"},
                       "spec": {"podSelector": {"matchLabels": {"app.kubernetes.io/name": "dependency-track-api"}},
                                "policyTypes": ["Ingress"], "ingress": [{"from": [{"podSelector": {"matchLabels": {"qualification": "client"}}}],
                                                                         "ports": [{"protocol": "TCP", "port": 8080}]}]}}
            apply(overlay)
            wait(lambda: connection() == "http-unauthorized", 30)
            observed["network"]["admitted"] = connection()
            observed["network"]["management"] = connection(9000)
            if observed["network"]["management"] != "connection-refused":
                raise QualificationFailure("management-port-admitted")
            denied_database = k("-n", "dependency-track", "exec", "fixture-client", "--",
                                "pg_isready", "-h", pod_ip("postgres"), "-U", "dtrack", "-d", "dtrack", "-t", "3", check=False)
            observed["network"]["databaseExit"] = denied_database.returncode
            if denied_database.returncode != 2 or b"no response" not in denied_database.stdout:
                raise QualificationFailure("database-client-not-denied")
            k("-n", "dependency-track", "delete", "networkpolicy/fixture-only-api-ingress")
            wait(lambda: connection() == "connection-refused", 30)
            observed["network"]["removed"] = connection()
            check("api-database-management-deny-exact-fixture-api-admission-then-deny")
            phase = "real-producer-refresh"
            start_host_forward()
            ingestor_temporary = tempfile.TemporaryDirectory(prefix="homelab-dt-ingestor-")
            ingestor_home = Path(ingestor_temporary.name)
            for lookup in (pwd.getpwnam, grp.getgrnam):
                try:
                    lookup(account_name)
                except KeyError:
                    pass
                else:
                    raise QualificationFailure("fixture-identity-name-already-exists")
            account_group_owned = True
            run([settings["groupadd"], "--gid", "705", account_name])
            account_user_owned = True
            run([settings["useradd"], "--system", "--uid", "705", "--gid", "705", "--groups", "",
                 "--no-create-home", "--home-dir", str(ingestor_home), "--shell", settings["nonLoginShell"], account_name])
            os.chown(ingestor_home, 705, 705)
            for path in (ingestor_home / "credentials", ingestor_home / "tmp"):
                path.mkdir(mode=0o700)
                os.chown(path, 705, 705)
            key_file = ingestor_home / "credentials/api-key"
            token_file = ingestor_home / "credentials/github-token"
            key_file.write_bytes((credential_directory / "api-key").read_bytes())
            token_file.write_text(sync.credential(args.github_token_file))
            for path in (key_file, token_file):
                path.chmod(0o400)
                os.chown(path, 705, 705)
            refresh_state = ingestor_home / "state"
            api_origin = "http://127.0.0.1:" + str(host_api_port)
            stock = sync.Client(api_origin, key_file)
            declarations = settings["qualificationTargets"]
            target_ids = [declarations[name]["id"] for name in ("host", "oci")]
            command_base = [
                settings["sync"], "refresh", "--api-url", api_origin, "--api-key-file", str(key_file),
                "--state-dir", str(refresh_state), "--repository", settings["repository"],
                "--github-token-file", str(token_file), "--timeout", "180",
            ]
            cli_environment = {key: value for key, value in env.items() if key not in ("KUBECONFIG", "DOCKER_CONFIG")}
            cli_environment.update(HOME=str(ingestor_home), TMPDIR=str(ingestor_home / "tmp"), USER=account_name, LOGNAME=account_name)
            observed["cliUid"] = int(run([settings["id"], "-u"], user=705, environment=cli_environment).stdout)
            observed["cliGroups"] = [int(group) for group in run([settings["id"], "-G"], user=705, environment=cli_environment).stdout.split()]
            observed["cliKubeconfigReadExit"] = run([settings["cat"], str(config_path)], user=705, environment=cli_environment, check=False).returncode
            if observed["cliUid"] != 705 or observed["cliGroups"] != [705] or observed["cliKubeconfigReadExit"] == 0:
                raise QualificationFailure("actual-ingestor-identity-or-kubeconfig-isolation")

            pinned_run = None
            def call_refresh(branch=args.producer_branch, targets=target_ids, age=604800):
                command = [*command_base, "--branch", branch, "--max-age-seconds", str(age)]
                if pinned_run is not None:
                    command += ["--run-id", str(pinned_run)]
                for declaration_id in targets:
                    command += ["--target", declaration_id]
                state = refresh_state / "state.json"
                previous_attempt = sync.load(state).get("refresh", {}).get("at") if state.exists() else None
                result = run(command, timeout=1800, check=False, user=705, environment=cli_environment)
                if result.returncode:
                    state = refresh_state / "state.json"
                    failed = sync.load(state).get("refresh", {}) if state.exists() else {}
                    updated = failed.get("at") != previous_attempt
                    current = failed if updated else {}
                    classified = re.fullmatch(
                        rb"dependency-track-sync failed: (PermissionError|BlockingIOError|FileNotFoundError|OSError|TypeError|KeyError|AttributeError)\n?",
                        result.stderr)
                    receipt["refreshFailure"] = {
                        "exitCode": result.returncode, "journalPresent": state.exists(),
                        "journalUpdated": updated,
                        "operation": current.get("operation"), "errorType": (
                            classified[1].decode() if classified else current.get("errorType")),
                        "run": current.get("run"), "errorCategories": safe_error_categories(result.stderr),
                        "targets": [
                            {"target": target, **{key: record.get(key) for key in
                             ("status", "operation", "errorType", "httpStatus")}}
                            for target, record in list(current.get("targets", {}).items())[:8]
                        ],
                    }
                else:
                    receipt.pop("refreshFailure", None)
                return result

            first_refresh = call_refresh()
            if first_refresh.returncode:
                receipt["refreshFailure"]["attempt"] = "first"
                raise QualificationFailure("actual-refresh-failed", operation="inventory-refresh", exit_code=first_refresh.returncode)
            first_snapshot = refresh_snapshot(refresh_state, stock)
            pinned_run = first_snapshot["producer"]["run"]
            second_refresh = call_refresh()
            if second_refresh.returncode:
                receipt["refreshFailure"]["attempt"] = "repeat"
                raise QualificationFailure("actual-refresh-repeat-failed", operation="inventory-refresh", exit_code=second_refresh.returncode)
            second_snapshot = refresh_snapshot(refresh_state, stock)
            if first_snapshot["storage"]["artifacts"] != second_snapshot["storage"]["artifacts"]:
                raise QualificationFailure("same-run-repeat-duplicated-artifact-cache")
            if (first_snapshot["stableIdentity"] != second_snapshot["stableIdentity"]
                    or first_snapshot["producer"] != second_snapshot["producer"]):
                raise QualificationFailure("refresh-repeat-changed-identities-or-producer")
            known_ids = {entry["source"]["id"] for entry in sync.load(refresh_state / "state.json")["expected"].values()}
            absent_id = next(f"{number:024x}" for number in range(1024) if f"{number:024x}" not in known_ids)
            wrong_branch = "qualification-refused-source-branch"
            if wrong_branch == args.producer_branch:
                wrong_branch += "-other"
            negatives = []
            for reason, branch, targets, age, diagnostic in (
                ("source-policy", wrong_branch, target_ids, 604800, b"state belongs to another source trust policy"),
                ("stale-producer", args.producer_branch, target_ids, 1, b"stale or future-dated"),
                ("absent-target", args.producer_branch, [absent_id], 604800, b"configured target IDs are absent"),
            ):
                rejected = call_refresh(branch, targets, age)
                if rejected.returncode == 0 or diagnostic not in rejected.stderr:
                    raise QualificationFailure("refresh-negative-not-refused-for-required-reason")
                retained = refresh_snapshot(refresh_state, stock, complete=False)
                unchanged = retained["stableIdentity"] == first_snapshot["stableIdentity"]
                if not unchanged:
                    raise QualificationFailure("refresh-negative-replaced-last-good")
                negatives.append({"reason": reason, "exitCode": rejected.returncode, "lastGoodPreserved": unchanged,
                                  "coverageStatus": retained["refreshStatus"]})
            recovered_refresh = call_refresh()
            if recovered_refresh.returncode:
                raise QualificationFailure("refresh-recovery-failed", operation="inventory-refresh", exit_code=recovered_refresh.returncode)
            recovered_snapshot = refresh_snapshot(refresh_state, stock)
            if recovered_snapshot["stableIdentity"] != first_snapshot["stableIdentity"]:
                raise QualificationFailure("refresh-recovery-changed-last-good-identities")
            receipt["refresh"] = {
                "executable": settings["sync"], "repository": settings["repository"],
                "branch": args.producer_branch, "mainProducerQualified": args.producer_branch == "main",
                "pinnedRun": pinned_run,
                "deployment": "unobserved", "boundary": "isolated stock API consuming exactly two admitted public declarations",
                "firstExitCode": first_refresh.returncode, "repeatExitCode": second_refresh.returncode,
                "recoveryExitCode": recovered_refresh.returncode, "first": first_snapshot, "repeat": second_snapshot,
                "recovered": recovered_snapshot, "negatives": negatives,
            }
            receipt["refresh"]["repeatStorageGrowthBytes"] = {
                category: second_snapshot["storage"][category]["bytes"] - first_snapshot["storage"][category]["bytes"]
                for category in STORAGE_CATEGORIES
            }
            check("real-producer-restricted-refresh-repeat-and-refusals-retain-last-good")
            phase = "retained-restart"
            key_path = "/srv/dependency-track/api/.dependency-track/keys/secret-management-kek.json"
            original_keyset = hashlib.sha256(native("cat", key_path).stdout).digest()
            stop_forward()
            deployment("api", 0)
            deployment("postgres", 0)
            apply(private_restore())
            for component in ("postgres", "api"):
                deployment(component, 1)
            start_forward()
            observed["restartProjectMatches"] = json.loads(api("/v1/project/" + project_uuid, key=key))["uuid"] == project_uuid
            if not observed["restartProjectMatches"]:
                raise QualificationFailure("project-identity-changed")
            observed["restartKeysetMatches"] = hashlib.sha256(native("cat", key_path).stdout).digest() == original_keyset
            if not observed["restartKeysetMatches"]:
                raise QualificationFailure("keyset-changed")
            check("restore-phase-restart-retains-project-key-and-keyset")
            restarted_snapshot = refresh_snapshot(refresh_state, stock)
            observed["refreshRetainedAcrossRestart"] = restarted_snapshot["stableIdentity"] == first_snapshot["stableIdentity"]
            if not observed["refreshRetainedAcrossRestart"]:
                raise QualificationFailure("real-refresh-identities-changed-on-restart")
            # Stock 5.2.1 e6c887c: ExtensionsResource resolves x-secret-ref before
            # EmailNotificationPublisherFactory.test returns for enabled=false.
            # API-key authentication alone only exercises SECRET_HASH, not Crypto.
            witness_name = "restore_ciphertext_witness"
            ciphertext = {}
            observed["retainedCiphertext"] = ciphertext

            def witness_record():
                # Private comparison only: never publish ciphertext, DEK, or hashes.
                record = pg("""SELECT json_build_array("NAME", encode("VALUE", 'hex'),
                    encode("DEK", 'hex'), "CREATED_AT", "UPDATED_AT")
                    FROM "SECRET" WHERE "NAME" = 'restore_ciphertext_witness'
                    AND octet_length("VALUE") > 0 AND octet_length("DEK") > 0;""").stdout.strip()
                if not record:
                    raise QualificationFailure("retained-secret-record-missing")
                return hashlib.sha256(record).digest()


            def consume_witness(admin_session, *, wrong_key=False):
                reference_exists = json.loads(api("/v2/secrets/" + witness_name, bearer=admin_session,
                    expected=(200,), record=False)).get("name") == witness_name
                record_unchanged = witness_record() == original_witness
                if not reference_exists or not record_unchanged:
                    raise QualificationFailure("retained-secret-reference-or-ciphertext-changed")
                result = api("/v2/extension-points/notification-publisher/extensions/email/test",
                    method="POST", bearer=admin_session,
                    body={"config": {"enabled": False, "password": witness_name}},
                    expected=tuple(range(500, 600)) if wrong_key else (200,), record=False)
                proof = {"status": observed["lastHttpStatus"], "referenceExists": reference_exists,
                         "recordUnchanged": record_unchanged}
                if not wrong_key:
                    checks = json.loads(result).get("checks")
                    if (not isinstance(checks, list) or len(checks) != 1
                            or checks[0].get("name") != "connection"
                            or checks[0].get("status") != "SKIPPED"):
                        raise QualificationFailure("disabled-retained-secret-consumer-result-mismatch")
                    proof["connection"] = "SKIPPED"
                if witness_record() != original_witness:
                    raise QualificationFailure("retained-secret-consumer-mutated-ciphertext")
                return proof

            bearer = api("/v1/user/login", method="POST", form=True,
                body={"username": "admin", "password": new_password}, record=False).decode()
            try:
                api("/v2/secrets", method="POST", bearer=bearer,
                    body={"name": witness_name, "value": "synthetic-noncredential-restore-witness"},
                    expected=(201,), record=False)
                ciphertext["createStatus"] = observed["lastHttpStatus"]
                original_witness = witness_record()
                ciphertext["beforeBackup"] = consume_witness(bearer)
            finally:
                api("/v1/user/logout", method="POST", bearer=bearer, record=False)
            phase = "offline-backup-restore"
            stop_forward()
            deployment("api", 0)
            deployment("postgres", 0)
            retained_metadata = retained_tree(refresh_state)
            native("mkdir", "-p", "/srv/dependency-track/evidence/sync-state")
            d("cp", "-a", str(refresh_state) + "/.", name + ":/srv/dependency-track/evidence/sync-state", timeout=600)
            native("chown", "705:705", "/srv/dependency-track/evidence/sync-state")
            native("chmod", "0700", "/srv/dependency-track/evidence/sync-state")
            native("sh", "-ec", "umask 077; mkdir -m 0700 /run/fixture-dt-backup; printf '%s' synthetic-fixture-evidence > /srv/dependency-track/evidence/witness; tar -C /srv -cpf /run/fixture-dt-backup/state.tar dependency-track")
            backup_file = work / "retained-backup.tar"
            d("cp", name + ":/run/fixture-dt-backup/state.tar", str(backup_file), timeout=600)
            backup_file.chmod(0o600)
            native("rm", "/run/fixture-dt-backup/state.tar")
            shutil.rmtree(refresh_state)
            if refresh_state.exists():
                raise QualificationFailure("real-refresh-journal-not-destroyed")
            destroyed = native("sh", "-ec", "rm -rf /srv/dependency-track; test ! -e /srv/dependency-track")
            d("cp", str(backup_file), name + ":/run/fixture-dt-backup/state.tar", timeout=600)
            archive_restore = native("sh", "-ec", "tar -C /srv -xpf /run/fixture-dt-backup/state.tar; rm /run/fixture-dt-backup/state.tar")
            refresh_state.mkdir(mode=0o700)
            evidence_archive = work / "restored-evidence.tar"
            with evidence_archive.open("xb") as archive_output:
                os.fchmod(archive_output.fileno(), 0o600)
                exported = subprocess.run(
                    [*docker, "exec", name, "tar", "-C", "/srv/dependency-track/evidence/sync-state", "-cpf", "-", "."],
                    stdout=archive_output, stderr=subprocess.DEVNULL, env=env, timeout=600)
            if exported.returncode:
                raise QualificationFailure("retained-evidence-export-failed", operation="docker-exec",
                                           exit_code=exported.returncode)
            # Docker's container-to-host cp -a drops numeric ownership.
            extract_retained_tree(evidence_archive, refresh_state)
            evidence_archive.unlink()
            observed["retainedEvidenceMetadataMatches"] = retained_tree(refresh_state) == retained_metadata
            if not observed["retainedEvidenceMetadataMatches"]:
                raise QualificationFailure("retained-evidence-owner-mode-or-bytes-changed")
            observed["backupDestroyedAndRestored"] = destroyed.returncode == 0 and archive_restore.returncode == 0
            k("-n", "dependency-track", "delete", "secret/dependency-track-postgres")
            apply(secret)
            for component in ("postgres", "api"):
                deployment(component, 1)
            start_forward()
            observed["restoreProjectMatches"] = json.loads(api("/v1/project/" + project_uuid, key=key))["uuid"] == project_uuid
            if not observed["restoreProjectMatches"]:
                raise QualificationFailure("restored-project-identity-changed")
            observed["restoreKeysetMatches"] = hashlib.sha256(native("cat", key_path).stdout).digest() == original_keyset
            if not observed["restoreKeysetMatches"]:
                raise QualificationFailure("restored-keyset-changed")
            observed["canonicalEvidenceMatches"] = native("cat", "/srv/dependency-track/evidence/witness").stdout == b"synthetic-fixture-evidence"
            if not observed["canonicalEvidenceMatches"]:
                raise QualificationFailure("canonical-evidence-not-restored")
            api("/v1/project", expected=(401, 403))
            bearer = api("/v1/user/login", method="POST", form=True,
                body={"username": "admin", "password": new_password}, record=False).decode()
            try:
                ciphertext["afterColdRestore"] = consume_witness(bearer)
            finally:
                api("/v1/user/logout", method="POST", bearer=bearer, record=False)
            check("offline-backup-destroy-restore-retains-auth-uuid-keyset-and-evidence")
            restored_refresh = call_refresh()
            if restored_refresh.returncode:
                raise QualificationFailure("real-refresh-cannot-resume-restored-journal",
                                           operation="inventory-refresh", exit_code=restored_refresh.returncode)
            receipt["refresh"]["postRestoreExitCode"] = restored_refresh.returncode
            restored_snapshot = refresh_snapshot(refresh_state, stock)
            receipt["refresh"]["postRestore"] = restored_snapshot
            observed["refreshRetainedAcrossBackupRestore"] = restored_snapshot["stableIdentity"] == first_snapshot["stableIdentity"]
            if not observed["refreshRetainedAcrossBackupRestore"]:
                raise QualificationFailure("real-refresh-identities-changed-on-backup-restore")
            phase = "same-id-wrong-key-ciphertext-recovery"
            stop_forward()
            deployment("api", 0)  # No API writers may retain the original in-memory KEK.
            original_keyset_bytes = native("cat", key_path).stdout
            if hashlib.sha256(original_keyset_bytes).digest() != original_keyset:
                raise QualificationFailure("wrong-key-original-keyset-changed")
            wrong_keyset = json.loads(original_keyset_bytes)
            entries = wrong_keyset.get("key", [])
            if len(entries) != 1:
                raise QualificationFailure("wrong-key-fixture-requires-stock-single-key")
            entry = entries[0]
            key_data = entry.get("keyData", {})
            if (entry.get("keyId") != wrong_keyset.get("primaryKeyId")
                    or entry.get("status") != "ENABLED" or entry.get("outputPrefixType") != "TINK"
                    or key_data.get("typeUrl") != "type.googleapis.com/google.crypto.tink.AesGcmKey"
                    or key_data.get("keyMaterialType") != "SYMMETRIC"):
                raise QualificationFailure("wrong-key-fixture-requires-stock-aes256-gcm")
            encoded_key = base64.b64decode(key_data["value"], validate=True)
            # Crypto.loadKek generates AES256_GCM. Tink's proto3 AesGcmKey
            # omits version=0 and encodes key_value (field 3) as 1a 20 + 32 bytes:
            # https://github.com/tink-crypto/tink-java/blob/main/proto/aes_gcm.proto
            # This is a deliberately narrow fixture edit, NOT a Tink validator.
            # Actual stock startup/getPrimitive plus real servlet/probes below
            # must accept it; unknown shapes fail, never fall back or skip.
            if len(encoded_key) != 34 or encoded_key[:2] != b"\x1a\x20":
                raise QualificationFailure("wrong-key-fixture-unexpected-stock-key-encoding")
            key_data["value"] = base64.b64encode(encoded_key[:-1] + bytes([encoded_key[-1] ^ 1])).decode()
            wrong_keyset_bytes = json.dumps(wrong_keyset).encode()
            wrong = {
                "keyIdsUnchanged": (wrong_keyset["primaryKeyId"] == json.loads(original_keyset_bytes)["primaryKeyId"]
                    and [item["keyId"] for item in entries]
                    == [item["keyId"] for item in json.loads(original_keyset_bytes)["key"]]),
                "keyMaterialChanged": key_data["value"] != json.loads(original_keyset_bytes)["key"][0]["keyData"]["value"],
            }
            ciphertext["validWrongKey"] = wrong
            if not wrong["keyIdsUnchanged"] or not wrong["keyMaterialChanged"]:
                raise QualificationFailure("wrong-key-fixture-did-not-preserve-ids-and-change-material")
            native("mv", key_path, key_path + ".saved")
            try:
                native("cp", "-p", key_path + ".saved", key_path)
                d("exec", "-i", name, "sh", "-ec", 'cat > "$1"', "fixture-keyset", key_path,
                  data=wrong_keyset_bytes, operation="write-fixture-same-id-wrong-keyset")
                deployment("api", 1)  # Stock parses keyset and constructs its Tink AEAD primitive.
                start_forward()
                pod = api_pod()
                wrong["podReady"] = any(condition.get("type") == "Ready" and condition.get("status") == "True"
                                        for condition in pod["status"].get("conditions", []))
                guard = next(item for item in pod["status"]["initContainerStatuses"]
                             if item["name"] == "require-restored-api-keyset")
                wrong["initGuardExit"] = guard["state"]["terminated"]["exitCode"]
                container = next(item for item in pod["spec"]["containers"] if item["name"] == "api")
                for probe in ("startupProbe", "readinessProbe"):
                    wrong[probe + "Exit"] = k("-n", "dependency-track", "exec", pod["metadata"]["name"],
                        "-c", "api", "--", *container[probe]["exec"]["command"], check=False).returncode
                api("/version", expected=(200,), record=False)
                wrong["apiVersionStatus"] = observed["lastHttpStatus"]
                wrong["authenticatedProjectMatches"] = (
                    json.loads(api("/v1/project/" + project_uuid, key=key, expected=(200,), record=False))["uuid"]
                    == project_uuid
                )
                if (not wrong["podReady"] or wrong["initGuardExit"] != 0
                        or wrong["startupProbeExit"] != 0 or wrong["readinessProbeExit"] != 0
                        or not wrong["authenticatedProjectMatches"]):
                    raise QualificationFailure("valid-wrong-key-stock-initialization-or-project-failed")
                bearer = api("/v1/user/login", method="POST", form=True,
                    body={"username": "admin", "password": new_password}, record=False).decode()
                try:
                    wrong.update(consume_witness(bearer, wrong_key=True))
                finally:
                    api("/v1/user/logout", method="POST", bearer=bearer, record=False)
                wrong["wrongBytesUnchanged"] = native("cat", key_path).stdout == wrong_keyset_bytes
                if not wrong["wrongBytesUnchanged"]:
                    raise QualificationFailure("valid-wrong-key-bytes-rewritten")
            finally:
                stop_forward()
                deployment("api", 0)
                native("mv", key_path + ".saved", key_path)
                ciphertext["exactOriginalBytesRestored"] = native("cat", key_path).stdout == original_keyset_bytes
                if not ciphertext["exactOriginalBytesRestored"]:
                    raise QualificationFailure("wrong-key-exact-original-not-restored")
                deployment("api", 1)
                start_forward()
                ciphertext["authenticatedProjectRecovered"] = (
                    json.loads(api("/v1/project/" + project_uuid, key=key, expected=(200,), record=False))["uuid"]
                    == project_uuid
                )
                if not ciphertext["authenticatedProjectRecovered"]:
                    raise QualificationFailure("wrong-key-original-project-not-recovered")
                bearer = api("/v1/user/login", method="POST", form=True,
                    body={"username": "admin", "password": new_password}, record=False).decode()
                try:
                    ciphertext["afterOriginalKeyRestore"] = consume_witness(bearer)
                finally:
                    api("/v1/user/logout", method="POST", bearer=bearer, record=False)
                ciphertext["exactOriginalBytesRestored"] = native("cat", key_path).stdout == original_keyset_bytes
                if not ciphertext["exactOriginalBytesRestored"]:
                    raise QualificationFailure("recovered-original-keyset-bytes-rewritten")
            check("retained-secret-ciphertext-cold-restore-same-id-wrong-key-refusal-and-exact-recovery")
            phase = "restore-refusal"
            stop_forward()
            deployment("api", 0)
            native("mv", key_path, key_path + ".saved")
            k("-n", "dependency-track", "scale", "deployment/dependency-track-api", "--replicas=1")

            def container_refused(component, container_name, init=False):
                pods = json.loads(k("-n", "dependency-track", "get", "pod", "-l", "app.kubernetes.io/name=dependency-track-" + component, "-o", "json").stdout)
                for pod in pods["items"]:
                    for status in pod.get("status", {}).get("initContainerStatuses" if init else "containerStatuses", []):
                        if status["name"] == container_name:
                            state = status.get("state", {}).get("terminated") or status.get("lastState", {}).get("terminated") or {}
                            if state.get("exitCode", 0) != 0:
                                observed["refusedExits"][container_name] = state["exitCode"]
                                return True
                return False

            wait(lambda: container_refused("api", "require-restored-api-keyset", init=True), 90)
            observed["missingKeysetUnchanged"] = native("test", "!", "-e", key_path, check=False).returncode == 0
            if not observed["missingKeysetUnchanged"]:
                raise QualificationFailure("missing-keyset-regenerated")
            deployment("api", 0)
            native("mv", key_path + ".saved", key_path)
            pg("ALTER ROLE dtrack SUPERUSER;")
            k("-n", "dependency-track", "scale", "deployment/dependency-track-api", "--replicas=1")
            wait(lambda: container_refused("api", "require-restricted-database-role", init=True), 90)
            deployment("api", 0)
            pg("ALTER ROLE dtrack NOSUPERUSER;")
            deployment("api", 1)
            start_forward()
            api("/v1/project/" + project_uuid, key=key)
            check("restore-refuses-missing-keyset-and-privileged-role-then-recovers")
            phase = "malformed-keyset-restore"
            stop_forward()
            deployment("api", 0)
            native("mv", key_path, key_path + ".saved")
            native("cp", "-p", key_path + ".saved", key_path)
            d("exec", "-i", name, "sh", "-ec", 'cat > "$1"', "fixture-keyset", key_path,
              data=MALFORMED_KEYSET, operation="write-fixture-malformed-keyset")
            malformed = {"nonemptyGuardExit": native("test", "-s", key_path, check=False).returncode}
            observed["malformedKeyset"] = malformed
            if malformed["nonemptyGuardExit"] != 0:
                raise QualificationFailure("malformed-keyset-fixture-was-empty")
            apply(private_restore())

            def malformed_admission_refused():
                malformed["corruptBytesUnchanged"] = native("cat", key_path).stdout == MALFORMED_KEYSET
                if not malformed["corruptBytesUnchanged"]:
                    raise QualificationFailure("malformed-keyset-rewritten")
                pods = json.loads(k("-n", "dependency-track", "get", "pod", "-l",
                                    "app.kubernetes.io/name=dependency-track-api", "-o", "json").stdout)
                for pod in pods["items"]:
                    status = pod.get("status", {})
                    guard = next((item.get("state", {}).get("terminated", {})
                                  for item in status.get("initContainerStatuses", [])
                                  if item.get("name") == "require-restored-api-keyset"), {})
                    application = next((item for item in status.get("containerStatuses", [])
                                        if item.get("name") == "api"), {})
                    if guard.get("exitCode") != 0 or not application.get("state", {}).get("running"):
                        continue
                    pod_name = pod["metadata"]["name"]
                    command = ("-n", "dependency-track", "exec", pod_name, "-c", "api", "--")
                    logs = k("-n", "dependency-track", "logs", pod_name, "-c", "api",
                             "--tail=100", "--limit-bytes=32768", check=False)
                    malformed["cryptoInitializationRejected"] = (
                        logs.returncode == 0
                        and "api-keyset-crypto-invalid" in safe_error_categories(logs.stdout)
                    )
                    if not malformed["cryptoInitializationRejected"]:
                        continue
                    malformed.update(initGuardExit=guard["exitCode"], applicationRunning=True,
                                     podReady=any(condition.get("type") == "Ready" and condition.get("status") == "True"
                                                  for condition in status.get("conditions", [])))
                    for field, port, path in (
                        ("managementStartedExit", 9000, "/health/started"),
                        ("managementReadyExit", 9000, "/health/ready"),
                        ("apiVersionExit", 8080, "/api/version"),
                    ):
                        malformed[field] = k(*command, "wget", "-q", "-Y", "off", "-T", "2",
                                             "-O", "/dev/null", f"http://127.0.0.1:{port}{path}", check=False).returncode
                    # Execute the exact rendered production probes, not a substitute.
                    container = next(item for item in pod["spec"]["containers"] if item["name"] == "api")
                    for probe in ("startupProbe", "readinessProbe"):
                        malformed[probe + "Exit"] = k(*command, *container[probe]["exec"]["command"],
                                                       check=False).returncode
                    events = json.loads(k("-n", "dependency-track", "get", "events", "--field-selector",
                                          "involvedObject.uid=" + pod["metadata"]["uid"] + ",reason=Unhealthy",
                                          "-o", "json").stdout)
                    malformed["startupProbeFailureObserved"] = any(
                        event.get("message", "").startswith("Startup probe failed:") for event in events["items"]
                    )
                    return (
                        malformed["podReady"] is False
                        and malformed["startupProbeFailureObserved"]
                        and malformed["managementStartedExit"] == malformed["managementReadyExit"] == 0
                        and all(0 < malformed[field] < 126
                                for field in ("apiVersionExit", "startupProbeExit", "readinessProbeExit"))
                    )
                return False

            wait(malformed_admission_refused, 180, reason="malformed-keyset-admission-did-not-refuse")
            deployment("api", 0)
            malformed["corruptBytesUnchanged"] = native("cat", key_path).stdout == MALFORMED_KEYSET
            if not malformed["corruptBytesUnchanged"]:
                raise QualificationFailure("malformed-keyset-rewritten")
            native("mv", key_path + ".saved", key_path)
            malformed["originalRestored"] = hashlib.sha256(native("cat", key_path).stdout).digest() == original_keyset
            deployment("api", 1)
            start_forward()
            malformed["authenticatedProjectRecovered"] = (
                json.loads(api("/v1/project/" + project_uuid, key=key, record=False))["uuid"] == project_uuid
            )
            if not malformed["originalRestored"] or not malformed["authenticatedProjectRecovered"]:
                raise QualificationFailure("malformed-keyset-original-state-not-recovered")
            check("restore-refuses-malformed-nonempty-keyset-without-rewrite-then-recovers")
            phase = "restore-refusal"
            stop_forward()
            deployment("api", 0)
            deployment("postgres", 0)
            pg_version = "/srv/dependency-track/postgres/18/docker/PG_VERSION"
            native("mv", pg_version, pg_version + ".saved")
            k("-n", "dependency-track", "scale", "deployment/dependency-track-postgres", "--replicas=1")
            wait(lambda: container_refused("postgres", "postgres"), 90)
            observed["missingPostgresUnchanged"] = native("test", "!", "-e", pg_version, check=False).returncode == 0
            if not observed["missingPostgresUnchanged"]:
                raise QualificationFailure("missing-database-state-reinitialized")
            deployment("postgres", 0)
            native("mv", pg_version + ".saved", pg_version)
            deployment("postgres", 1)
            deployment("api", 1)
            start_forward()
            api("/v1/project/" + project_uuid, key=key)
            check("restore-refuses-missing-database-version-without-reinitializing")
            phase = "native-access-pod-readmission"
            previous_uid = api_pod()["metadata"]["uid"]
            policy_proof["previousPodUID"] = previous_uid
            stop_forward()
            deployment("api", 0)
            k("-n", "dependency-track", "scale", "deployment/dependency-track-api", "--replicas=1")
            wait(api_pod_ready, seconds=620, reason="recreated-api-container-not-ready")
            policy_proof["recreatedPodUID"] = api_pod()["metadata"]["uid"]
            if policy_proof["recreatedPodUID"] == previous_uid or admitted():
                raise QualificationFailure("recreated-pod-inherited-admission")
            policy_proof["recreatedPodGateway"] = gateway_closed()
            reconcile_access()
            policy_proof["validatedPodUID"] = api_pod()["metadata"]["uid"]
            start_forward()
            start_host_forward()
            inspection_admin = api("/v1/user/login", method="POST", form=True,
                body={"username": "admin", "password": new_password}, record=False).decode()
            try:
                alternate = json.loads(api("/v1/team", method="PUT",
                    body={"name": "fixture-alternate-privileged-team"}, bearer=inspection_admin, record=False))
                api("/v1/permission/VIEW_PORTFOLIO/team/" + alternate["uuid"],
                    method="POST", bearer=inspection_admin, record=False)
                unexpected = json.loads(api("/v1/oidc/group", method="PUT",
                    body={"name": "fixture-unapproved-administrators"}, bearer=inspection_admin, record=False))
                api("/v1/oidc/mapping", method="PUT",
                    body={"team": alternate["uuid"], "group": unexpected["uuid"]},
                    bearer=inspection_admin, record=False)
                reconcile_access()
                refused_bindings = {}
                for permission in ("ACCESS_MANAGEMENT", "ACCESS_MANAGEMENT_CREATE", "ACCESS_MANAGEMENT_UPDATE"):
                    permission_path = "/v1/permission/" + permission + "/team/" + alternate["uuid"]
                    api(permission_path, method="POST", bearer=inspection_admin, record=False)
                    reconcile_access(succeeds=False)
                    refused_bindings[permission] = gateway_closed()
                    api(permission_path, method="DELETE", bearer=inspection_admin, record=False)
                    reconcile_access()
                policy_proof["alternatePrivilegedBindings"] = refused_bindings
            finally:
                api("/v1/user/logout", method="POST", bearer=inspection_admin, record=False)
            # Exercise the CLI's actual managed-session owner against stock DT,
            # including exception exit, then try those exact revoked sessions.
            client = sync.Client("http://127.0.0.1:" + str(host_api_port), anonymous=True)
            for fail_inside in (False, True):
                try:
                    with sync.managed_session(client, new_password):
                        session_token = client.key
                        if client.request("GET", "user/self")["username"] != "admin":
                            raise QualificationFailure("managed-session-wrong-actor")
                        if fail_inside:
                            raise RuntimeError("fixture-owned-session-exception")
                except RuntimeError as error:
                    if str(error) != "fixture-owned-session-exception":
                        raise
                api("/v1/user/self", bearer=session_token, expected=(401,), record=False)
            policy_proof["successAndFailureSessionLogout"] = True
            check("native-root-access-policy-bootstrap-restore-and-pod-uid-readmission")
            phase = "native-browser-oidc"
            deployment("frontend", 1)
            mounts = k("-n", "dependency-track", "exec", "deployment/dependency-track-frontend",
                       "--", "/bin/cat", "/proc/self/mountinfo").stdout.decode().splitlines()
            mount_options = {fields[4]: fields[5].split(",")
                             for line in mounts if len(fields := line.split()) >= 6}
            observed["frontendReadOnlyRoot"] = "ro" in mount_options.get("/", [])
            observed["frontendReadOnlyConfig"] = "ro" in mount_options.get(
                "/opt/owasp/dependency-track-frontend/static/config.json", [])
            if not observed["frontendReadOnlyRoot"] or not observed["frontendReadOnlyConfig"]:
                raise QualificationFailure("native-frontend-filesystem-not-readonly")
            bearer = api("/v1/user/login", method="POST", form=True,
                         body={"username": "admin", "password": new_password}, record=False).decode()
            qualify_browser(recovery_password, bearer)
            policy_proof["finalPodUID"] = api_pod()["metadata"]["uid"]
            policy_proof["finalPodAdmitted"] = admitted() and endpoints_ready()
            if not policy_proof["finalPodAdmitted"]:
                raise QualificationFailure("final-native-pod-not-admitted")
            api("/v1/user/logout", method="POST", bearer=bearer, record=False)
            check("native-trusted-browser-public-pkce-admin-denial-logout-and-group-removal")
            success = True
        except Exception as error:
            # Native messages and traceback locals can contain credentials or response bodies.
            receipt["failure"] = safe_failure(error, phase)
            receipt["failureOperations"] = list(receipt.get("operations", []))
            capture_failure_diagnostics()
        finally:
            cleanup = True
            for process in oidc_processes:
                try:
                    if process.poll() is None:
                        if process.args[0] == settings["nsenter"]:
                            os.killpg(process.pid, signal.SIGTERM)
                        else:
                            process.terminate()
                    try:
                        process.wait(timeout=20)
                    except subprocess.TimeoutExpired:
                        if process.args[0] == settings["nsenter"]:
                            os.killpg(process.pid, signal.SIGKILL)
                        else:
                            process.kill()
                        process.wait(timeout=10)
                    if process.stdout is not None:
                        process.stdout.close()
                except Exception:
                    cleanup = False
            receipt["cleanupWitness"]["nativeProcessesRemoved"] = all(
                process.poll() is not None for process in oidc_processes)
            for group in notifier_groups:
                if notifier_group_alive(group):
                    try:
                        os.killpg(group, signal.SIGKILL)
                        wait(lambda: not notifier_group_alive(group), seconds=10,
                             reason="failure-notification-proxy-cleanup-timeout")
                    except Exception:
                        cleanup = False
            receipt["cleanupWitness"]["failureProxyRemoved"] = all(
                not notifier_group_alive(group) for group in notifier_groups)
            for path in reversed(owned_host_paths):
                try:
                    shutil.rmtree(path)
                except OSError:
                    cleanup = False
            try:
                stop_forward()
            except Exception:
                cleanup = False
            for kind, identity, attempted in (("container", name, created), ("network", network, network_created)):
                if not attempted:
                    continue
                try:
                    inspected = d(kind, "inspect", identity, check=False)
                    if inspected.returncode:
                        cleanup = resource_absent(kind, identity) and cleanup
                        continue
                    owned = json.loads(inspected.stdout)[0]
                    volumes = [mount["Name"] for mount in owned.get("Mounts", []) if mount.get("Type") == "volume"] if kind == "container" else []
                    labels = (owned.get("Config", {}).get("Labels") if kind == "container" else owned.get("Labels")) or {}
                    if labels.get("verification.homelab/fixture") != token:
                        cleanup = False
                        continue
                    options = ["--force", "--volumes"] if kind == "container" else []
                    removed = d(kind, "rm", *options, identity, check=False, timeout=120).returncode == 0
                    removed = removed and resource_absent(kind, identity)
                    receipt["cleanupWitness"][kind + "Removed"] = removed
                    cleanup = removed and cleanup
                    if kind == "container":
                        volumes_removed = all(resource_absent("volume", volume) for volume in volumes)
                        receipt["cleanupWitness"]["volumesRemoved"] = volumes_removed
                        cleanup = cleanup and volumes_removed
                except Exception:
                    cleanup = False
            # Removing the owned K3s node and its volumes also removes every
            # namespace/ephemeral volume if a failure interrupted explicit deletion.
            receipt["cleanupWitness"]["alertmanagerRemoved"] = (
                receipt["cleanupWitness"].get("alertmanagerRemoved", not alertmanager_created)
                or (receipt["cleanupWitness"]["containerRemoved"] and receipt["cleanupWitness"]["volumesRemoved"])
            )
            identity_removed = True
            if account_user_owned:
                try:
                    user = pwd.getpwnam(account_name)
                except KeyError:
                    pass
                else:
                    if (user.pw_name != account_name or user.pw_uid != 705 or user.pw_gid != 705
                            or user.pw_dir != str(ingestor_home) or user.pw_shell != settings["nonLoginShell"]):
                        identity_removed = False
                    else:
                        try:
                            identity_removed = run([settings["userdel"], account_name], check=False).returncode == 0
                        except Exception:
                            identity_removed = False
            if account_group_owned:
                try:
                    group = grp.getgrnam(account_name)
                except KeyError:
                    pass
                else:
                    if group.gr_name != account_name or group.gr_gid != 705 or set(group.gr_mem) - {account_name}:
                        identity_removed = False
                    else:
                        try:
                            identity_removed = run([settings["groupdel"], account_name], check=False).returncode == 0 and identity_removed
                        except Exception:
                            identity_removed = False
            for lookup in (pwd.getpwuid, grp.getgrgid):
                try:
                    lookup(705)
                except KeyError:
                    pass
                else:
                    identity_removed = False
            receipt["cleanupWitness"]["identityRemoved"] = identity_removed
            if ingestor_temporary is not None:
                try:
                    ingestor_temporary.cleanup()
                except OSError:
                    cleanup = False
            cleanup = cleanup and identity_removed
            receipt["cleanup"] = cleanup
    receipt["cleanupWitness"]["credentialsRemoved"] = (
        not work.exists() and (ingestor_temporary is None or not Path(ingestor_temporary.name).exists())
        and not any(os.path.lexists(path) for path in (
            credential_directory, staged_directory, Path("/run/dependency-track-sync-api-tunnel")))
        and receipt["cleanupWitness"]["containerRemoved"] and receipt["cleanupWitness"]["volumesRemoved"]
    )
    observed["hostPortBoundaryUnchanged"] = int(Path("/proc/sys/net/ipv4/ip_unprivileged_port_start").read_text()) == host_port_boundary
    receipt["cleanup"] = receipt["cleanup"] and observed["hostPortBoundaryUnchanged"]
    receipt["cleanup"] = receipt["cleanup"] and all(receipt["cleanupWitness"].values())
    receipt["status"] = "passed" if success and receipt["cleanup"] else "failed"
    if receipt["status"] == "passed":
        try:
            validate_report(receipt, settings, args.producer_branch)
        except (ValueError, TypeError, KeyError, AttributeError, RecursionError) as error:
            receipt.update(status="failed", failure=safe_failure(error, "report-validation"))
    json.dump(receipt, output, indent=2, sort_keys=True)
    output.write("\n")
    output.close()
    print(json.dumps(receipt, sort_keys=True))
    return 0 if receipt["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
