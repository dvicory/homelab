"""Host-side lifecycle operations for a Nix-declared compute guest."""
import argparse
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import time
from urllib.parse import quote


def run(*args, timeout=180, input=None):
    return subprocess.run(
        args, input=input, text=True, capture_output=True, check=True, timeout=timeout
    ).stdout.strip()


def check_preseed(spec):
    """Return absent envelope resources and reject incompatible existing ones."""
    project = spec["project"]

    def collection(path):
        return json.loads(run("incus", "--force-local", "query", path))

    def resource(items, name):
        return next((item for item in items if item.get("name") == name), None)

    missing = []
    project_state = resource(collection("/1.0/projects?recursion=1"), project)
    if project_state is None:
        missing.append(f"project/{project}")
    elif any(
        project_state.get("config", {}).get(key) != value
        for key, value in spec["projectConfig"].items()
    ):
        raise RuntimeError(f"Existing project {project} has incompatible restrictions.")

    pool = resource(collection("/1.0/storage-pools?recursion=1"), spec["pool"])
    if pool is None:
        missing.append(f"storage-pool/{spec['pool']}")
    elif (
        pool.get("driver") != "dir"
        or pool.get("config", {}).get("source") != spec["poolPath"]
    ):
        raise RuntimeError(f"Existing storage pool {spec['pool']} is incompatible.")

    network = resource(
        collection("/1.0/networks?recursion=1&project=default"), spec["network"]
    )
    if network is None:
        missing.append("network/default/" + spec["network"])
    else:
        network_config = {
            key: value
            for key, value in network.get("config", {}).items()
            if not key.startswith("volatile.") and key != "bridge.hwaddr"
        }
        if network.get("type") != "bridge" or network_config != spec["networkConfig"]:
            raise RuntimeError(f"Existing network {spec['network']} is incompatible.")

    if project_state is None:
        missing.append(f"profile/{project}/{spec['profile']}")
    else:
        profile = resource(
            collection(
                "/1.0/profiles?recursion=1&project=" + quote(project, safe="")
            ),
            spec["profile"],
        )
        if profile is None:
            missing.append(f"profile/{project}/{spec['profile']}")
        elif (
            profile.get("config") != spec["config"]
            or profile.get("devices") != spec["devices"]
        ):
            raise RuntimeError(
                f"Existing profile {project}/{spec['profile']} is incompatible."
            )
    return missing

def load_descriptor(path):
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise RuntimeError(f"Cannot resolve descriptor: {path}") from error
    if not resolved.is_file():
        raise RuntimeError("descriptor is not a regular file")
    metadata = resolved.stat()
    if metadata.st_uid != 0:
        raise RuntimeError("descriptor must be root-owned")
    if metadata.st_mode & 0o22:
        raise RuntimeError("descriptor must not be writable by group or other users")
    spec = json.loads(resolved.read_text())
    if not isinstance(spec, dict):
        raise RuntimeError("descriptor must be a JSON object")
    return spec


def check_required_paths(spec):
    required_paths = spec.get("requiredPaths")
    if not isinstance(required_paths, list) or not required_paths:
        raise RuntimeError("Nix descriptor has no required host paths.")
    for entry in required_paths:
        if not isinstance(entry, dict):
            raise RuntimeError("Malformed required host path metadata.")
        try:
            path = Path(entry["path"])
            uid = int(entry["uid"])
            gid = int(entry["gid"])
            mode_value = entry["mode"]
            if not isinstance(mode_value, str):
                raise TypeError
            mode = int(mode_value, 8)
            if not 0 <= mode <= 0o7777:
                raise ValueError
        except (KeyError, TypeError, ValueError) as error:
            raise RuntimeError("Malformed required host path metadata.") from error
        if not path.is_absolute() or not path.is_dir():
            raise RuntimeError(f"Required host path is not an existing directory: {path}")
        metadata = path.stat()
        if metadata.st_uid != uid or metadata.st_gid != gid:
            raise RuntimeError(f"Unexpected required path identity: {path}; never repair by recursive chown.")
        if metadata.st_mode & 0o7777 != mode:
            raise RuntimeError(f"Unexpected required path mode: {path}; never repair permissions.")
        read_only = entry.get("readOnly")
        if read_only is not None:
            if not isinstance(read_only, bool):
                raise RuntimeError("Malformed required host path readOnly metadata.")
            options = run("findmnt", "-n", "-o", "VFS-OPTIONS", "-M", str(path)).split(",")
            if ("ro" in options) != read_only:
                state = "read-only" if read_only else "writable"
                raise RuntimeError(f"Required host path is not mounted {state}: {path}")


