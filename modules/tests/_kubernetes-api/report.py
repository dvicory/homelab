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

GATEWAY_PREREQUISITES = (
    ("GatewayClass", "envoy", ""), ("Gateway", "household", "gateway"),
    ("EnvoyProxy", "household", "gateway"), ("ClientTrafficPolicy", "trusted-edges", "gateway"),
)

ENVOY_READINESS_STATS = (
    "server.state", "control_plane.connected_state",
    "cluster_manager.warming_clusters", "listener_manager.total_listeners_active",
    "listener_manager.total_listeners_warming",
) + tuple("cluster.xds_cluster." + suffix for suffix in (
    "membership_total", "membership_healthy", "update_attempt", "update_success", "update_failure",
    "upstream_cx_active", "upstream_cx_total", "upstream_cx_connect_fail", "upstream_cx_connect_timeout",
    "ssl.handshake", "ssl.connection_error", "ssl.fail_verify_error", "ssl.fail_verify_san",
    "ssl.fail_verify_no_cert",
)) + tuple(prefix + "." + suffix for prefix in ("cluster_manager.cds", "listener_manager.lds")
          for suffix in ("update_attempt", "update_success", "update_failure", "update_rejected", "control_plane.connected_state"))


def containerd_socket_failure(stderr):
    """Project only known dial failures for the fixture's fixed socket."""
    message = stderr[:8192].lower()
    if "/run/k3s/containerd/containerd.sock" in message and (
            "failed to dial" in message or "dial unix" in message):
        for text, category in (
            ("connection refused", "connection-refused"),
            ("no such file or directory", "socket-absent"),
            ("deadline exceeded", "timeout"), ("i/o timeout", "timeout"),
        ):
            if text in message:
                return category
    return "unclassified"


def dns_query_witness(return_code, output, service_ip):
    """Fixed projection only; DNS output may contain private names and addresses."""
    text = output[:4096].decode(errors="replace").lower()
    category = "none" if return_code == 0 else "unclassified"
    if len(output) > 4096:
        category = "response-size-limit"
    elif return_code:
        for match, value in (
            ("no such file", "tool-unavailable"), ("not found", "tool-unavailable"),
            ("operation not permitted", "namespace-denied"), ("nxdomain", "nxdomain"),
            ("servfail", "server-failure"), ("refused", "refused"),
            ("timed out", "timeout"), ("no servers could be reached", "timeout"),
        ):
            if match in text:
                category = value
                break
    answers = text.partition("name:")[2].split()
    return {"returnCode": return_code, "errorCategory": category,
            "answerMatchesXdsService": return_code == 0 and category == "none"
                and isinstance(service_ip, str) and service_ip.lower() in answers}


def bridge_netfilter_witness(module_return_code, hook_return_code, hook_output):
    """Absent/disabled are observed booleans; unreadable probes remain null."""
    return {
        "modulePresent": module_return_code == 0 if type(module_return_code) is int and module_return_code in (0, 1) else None,
        "ipv4HookEnabled": hook_output.strip() == b"1" if type(hook_return_code) is int and hook_return_code == 0 and hook_output.strip() in (b"0", b"1") else None,
    }


def envoy_readiness_witness(server_info, stats):
    """Never export native version text, dynamically named stats or nonnumeric values."""
    state = server_info.get("state")
    values = {stat.get("name"): stat.get("value") for stat in (stats.get("stats") or [])[:64]
              if isinstance(stat, dict) and isinstance(stat.get("name"), str)}
    return {
        "state": state if state in ("LIVE", "DRAINING", "PRE_INITIALIZING", "INITIALIZING") else "unknown",
        "versionMatches": isinstance(server_info.get("version"), str)
            and server_info["version"].split("/")[1:2] == ["1.39.1"],
        "stats": {name: values[name] if type(values.get(name)) is int and 0 <= values[name] <= 2147483647
                  else None for name in ENVOY_READINESS_STATS},
    }


def _optional_array(value):
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError("invalid-array-shape")
    return value


def dns_service_endpoints(slices):
    """The API can serialize an empty EndpointSlice's endpoints as null."""
    items = slices["items"]
    if not isinstance(items, list):
        raise ValueError("invalid-array-shape")
    return [endpoint for item in items for endpoint in _optional_array(item["endpoints"])]


