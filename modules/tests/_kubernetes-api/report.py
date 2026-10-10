"""Fail closed on named safety scenarios, not incidental operation counts."""

# Independent of fixture discovery and supplied settings: missing a family or
# selecting a smaller fixture cannot redefine full acceptance.
REQUIRED_SCENARIOS = [
    "gateway-cel-admission",
    "argo-01-child-gating-recovery",
    "argo-02-retained-hook-sequencing",
    "argo-03-workload-self-heal",
    "argo-04-git-omission",
    "argo-05-direct-retirement",
    "argo-06-root-child-retirement",
    "runtime-secret-initial-exact-ack",
    "runtime-secret-missing-desired-inventory",
    "runtime-secret-stale-desired-inventory",
    "runtime-secret-malformed-desired-inventory",
    "runtime-secret-malformed-owned-inventory",
    "runtime-secret-duplicate-owned-inventory",
    "runtime-secret-failed-uid-recording-keeps-ack",
    "runtime-secret-ssa-uid",
    "runtime-secret-empty-generation-relinquishes-only-owned-fields",
    "runtime-secret-matching-uid-shared-owner-tls-retirement",
    "runtime-secret-matching-uid-sole-owner-tls-retirement",
    "runtime-secret-projected-mode-zero-unreadable",
    "runtime-secret-fsgroup-readable",
    "gateway-current-generation-status",
    "gateway-direct-source-spoofing",
    "gateway-trusted-cni-source-boundary",
    "gateway-referencegrant-deny-restore",
    "gateway-backend-name-deny-restore",
    "gateway-backend-ca-deny-restore",
    "gateway-real-webauthn-authorization",
    "gateway-access-error-log-privacy",
]


ARGO_CRDS = ("applications.argoproj.io", "appprojects.argoproj.io", "applicationsets.argoproj.io")
ARGO_RECOVERY_APPS = ("failed-child", "missing-child", "failed-root", "missing-root")
ARGO_RECOVERY_JOBS = ("failed-child-late", "missing-child-late")
ARGO_RETAINED_APPS = ("hook",)
ARGO_ROOT_RETIREMENT_APPS = ("retained", "retirement-root")


