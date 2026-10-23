"""Mandatory OCI createRuntime hook; native guard semantics require the VM proof.

No retained opt-in annotations are consulted. The host wrapper must install this
for every CRI handler, with systemd cgroups and a trusted, root-owned descriptor.
The wrapper/security policy must deny host namespaces, privileged containers,
CAP_SYS_ADMIN, host filesystem access and mount propagation to applications.
Writers require full-directory kubelet local-volume publications. Static and
dynamic local PVs must name exactly one declared, established inventory leaf.
A generic exact-root read-only bind supports nonmutating publication helpers;
it validates only the root and receives the same native source/scope guard.
The guard revokes source mount loss, not per-entry changes on a still-live mount.
"""

import contextlib
import errno
import json
import os
import posixpath
import re
import select
import selectors
import shutil
import stat
import subprocess
import sys
import time


NODE = "/etc/homelab/retained-node.json"
LIMIT = 1024 * 1024
ENV = {"PATH": "/run/current-system/sw/bin:/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "HOME": "/root"}
NOFOLLOW = os.O_NOFOLLOW | os.O_CLOEXEC
DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW
NAME = re.compile(r"[a-z0-9](?:[-a-z0-9.]{0,251}[a-z0-9])?\Z")
UID = re.compile(r"[a-zA-Z0-9][-a-zA-Z0-9_.]{0,127}\Z")
CONTAINER = re.compile(r"[a-f0-9]{64}\Z")


class Denied(Exception):
    pass


def require(ok, reason):
    if not ok:
        raise Denied(reason)


def absolute(value):
    require(isinstance(value, str) and value.startswith("/") and all(32 <= ord(char) != 127 for char in value)
            and posixpath.normpath(value) == value and "//" not in value,
            "noncanonical absolute path")
    return value


def mount_path(value):
    # OCI/Kubernetes mount paths use Linux syntax, not descriptor syntax.
    require(isinstance(value, str) and value.startswith("/")
            and all(32 <= ord(char) != 127 for char in value), "invalid mount path")
    return absolute(posixpath.normpath("/" + value.lstrip("/")))


def inside(path, parent):
    return path == parent or path.startswith(parent.rstrip("/") + "/")


def overlaps(left, right):
    return inside(left, right) or inside(right, left)


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def decode(data, label):
    require(len(data) <= LIMIT, label + " exceeds JSON limit")
    try:
        value = json.loads(data, object_pairs_hook=pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(Denied("nonfinite JSON number")))
    except (ValueError, UnicodeError, RecursionError) as error:
        raise Denied(label + " is not valid JSON") from error
    require(isinstance(value, dict), label + " must be a JSON object")
    return value


def read_fd(fd, limit=LIMIT, deadline=None):
    parts = []
    size = 0
    while True:
        if deadline is not None:
            remaining = deadline - time.monotonic()
            require(remaining > 0 and select.select([fd], [], [], remaining)[0], "stdin deadline exceeded")
        data = os.read(fd, min(65536, limit + 1 - size))
        if not data:
            return b"".join(parts)
        parts.append(data)
        size += len(data)
        require(size <= limit, "input exceeds byte limit")


@contextlib.contextmanager
def directory(path, base=None):
    """Walk every component relative to an already pinned descriptor."""
    if base is None:
        absolute(path)
        fd = os.open("/", DIRECTORY)
    else:
        require(not path.startswith("/"), "relative descriptor path required")
        fd = os.dup(base)
    try:
        for part in path.split("/"):
            if not part:
                continue
            require(part not in (".", ".."), "unsafe traversal component")
            child = os.open(part, DIRECTORY, dir_fd=fd)
            os.close(fd)
            fd = child
        yield fd
    finally:
        os.close(fd)


def file_at(base, name, owner=None):
    require(name not in ("", ".", "..") and "/" not in name, "unsafe file name")
    fd = os.open(name, os.O_RDONLY | NOFOLLOW | os.O_NONBLOCK, dir_fd=base)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode), "expected regular file: " + name)
        if owner is not None:
            require((info.st_uid, info.st_gid) == owner and stat.S_IMODE(info.st_mode) == 0o444
                    and info.st_nlink == 1, "untrusted retained receipt: " + name)
        return read_fd(fd)
    finally:
        os.close(fd)


def trusted_path(path):
    """Nix /etc and system-profile links are allowed only in root-controlled paths."""
    absolute(path)
    for candidate in (path, os.path.realpath(path)):
        current = "/"
        for part in candidate.strip("/").split("/"):
            current = posixpath.join(current, part)
            info = os.lstat(current)
            require(info.st_uid == 0 and (stat.S_ISLNK(info.st_mode) or not info.st_mode & 0o022
                    or stat.S_ISDIR(info.st_mode) and info.st_mode & stat.S_ISVTX),
                    "untrusted host path: " + current)
    return os.path.realpath(path)