def coredns_workload_witness(workloads):
    """Only CoreDNS's Deployment owner chain; fixed counts/enums, no names or messages."""
    def count(value):
        return value if type(value) is int and 0 <= value <= 2147483647 else None
    def enum(value, allowed):
        return value if isinstance(value, str) and value in allowed else "other"
    def owned(obj, kind, uids):
        return any(owner.get("uid") in uids and owner.get("kind") == kind and owner.get("controller") is True
                   for owner in _optional_array((obj.get("metadata") or {}).get("ownerReferences")))
    objects = workloads["items"]
    if not isinstance(objects, list):
        raise ValueError("invalid-array-shape")
    deployment = next((obj for obj in objects if obj.get("kind") == "Deployment"
                       and (obj.get("metadata") or {}).get("name") == "coredns"), {})
    uid = (deployment.get("metadata") or {}).get("uid")
    replicas = {(obj.get("metadata") or {}).get("uid") for obj in objects
                if uid and obj.get("kind") == "ReplicaSet" and owned(obj, "Deployment", {uid})} - {None}
    pods = [obj for obj in objects if obj.get("kind") == "Pod" and owned(obj, "ReplicaSet", replicas)][:4]
    phases = dict.fromkeys(("Pending", "Running", "Succeeded", "Failed", "Unknown", "other"), 0)
    waiting = dict.fromkeys(("ContainerCreating", "PodInitializing", "CrashLoopBackOff", "ErrImagePull",
                             "ImagePullBackOff", "CreateContainerConfigError", "CreateContainerError",
                             "ContainerCannotRun", "other"), 0)
    ready = 0
    for pod in pods:
        status = pod.get("status") or {}
        phases[enum(status.get("phase"), phases)] += 1
        ready += any(condition.get("type") == "Ready" and condition.get("status") == "True"
                     for condition in _optional_array(status.get("conditions")))
        for container in (_optional_array(status.get("initContainerStatuses"))[:4]
                          + _optional_array(status.get("containerStatuses"))[:4]):
            state = container.get("state") or {}
            if "waiting" in state:
                waiting[enum((state.get("waiting") or {}).get("reason"), waiting)] += 1
    return {
        "status": "observed", "deploymentPresent": bool(uid),
        "desiredReplicas": count((deployment.get("spec") or {}).get("replicas")),
        "readyReplicas": count((deployment.get("status") or {}).get("readyReplicas")),
        "observedPodCount": len(pods), "readyPodCount": ready,
        "phaseCounts": [{"phase": phase, "count": value} for phase, value in phases.items() if value],
        "waitingReasonCounts": [{"reason": reason, "count": value} for reason, value in waiting.items() if value],
    }


def gateway_owned_workloads(workloads):
    """Select only fixture controller/proxy Deployments and their Pod owner chains."""
    objects = workloads.get("items") or []
    deployments = [obj for obj in objects if obj.get("kind") == "Deployment" and (
        (obj.get("metadata") or {}).get("name") == "envoy-gateway" or
        all(((obj.get("metadata") or {}).get("labels") or {}).get(key) == value for key, value in (
            ("gateway.envoyproxy.io/owning-gateway-name", "household"),
            ("gateway.envoyproxy.io/owning-gateway-namespace", "gateway"),
        )))][:4]
    deployment_uids = {(obj.get("metadata") or {}).get("uid") for obj in deployments} - {None}

    def owned(obj, kind, uids):
        return any(owner.get("uid") in uids and owner.get("kind") == kind and owner.get("controller") is True
                   for owner in (obj.get("metadata") or {}).get("ownerReferences") or [])

    replica_uids = {(obj.get("metadata") or {}).get("uid") for obj in objects
                    if obj.get("kind") == "ReplicaSet" and owned(obj, "Deployment", deployment_uids)} - {None}
    pods = [obj for obj in objects if obj.get("kind") == "Pod" and owned(obj, "ReplicaSet", replica_uids)][:8]
    return deployments, pods


