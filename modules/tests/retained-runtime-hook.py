"""Pure source checks only; no API, mounts, subprocesses or native capability claim."""

import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace


source = Path(__file__).parents[1] / "den/aspects/services/retained-runtime-hook.py"
spec = importlib.util.spec_from_file_location("retained_runtime_hook", source)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


def denied(fn):
    try:
        fn()
    except hook.Denied:
        return
    raise AssertionError("unsafe case was accepted")


def row(identity, root, destination, options="rw", fs="virtiofs", name="retained"):
    return hook.Mount(f"{identity} 1 0:42 {root} {destination} {options} - {fs} {name} rw")


def main():
    ns = hook.Mount("419 414 0:4 net:[4026532423] /run/netns/cni-test rw - nsfs nsfs rw")
    assert ns.source("/run/netns/cni-test") == {"fsType": "nsfs", "name": "nsfs", "root": "net:[4026532423]"}
    denied(lambda: hook.Mount(
        "419 414 0:4 net:[4026532423] /run/netns/cni-test rw - zfs pool rw").source("/run/netns/cni-test"))
    native_root = "/run/containerd/bundle/rootfs"
    rows = hook.container_mounts([
        row(1, "/", "/", fs="overlay", name="overlay"),
        row(2, "/", "/srv/state"),
        row(3, "/", native_root, fs="overlay", name="overlay"),
        row(4, "/app", native_root + "/data"),
        row(5, "/", native_root + "-other/data"),
        row(6, "/old//deleted", "/run/unrelated"),
    ], native_root)
    assert [(item.id, item.path) for item in rows] == [(3, "/"), (4, "/data")]
    assert rows[1].source("/data")["root"] == "/app"
    denied(lambda: hook.container_mounts([row(1, "/", "/")], native_root))
    node = {"kubeletRoot": "/var/lib/kubelet", "root": {
        "path": "/srv/state", "source": {"fsType": "virtiofs", "name": "retained", "root": "/"}}}
    publication = "/var/lib/kubelet/pods/pod-uid/volumes/kubernetes.io~local-volume/pv-one"
    mount = {"source": publication, "destination": "/data", "type": "bind", "options": ["rw", "rbind"]}
    child = SimpleNamespace(rows=[row(10, "/app", "/data")])
    config = {"mounts": [mount]}
    assert hook.classify(config, child, node)[0][1] == ("pod-uid", "pv-one")
    # No RuntimeClass, image, CRI annotations or retained opt-in are involved.
    ignored_annotation = dict(config, annotations={"retained-disabled": "true"})
    assert hook.classify(ignored_annotation, child, node)[0][1] == ("pod-uid", "pv-one")
    assert child.rows[0].source("/data") == {"fsType": "virtiofs", "name": "retained", "root": "/app"}
    assert row(11, "/wrong", "/data").source("/data") != child.rows[0].source("/data")
    denied(lambda: hook.classify({"mounts": [dict(mount, source="/srv/state/app")]}, child, node))
    denied(lambda: hook.classify({"mounts": [dict(mount, source="/tmp/unclassified")]}, child, node))
    denied(lambda: hook.classify(config, SimpleNamespace(rows=child.rows + [row(11, "/app/nested", "/data/nested")]), node))
    denied(lambda: hook.classify({"mounts": [mount, dict(mount, destination="/data/nested")]}, child, node))
    denied(lambda: hook.classify({"mounts": []}, child, node))
    unusable = row(15, "/app//deleted", "/data")
    denied(lambda: hook.classify(config, SimpleNamespace(rows=[unusable]), node))
    denied(lambda: hook.classify(config, SimpleNamespace(rows=[]), node))
    # An unusable actual mount must not disappear into the unrelated fast path,
    # even when the OCI list omits it or declares an ordinary ephemeral source.
    denied(lambda: hook.classify({"mounts": []}, SimpleNamespace(rows=[unusable]), node))
    denied(lambda: hook.classify({"mounts": [dict(mount, source="tmpfs", type="tmpfs")]},
                                 SimpleNamespace(rows=[unusable]), node))
    denied(lambda: hook.publication(publication + "/nested", node["kubeletRoot"]))
    denied(lambda: hook.publication(publication.replace("local-volume", "csi"), node["kubeletRoot"]))
    root_view = dict(mount, source="/srv/state", options=["ro", "bind"])
    root_child = SimpleNamespace(rows=[row(13, "/", "/data", "ro")])
    assert hook.classify({"mounts": [root_view]}, root_child, node)[0][1] is None
    assert hook.classify({"mounts": [dict(root_view, source="/srv/state/")]}, root_child, node)[0][0]["source"] == "/srv/state"
    denied(lambda: hook.classify({"mounts": [dict(root_view, options=["rw", "bind"])]}, root_child, node))
    denied(lambda: hook.classify({"mounts": [root_view]}, child, node))
    denied(lambda: hook.classify({"mounts": [dict(root_view, source="/srv")]}, root_child, node))
    denied(lambda: hook.classify({"mounts": [root_view]}, SimpleNamespace(
        rows=root_child.rows + [row(14, "/app", "/data/app")]), node))
    for plugin in ("secret", "configmap", "empty-dir", "projected"):
        ordinary = {"mounts": [dict(mount, source=publication.replace("local-volume", plugin))]}
        unrelated = SimpleNamespace(rows=[row(12, "/", "/data", fs="tmpfs", name="tmpfs")])
        assert hook.classify(ordinary, unrelated, node) == []
        assert hook.classify({"mounts": [dict(ordinary["mounts"][0], destination="/data/")]}, unrelated, node) == []
    assert hook.escape_mount("/srv/state") == "srv-state.mount"
    assert hook.escape_mount("/srv/state-data") == "srv-state\\x2ddata.mount"
    assert hook.escape_mount("/.state") == "\\x2estate.mount"
    pod_uid = "12345678-1234-1234-1234-123456789abc"
    for qos in ("", "-burstable", "-besteffort"):
        group = "/kubepods.slice/kubepods" + qos + "-pod" + pod_uid.replace("-", "_") + ".slice/cri-containerd-id.scope"
        assert hook.cgroup_pod_uid(group) == pod_uid
    native = SimpleNamespace(cgroup=lambda: group)
    api = SimpleNamespace(dependency=lambda *_: "/srv/state/app")
    candidate = (mount, (pod_uid, "pv-one"), row(10, "/app", "/data"))
    assert len(hook.retained_dependencies([candidate], api, native, node)) == 1
    denied(lambda: hook.retained_dependencies([
        (dict(mount, options=["ro", "bind"]), candidate[1], candidate[2])], api, native, node))
    denied(lambda: hook.retained_dependencies([
        (mount, candidate[1], row(10, "/app", "/data", "ro"))], api, native, node))
    external = SimpleNamespace(dependency=lambda *_: "/srv/cache/independent")
    assert hook.retained_dependencies([
        (dict(mount, options=["ro", "bind"]), candidate[1],
         row(20, "/", "/data", "ro", fs="tmpfs", name="independent"))], external, native, node) == []
    denied(lambda: hook.retained_dependencies([candidate], external, native, node))
    denied(lambda: hook.publication("/var/lib", node["kubeletRoot"]))
    denied(lambda: hook.publication("/var/lib/kubelet", node["kubeletRoot"]))
    denied(lambda: hook.cgroup_pod_uid("/system.slice/unrelated.scope"))
    denied(lambda: hook.decode(b'{"id":1,"id":2}', "duplicate"))
    denied(lambda: hook.decode(b'{"id":NaN}', "nonfinite"))
    denied(lambda: hook.decode(b"[]", "not object"))
    denied(lambda: hook.decode(b" " * (hook.LIMIT + 1), "oversized"))
    denied(lambda: hook.absolute("/srv/state/../other"))
    assert hook.mount_path("/etc/config/") == "/etc/config"
    assert hook.mount_path("//etc/./config//") == "/etc/config"
    denied(lambda: hook.mount_path("/bad\x00/../safe"))
    hook.entry_metadata({"id": "stable-app-id", "uid": 1000, "gid": 1000, "mode": "700"})
    denied(lambda: hook.entry_metadata({"id": "stable-app-id", "uid": True, "gid": 0, "mode": "0700"}))

    # Binding coherence applies to dynamically created local PVs just as to static ones.
    api = hook.API(None, node)
    pv = {"metadata": {"name": "pv-one", "uid": "pv-id"}, "spec": {
        "local": {"path": "/srv/state/apps.claim-one"}, "storageClassName": "retained-local",
        "claimRef": {"namespace": "apps", "name": "claim-one", "uid": "claim-id"}}, "status": {"phase": "Bound"}}
    pvc = {"metadata": {"name": "claim-one", "namespace": "apps", "uid": "claim-id"},
           "spec": {"volumeName": "pv-one", "storageClassName": "retained-local"}, "status": {"phase": "Bound"}}
    pod = {"metadata": {"namespace": "apps", "uid": "pod-uid"}, "spec": {
        "nodeName": os.uname().nodename,
        "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "claim-one"}}],
        "containers": [{"name": "ordinary-app", "volumeMounts": [{"name": "data", "mountPath": "/data"}]}]}}
    api.cache = {("persistentvolume", "pv-one", None): pv,
                 ("persistentvolumeclaim", "claim-one", "apps"): pvc,
                 ("pods", None, "apps"): {"items": [pod]}}
    assert api.dependency("pod-uid", "pv-one", "/data") == "/srv/state/apps.claim-one"
    pod["spec"]["containers"][0]["volumeMounts"][0]["mountPath"] = "/data/"
    assert api.dependency("pod-uid", "pv-one", "/data") == "/srv/state/apps.claim-one"
    denied(lambda: api.dependency("stale-pod-uid", "pv-one", "/data"))
    denied(lambda: api.dependency("pod-uid", "pv-one", "/other"))
    pod["spec"]["containers"][0]["volumeMounts"][0]["subPath"] = "nested"
    denied(lambda: api.dependency("pod-uid", "pv-one", "/data"))
    del pod["spec"]["containers"][0]["volumeMounts"][0]["subPath"]
    pv["spec"]["local"]["path"] = "/srv/escaped"
    denied(lambda: api.dependency("pod-uid", "pv-one", "/data"))
    pv["spec"]["local"]["path"] = "/srv/state/apps.claim-one"
    pvc["metadata"]["uid"] = "replaced-claim"
    denied(lambda: api.dependency("pod-uid", "pv-one", "/data"))
    print("retained runtime source checks passed")


if __name__ == "__main__":
    main()