def argo_recovery_witness(raw, raw_jobs, fixture_sources, app_names=ARGO_RECOVERY_APPS):
    """Diagnostic state only: omit messages, credentials, URLs and arbitrary text."""
    def enum(value, allowed):
        return value if value in allowed else "unknown"

    def revision(value):
        if isinstance(value, str):
            if len(value) == 40 and all(char in "0123456789abcdef" for char in value):
                return value
            return "non-sha"
        return "missing"

    health_states = ("Healthy", "Degraded", "Progressing", "Suspended", "Missing", "Unknown")
    sync_states = ("Synced", "OutOfSync", "Unknown")
    if raw.get("kind") == "Application":
        items = [raw]
    else:
        items = raw.get("items") or []
    objects = {(obj.get("metadata") or {}).get("name"): obj for obj in items}
    applications = []
    for name in app_names:
        if name not in (*ARGO_RECOVERY_APPS, *ARGO_RETAINED_APPS, *ARGO_ROOT_RETIREMENT_APPS):
            continue
        obj = objects.get(name, {})
        metadata = obj.get("metadata") or {}
        source = (obj.get("spec") or {}).get("source") or {}
        status = obj.get("status") or {}
        sync = status.get("sync") or {}
        operation = status.get("operationState") or {}
        generation = metadata.get("generation")
        applications.append({
            "name": name,
            "present": name in objects,
            "generation": generation if type(generation) is int and generation >= 0 else None,
            "sourceMatchesFixture": source == fixture_sources.get(name) if obj else False,
            "desiredRevision": revision(source.get("targetRevision")),
            "syncRevision": revision(sync.get("revision")),
            "operationRevision": revision((operation.get("syncResult") or {}).get("revision")),
            "comparedSourceMatchesDesired": ((sync.get("comparedTo") or {}).get("source") == source) if obj else False,
            "syncStatus": enum(sync.get("status"), sync_states),
            "healthStatus": enum((status.get("health") or {}).get("status"), health_states),
            "operationPhase": enum(operation.get("phase"), ("Running", "Terminating", "Failed", "Error", "Succeeded")),
            "comparisonErrorPresent": any(condition.get("type") == "ComparisonError" for condition in status.get("conditions") or []),
            "comparisonErrorCategories": sorted({
                classify_comparison_error(condition.get("message"))
                for condition in status.get("conditions") or []
                if isinstance(condition, dict) and condition.get("type") == "ComparisonError"
            }),
            "comparisonErrorMarkers": sorted({
                marker
                for condition in status.get("conditions") or []
                if isinstance(condition, dict) and condition.get("type") == "ComparisonError"
                for marker in comparison_error_markers(condition.get("message"))
            }),
        })
        if name in ARGO_ROOT_RETIREMENT_APPS:
            expected = fixture_sources.get(name)
            compared = (sync.get("comparedTo") or {}).get("source")
            conditions = status.get("conditions")
            finalizers = metadata.get("finalizers")
            applications[-1].update({
                "expectedRevision": revision((expected or {}).get("targetRevision")),
                "sourceMatchesFixture": source == expected if obj and source and expected else None,
                "comparedSourceMatchesDesired": compared == source if obj and source and isinstance(compared, dict) else None,
                "conditionsShape": "missing" if "conditions" not in status else "null" if conditions is None else "list" if isinstance(conditions, list) else "unexpected",
                "conditionTypes": sorted({enum(condition.get("type"), (
                    "ComparisonError", "InvalidSpecError", "SyncError", "UnknownError",
                    "SharedResourceWarning", "RepeatedResourceWarning", "ExcludedResourceWarning",
                    "OrphanedResourceWarning", "DeletionError", "ApplicationMissingWarning",
                )) for condition in conditions if isinstance(condition, dict)}) if isinstance(conditions, list) else None,
                "comparisonErrorPresent": any(isinstance(condition, dict) and condition.get("type") == "ComparisonError" for condition in conditions) if isinstance(conditions, list) else None,
                "deletionTimestampPresent": metadata.get("deletionTimestamp") is not None if obj else None,
                "finalizersShape": "missing" if "finalizers" not in metadata else "null" if finalizers is None else "list" if isinstance(finalizers, list) else "unexpected",
                "finalizerCount": len(finalizers) if isinstance(finalizers, list) else None,
                "finalizerCategories": sorted({
                    "argo-foreground" if value == "resources-finalizer.argocd.argoproj.io" else
                    "argo-background" if value == "resources-finalizer.argocd.argoproj.io/background" else "other"
                    for value in finalizers
                }) if isinstance(finalizers, list) else None,
            })
    objects = {obj["metadata"]["name"]: obj for obj in raw_jobs.get("items") or []}
    jobs = []
    for name in ARGO_RECOVERY_JOBS:
        obj = objects.get(name, {})
        uid = (obj.get("metadata") or {}).get("uid")
        safe_uid = isinstance(uid, str) and len(uid) == 36 and all(
            char == "-" if index in (8, 13, 18, 23) else char in "0123456789abcdef"
            for index, char in enumerate(uid)
        )
        jobs.append({
            "name": name,
            "present": name in objects,
            "uid": uid if safe_uid else "unknown",
            "conditions": [
                {"type": condition["type"], "status": enum(condition.get("status"), ("True", "False", "Unknown"))}
                for condition in (obj.get("status") or {}).get("conditions") or []
                if condition.get("type") in ("Complete", "Failed")
            ],
        })
    return {"applications": applications, "lateJobs": jobs}


