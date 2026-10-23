"""Source checks and bounded local subprocess cleanup; no API or mount capability claim."""

import importlib.machinery
import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace
import subprocess
import sys
import tempfile
import threading
import time
from unittest.mock import patch


source = Path(sys.argv[1]) if len(sys.argv) > 1 else (
    Path(__file__).parents[1] / "den/aspects/services/retained-runtime-hook.py")
spec = importlib.util.spec_from_file_location(
    "retained_runtime_hook", source,
    loader=importlib.machinery.SourceFileLoader("retained_runtime_hook", str(source)))
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


def deadline_cleanup():
    original_commands, original_popen = hook.Commands, subprocess.Popen
    for stalled_input in (False, True):
        processes = []
        reader, writer = os.pipe()
        finished = threading.Event()

        def command_budget():
            command = original_commands()
            assert 0 < command.deadline - time.monotonic() < 30
            command.deadline = time.monotonic() + 2
            return command

        def spawn(*args, **kwargs):
            process = original_popen(*args, **kwargs)
            processes.append(process)
            return process

        def work(_state, command):
            command.run([sys.executable, "-c", "import time; time.sleep(60)"])

        def send_state():
            with os.fdopen(writer, "wb") as stream:
                if stalled_input:
                    finished.wait()
                else:
                    time.sleep(0.2)
                    stream.write(b"{}")

        sender = threading.Thread(target=send_state)
        sender.start()
        started = time.monotonic()
        try:
            with patch.object(hook, "Commands", side_effect=command_budget), \
                    patch.object(hook, "run", side_effect=work), \
                    patch.object(hook.subprocess, "Popen", side_effect=spawn), \
                    patch.object(hook.sys, "stdin", SimpleNamespace(fileno=lambda: reader)), \
                    patch.object(hook.sys, "argv", ["retained-runtime-hook"]):
                assert hook.main() == 1
            assert time.monotonic() - started < (4 if stalled_input else 5), (
                "stdin or subprocess ignored the shared two-second request budget")
            if stalled_input:
                assert not processes, "work started after stdin exhausted the request budget"
            else:
                assert len(processes) == 1 and processes[0].returncode is not None
                assert all(stream.closed for stream in (processes[0].stdout, processes[0].stderr))
        finally:
            finished.set()
            sender.join(timeout=5)
            os.close(reader)
            for process in processes:
                if process.poll() is None:
                    process.kill()
                process.wait()