def node_descriptor():
    path = trusted_path(NODE)
    with directory(posixpath.dirname(path)) as parent:
        node = decode(file_at(parent, posixpath.basename(path)), "node descriptor")
    require(node.get("version") == 1 and type(node["version"]) is int, "unsupported node descriptor version")
    root = node.get("root")
    require(isinstance(root, dict), "node descriptor lacks root")
    absolute(root.get("path"))
    require(root["path"] != "/", "retained root cannot be filesystem root")
    source = root.get("source")
    require(isinstance(source, dict) and set(source) == {"fsType", "name", "root"}
            and all(isinstance(value, str) and value and not any(ord(c) < 32 for c in value)
                    for value in source.values()), "invalid declared source coordinates")
    absolute(source["root"])
    require(isinstance(root.get("id"), str) and root["id"], "missing retained root identity")
    marker = root.get("marker")
    require(isinstance(marker, str) and marker not in ("", ".", "..")
            and "/" not in marker and "\x00" not in marker, "invalid root marker basename")
    for key in ("k3s", "helper", "systemctl", "systemdRun"):
        path = absolute(node.get(key))
        require(re.fullmatch(r"/[A-Za-z0-9_./+-]+", path), "unsafe executable path: " + key)
        trusted_path(path)
        require(os.access(node[key], os.X_OK), "host executable is not executable: " + key)
    require(node.get("kubeletRoot") == "/var/lib/kubelet"
            and node.get("inventoryNamespace") == "local-path-storage"
            and node.get("inventoryName") == "retained-directories"
            and node.get("inventoryKey") == "directories.json", "unsupported node descriptor inventory coordinates")
    return node


class Commands:
    def __init__(self):
        self.deadline = time.monotonic() + 45

    def run(self, argv, data=None, limit=LIMIT):
        require(data is None or len(data) <= LIMIT, "subprocess stdin exceeds byte limit")
        deadline = min(self.deadline, time.monotonic() + 10)
        require(deadline > time.monotonic(), "hook request deadline exceeded")
        process = subprocess.Popen(argv, stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV, close_fds=True)
        output = {"stdout": bytearray(), "stderr": bytearray()}
        sent = 0
        try:
            with selectors.DefaultSelector() as streams:
                for stream, kind in ((process.stdout, "stdout"), (process.stderr, "stderr")):
                    os.set_blocking(stream.fileno(), False)
                    streams.register(stream, selectors.EVENT_READ, kind)
                if data is not None:
                    os.set_blocking(process.stdin.fileno(), False)
                    streams.register(process.stdin, selectors.EVENT_WRITE, "stdin")
                while streams.get_map():
                    remaining = deadline - time.monotonic()
                    require(remaining > 0, "subprocess deadline exceeded: " + posixpath.basename(argv[0]))
                    for key, _ in streams.select(remaining):
                        if key.data == "stdin":
                            if sent < len(data):
                                sent += os.write(key.fd, data[sent:sent + 65536])
                            if sent == len(data):
                                streams.unregister(key.fileobj)
                                key.fileobj.close()
                        else:
                            chunk = os.read(key.fd, 65536)
                            if not chunk:
                                streams.unregister(key.fileobj)
                                key.fileobj.close()
                            else:
                                output[key.data].extend(chunk)
                                require(len(output[key.data]) <= (limit if key.data == "stdout" else 65536),
                                        "subprocess output exceeds byte limit")
                status = process.wait(timeout=max(0.001, deadline - time.monotonic()))
            detail = output["stderr"].decode("utf-8", "replace").replace("\n", " ")[:512]
            require(status == 0, posixpath.basename(argv[0]) + " failed: " + detail)
            return bytes(output["stdout"])
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()


class Mount:
    def __init__(self, line):
        fields = line.split()
        split = fields.index("-")
        require(split >= 6 and len(fields) >= split + 4, "malformed mountinfo row")
        self.id = int(fields[0])
        self.device = fields[2]
        # Keep unusable roots until scope/identity selection; dropping rows can
        # hide an unclassified retained mount from the child-namespace scan.
        self.root = unescape(fields[3])
        self.path = absolute(unescape(fields[4]))
        self.options = set(fields[5].split(","))
        self.fs = unescape(fields[split + 1])
        self.name = unescape(fields[split + 2])
        self.super_options = set(fields[split + 3].split(","))

    def source(self, path):
        if not (self.fs == "nsfs" and re.fullmatch(r"[a-z_]+:\[[0-9]+\]", self.root)):
            absolute(self.root)
        require(inside(path, self.path), "path is outside selected mount")
        relative = posixpath.relpath(path, self.path)
        return {"fsType": self.fs, "name": self.name,
                "root": self.root if relative == "." else posixpath.join(self.root, relative)}

    def writable(self):
        require("rw" in self.options and "ro" not in self.options and "ro" not in self.super_options,
                "retained mount is read-only")

    def readonly(self):
        require("ro" in self.options and "rw" not in self.options, "root view is not actually read-only")