def capture_retained_witness():
    """Capture safe owned hook or selected root state before native cleanup."""
    import json
    import os
    from pathlib import Path
    import subprocess

    if os.environ.get("FIXTURE_ARGO_WITNESS") == "root-retirement":
        capture_root_retirement_witness()
        return

    work = Path(os.environ["FIXTURE_WORK"]) / "argo"
    try:
        settings = json.loads(Path(os.environ["FIXTURE_SETTINGS"]).read_text())
        result = subprocess.run([
            settings["kubectl"],
            "-n", "argocd", "get", "application", "hook", "--ignore-not-found",
            "-o", "json", "--request-timeout=10s",
        ], capture_output=True, text=True, timeout=15, check=False)
        if result.returncode:
            witness = {"status": "unavailable", "returnCode": result.returncode,
                       "errorCategory": classify_kubectl_error(result.stderr)}
        else:
            raw = json.loads(result.stdout) if result.stdout.strip() else {}
            initial = (work / "initial").read_text().strip()
            source = {"repoURL": f"git://{os.environ['FIXTURE_ARGO_GIT_IP']}/runtime.git",
                      "path": "hook", "targetRevision": initial}
            witness = {
                "status": "observed",
                "responseShape": "list" if "items" in raw else "single" if raw.get("kind") == "Application" else "empty",
                "applications": argo_recovery_witness(raw, {}, {"hook": source}, ARGO_RETAINED_APPS)["applications"],
            }
            operation = (raw.get("status") or {}).get("operationState") or {}
            outcomes = (operation.get("syncResult") or {}).get("resources") or []
            messages = " ".join(str(value) for value in [
                operation.get("message", ""),
                *(item.get("message", "") for item in outcomes if item.get("kind") == "Job" and item.get("name") in ("retained-directories", "after-retained-hook")),
            ]).lower()
            witness["hookOperationHints"] = [name for name, marker in (
                ("immutable-field", "field is immutable"),
                ("delete-failed", "failed to delete"),
                ("create-failed", "failed to create"),
                ("namespace-missing", "namespace"),
                ("forbidden", "forbidden"),
                ("not-found", "not found"),
                ("operation-conflict", "operation is already"),
                ("deletion-in-progress", "being deleted"),
                ("namespace-terminating", "terminating"),
                ("validation", "invalid"),
                ("resource-exists", "already exists"),
                ("timeout", "timeout"),
                ("deadline", "deadline exceeded"),
            ) if marker in messages]
            witness["hookResourceOutcomes"] = [
                {"name": item["name"],
                 "status": item.get("status") if item.get("status") in ("Synced", "SyncFailed", "PruneSkipped", "Pruned") else "unknown",
                 "hookPhase": item.get("hookPhase") if item.get("hookPhase") in ("Pending", "Running", "Succeeded", "Failed", "Error") else "unknown"}
                for item in outcomes if item.get("kind") == "Job" and item.get("name") in ("retained-directories", "after-retained-hook")
            ]
            try:
                job_probe = subprocess.run([
                    settings["kubectl"], "-n", "local-path-storage", "get",
                    "job", "retained-directories", "--ignore-not-found",
                    "-o", "json", "--request-timeout=10s",
                ], capture_output=True, text=True, timeout=15, check=False)
                job = json.loads(job_probe.stdout) if job_probe.returncode == 0 and job_probe.stdout.strip() else {}
                uid_file = work / "hook.uid"
                witness["retainedJob"] = {
                    "returnCode": job_probe.returncode,
                    "present": bool(job) if job_probe.returncode == 0 else None,
                    "sameInitialUid": (job.get("metadata") or {}).get("uid") == uid_file.read_text().strip() if job and uid_file.exists() else None,
                    "failed": any(item.get("type") == "Failed" and item.get("status") == "True" for item in (job.get("status") or {}).get("conditions") or []) if job_probe.returncode == 0 else None,
                }
                logs = subprocess.run([
                    settings["kubectl"], "-n", "local-path-storage", "logs",
                    "job/retained-directories", "--tail=40", "--request-timeout=10s",
                ], capture_output=True, text=True, timeout=15, check=False)
                witness["retainedConsumer"] = {
                    "returnCode": logs.returncode,
                    "errorCategory": classify_kubectl_error(logs.stderr) if logs.returncode else None,
                    "hints": [name for name, marker in (
                        ("missing-marker", "state root marker"),
                        ("ownership-mode-mismatch", "not repairing"),
                        ("permission-denied", "permission denied"),
                        ("readonly-filesystem", "read-only file system"),
                        ("invalid-entry", "invalid entries"),
                        ("invalid-arguments", "usage: retained-directories"),
                    ) if marker in logs.stdout.lower()],
                }
            except Exception as diagnostic_error:
                witness["retainedConsumer"] = {"status": "unavailable", "type": type(diagnostic_error).__name__}
    except Exception as error:
        witness = {"status": "unavailable", "type": type(error).__name__}
    witness["capturePhase"] = "native-catch-before-cleanup"
    (work / "hook-witness.json").write_text(json.dumps(witness))


