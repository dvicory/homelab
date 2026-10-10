#!/usr/bin/env python3
"""Carry an existing compute guest across the media-capability host upgrade.

The fixture host boots with the declaration from before the media storage
capability and creates the guest under it. The scenario then activates the
current declaration with switch-to-configuration test, records what each host
unit and the lifecycle helper report while the old guest is still running,
applies the operator procedure, and verifies the guest, its retained state and
its staged credentials, delivers the Jellyfin helper images into the existing
guest as docs/operations/jellyfin.md describes, and finishes with the
documented guest replacement onto the current bundle.

Runs only inside the disposable fixture-host VM of checks.compute-guest-upgrade.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import sys
import tempfile
import threading
import time

LOCK = "/run/lock/compute-{project}-{instance}.lock"
MEDIA_FILE = "/srv/media/data/library/movies/upgrade-probe.txt"
RESULTS: dict = {"timings": {}, "observations": {}}


def load_library(path: Path):
    spec = importlib.util.spec_from_file_location("prod_home_replacement", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def observe(key: str, value) -> None:
    RESULTS["observations"][key] = value
    print(f"OBSERVE: {key}: {json.dumps(value)}", flush=True)


def unit_state(lib, unit: str) -> dict:
    show = lib.completed("systemctl", "show", unit, "-p", "ActiveState,Result,ExecMainStatus,NRestarts")
    journal = lib.completed("journalctl", "-u", unit, "-n", "30", "--no-pager", "-o", "cat")
    return {"show": show.stdout.strip().splitlines(), "journal": journal.stdout.strip().splitlines()}


def volatile(lib, project: str, name: str) -> dict:
    instance = lib.instance_query(project, name)
    keys = ("volatile.idmap.current", "volatile.idmap.next", "volatile.last_state.idmap", "volatile.idmap.base", "volatile.uuid")
    return {"status": instance["status"], **{key: instance["config"].get(key) for key in keys}}


def rows(raw: str) -> dict[str, list[tuple[int, int, int]]]:
    result: dict[str, list[tuple[int, int, int]]] = {"uid": [], "gid": []}
    for entry in json.loads(raw):
        row = (entry["Nsid"], entry["Hostid"], entry["Maprange"])
        if entry["Isuid"]:
            result["uid"].append(row)
        if entry["Isgid"]:
            result["gid"].append(row)
    return {kind: sorted(value) for kind, value in result.items()}


def declared_rows(descriptor: dict) -> dict[str, list[tuple[int, int, int]]]:
    return {kind: sorted((row["nsid"], row["hostid"], row["range"]) for row in descriptor["idmap"][kind]) for kind in ("uid", "gid")}


def helper(lib, args, operation: str, spec: Path, *extra: str, timeout: int = 3_600) -> subprocess.CompletedProcess[str]:
    return lib.completed(str(args.helper), "--spec", str(spec), operation, *extra, timeout=timeout)


def guest_exec(lib, project: str, name: str, *command: str, user: int | None = None, group: int | None = None) -> subprocess.CompletedProcess[str]:
    prefix = ["incus", "--force-local", "--project", project, "exec", name]
    if user is not None:
        prefix += ["--user", str(user), "--group", str(group if group is not None else user)]
    return lib.completed(*prefix, "--mode=non-interactive", "--", *command)


def rootfs_gid_counts(lib, rootfs: str) -> dict:
    counts = {}
    for gid in (505, 1000505):
        result = lib.completed("sh", "-c", f"find {shlex.quote(rootfs)} -xdev -gid {gid} | wc -l", timeout=600)
        counts[str(gid)] = int(result.stdout.strip() or "-1")
    return counts


class Availability:
    """Poll the guest's Kubernetes API once a second and record outages."""

    def __init__(self, lib, project: str, name: str):
        self.command = ["incus", "--force-local", "--project", project, "exec", name, "--mode=non-interactive",
                        "--", "k3s", "kubectl", "--request-timeout=3s", "get", "--raw", "/readyz"]
        self.lib = lib
        self.samples: list[tuple[float, bool]] = []
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.poll, daemon=True)

    def poll(self) -> None:
        while not self.stop.is_set():
            try:
                ok = self.lib.completed(*self.command, timeout=10).returncode == 0
            except subprocess.TimeoutExpired:
                ok = False
            self.samples.append((time.monotonic(), ok))
            self.stop.wait(1)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join()

    def outage(self) -> float:
        """Seconds from the first failed probe to the next successful one."""
        down = next((at for at, ok in self.samples if not ok), None)
        if down is None:
            return 0.0
        up = next((at for at, ok in self.samples if ok and at > down), None)
        return round((up if up is not None else self.samples[-1][0]) - down, 2)