def unescape(value):
    return re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), value)


def mountinfo(base):
    text = file_at(base, "mountinfo").decode("utf-8", "strict")
    rows = [Mount(line) for line in text.splitlines()]
    require(len(rows) <= 8192 and len({row.id for row in rows}) == len(rows), "invalid mountinfo table")
    return rows


def container_mounts(rows, root):
    """createRuntime is pre-pivot: restrict the namespace to its bundle rootfs."""
    result = []
    for row in rows:
        if inside(row.path, root):
            row.path = "/" + posixpath.relpath(row.path, root) if row.path != root else "/"
            result.append(row)
    require(any(row.path == "/" for row in result), "container bundle rootfs has no native mount")
    return result


def mount_id(fd):
    with directory("/proc/" + str(os.getpid()) + "/fdinfo") as info:
        text = file_at(info, str(fd)).decode("ascii")
    values = [line.split(":", 1)[1].strip() for line in text.splitlines() if line.startswith("mnt_id:")]
    require(len(values) == 1, "descriptor has no unique mount identity")
    return int(values[0])


def mounted_fd(rows, fd):
    identity = mount_id(fd)
    selected = [row for row in rows if row.id == identity]
    require(len(selected) == 1, "pinned mount is no longer published")
    row = selected[0]
    device = os.fstat(fd).st_dev
    require(row.device == str(os.major(device)) + ":" + str(os.minor(device)), "mount device differs from descriptor")
    return row


def same_object(*fds):
    identities = {(os.fstat(fd).st_dev, os.fstat(fd).st_ino) for fd in fds}
    require(len(identities) == 1, "current leaf, kubelet publication and actual destination differ")


def cgroup_pod_uid(group):
    matches = []
    pattern = (r"kubepods(?:-(?:burstable|besteffort))?-pod"
               r"([0-9a-f]{8}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{12})\.slice")
    for part in absolute(group).split("/"):
        match = re.fullmatch(pattern, part)
        if match:
            matches.append(match[1].replace("_", "-"))
    require(len(matches) == 1, "actual child cgroup has no unique native PodUID slice")
    return matches[0]


class Child:
    def __init__(self, state, config, stack):
        self.pid = state.get("pid")
        require(type(self.pid) is int and self.pid > 1, "OCI state has no live child PID")
        self.proc = stack.enter_context(directory("/proc/" + str(self.pid)))
        self.ticks = self.start_ticks()
        self.pidfd = None
        if hasattr(os, "pidfd_open"):
            try:
                self.pidfd = os.pidfd_open(self.pid, 0)
                stack.callback(os.close, self.pidfd)
            except OSError as error:
                require(error.errno in (errno.ENOSYS, errno.EINVAL), "cannot pin child pidfd")
        # /proc/PID/root is the one intentional magic link, entered only after PID pinning.
        self.procroot = os.open("root", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC, dir_fd=self.proc)
        stack.callback(os.close, self.procroot)
        self.procroot_identity = os.fstat(self.procroot)
        root = config.get("root", {}).get("path")
        require(isinstance(root, str) and root, "OCI bundle rootfs is missing")
        self.rootpath = absolute(root if root.startswith("/") else posixpath.join(state["bundle"], root))
        self.root = stack.enter_context(directory(self.rootpath.lstrip("/"), self.procroot))
        self.root_identity = os.fstat(self.root)
        self.rows = self.mounts()
        self.check()

    def mounts(self):
        return container_mounts(mountinfo(self.proc), self.rootpath)

    def start_ticks(self):
        data = file_at(self.proc, "stat").decode("utf-8")
        fields = data[data.rfind(")") + 2:].split()
        require(len(fields) > 19 and fields[0] not in ("Z", "X"), "child process is not live")
        return int(fields[19])

    def check(self):
        require(self.start_ticks() == self.ticks, "child PID identity changed")
        if self.pidfd is not None:
            require(not select.select([self.pidfd], [], [], 0)[0], "child pidfd exited")
        fd = os.open("root", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC, dir_fd=self.proc)
        try:
            info = os.fstat(fd)
            require((info.st_dev, info.st_ino, mount_id(fd)) ==
                    (self.procroot_identity.st_dev, self.procroot_identity.st_ino, mount_id(self.procroot)),
                    "child pre-pivot process root changed")
            with directory(self.rootpath.lstrip("/"), fd) as root:
                info = os.fstat(root)
                require((info.st_dev, info.st_ino, mount_id(root)) ==
                        (self.root_identity.st_dev, self.root_identity.st_ino, mount_id(self.root)),
                        "child bundle rootfs changed during createRuntime")
        finally:
            os.close(fd)

    def cgroup(self):
        rows = file_at(self.proc, "cgroup").decode("utf-8").splitlines()
        require(len(rows) == 1 and rows[0].startswith("0::/"), "native unified systemd cgroup is required")
        return absolute(rows[0][3:])