def capture_root_retirement_witness():
    """Bounded owned root/child state inside native catch, never raw API output."""
    import json
    import os
    from pathlib import Path
    import subprocess

    work = Path(os.environ["FIXTURE_WORK"]) / "argo"
    try:
        settings = json.loads(Path(os.environ["FIXTURE_SETTINGS"]).read_text())
        result = subprocess.run([
            settings["kubectl"], "-n", "argocd", "get", "application",
            *ARGO_ROOT_RETIREMENT_APPS, "--ignore-not-found",
            "-o", "json", "--request-timeout=10s",
        ], capture_output=True, text=True, timeout=15, check=False)
        if result.returncode:
            witness = {"status": "unavailable", "returnCode": result.returncode,
                       "errorCategory": classify_kubectl_error(result.stderr)}
        else:
            raw = json.loads(result.stdout) if result.stdout.strip() else {}
            sources = {}
            git_ip = os.environ.get("FIXTURE_ARGO_GIT_IP")
            for name, pin in (("retained", "rootPayload"), ("retirement-root", "retirementRoot")):
                revision_file = work / pin
                if revision_file.exists() and git_ip:
                    sources[name] = {"repoURL": f"git://{git_ip}/runtime.git",
                                     "path": name, "targetRevision": revision_file.read_text().strip()}
            witness = {
                "status": "observed",
                "responseShape": "list" if "items" in raw else "single" if raw.get("kind") == "Application" else "empty",
                "applications": argo_recovery_witness(raw, {}, sources, ARGO_ROOT_RETIREMENT_APPS)["applications"],
            }
    except Exception as error:
        witness = {"status": "unavailable", "type": type(error).__name__}
    witness["capturePhase"] = "native-catch-before-cleanup"
    (work / "root-retirement-witness.json").write_text(json.dumps(witness))


def classify_kubectl_error(stderr):
    """Diagnostic hint only; never return native error text or policy verdicts."""
    text = stderr[-16384:].lower()
    if "status.conditions" in text and "accessor error" in text:
        return "condition-shape"
    for category, markers in (
        ("condition-timeout", ("timed out waiting for the condition",)),
        ("not-found", ("(notfound)", "no matching resources found")),
        ("forbidden", ("(forbidden)",)),
        ("transport-or-tls", ("x509:", "unable to connect to the server", "connection refused")),
        ("client-argument", ("unknown flag:", "expected resource", "must be specified")),
        ("api-discovery", ("the server doesn't have a resource type", "couldn't get current server api group list")),
    ):
        if any(marker in text for marker in markers):
            return category
    return "unclassified"


def classify_docker_error(stderr):
    """Diagnostic hint only for failed Docker commands; never native text."""
    text = stderr[-16384:].lower()
    for category, markers in (
        ("disk-full", ("no space left",)),
        ("image-store", ("content digest", "failed to unpack", "snapshotter", "unexpected eof", "invalid tar", "archive/tar")),
        ("static-address", ("user configured subnets", "no configured subnet")),
        ("missing-path", ("no such file or directory", "could not find the file")),
        ("container-state", ("is not running", "no such container", "is paused", "is restarting")),
        ("port-conflict", ("port is already allocated", "address already in use")),
        ("address-pool", ("pool overlaps", "non-overlapping", "no available network")),
        ("name-conflict", ("is already in use by container", "already exists")),
        ("cgroup", ("cgroup",)),
        ("permission", ("permission denied", "operation not permitted")),
        ("rate-limited", ("toomanyrequests", "rate limit")),
        ("unauthorized", ("unauthorized", "authentication required", "access denied")),
        ("not-found", ("manifest unknown", "not found", "no such image")),
        ("platform", ("no matching manifest", "specified platform", "does not match the platform")),
        ("network", ("timeout", "timed out", "connection refused", "connection reset", "no such host", "tls:", "x509:", "eof")),
    ):
        if any(marker in text for marker in markers):
            return category
    return "unclassified"


