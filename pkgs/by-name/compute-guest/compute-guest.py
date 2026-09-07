"""Host-side lifecycle operations for a Nix-declared compute guest."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.parse import quote


def run(*args, timeout=180, input=None):
    return subprocess.run(
        args, input=input, text=True, capture_output=True, check=True, timeout=timeout
    ).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", type=Path, default=Path("/etc/homelab/compute.json"))
    parser.add_argument("operation", choices=["inspect", "create", "replace"])
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--confirm", help="Exact instance name for destructive replacement")
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("Run on the physical host as root; do not run against a remote Incus context.")

    spec = json.loads(args.spec.read_text())
    project, name = spec["project"], spec["instance"]
    # The descriptor is root-owned desired state. Use the local socket explicitly.
    os.environ["INCUS_SOCKET"] = "/var/lib/incus/unix.socket"
    lock_path = Path("/run/lock") / f"compute-{project}-{name}.lock"
    with lock_path.open("a") as lock:
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
        if args.operation == "inspect":
            print(json.dumps({"desired": spec, "instance": instance}, indent=2))
            return

        project_state = json.loads(
            run(
                "incus",
                "--force-local",
                "query",
                "/1.0/projects/" + quote(project, safe=""),
            )
        )
        if any(project_state["config"].get(key) != value for key, value in spec["projectConfig"].items()):
            raise RuntimeError("Project restrictions differ from Nix desired state.")

        network = json.loads(
            run(
                "incus",
                "--force-local",
                "query",
                "/1.0/networks/" + quote(spec["network"], safe="") + "?project=default",
            )
        )
        network_config = {
            key: value
            for key, value in network["config"].items()
            if not key.startswith("volatile.") and key != "bridge.hwaddr"
        }
        if network["type"] != "bridge" or network_config != spec["networkConfig"]:
            raise RuntimeError("Network differs from Nix desired state.")

        pool = json.loads(
            run(
                "incus",
                "--force-local",
                "query",
                "/1.0/storage-pools/" + quote(spec["pool"], safe=""),
            )
        )
        if pool["driver"] != "dir" or pool["config"].get("source") != spec["poolPath"]:
            raise RuntimeError("Root storage pool differs from Nix desired state.")

        profile = query("/1.0/profiles/" + quote(spec["profile"], safe=""))
        if profile["config"] != spec["config"] or profile["devices"] != spec["devices"]:
            raise RuntimeError("Profile differs from Nix desired state; deploy/reconcile the host, not this helper.")

        if instance:
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

        start, end = spec["idmapBase"], spec["idmapBase"] + spec["idmapSize"]
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
        for other in all_instances:
            if other["name"] == name and other["project"] == project:
                continue
            for entry in json.loads(other["config"].get("volatile.idmap.current", "[]")):
                if entry["Hostid"] < end and entry["Hostid"] + entry["Maprange"] > start:
                    raise RuntimeError(f"ID range overlaps {other['project']}/{other['name']}.")

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
            except (KeyError, TypeError, ValueError) as error:
                raise RuntimeError("Malformed required host path metadata.") from error
            if not path.is_absolute() or not path.is_dir():
                raise RuntimeError(f"Required host path is not an existing directory: {path}")
            stat = path.stat()
            if stat.st_uid != uid or stat.st_gid != gid:
                raise RuntimeError(f"Unexpected required path identity: {path}; never repair by recursive chown.")
            read_only = entry.get("readOnly")
            if read_only is not None:
                if not isinstance(read_only, bool):
                    raise RuntimeError("Malformed required host path readOnly metadata.")
                options = run("findmnt", "-n", "-o", "VFS-OPTIONS", "-M", str(path)).split(",")
                if ("ro" in options) != read_only:
                    state = "read-only" if read_only else "writable"
                    raise RuntimeError(f"Required host path is not mounted {state}: {path}")

        identity = Path(spec["identityPath"])
        expected_public = spec.get("publicKey")
        if not expected_public:
            raise RuntimeError("Guest public identity is not provisioned in the host declaration.")
        public = run("ssh-keygen", "-y", "-f", str(identity / "ssh_host_ed25519_key"))
        if public.split()[:2] != expected_public.split()[:2]:
            raise RuntimeError("Staged guest private key does not match the declared public identity.")

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