def publication(source, kubelet):
    absolute(source)
    if not inside(source, kubelet):
        require(not inside(kubelet, source), "host mount exposes an ancestor of kubelet storage")
        return None
    require(source != kubelet, "host mount exposes all kubelet storage")
    parts = source[len(kubelet):].strip("/").split("/")
    if len(parts) >= 3 and parts[0] == "pods" and parts[2] == "volume-subpaths":
        require(len(parts) == 6 and UID.fullmatch(parts[1]) and NAME.fullmatch(parts[3])
                and NAME.fullmatch(parts[4]) and parts[5].isdigit(), "malformed subPath publication")
        # Projected/ephemeral subPaths need neither retained root nor API. Kubelet's
        # immutable PodUID volume directory must independently establish their kind.
        safe = 0
        base = kubelet + "/pods/" + parts[1] + "/volumes/"
        for plugin in ("secret", "configmap", "empty-dir", "projected", "downward-api"):
            try:
                with directory(base + "kubernetes.io~" + plugin + "/" + parts[3]):
                    safe += 1
            except FileNotFoundError:
                pass
        require(safe == 1, "unclassified or protected kubelet subPath is unsupported")
        return None
    if len(parts) >= 4 and parts[0] == "pods" and parts[2] == "volumes":
        plugin = parts[3]
        if plugin == "kubernetes.io~local-volume":
            require(len(parts) == 5 and UID.fullmatch(parts[1]) and NAME.fullmatch(parts[4]),
                    "malformed local-PV publication source")
            return parts[1], parts[4]
        # These publishers can carry local retained storage but lack the local-PV evidence chain.
        require(plugin not in ("kubernetes.io~csi", "kubernetes.io~host-path"),
                "unsupported CSI or hostPath kubelet publication")
    return None


def protected(row, path, expected):
    source = row.source(path)
    return source["fsType"] == expected["fsType"] and source["name"] == expected["name"] \
        and overlaps(source["root"], expected["root"])


def selected_mount(rows, destination):
    matches = [row for row in rows if row.path == destination]
    require(len(matches) == 1, "actual destination has no unique mounted filesystem: " + destination)
    return matches[0]


def classify(config, child, node):
    mounts = config.get("mounts", [])
    require(isinstance(mounts, list) and len(mounts) <= 256, "invalid OCI mount list")
    result = []
    destinations = []
    for item in mounts:
        require(isinstance(item, dict), "malformed OCI mount")
        destination = mount_path(item.get("destination"))
        destinations.append(destination)
        source = item.get("source", "")
        options = item.get("options", [])
        require(isinstance(source, str) and isinstance(options, list)
                and all(isinstance(option, str) for option in options), "malformed OCI mount source/options")
        if source.startswith("/"):
            source = mount_path(source)
        published = publication(source, node["kubeletRoot"]) if source.startswith("/") else None
        actual = [row for row in child.rows if row.path == destination]
        coordinates = any(protected(row, destination, node["root"]["source"]) for row in actual)
        direct = source.startswith("/") and overlaps(source, node["root"]["path"])
        if direct:
            require(source == node["root"]["path"] and "ro" in options and "rw" not in options,
                    "direct retained mounts require an exact read-only root view")
            require(item.get("type") == "bind" or "bind" in options or "rbind" in options,
                    "read-only root view is not a bind mount")
            require(not any(option in ("shared", "rshared", "slave", "rslave") for option in options),
                    "root view mount propagation is unsupported")
            row = selected_mount(child.rows, destination)
            row.readonly()
            require(row.source(destination) == node["root"]["source"], "actual root view source differs")
            result.append((dict(item, source=source, destination=destination), None, row))
            continue
        if not published:
            require(not coordinates, "retained source lacks a native local-PV publication: " + destination)
            continue
        require(item.get("type") == "bind" or "bind" in options or "rbind" in options,
                "local-PV publication is not a bind mount")
        row = selected_mount(child.rows, destination)
        result.append((dict(item, source=source, destination=destination), published, row))
    require(len(result) <= 16, "too many local-PV dependencies")
    for item, _, _ in result:
        destination = item["destination"]
        require(sum(overlaps(destination, other) for other in destinations) == 1,
                "overlapping OCI mounts on a local-PV destination")
        require(not any(inside(row.path, destination) and row.path != destination for row in child.rows),
                "nested actual mounts under local-PV destination")
    known = {row.id for _, _, row in result}
    require(not any(protected(row, row.path, node["root"]["source"]) and row.id not in known
                    for row in child.rows), "unclassified actual retained mount in child namespace")
    return result