def gateway_prerequisite_witness(resources, workloads, node, expectation):
    """Fixed fixture status only; no messages, addresses, names, UIDs or spec export."""
    def count(value):
        return value if type(value) is int and 0 <= value <= 2147483647 else None

    def enum(value, allowed):
        return value if value in allowed else "unknown"

    def items(raw):
        return raw.get("items") or ([raw] if raw.get("kind") else [])

    def conditions(raw):
        return [{
            "type": enum(condition.get("type"), ("Accepted", "Programmed", "ResolvedRefs", "Ready", "Available", "Progressing", "ReplicaFailure", "PodScheduled", "Initialized", "ContainersReady")),
            "status": enum(condition.get("status"), ("True", "False", "Unknown")),
            "observedGeneration": count(condition.get("observedGeneration")),
            "reason": enum(condition.get("reason"), (
                "Accepted", "Programmed", "ResolvedRefs", "Pending", "Invalid", "UnsupportedValue",
                "AddressNotAssigned", "AddressNotUsable", "NoResources", "ListenersNotValid",
                "InvalidParameters", "InvalidCertificateRef", "RefNotPermitted", "BackendNotFound",
                "InvalidBackendRef", "InvalidCACertificateRef", "Conflicted", "TargetNotFound",
                "NotAccepted", "Unschedulable", "MinimumReplicasAvailable", "MinimumReplicasUnavailable",
                "NewReplicaSetAvailable", "ReplicaSetUpdated", "ProgressDeadlineExceeded", "FailedCreate",
                "PodCompleted", "ContainersNotReady", "PodReady", "KubeletReady", "KubeletNotReady",
            )),
        } for condition in (raw or [])[:16] if isinstance(condition, dict)]

    objects = {(obj.get("kind"), (obj.get("metadata") or {}).get("name"),
                (obj.get("metadata") or {}).get("namespace", "")): obj for obj in items(resources)}
    result = {"resources": []}
    for kind, name, namespace in GATEWAY_PREREQUISITES:
        obj = objects.get((kind, name, namespace), {})
        status = obj.get("status") or {}
        result["resources"].append({
            "kind": kind, "name": name, "present": bool(obj),
            "generation": count((obj.get("metadata") or {}).get("generation")),
            "conditions": conditions(status.get("conditions")),
            "addressCount": count(len(status.get("addresses") or [])) if kind == "Gateway" else None,
            "listeners": [{"conditions": conditions(listener.get("conditions")),
                           "attachedRoutes": count(listener.get("attachedRoutes"))}
                          for listener in (status.get("listeners") or [])[:4]],
            "ancestors": [{
                "controllerMatches": ancestor.get("controllerName") == "gateway.envoyproxy.io/gatewayclass-controller",
                "targetMatches": (ancestor.get("ancestorRef") or {}).get("name") == "household"
                    and (ancestor.get("ancestorRef") or {}).get("namespace", "gateway") == "gateway"
                    and (ancestor.get("ancestorRef") or {}).get("kind", "Gateway") == "Gateway"
                    and (ancestor.get("ancestorRef") or {}).get("group", "gateway.networking.k8s.io") == "gateway.networking.k8s.io",
                "conditions": conditions(ancestor.get("conditions")),
            } for ancestor in (status.get("ancestors") or [])[:8]],
        })
    expectation = expectation if isinstance(expectation, dict) else {}
    result["waitingFor"] = {
        "resource": enum(expectation.get("resource"), ("gatewayclass", "gateway", "envoyproxy", "clienttrafficpolicy", "httproute", "backendtlspolicy", "securitypolicy")),
        "condition": enum(expectation.get("condition"), ("Accepted", "Programmed", "ResolvedRefs")),
        "status": enum(expectation.get("status"), ("True", "False", "Unknown")),
        "stage": enum(expectation.get("stage"), ("generation", "status", "assertion")),
    }
    deployments, pods = gateway_owned_workloads(workloads)
    result["deployments"] = [{
        "controller": (obj.get("metadata") or {}).get("name") == "envoy-gateway",
        "generation": count((obj.get("metadata") or {}).get("generation")),
        **{key: count((obj.get("status") or {}).get(key)) for key in
           ("observedGeneration", "replicas", "readyReplicas", "availableReplicas", "unavailableReplicas")},
        "conditions": conditions((obj.get("status") or {}).get("conditions")),
    } for obj in deployments]
    result["pods"] = [{
        "phase": enum((pod.get("status") or {}).get("phase"), ("Pending", "Running", "Succeeded", "Failed", "Unknown")),
        "conditions": conditions((pod.get("status") or {}).get("conditions")),
        "containers": [{
            "ready": container.get("ready") is True, "restartCount": count(container.get("restartCount")),
            "states": [{"state": state, "reason": enum(value.get("reason"), (
                "ContainerCreating", "PodInitializing", "CrashLoopBackOff", "ErrImagePull",
                "ImagePullBackOff", "CreateContainerConfigError", "CreateContainerError",
                "Error", "Completed", "OOMKilled", "ContainerCannotRun",
            )), "errorCategory": classify_network_policy_error(value.get("message") or "")}
                for state, value in (container.get("state") or {}).items() if state in ("waiting", "running", "terminated")],
        } for container in ((pod.get("status") or {}).get("initContainerStatuses") or [])[:4]
            + ((pod.get("status") or {}).get("containerStatuses") or [])[:4]],
    } for pod in pods]
    result["node"] = {
        "present": node.get("kind") == "Node",
        "hostnameMatches": ((node.get("metadata") or {}).get("labels") or {}).get("kubernetes.io/hostname") == "compute-1",
        "conditions": conditions((node.get("status") or {}).get("conditions")),
        "addressTypes": sorted({enum(address.get("type"), ("InternalIP", "ExternalIP", "Hostname"))
                                for address in (node.get("status") or {}).get("addresses") or []}),
    }
    return result


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


