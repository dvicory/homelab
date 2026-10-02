"""Executed inside the standard NixOS test driver, not a separate runner."""
import os
import shlex

k = settings["kubectl"]
repo = "/srv/git/runtime.git"
mutation = os.environ.get("ARGOCD_RUNTIME_MUTATION", "")
assert mutation in ("", "always-healthy", "cascade-retained"), "unknown Argo mutation"


def shell(value):
    return shlex.quote(str(value))


def put(path, value):
    machine.succeed(f"mkdir -p {shell(os.path.dirname(path))}; printf %s {shell(json.dumps(value))} > {shell(path)}")


def apply(value):
    machine.succeed(f"printf %s {shell(json.dumps(value))} | {k} apply -f -")


def get(resource, namespace="argocd"):
    return json.loads(machine.succeed(f"{k} -n {namespace} get {resource} -o json"))


def wait(resource, predicate, namespace="argocd", timeout=180):
    machine.wait_until_succeeds(
        f"{k} -n {namespace} get {resource} -o json | jq -e {shell(predicate)} > /dev/null",
        timeout=timeout,
    )


def canonical(path):
    return json.loads(machine.succeed(f"yq -o=json '.' {shell(settings['manifests'] + '/' + path)}"))


def commit(message):
    machine.succeed(f"git -C {repo} add .; git -C {repo} commit -m {shell(message)}")
    return machine.succeed(f"git -C {repo} rev-parse HEAD").strip()


def app(name, path, revision, retained=False, namespace="runtime"):
    # Copy the rendered production sync, retry and deletion policy, not a
    # parallel policy implementation. Only fixture addressing is substituted.
    source = "Application-identity-retained.yaml" if retained else "Application-argocd.yaml"
    value = canonical("apps/" + source)
    value["metadata"]["name"] = name
    value["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"] = "0"
    value["spec"]["project"] = "runtime"
    value["spec"]["destination"]["namespace"] = namespace
    value["spec"]["source"] = {"repoURL": repo_url, "path": path, "targetRevision": revision}
    return value


def job(name, command, wave="0"):
    return {
        "apiVersion": "batch/v1", "kind": "Job",
        "metadata": {"name": name, "namespace": "runtime", "annotations": {"argocd.argoproj.io/sync-wave": wave}},
        "spec": {"backoffLimit": 0, "template": {"spec": {
            "restartPolicy": "Never", "automountServiceAccountToken": False,
            "containers": [{"name": "probe", "image": settings["probeImage"], "imagePullPolicy": "Never",
                            "command": ["/bin/sh", "-ec", command],
                            "volumeMounts": [{"name": "proof", "mountPath": "/proof"}]}],
            "volumes": [{"name": "proof", "hostPath": {"path": "/srv/proof", "type": "Directory"}}],
        }}},
    }


def current(name, revision, healthy=True):
    condition = (
        f'.status.sync.revision == {json.dumps(revision)} and '
        '.status.sync.comparedTo.source == .spec.source and '
        f'.status.operationState.syncResult.revision == {json.dumps(revision)}'
    )
    if healthy:
        condition += ' and .status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded"'
    wait("application/" + name, condition)


start_all()
machine.wait_until_succeeds(f"{k} get --raw=/readyz", timeout=300)
machine.succeed("mkdir -p /srv/state /srv/proof /srv/git/runtime.git; git -C /srv/git/runtime.git init -b main; "
                "git -C /srv/git/runtime.git config user.email fixture@example.invalid; "
                "git -C /srv/git/runtime.git config user.name fixture")
repo_url = "git://" + machine.succeed("hostname -I").split()[0] + "/runtime.git"
machine.wait_for_unit("argocd-runtime-git.service")