class API:
    def __init__(self, commands, node):
        self.commands = commands
        self.node = node
        self.cache = {}

    def get(self, kind, name=None, namespace=None):
        key = kind, name, namespace
        if key not in self.cache:
            args = [self.node["k3s"], "kubectl", "get", kind]
            if name:
                require(NAME.fullmatch(name), "invalid Kubernetes resource name")
                args.append(name)
            if namespace:
                require(NAME.fullmatch(namespace), "invalid Kubernetes namespace")
                args.extend(["--namespace", namespace])
            args.extend(["--output=json", "--request-timeout=5s"])
            self.cache[key] = decode(self.commands.run(args), "authoritative " + kind)
        return self.cache[key]

    def object(self, kind, name, namespace=None):
        obj = self.get(kind, name, namespace)
        metadata = obj.get("metadata", {})
        require(isinstance(metadata, dict) and metadata.get("name") == name and metadata.get("uid")
                and not metadata.get("deletionTimestamp")
                and (namespace is None or metadata.get("namespace") == namespace),
                "deleted or mismatched authoritative " + kind)
        return obj

    def dependency(self, pod_uid, pv_name, destination):
        pv = self.object("persistentvolume", pv_name)
        spec = pv.get("spec", {})
        require(isinstance(spec, dict) and isinstance(spec.get("local"), dict)
                and spec.get("volumeMode", "Filesystem") == "Filesystem"
                and pv.get("status", {}).get("phase") == "Bound", "PV is not a bound local filesystem volume")
        require(set(spec["local"]) <= {"path", "fsType"}, "unsupported local-PV source fields")
        path = absolute(spec["local"].get("path"))
        claim = spec.get("claimRef", {})
        require(isinstance(claim, dict) and claim.get("kind", "PersistentVolumeClaim") == "PersistentVolumeClaim"
                and claim.get("apiVersion", "v1") == "v1" and claim.get("uid"), "PV has no bound claim identity")
        namespace, name = claim.get("namespace"), claim.get("name")
        require(isinstance(namespace, str) and isinstance(name, str), "PV claim reference is incomplete")
        if spec.get("storageClassName") == "retained-local":
            require(path == posixpath.join(self.node["root"]["path"], namespace + "." + name),
                    "retained-local source differs from its native namespace/claim identity")
        pvc = self.object("persistentvolumeclaim", name, namespace)
        require(pvc["metadata"]["uid"] == claim["uid"]
                and pvc.get("spec", {}).get("volumeName") == pv_name
                and pvc.get("spec", {}).get("volumeMode", "Filesystem") == "Filesystem"
                and pvc.get("status", {}).get("phase") == "Bound", "PVC/PV binding identity differs")
        listing = self.get("pods", namespace=namespace)
        pods = listing.get("items")
        require(isinstance(pods, list) and len(pods) <= 2048, "invalid bounded Pod lookup")
        matching = [pod for pod in pods if isinstance(pod, dict) and pod.get("metadata", {}).get("uid") == pod_uid]
        require(len(matching) == 1, "publication PodUID has no unique authoritative Pod")
        pod = matching[0]
        require(not pod["metadata"].get("deletionTimestamp")
                and pod["metadata"].get("namespace") == namespace
                and pod.get("spec", {}).get("nodeName") == os.uname().nodename,
                "publication Pod is deleted or belongs to another node")
        volumes = pod["spec"].get("volumes", [])
        require(isinstance(volumes, list), "invalid Pod volume list")
        required = overlaps(path, self.node["root"]["path"])
        names = {volume.get("name") for volume in volumes if isinstance(volume, dict)
                 and isinstance(volume.get("persistentVolumeClaim"), dict)
                 and volume["persistentVolumeClaim"].get("claimName") == name
                 and (not required or not volume["persistentVolumeClaim"].get("readOnly", False))}
        require(names, "publication is not a compatible claim of its Pod")
        ordinary = []
        for key in ("containers", "initContainers", "ephemeralContainers"):
            containers = pod["spec"].get(key, [])
            require(isinstance(containers, list), "invalid Pod container list")
            for container in containers:
                require(isinstance(container, dict), "invalid Pod container")
                for mount in container.get("volumeMounts", []):
                    if mount.get("name") in names and mount_path(mount.get("mountPath")) == destination:
                        ordinary.append(not any(mount.get(key) for key in
                                                ("subPath", "subPathExpr", "mountPropagation"))
                                        and (not required or not mount.get("readOnly")))
        require(any(ordinary), "actual mount is not an ordinary full-volume Pod mount")
        return path