def classify_network_policy_error(text):
    """Fixed diagnostic category only; never retain event messages or logs."""
    text = text[-16384:].lower()
    for category, markers in (
        # Specific kubelet/containerd/OCI causes precede their generic wrappers.
        ("nonroot-user", ("runasnonroot", "breaks non-root policy")),
        ("seccomp", ("seccomp",)),
        ("apparmor", ("apparmor",)),
        ("mount-propagation", ("not a shared mount", "not a shared or slave mount", "mount propagation")),
        ("mount", ("failedmount", "failed to mount")),
        ("oci-entrypoint", ("executable file not found", "exec format error", "no command specified")),
        ("image", ("errimagepull", "imagepullbackoff", "failed to pull image")),
        ("permission", ("operation not permitted", "permission denied")),
        ("kernel-support", ("protocol not supported", "operation not supported", "module not found")),
        ("nfqueue", ("could not open nfqueue", "nfqueue socket", "reading nfqueue stats")),
        ("nftables", ("nftables sync failed", "failed to create dataplane controller")),
        ("nri", ("nri plugin exited", "failed to create nri plugin")),
        ("container-spec", ("failed to generate container spec",)),
        ("oci-runtime", ("oci runtime create failed", "failed to create shim task")),
        ("container-config", ("createcontainerconfigerror", "createcontainererror", "failedcreate")),
        ("scheduling", ("failedscheduling",)),
        ("readiness", ("readiness probe failed",)),
    ):
        if any(marker in text for marker in markers):
            return category
    if "secret" in text and "not found" in text:
        return "missing-secret"
    return classify_kubectl_error(text)


def network_policy_witness(daemonset, pods, events):
    """Owned enforcer state only; exclude names, UIDs, messages and arbitrary text."""
    def count(value):
        return value if type(value) is int and 0 <= value <= 2147483647 else None

    def enum(value, allowed):
        return value if value in allowed else "unknown"

    metadata = daemonset.get("metadata") or {}
    uid = metadata.get("uid")
    owned = [pod for pod in pods.get("items") or [] if uid and any(
        owner.get("uid") == uid and owner.get("kind") == "DaemonSet" and owner.get("controller") is True
        for owner in (pod.get("metadata") or {}).get("ownerReferences") or []
    )][:4]
    owned_uids = {pod.get("metadata", {}).get("uid") for pod in owned}
    if uid:
        owned_uids.add(uid)
    status = daemonset.get("status") or {}
    return {
        "daemonSetPresent": bool(uid),
        "daemonSet": {key: count(status.get(key)) for key in (
            "desiredNumberScheduled", "currentNumberScheduled", "numberReady",
            "numberAvailable", "numberUnavailable", "numberMisscheduled", "observedGeneration",
        )},
        "pods": [{
            "index": index,
            "phase": enum((pod.get("status") or {}).get("phase"), ("Pending", "Running", "Succeeded", "Failed", "Unknown")),
            "conditions": [{
                "type": condition["type"], "status": enum(condition.get("status"), ("True", "False", "Unknown")),
            } for condition in (pod.get("status") or {}).get("conditions") or []
                if condition.get("type") in ("PodScheduled", "Initialized", "ContainersReady", "Ready", "PodReadyToStartContainers")],
            "containers": [{
                "ready": container.get("ready") is True,
                "restartCount": count(container.get("restartCount")),
                "states": {key: [{
                    "state": state,
                    "reason": enum(value.get("reason"), (
                        "ContainerCreating", "PodInitializing", "CrashLoopBackOff", "ErrImagePull",
                        "ImagePullBackOff", "CreateContainerConfigError", "CreateContainerError",
                        "Error", "Completed", "OOMKilled", "ContainerCannotRun",
                    )),
                    "exitCode": count(value.get("exitCode")),
                    "errorCategory": classify_network_policy_error(value.get("message") or ""),
                } for state, value in (container.get(key) or {}).items() if state in ("waiting", "running", "terminated")]
                    for key in ("state", "lastState")},
            } for container in (pod.get("status") or {}).get("containerStatuses") or []
                if container.get("name") == "kube-network-policies"],
        } for index, pod in enumerate(owned, 1)],
        "events": [{
            "type": enum(event.get("type"), ("Normal", "Warning")),
            "reason": enum(event.get("reason"), (
                "FailedCreate", "FailedScheduling", "FailedMount", "FailedAttachVolume",
                "Failed", "BackOff", "Unhealthy", "Pulling", "Pulled", "Created", "Started",
                "SuccessfulCreate", "Killing", "FailedSync",
            )),
            "count": count(event.get("count")),
            "errorCategory": classify_network_policy_error(
                (event.get("reason") or "") + " " + (event.get("message") or "")
            ),
        } for event in events.get("items") or []
            if (event.get("involvedObject") or {}).get("uid") in owned_uids][:32],
    }


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
            or any(op.get("status") != "passed" or op.get("failure") or op.get("hasFailure") for op in step["operations"])
            for step in steps
        ):
            raise ValueError("scenario-failure-or-skip")