def classify_comparison_error(message):
    """Fixed category for an Argo ComparisonError; never the message itself."""
    text = message.lower() if isinstance(message, str) else ""
    for category, markers in (
        ("connection-refused", ("connection refused",)),
        ("timeout", ("timeout", "timed out", "deadline exceeded")),
        ("unreachable", ("no route to host", "network is unreachable", "no such host")),
        ("repository-missing", ("repository not found", "does not appear to be a git repository", "not a git repository")),
        ("revision-missing", ("unable to resolve", "reference not found", "not our ref", "couldn't find remote ref")),
        ("path-missing", ("app path does not exist", "no such file or directory")),
        ("permission", ("permission denied", "is not permitted", "not permitted in project")),
        ("manifest-generation", ("failed to unmarshal", "error unmarshaling", "manifest generation")),
    ):
        if any(marker in text for marker in markers):
            return category
    return "unclassified"


COMPARISON_MARKERS = (
    "rpc error", "code = unavailable", "code = unknown", "code = internal", "code = deadlineexceeded",
    "failed to fetch", "failed to list refs", "ls-remote", "exit status 128", "unable to connect",
    "dial tcp", "connection reset", "connection refused", "i/o timeout", "context deadline", "eof",
    "no such host", "lookup", "x509", "tls", "authentication", "dubious ownership", "safe.directory",
    "repository not found", "not exported", "access denied", "not permitted in project", "is forbidden", "permission denied",
    "app path does not exist", "does not exist", "manifest generation", "unmarshal", "unknown field",
    "kustomize", "helm", "directory", "redis", "cache", "repo-server", "failed to load target state",
    "failed to generate manifest", "invalid", "unsupported", "too large", "out of memory", "killed",
)


def comparison_error_markers(message):
    """Which fixed phrases occur in an Argo ComparisonError; never the message itself."""
    text = message.lower() if isinstance(message, str) else ""
    return [marker for marker in COMPARISON_MARKERS if marker in text]


def crd_condition_witness(raw):
    """Readonly diagnostic fields from three owned CRDs; not a readiness gate."""
    objects = {obj["metadata"]["name"]: obj for obj in raw.get("items") or []}
    result = []
    for name in ARGO_CRDS:
        status = objects.get(name, {}).get("status") or {}
        conditions = status.get("conditions")
        result.append({
            "name": name,
            "present": name in objects,
            "conditionsShape": "missing" if "conditions" not in status else "null" if conditions is None else "list" if isinstance(conditions, list) else "unexpected",
            "conditions": [
                {"type": condition["type"], "status": condition["status"]}
                for condition in conditions if condition.get("type") in ("Established", "NamesAccepted") and condition.get("status") in ("True", "False", "Unknown")
            ] if isinstance(conditions, list) else [],
        })
    return result


def sanitize_tests(tests):
    """Retain only approved identities and indexed native status fields."""
    def status(value):
        return value if value in ("passed", "failed", "skipped") else "unknown"

    return [
        {
            "name": test.get("name") if test.get("name") in REQUIRED_SCENARIOS else "unexpected",
            "status": status(test.get("status")),
            "steps": [
                {
                    "index": step_index + 1,
                    "status": status(step.get("status")),
                    "operations": [
                        {
                            "index": operation_index + 1,
                            "type": operation.get("type") if operation.get("type") in ("apply", "assert", "script", "command", "delete", "error", "patch", "get") else "unknown",
                            "status": status(operation.get("status")),
                            "hasFailure": bool(operation.get("failure")),
                        }
                        for operation_index, operation in enumerate(step.get("operations") or [])
                    ],
                }
                for step_index, step in enumerate(test.get("steps") or [])
            ],
        }
        for test in tests
    ]