def retained_dependencies(candidates, api, child, node):
    result = []
    for item, publication, actual in candidates:
        path = None
        if publication is not None:
            pod_uid, pv_name = publication
            require(cgroup_pod_uid(child.cgroup()) == pod_uid,
                    "publication PodUID differs from actual child Pod slice")
            path = api.dependency(pod_uid, pv_name, item["destination"])
            if not overlaps(path, node["root"]["path"]):
                require(not protected(actual, item["destination"], node["root"]["source"]),
                        "unrelated local PV actually exposes retained backing")
                continue
            require("ro" not in item["options"] and "rw" in item["options"],
                    "retained local-PV destination must be explicitly writable")
            require(not any(option in ("shared", "rshared", "slave", "rslave") for option in item["options"]),
                    "retained local-PV mount propagation is unsupported")
            actual.writable()
        result.append((item, publication, actual, path))
    return result


def entry_metadata(entry):
    require(isinstance(entry, dict) and set(entry) == {"id", "uid", "gid", "mode"}
            and isinstance(entry["id"], str) and entry["id"]
            and type(entry["uid"]) is int and 0 <= entry["uid"] <= 2 ** 32 - 2
            and type(entry["gid"]) is int and 0 <= entry["gid"] <= 2 ** 32 - 2
            and isinstance(entry["mode"], str) and re.fullmatch(r"[0-7]{3,4}", entry["mode"])
            and int(entry["mode"], 8) <= 0o777,
            "invalid selected inventory entry")


def metadata(fd, wanted):
    info = os.fstat(fd)
    require((info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) ==
            (wanted["uid"], wanted["gid"], int(wanted["mode"], 8)), "actual mounted retained metadata differs")


def root_receipt(rootfd, node):
    root = node["root"]
    ledger = decode(file_at(rootfd, root["marker"], (root["uid"], root["gid"])), "root identity ledger")
    require(ledger.get("version") == 1 and ledger.get("id") == root["id"]
            and ledger.get("source") == root["source"]
            and type(ledger.get("inode")) is int and ledger["inode"] == os.fstat(rootfd).st_ino,
            "actual root ledger identity differs")
    metadata(rootfd, root)
    return ledger


def application_identity(rootfd, appfd, node, name, entry):
    root = node["root"]
    ledger = root_receipt(rootfd, node)
    require(ledger.get("entries", {}).get(name) ==
            {"id": entry["id"], "state": "established", "inode": os.fstat(appfd).st_ino},
            "actual root ledger has no established selected identity")
    for fd, wanted in ((rootfd, root), (appfd, entry)):
        metadata(fd, wanted)
        require(not os.fstatvfs(fd).f_flag & os.ST_RDONLY, "actual retained filesystem is read-only")


def escape_mount(path):
    value = path.strip("/")
    if not value:
        return "-.mount"
    output = []
    for index, byte in enumerate(os.fsencode(value)):
        char = chr(byte)
        if char == "/":
            output.append("-")
        elif (char.isascii() and (char.isalnum() or char in "_:.") and not (index == 0 and char == ".")):
            output.append(char)
        else:
            output.append("\\x" + format(byte, "02x"))
    return "".join(output) + ".mount"


def properties(commands, node, unit, names):
    data = commands.run([node["systemctl"], "show", "--no-pager", "--property=" + ",".join(names), "--", unit])
    result = {}
    for line in data.decode("utf-8").splitlines():
        require("=" in line, "malformed systemd properties")
        key, value = line.split("=", 1)
        require(key not in result, "duplicate systemd property")
        result[key] = value
    require(all(name in result for name in names), "missing native systemd properties")
    require(result.get("Id") == unit and result.get("LoadState") == "loaded"
            and result.get("ActiveState") == "active", "native unit is not active: " + unit)
    return result


def live_scope(commands, node, child, container_id):
    scope = "cri-containerd-" + container_id + ".scope"
    group = child.cgroup()
    require(posixpath.basename(group) == scope, "child is not in its exact native containerd scope")
    data = properties(commands, node, scope,
                      ("Id", "LoadState", "ActiveState", "SubState", "ControlGroup", "Transient"))
    require(data["SubState"] == "running" and data["ControlGroup"] == group and data["Transient"] == "yes",
            "native scope does not own the actual child cgroup")
    child.check()
    return scope


def source_unit(commands, node, row):
    require(row.path != "/", "retained source has no independent native mount lifetime")
    unit = escape_mount(row.path)
    data = properties(commands, node, unit,
                      ("Id", "LoadState", "ActiveState", "SubState", "Where", "What", "Type"))
    require(data["SubState"] == "mounted" and data["Where"] == row.path
            and data["What"] == row.name and data["Type"] == row.fs,
            "native source mount unit differs from the actual source")
    return unit