def check_acceptance(report):
    """Validate the persisted sanitized result with independent safety identities."""
    if not isinstance(report, dict):
        raise ValueError("acceptance-report-shape")
    if report.get("scenario") != "kubernetes-native-safety":
        raise ValueError("acceptance-scenario")
    supplied = report.get("requiredScenarios")
    if not isinstance(supplied, list) or len(supplied) != len(REQUIRED_SCENARIOS) or set(supplied) != set(REQUIRED_SCENARIOS):
        raise ValueError("required-scenario-inventory")
    check_report({"tests": report.get("executed")}, REQUIRED_SCENARIOS)
    if any(
        operation.get("hasFailure") is not False
        for test in report["executed"] for step in test["steps"] for operation in step["operations"]
    ):
        raise ValueError("scenario-failure-or-skip")
    if report.get("scoped") is not False:
        raise ValueError("scoped-execution-not-full-acceptance")
    mutation = report.get("mutation")
    if not isinstance(mutation, dict) or set(mutation) != {"gatewayTLSCEL", "argo"} or mutation.get("gatewayTLSCEL") is not False or mutation.get("argo") != "":
        raise ValueError("negative-mutation-not-full-acceptance")
    cleanup = report.get("cleanup")
    if not isinstance(cleanup, dict) or any(
        cleanup.get(key) is not True for key in ("containers", "volumes", "network", "credentials")
    ) or any(value is not True for value in cleanup.values()):
        raise ValueError("owned-state-cleanup-failed")
    if report.get("status") != "passed" or report.get("fullAcceptance") is not True or any(
        key in report for key in ("failurePhase", "failureReason", "commandFailure")
    ):
        raise ValueError("acceptance-failed")


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
    gateway = gateway_prerequisite_witness({"items": [{
        "kind": "Gateway", "metadata": {"name": "household", "namespace": "gateway", "generation": 2},
        "status": {"addresses": [{"value": sensitive}], "conditions": [
            {"type": "Programmed", "status": "False", "reason": "AddressNotAssigned", "observedGeneration": 1, "message": sensitive},
            {"type": sensitive, "status": sensitive, "reason": sensitive, "observedGeneration": True}],
            "listeners": [{"name": sensitive, "attachedRoutes": 2, "conditions": None}]},
    }, {
        "kind": "EnvoyProxy", "metadata": {"name": "household", "namespace": "gateway", "generation": 1},
        "status": {"ancestors": [{"controllerName": sensitive, "ancestorRef": {"name": sensitive},
                                  "conditions": [{"type": "Accepted", "status": "True", "reason": "Accepted", "observedGeneration": 1}]}]},
    }]}, {"items": [{
        "kind": "Deployment", "metadata": {"name": "envoy-gateway", "uid": "controller"},
        "status": {"availableReplicas": 0, "observedGeneration": 1},
    }, {
        "kind": "Deployment", "metadata": {"name": sensitive, "uid": "proxy", "labels": {
            "gateway.envoyproxy.io/owning-gateway-name": "household",
            "gateway.envoyproxy.io/owning-gateway-namespace": "gateway"}},
        "status": {"availableReplicas": 0},
    }, {
        "kind": "ReplicaSet", "metadata": {"uid": "replica", "ownerReferences": [
            {"kind": "Deployment", "uid": "proxy", "controller": True}]},
    }, {
        "kind": "Pod", "metadata": {"name": sensitive, "ownerReferences": [
            {"kind": "ReplicaSet", "uid": "replica", "controller": True}]},
        "status": {"phase": "Pending", "conditions": [{"type": "PodScheduled", "status": "False", "reason": "Unschedulable", "message": sensitive}],
                   "containerStatuses": [{"name": sensitive, "ready": False, "restartCount": 0,
                                          "state": {"waiting": {"reason": "CreateContainerError", "message": "permission denied " + sensitive}}}]},
    }, {
        "kind": "Pod", "metadata": {"ownerReferences": [{"kind": "ReplicaSet", "uid": sensitive, "controller": True}]},
        "status": {"phase": "Running"},
    }]}, {"kind": "Node", "metadata": {"labels": {"kubernetes.io/hostname": "compute-1"}},
          "status": {"addresses": [{"type": "InternalIP", "address": sensitive}],
                     "conditions": [{"type": "Ready", "status": "True", "reason": "KubeletReady"}]}},
        {"resource": "gateway", "condition": "Programmed", "status": "True", "stage": "status", "private": sensitive})
    assert sensitive not in json.dumps(gateway)
    assert gateway["waitingFor"] == {"resource": "gateway", "condition": "Programmed", "status": "True", "stage": "status"}
    assert gateway["resources"][1]["generation"] == 2 and gateway["resources"][1]["conditions"][0]["observedGeneration"] == 1
    assert gateway["resources"][1]["conditions"][0]["reason"] == "AddressNotAssigned"
    assert gateway["resources"][1]["conditions"][1] == {"type": "unknown", "status": "unknown", "observedGeneration": None, "reason": "unknown"}
    assert not gateway["resources"][2]["ancestors"][0]["controllerMatches"] and not gateway["resources"][2]["ancestors"][0]["targetMatches"]
    assert len(gateway["deployments"]) == 2 and len(gateway["pods"]) == 1
    assert gateway["pods"][0]["conditions"][0]["reason"] == "Unschedulable"
    assert gateway["pods"][0]["containers"][0]["states"][0]["errorCategory"] == "permission"
    assert gateway["node"]["hostnameMatches"] and gateway["node"]["addressTypes"] == ["InternalIP"]
    missing_gateway = gateway_prerequisite_witness({}, {}, {}, {"resource": sensitive})
    assert not any(resource["present"] for resource in missing_gateway["resources"])
    assert missing_gateway["pods"] == [] and missing_gateway["waitingFor"]["resource"] == "unknown"
    envoy = envoy_readiness_witness(
        {"state": "INITIALIZING", "version": sensitive + "/1.39.1/clean/RELEASE/BoringSSL", "private": sensitive},
        {"stats": [{"name": "control_plane.connected_state", "value": 0},
                   {"name": "cluster.xds_cluster.ssl.fail_verify_error", "value": 3},
                   {"name": "listener_manager.lds.update_rejected", "value": 1},
                   {"name": "server.state", "value": True},
                   {"name": "cluster_manager.warming_clusters", "value": -1},
                   {"name": "cluster.xds_cluster.upstream_cx_total", "value": sensitive},
                   {"name": sensitive, "value": 42}]})
    assert sensitive not in json.dumps(envoy) and envoy["state"] == "INITIALIZING" and envoy["versionMatches"]
    assert envoy["stats"]["control_plane.connected_state"] == 0
    assert envoy["stats"]["cluster.xds_cluster.ssl.fail_verify_error"] == 3
    assert envoy["stats"]["listener_manager.lds.update_rejected"] == 1
    assert envoy["stats"]["server.state"] is None and envoy["stats"]["cluster_manager.warming_clusters"] is None
    assert envoy["stats"]["cluster.xds_cluster.upstream_cx_total"] is None
    assert envoy["stats"]["cluster.xds_cluster.update_success"] is None
    assert set(envoy["stats"]) == set(ENVOY_READINESS_STATS)
    absent_envoy = envoy_readiness_witness({"state": sensitive, "version": sensitive}, {})
    assert absent_envoy["state"] == "unknown" and not absent_envoy["versionMatches"]
    assert all(value is None for value in absent_envoy["stats"].values())
    dns = dns_query_witness(0, b"Server: 10.43.0.10\nName: private.test\nAddress: 10.43.1.2\n", "10.43.1.2")
    assert dns == {"returnCode": 0, "errorCategory": "none", "answerMatchesXdsService": True}
    for message, category in ((b"NXDOMAIN", "nxdomain"), (b"SERVFAIL", "server-failure"),
                              (b"connection timed out", "timeout"), (b"nslookup: not found", "tool-unavailable")):
        dns = dns_query_witness(1, message + sensitive.encode(), "10.43.1.2")
        assert dns["errorCategory"] == category and not dns["answerMatchesXdsService"]
        assert sensitive not in json.dumps(dns)
    assert not dns_query_witness(0, b"Server: 10.43.1.2\nName: private.test\n", "10.43.1.2")["answerMatchesXdsService"]
    assert dns_query_witness(0, b"x" * 4097, "10.43.1.2")["errorCategory"] == "response-size-limit"
    assert bridge_netfilter_witness(0, 0, b"1\n") == {"modulePresent": True, "ipv4HookEnabled": True}
    assert bridge_netfilter_witness(1, 0, b"0\n") == {"modulePresent": False, "ipv4HookEnabled": False}
    assert bridge_netfilter_witness(2, 1, sensitive.encode()) == {"modulePresent": None, "ipv4HookEnabled": None}
    assert bridge_netfilter_witness(None, None, b"") == {"modulePresent": None, "ipv4HookEnabled": None}
    assert bridge_netfilter_witness(False, False, b"1") == {"modulePresent": None, "ipv4HookEnabled": None}
    assert bridge_netfilter_witness(1, 1, b"") == {"modulePresent": False, "ipv4HookEnabled": None}
    endpoint = {"conditions": {"ready": True}, "addresses": ["192.0.2.10"]}
    for value in (None, []):
        assert dns_service_endpoints({"items": [{"endpoints": value}]}) == []
        assert dns_service_endpoints({"items": [{"endpoints": value}, {"endpoints": [endpoint]}]}) == [endpoint]
    assert dns_service_endpoints({"items": []}) == []
    for invalid in (None, 0, False, "", {}, [], {"items": None}):
        for project in (dns_service_endpoints, coredns_workload_witness):
            try:
                project(invalid)
                raise AssertionError("malformed List envelope accepted")
            except (KeyError, TypeError, ValueError):
                pass
    try:
        dns_service_endpoints({"items": [{}]})
        raise AssertionError("missing required endpoints field accepted")
    except KeyError:
        pass
    for invalid in (0, False, "", {}):
        for value in ({"items": invalid}, {"items": [{"endpoints": invalid}]}):
            try:
                dns_service_endpoints(value)
                raise AssertionError("malformed EndpointSlice array accepted")
            except ValueError:
                pass
        try:
            coredns_workload_witness({"items": invalid})
            raise AssertionError("malformed workload array accepted")
        except ValueError:
            pass
    dns_workloads = {"items": [
        {"kind": "Deployment", "metadata": {"name": "coredns", "uid": "dns-owner"},
         "spec": {"replicas": 1}, "status": {"readyReplicas": 0}},
        {"kind": "ReplicaSet", "metadata": {"uid": "dns-replicas", "ownerReferences": [
            {"kind": "Deployment", "uid": "dns-owner", "controller": True}]}},
        {"kind": "Pod", "metadata": {"name": sensitive, "ownerReferences": [
            {"kind": "ReplicaSet", "uid": "dns-replicas", "controller": True}]},
         "status": {"phase": "Pending", "conditions": [{"type": "Ready", "status": "False"}],
                    "containerStatuses": [{"name": sensitive, "ready": False, "restartCount": 0,
                                           "state": {"waiting": {"reason": "ImagePullBackOff", "message": sensitive}}}]}},
        {"kind": "Pod", "metadata": {"ownerReferences": [
            {"kind": "ReplicaSet", "uid": sensitive, "controller": True}]}, "status": {"phase": sensitive}},
    ]}
    dns_workload = coredns_workload_witness(dns_workloads)
    assert sensitive not in json.dumps(dns_workload) and dns_workload["observedPodCount"] == 1
    assert dns_workload["desiredReplicas"] == 1 and dns_workload["readyReplicas"] == 0
    assert dns_workload["readyPodCount"] == 0 and dns_workload["phaseCounts"] == [{"phase": "Pending", "count": 1}]
    assert dns_workload["waitingReasonCounts"] == [{"reason": "ImagePullBackOff", "count": 1}]
    container = dns_workloads["items"][2]["status"]["containerStatuses"][0]
    container["state"] = {"waiting": {"reason": sensitive, "message": sensitive}}
    dns_workload = coredns_workload_witness(dns_workloads)
    assert dns_workload["waitingReasonCounts"] == [{"reason": "other", "count": 1}]
    assert sensitive not in json.dumps(dns_workload)
    container["state"] = {"running": {}}
    dns_workloads["items"][2]["status"]["conditions"][0]["status"] = "True"
    dns_workloads["items"][0]["spec"]["replicas"] = True
    dns_workload = coredns_workload_witness(dns_workloads)
    assert dns_workload["readyPodCount"] == 1 and dns_workload["waitingReasonCounts"] == []
    assert dns_workload["desiredReplicas"] is None
    assert coredns_workload_witness({"items": []})["desiredReplicas"] is None
    assert coredns_workload_witness({"items": []})["observedPodCount"] == 0
    for text, expected in (
        ("connection refused", "connection-refused"),
        ("no such file or directory", "socket-absent"),
        ("context deadline exceeded", "timeout"),
    ):
        assert containerd_socket_failure("failed to dial /run/k3s/containerd/containerd.sock: " + text + sensitive) == expected
        assert containerd_socket_failure("failed to dial /private.sock: " + text + sensitive) == "unclassified"
    assert containerd_socket_failure("x" * 8192 + "dial unix /run/k3s/containerd/containerd.sock: connection refused") == "unclassified"
    enforcer_uid = "owned-enforcer"
    creation_message = f'failed to generate container spec: path "/{sensitive}" is mounted on "/{sensitive}" but it is not a shared or slave mount'
    enforcer = network_policy_witness(
        {"metadata": {"uid": enforcer_uid, "annotations": {"private": sensitive}},
         "status": {"desiredNumberScheduled": 1, "numberReady": 0}},
        {"items": [
            {"metadata": {"uid": "owned-pod", "name": sensitive, "ownerReferences": [
                {"uid": enforcer_uid, "kind": "DaemonSet", "controller": True}]},
             "status": {"phase": "Pending", "containerStatuses": [{
                 "name": "kube-network-policies", "ready": False, "restartCount": 2,
                 "state": {"waiting": {"reason": "CreateContainerError", "message": creation_message}},
                 "lastState": {"terminated": {"reason": "Error", "exitCode": 1, "message": "operation not permitted " + sensitive}},
             }]}},
            {"metadata": {"uid": sensitive}, "status": {"phase": sensitive}},
        ]},
        {"items": [
            {"involvedObject": {"uid": "owned-pod"}, "type": "Warning", "reason": "FailedMount",
             "message": sensitive, "count": 3},
            {"involvedObject": {"uid": "owned-pod"}, "type": "Warning", "reason": "Failed",
             "message": creation_message, "count": 1},
            {"involvedObject": {"uid": sensitive}, "type": "Warning", "reason": sensitive, "message": sensitive},
        ]},
    )
    assert enforcer["daemonSet"]["numberReady"] == 0 and len(enforcer["pods"]) == 1
    assert enforcer["pods"][0]["containers"][0]["states"]["state"][0]["errorCategory"] == "mount-propagation"
    assert enforcer["pods"][0]["containers"][0]["states"]["lastState"][0]["errorCategory"] == "permission"
    assert enforcer["events"] == [
        {"type": "Warning", "reason": "FailedMount", "count": 3, "errorCategory": "mount"},
        {"type": "Warning", "reason": "Failed", "count": 1, "errorCategory": "mount-propagation"},
    ]
    assert sensitive not in json.dumps(enforcer)
    assert classify_network_policy_error("could not open nfqueue socket " + sensitive) == "nfqueue"
    assert sensitive not in classify_network_policy_error(sensitive)
    assert classify_network_policy_error('secret "' + sensitive + '" not found') == "missing-secret"
    assert classify_network_policy_error('FailedMount: secret "' + sensitive + '" not found') == "mount"
    assert classify_network_policy_error('ErrImagePull: secret "' + sensitive + '" not found') == "image"
    for category, message in (
        ("nonroot-user", f"container has runAsNonRoot and image has non-numeric user ({sensitive}), cannot verify user is non-root"),
        ("seccomp", f'failed to generate container spec: cannot load seccomp profile "/{sensitive}": permission denied'),
        ("oci-entrypoint", f'failed to create shim task: OCI runtime create failed: exec: "{sensitive}": executable file not found in $PATH'),
        ("container-spec", "failed to generate container spec: " + sensitive),
        ("oci-runtime", "failed to create shim task: " + sensitive),
    ):
        assert classify_network_policy_error(message) == category
    assert classify_network_policy_error(sensitive) == "unclassified"
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

    # Harmless operation-count changes are not a new safety inventory.
    varied = copy.deepcopy(good)
    varied["tests"][0]["steps"][0]["operations"] *= 3
    check_report(varied, required)
    complete = {
        "scenario": "kubernetes-native-safety", "requiredScenarios": REQUIRED_SCENARIOS,
        "executed": sanitize_tests({"name": name, "status": "passed", "steps": [
            {"status": "passed", "operations": [{"status": "passed", "type": "assert"}]},
        ]} for name in REQUIRED_SCENARIOS),
        "status": "passed", "fullAcceptance": True, "scoped": False,
        "mutation": {"gatewayTLSCEL": False, "argo": ""},
        "cleanup": {key: True for key in ("containers", "volumes", "network", "credentials")},
    }
    check_acceptance(complete)
    incomplete = [None, {}, {"executed": []}]
    for key in complete:
        bad = copy.deepcopy(complete)
        del bad[key]
        incomplete.append(bad)
    for key, value in (
        ("executed", []), ("requiredScenarios", REQUIRED_SCENARIOS[:-1]),
        ("scoped", True), ("scoped", None), ("status", "failed"), ("fullAcceptance", False),
        ("mutation", {"gatewayTLSCEL": True, "argo": ""}), ("failureReason", "command-failed"),
        ("mutation", {"gatewayTLSCEL": 0, "argo": ""}),
        ("failurePhase", "cleanup"), ("commandFailure", {"returnCode": 1}),
        ("cleanup", {**complete["cleanup"], "extra": False}),
    ):
        bad = copy.deepcopy(complete)
        bad[key] = value
        incomplete.append(bad)
    for key in complete["cleanup"]:
        for value in (False, None, 1):
            bad = copy.deepcopy(complete)
            bad["cleanup"][key] = value
            incomplete.append(bad)
        bad = copy.deepcopy(complete)
        del bad["cleanup"][key]
        incomplete.append(bad)
    for path in ("scenario", "step", "operation", "failure", "failure-missing", "missing"):
        bad = copy.deepcopy(complete)
        test = bad["executed"][0]
        if path == "scenario":
            test["status"] = "skipped"
        elif path == "step":
            test["steps"][0]["status"] = "failed"
        elif path == "operation":
            test["steps"][0]["operations"][0]["status"] = "skipped"
        elif path == "failure":
            test["steps"][0]["operations"][0]["hasFailure"] = True
        elif path == "failure-missing":
            del test["steps"][0]["operations"][0]["hasFailure"]
        else:
            bad["executed"].pop()
        incomplete.append(bad)
    for bad in incomplete:
        try:
            check_acceptance(bad)
        except ValueError:
            continue
        raise AssertionError("incomplete acceptance accepted")


if __name__ == "__main__":
    import sys

    if sys.argv[1:] == ["--capture-retained"]:
        capture_retained_witness()
    elif len(sys.argv) == 3 and sys.argv[1] == "--check-full":
        import json
        from pathlib import Path

        try:
            check_acceptance(json.loads(Path(sys.argv[2]).read_text()))
        except (OSError, ValueError, TypeError, AttributeError, KeyError):
            raise SystemExit("invalid-full-acceptance-report") from None
    elif len(sys.argv) == 1:
        self_check()
    else:
        raise SystemExit("unsupported reporter operation")
