#!/usr/bin/env python3
"""NetworkPolicy enforcement by kube-network-policies in the unprivileged
compute guest, including the migration away from K3s's embedded controller.

The fixture host creates the real compute guest through the production
lifecycle helper and loads every committed NetworkPolicy and Service, a
stand-in Pod for each committed workload, and Pods that committed policies
select until the node is full.

Migration: the guest first runs as a guest from before this change, with
K3s's embedded controller (kube-router) and the host's runtime send-buffer
stopgap. The committed enforcer is applied, K3s is restarted with the
controller disabled, and the stale kube-router rules are removed, as the
runbook describes. A Pod that must be refused probes throughout and must
never get through.

Then, at the kernel's default send buffer, on the migrated boot and after a
guest restart (every Pod gets a new address), it checks the representative
boundaries, a new Pod's first connection, the enforcer's health and metrics,
that no kube-router rule is left, that neither K3s's controller nor
kube-proxy reports a failed restore and that kube-proxy's tables fit the
buffer. On the migrated boot it also kills the enforcer and checks that new
connections are refused, not admitted, until it is back (fail-closed), and
that it holds only NET_ADMIN and cannot reach a render node hotplugged into
the guest, which a privileged control container can open.

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
KERNEL_DEFAULT = 212992
# The owner's runtime stopgap on production until this change deploys.
STOPGAP = 4194304
WMEM = Path("/proc/sys/net/core/wmem_default")
# Failed restores: K3s's embedded controller, kube-proxy, and iptables-nft
# itself when a netlink batch outgrows the socket's send buffer.
RESTORE_FAILURES = re.compile(
    r"Aborting sync|Failed to run iptables-restore|Failed to execute iptables-restore|nftables sync failed"
    r"|Message too long")
KUBE_ROUTER = re.compile(r"KUBE-ROUTER|KUBE-POD-FW|KUBE-NWPLCY")
POD_CHAIN = re.compile(
    r"^-A KUBE-ROUTER-FORWARD -d (?P<ip>[0-9.]+)/32 .*destined to POD name:(?P<name>\S+) namespace: (?P<namespace>\S+) ")
ENFORCER = ("kube-system", "kube-network-policies")
WATCH = ("setsid sh -c 'while :; do if wget -q -T 2 -O /dev/null http://{address}:{port}/; "
         "then echo \"$(date +%s) reached\"; else echo \"$(date +%s) refused\"; fi; sleep 0.5; done' "
         "> /tmp/watch-{name}.log 2>&1 < /dev/null & echo $! > /tmp/watch-{name}.pid")


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
    def __init__(self, lib, runtime, inputs: Path, workspace: Path):
        self.lib = lib
        self.runtime = runtime
        self.project = runtime.project
        self.instance = runtime.instance
        self.inputs = inputs
        self.workspace = workspace
        self.plan = json.loads((inputs / "plan.json").read_text())

    def kubectl(self, *args: str, namespace: str | None = None, timeout: int = 180) -> str:
        return self.runtime.kubectl(*args, namespace=namespace, timeout=timeout)

    def push_apply(self, name: str) -> None:
        path = f"/tmp/{name}.json"
        self.lib.run("incus", "--force-local", "--project", self.project, "file", "push",
                     str(self.inputs / f"{name}.json"), f"{self.instance}{path}")
        self.kubectl("apply", "-f", path, timeout=300)

    def init_pid(self) -> int:
        state = json.loads(self.lib.run("incus", "--force-local", "query",
                                        f"/1.0/instances/{self.instance}/state?project={self.project}"))
        return state["pid"]

    def now(self) -> int:
        return int(self.runtime.guest("date", "+%s"))

    def journal(self, since: int) -> list[str]:
        return self.runtime.guest("journalctl", "-u", "k3s", f"--since=@{since}", "--no-pager", "-o", "cat",
                                  timeout=300).splitlines()

    def restore_failures(self, since: int) -> list[str]:
        return [line[:300] for line in self.journal(since) if RESTORE_FAILURES.search(line)]

    def k3s_path(self) -> str:
        k3s = self.runtime.guest("systemctl", "show", "--value", "-p", "MainPID", "k3s")
        return self.runtime.guest("sh", "-c", f"tr '\\0' '\\n' < /proc/{k3s}/environ | sed -n 's/^PATH=//p'")

    def iptables(self, command: str) -> str:
        """Run an iptables tool from K3s's own PATH inside the guest."""
        return self.runtime.guest("sh", "-c", f"export PATH={self.k3s_path()}; {command}", timeout=300)

    def pods(self) -> list[dict]:
        return self.runtime.kubectl_json("get", "pods", "--all-namespaces", "-o", "json")["items"]

    def active(self) -> list[dict]:
        return [pod for pod in self.pods() if pod["status"].get("phase") not in ("Succeeded", "Failed")]

    def pod_ips(self) -> dict[tuple[str, str], str]:
        return {(pod["metadata"]["namespace"], pod["metadata"]["name"]): pod["status"].get("podIP", "")
                for pod in self.active() if not pod["spec"].get("hostNetwork")}

    def selected_pods(self) -> dict[tuple[str, str], str]:
        names, filler = self.plan["names"], self.plan["filler"]
        return {
            key: ip for key, ip in self.pod_ips().items()
            if (key[1] in self.plan["selected"] and names.get(key[1]) == key[0])
            or (key[0] == filler["namespace"] and key[1].startswith(filler["name"] + "-"))
        }

    def router_chains_missing(self) -> list[str]:
        chains = {}
        for line in self.iptables("iptables-save -t filter").splitlines():
            match = POD_CHAIN.match(line)
            if match:
                chains[(match["namespace"], match["name"])] = match["ip"]
        return sorted(f"{ns}/{name}@{ip}" for (ns, name), ip in self.selected_pods().items()
                      if chains.get((ns, name)) != ip)

    def router_rules(self) -> int:
        saved = self.iptables("iptables-save; ip6tables-save")
        return sum(1 for line in saved.splitlines() if KUBE_ROUTER.search(line))

    def address(self, name: str) -> str:
        return self.kubectl("get", "pod", name, "-o", "jsonpath={.status.podIP}", namespace=self.plan["names"][name])

    def reaches(self, client: str, server: str, port: int, namespace: str | None = None) -> bool:
        namespace = namespace or self.plan["names"][client]
        command = ["incus", "--force-local", "--project", self.project, "exec", self.instance,
                   "--mode=non-interactive", "--", "k3s", "kubectl", "exec", client, "-n", namespace,
                   "--", "wget", "-q", "-O", "/dev/null", "-T", "3", f"http://{self.address(server)}:{port}/"]
        return self.lib.completed(*command, timeout=60).returncode == 0

    def exec_in(self, client: str, *command: str) -> str:
        """kubectl exec, retried: the API server's tunnel to the kubelet can
        be briefly unavailable after a K3s restart."""
        return self.lib.wait_for(f"exec in {client}", lambda: self.kubectl(
            "exec", client, "--", *command, namespace=self.plan["names"][client]) + "\n", timeout=120)

    def watch_start(self, client: str, server: str, port: int) -> str:
        name = f"{client}-{server}"
        self.exec_in(client, "sh", "-c", WATCH.format(address=self.address(server), port=port, name=name))
        return name

    def watch_read(self, client: str, name: str, stop: bool = True) -> list[tuple[int, str]]:
        if stop:
            self.exec_in(client, "sh", "-c", f"kill $(cat /tmp/watch-{name}.pid) 2>/dev/null; true")
        text = self.exec_in(client, "cat", f"/tmp/watch-{name}.log")
        return [(int(line.split()[0]), line.split()[1]) for line in text.splitlines() if len(line.split()) == 2]

    def waiting(self) -> list[str]:
        return [f"{pod['metadata']['namespace']}/{pod['metadata']['name']}: {pod['status'].get('phase')}"
                for pod in self.pods()
                if pod["status"].get("phase") != "Succeeded"
                and not any(c["type"] == "Ready" and c["status"] == "True"
                            for c in pod["status"].get("conditions", []))]

    def wait_ready(self, label: str, predicate=None, timeout: int = 900) -> None:
        try:
            self.lib.wait_for(f"{label}: every Pod ready",
                              lambda: not self.waiting() and (predicate is None or predicate()), timeout=timeout)
        except Exception:
            observe(f"{label}.not_ready", self.waiting()[:20])
            raise

    def enforcer(self) -> dict:
        pods = self.runtime.kubectl_json("get", "pods", "-l", f"app.kubernetes.io/name={ENFORCER[1]}", "-o", "json",
                                         namespace=ENFORCER[0])["items"]
        ds = self.runtime.kubectl_json("get", "daemonset", ENFORCER[1], "-o", "json", namespace=ENFORCER[0])
        return {
            "ready": ds["status"].get("numberReady", 0) == 1 and ds["status"].get("updatedNumberScheduled", 0) == 1,
            "pod": pods[0]["metadata"]["name"] if pods else "",
            "restarts": sum(status.get("restartCount", 0) for pod in pods
                            for status in pod["status"].get("containerStatuses", [])),
        }

    def enforcer_metrics(self) -> dict[str, float]:
        pod = self.enforcer()["pod"]
        text = self.kubectl("get", "--raw", f"/api/v1/namespaces/{ENFORCER[0]}/pods/{pod}:9080/proxy/metrics")
        verdicts: dict[str, float] = {}
        for line in text.splitlines():
            match = re.match(r'kube_network_policies_packet_count\{.*verdict="(\w+)".*\} (\S+)', line)
            if match:
                verdicts[match[1]] = verdicts.get(match[1], 0) + float(match[2])
        return verdicts

    def nft_table(self) -> bool:
        return self.lib.completed("nsenter", "--target", str(self.init_pid()), "--user", "--net", "--",
                                  "nft", "list", "table", "inet", "kube-network-policies").returncode == 0

    def kube_proxy_mode(self) -> str:
        found = self.lib.completed("nsenter", "--target", str(self.init_pid()), "--user", "--net", "--",
                                   "nft", "list", "table", "ip", "kube-proxy").returncode == 0
        return "nftables" if found else "iptables"

    def nft_batch(self) -> dict:
        """Re-send kube-proxy's whole nftables table in check mode with the
        guest's own nft, traced from the host: the kernel validates the batch
        without committing it. kube-proxy's full sync sends at most this."""
        dump = self.workspace / "kube-proxy.nft"
        dump.write_text(self.iptables("nft list table ip kube-proxy") + "\n")
        trace = self.workspace / "kube-proxy.trace"
        with dump.open() as stream:
            result = subprocess.run(
                ["strace", "-f", "-v", "-s", "0", "-o", str(trace), "-e", "trace=sendmsg,setsockopt",
                 "nsenter", "--target", str(self.init_pid()), "--all", "--", "env", f"PATH={self.k3s_path()}",
                 "nft", "-c", "-f", "-"],
                stdin=stream, capture_output=True, text=True, timeout=300, check=False)
        calls = trace.read_text().splitlines()
        sends = [line for line in calls if "sendmsg(" in line]
        return {
            "bytes_listed": len(dump.read_bytes()),
            "batch_bytes": iov_bytes(max(sends, key=iov_bytes, default="")),
            "sndbuf_calls": sorted({re.sub(r"^\d+\s+", "", line)[:160] for line in calls if "SO_SNDBUF" in line}),
            "returncode": result.returncode,
            "stderr": result.stderr.strip()[-200:],
        }

    def kube_proxy_headroom(self) -> dict:
        mode = self.kube_proxy_mode()
        if mode == "nftables":
            return {"mode": mode, "kube-proxy": self.nft_batch(), "filter": self.restore_batch("filter")}
        return {"mode": mode, "nat": self.restore_batch("nat"), "filter": self.restore_batch("filter")}

    def services_work(self) -> dict:
        """kube-proxy forwards a ClusterIP Service between Pods and the
        household ingress NodePort from outside the guest."""
        ip = self.kubectl("get", "service", "radarr", "-o", "jsonpath={.spec.clusterIP}", namespace="media")
        cluster_ip = self.lib.wait_for("ClusterIP Service", lambda: self.lib.completed(
            "incus", "--force-local", "--project", self.project, "exec", self.instance, "--mode=non-interactive",
            "--", "k3s", "kubectl", "exec", "gateway-proxy", "-n", "gateway", "--",
            "wget", "-q", "-O", "/dev/null", "-T", "3", f"http://{ip}:7878/", timeout=60).returncode == 0, timeout=120)
        node_port = self.lib.wait_for("NodePort Service", lambda: self.lib.completed(
            "curl", "-sf", "-m", "3", f"http://{self.runtime.descriptor['address']}:{self.plan['nodePort']}/",
            timeout=30).returncode == 0, timeout=120)
        return {"cluster_ip": bool(cluster_ip), "node_port": bool(node_port)}

    def restore_batch(self, table: str) -> dict:
        """Replay one live table through the guest's own iptables-restore,
        traced from the host, at the current send buffer. A replay rewrites
        the table with its own contents; kube-proxy's full sync writes at
        most this much."""
        rules = self.workspace / f"{table}.rules"
        rules.write_text(self.iptables(f"iptables-save -t {table}") + "\n")
        trace = self.workspace / f"{table}.trace"
        with rules.open() as stream:
            result = subprocess.run(
                ["strace", "-f", "-v", "-s", "0", "-o", str(trace), "-e", "trace=sendmsg",
                 "nsenter", "--target", str(self.init_pid()), "--all", "--", "env", f"PATH={self.k3s_path()}",
                 "iptables-restore", "-w", "-T", table],
                stdin=stream, capture_output=True, text=True, timeout=300, check=False)
        sends = [line for line in trace.read_text().splitlines() if "sendmsg(" in line]
        biggest = max(sends, key=iov_bytes, default="")
        return {
            "rules": sum(1 for line in rules.read_text().splitlines() if line.startswith("-A ")),
            "batch_bytes": iov_bytes(biggest),
            "returncode": result.returncode,
            "stderr": result.stderr.strip()[-200:],
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


def restart_k3s(lib, guest: Guest) -> None:
    guest.runtime.guest("systemctl", "daemon-reload")
    guest.runtime.guest("systemctl", "restart", "k3s", timeout=600)
    lib.wait_for("K3s node after the K3s restart", guest.runtime.node_ready, timeout=600)


def as_before_change(lib, guest: Guest, args) -> None:
    """Run the guest as one from before this change: K3s's embedded
    controller and kube-proxy in iptables mode, with the host's runtime
    send-buffer stopgap so the controller can sync."""
    override = Path(args.old_unit).read_text()
    guest.runtime.guest("sh", "-c", f"sed -E 's/(mode\"?:[[:space:]]*\"?)nftables/\\1iptables/' {args.proxy_config} "
                                    f"> {args.before_proxy_config} && grep -q iptables {args.before_proxy_config}")
    guest.runtime.guest("sh", "-c", "mkdir -p /run/systemd/system/k3s.service.d && "
                                    "cat > /run/systemd/system/k3s.service.d/90-before-enforcer.conf "
                                    f"<<'EOF'\n{override}EOF")
    WMEM.write_text(str(STOPGAP))
    restart_k3s(lib, guest)
    try:
        lib.wait_for("kube-proxy in iptables mode", lambda: guest.kube_proxy_mode() == "iptables"
                     and "KUBE-SERVICES" in guest.iptables("iptables-save -t nat"), timeout=300)
    except Exception:
        journal = guest.journal(guest.now() - 600)
        observe("before-change.diagnostics", {
            "exec_start": guest.runtime.guest("systemctl", "show", "-p", "ExecStart", "--value", "k3s")[:600],
            "nft_tables": guest.iptables("nft list tables"),
            "nat_kube_services": guest.iptables("iptables-save -t nat | grep -c KUBE-SERVICES || true"),
            "proxy_lines": [line[:240] for line in journal if "proxy" in line.lower() or "nftables" in line][-15:],
        })
        raise


def migrate(lib, guest: Guest, args) -> None:
    """From K3s's embedded controller to the committed enforcer, in the
    runbook's order, with a refused Pod probing throughout."""
    runtime = guest.runtime
    guest.wait_ready("embedded controller", lambda: not guest.router_chains_missing(), timeout=900)
    observe("migration.before", {"router_rules": guest.router_rules(), "pods": len(guest.active())})
    lib.check(not guest.reaches("stranger", "radarr", 7878), "before migration: kube-router refuses the stranger")
    stranger = guest.watch_start("stranger", "radarr", 7878)
    caller = guest.watch_start("gateway-proxy", "radarr", 7878)
    started = guest.now()

    # 1. Argo applies the enforcer while kube-router still enforces.
    guest.push_apply("enforcer")
    lib.wait_for("enforcer ready", lambda: guest.enforcer()["ready"], timeout=600)
    # 2. The guest's K3s restarts with the embedded controller disabled.
    runtime.guest("sh", "-c", "mkdir -p /etc/rancher/k3s/config.yaml.d && "
                              "printf 'disable-network-policy: true\\n' > "
                              "/etc/rancher/k3s/config.yaml.d/50-disable-network-policy.yaml")
    restart_k3s(lib, guest)
    stale = guest.router_rules()
    observe("migration.stale_router_rules_after_restart", stale)
    # 3. The runbook's cleanup.
    with open(args.cleanup) as script:
        result = subprocess.run(["incus", "--force-local", "--project", guest.project, "exec", guest.instance,
                                 "--", "sh", "-s"], stdin=script, capture_output=True, text=True, timeout=300,
                                check=False)
    observe("migration.cleanup", {"returncode": result.returncode, "output": (result.stdout + result.stderr)[-400:]})
    lib.check(result.returncode == 0, "the runbook's kube-router cleanup succeeds")
    time.sleep(10)
    refused = guest.watch_read("stranger", stranger)
    admitted = guest.watch_read("gateway-proxy", caller)
    observe("migration.window", {
        "seconds": guest.now() - started,
        "stranger": {state: sum(1 for _, s in refused if s == state) for state in ("reached", "refused")},
        "caller": {state: sum(1 for _, s in admitted if s == state) for state in ("reached", "refused")},
    })
    lib.check(stale > 0, "K3s leaves kube-router's rules behind when the controller is disabled")
    lib.check(guest.router_rules() == 0, "no kube-router rule is left after the cleanup")
    lib.check(refused and all(state == "refused" for _, state in refused),
              "the stranger is refused at radarr throughout the migration")
    lib.check(admitted and admitted[-1][1] == "reached", "the Gateway proxy reaches radarr after the migration")
    WMEM.write_text(str(KERNEL_DEFAULT))


def crash(lib, guest: Guest) -> None:
    """Kill the enforcer twice so the kubelet backs off, and watch a declared
    caller and a stranger while it is down."""
    before = guest.enforcer()["restarts"]
    caller = guest.watch_start("gateway-proxy", "radarr", 7878)
    stranger = guest.watch_start("stranger", "radarr", 7878)
    time.sleep(3)
    killed = int(time.time())
    lib.run("pkill", "-9", "-f", "/bin/netpol")
    lib.wait_for("enforcer restarted once", lambda: guest.enforcer()["restarts"] > before, timeout=120)
    time.sleep(2)
    lib.run("pkill", "-9", "-f", "/bin/netpol")
    lib.wait_for("enforcer back after the back-off", lambda: guest.enforcer()["ready"]
                 and guest.enforcer()["restarts"] >= before + 2, timeout=300)
    time.sleep(10)
    admitted = guest.watch_read("gateway-proxy", caller)
    refused = guest.watch_read("stranger", stranger)
    down = [state for at, state in admitted if at >= killed]
    observe("crash", {"caller_after_kill": {s: down.count(s) for s in ("reached", "refused")},
                      "stranger": {s: sum(1 for _, x in refused if x == s) for s in ("reached", "refused")},
                      "restarts": guest.enforcer()["restarts"] - before})
    lib.check("refused" in down, "fail-closed: while the enforcer is down a declared caller's new connection is refused")
    lib.check(admitted[-1][1] == "reached", "the declared caller reaches radarr again once the enforcer is back")
    lib.check(all(state == "refused" for _, state in refused), "the stranger is refused throughout the crash")


RENDER_NODE = "/dev/dri/renderD128"
NET_ADMIN = 1 << 12


def no_device_access(lib, guest: Guest) -> None:
    """The enforcer holds NET_ADMIN only and cannot reach the delegated render
    node, which a privileged container could open."""
    lib.run("modprobe", "vgem")
    lib.wait_for("render node in the guest", lambda: guest.runtime.guest(
        "stat", "-c", "%F", RENDER_NODE, check_result=False) == "character special file", timeout=120)
    pid = lib.run("pgrep", "-o", "-f", "/bin/netpol")
    status = dict(line.split(":\t", 1) for line in Path(f"/proc/{pid}/status").read_text().splitlines() if ":\t" in line)
    enforcer_dev = sorted(os.listdir(f"/proc/{pid}/root/dev"))
    # Unprivileged, it must still reach containerd's NRI socket, which gives
    # it Pod addresses before the API server does.
    logs = guest.kubectl("logs", f"daemonset/{ENFORCER[1]}", "--tail=-1", namespace=ENFORCER[0])
    nri = {"connected": "Created plugin" in logs, "failed": "failed to create NRI plugin" in logs}
    guest.push_apply("device-probes")
    guest.wait_ready("device probes", timeout=300)

    def in_probe(name: str, script: str) -> subprocess.CompletedProcess:
        return lib.completed("incus", "--force-local", "--project", guest.project, "exec", guest.instance,
                             "--mode=non-interactive", "--", "k3s", "kubectl", "exec", name, "-n", ENFORCER[0],
                             "--", "sh", "-c", script, timeout=60)

    twin_sees = in_probe("enforcer-twin", f"test -e {RENDER_NODE}").returncode == 0
    twin_mknod = in_probe("enforcer-twin", "mknod /tmp/render c 226 128 && exec 3<>/tmp/render")
    twin_caps = in_probe("enforcer-twin", "grep CapEff /proc/self/status").stdout.split()[-1:]
    control = in_probe("privileged-control", f"exec 3<>{RENDER_NODE}")
    guest.kubectl("delete", "-f", "/tmp/device-probes.json", "--wait=true", timeout=300)
    observe("device_access", {
        "enforcer": {"CapEff": status.get("CapEff", "").strip(), "NoNewPrivs": status.get("NoNewPrivs", "").strip(),
                     "dev": enforcer_dev},
        "twin": {"sees_node": twin_sees, "mknod": (twin_mknod.stdout + twin_mknod.stderr).strip()[-160:],
                 "CapEff": twin_caps},
        "privileged_control_opens": control.returncode == 0,
        "nri": nri,
    })
    lib.check(nri["connected"] and not nri["failed"], "the unprivileged enforcer connects to containerd's NRI socket")
    lib.check(int(status["CapEff"], 16) == NET_ADMIN, "the enforcer's only effective capability is NET_ADMIN")
    lib.check(status.get("NoNewPrivs", "").strip() == "1", "the enforcer cannot gain privileges")
    lib.check("dri" not in enforcer_dev, "the enforcer's /dev has no render node")
    lib.check(not twin_sees and twin_mknod.returncode != 0,
              "a container with the enforcer's securityContext cannot see or create the render node")
    lib.check(control.returncode == 0, "a privileged container in the same guest could open the render node")


def enforce(lib, guest: Guest, label: str, since: int, expect_nftables: bool) -> None:
    for probe in guest.plan["probes"]:
        client, server, port, admitted = probe["client"], probe["server"], probe["port"], probe["admitted"]
        reached = lib.wait_for(f"{client} -> {server}:{port}",
                               lambda: guest.reaches(client, server, port) == admitted, timeout=60)
        lib.check(bool(reached), f"{label}: {client} {'reaches' if admitted else 'is refused at'} {server}:{port}")
    # A new Pod's first connection, with no retry.
    guest.push_apply("newcomers")
    guest.wait_ready(f"{label} newcomers", timeout=300)
    for name, admitted in guest.plan["newcomers"].items():
        reached = guest.reaches(name, "radarr", 7878, namespace="media")
        lib.check(reached == admitted, f"{label}: {name}'s first connection to radarr is {'admitted' if admitted else 'refused'}")
    guest.kubectl("delete", "-f", "/tmp/newcomers.json", "--wait=true", timeout=300)
    enforcer = guest.enforcer()
    metrics = guest.enforcer_metrics()
    failures = guest.restore_failures(since)
    headroom = guest.kube_proxy_headroom()
    services = guest.services_work()
    observe(f"{label}.state", {"pods": len(guest.active()), "policy_selected": len(guest.selected_pods()),
                               "services": guest.plan["services"], "enforcer": enforcer, "verdicts": metrics,
                               "wmem_default": int(WMEM.read_text()),
                               "wmem_max": int(Path("/proc/sys/net/core/wmem_max").read_text()),
                               "restore_failures": failures[-3:], "router_rules": guest.router_rules(),
                               "kube_proxy": headroom, "service_paths": services})
    lib.check(int(WMEM.read_text()) == KERNEL_DEFAULT, f"{label}: the host still runs the kernel's default send buffer")
    lib.check(enforcer["ready"], f"{label}: the enforcer DaemonSet is ready")
    lib.check(guest.nft_table(), f"{label}: the enforcer's nftables table is installed")
    lib.check(metrics.get("drop", 0) > 0 and metrics.get("accept", 0) > 0,
              f"{label}: the enforcer's metrics count accepted and dropped connections")
    lib.check(guest.router_rules() == 0, f"{label}: no kube-router rule is installed")
    lib.check(not failures, f"{label}: K3s reports no failed iptables restore")
    lib.check(services["cluster_ip"] and services["node_port"],
              f"{label}: kube-proxy forwards a ClusterIP Service and the ingress NodePort")
    if expect_nftables:
        lib.check(headroom["mode"] == "nftables", f"{label}: kube-proxy runs in nftables mode")
        lib.check(headroom["kube-proxy"]["returncode"] == 0,
                  f"{label}: kube-proxy's whole table ({headroom['kube-proxy']['batch_bytes']} bytes) "
                  "is accepted in one batch at the default buffers")
        lib.check(headroom["filter"]["returncode"] == 0,
                  f"{label}: the iptables filter table ({headroom['filter']['batch_bytes']} bytes) restores "
                  "within the default buffer")


def boot_window(guest: Guest) -> dict:
    """How long policy-selected Pods ran after the guest started before the
    enforcer was ready: the window a boot leaves unenforced."""
    def stamp(value: str) -> float:
        return time.mktime(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ"))

    pods = {(pod["metadata"]["namespace"], pod["metadata"]["name"]): pod for pod in guest.active()}
    enforcer = next(pod for key, pod in pods.items() if key[0] == ENFORCER[0] and key[1].startswith(ENFORCER[1]))
    ready = next(c["lastTransitionTime"] for c in enforcer["status"]["conditions"] if c["type"] == "Ready")
    started = sorted(
        stamp(status["state"]["running"]["startedAt"])
        for key in guest.selected_pods()
        for status in pods[key]["status"].get("containerStatuses", [])
        if "running" in status.get("state", {})
    )
    return {"first_selected_pod_started_before_enforcer_ready_s": stamp(ready) - started[0] if started else None,
            "selected_pods_started_before_enforcer_ready": sum(1 for at in started if at < stamp(ready))}


def run_scenario(args) -> None:
    lib = load_library(args.library)
    workspace = Path(tempfile.mkdtemp(prefix="network-policy-"))
    with lib.phase("create the compute guest"):
        runtime = create_guest(lib, args, workspace)
    guest = Guest(lib, runtime, args.inputs, workspace)
    # Enforcement must work at the kernel's default buffer, not at a tuned one.
    lib.check(args.kernel_default_wmem == KERNEL_DEFAULT and int(WMEM.read_text()) == KERNEL_DEFAULT,
              f"the fixture host runs the kernel's default {KERNEL_DEFAULT}-byte send buffer")
    with args.image.open("rb") as stream:
        result = subprocess.run(["incus", "--force-local", "--project", runtime.project, "exec", runtime.instance, "--",
                                 "k3s", "ctr", "--namespace", "k8s.io", "images", "import", "-"],
                                stdin=stream, capture_output=True, text=True, timeout=600, check=False)
    lib.check(result.returncode == 0, f"the stand-in image imports into the guest: {result.stderr.strip()[-300:]}")
    observe("guest", {"k3s_path": guest.k3s_path(), "iptables": guest.iptables("command -v iptables-save; iptables --version"),
                      "ipset": guest.iptables("command -v ipset || true"),
                      "killmode": runtime.guest("systemctl", "show", "-p", "KillMode", "--value", "k3s"),
                      "host_wmem_max": int(Path("/proc/sys/net/core/wmem_max").read_text())})
    with lib.phase("committed objects, the guest as before the change, filler up to the Pod limit"):
        for name in ("namespaces", "services", "stand-ins", "policies", "filler"):
            guest.push_apply(name)
        guest.wait_ready("stand-ins")
        as_before_change(lib, guest, args)
        guest.wait_ready("before the change")
        # kube-proxy's iptables tables at the production Service and Pod count.
        WMEM.write_text(str(KERNEL_DEFAULT))
        observe("before-change.production-count", {"pods": len(guest.active()),
                                                    "kube_proxy": guest.kube_proxy_headroom()})
        WMEM.write_text(str(STOPGAP))
        limit = int(runtime.kubectl_json("get", "nodes", "-o", "json")["items"][0]["status"]["allocatable"]["pods"])
        # Room for the enforcer and the two newcomer Pods.
        replicas = limit - len(guest.active()) - 3
        lib.check(replicas > 0, f"the node has room for filler Pods below its limit of {limit}")
        filler = guest.plan["filler"]
        guest.kubectl("scale", "deployment", filler["name"], f"--replicas={replicas}", namespace=filler["namespace"])
        guest.wait_ready("filler", lambda: len(guest.active()) == limit - 3)
    with lib.phase("migration from the embedded controller"):
        migrate(lib, guest, args)
    with lib.phase("enforcement after the migration"):
        # The guest still runs its pre-change K3s unit, with kube-proxy in
        # iptables mode; its tables are recorded, not required to fit.
        enforce(lib, guest, "migrated", guest.now() - 5, expect_nftables=False)
    with lib.phase("the enforcer has no device access"):
        no_device_access(lib, guest)
    with lib.phase("enforcer crash"):
        crash(lib, guest)
    with lib.phase("enforcement after a guest restart"):
        before = guest.pod_ips()
        restarted = guest.now()
        lib.run("incus", "--force-local", "--project", runtime.project, "restart", runtime.instance, "--timeout=120",
                timeout=900)
        lib.wait_for("K3s node after the restart", runtime.node_ready, timeout=600)
        guest.wait_ready("restarted", lambda: guest.enforcer()["ready"] and all(
            ip and ip != before.get(key) for key, ip in guest.selected_pods().items()))
        observe("restarted.boot_window", boot_window(guest))
        # The restart drops the pre-change unit: this is the guest as the
        # bundle declares it, kube-proxy in nftables mode.
        enforce(lib, guest, "restarted", restarted, expect_nftables=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--inputs", required=True, type=Path)
    parser.add_argument("--old-unit", required=True, help="k3s.service drop-in for a guest from before this change")
    parser.add_argument("--cleanup", required=True, help="the runbook's kube-router cleanup script")
    parser.add_argument("--proxy-config", required=True, help="the guest's kube-proxy configuration")
    parser.add_argument("--before-proxy-config", required=True, help="where the iptables-mode copy goes")
    parser.add_argument("--kernel-default-wmem", required=True, type=int)
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