def guard(commands, node, child, container_id, source):
    mount = source_unit(commands, node, source)
    scope = live_scope(commands, node, child, container_id)
    unit = "retainedguard-" + container_id + ".service"
    executable = shutil.which("true", path=ENV["PATH"])
    require(executable is not None, "trusted native true executable is missing")
    trusted_path(executable)
    stop = node["systemctl"] + " kill --signal=KILL --kill-whom=all " + scope
    commands.run([node["systemdRun"], "--quiet", "--collect", "--unit=" + unit,
                  "--property=Type=oneshot", "--property=RemainAfterExit=yes",
                  "--property=BindsTo=" + mount + " " + scope,
                  "--property=After=" + mount + " " + scope,
                  "--property=TimeoutStopSec=5s", "--property=ExecStop=" + stop, "--", executable])
    data = properties(commands, node, unit,
                      ("Id", "LoadState", "ActiveState", "SubState", "Type", "RemainAfterExit", "BindsTo", "After",
                       "TimeoutStopUSec", "ExecStart", "ExecStop", "Transient", "Result"))
    require(data["Type"] == "oneshot" and data["RemainAfterExit"] == "yes" and data["SubState"] == "exited"
            and data["Transient"] == "yes" and data["Result"] == "success"
            and data["TimeoutStopUSec"] == "5s", "native guard is not an active retained oneshot")
    require(set(data["BindsTo"].split()) == {mount, scope}
            and {mount, scope} <= set(data["After"].split()), "native guard source/scope dependencies differ")
    for key, expected in (("ExecStart", executable), ("ExecStop", stop)):
        argv = re.findall(r"argv\[\]=(.*?) ;", data[key])
        paths = re.findall(r"(?:\{ |; )path=([^ ;]+)", data[key])
        require(argv == [expected] and paths == [expected.split()[0]] and "ignore_errors=no" in data[key],
                "native guard command differs: " + key)
    require(source_unit(commands, node, source) == mount
            and live_scope(commands, node, child, container_id) == scope, "native guard dependencies changed")