def check_identity(spec):
    identity = Path(spec["identityPath"])
    expected_public = spec.get("publicKey")
    if not expected_public:
        raise RuntimeError("Guest public identity is not provisioned in the host declaration.")
    public = run("ssh-keygen", "-y", "-f", str(identity / "ssh_host_ed25519_key"))
    if public.split()[:2] != expected_public.split()[:2]:
        raise RuntimeError("Staged guest private key does not match the declared public identity.")


def check_idmap(spec, instance):
    start = int(spec["idmapBase"])
    size = int(spec["idmapSize"])
    if start <= 0 or size <= 0:
        raise RuntimeError("Nix descriptor has an invalid ID map.")
    end = start + size
    if instance is not None:
        raw_idmap = instance.get("config", {}).get("volatile.idmap.current")
        if raw_idmap is None:
            raw_idmap = instance.get("expanded_config", {}).get("volatile.idmap.current")
        try:
            mapping = json.loads(raw_idmap) if isinstance(raw_idmap, str) else raw_idmap
            uid_ranges = []
            gid_ranges = []
            for entry in mapping:
                if not isinstance(entry, dict):
                    raise TypeError
                is_uid, is_gid = entry["Isuid"], entry["Isgid"]
                if not isinstance(is_uid, bool) or not isinstance(is_gid, bool) or not (is_uid or is_gid):
                    raise TypeError
                row = (int(entry["Nsid"]), int(entry["Hostid"]), int(entry["Maprange"]))
                if is_uid:
                    uid_ranges.append(row)
                if is_gid:
                    gid_ranges.append(row)
        except (TypeError, KeyError, ValueError) as error:
            raise RuntimeError("Existing instance has no valid effective ID map; refusing mutation.") from error
        # Compare against the rows Nix generated. This function must not
        # reconstruct mapping semantics: a second coordinate algorithm is a
        # second chance to disagree with the profile actually applied.
        def desired(kind):
            return sorted(
                (int(entry["nsid"]), int(entry["hostid"]), int(entry["range"]))
                for entry in spec.get("idmap", {}).get(kind, [])
            )

        expected_uid = desired("uid")
        expected_gid = desired("gid")
        if not expected_uid or not expected_gid:
            raise RuntimeError("Nix descriptor carries no expected ID map.")
        if sorted(uid_ranges) != expected_uid or sorted(gid_ranges) != expected_gid:
            raise RuntimeError("Existing instance has incompatible effective ID map; refusing mutation.")

    for allocation_file in ["/etc/subuid", "/etc/subgid"]:
        allocations = [
            line.split(":")
            for line in Path(allocation_file).read_text().splitlines()
            if line and not line.startswith("#")
        ]
        if not any(
            owner == "root" and int(base) <= start and int(base) + int(count) >= end
            for owner, base, count in allocations
        ):
            raise RuntimeError(f"Root lacks the declared subordinate range in {allocation_file}.")
        # A crossing capability is mapped to its own host ID, and the kernel's
        # setuid helpers refuse host IDs the caller holds no subordinate range
        # for. Only the GID side needs it: service UIDs stay translated.
        if allocation_file.endswith("subgid"):
            identity_host_ids = [
                int(entry["hostid"])
                for entry in spec.get("idmap", {}).get("gid", [])
                if int(entry["nsid"]) == int(entry["hostid"]) and int(entry["range"]) == 1
            ]
            for gid in identity_host_ids:
                if not any(
                    owner == "root" and int(base) <= gid < int(base) + int(count)
                    for owner, base, count in allocations
                ):
                    raise RuntimeError(
                        f"Root lacks subordinate coverage for capability GID {gid} in {allocation_file}."
                    )
        if any(
            owner != "root" and int(base) < end and int(base) + int(count) > start
            for owner, base, count in allocations
        ):
            raise RuntimeError(f"Declared ID range overlaps another owner in {allocation_file}.")

    all_instances = json.loads(
        run(
            "incus",
            "--force-local",
            "query",
            "/1.0/instances?recursion=1&all-projects=true",
        )
    )
    project, name = spec["project"], spec["instance"]
    for other in all_instances:
        if other.get("name") == name and other.get("project") == project:
            continue
        raw_idmap = other.get("config", {}).get("volatile.idmap.current", "[]")
        mapping = json.loads(raw_idmap) if isinstance(raw_idmap, str) else raw_idmap
        for entry in mapping:
            hostid = int(entry["Hostid"])
            maprange = int(entry["Maprange"])
            if hostid < end and hostid + maprange > start:
                raise RuntimeError(f"ID range overlaps {other['project']}/{other['name']}.")