def check_report(raw, required):
    if not required or len(required) != len(set(required)):
        raise ValueError("required-scenario-inventory")
    tests = raw.get("tests") or []
    names = [test.get("name") for test in tests]
    if len(names) != len(required) or set(names) != set(required):
        raise ValueError("scenario-coverage")
    for test in tests:
        steps = test.get("steps") or []
        if not steps:
            raise ValueError("step-coverage")
        if test.get("status") != "passed" or any(
            step.get("status") != "passed"
            or not step.get("operations")
            or any(op.get("status") != "passed" or op.get("failure") for op in step["operations"])
            for step in steps
        ):
            raise ValueError("scenario-failure-or-skip")


def self_check():
    import copy
    import json

    sensitive = "private-credential-marker"
    assert classify_kubectl_error("Error from server (NotFound): " + sensitive) == "not-found"
    assert classify_kubectl_error("x509: " + sensitive) == "transport-or-tls"
    assert sensitive not in classify_kubectl_error(sensitive)
    assert classify_kubectl_error(".status.conditions accessor error: " + sensitive) == "condition-shape"
    assert classify_docker_error("toomanyrequests: " + sensitive) == "rate-limited"
    assert classify_docker_error("dial tcp: i/o timeout") == "network"
    assert classify_docker_error("write /var/lib/docker/x: no space left on device") == "disk-full"
    assert classify_docker_error("failed to unpack image: content digest sha256:00 not found") == "image-store"
    assert sensitive not in classify_docker_error(sensitive)
    assert classify_docker_error("Bind for 127.0.0.1:6443 failed: port is already allocated") == "port-conflict"
    assert classify_docker_error("Error response from daemon: Container abc is not running") == "container-state"
    assert classify_comparison_error("rpc error: dial tcp 10.0.0.1:9418: connect: connection refused " + sensitive) == "connection-refused"
    assert sensitive not in classify_comparison_error(sensitive)
    assert comparison_error_markers("rpc error: dial tcp: i/o timeout " + sensitive) == ["rpc error", "dial tcp", "i/o timeout"]
    witness = crd_condition_witness({"items": [{"metadata": {"name": ARGO_CRDS[0]}, "status": {"conditions": None, "message": sensitive}}]})
    assert witness[0]["conditionsShape"] == "null" and witness[0]["conditions"] == []
    assert witness[1]["conditionsShape"] == "missing" and not witness[1]["present"]
    assert sensitive not in json.dumps(witness)
    source = {"repoURL": sensitive, "targetRevision": "a" * 40}
    job_uid = "12345678-1234-1234-1234-123456789abc"
    recovery = argo_recovery_witness({"items": [{
        "metadata": {"name": "failed-root", "generation": 2, "annotations": {"private": sensitive}},
        "spec": {"source": source},
        "status": {
            "sync": {"revision": "a" * 40, "status": "Synced", "comparedTo": {"source": source}},
            "health": {"status": "Degraded", "message": sensitive},
            "conditions": [{"type": "ComparisonError", "message": sensitive}, {"type": sensitive}],
            "operationState": {"phase": "Failed", "message": sensitive, "syncResult": {
                "revision": "a" * 40, "resources": [{"name": "failed-child", "kind": "Application", "status": "SyncFailed", "message": sensitive}],
            }},
        },
    }, {
        "metadata": {"name": "failed-child", "generation": None},
        "spec": {"source": None},
        "status": {"sync": None, "health": None, "operationState": None, "conditions": None},
    }, {"metadata": {"name": sensitive}}]}, {"items": [{
        "metadata": {"name": "failed-child-late", "uid": job_uid},
        "status": {"conditions": [{"type": "Complete", "status": "True", "message": sensitive}, {"type": sensitive, "status": sensitive}]},
    }, {
        "metadata": {"name": "missing-child-late", "uid": sensitive},
        "status": {"conditions": None},
    }]}, {"failed-root": source})
    assert sensitive not in json.dumps(recovery)
    applications = recovery["applications"]
    assert applications[2]["operationPhase"] == "Failed" and applications[2]["comparedSourceMatchesDesired"]
    assert applications[2]["sourceMatchesFixture"] and applications[2]["comparisonErrorPresent"]
    assert applications[2]["generation"] == 2 and applications[2]["desiredRevision"] == "a" * 40
    assert applications[0]["operationPhase"] == "unknown" and applications[0]["generation"] is None
    assert applications[0]["desiredRevision"] == "missing" and not applications[0]["comparisonErrorPresent"]
    assert not applications[1]["present"]
    assert recovery["lateJobs"][0]["uid"] == job_uid and recovery["lateJobs"][0]["conditions"] == [{"type": "Complete", "status": "True"}]
    assert recovery["lateJobs"][1]["uid"] == "unknown" and recovery["lateJobs"][1]["conditions"] == []
    untrusted = argo_recovery_witness({"items": [{"metadata": {"name": "failed-child"}, "spec": {"source": {"targetRevision": sensitive}}}]}, {}, {})
    assert untrusted["applications"][0]["desiredRevision"] == "non-sha" and sensitive not in json.dumps(untrusted)
    retained = argo_recovery_witness({"items": [{
        "metadata": {"name": "hook", "generation": 3},
        "spec": {"source": source},
        "status": {
            "sync": {"revision": "a" * 40, "status": "Synced", "comparedTo": {"source": source}},
            "health": {"status": "Degraded", "message": sensitive},
            "conditions": None,
            "operationState": {"phase": "Failed", "message": sensitive, "syncResult": {"revision": "a" * 40}},
        },
    }]}, {}, {"hook": source}, ("hook", sensitive))
    assert sensitive not in json.dumps(retained)
    assert len(retained["applications"]) == 1 and retained["applications"][0]["name"] == "hook"
    assert retained["applications"][0]["sourceMatchesFixture"] and retained["applications"][0]["operationPhase"] == "Failed"
    assert not retained["applications"][0]["comparisonErrorPresent"]
    singleton = {"apiVersion": "argoproj.io/v1alpha1", "kind": "Application",
                 "metadata": {"name": "hook"}, "spec": {"source": source},
                 "status": {"conditions": None, "health": {"status": "Degraded", "message": sensitive},
                            "operationState": {"phase": "Failed", "syncResult": {"revision": "a" * 40}}}}
    single_witness = argo_recovery_witness(singleton, {}, {"hook": source}, ARGO_RETAINED_APPS)
    list_witness = argo_recovery_witness({"items": [singleton]}, {}, {"hook": source}, ARGO_RETAINED_APPS)
    assert single_witness == list_witness and single_witness["applications"][0]["present"]
    assert sensitive not in json.dumps(single_witness)
    assert not argo_recovery_witness({}, {}, {}, ARGO_RETAINED_APPS)["applications"][0]["present"]
    raw_test = {"name": sensitive, "status": sensitive, "steps": [{"name": sensitive, "status": "failed", "operations": [{"type": sensitive, "status": "failed", "failure": sensitive, "stdout": sensitive}]}]}
    sanitized = sanitize_tests([raw_test])
    assert sensitive not in json.dumps(sanitized)
    assert sanitized[0]["steps"][0]["operations"][0]["hasFailure"]

    required = ["safety-one", "safety-two"]
    good = {"tests": [{"name": name, "status": "passed", "steps": [{"status": "passed", "operations": [{"status": "passed"}]}]} for name in required]}
    check_report(good, required)
    probes = [None, {}, {"tests": []}, {"tests": good["tests"][:1]}, {"tests": good["tests"] * 2}]
    for path, value in [("test", "skipped"), ("step", "failed"), ("operation", "skipped"), ("operations", []), ("failure", "failure"), ("steps", [])]:
        bad = copy.deepcopy(good)
        test = bad["tests"][0]
        step = test["steps"][0]
        if path == "test":
            test["status"] = value
        elif path == "step":
            step["status"] = value
        elif path == "operation":
            step["operations"][0]["status"] = value
        elif path == "failure":
            step["operations"][0]["failure"] = value
        elif path == "steps":
            test["steps"] = value
        else:
            step["operations"] = value
        probes.append(bad)
    for bad in probes:
        try:
            check_report(bad or {}, required)
        except ValueError:
            continue
        raise AssertionError("incomplete report accepted")


if __name__ == "__main__":
    import sys

    if sys.argv[1:] == ["--capture-retained"]:
        capture_retained_witness()
    elif len(sys.argv) == 1:
        self_check()
    else:
        raise SystemExit("unsupported reporter operation")
