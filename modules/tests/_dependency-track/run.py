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
from datetime import datetime, timezone
import time
from types import SimpleNamespace
import urllib.parse
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
    "restore-refuses-missing-keyset-and-privileged-role-then-recovers",
    "restore-refuses-malformed-nonempty-keyset-without-rewrite-then-recovers",
    "restore-refuses-missing-database-version-without-reinitializing",
]

MALFORMED_KEYSET = b"fixture-malformed-nonempty-keyset\n"
STORAGE_CATEGORIES = ("archive", "acquisitions", "origins", "artifacts")
SAFE_ERROR_SIGNATURES = {
    "permission-denied": b"permission denied",
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
}
SAFE_CONTAINER_REASONS = {
    "Completed", "Error", "OOMKilled", "CrashLoopBackOff", "ContainerCannotRun",
    "RunContainerError", "CreateContainerConfigError", "InvalidImageName", "ErrImagePull",
    "ImagePullBackOff", "CreateContainerError", "PodInitializing", "ContainerCreating",
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
    return {"phase": phase, "operation": "fixture-observation", "reason": reason}


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
    paths = [Path(settings[key]) for key in ("bootstrap", "restore", "retained")]
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
    section = "malformed-nonempty-keyset-restore"
    malformed = observed.get("malformedKeyset", {})
    require(malformed.get("nonemptyGuardExit") == 0 and type(malformed.get("nonemptyGuardExit")) is int)
    require(malformed.get("initGuardExit") == 0 and type(malformed.get("initGuardExit")) is int)
    require(malformed.get("applicationStarted") is True)
    require(type(malformed.get("applicationExit")) is int and 0 < malformed["applicationExit"] < 126)
    require(malformed.get("applicationReason") == "Error")
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
    require(set(refused) == {"require-restored-api-keyset", "require-restricted-database-role", "api", "postgres"})
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
                             "identityRemoved", "failureProxyRemoved", "alertmanagerRemoved"})
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
                               "No advisory bulk import, fleet sizing, browser flow or production credential enrollment",
                               "Fixture-only API ingress overlay proves packet enforcement, not an admitted fleet route",
                               "Local PV capacities are declarations, not filesystem quotas; tiny fixture does not prove production disk sizing"]}
    receipt["limitations"].append("Exact projection/getter/rotation and705 transport only; envelope reconciler and systemd lifecycle are not executed")
    receipt["limitations"].append("Storage counts are logical regular-file bytes per retained path, not physical allocation or a capacity proof")
    receipt["limitations"].append("Exact root notifier with null receivers only; no systemd sandbox/lifecycle or provider delivery proof")
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
            if not owned_host_paths:
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
            config_path = work / "kubeconfig"
            config_path.write_text(yaml.safe_dump(kubeconfig))
            config_path.chmod(0o600)
            env["KUBECONFIG"] = str(config_path)
            versions = json.loads(k("version", "-o", "json").stdout)
            if versions["clientVersion"]["gitVersion"] != version or versions["serverVersion"]["gitVersion"] != version:
                raise QualificationFailure("source-client-server-version-mismatch")
            receipt["versions"]["sourceClient"] = versions["clientVersion"]["gitVersion"]
            for index, image in enumerate(sorted(images)):
                archive = work / (str(index) + ".tar")
                d("save", "-o", str(archive), image, timeout=600)
                destination = "/tmp/fixture-image.tar"
                d("cp", str(archive), name + ":" + destination, timeout=600)
                native("ctr", "--address", "/run/k3s/containerd/containerd.sock", "--namespace", "k8s.io",
                       "images", "import", destination, timeout=600)
                native("rm", "-f", destination)
                archive.unlink()
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
            for component in ("postgres", "api", "frontend"):
                deployment(component, 1)
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
            new_password = secrets.token_urlsafe(36)
            api("/v1/user/forceChangePassword", method="POST", form=True,
                body={"username": "admin", "password": "admin", "newPassword": new_password,
                      "confirmPassword": new_password})
            api("/v1/user/login", method="POST", form=True,
                body={"username": "admin", "password": "admin"}, expected=(401, 403))
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
                result = run(command, timeout=1800, check=False, user=705, environment=cli_environment)
                if result.returncode:
                    state = refresh_state / "state.json"
                    failed = sync.load(state).get("refresh", {}) if state.exists() else {}
                    receipt["refreshFailure"] = {
                        "exitCode": result.returncode, "journalPresent": state.exists(),
                        "operation": failed.get("operation"), "errorType": failed.get("errorType"),
                        "run": failed.get("run"), "errorCategories": safe_error_categories(result.stderr),
                        "targets": [
                            {"target": target, **{key: record.get(key) for key in
                             ("status", "operation", "errorType", "httpStatus")}}
                            for target, record in list(failed.get("targets", {}).items())[:8]
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
            apply(json.loads(Path(settings["restore"]).read_text()))
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
            phase = "offline-backup-restore"
            stop_forward()
            deployment("api", 0)
            deployment("postgres", 0)
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
            os.chown(refresh_state, 705, 705)
            d("cp", "-a", name + ":/srv/dependency-track/evidence/sync-state/.", str(refresh_state), timeout=600)
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
            api("/v1/user/login", method="POST", form=True,
                body={"username": "admin", "password": new_password})
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
            apply(json.loads(Path(settings["restore"]).read_text()))

            def malformed_application_refused():
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
                    for item in status.get("containerStatuses", []):
                        if item.get("name") != "api":
                            continue
                        terminated = item.get("state", {}).get("terminated") or item.get("lastState", {}).get("terminated") or {}
                        code = terminated.get("exitCode")
                        if (guard.get("exitCode") == 0 and type(code) is int and 0 < code < 126
                                and terminated.get("reason") == "Error" and terminated.get("startedAt")):
                            malformed.update(applicationExit=code, applicationReason="Error",
                                             initGuardExit=guard["exitCode"], applicationStarted=bool(terminated["startedAt"]))
                            observed["refusedExits"]["api"] = code
                            return True
                return False

            wait(malformed_application_refused, 180, reason="malformed-keyset-application-did-not-refuse")
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
            success = True
        except Exception as error:
            # Native messages and traceback locals can contain credentials or response bodies.
            receipt["failure"] = safe_failure(error, phase)
            receipt["failureOperations"] = list(receipt.get("operations", []))
            capture_failure_diagnostics()
        finally:
            cleanup = True
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
        and not any(os.path.lexists(path) for path in (credential_directory, staged_directory))
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