with subtest("canonical Argo seed, pinned registry images, synthetic secrets"):
    machine.succeed(f"{k} apply --server-side --field-manager=homelab-bootstrap -f {settings['bootstrap']}/namespaces.yaml; {k} apply --server-side --field-manager=homelab-bootstrap -f {settings['bootstrap']}/crds.yaml")
    for crd in ("applications.argoproj.io", "appprojects.argoproj.io"):
        wait("crd/" + crd, 'any(.status.conditions[]?; .type == "Established" and .status == "True")', timeout=120)
    apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "argocd-secret", "namespace": "argocd"},
           "stringData": {"server.secretkey": "isolated-runtime-fixture-only", "admin.password": "$2a$10$7lKraD.Az3/wo2XdoQ4YU.kAeUWu0bC7khAuqmskfCXKg3fRDSKGa", "admin.passwordMtime": "2026-01-01T00:00:00Z"}})
    machine.succeed(f"{k} apply --server-side --field-manager=homelab-bootstrap -f {settings['bootstrap']}/controllers.yaml")
    if mutation == "always-healthy":
        machine.succeed(f"{k} -n argocd patch configmap argocd-cm --type=merge -p " + shell(json.dumps({
            "data": {"resource.customizations.health.argoproj.io_Application": 'return {status = "Healthy", message = "broken fixture"}'}})))
    for resource in ("statefulset/argocd-application-controller", "deployment/argocd-repo-server", "deployment/argocd-redis"):
        machine.succeed(f"{k} -n argocd rollout status {resource} --timeout=300s")
    for namespace in ("runtime", "local-path-storage"):
        apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": namespace}})
    apply({"apiVersion": "argoproj.io/v1alpha1", "kind": "AppProject", "metadata": {"name": "runtime", "namespace": "argocd"},
           "spec": {"sourceRepos": [repo_url], "destinations": [{"server": "https://kubernetes.default.svc", "namespace": "*"}],
                    "clusterResourceWhitelist": [{"group": "", "kind": "Namespace"}, {"group": "", "kind": "PersistentVolume"}]}})

with subtest("actual retained-directory hook fails closed without a substitute directory"):
    hook = canonical("retained-storage/Job-retained-directories.yaml")
    hook["spec"]["template"]["spec"]["nodeSelector"]["kubernetes.io/hostname"] = "machine"
    hook["spec"]["template"]["spec"]["containers"][0]["image"] = settings["directoriesImage"]
    put(repo + "/hook/hook.json", hook)
    after = job("after-retained-hook", "echo completed > /proof/hook-completed", "2")
    after["metadata"]["namespace"] = "local-path-storage"
    put(repo + "/hook/after.json", after)
    hook_revision = commit("real retained hook and later-wave workload")
    apply(app("hook", "hook", hook_revision, retained=True, namespace="local-path-storage"))
    hook_uid = machine.wait_until_succeeds(
        f"{k} -n local-path-storage get job/retained-directories -o json | jq -er "
        + shell('select(any(.status.conditions[]?; .type == "Failed" and .status == "True")) | .metadata.uid'),
        timeout=180,
    ).strip()
    current("hook", hook_revision, healthy=False)
    # Canonical retry policy can keep the operation Running after a failed hook.
    # Require the controller to observe that failure, not exhausted retries.
    wait("application/hook", 'any(.status.operationState.syncResult.resources[]?; .kind == "Job" and .name == "retained-directories" and .hookPhase == "Failed")')
    assert get("application/hook")["status"]["operationState"]["phase"] in ("Running", "Failed"), "failed hook did not block its sync"
    machine.succeed("test ! -e /srv/state/identity-kanidm; test ! -e /srv/state/kubernetes-volumes; test ! -e /srv/proof/hook-completed")
    machine.succeed(f"{k} -n local-path-storage get jobs -o json | jq -e " + shell('all(.items[]; .metadata.name != "after-retained-hook")'))
    # No cross-Application declaration barrier is claimed here.
    # A separately declared consumer is allowed to exist, but cannot start or
    # create substitute data while the real hook refuses directory creation.
    blocked_consumer = {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": "directory-consumer", "namespace": "runtime"},
        "spec": {
            "restartPolicy": "Never", "automountServiceAccountToken": False,
            "containers": [{"name": "consumer", "image": settings["probeImage"], "imagePullPolicy": "Never",
                            "command": ["/bin/sh", "-ec", "echo started > /data/startup; sleep 3600"],
                            "volumeMounts": [{"name": "data", "mountPath": "/data"}]}],
            "volumes": [{"name": "data", "hostPath": {"path": "/srv/state/kubernetes-volumes", "type": "Directory"}}],
        },
    }
    apply(blocked_consumer)
    consumer_uid = get("pod/directory-consumer", "runtime")["metadata"]["uid"]
    machine.wait_until_succeeds(
        f"{k} -n runtime get events -o json | jq -e " +
        shell(f'any(.items[]; .involvedObject.uid == "{consumer_uid}" and .reason == "FailedMount")'),
        timeout=120,
    )
    statuses = get("pod/directory-consumer", "runtime").get("status", {}).get("containerStatuses", [])
    assert all(not status.get("state", {}).get("running") and not status.get("state", {}).get("terminated") for status in statuses), "consumer started on substitute data"
    machine.succeed("test ! -e /srv/state/kubernetes-volumes")
    marker = hook["spec"]["template"]["spec"]["containers"][0]["args"][1]
    machine.succeed(f"touch {shell('/srv/state/' + marker)}")
    current("hook", hook_revision)
    assert get("job/retained-directories", "local-path-storage")["metadata"]["uid"] != hook_uid, "BeforeHookCreation did not replace the failed hook"
    machine.succeed("test -d /srv/state/identity-kanidm; test -d /srv/state/kubernetes-volumes; test \"$(cat /srv/proof/hook-completed)\" = completed")
    wait("pod/directory-consumer", 'any(.status.conditions[]?; .type == "Ready" and .status == "True")', namespace="runtime")
    machine.succeed("test \"$(cat /srv/state/kubernetes-volumes/startup)\" = started")