def helper_images(lib, project: str, name: str) -> list[str]:
    listing = guest_exec(lib, project, name, "k3s", "ctr", "--namespace", "k8s.io", "images", "ls", "-q").stdout
    return sorted(line for line in listing.splitlines() if "homelab/jellyfin-provisioner:" in line or "homelab/jellarr:" in line)


def run_scenario(args) -> None:
    lib = load_library(args.library)
    check = lib.check
    old = json.loads(Path("/etc/homelab/compute.json").read_text())
    new = json.loads((args.upgraded / "etc/homelab/compute.json").read_text())
    check("media" not in old["devices"] and "media" in new["devices"], "fixture boots the pre-capability declaration")
    project, name = old["project"], old["instance"]
    lock = LOCK.format(project=project, instance=name)
    lib.wait_for("Incus API", lambda: lib.completed("incus", "--force-local", "query", "/1.0").returncode == 0)

    workspace = Path(tempfile.mkdtemp(prefix="compute-upgrade-"))
    # Required host paths are mount points in production; bind each from a
    # disposable backing directory with the declared owner and mode.
    for entry in old["requiredPaths"]:
        target = Path(entry["path"])
        backing = workspace / "persist" / str(target).lstrip("/")
        backing.mkdir(parents=True)
        target.mkdir(parents=True, exist_ok=True)
        lib.run("mount", "--bind", str(backing), str(target))
        os.chown(target, entry["uid"], entry["gid"])
        os.chmod(target, int(entry["mode"], 8))
    public_key = lib.stage_identity(old, Path(old["identityPath"]))
    specs = {}
    for label, value in (("old", old), ("new", new)):
        value = dict(value, publicKey=public_key)
        specs[label] = workspace / f"{label}.json"
        specs[label].write_text(json.dumps(value, indent=2) + "\n")
        specs[label].chmod(0o400)

    # Disposable credential inputs for every current source; the earlier
    # staging script reads only the sources it declares.
    agenix = Path("/run/agenix")
    agenix.mkdir(exist_ok=True)
    lib.run("mount", "-t", "tmpfs", "-o", "mode=0700,size=1m", "tmpfs", str(agenix))
    for source, entry in new["runtimeSecrets"].items():
        target = agenix / source
        target.write_bytes(lib.fixture_secret_value(entry))
        target.chmod(0o400)

    # A media tree with the capability GID, as media-namespace leaves it.
    media_dir = Path(MEDIA_FILE).parent
    media_dir.mkdir(parents=True)
    for path in (Path("/srv/media/data"), Path("/srv/media/data/library"), media_dir):
        os.chown(path, 0, 505)
        os.chmod(path, 0o2750)
    Path(MEDIA_FILE).write_text("media-capability\n")
    os.chown(MEDIA_FILE, 0, 505)
    os.chmod(MEDIA_FILE, 0o640)

    with lib.phase("pre-capability guest"):
        lib.run("systemctl", "start", "compute-stage-secrets.service", timeout=300)
        lib.run("systemctl", "start", "incus-preseed.service", timeout=600)
        result = helper(lib, args, "create", specs["old"], "--bundle", str(args.previous_bundle))
        check(result.returncode == 0, f"pre-capability guest is created: {(result.stdout + result.stderr).strip()}")
        runtime = lib.Runtime(new, specs["new"], args.helper, args.bundle)
        lib.wait_for("pre-capability K3s node", runtime.node_ready)
        observe("before.volatile", volatile(lib, project, name))
        observe("before.guest_gid_map", runtime.guest("cat", "/proc/self/gid_map"))
        check(rows(volatile(lib, project, name)["volatile.idmap.current"]) == declared_rows(old),
              "pre-capability guest runs the contiguous ID map")
        # Retained state as the guest's own directory Job would leave it.
        runtime.guest("sh", "-ec", """
            install -d -o 1000 -g 1000 -m 0700 /srv/state/identity-kanidm
            install -d -o 0 -g 0 -m 0700 /srv/state/kubernetes-volumes
            printf 'kanidm-db\\n' > /srv/state/identity-kanidm/sentinel
            chown 1000:1000 /srv/state/identity-kanidm/sentinel
            chmod 0600 /srv/state/identity-kanidm/sentinel
            printf 'volume\\n' > /srv/state/kubernetes-volumes/sentinel
            mkdir -p /var/lib/upgrade-sentinel
            printf 'guest-root\\n' > /var/lib/upgrade-sentinel/root-owned
            printf 'media-group\\n' > /var/lib/upgrade-sentinel/media-owned
            chgrp 505 /var/lib/upgrade-sentinel/media-owned
        """)
        # Argo creates these namespaces; jellyfin appears only once #24 is merged.
        for namespace in ("argocd", "cert-manager", "identity"):
            runtime.kubectl("create", "namespace", namespace)
        runtime.kubectl("create", "configmap", "upgrade-sentinel", "--from-literal=value=keep", namespace="default")
        lib.wait_for("pre-capability runtime Secrets", lambda: runtime.kubectl(
            "get", "secret", "argocd-secret", "-o", "name", "--ignore-not-found", namespace="argocd") != "", timeout=300)
        check(helper_images(lib, project, name) == [], "pre-capability guest has no Jellyfin helper images")
        observe("before.retained_host", lib.run("sh", "-c", f"stat -c '%n %u:%g %a' {old['devices']['state']['source']}/*"))
        observe("before.media_in_guest", guest_exec(lib, project, name, "findmnt", "-n", "/srv/media").stdout.strip())
        rootfs = f"{old['poolPath']}/containers/{project}_{name}/rootfs"
        observe("before.rootfs_owner", lib.run("stat", "-c", "%u:%g", f"{rootfs}/etc"))
        observe("before.rootfs_gid_counts", rootfs_gid_counts(lib, rootfs))
        k3s_before = runtime.guest("systemctl", "show", "--value", "-p", "MainPID", "k3s")

    with lib.phase("host activation with the old guest running"):
        started = time.monotonic()
        activation = lib.completed(str(args.upgraded / "bin/switch-to-configuration"), "test", timeout=900)
        RESULTS["timings"]["activation"] = round(time.monotonic() - started, 2)
        observe("activation.returncode", activation.returncode)
        observe("activation.output", (activation.stdout + activation.stderr).strip().splitlines()[-40:])
        check(json.loads(Path("/etc/homelab/compute.json").read_text()) == new, "activation installs the current descriptor")
        observe("activation.subgid", Path("/etc/subgid").read_text().splitlines())
        for unit in ("incus-preseed.service", "compute-stage-secrets.service"):
            observe(f"activation.{unit}", unit_state(lib, unit))
        observe("activation.failed_units", lib.completed("systemctl", "--failed", "--no-legend", "--plain").stdout.strip().splitlines())
        observe("activation.project", {key: value for key, value in lib.query_incus(f"/1.0/projects/{project}")["config"].items()
                                       if key in ("restricted.idmap.gid", "restricted.devices.disk.paths")})
        observe("activation.profile_raw_idmap", lib.query_incus(f"/1.0/profiles/{old['profile']}", project=project)["config"].get("raw.idmap"))
        observe("activation.volatile", volatile(lib, project, name))
        for operation in ("adopt", "inspect"):
            result = helper(lib, args, operation, specs["new"])
            observe(f"activation.compute-guest.{operation}", {"returncode": result.returncode, "output": (result.stdout + result.stderr).strip()[-600:]})
        check("jellyfin\tjellyfin-admin" in runtime.guest("cat", "/srv/secrets/runtime-secrets.names"),
              "activation restages the new credential into the running old guest")
        # Before #24 reaches Argo the jellyfin namespace is absent, so the
        # guest's Secret reconciliation fails and retries.
        lib.wait_for("guest Secret reconciliation retrying without the jellyfin namespace", lambda: "Runtime Secret reconciliation failed" in runtime.guest(
            "journalctl", "-u", "kubernetes-runtime-secrets", "-n", "20", "--no-pager", "-o", "cat"), timeout=300)
        observe("activation.guest_runtime_secrets", {
            "show": runtime.guest("systemctl", "show", "kubernetes-runtime-secrets", "-p", "ActiveState,SubState,Result,NRestarts").splitlines(),
            "journal": runtime.guest("journalctl", "-u", "kubernetes-runtime-secrets", "-n", "6", "--no-pager", "-o", "cat").splitlines(),
        })

    def preseed_failure() -> str | None:
        if lib.completed("systemctl", "is-failed", "--quiet", "incus-preseed.service").returncode != 0:
            return None
        invocation = lib.run("systemctl", "show", "--value", "-p", "InvocationID", "incus-preseed.service")
        journal = lib.completed("journalctl", f"_SYSTEMD_INVOCATION_ID={invocation}", "--no-pager", "-o", "cat").stdout
        if "Conflict detected" in journal:
            return "idmap-conflict"
        if "lifecycle lock is held" in journal:
            return "lifecycle-lock-busy"
        return "other"

    failure = preseed_failure()
    observe("activation.incus_preseed_failure", failure)
    # The preseed waits for the lock that compute-stage-secrets holds during
    # activation, so the only expected failure is the ID-map conflict.
    check(failure in (None, "idmap-conflict"), f"incus-preseed fails only for a recognized reason: {failure}")
    if failure == "idmap-conflict":
        with lib.phase("bridge the project ID-map restriction"):
            # Incus validates the project before the profile, and each of the
            # narrow old and new GID permissions forbids the other's raw.idmap.
            # Permit both for one step, move the profile, then let the native
            # preseed narrow the project to the declaration.
            identity = [str(row["hostid"]) for row in new["idmap"]["gid"] if row["nsid"] == row["hostid"]]
            union = ",".join(identity + [f"{new['idmapBase']}-{new['idmapBase'] + new['idmapSize'] - 1}"])
            bridge = (
                f"exec 9>{lock}; flock -n 9; "
                f"incus --force-local project set {project} restricted.idmap.gid={shlex.quote(union)} && "
                f"incus --force-local --project {project} profile set {old['profile']} "
                f"raw.idmap={shlex.quote(new['config']['raw.idmap'])}"
            )
            result = lib.completed("sh", "-c", bridge)
            observe("bridge.result", {"returncode": result.returncode, "output": (result.stdout + result.stderr).strip()})
            check(result.returncode == 0, "the bridge permits both maps and moves the profile")
            result = lib.completed("systemctl", "restart", "incus-preseed.service", timeout=600)
            observe("bridge.incus-preseed", unit_state(lib, "incus-preseed.service"))
            check(result.returncode == 0, "native preseed applies the current declaration after the bridge")
    project_config = lib.query_incus(f"/1.0/projects/{project}")["config"]
    check(all(project_config.get(key) == value for key, value in new["projectConfig"].items()),
          "project restrictions equal the current declaration")
    check(lib.query_incus(f"/1.0/profiles/{old['profile']}", project=project)["config"] == new["config"],
          "profile equals the current declaration")
    observe("preseeded.volatile", volatile(lib, project, name))
    observe("preseeded.media_mount", guest_exec(lib, project, name, "findmnt", "-n", "-o", "TARGET,OPTIONS", "/srv/media").stdout.strip())
    probe = guest_exec(lib, project, name, "sh", "-c", f"id; stat -c '%u:%g %a' /srv/media/data; cat {MEDIA_FILE}", user=751, group=505)
    observe("preseeded.media_as_751_505", {"returncode": probe.returncode, "output": (probe.stdout + probe.stderr).strip()})
    inspect = helper(lib, args, "inspect", specs["new"])
    observe("preseeded.compute-guest.inspect", {"returncode": inspect.returncode, "output": (inspect.stdout + inspect.stderr).strip()[-600:]})
    check(inspect.returncode != 0 and "incompatible effective ID map; refusing mutation" in inspect.stderr,
          "the running old guest is still refused until it restarts under the new map")
    check(runtime.guest("systemctl", "show", "--value", "-p", "MainPID", "k3s") == k3s_before,
          "activation and preseed leave the running guest's K3s process untouched")
    replace = helper(lib, args, "replace", specs["new"], "--bundle", str(args.bundle), "--confirm", name)
    check(replace.returncode != 0 and "incompatible effective ID map; refusing mutation" in replace.stderr,
          "replacement is refused under the same guard before the restart")

    with lib.phase("guest restart under the current map"):
        with Availability(lib, project, name) as availability:
            started = time.monotonic()
            lib.run("sh", "-c", f"exec 9>{lock}; flock -n 9; incus --force-local --project {project} restart {name} --timeout=120", timeout=900)
            restarted = time.monotonic()
            lib.wait_for("restarted K3s node", runtime.node_ready, timeout=600)
            lib.wait_for("sentinel ConfigMap", lambda: runtime.kubectl("get", "configmap", "upgrade-sentinel", "-o", "jsonpath={.data.value}", namespace="default") == "keep", timeout=300)
            ready = time.monotonic()
            time.sleep(3)
        RESULTS["timings"]["restart_api_outage"] = availability.outage()
        RESULTS["timings"]["restart_command"] = round(restarted - started, 2)
        RESULTS["timings"]["restart_until_k3s_ready"] = round(ready - started, 2)
        state = volatile(lib, project, name)
        observe("restarted.volatile", state)
        check(state["status"] == "Running", "guest is running after the restart")
        check(rows(state["volatile.idmap.current"]) == declared_rows(new), "effective ID map equals the current declaration")
        inspect = helper(lib, args, "inspect", specs["new"])
        check(inspect.returncode == 0, f"lifecycle helper accepts the restarted guest: {inspect.stderr.strip()}")
        for kind in ("uid", "gid"):
            mapping = sorted(tuple(map(int, line.split())) for line in runtime.guest("cat", f"/proc/self/{kind}_map").splitlines())
            check(mapping == declared_rows(new)[kind], f"guest {kind}_map matches the current declaration")
        observe("restarted.rootfs_owner", lib.run("stat", "-c", "%u:%g", f"{rootfs}/etc"))
        observe("restarted.rootfs_gid_counts", rootfs_gid_counts(lib, rootfs))
        check(guest_exec(lib, project, name, "findmnt", "-n", "-o", "TARGET", "/srv/media").stdout.strip() == "/srv/media",
              "media attachment is mounted in the guest")
        check(guest_exec(lib, project, name, "stat", "-c", "%g", MEDIA_FILE, user=751, group=505).stdout.strip() == "505",
              "guest sees the media file under the fleet GID 505")
        check(guest_exec(lib, project, name, "cat", MEDIA_FILE, user=751, group=505).stdout == "media-capability\n",
              "an identity holding GID 505 reads the media file")
        check(guest_exec(lib, project, name, "cat", MEDIA_FILE, user=751, group=751).returncode != 0,
              "an identity without GID 505 cannot read the media file")
        check(guest_exec(lib, project, name, "cat", MEDIA_FILE).returncode != 0,
              "guest root without GID 505 cannot read the media file")
        k3s_pid = runtime.guest("systemctl", "show", "--value", "-p", "MainPID", "k3s")
        groups = [line.split()[1:] for line in runtime.guest("cat", f"/proc/{k3s_pid}/status").splitlines() if line.startswith("Groups:")]
        check(bool(groups) and "505" in groups[0], "K3s holds the media group under the current map")
        retained = runtime.guest("sh", "-c", "stat -c '%n %u:%g %a' /srv/state/identity-kanidm /srv/state/identity-kanidm/sentinel /srv/state/kubernetes-volumes /srv/state/kubernetes-volumes/sentinel")
        observe("restarted.retained_in_guest", retained.splitlines())
        check(retained.splitlines() == [
            "/srv/state/identity-kanidm 1000:1000 700",
            "/srv/state/identity-kanidm/sentinel 1000:1000 600",
            "/srv/state/kubernetes-volumes 0:0 700",
            "/srv/state/kubernetes-volumes/sentinel 0:0 644",
        ], "retained state keeps its guest ownership")
        check(runtime.guest("cat", "/srv/state/identity-kanidm/sentinel") == "kanidm-db", "retained identity data survives")
        check(runtime.guest("cat", "/var/lib/upgrade-sentinel/root-owned") == "guest-root", "guest root data survives the restart")
        observe("restarted.media_owned_root_file", runtime.guest("stat", "-c", "%u:%g", "/var/lib/upgrade-sentinel/media-owned"))
        stage = lib.completed("systemctl", "restart", "compute-stage-secrets.service", timeout=300)
        check(stage.returncode == 0, "compute-stage-secrets succeeds after the restart")
        check("jellyfin\tjellyfin-admin" in runtime.guest("cat", "/srv/secrets/runtime-secrets.names"),
              "the current credential inventory is staged in the guest")

    with lib.phase("helper images and Argo's jellyfin namespace"):
        # docs/operations/jellyfin.md, "Deliver helper images".
        for archive in args.images.split(","):
            with open(archive, "rb") as stream:
                result = subprocess.run(["incus", "--force-local", "--project", project, "exec", name, "--",
                                         "k3s", "ctr", "--namespace", "k8s.io", "images", "import", "-"],
                                        stdin=stream, capture_output=True, text=True, timeout=600, check=False)
            check(result.returncode == 0, f"helper image imports into the existing guest: {result.stderr.strip()[-300:]}")
        imported = helper_images(lib, project, name)
        observe("images.imported", imported)
        check(len(imported) == 2, "both Jellyfin helper images are present in the existing guest")
        runtime.kubectl("create", "namespace", "jellyfin")
        lib.wait_for("staged Jellyfin credential once its namespace exists", lambda: runtime.kubectl(
            "get", "secret", "jellyfin-admin", "-o", "name", "--ignore-not-found", namespace="jellyfin") == "secret/jellyfin-admin", timeout=300)
        check(runtime.kubectl("get", "configmap", "upgrade-sentinel", "-o", "jsonpath={.data.value}", namespace="default") == "keep",
              "the K3s datastore is unchanged by the in-place upgrade")

    with lib.phase("documented guest replacement"):
        old_uuid = volatile(lib, project, name)["volatile.uuid"]
        with Availability(lib, project, name) as availability:
            started = time.monotonic()
            replace = helper(lib, args, "replace", specs["new"], "--bundle", str(args.bundle), "--confirm", name)
            RESULTS["timings"]["replace_command"] = round(time.monotonic() - started, 2)
            check(replace.returncode == 0, f"replacement succeeds after the restart: {(replace.stdout + replace.stderr).strip()[-400:]}")
            lib.wait_for("replacement K3s node", runtime.node_ready, timeout=600)
            RESULTS["timings"]["replace_until_k3s_ready"] = round(time.monotonic() - started, 2)
            time.sleep(3)
        RESULTS["timings"]["replace_api_outage"] = availability.outage()
        state = volatile(lib, project, name)
        observe("replaced.volatile", state)
        check(state["volatile.uuid"] != old_uuid, "replacement has a fresh instance")
        check(rows(state["volatile.idmap.current"]) == declared_rows(new), "replacement runs the current map")
        check(runtime.guest("sh", "-c", "stat -c '%n %u:%g %a' /srv/state/identity-kanidm /srv/state/identity-kanidm/sentinel /srv/state/kubernetes-volumes /srv/state/kubernetes-volumes/sentinel").splitlines()
              == retained.splitlines(), "replacement keeps retained ownership")
        check(guest_exec(lib, project, name, "test", "-e", "/var/lib/upgrade-sentinel/root-owned").returncode != 0,
              "replacement discards the old guest root, as designed")
        check(runtime.kubectl("get", "configmap", "upgrade-sentinel", "--ignore-not-found", "-o", "name", namespace="default") == "",
              "replacement discards the old K3s datastore, as designed")
        check("jellyfin\tjellyfin-admin" in runtime.guest("cat", "/srv/secrets/runtime-secrets.names"),
              "replacement attaches the staged credentials")
        check(len(helper_images(lib, project, name)) == 2, "the current guest bundle imports the helper images at boot")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--previous-bundle", required=True, type=Path)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--images", required=True)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--upgraded", required=True, type=Path)
    args = parser.parse_args()
    if platform.node() != "fixture-host" or os.geteuid() != 0:
        parser.error("run as root inside the disposable fixture-host VM")
    status = 0
    try:
        run_scenario(args)
        print("PASS: compute guest upgrade scenario completed", flush=True)
    except Exception as error:  # report every failure with the evidence so far
        print(f"FAIL: {type(error).__name__}: {error}", file=sys.stderr, flush=True)
        status = 1
    print("RESULTS: " + json.dumps(RESULTS, sort_keys=True), flush=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