def main():
    deadline_cleanup()
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
    unicode_paths = ["/x\u00a0-\u00a0y", "/x\u2028-\u2028y"]
    text = "".join(f"{20 + i} 1 0:9 /cache\u00a0root {path} rw - tmpfs independent rw\n"
                   for i, path in enumerate(unicode_paths))
    with patch.object(hook, "file_at", return_value=text.encode()):
        unicode_rows = hook.mountinfo(None)
    for i, (actual, path) in enumerate(zip(unicode_rows, unicode_paths)):
        assert actual.id == 20 + i and actual.path == path and actual.root == "/cache\u00a0root"
        assert actual.source(path + "/app") == {
            "fsType": "tmpfs", "name": "independent", "root": "/cache\u00a0root/app"}
        denied(lambda: actual.source("/x/forbidden"))
    assert len(unicode_rows) == 2
    denied(lambda: hook.Mount("42 1 0:9 / /data - tmpfs independent rw"))
    publication = "/var/lib/kubelet/pods/pod-uid/volumes/kubernetes.io~local-volume/pv-one"
    mount = {"source": publication, "destination": "/data", "type": "bind", "options": ["rw", "rbind"]}
    child = SimpleNamespace(rows=[row(10, "/app", "/data")] + unicode_rows)
    config = {"mounts": [mount]}
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
    denied(lambda: hook.publication(publication + "/nested", node["kubeletRoot"], True))
    denied(lambda: hook.publication(publication.replace("local-volume", "csi"), node["kubeletRoot"], True))
    unrelated = SimpleNamespace(rows=[row(12, "/", "/data", fs="tmpfs", name="independent")])
    for plugin in ("csi", "host-path"):
        unsupported = {"mounts": [dict(mount, source=publication.replace("local-volume", plugin))]}
        assert hook.classify(unsupported, unrelated, node) == []
        denied(lambda: hook.classify(unsupported, child, node))
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
    native = SimpleNamespace(cgroup=lambda: group, rows=child.rows)
    api = SimpleNamespace(dependency=lambda *_: "/srv/state/app")
    candidate = (mount, (pod_uid, "pv-one", None), row(10, "/app", "/data"))
    denied(lambda: hook.retained_dependencies([
        (mount, ("87654321-4321-4321-cba987654321", "pv-one", None), candidate[2])],
        api, native, node, config))
    denied(lambda: hook.retained_dependencies([
        (dict(mount, options=["ro", "bind"]), candidate[1], candidate[2])], api, native, node, config))
    denied(lambda: hook.retained_dependencies([
        (mount, candidate[1], row(10, "/app", "/data", "ro"))], api, native, node, config))
    external = SimpleNamespace(dependency=lambda *_: "/srv/cache/independent")
    assert hook.retained_dependencies([
        (dict(mount, options=["ro", "bind"]), candidate[1],
         row(20, "/", "/data", "ro", fs="tmpfs", name="independent"))], external, native, node, config) == []
    denied(lambda: hook.retained_dependencies([candidate], external, native, node, config))

    def dependencies(config, child, api):
        return hook.retained_dependencies(hook.classify(config, child, node), api, child, node, config)

    published = dict(mount, source=publication.replace("pod-uid", pod_uid))
    configmap = {"source": publication.replace("pod-uid", pod_uid).replace(
        "local-volume/pv-one", "configmap/settings"), "destination": "/data/config",
        "type": "bind", "options": ["ro", "rbind"]}
    nested = row(31, "/", "/data/config", "ro", fs="tmpfs", name="settings")
    for declared in ([published, configmap], [published]):
        nested_config = {"mounts": declared}
        external_child = SimpleNamespace(cgroup=lambda: group, rows=[
            row(30, "/", "/data", fs="tmpfs", name="independent"), nested])
        assert dependencies(nested_config, external_child, external) == []
        retained_child = SimpleNamespace(cgroup=lambda: group, rows=[row(30, "/app", "/data"), nested])
        denied(lambda: dependencies(nested_config, retained_child, api))
    denied(lambda: dependencies({"mounts": [root_view, configmap]}, SimpleNamespace(
        rows=root_child.rows + [nested]), api))

    many = [dict(published, source=published["source"].replace("pv-one", f"pv-{i}"),
                 destination=f"/volume{i}") for i in range(17)]
    external_child = SimpleNamespace(cgroup=lambda: group, rows=[
        row(100 + i, "/", f"/volume{i}", fs="tmpfs", name="independent") for i in range(17)])
    assert dependencies({"mounts": many}, external_child, external) == []
    retained_child = SimpleNamespace(cgroup=lambda: group, rows=[
        row(100 + i, "/app", f"/volume{i}") for i in range(17)])
    denied(lambda: dependencies({"mounts": many}, retained_child, api))
    retained_child.rows = retained_child.rows[:16]
    assert len(dependencies({"mounts": many[:16]}, retained_child, api)) == 16

    denied(lambda: hook.publication("/var/lib", node["kubeletRoot"], False))
    denied(lambda: hook.publication("/var/lib/kubelet", node["kubeletRoot"], False))
    denied(lambda: hook.cgroup_pod_uid("/system.slice/unrelated.scope"))
    denied(lambda: hook.decode(b'{"id":1,"id":2}', "duplicate"))
    denied(lambda: hook.decode(b'{"id":NaN}', "nonfinite"))
    denied(lambda: hook.decode(b"[]", "not object"))
    denied(lambda: hook.decode(b"{}" + b" " * hook.LIMIT, "oversized"))
    denied(lambda: hook.absolute("/srv/state/../other"))
    assert hook.mount_path("/etc/config/") == "/etc/config"
    assert hook.mount_path("//etc/./config//") == "/etc/config"
    denied(lambda: hook.mount_path("/bad\x00/../safe"))
    denied(lambda: hook.entry_metadata({"id": "stable-app-id", "uid": True, "gid": 0, "mode": "0700"}))

    # Binding coherence applies to dynamically created local PVs just as to static ones.
    api = hook.API(None, node)
    pv = {"metadata": {"name": "pv-one", "uid": "pv-id"}, "spec": {
        "local": {"path": "/srv/state/apps.claim-one"}, "storageClassName": "retained-local",
        "claimRef": {"namespace": "apps", "name": "claim-one", "uid": "claim-id"}}, "status": {"phase": "Bound"}}
    pvc = {"metadata": {"name": "claim-one", "namespace": "apps", "uid": "claim-id"},
           "spec": {"volumeName": "pv-one", "storageClassName": "retained-local"}, "status": {"phase": "Bound"}}
    pod = {"metadata": {"namespace": "apps", "uid": pod_uid}, "spec": {
        "nodeName": os.uname().nodename,
        "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "claim-one"}}],
        "containers": [{"name": "ordinary-app", "volumeMounts": [
            {"name": "data", "mountPath": "/data", "mountPropagation": "None"}]}]}}
    api.cache = {("persistentvolume", "pv-one", None): pv,
                 ("persistentvolumeclaim", "claim-one", "apps"): pvc,
                 ("pods", None, "apps"): {"items": [pod]},
                 ("pods", None, None): {"items": [pod]}}
    assert api.dependency(pod_uid, "pv-one", "/data") == "/srv/state/apps.claim-one"
    pod["spec"]["containers"][0]["volumeMounts"][0]["mountPath"] = "/data/"
    assert api.dependency(pod_uid, "pv-one", "/data") == "/srv/state/apps.claim-one"
    denied(lambda: api.dependency("stale-pod-uid", "pv-one", "/data"))
    denied(lambda: api.dependency(pod_uid, "pv-one", "/other"))
    pod["spec"]["containers"][0]["volumeMounts"][0]["subPath"] = "nested"
    denied(lambda: api.dependency(pod_uid, "pv-one", "/data"))
    subpath_config = {"mounts": [dict(
        mount, source=f"/var/lib/kubelet/pods/{pod_uid}/volume-subpaths/pv-one/ordinary-app/0")]}
    replacement = SimpleNamespace(cgroup=lambda: group, rows=[
        row(40, "/nested", "/data", fs="tmpfs", name="replacement")])
    volumes = pod["spec"]["volumes"]
    mounts = pod["spec"]["containers"][0]["volumeMounts"]
    volumes.extend([
        {"name": "alias", "persistentVolumeClaim": {"claimName": "claim-one"}},
        {"name": "pv-one", "configMap": {"name": "settings"}}])
    mounts.append({"name": "pv-one", "mountPath": "/config"})
    with tempfile.TemporaryDirectory() as kubelet:
        previous = node["kubeletRoot"]
        node["kubeletRoot"] = str(Path(kubelet).resolve())
        (Path(node["kubeletRoot"]) / "pods" / pod_uid / "volumes" /
         "kubernetes.io~configmap" / "pv-one").mkdir(parents=True)
        collision = {"mounts": [dict(mount, source=subpath_config["mounts"][0]["source"].replace(
            previous, node["kubeletRoot"], 1))]}
        try:
            denied(lambda: dependencies(collision, replacement, api))
        finally:
            node["kubeletRoot"] = previous
    pv["spec"]["local"]["path"] = "/srv/cache/independent"
    pv["spec"]["storageClassName"] = pvc["spec"]["storageClassName"] = ""
    mounts.insert(0, {"name": "data", "mountPath": "/other"})
    denied(lambda: dependencies(subpath_config, replacement, api))
    indexed = {"mounts": [dict(mount, source=subpath_config["mounts"][0]["source"][:-1] + "1")]}
    assert dependencies(indexed, replacement, api) == []
    mounts[1]["mountPropagation"] = "HostToContainer"
    denied(lambda: dependencies(indexed, replacement, api))
    mounts[1]["mountPropagation"] = "None"
    del mounts[0]
    volume = volumes[0]
    volumes[0] = {"name": "data", "hostPath": {"path": "/srv/state/app"}}
    hostpath_config = {"mounts": [dict(
        mount, source=f"/var/lib/kubelet/pods/{pod_uid}/volume-subpaths/data/ordinary-app/0")]}
    denied(lambda: dependencies(hostpath_config, replacement, api))
    volumes[0]["hostPath"]["path"] = "/srv/cache/independent"
    assert dependencies(hostpath_config, replacement, api) == []
    volumes[0] = volume
    del volumes[1:]
    del mounts[1:]
    pv["spec"]["local"]["path"] = "/srv/state/apps.claim-one"
    pv["spec"]["storageClassName"] = pvc["spec"]["storageClassName"] = "retained-local"
    del pod["spec"]["containers"][0]["volumeMounts"][0]["subPath"]
    pv["spec"]["local"]["path"] = "/srv/escaped"
    denied(lambda: api.dependency(pod_uid, "pv-one", "/data"))
    pv["spec"]["local"]["path"] = "/srv/state/apps.claim-one"
    pvc["metadata"]["uid"] = "replaced-claim"
    denied(lambda: api.dependency(pod_uid, "pv-one", "/data"))
    print("retained runtime source checks passed")


if __name__ == "__main__":
    main()