with subtest("retained real PV/PVC and self-healing workload preserve data"):
    for filename in ("Namespace-identity.yaml", "PersistentVolume-identity-kanidm.yaml", "PersistentVolumeClaim-identity-kanidm.yaml"):
        value = canonical("identity-retained/" + filename)
        if value["kind"] == "PersistentVolume":
            value["spec"]["nodeAffinity"]["required"]["nodeSelectorTerms"][0]["matchExpressions"][0]["values"] = ["machine"]
        if mutation == "cascade-retained":
            value["metadata"].pop("annotations", None)
        put(repo + "/retained/" + filename + ".json", value)
    deployment = {
        "apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "data-reader", "namespace": "identity"},
        "spec": {"replicas": 1, "selector": {"matchLabels": {"app": "data-reader"}}, "template": {
            "metadata": {"labels": {"app": "data-reader"}}, "spec": {
                "automountServiceAccountToken": False,
                "containers": [{"name": "reader", "image": settings["probeImage"], "imagePullPolicy": "Never",
                                "command": ["/bin/sh", "-ec", "test \"$(cat /data/sentinel)\" = retained-fixture-data; echo consumed > /data/consumed; sleep 3600"],
                                "readinessProbe": {"exec": {"command": ["/bin/sh", "-ec", "test \"$(cat /data/sentinel)\" = retained-fixture-data"]}},
                                "volumeMounts": [{"name": "data", "mountPath": "/data"}]}],
                "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "identity-kanidm"}}],
            }}}
    }
    put(repo + "/reader/deployment.json", deployment)
    retention_revision = commit("retained volumes and data consumer")
    retained_app = app("retained", "retained", retention_revision, retained=True, namespace="identity")
    if mutation == "cascade-retained":
        retained_app["metadata"]["finalizers"] = ["resources-finalizer.argocd.argoproj.io"]
    apply(retained_app)
    current("retained", retention_revision)
    machine.succeed("printf %s retained-fixture-data > /srv/state/identity-kanidm/sentinel")
    apply(app("reader", "reader", retention_revision, namespace="identity"))
    current("reader", retention_revision)
    machine.succeed("test \"$(cat /srv/state/identity-kanidm/consumed)\" = consumed")
    old_uid = get("deployment/data-reader", "identity")["metadata"]["uid"]
    machine.succeed(f"{k} -n identity delete deployment data-reader --wait=true")
    wait("deployment/data-reader", f'.metadata.uid != {json.dumps(old_uid)} and .status.observedGeneration == .metadata.generation and .status.availableReplicas == 1', namespace="identity")
    current("reader", retention_revision)
    machine.succeed(f"{k} -n identity exec deployment/data-reader -- /bin/cat /data/sentinel | cmp - <(printf %s retained-fixture-data)")
    identities = {resource: get(resource, "identity")["metadata"]["uid"] for resource in ("namespace/identity", "pv/identity-kanidm", "pvc/identity-kanidm")}
    machine.succeed(f"rm {repo}/retained/PersistentVolumeClaim-identity-kanidm.yaml.json")
    omission_revision = commit("retire the retained PVC declaration")
    machine.succeed(f"{k} -n argocd patch application retained --type=merge -p " + shell(json.dumps({"spec": {"source": {"targetRevision": omission_revision}}})))
    wait("application/retained",
         f'.status.sync.revision == "{omission_revision}" and .status.sync.comparedTo.source == .spec.source and '
         'any(.status.resources[]?; .kind == "PersistentVolumeClaim" and .name == "identity-kanidm" and .requiresPruning == true)')
    for resource, uid in identities.items():
        assert get(resource, "identity")["metadata"]["uid"] == uid, "Git omission pruned " + resource
    machine.succeed(f"{k} -n identity exec deployment/data-reader -- /bin/cat /data/sentinel | cmp - <(printf %s retained-fixture-data)")
    # Retire the retained Application, not just inspect its finalizer strings.
    # Stop the consumer first so a broken cascade cannot hide behind PVC protection.
    machine.succeed(f"{k} -n argocd patch application reader --type=merge -p " + shell(json.dumps({"spec": {"syncPolicy": {"automated": None}}})))
    machine.succeed(f"{k} -n identity delete deployment data-reader --wait=true --timeout=120s")
    machine.succeed(f"{k} -n identity wait --for=delete pod -l app=data-reader --timeout=120s")
    machine.succeed(f"{k} -n argocd delete application retained --wait=false")
    machine.wait_until_succeeds(f"{k} -n argocd get applications -o json | jq -e 'all(.items[]; .metadata.name != \"retained\")'", timeout=180)
    for resource, uid in identities.items():
        value = get(resource, "identity")
        assert value["metadata"]["uid"] == uid and not value["metadata"].get("deletionTimestamp"), "retirement deleted or replaced " + resource
    # Recreate an actual consumer after retirement; a surviving pathname alone
    # is not usable-volume proof. Neither Argo nor the fixture recreates the PVC.
    apply(deployment)
    wait("deployment/data-reader", '.status.observedGeneration == .metadata.generation and .status.availableReplicas == 1', namespace="identity")
    machine.succeed(f"{k} -n identity exec deployment/data-reader -- /bin/cat /data/sentinel | cmp - <(printf %s retained-fixture-data)")
    machine.succeed("test \"$(cat /srv/state/identity-kanidm/consumed)\" = consumed")

