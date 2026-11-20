#!/usr/bin/env python3
"""Disposable-only Argo/local-PV lifecycle experiment. Never imports production code.

render writes Git fixture snapshots; Parent publishes them. native performs actual
Argo reconciliation through an explicitly supplied kubectl argv and Git revision.
The lease JSON is an operator-supplied authorization, not a production credential.

Replay: render, Parent publishes exact Git snapshot, native, policy, registry-cases.
After Parent reconstructs a fenced disposable guest/cluster, recover consumes the
prior policy receipt and requires explicit --approval plus old_writers_fenced.
No commands here create/stop guests, acquire images or alter source history.
kubectl must route ONLY to the admitted disposable cluster. Evidence JSON is
incrementally persisted, including actual subprocess failures; no mocked API.

Native responsibility: Argo sync/prune/delete annotations, local-PV publication,
Retain/Delete cleanup, PVC UID binding, local-path existence and node affinity.
Custom responsibility: independent allocation history, UID adoption authorization,
ordinary directory-replacement detection and common metadata-aware init check.
Admission covers direct PVC references in new Pods in one pre-enrolled namespace.
It does not check generic ephemeral volumes, enroll arbitrary new namespaces or
rerun on cached container restarts. PVC-API/image/registry-root
dependencies couple disposable workloads too; unrelated-workload isolation is
not satisfied. No automatic recovery, physical authentication or fencing is provided.
App and existing app-init run UID/GID1000 with ordinary fsGroup1000. The injected
trusted checker explicitly runs UID0 to read private metadata, all mounts RO and
capabilities dropped. Injected hostPath violates Pod Security Baseline and
Restricted; UID0 additionally conflicts with Restricted. No exemptions or namespace
enrollment mechanism are implemented by this prototype.
"""
import argparse
import json
from pathlib import Path
import re
import shlex
import subprocess
import time

HERE = Path(__file__).resolve().parent
NS = "psx-lifecycle"
APP = "psx-lifecycle"
PROTECT = {"argocd.argoproj.io/sync-options": "Prune=false,Delete=false"}


def obj(kind, name, spec=None, namespace=None, api="v1", annotations=None):
    result = {"apiVersion": api, "kind": kind, "metadata": {"name": name}}
    if namespace:
        result["metadata"]["namespace"] = namespace
    if annotations:
        result["metadata"]["annotations"] = annotations
    if spec is not None:
        result["spec"] = spec
    return result


def helper_logs(log, name):
    """Yield complete helper frames only when no other frame overlaps."""
    active = set()
    body = None
    for line in log.splitlines():
        marker = re.search(r"\b(Start|End) of (helper-pod-\S+) logs\b", line)
        if marker is None:
            if body is not None:
                body.append(line)
            continue
        action, helper = marker.groups()
        if action == "Start":
            body = [] if not active and helper == name else None
            active.add(helper)
        else:
            if helper == name and body is not None and active == {name}:
                yield "\n".join(body)
            active.discard(helper)
            body = None


