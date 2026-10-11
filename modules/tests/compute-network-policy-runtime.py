#!/usr/bin/env python3
"""NetworkPolicy enforcement in the unprivileged compute guest.

The fixture host creates the real compute guest through the production
lifecycle helper, loads every committed NetworkPolicy and a stand-in Pod for
each committed workload, then fills the node to its Pod limit with Pods that
committed policies select. It checks that K3s's network-policy controller
syncs without error, installs a firewall chain for every Pod at its current
address, and enforces representative boundaries, before and after a guest
restart.

It also traces one controller sync from the host and records the size of
the iptables-restore batch and the socket send buffer iptables gets inside
the guest, so a failure says why.

Runs only inside the disposable fixture-host VM of
checks.compute-network-policy-runtime.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import time

RESULTS: dict = {"observations": {}}
# The kernel's default socket send buffer before this check existed. The
# fixture must stay larger than this, or the check proves nothing.
OLD_DEFAULT = 212992
# The controller's failure message, and iptables-restore's own when its
# netlink batch is larger than the socket's send buffer.
SYNC_FAILURES = re.compile(r"Aborting sync|Failed to run iptables-restore|Message too long")
POD_CHAIN = re.compile(
    r"^-A KUBE-ROUTER-FORWARD -d (?P<ip>[0-9.]+)/32 .*destined to POD name:(?P<name>\S+) namespace: (?P<namespace>\S+) "
)
# Run inside the guest's user and network namespaces, as K3s's iptables is.
BUFFER_PROBE = r"""
import errno, json, socket
SO_SNDBUFFORCE = 32
sock = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 12)  # NETLINK_NETFILTER
result = {"default": sock.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)}
try:
    sock.setsockopt(socket.SOL_SOCKET, SO_SNDBUFFORCE, 4 << 20)
    result["force"] = "ok"
except OSError as error:
    result["force"] = errno.errorcode[error.errno]