def check_instance(spec, instance):
    if instance is None:
        return
    actual = {
        key: value
        for key, value in instance["expanded_config"].items()
        if not key.startswith(("volatile.", "image.")) and key != "user.homelab.bundle"
    }
    if (
        instance["type"] != "container"
        or instance["profiles"] != [spec["profile"]]
        or actual != spec["config"]
        or instance["expanded_devices"] != spec["devices"]
    ):
        raise RuntimeError("Existing instance has incompatible effective configuration; refusing mutation.")


def inspect_envelope(spec, instance):
    """Read-only validation shared by inspect and lifecycle operations."""
    missing = check_preseed(spec)
    if missing:
        raise RuntimeError("Declared Incus envelope is incomplete: " + ", ".join(missing))
    check_instance(spec, instance)
    check_idmap(spec, instance)
    check_required_paths(spec)
    check_identity(spec)


def open_lifecycle_lock(path, inherited_fd=None):
    if inherited_fd is None:
        return path.open("a")
    try:
        inherited = os.fstat(inherited_fd)
        expected = path.stat()
        if (inherited.st_dev, inherited.st_ino) != (expected.st_dev, expected.st_ino):
            raise RuntimeError("inherited descriptor is not the selected lifecycle lock")
        return os.fdopen(os.dup(inherited_fd), "a")
    except OSError as error:
        raise RuntimeError("invalid inherited lifecycle lock") from error



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", type=Path, default=Path("/etc/homelab/compute.json"))
    parser.add_argument("operation", choices=["inspect", "create", "replace"])
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--confirm", help="Exact instance name for destructive replacement")
    parser.add_argument("--lock-fd", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("Run on the physical host as root; do not run against a remote Incus context.")

    spec = load_descriptor(args.spec)
    project, name = spec["project"], spec["instance"]
    if not all(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]+", value)
               for value in (project, name)):
        raise RuntimeError("descriptor has an invalid project or instance name")
    # The descriptor is root-owned desired state. Use the local socket explicitly.
    os.environ["INCUS_SOCKET"] = "/var/lib/incus/unix.socket"
    lock_path = Path("/run/lock") / f"compute-{project}-{name}.lock"
    with open_lifecycle_lock(lock_path, args.lock_fd) as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

        def incus(*command, **kwargs):
            return run("incus", "--force-local", "--project", project, *command, **kwargs)

        def query(path):
            separator = "&" if "?" in path else "?"
            return json.loads(
                run(
                    "incus",
                    "--force-local",
                    "query",
                    path + separator + "project=" + quote(project, safe=""),
                )
            )

        def execute(*command, **kwargs):
            return incus("exec", name, "--mode=non-interactive", "--", *command, **kwargs)

        instances = query("/1.0/instances?recursion=1")
        instance = next((item for item in instances if item["name"] == name), None)
        inspect_envelope(spec, instance)
        if args.operation == "inspect":
            print(json.dumps({"desired": spec, "instance": instance}, indent=2))
            return

        def bundle(path):
            if path is None:
                raise RuntimeError("--bundle is required")
            path = path.resolve(strict=True)
            store = Path("/nix/store")
            if store not in path.parents or not path.is_dir():
                raise RuntimeError("Bundle must be an immutable Nix store output")
            for member in ["metadata.tar.xz", "rootfs.tar.xz", "system"]:
                if not (path / member).exists():
                    raise RuntimeError(f"Incomplete bundle: {member}")
            return path

        def retain(path):
            roots = Path("/nix/var/nix/gcroots/homelab-compute")
            roots.mkdir(mode=0o700, exist_ok=True)
            root = roots / (
                project
                + "-"
                + name
                + "-"
                + hashlib.sha256(str(path).encode()).hexdigest()
            )
            run("nix-store", "--add-root", str(root), "--realise", str(path))

        old_reference = instance.get("config", {}).get("user.homelab.bundle") if instance else None
        if args.operation in ["create", "replace"] and args.bundle is None:
            raise RuntimeError("--bundle is required for create or replace")
        selected = bundle(args.bundle) if args.bundle else None
        if args.operation == "replace" and args.confirm != name:
            raise RuntimeError(f"Explicit acknowledgment required: --confirm {name}")
        if args.operation == "replace" and instance is None:
            raise RuntimeError("Instance is absent; use create with a declared bundle.")
        if args.operation == "create" and instance:
            if selected and old_reference and str(selected) != old_reference:
                raise RuntimeError("Creation cannot update an existing instance; use replace.")
            print(f"{project}/{name} already exists and conforms; its root was preserved.")
            return

        def current_instance():
            current = query("/1.0/instances?recursion=1")
            return next((item for item in current if item["name"] == name), None)

        def stop_if_running():
            current = current_instance()
            if current and current.get("status") == "Running":
                incus("stop", name, "--timeout=120")
                current = current_instance()
                if current and current.get("status") == "Running":
                    raise RuntimeError("Instance remained running after graceful stop; refusing deletion.")

        def import_image():
            retain(selected)
            digest = hashlib.sha256()
            for member in ["metadata.tar.xz", "rootfs.tar.xz"]:
                with (selected / member).open("rb") as source:
                    while block := source.read(1024 * 1024):
                        digest.update(block)
            fingerprint = digest.hexdigest()
            images = query("/1.0/images?recursion=1")
            if not any(image["fingerprint"] == fingerprint for image in images):
                incus(
                    "image",
                    "import",
                    str(selected / "metadata.tar.xz"),
                    str(selected / "rootfs.tar.xz"),
                    timeout=1800,
                )
            return fingerprint

        fingerprint = import_image()
        try:
            if instance:
                stop_if_running()
                current = current_instance()
                if current and current.get("status") == "Running":
                    raise RuntimeError("Instance is still running; refusing deletion.")
                incus("delete", name)
            incus(
                "init",
                fingerprint,
                name,
                "--profile",
                spec["profile"],
                "--config",
                "user.homelab.bundle=" + str(selected),
                timeout=1800,
            )
            incus("start", name)

            deadline = time.monotonic() + 240
            layer = "guest management"
            while time.monotonic() < deadline:
                try:
                    layer = "guest management and K3s service"
                    execute("systemctl", "is-active", "sshd", "k3s", timeout=20)
                    layer = "Kubernetes node readiness"
                    nodes = json.loads(
                        execute(
                            "k3s",
                            "kubectl",
                            "--request-timeout=15s",
                            "get",
                            "nodes",
                            "-o",
                            "json",
                            timeout=20,
                        )
                    )["items"]
                    if not nodes or not all(
                        any(
                            condition["type"] == "Ready" and condition["status"] == "True"
                            for condition in node["status"]["conditions"]
                        )
                        for node in nodes
                    ):
                        time.sleep(2)
                        continue
                    print(f"{project}/{name}: guest management and K3s are ready.")
                    return
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired, KeyError, ValueError):
                    pass
                time.sleep(2)
            raise RuntimeError(f"Readiness failed at {layer}. The guest was stopped and retained inputs were not removed.")
        except (RuntimeError, OSError, KeyError, ValueError, subprocess.SubprocessError):
            try:
                stop_if_running()
            except (RuntimeError, OSError, KeyError, ValueError, subprocess.SubprocessError) as cleanup_error:
                print(f"compute-guest: failed to stop guest after lifecycle error: {cleanup_error}", file=sys.stderr)
            raise


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, KeyError, ValueError, subprocess.SubprocessError) as error:
        print(f"compute-guest: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.strip(), file=sys.stderr)
        sys.exit(1)
