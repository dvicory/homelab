#!/usr/bin/env python3
"""Run only after Parent admits a disposable runtime; creates no guests or services.

--lease is Parent's JSON: authorization='disposable-portable-storage', incus,
findmnt, socket, env={INCUS_DIR,...}, project, container, vm, host_root, guest_root,
guest_python, guest_script, uid, gid, host_uid, host_gid, denied_uid, denied_gid,
provenance={...}, phase='transport-exclusive', vm_cache_mode='unsafe'.
Parent stages the identical workload at guest_script in both instances.
--output is a new external host evidence dir. socket is checked provenance;
the native client routes through INCUS_DIR. The phase lease permits serial
stop/start of BOTH test fixtures, including their bootstrap services. Only one
guest runs at a time; each VM phase starts a fresh mount/cache epoch. Boot is
outside measurement. No simultaneous host/guest or cross-guest writer claim.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import stat
import subprocess
import sys
import time
from urllib.parse import quote

from sqlite_workload import identity, payload, require


def durable_json(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def host_stat(path):
    value = path.stat()
    return {"device": value.st_dev, "inode": value.st_ino, "uid": value.st_uid,
            "gid": value.st_gid, "mode": oct(stat.S_IMODE(value.st_mode)),
            "bytes": value.st_size, "allocated_bytes": value.st_blocks * 512}


def footprint(root):
    files = {name: host_stat(root / name)
             for name in ("portable.sqlite3", "portable.sqlite3-wal", "portable.sqlite3-shm")
             if (root / name).exists()}
    apparent = sum(value["bytes"] for value in files.values())
    require(apparent <= 8 * 1024 * 1024, "owned SQLite footprint exceeds admitted 8MiB bound")
    return {"files": files, "apparent_bytes": apparent,
            "allocated_bytes": sum(value["allocated_bytes"] for value in files.values())}


class Experiment:
    def __init__(self, lease, output, commits, repeats):
        self.lease, self.output = lease, output
        self.commits, self.repeats = commits, repeats
        self.env = os.environ.copy()
        self.env.update(lease["env"])
        self.env.pop("INCUS_SOCKET", None)
        self.env.update(INCUS_PROJECT=lease["project"], INCUS_REMOTE="local")
        self.cli = [lease["incus"], "--force-local", "--project", lease["project"]]
        self.trace = []
        self.crash_ledgers = []

    def call(self, command, *, input=None, timeout=60, check=True):
        result = subprocess.run(command, env=self.env, input=input, capture_output=True,
                                text=True, timeout=timeout)
        self.trace.append({"command": command, "returncode": result.returncode,
                           "stdout": result.stdout, "stderr": result.stderr})
        if check and result.returncode:
            raise RuntimeError(f"command failed ({result.returncode}): {command}: {result.stderr}")
        return result

    def incus(self, *args, **kwargs):
        return self.call(self.cli + list(args), **kwargs)

    def instance(self, name):
        path = "/1.0/instances/" + quote(name, safe="") + "?project=" + quote(self.lease["project"], safe="")
        return json.loads(self.call([self.lease["incus"], "--force-local", "query", path]).stdout)

    def activate(self, name):
        require(name in (self.lease["container"], self.lease["vm"]), "unleased guest")
        for instance in (self.lease["container"], self.lease["vm"]):
            status = self.instance(instance)["status"]
            require(status in ("Running", "Stopped"), f"unexpected guest state: {instance}: {status}")
            if status == "Running" and (instance != name or instance == self.lease["vm"]):
                self.incus("stop", instance, "--force", timeout=60)
                require(self.instance(instance)["status"] == "Stopped", "guest did not stop")
        if self.instance(name)["status"] == "Stopped":
            self.incus("start", name, timeout=90)
        deadline = time.monotonic() + 90
        while True:
            result = self.incus("exec", name, "--", self.lease["guest_python"], "--version",
                                timeout=10, check=False)
            if result.returncode == 0:
                break
            require(time.monotonic() < deadline, "guest agent not operational after activation")
            time.sleep(1)
        other = self.lease["vm"] if name == self.lease["container"] else self.lease["container"]
        require(self.instance(other)["status"] == "Stopped", "inactive guest is still running")

    def guest_command(self, name, *args, denied=False):
        lease = self.lease
        uid, gid = ((lease["denied_uid"], lease["denied_gid"]) if denied else
                    (lease["uid"], lease["gid"]))
        return self.cli + ["exec", name, "--user", str(uid), "--group", str(gid),
                           "--", lease["guest_python"], lease["guest_script"],
                           "--root", lease["guest_root"], "--uid", str(lease["uid"]),
                           "--gid", str(lease["gid"]), *args]

    def workload(self, name, *args, input=None, denied=False):
        result = self.call(self.guest_command(name, *args, denied=denied), input=input)
        return json.loads(result.stdout)

    def crash(self, name, kind):
        run = f"{name}-{kind}"
        acks, armed, pid, start_token = [], None, None, None
        ledger_path = self.output / f"{run}-external-acks.jsonl"
        command = self.guest_command(name, "--op", "crash-writer", "--run", run,
                                     "--commits", str(self.commits))
        with ledger_path.open("x") as ledger, (self.output / f"{run}-stderr.txt").open("x") as errors:
            os.fsync(ledger.fileno())
            directory = os.open(self.output, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
            process = subprocess.Popen(command, env=self.env, stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=errors)
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            buffered = b""
            try:
                while armed is None:
                    require(selector.select(timeout=30), "timed out waiting for writer event")
                    chunk = os.read(process.stdout.fileno(), 65536)
                    require(chunk, "writer exited before fault was armed; inspect stderr evidence")
                    buffered += chunk
                    while b"\n" in buffered:
                        line, buffered = buffered.split(b"\n", 1)
                        event = json.loads(line)
                        ledger.write(json.dumps(event, sort_keys=True) + "\n")
                        ledger.flush()
                        os.fsync(ledger.fileno())
                        require(event.get("run") == run, "writer event has wrong run identity")
                        if event["event"] == "started":
                            require(pid is None and event["pid"] > 1 and
                                    str(event["start_token"]).isdigit(), "invalid writer identity")
                            pid, start_token = event["pid"], event["start_token"]
                        elif event["event"] == "ack":
                            require(len(acks) < self.commits, "too many ACKs")
                            wanted = identity(run, len(acks), payload(run, len(acks)))
                            require({key: event[key] for key in wanted} == wanted, "ACK identity mismatch")
                            acks.append(wanted)
                            # The guest cannot advance until this external ledger is fsynced.
                            process.stdin.write(b"\n")
                            process.stdin.flush()
                        elif event["event"] == "armed":
                            require(len(acks) == self.commits and event["pid"] == pid and
                                    event["start_token"] == start_token,
                                    "fault armed without all external ACKs/own writer identity")
                            checkpoint = event["committed_wal_checkpoint"]
                            require(event["pending_seq"] == self.commits and event["wal_bytes"] > 0
                                    and checkpoint[0] == 0 and checkpoint[1] > 0 and checkpoint[2] == 0,
                                    "missing pending transaction/uncheckpointed committed WAL")
                            armed = event
                        else:
                            raise RuntimeError(f"unexpected writer event: {event}")
                fault_footprint = footprint(Path(self.lease["host_root"]))
                if kind == "process-kill":
                    self.workload(name, "--op", "kill-writer", "--run", run,
                                  "--writer-pid", str(pid), "--writer-start", start_token)
                else:
                    self.incus("stop", name, "--force")
                    require(self.instance(name)["status"] == "Stopped", "VM did not stop")
                    # A stopped VM proves writer death; its exec websocket may stay open.
                    process.kill()
                returncode = process.wait(timeout=30)
                require(returncode != 0, "exec client survived the injected fault")
            except BaseException:
                if pid is not None and process.poll() is None:
                    try:
                        self.call(self.guest_command(name, "--op", "kill-writer", "--run", run,
                                                     "--writer-pid", str(pid),
                                                     "--writer-start", start_token),
                                  check=False, timeout=10)
                    except (OSError, subprocess.TimeoutExpired) as cleanup_error:
                        self.trace.append({"cleanup_error": str(cleanup_error), "instance": name, "pid": pid})
                raise
            finally:
                selector.close()
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
                process.stdin.close()
                process.stdout.close()
        if kind == "vm-stop":
            self.activate(name)
        # Read the persisted external ledger, not merely the in-memory ACK count.
        persisted = [json.loads(line) for line in ledger_path.read_text().splitlines()]
        external = [{key: event[key] for key in ("run", "seq", "sha256")}
                    for event in persisted if event["event"] == "ack"]
        require(external == acks, "external ledger differs from acknowledged identities")
        self.crash_ledgers.append((run, ledger_path, armed["pending_seq"]))
        recovered = {}
        # The faulted transport must recover first, before another guest can checkpoint it.
        for instance in (name, self.lease["vm"] if name == self.lease["container"]
                         else self.lease["container"]):
            if instance != name:
                self.activate(instance)
            recovered[instance] = {}
            for previous_run, previous_ledger, pending_seq in self.crash_ledgers:
                events = [json.loads(line) for line in previous_ledger.read_text().splitlines()]
                previous_acks = [{key: event[key] for key in ("run", "seq", "sha256")}
                                 for event in events if event["event"] == "ack"]
                require(len(previous_acks) == self.commits, "incomplete accumulated ACK ledger")
                expected = json.dumps({"acks": previous_acks, "pending_seq": pending_seq})
                recovered[instance][previous_run] = self.workload(
                    instance, "--op", "verify", "--run", previous_run, input=expected)
        return {"instance": name, "fault": kind, "external_ledger": ledger_path.name,
                "exec_client_returncode": returncode, "armed": armed, "recovery": recovered,
                "footprint_before_fault": fault_footprint,
                "footprint_after_recovery": footprint(Path(self.lease["host_root"])),
                "host_database": host_stat(Path(self.lease["host_root"]) / "portable.sqlite3")}

    def run(self):
        lease = self.lease
        root = Path(lease["host_root"])
        require(not root.is_symlink() and root.is_dir(), "host root must be a real directory")
        before = host_stat(root)
        require((before["uid"], before["gid"], before["mode"]) ==
                (lease["host_uid"], lease["host_gid"], "0o700"), "wrong host ownership/mode")
        require(not (root / "portable.sqlite3").exists(), "experiment database already exists")
        backing = json.loads(self.call([lease["findmnt"], "--json", "--target", str(root),
                                       "--output", "SOURCE,FSTYPE,TARGET,OPTIONS"]).stdout)
        filesystems = backing["filesystems"]
        require(len(filesystems) == 1 and filesystems[0]["fstype"] not in
                ("tmpfs", "ramfs", "overlay", "9p", "virtiofs"), "not real host filesystem backing")
        instances = {name: self.instance(name) for name in (lease["container"], lease["vm"])}
        for name, info in instances.items():
            require(info["status"] in ("Running", "Stopped"), f"leased instance not stable: {name}")
            require(info["type"] == ("virtual-machine" if name == lease["vm"] else "container"),
                    "wrong instance type")
            disks = [device for device in info["expanded_devices"].values()
                     if device.get("type") == "disk" and device.get("path") == lease["guest_root"]]
            require(len(disks) == 1 and disks[0].get("source") == str(root), "not the same host backing")
            if name == lease["vm"]:
                require(disks[0].get("io.bus") == "virtiofs", "VM transport must explicitly select virtiofs")
                require(disks[0].get("io.cache") == lease["vm_cache_mode"],
                        "VM cache mode differs from explicit phase lease")
        source_hash = hashlib.sha256(Path(__file__).with_name("sqlite_workload.py").read_bytes()).hexdigest()
        guest_hashes, probes = {}, {}
        for name in instances:
            self.activate(name)
            result = self.incus("exec", name, "--", lease["guest_python"], "-c",
                                "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())",
                                lease["guest_script"])
            guest_hashes[name] = result.stdout.strip()
            require(guest_hashes[name] == source_hash, "guest workload source differs")
            probes[name] = {"probe": self.workload(name, "--op", "probe"),
                            "unrelated_uid": self.workload(name, "--op", "denied", denied=True)}
        provenance = {"parent": lease["provenance"],
                      "incus_version": self.incus("version").stdout, "instances_before": instances,
                      "backing": backing, "host_root_before": before, "host_uname": list(os.uname()),
                      "driver_python": sys.version, "workload_sha256": source_hash,
                      "guest_workload_sha256": guest_hashes,
                      "measurement": {"commits_per_run": self.commits, "repeats": self.repeats,
                                      "payload_bytes": 1024, "order": "container then VM, interleaved repeats",
                                      "cache_policy": "single active guest; fresh VM mount/cache epoch each phase; no host cache dropping",
                                      "boot_timing": "excluded from all workload measurements",
                                      "vm_cache_mode": lease["vm_cache_mode"],
                                      "coherence_scope": "no concurrent host/guest or cross-guest writers",
                                      "fault_scope": "guest/process only; no host power-loss durability claim"}}
        durable_json(self.output / "provenance.json", provenance)
        # Probes above also run with exclusive guest ownership, including source hash checks.
        durable_json(self.output / "probes.json", probes)
        require(probes[lease["vm"]]["probe"]["mount"]["filesystem"] == "virtiofs",
                "actual VM retained mount is not virtiofs")
        require(probes[lease["container"]]["probe"]["mount"]["filesystem"] == filesystems[0]["fstype"],
                "container retained mount differs from real host backing")
        database = host_stat(root / "portable.sqlite3")
        require((database["uid"], database["gid"]) == (lease["host_uid"], lease["host_gid"]),
                "created database has wrong mapped host owner")
        benchmarks = []
        for repeat in range(self.repeats):
            for name in instances:
                self.activate(name)
                benchmarks.append({"instance": name, "repeat": repeat,
                                   **self.workload(name, "--op", "benchmark", "--run", f"{name}-bench-{repeat}",
                                                   "--commits", str(self.commits))})
                benchmarks[-1]["host_footprint_after_checkpoint"] = footprint(root)
        durable_json(self.output / "benchmarks.json", {"probes": probes, "runs": benchmarks})
        faults = []
        for name, kind in ((lease["container"], "process-kill"), (lease["vm"], "process-kill"),
                           (lease["vm"], "vm-stop")):
            self.activate(name)
            fault = self.crash(name, kind)
            require((fault["host_database"]["device"], fault["host_database"]["inode"]) ==
                    (database["device"], database["inode"]), "host database object was replaced")
            faults.append(fault)
            durable_json(self.output / f"{name}-{kind}-result.json", fault)
        return {"status": "completed", "benchmarks": benchmarks, "faults": faults,
                "instances_after": {name: self.instance(name) for name in instances},
                "host_database_after": host_stat(root / "portable.sqlite3"),
                "cleanup": "Parent owns guest, script, database, daemon and dataset retirement"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lease", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--commits", type=int, default=100)
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    lease = json.loads(args.lease.read_text())
    require(lease["authorization"] == "disposable-portable-storage", "missing runtime lease authorization")
    require(lease["phase"] == "transport-exclusive",
            "Parent must release bootstrap and both fixtures for serial transport ownership")
    require(lease["vm_cache_mode"] == "unsafe",
            "explicit Parent-probed filesystem cache=always phase required")
    require(lease["env"]["INCUS_DIR"], "explicit admitted runtime directory required")
    require(Path(lease["socket"]).resolve() ==
            (Path(lease["env"]["INCUS_DIR"]) / "unix.socket").resolve(),
            "socket provenance does not match native INCUS_DIR routing")
    require(stat.S_ISSOCK(Path(lease["socket"]).stat().st_mode), "admitted runtime socket is not a socket")
    require(lease["project"] == "psx-20261104-ea009e9d"
            and lease["container"] == "psx-container" and lease["vm"] == "psx-vm",
            "only the exact owned disposable project/fixtures are admitted")
    require(lease["uid"] != 0 and lease["denied_uid"] not in (0, lease["uid"]), "invalid access-test UIDs")
    require(bool(lease["provenance"]), "Parent software/image/backing provenance required")
    for key in ("incus", "findmnt", "socket", "host_root", "guest_root", "guest_python", "guest_script"):
        require(Path(lease[key]).is_absolute(), f"absolute {key} required")
    require(1 <= args.commits <= 100 and 3 <= args.repeats <= 5, "bounded commits/repeats required")
    require(not args.output.resolve().is_relative_to(Path(lease["host_root"]).resolve()),
            "external ACK evidence must not reside on the tested retained root")
    args.output.mkdir(mode=0o700, parents=False, exist_ok=False)
    experiment = Experiment(lease, args.output, args.commits, args.repeats)
    try:
        result = experiment.run()
    except BaseException as error:
        durable_json(args.output / "failure.json", {"status": "failed", "type": type(error).__name__,
                                                   "error": str(error), "cleanup": "Parent must inspect/retire leased resources"})
        raise
    else:
        durable_json(args.output / "result.json", result)
        print(json.dumps({"status": result["status"], "evidence": str(args.output)}))
    finally:
        durable_json(args.output / "commands.json", experiment.trace)


if __name__ == "__main__":
    main()