result["after_force"] = sock.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)
print(json.dumps(result))
"""


def load_library(path: Path):
    spec = importlib.util.spec_from_file_location("prod_home_replacement", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def observe(key: str, value) -> None:
    RESULTS["observations"][key] = value
    print(f"EVIDENCE {key}: {json.dumps(value)}", flush=True)


def iov_bytes(line: str) -> int:
    return sum(map(int, re.findall(r"iov_len=(\d+)", line)))


class Guest:
    def __init__(self, lib, runtime, inputs: Path):
        self.lib = lib
        self.runtime = runtime
        self.project = runtime.project
        self.instance = runtime.instance
        self.plan = json.loads((inputs / "plan.json").read_text())

    def init_pid(self) -> int:
        state = json.loads(self.lib.run("incus", "--force-local", "query",
                                        f"/1.0/instances/{self.instance}/state?project={self.project}"))
        return state["pid"]

    def now(self) -> int:
        return int(self.runtime.guest("date", "+%s"))

    def sync_failures(self, since: int) -> list[str]:
        journal = self.runtime.guest("journalctl", "-u", "k3s", f"--since=@{since}", "--no-pager", "-o", "cat",
                                     timeout=300)
        return [line[:300] for line in journal.splitlines() if SYNC_FAILURES.search(line)]

    def filter_table(self) -> str:
        """The filter table, read with the iptables on K3s's own PATH."""
        k3s = self.runtime.guest("systemctl", "show", "--value", "-p", "MainPID", "k3s")
        return self.runtime.guest(
            "sh", "-c", f"PATH=$(tr '\\0' '\\n' < /proc/{k3s}/environ | sed -n 's/^PATH=//p') iptables-save -t filter")

    def pods(self) -> list[dict]:
        return self.runtime.kubectl_json("get", "pods", "--all-namespaces", "-o", "json")["items"]

    def pod_ips(self) -> dict[tuple[str, str], str]:
        return {(pod["metadata"]["namespace"], pod["metadata"]["name"]): pod["status"].get("podIP", "")
                for pod in self.pods()
                if not pod["spec"].get("hostNetwork") and pod["status"].get("phase") not in ("Succeeded", "Failed")}

    def selected_pods(self) -> dict[tuple[str, str], str]:
        """Pods committed policies select: the selected stand-ins and every filler."""
        names = self.plan["names"]
        return {
            key: ip for key, ip in self.pod_ips().items()
            if (key[1] in self.plan["selected"] and names.get(key[1]) == key[0])
            or (key[0] == self.plan["filler"]["namespace"] and key[1].startswith(self.plan["filler"]["name"] + "-"))
        }

    def missing_chains(self) -> list[str]:
        chains = {}
        for line in self.filter_table().splitlines():
            match = POD_CHAIN.match(line)
            if match:
                chains[(match["namespace"], match["name"])] = match["ip"]
        return sorted(f"{namespace}/{name}@{ip}" for (namespace, name), ip in self.selected_pods().items()
                      if chains.get((namespace, name)) != ip)

    def address(self, name: str) -> str:
        return self.runtime.kubectl("get", "pod", name, "-o", "jsonpath={.status.podIP}",
                                    namespace=self.plan["names"][name])

    def reaches(self, client: str, server: str, port: int) -> bool:
        command = ["incus", "--force-local", "--project", self.project, "exec", self.instance,
                   "--mode=non-interactive", "--", "k3s", "kubectl", "exec", client, "-n", self.plan["names"][client],
                   "--", "wget", "-q", "-O", "/dev/null", "-T", "3", f"http://{self.address(server)}:{port}/"]
        return self.lib.completed(*command, timeout=60).returncode == 0

    def waiting(self) -> list[str]:
        return [
            f"{pod['metadata']['namespace']}/{pod['metadata']['name']}: {pod['status'].get('phase')}"
            for pod in self.pods()
            if pod["status"].get("phase") != "Succeeded"
            and not any(c["type"] == "Ready" and c["status"] == "True" for c in pod["status"].get("conditions", []))
        ]

    def wait_ready(self, label: str, predicate=None) -> None:
        try:
            self.lib.wait_for(f"{label}: every Pod ready",
                              lambda: not self.waiting() and (predicate is None or predicate()), timeout=900)
        except Exception:
            observe(f"{label}.not_ready", self.waiting()[:20])
            raise

    def controller_batch(self, workspace: Path) -> dict:
        """Trace one controller sync from the host: the buffer iptables asks
        for and the batch it sends."""
        k3s = self.lib.run("pgrep", "-o", "-f", "k3s server")
        threads = ",".join(os.listdir(f"/proc/{k3s}/task"))
        trace = workspace / "controller.trace"
        tracer = subprocess.Popen(
            ["strace", "-f", "-v", "-s", "0", "-o", str(trace), "-e", "trace=setsockopt,sendmsg",
             "-e", "signal=none", "-p", threads],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        sends: list[str] = []
        try:
            time.sleep(5)
            # A label change on a Pod requests a full sync.
            self.runtime.kubectl("label", "pod", "stranger", f"sync-trigger={time.monotonic_ns()}", "--overwrite",
                                 namespace="media", timeout=300)
            deadline = time.monotonic() + 240
            while not sends and time.monotonic() < deadline:
                time.sleep(5)
                calls = trace.read_text().splitlines() if trace.exists() else []
                sends = [line for line in calls if "sendmsg(" in line and iov_bytes(line) > 16384]
        finally:
            tracer.terminate()
            tracer.wait(timeout=60)
        calls = trace.read_text().splitlines()
        biggest = max(sends, key=iov_bytes, default="")
        result = biggest.rsplit("=", 1)[-1].strip() if biggest else "no batch traced"
        if "unfinished" in biggest:
            pid = biggest.split()[0]
            resumed = [line for line in calls if line.startswith(pid + " ") and "sendmsg resumed" in line]
            result = resumed[0].rsplit("=", 1)[-1].strip() if resumed else "unknown"
        return {
            "batch_bytes": iov_bytes(biggest),
            "batch_result": result,
            "sndbuf_calls": sorted({re.sub(r"^\d+\s+", "", line)[:200] for line in calls if "SO_SNDBUF" in line}),
        }


def create_guest(lib, args, workspace: Path):
    descriptor = json.loads(Path("/etc/homelab/compute.json").read_text())
    lib.wait_for("Incus API", lambda: lib.completed("incus", "--force-local", "query", "/1.0").returncode == 0)
    # Required host paths are mount points in production; bind each from a
    # disposable backing directory with the declared owner and mode.
    for entry in descriptor["requiredPaths"]:
        target = Path(entry["path"])
        backing = workspace / "persist" / str(target).lstrip("/")
        backing.mkdir(parents=True)
        target.mkdir(parents=True, exist_ok=True)
        lib.run("mount", "--bind", str(backing), str(target))
        os.chown(target, entry["uid"], entry["gid"])
        os.chmod(target, int(entry["mode"], 8))
    public_key = lib.stage_identity(descriptor, Path(descriptor["identityPath"]))
    spec = workspace / "compute.json"
    spec.write_text(json.dumps(dict(descriptor, publicKey=public_key), indent=2) + "\n")
    spec.chmod(0o400)
    agenix = Path("/run/agenix")
    agenix.mkdir(exist_ok=True)
    lib.run("mount", "-t", "tmpfs", "-o", "mode=0700,size=1m", "tmpfs", str(agenix))
    for source, entry in descriptor["runtimeSecrets"].items():
        target = agenix / source
        target.write_bytes(lib.fixture_secret_value(entry))
        target.chmod(0o400)
    # As on the host, /srv/media/data is its own mount below /srv/media.
    media = Path(descriptor["devices"]["media"]["source"]) / "data"
    media.mkdir(parents=True, exist_ok=True)
    lib.run("mount", "-t", "tmpfs", "-o", "mode=2750,size=16m", "tmpfs", str(media))
    os.chown(media, 0, 505)
    lib.run("systemctl", "start", "compute-stage-secrets.service", timeout=300)
    lib.run("systemctl", "start", "incus-preseed.service", timeout=600)
    result = lib.completed(str(args.helper), "--spec", str(spec), "create", "--bundle", str(args.bundle), timeout=3_600)
    lib.check(result.returncode == 0, f"the compute guest is created: {(result.stdout + result.stderr).strip()[-400:]}")
    runtime = lib.Runtime(descriptor, spec, args.helper, args.bundle)
    lib.wait_for("K3s node", runtime.node_ready, timeout=600)
    return runtime


def mechanism(lib, guest: Guest, workspace: Path, label: str) -> dict:
    """What iptables gets inside the guest, and how big its batch is."""
    pid = guest.init_pid()
    table = guest.filter_table()
    evidence = {
        "host_wmem_default": int(Path("/proc/sys/net/core/wmem_default").read_text()),
        "netlink_sndbuf_in_guest": json.loads(lib.run(
            "nsenter", "--target", str(pid), "--user", "--net", "--", sys.executable, "-c", BUFFER_PROBE)),
        # As last installed; after a failed sync this is an older table.
        "installed_filter_rules": sum(1 for line in table.splitlines() if line.startswith("-A ")),
        "batch": guest.controller_batch(workspace),
    }
    observe(f"{label}.mechanism", evidence)
    return evidence


def enforce(lib, guest: Guest, workspace: Path, label: str, since: int) -> dict:
    # A sync starts within seconds of a Pod or policy change. Wait until one
    # has installed a chain for every policy-selected Pod at its current
    # address, or give up and report what is missing.
    deadline = time.monotonic() + 420
    missing = guest.missing_chains()
    while missing and time.monotonic() < deadline:
        time.sleep(10)
        missing = guest.missing_chains()
    failures = guest.sync_failures(since)
    observe(f"{label}.pods", {"running": len(guest.pod_ips()), "policy_selected": len(guest.selected_pods())})
    observe(f"{label}.sync_failures", {"count": len(failures), "last": failures[-3:]})
    evidence = mechanism(lib, guest, workspace, label)
    lib.check(not failures, f"{label}: K3s's network-policy controller reports no failed sync")
    lib.check(not missing, f"{label}: every policy-selected Pod has a firewall chain at its current address: {missing[:5]}")
    for probe in guest.plan["probes"]:
        client, server, port, admitted = probe["client"], probe["server"], probe["port"], probe["admitted"]
        reached = lib.wait_for(f"{client} -> {server}:{port}",
                               lambda: guest.reaches(client, server, port) == admitted, timeout=60)
        lib.check(bool(reached), f"{label}: {client} {'reaches' if admitted else 'is refused at'} {server}:{port}")
    batch, buffer = evidence["batch"]["batch_bytes"], evidence["netlink_sndbuf_in_guest"]["default"]
    lib.check(batch > OLD_DEFAULT, f"{label}: the restore batch ({batch} bytes) exceeds the old {OLD_DEFAULT}-byte default")
    lib.check(batch <= buffer - 32, f"{label}: the restore batch ({batch} bytes) fits the guest's send buffer ({buffer} bytes)")
    return evidence


def run_scenario(args) -> None:
    lib = load_library(args.library)
    workspace = Path(tempfile.mkdtemp(prefix="network-policy-"))
    with lib.phase("create the compute guest"):
        runtime = create_guest(lib, args, workspace)
    guest = Guest(lib, runtime, args.inputs)
    created = guest.now()
    with args.image.open("rb") as stream:
        result = subprocess.run(["incus", "--force-local", "--project", runtime.project, "exec", runtime.instance, "--",
                                 "k3s", "ctr", "--namespace", "k8s.io", "images", "import", "-"],
                                stdin=stream, capture_output=True, text=True, timeout=600, check=False)
    lib.check(result.returncode == 0, f"the stand-in image imports into the guest: {result.stderr.strip()[-300:]}")
    with lib.phase("committed policies, stand-ins, and filler up to the Pod limit"):
        for name in ("namespaces", "stand-ins", "policies", "filler"):
            path = f"/tmp/{name}.json"
            lib.run("incus", "--force-local", "--project", runtime.project, "file", "push",
                    str(args.inputs / f"{name}.json"), f"{runtime.instance}{path}")
            runtime.kubectl("apply", "-f", path, timeout=300)
        guest.wait_ready("stand-ins")
        limit = int(runtime.kubectl_json("get", "nodes", "-o", "json")["items"][0]["status"]["allocatable"]["pods"])
        filler = guest.plan["filler"]
        replicas = limit - len(guest.pod_ips())
        lib.check(replicas > 0, f"the node has room for filler Pods below its limit of {limit}")
        runtime.kubectl("scale", "deployment", filler["name"], f"--replicas={replicas}", namespace=filler["namespace"])
        guest.wait_ready("filler", lambda: len(guest.pod_ips()) == limit)
    with lib.phase("enforcement on first boot"):
        enforce(lib, guest, workspace, "first-boot", created)
    with lib.phase("enforcement after a guest restart"):
        before = guest.pod_ips()
        restarted = guest.now()
        lib.run("incus", "--force-local", "--project", runtime.project, "restart", runtime.instance, "--timeout=120",
                timeout=900)
        lib.wait_for("K3s node after the restart", runtime.node_ready, timeout=600)
        guest.wait_ready("restarted", lambda: all(
            ip and ip != before.get(key) for key, ip in guest.selected_pods().items()))
        enforce(lib, guest, workspace, "restarted", restarted)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--inputs", required=True, type=Path)
    args = parser.parse_args()
    if platform.node() != "fixture-host" or os.geteuid() != 0:
        parser.error("run as root inside the disposable fixture-host VM")
    status = 0
    try:
        run_scenario(args)
        print("PASS: compute network policy scenario completed", flush=True)
    except Exception as error:  # report every failure with the evidence so far
        print(f"FAIL: {type(error).__name__}: {error}", file=sys.stderr, flush=True)
        status = 1
    print("RESULTS: " + json.dumps(RESULTS, sort_keys=True), flush=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