def run(state):
    node = node_descriptor()
    require(state.get("ociVersion") == "1.0.2" or isinstance(state.get("ociVersion"), str)
            and re.fullmatch(r"1\.[0-9]+\.[0-9]+", state["ociVersion"]), "unsupported OCI state version")
    container_id = state.get("id")
    require(isinstance(container_id, str) and CONTAINER.fullmatch(container_id), "invalid native CRI container ID")
    require(state.get("status") == "creating", "hook requires OCI createRuntime creating state")
    bundle = absolute(state.get("bundle"))
    commands = Commands()
    with contextlib.ExitStack() as stack:
        bundlefd = stack.enter_context(directory(bundle))
        config = decode(file_at(bundlefd, "config.json"), "OCI bundle configuration")
        child = Child(state, config, stack)
        api = API(commands, node)
        dependencies = retained_dependencies(classify(config, child, node), api, child, node)
        if not dependencies:
            return
        # These are safety prerequisites, not an application allowlist or retained opt-in.
        capabilities = config.get("process", {}).get("capabilities", {})
        require(isinstance(capabilities, dict) and not any("CAP_SYS_ADMIN" in values for values in capabilities.values()),
                "retained containers must not have CAP_SYS_ADMIN")
        with directory("/proc/" + str(os.getpid()) + "/ns") as hostns, directory("ns", child.proc) as childns:
            for kind in ("mnt", "pid"):
                require(os.stat(kind, dir_fd=hostns).st_ino != os.stat(kind, dir_fd=childns).st_ino,
                        "retained container shares host " + kind + " namespace")
        entries = {}
        if any(published is not None for _, published, _, _ in dependencies):
            inventory = api.object("configmap", node["inventoryName"], node["inventoryNamespace"])
            text = inventory.get("data", {}).get(node["inventoryKey"])
            require(isinstance(text, str), "compared inventory data is missing")
            entries = decode(text.encode("utf-8"), "compared retained entries")
        spec = json.dumps({"version": 1, "root": node["root"], "entries": {}}, separators=(",", ":")).encode()
        rootfd = stack.enter_context(directory(node["root"]["path"]))
        with directory("/proc/" + str(os.getpid())) as hostproc:
            hostrows = mountinfo(hostproc)
        source = mounted_fd(hostrows, rootfd)
        require(source.source(node["root"]["path"]) == node["root"]["source"], "actual retained root source differs")
        source.writable()
        pinned = []
        views = []
        for item, published_identity, actual, path in dependencies:
            destination = item["destination"]
            if published_identity is None:
                destfd = stack.enter_context(directory(destination.lstrip("/"), child.root))
                same_object(rootfd, destfd)
                require(mounted_fd(child.rows, destfd).id == actual.id
                        and actual.source(destination) == node["root"]["source"], "root view mount identity differs")
                actual.readonly()
                require(os.fstatvfs(destfd).f_flag & os.ST_RDONLY, "root view descriptor is writable")
                root_receipt(destfd, node)
                commands.run([node["helper"], "validate", "--spec", "-", "--root"], spec)
                views.append((item, destfd, actual.id))
                continue
            require(posixpath.dirname(path) == node["root"]["path"], "local PV does not name one retained inventory leaf")
            name = posixpath.basename(path)
            require(NAME.fullmatch(name) and name in entries, "local PV leaf is absent from compared inventory: " + name)
            entry = entries[name]
            entry_metadata(entry)
            appfd = stack.enter_context(directory(name, rootfd))
            pubfd = stack.enter_context(directory(item["source"]))
            destfd = stack.enter_context(directory(destination.lstrip("/"), child.root))
            same_object(appfd, pubfd, destfd)
            hostapp = mounted_fd(hostrows, appfd)
            published = mounted_fd(hostrows, pubfd)
            actualfd = mounted_fd(child.rows, destfd)
            expected_source = dict(node["root"]["source"], root=posixpath.join(node["root"]["source"]["root"], name))
            require(hostapp.id == source.id and hostapp.source(path) == expected_source
                    and published.source(item["source"]) == expected_source
                    and actualfd.id == actual.id and actual.source(destination) == expected_source,
                    "mounted source coordinates differ from declared leaf or kubelet publication")
            for row in (hostapp, published, actualfd):
                row.writable()
            require(not any(row.path != item["source"] and inside(row.path, item["source"])
                            for row in hostrows), "nested mount under local-PV publication")
            application_identity(rootfd, destfd, node, name, entry)
            selected_spec = json.dumps({"version": 1, "root": node["root"], "entries": {name: entry}},
                                       separators=(",", ":")).encode()
            commands.run([node["helper"], "validate", "--spec", "-", "--entry", name], selected_spec)
            pinned.append((name, entry, path, item, appfd, pubfd, destfd, actual.id))
        guard(commands, node, child, container_id, source)
        # Reopen names after helper/guard work: never validate a path then trust an older bind.
        child.check()
        current_child = child.mounts()
        known_mounts = {row.id for _, _, row, _ in dependencies}
        require(not any(protected(row, row.path, node["root"]["source"]) and row.id not in known_mounts
                        for row in current_child), "unclassified retained mount appeared during hook")
        with directory("/proc/" + str(os.getpid())) as hostproc:
            current_host = mountinfo(hostproc)
        with directory(node["root"]["path"]) as current_root:
            same_object(rootfd, current_root)
            current_source = mounted_fd(current_host, current_root)
            require(current_source.id == source.id
                    and current_source.source(node["root"]["path"]) == node["root"]["source"],
                    "source mount was replaced during hook")
            current_source.writable()
            for item, destfd, identity in views:
                destination = item["destination"]
                with directory(destination.lstrip("/"), child.root) as current_dest:
                    same_object(rootfd, current_root, destfd, current_dest)
                    actual = mounted_fd(current_child, current_dest)
                    require(actual.id == identity and selected_mount(current_child, destination).id == identity
                            and actual.source(destination) == node["root"]["source"], "root view changed during hook")
                    actual.readonly()
                    require(os.fstatvfs(current_dest).f_flag & os.ST_RDONLY, "root view became writable")
                    require(not any(row.path != destination and inside(row.path, destination)
                                    for row in current_child), "nested mount appeared under root view")
                    root_receipt(current_dest, node)
            for name, entry, path, item, appfd, pubfd, destfd, identity in pinned:
                with directory(name, current_root) as current_app, directory(item["source"]) as current_pub, \
                        directory(item["destination"].lstrip("/"), child.root) as current_dest:
                    same_object(appfd, pubfd, destfd, current_app, current_pub, current_dest)
                    require(mounted_fd(current_child, current_dest).id == identity
                            and selected_mount(current_child, item["destination"]).id == identity,
                            "actual container mount was replaced during hook")
                    require(mounted_fd(current_host, current_app).id == source.id,
                            "current app no longer belongs to the pinned source")
                    expected = dict(node["root"]["source"],
                                    root=posixpath.join(node["root"]["source"]["root"], name))
                    for rows, fd, path_now in ((current_host, current_app, path),
                                              (current_host, current_pub, item["source"]),
                                              (current_child, current_dest, item["destination"])):
                        row = mounted_fd(rows, fd)
                        require(row.source(path_now) == expected, "source coordinates changed during hook")
                        row.writable()
                        require(not any(other.path != path_now and inside(other.path, path_now)
                                        for other in rows), "nested mount appeared during hook")
                    application_identity(current_root, current_dest, node, name, entry)
        child.check()


def main():
    try:
        require(not sys.argv[1:], "hook accepts no arguments")
        run(decode(read_fd(sys.stdin.fileno(), deadline=time.monotonic() + 5), "OCI state"))
    except (Denied, OSError, ValueError, KeyError, TypeError, AttributeError, IndexError,
            UnicodeError, subprocess.SubprocessError) as error:
        detail = str(error).replace("\n", " ").replace("\r", " ")[:768]
        print("retained-runtime-hook: deny: " + detail, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