with subtest("failed and missing child do not unblock the next parent wave"):
    put(repo + "/failed/job.json", job("failed-child-job", "exit 1"))
    payload_revision = commit("failing workload")
    for name, path in (("failed-child", "failed"), ("missing-child", "does-not-exist")):
        put(repo + "/" + name + "-root/child.json", app(name, path, payload_revision))
        put(repo + "/" + name + "-root/late.json", job(name + "-late", f"echo advanced > /proof/{name}-late", "1"))
    parent_revision = commit("dependency roots")
    apply(app("failed-root", "failed-child-root", parent_revision, namespace="argocd"))
    apply(app("missing-root", "missing-child-root", parent_revision, namespace="argocd"))
    current("failed-child", payload_revision, healthy=False)
    wait("application/failed-child", '.status.health.status == "Degraded"')
    # A source error may still carry a resolved revision and Healthy health.
    # Observe the actual ComparisonError rather than assuming a sync operation.
    wait("application/missing-child", '.status.sync.comparedTo.source == .spec.source and any(.status.conditions[]?; .type == "ComparisonError")')
    # Argo 3 stores per-resource health outside the Application CR. Prove
    # wave gating by the actual workload side effect, not that optional field.
    for root in ("failed-root", "missing-root"):
        current(root, parent_revision, healthy=False)
    late_jobs = [item["metadata"]["name"] for item in get("jobs", "runtime")["items"] if item["metadata"]["name"].endswith("-late")]
    if late_jobs:
        for name in ("failed-child", "missing-child", "failed-root", "missing-root"):
            status = get("application/" + name).get("status", {})
            print(name, json.dumps({key: status.get(key) for key in ("health", "sync", "conditions", "operationState")}))
    assert not late_jobs, f"parent advanced before child recovery: {late_jobs}"
    machine.succeed("sleep 15; test ! -e /srv/proof/failed-child-late; test ! -e /srv/proof/missing-child-late")
    put(repo + "/failed/job.json", job("repaired-child-job", "exit 0"))
    put(repo + "/does-not-exist/job.json", job("found-child-job", "exit 0"))
    repaired_revision = commit("repair both child workloads")
    for name, path in (("failed-child", "failed"), ("missing-child", "does-not-exist")):
        put(repo + "/" + name + "-root/child.json", app(name, path, repaired_revision))
    resumed_revision = commit("resume dependency roots")
    for root, path in (("failed-root", "failed-child-root"), ("missing-root", "missing-child-root")):
        apply(app(root, path, resumed_revision, namespace="argocd"))
        current(root, resumed_revision)
    for child in ("failed-child", "missing-child"):
        current(child, repaired_revision)
        assert not any(condition.get("type") == "ComparisonError" for condition in (get("application/" + child).get("status", {}).get("conditions") or [])), "recovered child retains a source error"
    machine.succeed("test \"$(cat /srv/proof/failed-child-late)\" = advanced; test \"$(cat /srv/proof/missing-child-late)\" = advanced")