def injection(lease, registry):
    """Native beta admission only. No webhook/controller; no PVC parameter join."""
    root = f'{lease["guest_data_root"]}/policy/.registry'
    image = json.dumps(lease["python_image"])
    policy = obj("MutatingAdmissionPolicy", "psx-startup", api="admissionregistration.k8s.io/v1beta1")
    policy["spec"] = {
        "failurePolicy": "Fail", "reinvocationPolicy": "IfNeeded",
        "matchConstraints": {"resourceRules": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE"], "resources": ["pods"]}]},
        "matchConditions": [{"name": "pvc-backed", "expression": "has(object.spec.volumes) && object.spec.volumes.exists(v, has(v.persistentVolumeClaim))"}],
        "variables": [{"name": "claims", "expression": "object.spec.volumes.filter(v, has(v.persistentVolumeClaim))"}],
        "mutations": [{"patchType": "JSONPatch", "jsonPatch": {"expression": f"""
[
 JSONPatch{{op: "add", path: "/spec/volumes", value:
  object.spec.volumes.filter(v, !(v.name in ["psx-registry", "psx-code", "psx-identity"])) + [
   Object.spec.volumes{{name: "psx-registry", hostPath: Object.spec.volumes.hostPath{{path: {json.dumps(root)}, type: "Directory"}}}},
   Object.spec.volumes{{name: "psx-code", configMap: Object.spec.volumes.configMap{{name: "psx-policy"}}}},
   Object.spec.volumes{{name: "psx-identity", projected: Object.spec.volumes.projected{{sources: [
    Object.spec.volumes.projected.sources{{serviceAccountToken: Object.spec.volumes.projected.sources.serviceAccountToken{{path: "token", expirationSeconds: 600}}}},
    Object.spec.volumes.projected.sources{{configMap: Object.spec.volumes.projected.sources.configMap{{name: "kube-root-ca.crt", items: [Object.spec.volumes.projected.sources.configMap.items{{key: "ca.crt", path: "ca.crt"}}]}}}}
   ]}}}}
  ]
 }},
 JSONPatch{{op: "add", path: "/spec/initContainers", value: [
  Object.spec.initContainers{{
   name: "psx-check", image: {image}, imagePullPolicy: "Never",
   securityContext: Object.spec.initContainers.securityContext{{
    runAsUser: 0, runAsGroup: 0, runAsNonRoot: false,
    allowPrivilegeEscalation: false, readOnlyRootFilesystem: true,
    capabilities: Object.spec.initContainers.securityContext.capabilities{{drop: ["ALL"]}}
   }},
   command: ["python3", "/policy/registry.py", "--root", "/registry", "podcheck"],
   env: [
    Object.spec.initContainers.env{{name: "POD_NAMESPACE", valueFrom: Object.spec.initContainers.env.valueFrom{{fieldRef: Object.spec.initContainers.env.valueFrom.fieldRef{{fieldPath: "metadata.namespace"}}}}}},
    Object.spec.initContainers.env{{name: "CLAIMS", value: variables.claims.map(v, v.name + ":" + v.persistentVolumeClaim.claimName).join(",")}}
   ],
   volumeMounts: [
    Object.spec.initContainers.volumeMounts{{name: "psx-registry", mountPath: "/registry", readOnly: true}},
    Object.spec.initContainers.volumeMounts{{name: "psx-code", mountPath: "/policy", readOnly: true}},
    Object.spec.initContainers.volumeMounts{{name: "psx-identity", mountPath: "/identity", readOnly: true}}
   ] + variables.claims.map(v, Object.spec.initContainers.volumeMounts{{name: v.name, mountPath: "/claims/" + v.name, readOnly: true}})
  }}
 ] + (has(object.spec.initContainers) ? object.spec.initContainers.filter(c, c.name != "psx-check") : [])
 }}
]
"""}}],
    }
    binding = obj("MutatingAdmissionPolicyBinding", "psx-startup", {
        "policyName": "psx-startup",
        "matchResources": {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": NS}}},
    }, api="admissionregistration.k8s.io/v1beta1")
    reserved = '["psx-registry", "psx-code", "psx-identity"]'
    no_borrow = f'(!has(c.volumeMounts) || c.volumeMounts.all(m, !(m.name in {reserved}))) && (!has(c.volumeDevices) || c.volumeDevices.all(m, !(m.name in {reserved})))'
    isolation = obj("ValidatingAdmissionPolicy", "psx-checker-isolation", {
        "failurePolicy": "Fail",
        "matchConstraints": {"resourceRules": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE", "UPDATE"], "resources": ["pods", "pods/ephemeralcontainers"]}]},
        "matchConditions": policy["spec"]["matchConditions"],
        "validations": [{"expression": f'object.spec.containers.all(c, {no_borrow}) && (!has(object.spec.initContainers) || object.spec.initContainers.filter(c, c.name != "psx-check").all(c, {no_borrow})) && (!has(object.spec.ephemeralContainers) || object.spec.ephemeralContainers.all(c, {no_borrow}))', "message": "application and other init/ephemeral containers cannot borrow checker-only metadata, code or API token volumes"}],
    }, api="admissionregistration.k8s.io/v1")
    isolation_binding = obj("ValidatingAdmissionPolicyBinding", "psx-checker-isolation", {"policyName": "psx-checker-isolation", "validationActions": ["Deny"], "matchResources": binding["spec"]["matchResources"]}, api="admissionregistration.k8s.io/v1")
    cm = obj("ConfigMap", "psx-policy", namespace=NS)
    cm["data"] = {"registry.py": registry}
    role = obj("Role", "psx-pvc-metadata", namespace=NS, api="rbac.authorization.k8s.io/v1")
    role["rules"] = [{"apiGroups": [""], "resources": ["persistentvolumeclaims"], "verbs": ["get"]}]
    rb = obj("RoleBinding", "psx-pvc-metadata", namespace=NS, api="rbac.authorization.k8s.io/v1")
    rb.update({"roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "psx-pvc-metadata"}, "subjects": [{"kind": "Group", "name": f"system:serviceaccounts:{NS}", "apiGroup": "rbac.authorization.k8s.io"}]})
    for resource in (cm, role, rb, policy, isolation):
        resource["metadata"]["annotations"] = {"argocd.argoproj.io/sync-wave": "-3"}
    binding["metadata"]["annotations"] = {"argocd.argoproj.io/sync-wave": "-2"}
    isolation_binding["metadata"]["annotations"] = {"argocd.argoproj.io/sync-wave": "-2"}
    return [cm, role, rb, policy, binding, isolation, isolation_binding]


def fixtures(lease, destination):
    node, root, image = lease["node"], lease["guest_data_root"], lease["python_image"]
    helper_image = lease["helper_image"]
    provisioner, provisioner_ns = lease["provisioner"], lease["provisioner_namespace"]
    config_name = lease["provisioner_configmap"]
    registry = (HERE / "registry.py").read_text()
    namespace = obj("Namespace", NS, annotations=PROTECT | {"argocd.argoproj.io/sync-wave": "-5"})

    def config(guarded):
        base = f"{root}/{'policy' if guarded else 'native'}"
        helper = obj("Pod", "helper-pod", {"containers": [{"name": "helper-pod", "image": image if guarded else helper_image, "imagePullPolicy": "Never"}]})
        cm = obj("ConfigMap", config_name, namespace=provisioner_ns)
        cm["data"] = {
            "config.json": json.dumps({"nodePathMap": [], "storageClassConfigs": {
                f"psx-{'policy-' if guarded else ''}retain": {"nodePathMap": [{"node": node, "paths": [base]}]},
                "psx-delete": {"nodePathMap": [{"node": node, "paths": [f"{root}/disposable"]}]},
            }}),
            "setup": f'set -eu\ncase "$VOL_DIR" in\n {root}/disposable/*) mkdir -m 0777 -p "$VOL_DIR";;\n {base}/*) exec python3 -c {shlex.quote(registry)} --root {shlex.quote(base)} setup;;\n *) exit 1;;\nesac\n' if guarded else 'set -eu\nmkdir -m 0777 -p "$VOL_DIR"\n',
            "teardown": f'set -eu\ncase "$VOL_DIR" in\n {root}/disposable/*) leaf=${{VOL_DIR#{root}/disposable/}};;\n *) echo "REFUSE retained/registry/unowned teardown" >&2; exit 1;;\nesac\ncase "$leaf" in ""|*/*|.*) exit 1;; esac\ncase "$leaf" in pvc-*) rm -rf -- "$VOL_DIR";; *) exit 1;; esac\n',
            "helperPod.yaml": json.dumps(helper),
        }
        return cm

    def classes(guarded):
        result = []
        for retention in ("retain", "delete"):
            sc = obj("StorageClass", f"psx-{'policy-' if guarded and retention == 'retain' else ''}{retention}", api="storage.k8s.io/v1", annotations={"defaultVolumeType": "local"})
            sc.update({"provisioner": provisioner, "volumeBindingMode": "WaitForFirstConsumer", "reclaimPolicy": retention.title()})
            result.append(sc)
        return result

    def claim(name, guarded, protected):
        ann = dict(PROTECT) if protected else {}
        storage_class = "psx-delete" if name == "disposable" else f"psx-{'policy-' if guarded else ''}retain"
        return obj("PersistentVolumeClaim", name, {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Mi"}}, "storageClassName": storage_class}, NS, annotations=ann)

    def workload(name, guarded):
        # This is deliberately a normal pre-existing init writer. Any automatic
        # guard must precede it, not merely precede the application container.
        script = "from pathlib import Path; p=Path('/data/init-writes'); p.open('a').write('init\\n')"
        app = (
            "from pathlib import Path\n"
            "import os, time\n"
            "with Path('/data/commits').open('a') as f:\n"
            "    f.write('commit\\n'); f.flush(); os.fsync(f.fileno())\n"
            "print('COMMITTED', flush=True)\n"
            "while True:\n"
            "    trigger = Path('/tmp/psx-self-exit')\n"
            "    if trigger.exists():\n"
            "        trigger.unlink()\n"
            "        raise SystemExit(17)\n"
            "    time.sleep(.2)\n"
        )
        pod = {"metadata": {"labels": {"app": name}}, "spec": {
            "terminationGracePeriodSeconds": 1,
            "securityContext": {"runAsUser": 1000, "runAsGroup": 1000, "runAsNonRoot": True, "fsGroup": 1000},
            "initContainers": [{"name": "application-init", "image": image, "imagePullPolicy": "Never", "command": ["python3", "-c", script], "volumeMounts": [{"name": "data", "mountPath": "/data"}]}],
            "containers": [{"name": "application", "image": image, "imagePullPolicy": "Never", "command": ["python3", "-c", app], "volumeMounts": [{"name": "data", "mountPath": "/data"}]}],
            "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": name}}],
        }}
        return obj("Deployment", name, {"replicas": 1, "selector": {"matchLabels": {"app": name}}, "template": pod}, NS, api="apps/v1")

    def coverage():
        resources = []
        for kind in ("bare", "statefulset", "job", "cronjob"):
            template = workload("disposable", True)["spec"]["template"]
            template["metadata"]["labels"] = {"coverage": kind}
            template["spec"]["containers"][0]["command"] = ["python3", "-c", "print('COVERAGE_APPLICATION_STARTED',flush=True)"]
            if kind == "bare":
                template["spec"]["restartPolicy"] = "Never"
                pod = obj("Pod", "psx-before-pvc", template["spec"], NS)
                pod["metadata"]["labels"] = template["metadata"]["labels"]
                resources.append(pod)
            elif kind == "statefulset":
                resources.append(obj("StatefulSet", "psx-coverage", {"serviceName": "psx-coverage", "replicas": 1, "selector": {"matchLabels": template["metadata"]["labels"]}, "template": template}, NS, api="apps/v1"))
            else:
                template["spec"]["restartPolicy"] = "Never"
                spec = {"backoffLimit": 0, "template": template}
                if kind == "job":
                    resources.append(obj("Job", "psx-coverage", spec, NS, api="batch/v1"))
                else:
                    resources.append(obj("CronJob", "psx-coverage", {"schedule": "* * * * *", "concurrencyPolicy": "Forbid", "successfulJobsHistoryLimit": 1, "failedJobsHistoryLimit": 1, "jobTemplate": {"spec": spec}}, NS, api="batch/v1"))
        return resources

    for guarded in (False, True):
        prefix = "policy" if guarded else "native"
        common = [namespace, config(guarded), *classes(guarded)]
        if guarded:
            common.extend(injection(lease, registry))
            # This Pod is admitted before its referenced PVC exists. Admission
            # must inject without pretending CEL can join arbitrary PVC objects.
            common.append(coverage()[0])
        full = common + [claim(name, guarded, name == "protected") for name in ("protected", "unprotected", "disposable")]
        full += [workload(name, guarded) for name in ("protected", "unprotected", "disposable")]
        if guarded:
            full.extend(coverage()[1:])
        variants = [(f"{prefix}-infra", common), (f"{prefix}-full", full), (f"{prefix}-removed", common)]
        if guarded:
            bootstrap = obj("Job", "psx-bootstrap", {
                "backoffLimit": 0, "template": {"spec": {
                    "restartPolicy": "Never", "containers": [{
                        "name": "bootstrap", "image": image, "imagePullPolicy": "Never",
                        "command": ["python3", "-c", f"import sys; from pathlib import Path; sys.path.insert(0,'/policy'); import registry; p=Path('{root}/policy'); p.mkdir(exist_ok=True); registry.bootstrap(p)"],
                        "volumeMounts": [{"name": "data", "mountPath": root}, {"name": "code", "mountPath": "/policy", "readOnly": True}],
                    }], "volumes": [
                        {"name": "data", "hostPath": {"path": root, "type": "Directory"}},
                        {"name": "code", "configMap": {"name": "psx-policy"}},
                    ],
                }},
            }, NS, api="batch/v1")
            variants.append(("policy-bootstrap", [namespace, *injection(lease, registry)[:3], bootstrap]))
        for variant, resources in variants:
            target = destination / variant
            target.mkdir(parents=True, exist_ok=True)
            (target / "resources.json").write_text(json.dumps({"apiVersion": "v1", "kind": "List", "items": resources}, indent=2) + "\n")


class Run:
    def __init__(self, lease, output):
        if lease.get("disposable_authorized") is not True:
            raise RuntimeError("explicit disposable runtime authorization required")
        revision = lease.get("git_revision")
        if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
            raise RuntimeError("git_revision must be a full lowercase commit SHA")
        self.lease, self.output = lease, output
        self.argv = shlex.split(lease["kubectl"])
        self.events = []

    def kubectl(self, *args, data=None, ok=True):
        result = subprocess.run(self.argv + list(args), input=None if data is None else json.dumps(data), text=True, capture_output=True, timeout=240)
        self.record("kubectl", {"args": args, "returncode": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
        if ok and result.returncode:
            raise RuntimeError(result.stderr)
        return result

    def record(self, name, value):
        self.events.append({"time": time.time(), "name": name, "value": value})
        self.output.write_text(json.dumps(self.events, indent=2) + "\n")

    def get(self, kind, name=None, namespace=NS):
        args = ["get", kind]
        if name:
            args.append(name)
        if namespace:
            args.extend(["-n", namespace])
        return json.loads(self.kubectl(*args, "-o", "json").stdout)

    def wait(self, label, predicate, seconds=180):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                self.record(label, value)
                return value
            time.sleep(2)
        raise RuntimeError(f"timeout: {label}")

    def application(self, path):
        application = obj("Application", APP, {
            "project": self.lease.get("argo_project", "default"),
            "source": {"repoURL": self.lease["git_url"], "targetRevision": self.lease["git_revision"], "path": path},
            "destination": {"server": "https://kubernetes.default.svc", "namespace": NS},
            "syncPolicy": {"automated": {"prune": True, "selfHeal": True, "allowEmpty": True}},
        }, self.lease.get("argo_namespace", "argocd"), api="argoproj.io/v1alpha1")
        application["metadata"]["finalizers"] = ["resources-finalizer.argocd.argoproj.io"]
        return application

    def reconcile(self, variant):
        path = f"{self.lease.get('git_path', 'experiments/portable-storage/manifests')}/{variant}".lstrip("/")
        self.kubectl("apply", "-f", "-", data=self.application(path))
        argo = self.lease.get("argo_namespace", "argocd")
        self.kubectl("annotate", "application", APP, "-n", argo, "argocd.argoproj.io/refresh=hard", "--overwrite")
        def completed():
            a = self.get("application", APP, argo)
            status = a.get("status", {})
            sync = status.get("sync", {})
            # Prune=false intentionally leaves OutOfSync after source removal.
            op = status.get("operationState", {})
            return a if sync.get("comparedTo", {}).get("source", {}).get("path") == path and op.get("phase") == "Succeeded" and op.get("syncResult", {}).get("source", {}).get("path") == path and op.get("syncResult", {}).get("revision") == self.lease["git_revision"] else None
        return self.wait(f"argo-{variant}", completed)

    def restart_provisioner(self):
        deployment = self.lease["provisioner_deployment"]
        namespace = self.lease["provisioner_namespace"]
        self.kubectl("rollout", "restart", f"deployment/{deployment}", "-n", namespace)
        self.kubectl("rollout", "status", f"deployment/{deployment}", "-n", namespace, "--timeout=180s")

    def ready(self, name):
        return self.kubectl("rollout", "status", f"deployment/{name}", "-n", NS, "--timeout=180s")

    def pod(self, name):
        pods = self.get("pods")["items"]
        return next((p for p in pods if p["metadata"].get("labels", {}).get("app") == name and not p["metadata"].get("deletionTimestamp")), None)

    def payload(self, name):
        pod = self.pod(name)["metadata"]["name"]
        code = "from pathlib import Path; import json; print(json.dumps({p.name:p.read_text() for p in Path('/data').iterdir() if p.is_file()}))"
        return json.loads(self.kubectl("exec", "-n", NS, pod, "-c", "application", "--", "python3", "-c", code).stdout)

    def seed(self, name, uid):
        # Test application data only: never read by the registry/startup guard.
        pod = self.pod(name)["metadata"]["name"]
        code = f"import os; from pathlib import Path; p=Path('/data/experiment-original-pvc'); f=p.open('x'); f.write({uid!r}); f.flush(); os.fsync(f.fileno()); f.close(); d=os.open('/data',os.O_RDONLY|os.O_DIRECTORY); os.fsync(d); os.close(d)"
        self.kubectl("exec", "-n", NS, pod, "-c", "application", "--", "python3", "-c", code)
        assert self.payload(name)["experiment-original-pvc"] == uid

    def identity(self, name):
        pod = self.pod(name)["metadata"]["name"]
        code = "import os,json; from pathlib import Path; print(json.dumps({'uid':os.getuid(),'gid':os.getgid(),'leaf_mode':oct(Path('/data').stat().st_mode & 0o7777),'files':{p.name:[p.stat().st_uid,p.stat().st_gid] for p in Path('/data').iterdir() if p.is_file()}}))"
        observed = json.loads(self.kubectl("exec", "-n", NS, pod, "-c", "application", "--", "python3", "-c", code).stdout)
        assert observed["uid"] == observed["gid"] == 1000
        assert observed["files"]["init-writes"] == observed["files"]["commits"] == [1000, 1000]
        self.record(f"nonroot-application-and-init-{name}", observed)

    def pause(self):
        self.kubectl("patch", "application", APP, "-n", self.lease.get("argo_namespace", "argocd"),
                     "--type=merge", "-p", '{"spec":{"syncPolicy":{"automated":null}}}')

    def scale(self, name, replicas):
        self.kubectl("scale", f"deployment/{name}", "-n", NS, f"--replicas={replicas}")
        if replicas == 0:
            self.wait(f"{name}-writers-excluded", lambda: not any(v.get("persistentVolumeClaim", {}).get("claimName") == name for pod in self.get("pods")["items"] for v in pod["spec"].get("volumes", [])))

    def toolbox(self, policy=True):
        root = self.lease["guest_data_root"]
        tool = obj("Pod", "psx-operator", {
            "restartPolicy": "Never", "containers": [{
                "name": "operator", "image": self.lease["python_image"], "imagePullPolicy": "Never",
                "command": ["python3", "-c", "import time; time.sleep(86400)"],
                "volumeMounts": [{"name": "data", "mountPath": root}, {"name": "code", "mountPath": "/policy", "readOnly": True}],
            }], "volumes": [
                {"name": "data", "hostPath": {"path": root, "type": "Directory"}},
                {"name": "code", "configMap": {"name": "psx-policy"}},
            ],
        }, NS)
        if not policy:
            tool["spec"]["containers"][0]["volumeMounts"].pop()
            tool["spec"]["volumes"].pop()
        self.kubectl("apply", "-f", "-", data=tool)
        self.kubectl("wait", "pod/psx-operator", "-n", NS, "--for=condition=Ready", "--timeout=180s")

    def operator(self, code, ok=True):
        return self.kubectl("exec", "-n", NS, "psx-operator", "--", "python3", "-c", code, ok=ok)

    def unstarted(self, pod, guard_may_run=False):
        statuses = pod.get("status", {}).get("containerStatuses", []) + pod.get("status", {}).get("initContainerStatuses", [])
        for status in statuses:
            if guard_may_run and status["name"] == "psx-check":
                continue
            assert not status.get("state", {}).get("running") and not status.get("state", {}).get("terminated")
            assert not status.get("lastState") and status.get("restartCount", 0) == 0

    def mount_denied(self, pod_name, path, label):
        def causal():
            pod = self.get("pod", pod_name)
            events = [e for e in self.get("events")["items"] if e.get("involvedObject", {}).get("uid") == pod["metadata"]["uid"] and e.get("reason") == "FailedMount" and path in e.get("message", "") and any(text in e.get("message", "").lower() for text in ("does not exist", "no such file", "not a directory"))]
            if events:
                self.unstarted(pod)
                return {"pod": pod, "causal_events": events}
        return self.wait(label, causal)

    def ownership_denied(self, uid):
        namespace = self.lease["provisioner_namespace"]
        cause = "DENIED: ownership collision or new PVC UID: explicit adoption required"
        def causal():
            for helper in self.get("pods", namespace=namespace)["items"]:
                if uid not in helper["metadata"]["name"]:
                    continue
                if any(s.get("state", {}).get("terminated", {}).get("exitCode", 0) != 0 for s in helper.get("status", {}).get("containerStatuses", [])):
                    log = self.kubectl("logs", helper["metadata"]["name"], "-n", namespace, ok=False)
                    if log.returncode == 0 and cause in log.stdout:
                        return {"helper": helper, "ownership_denial": log.stdout}
            log = self.kubectl("logs", f'deployment/{self.lease["provisioner_deployment"]}', "-n", namespace, ok=False)
            for body in helper_logs(log.stdout, f"helper-pod-create-pvc-{uid}"):
                if log.returncode == 0 and cause in body:
                    return {"pvc_uid": uid, "ownership_denial": body, "source": "provisioner"}
        return self.wait("helper-new-uid-ownership-denial", causal)

    def isolation(self):
        for target in ("containers", "initContainers"):
            spec = self.get("deployment", "disposable")["spec"]["template"]["spec"]
            spec["restartPolicy"] = "Never"
            spec[target][0]["volumeMounts"].append({"name": "psx-registry", "mountPath": "/borrowed-metadata", "readOnly": True})
            result = self.kubectl("create", "-f", "-", data=obj("Pod", f"psx-borrow-{target.lower()}", spec, NS), ok=False)
            assert result.returncode != 0 and "psx-checker-isolation" in result.stderr, "metadata isolation must deny actual admission, not fail later mounting"
            self.record(f"metadata-isolation-{target}-denied", result.stderr)
        pod = self.pod("disposable")["metadata"]["name"]
        result = self.kubectl("patch", "pod", pod, "-n", NS, "--subresource=ephemeralcontainers", "--type=merge", "-p", json.dumps({"spec": {"ephemeralContainers": [{
            "name": "psx-borrow-ephemeral", "image": self.lease["python_image"],
            "command": ["python3", "-c", "print('must not start')"],
            "volumeMounts": [{"name": "psx-registry", "mountPath": "/borrowed-metadata", "readOnly": True}],
        }]}}), ok=False)
        assert result.returncode != 0 and "psx-checker-isolation" in result.stderr
        self.record("metadata-isolation-ephemeral-denied", result.stderr)

    def coupling(self):
        template = self.get("deployment", "disposable")["spec"]["template"]
        spec = template["spec"]
        spec["restartPolicy"] = "Never"
        spec["containers"][0]["command"] = ["python3", "-c", "print('DISPOSABLE_PROBE_STARTED')"]
        binding = self.get("rolebinding", "psx-pvc-metadata")
        self.kubectl("delete", "rolebinding", "psx-pvc-metadata", "-n", NS, "--wait=true")
        try:
            self.kubectl("create", "-f", "-", data=obj("Pod", "psx-api-denied", spec, NS))
            def denied():
                pod = self.get("pod", "psx-api-denied")
                statuses = pod.get("status", {}).get("initContainerStatuses", [])
                return pod if any(s["name"] == "psx-check" and s.get("state", {}).get("terminated", {}).get("exitCode", 0) != 0 for s in statuses) else None
            self.wait("disposable-api-permission-coupling-denial", denied)
            self.unstarted(self.get("pod", "psx-api-denied"), guard_may_run=True)
            log = self.kubectl("logs", "psx-api-denied", "-n", NS, "-c", "psx-check").stdout
            assert "403" in log, "API-denial observation must be an actual permission failure"
            self.record("disposable-api-403", log)
        finally:
            restored = obj("RoleBinding", "psx-pvc-metadata", namespace=NS, api="rbac.authorization.k8s.io/v1")
            restored.update({key: binding[key] for key in ("roleRef", "subjects")})
            self.kubectl("apply", "-f", "-", data=restored)
            self.kubectl("delete", "pod", "psx-api-denied", "-n", NS, "--ignore-not-found", "--wait=true")
        root = f'{self.lease["guest_data_root"]}/policy/.registry'
        self.operator(f"from pathlib import Path; p=Path({root!r}); p.rename(str(p)+'.held')")
        try:
            self.kubectl("create", "-f", "-", data=obj("Pod", "psx-root-denied", spec, NS))
            self.mount_denied("psx-root-denied", root, "disposable-registry-root-coupling-denial")
        finally:
            self.operator(f"from pathlib import Path; p=Path({root!r}); Path(str(p)+'.held').rename(p)")
            self.kubectl("delete", "pod", "psx-root-denied", "-n", NS, "--ignore-not-found", "--wait=true")

    def policy(self):
        # The native lane intentionally leaves protected claims. This deletion
        # is explicit experiment teardown, never automatic retention behavior.
        for pvc in self.get("pvc")["items"]:
            assert pvc["spec"]["storageClassName"].startswith("psx-")
            self.kubectl("delete", "pvc", pvc["metadata"]["name"], "-n", NS, "--wait=true")
        self.reconcile("policy-bootstrap")
        self.kubectl("wait", "job/psx-bootstrap", "-n", NS, "--for=condition=Complete", "--timeout=180s")
        self.reconcile("policy-infra")
        before = self.get("pod", "psx-before-pvc")
        assert before["spec"]["initContainers"][0]["name"] == "psx-check"
        assert self.kubectl("get", "pvc", "disposable", "-n", NS, "--ignore-not-found", "-o", "name").stdout == ""
        self.record("automatic-injection-before-pvc-exists", before)
        self.restart_provisioner()
        self.reconcile("policy-full")
        self.toolbox()
        root = f'{self.lease["guest_data_root"]}/policy'
        prefix = f"import sys,json; from pathlib import Path; sys.path.insert(0,'/policy'); import registry; root=Path({root!r}); "
        originals = {}
        for name in ("protected", "unprotected", "disposable"):
            self.ready(name)
            self.identity(name)
            pod = self.pod(name)
            assert pod["spec"]["initContainers"][0]["name"] == "psx-check"
            assert next(s for s in pod["status"]["initContainerStatuses"] if s["name"] == "psx-check")["state"]["terminated"]["exitCode"] == 0
            assert pod["spec"]["initContainers"][1]["name"] == "application-init"
            pvc = self.get("pvc", name)
            self.seed(name, pvc["metadata"]["uid"])
            pv = self.get("pv", pvc["spec"]["volumeName"], namespace=None)
            assert "local" in pv["spec"] and "hostPath" not in pv["spec"]
            originals[name] = {"pvc": pvc, "pv": pv, "pod": pod, "payload": self.payload(name)}
        self.record("policy-argo-only-first-allocation", originals)
        self.pause()
        def coverage_complete():
            covered = {}
            for pod in self.get("pods")["items"]:
                kind = pod["metadata"].get("labels", {}).get("coverage")
                if kind and any(s["name"] == "psx-check" and s.get("state", {}).get("terminated", {}).get("exitCode") == 0 for s in pod.get("status", {}).get("initContainerStatuses", [])):
                    assert pod["spec"]["initContainers"][1]["name"] == "application-init"
                    covered[kind] = pod
            return covered if set(covered) == {"bare", "statefulset", "job", "cronjob"} else None
        self.wait("automatic-workload-coverage", coverage_complete, seconds=120)
        self.kubectl("patch", "cronjob", "psx-coverage", "-n", NS, "--type=merge", "-p", '{"spec":{"suspend":true}}')
        self.isolation()
        self.coupling()
        pod = self.pod("protected")
        pod_uid = pod["metadata"]["uid"]
        init_finished = pod["status"]["initContainerStatuses"][0]["state"]["terminated"]["finishedAt"]
        restart_count = pod["status"]["containerStatuses"][0]["restartCount"]
        self.kubectl("exec", "-n", NS, pod["metadata"]["name"], "-c", "application", "--", "python3", "-c", "from pathlib import Path; Path('/tmp/psx-self-exit').touch()")
        def restarted():
            current = self.pod("protected")
            return current if current and current.get("status", {}).get("containerStatuses", [{}])[0].get("restartCount", 0) > restart_count and current["status"]["containerStatuses"][0].get("ready") else None
        cached = self.wait("cached-application-restart", restarted)
        assert cached["metadata"]["uid"] == pod_uid
        assert cached["status"]["containerStatuses"][0]["lastState"]["terminated"]["exitCode"] == 17
        assert cached["status"]["initContainerStatuses"][0]["state"]["terminated"]["finishedAt"] == init_finished
        assert self.payload("protected")["init-writes"] == originals["protected"]["payload"]["init-writes"]
        self.record("cached-restart-does-not-rerun-guard", cached)
        self.scale("protected", 0)
        pv = originals["protected"]["pv"]
        path = pv["spec"]["local"]["path"]
        self.operator(f"from pathlib import Path; p=Path({path!r}); p.rename(str(p)+'.held')")
        self.scale("protected", 1)
        missing = self.wait("missing-path-pod-created", lambda: self.pod("protected"))
        self.mount_denied(missing["metadata"]["name"], path, "native-local-missing-path-denial")
        self.scale("protected", 0)
        self.operator(f"from pathlib import Path; Path({path!r}).mkdir()")
        self.scale("protected", 1)
        def check_denied():
            current = self.pod("protected")
            statuses = current.get("status", {}).get("initContainerStatuses", []) if current else []
            return current if any(s["name"] == "psx-check" and (s.get("state", {}).get("terminated", {}).get("exitCode", 0) != 0 or s.get("lastState", {}).get("terminated", {}).get("exitCode", 0) != 0) for s in statuses) else None
        denied = self.wait("replacement-directory-check-denied", check_denied)
        self.unstarted(denied, guard_may_run=True)
        log = self.kubectl("logs", denied["metadata"]["name"], "-n", NS, "-c", "psx-check").stdout
        self.record("replacement-directory-metadata-mismatch", self.operator(prefix + f"c=registry.connect(root/'.registry'); row=c.execute('SELECT * FROM allocations WHERE owner=?', ({f'{NS}/protected'!r},)).fetchone(); st=Path({path!r}).stat(); assert row[3]!=st.st_ino; print(json.dumps({{'registered_inode':row[3],'mounted_path_inode':st.st_ino}})); c.close()").stdout)
        self.record("replacement-directory-causal-denial", log)
        self.record("replacement-before-application-init", denied)
        self.operator(f"from pathlib import Path; p=Path({path!r}); assert list(p.iterdir()) == [], 'application init wrote before guard'")
        self.scale("protected", 0)
        self.operator(f"from pathlib import Path; p=Path({path!r}); p.rmdir(); Path(str(p)+'.held').rename(p)")
        self.scale("protected", 1)
        self.ready("protected")
        assert self.payload("protected")["experiment-original-pvc"] == originals["protected"]["payload"]["experiment-original-pvc"]
        self.scale("protected", 0)
        old_uid = originals["protected"]["pvc"]["metadata"]["uid"]
        self.kubectl("delete", "pvc", "protected", "-n", NS, "--wait=true")
        released = self.wait("native-retain-old-claimref", lambda: (p if (p := self.get("pv", pv["metadata"]["name"], namespace=None))["status"]["phase"] == "Released" else None))
        assert released["spec"]["claimRef"]["uid"] == old_uid
        self.reconcile("policy-full")
        # A successful old Argo operation is not proof that self-healing has
        # recreated this claim. Wait for the actual new UID before pausing it.
        new = self.wait("protected-claim-recreated", lambda: next((
            pvc for pvc in self.get("pvc")["items"]
            if pvc["metadata"]["name"] == "protected" and pvc["metadata"]["uid"] != old_uid
        ), None))
        self.pause()
        new_uid = new["metadata"]["uid"]
        # Observe repeated real setup denial, not just a source assertion.
        self.ownership_denied(new_uid)
        self.record("new-uid-metadata-mismatch", self.operator(prefix + f"c=registry.connect(root/'.registry'); row=c.execute('SELECT * FROM allocations WHERE owner=?', ({f'{NS}/protected'!r},)).fetchone(); assert row[1]=={old_uid!r} and row[1]!={new_uid!r}; registry.validate(root,row); print(json.dumps({{'registered_uid':row[1],'replacement_uid':{new_uid!r}}})); c.close()").stdout)
        current = self.get("pvc", "protected")
        assert current.get("status", {}).get("phase") == "Pending" and not current["spec"].get("volumeName")
        replacement = self.pod("protected")
        assert replacement is not None
        self.unstarted(replacement)
        self.operator(f"from pathlib import Path; assert not Path({f'{root}/pvc-{new_uid}_{NS}_protected'!r}).exists(), 'fresh substitute directory created'")
        self.record("new-uid-no-auto-reattachment-or-substitute", {"pvc": current, "events": self.get("events")})
        self.scale("protected", 0)
        # Explicit approval follows exclusion of old/failed replacement Pods.
        self.operator(prefix + f"registry.adopt(root, json.loads({json.dumps(new)!r}), {old_uid!r}, 'disposable experiment: all old Pods deleted, explicit operator adoption')")
        self.kubectl("patch", "pv", pv["metadata"]["name"], "--type=json", "-p", json.dumps([
            {"op": "test", "path": "/spec/claimRef/uid", "value": old_uid},
            {"op": "replace", "path": "/spec/claimRef", "value": {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "namespace": NS, "name": "protected", "uid": new_uid}},
        ]))
        self.kubectl("patch", "pvc", "protected", "-n", NS, "--type=merge", "-p", json.dumps({"spec": {"volumeName": pv["metadata"]["name"]}}))
        self.scale("protected", 1)
        self.ready("protected")
        assert self.get("pvc", "protected")["spec"]["volumeName"] == pv["metadata"]["name"]
        assert self.payload("protected")["experiment-original-pvc"] == originals["protected"]["payload"]["experiment-original-pvc"]
        self.record("explicit-native-adoption-preserves-data", {"pvc": self.get("pvc", "protected"), "pv": self.get("pv", pv["metadata"]["name"], namespace=None), "payload": self.payload("protected")})
        self.record("registry-after-adoption", self.operator(prefix + "c=registry.connect(root/'.registry'); print(json.dumps({t:c.execute('SELECT * FROM '+t).fetchall() for t in ['allocations','history']})); c.close()").stdout)
        self.record("policy-owned-resources-remaining", {"pods": self.get("pods"), "pvc": self.get("pvc"), "pv": self.get("pv", namespace=None)})
        self.record("recovery-plan", {name: {"pvc": self.get("pvc", name), "pv": self.get("pv", self.get("pvc", name)["spec"]["volumeName"], namespace=None), "payload": self.payload(name)} for name in ("protected", "unprotected")})

    def recover(self, prior, approval):
        assert self.lease.get("old_writers_fenced") is True, "Parent must independently fence old cluster/guest first"
        assert approval.strip(), "explicit reconstruction adoption approval required"
        plan = next(e["value"] for e in json.loads(prior.read_text()) if e["name"] == "recovery-plan")
        self.reconcile("policy-infra")  # Never replay empty-root bootstrap after KubeDB loss.
        self.restart_provisioner()
        self.reconcile("policy-full")
        self.pause()
        self.toolbox()
        root = f'{self.lease["guest_data_root"]}/policy'
        for name, established in plan.items():
            pvc = self.get("pvc", name)
            old_uid = established["pvc"]["metadata"]["uid"]
            assert pvc["metadata"]["uid"] != old_uid
            assert not pvc["spec"].get("volumeName"), "must not auto-relabel old storage as new"
            self.ownership_denied(pvc["metadata"]["uid"])
            replacement = self.pod(name)
            assert replacement is not None
            self.unstarted(replacement)
            self.scale(name, 0)
            self.record(f"reconstruction-{name}-blocked-until-adoption", pvc)
            self.operator(f"import sys,json; from pathlib import Path; sys.path.insert(0,'/policy'); import registry; registry.adopt(Path({root!r}), json.loads({json.dumps(pvc)!r}), {old_uid!r}, {approval!r})")
            old_pv = established["pv"]
            spec = {key: old_pv["spec"][key] for key in ("capacity", "accessModes", "volumeMode", "local", "nodeAffinity", "storageClassName", "persistentVolumeReclaimPolicy")}
            spec["claimRef"] = {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "name": name, "namespace": NS, "uid": pvc["metadata"]["uid"]}
            self.kubectl("create", "-f", "-", data=obj("PersistentVolume", old_pv["metadata"]["name"], spec))
            self.kubectl("patch", "pvc", name, "-n", NS, "--type=merge", "-p", json.dumps({"spec": {"volumeName": old_pv["metadata"]["name"]}}))
            self.scale(name, 1)
            self.ready(name)
            assert self.payload(name)["experiment-original-pvc"] == established["payload"]["experiment-original-pvc"]
            self.record(f"reconstruction-{name}-explicit-adoption-preserves-data", {"pvc": self.get("pvc", name), "pv": self.get("pv", old_pv["metadata"]["name"], namespace=None), "payload": self.payload(name)})
        self.record("reconstruction-owned-resources-remaining", {"pods": self.get("pods"), "pvc": self.get("pvc"), "pv": self.get("pv", namespace=None)})

    def cached_withdrawal(self):
        self.pause()
        self.ready("protected")
        self.toolbox()
        before = self.pod("protected")
        before_data = self.payload("protected")
        uid = before["metadata"]["uid"]
        count = before["status"]["containerStatuses"][0]["restartCount"]
        finished = next(s for s in before["status"]["initContainerStatuses"] if s["name"] == "psx-check")["state"]["terminated"]["finishedAt"]
        pvc = self.get("pvc", "protected")
        pv = self.get("pv", pvc["spec"]["volumeName"], namespace=None)
        path = pv["spec"]["local"]["path"]
        held = path + ".held-cached-restart"
        self.operator(f"from pathlib import Path; p=Path({path!r}); h=Path({held!r}); assert not h.exists(); p.rename(h); p.mkdir(mode=0o777); p.chmod(0o777)")
        try:
            self.kubectl("exec", "-n", NS, before["metadata"]["name"], "-c", "application", "--", "python3", "-c", "from pathlib import Path; Path('/tmp/psx-self-exit').touch()")
            def restarted():
                current = self.pod("protected")
                assert current is not None and current["metadata"]["uid"] == uid, "withdrawal must not be hidden by Pod replacement"
                status = current.get("status", {}).get("containerStatuses", [{}])[0]
                return current if status.get("restartCount", 0) > count and status.get("ready") else None
            after = self.wait("cached-withdrawal-application-restart", restarted)
            after_data = self.payload("protected")
            assert after["status"]["containerStatuses"][0]["lastState"]["terminated"]["exitCode"] == 17
            assert next(s for s in after["status"]["initContainerStatuses"] if s["name"] == "psx-check")["state"]["terminated"]["finishedAt"] == finished
            assert after_data["experiment-original-pvc"] == before_data["experiment-original-pvc"]
            assert after_data["init-writes"] == before_data["init-writes"]
            assert after_data["commits"] == before_data["commits"] + "commit\n", "one cached restart must append exactly one application record"
            filesystem = self.operator(f"from pathlib import Path; import json; p=Path({path!r}); h=Path({held!r}); assert list(p.iterdir())==[], 'cached restart wrote substitute'; assert (h/'experiment-original-pvc').read_text()=={before_data['experiment-original-pvc']!r}; assert (h/'commits').read_text()=={after_data['commits']!r}; print(json.dumps({{'substitute_empty':True,'substitute_mode':oct(p.stat().st_mode&0o7777),'held_inode':h.stat().st_ino,'substitute_inode':p.stat().st_ino}}))").stdout
            self.record("cached-restart-after-path-withdrawal", {
                "pod_uid_before": uid, "pod_uid_after": after["metadata"]["uid"],
                "guard_finished_at_before": finished, "guard_finished_at_after": next(s for s in after["status"]["initContainerStatuses"] if s["name"] == "psx-check")["state"]["terminated"]["finishedAt"],
                "restart_count_before": count, "restart_count_after": after["status"]["containerStatuses"][0]["restartCount"],
                "before_payload": before_data, "after_payload": after_data,
                "filesystem": json.loads(filesystem),
            })
        finally:
            # Preserve any failed substitute writes instead of deleting evidence.
            self.operator(f"from pathlib import Path; p=Path({path!r}); h=Path({held!r}); empty=not any(p.iterdir()); assert empty, 'failed substitute preserved; original remains held'; p.rmdir(); h.rename(p)")

    def registry_cases(self):
        self.toolbox()
        root = f'{self.lease["guest_data_root"]}/policy/.cases'
        code = f"""
import concurrent.futures,json,os,sqlite3,subprocess,sys
from pathlib import Path
sys.path.insert(0, '/policy')
import registry
root=Path({root!r})
root.mkdir()
metadata=root/'.registry'
events=[]
def denied(name, fn):
    try:
        fn()
    except (registry.Denied, sqlite3.Error, OSError) as e:
        events.append({{'case':name,'result':'DENIED','reason':str(e)}})
    else:
        raise AssertionError('expected denial: '+name)
path=root/'pvc-uid-original_ns_claim'
denied('missing-history-never-bootstrap', lambda: registry.allocate(root,path))
registry.bootstrap(root)
denied('duplicate-bootstrap', lambda: registry.bootstrap(root))
crash_root=root/'interrupted-bootstrap'
crash_root.mkdir()
bootstrap_child='''import os,sqlite3,sys
from pathlib import Path
sys.path.insert(0,'/policy')
import registry
real_connect=sqlite3.connect
def interrupt_connect(*args,**kwargs):
    connection=real_connect(*args,**kwargs)
    def interrupt(statement):
        if statement.lstrip().upper().startswith('CREATE TABLE ALLOCATIONS'):
            os._exit(71)
    connection.set_trace_callback(interrupt)
    return connection
sqlite3.connect=interrupt_connect
registry.bootstrap(Path(sys.argv[1]))
'''
crash=subprocess.run([sys.executable,'-B','-c',bootstrap_child,str(crash_root)],text=True,capture_output=True)
assert crash.returncode==71,(crash.returncode,crash.stdout,crash.stderr)
denied('interrupted-bootstrap-never-ready',lambda:registry.connect(crash_root/'.registry'))
denied('interrupted-bootstrap-never-auto-rebootstrap',lambda:registry.bootstrap(crash_root))
def provision(_):
    p=subprocess.run([sys.executable,'/policy/registry.py','--root',str(root),'setup','--path',str(path)],text=True,capture_output=True)
    return {{'returncode':p.returncode,'stderr':p.stderr}}
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    retries=list(pool.map(provision,range(2)))
assert all(p['returncode']==0 for p in retries), retries
events.append({{'case':'concurrent-identical-uid-and-retry','results':retries}})
registry.allocate(root,path)
assert list(path.iterdir())==[]
denied('replacement-uid',lambda:registry.allocate(root,root/'pvc-uid-new_ns_claim'))
registry.allocate(root,root/'pvc-uid-other_other-ns_claim')
registry.check(metadata,'other-ns/claim','uid-other',root/'pvc-uid-other_other-ns_claim')
events.append({{'case':'same-name-different-namespace','result':'INDEPENDENT'}})
pending=root/'pvc-uid-pending_ns_pending'
crash=subprocess.run([sys.executable,'/policy/registry.py','--root',str(root),'setup','--path',str(pending),'--fail-after','reserve'])
assert crash.returncode==71
events.append({{'case':'abrupt-process-exit-after-reservation','exit':crash.returncode}})
registry.allocate(root,pending)
registry.check(metadata,'ns/pending','uid-pending',pending)
events.append({{'case':'pending-missing-directory-retry','result':'ACTIVE'}})
ambiguous=root/'pvc-uid-ambiguous_ns_ambiguous'
crash=subprocess.run([sys.executable,'/policy/registry.py','--root',str(root),'setup','--path',str(ambiguous),'--fail-after','mkdir'])
assert crash.returncode==71
events.append({{'case':'abrupt-process-exit-after-mkdir','exit':crash.returncode}})
denied('ambiguous-retry-must-not-import',lambda:registry.allocate(root,ambiguous))
pvc={{'metadata':{{'namespace':'ns','name':'claim','uid':'uid-new'}}}}
denied('stale-adoption',lambda:registry.adopt(root,pvc,'wrong-old-uid','explicit experiment approval'))
registry.adopt(root,pvc,'uid-original','explicit experiment approval; no writers exist')
registry.adopt(root,pvc,'uid-original','idempotent retry')
denied('old-uid-no-longer-authorized',lambda:registry.check(metadata,'ns/claim','uid-original',path))
registry.check(metadata,'ns/claim','uid-new',path)
held=path.with_name('held-original')
path.rename(held)
denied('missing-established-directory',lambda:registry.check(metadata,'ns/claim','uid-new',path))
path.mkdir()
denied('replaced-established-directory',lambda:registry.check(metadata,'ns/claim','uid-new',path))
path.rmdir()
held.rename(path)
sentinel=path/'payload'
sentinel.write_text('committed\\\\n')
sentinel.unlink()
registry.check(metadata,'ns/claim','uid-new',path)
events.append({{'case':'payload-file-loss','result':'LIMIT: directory identity does not validate application contents'}})
reuse=root/'pvc-uid-reuse_ns_reuse'
registry.allocate(root,reuse)
original_inode=reuse.stat().st_ino
reused=False
for attempt in range(1,65):
    reuse.rmdir()
    reuse.mkdir(mode=0o777)
    if reuse.stat().st_ino==original_inode:
        registry.check(metadata,'ns/reuse','uid-reuse',reuse)
        reused=True
        break
events.append({{'case':'delete-recreate-inode-reuse','attempts':attempt,'reused':reused,'result':'COUNTEREXAMPLE: replaced directory accepted' if reused else 'NOT_OBSERVED_IN_64; not a physical identity guarantee'}})
backup=metadata/'backup.sqlite'
con=registry.connect(metadata)
target=sqlite3.connect(backup)
con.backup(target)
target.close()
con.close()
db=metadata/'ownership.sqlite'
lost=metadata/'ownership.sqlite.lost'
db.rename(lost)
denied('lost-registry',lambda:registry.allocate(root,root/'pvc-uid-late_ns_late'))
denied('lost-registry-cannot-rebootstrap-nonempty-root',lambda:registry.bootstrap(root))
db.write_bytes(b'not a SQLite ownership database')
denied('corrupt-registry',lambda:registry.allocate(root,root/'pvc-uid-late_ns_late'))
# Recovery requires quiesced callers and a consistent independent backup.
import shutil
shutil.copyfile(backup,metadata/'restore.tmp')
fd=os.open(metadata/'restore.tmp',os.O_RDONLY);os.fsync(fd);os.close(fd)
os.replace(metadata/'restore.tmp',db)
registry.sync_directory(metadata)
registry.check(metadata,'ns/claim','uid-new',path)
events.append({{'case':'explicit-backup-restore','result':'ACTIVE; retained UID/history preserved'}})
print(json.dumps(events))
"""
        self.record("registry-state-machine-cases", self.operator(code).stdout)
        self.record("registry-cases-cleanup-owned-paths", [root])

    def native(self):
        self.record("server", self.kubectl("version", "-o", "json").stdout)
        self.reconcile("native-infra")
        self.restart_provisioner()
        self.reconcile("native-full")
        snapshots = {}
        for name in ("protected", "unprotected", "disposable"):
            self.ready(name)
            self.identity(name)
            pvc = self.get("pvc", name)
            self.seed(name, pvc["metadata"]["uid"])
            pv = self.get("pv", pvc["spec"]["volumeName"], namespace=None)
            assert "local" in pv["spec"] and "hostPath" not in pv["spec"], "experiment requires local PVs"
            affinity = pv["spec"]["nodeAffinity"]["required"]["nodeSelectorTerms"]
            assert any(e["key"] == "kubernetes.io/hostname" and self.lease["node"] in e["values"] for term in affinity for e in term.get("matchExpressions", [])), "unstable node affinity"
            snapshots[name] = {"pvc": pvc, "pv": pv, "payload": self.payload(name)}
        self.record("native-first-allocation", snapshots)
        old = self.pod("protected")["metadata"]["uid"]
        self.kubectl("delete", "pod", self.pod("protected")["metadata"]["name"], "-n", NS, "--wait=true")
        self.wait("replacement-pod", lambda: self.pod("protected") and self.pod("protected")["metadata"]["uid"] != old)
        self.ready("protected")
        assert self.get("pvc", "protected")["metadata"]["uid"] == snapshots["protected"]["pvc"]["metadata"]["uid"]
        assert self.payload("protected")["experiment-original-pvc"] == snapshots["protected"]["payload"]["experiment-original-pvc"]
        self.record("same-pvc-pod-recreation", self.payload("protected"))
        self.reconcile("native-removed")
        self.wait("unprotected-pvc-pruned", lambda: not self.get("pvc")["items"] or all(p["metadata"]["name"] == "protected" for p in self.get("pvc")["items"]))
        assert self.get("pvc", "protected")["metadata"]["uid"] == snapshots["protected"]["pvc"]["metadata"]["uid"]
        for name in ("protected", "unprotected"):
            pv = self.get("pv", snapshots[name]["pv"]["metadata"]["name"], namespace=None)
            self.record(f"retained-pv-{name}", pv)
        disposable_pv = snapshots["disposable"]["pv"]["metadata"]["name"]
        self.wait("disposable-pv-deleted", lambda: self.kubectl("get", "pv", disposable_pv, "--ignore-not-found", "-o", "name").stdout == "")
        self.toolbox(policy=False)
        for name in ("protected", "unprotected"):
            path = snapshots[name]["pv"]["spec"]["local"]["path"]
            self.record(f"retained-payload-{name}", self.operator(f"from pathlib import Path; p=Path({path!r}); assert (p/'experiment-original-pvc').read_text()=={snapshots[name]['payload']['experiment-original-pvc']!r}; print((p/'experiment-original-pvc').read_text())").stdout)
        path = snapshots["disposable"]["pv"]["spec"]["local"]["path"]
        self.operator(f"from pathlib import Path; assert not Path({path!r}).exists(), 'Delete PV left its payload'")
        self.record("disposable-payload-removed", path)
        self.kubectl("delete", "pod", "psx-operator", "-n", NS, "--wait=true")
        # Recreate desired claims through Argo. Stock provisioning allocates new
        # empty data for the unprotected new UID; it does not safely adopt Retain.
        self.reconcile("native-full")
        self.ready("unprotected")
        current = self.get("pvc", "unprotected")
        assert current["metadata"]["uid"] != snapshots["unprotected"]["pvc"]["metadata"]["uid"]
        assert current["spec"]["volumeName"] != snapshots["unprotected"]["pv"]["metadata"]["name"]
        assert "experiment-original-pvc" not in self.payload("unprotected")
        self.record("stock-new-uid-fresh-substitute", {"pvc": current, "payload": self.payload("unprotected")})
        # Application cascade deletion tests Delete=false independently of prune.
        self.kubectl("delete", "application", APP, "-n", self.lease.get("argo_namespace", "argocd"), "--wait=true", "--timeout=180s")
        self.record("delete-false-survives-application", self.get("pvc", "protected"))
        self.record("native-owned-resources-remaining", {"pvc": self.get("pvc"), "pv": self.get("pv", namespace=None)})


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--lease", type=Path, required=True)
    sub = p.add_subparsers(dest="operation", required=True)
    rendering = sub.add_parser("render")
    rendering.add_argument("--destination", type=Path, required=True, help="disposable Git fixture tree, outside the public source repository")
    for operation in ("native", "policy", "registry-cases", "cached-withdrawal"):
        command = sub.add_parser(operation)
        command.add_argument("--output", type=Path, required=True)
    recovery = sub.add_parser("recover")
    recovery.add_argument("--output", type=Path, required=True)
    recovery.add_argument("--prior", type=Path, required=True)
    recovery.add_argument("--approval", required=True)
    args = p.parse_args()
    lease = json.loads(args.lease.read_text())
    if args.operation == "render":
        fixtures(lease, args.destination)
    else:
        run = Run(lease, args.output)
        try:
            if args.operation == "recover":
                run.recover(args.prior, args.approval)
            elif args.operation == "registry-cases":
                run.registry_cases()
            elif args.operation == "cached-withdrawal":
                run.cached_withdrawal()
            else:
                getattr(run, args.operation)()
        except Exception as e:
            run.record("failure", {"type": type(e).__name__, "message": str(e)})
            raise


if __name__ == "__main__":
    main()
