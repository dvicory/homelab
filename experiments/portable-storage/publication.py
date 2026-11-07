#!/usr/bin/env python3
"""Disposable publication-lifetime experiment, not a Kubernetes or safety gate.

Run on the native host with --lease /run/psx-20261104-ea009e9d/transport-lease.json
and --output NEW_RAM_DIRECTORY after Parent grants its publication phase.
The transport lease needs publication={authorization:'publication-lifetime',
active_guest:'psx-container'|'psx-vm', epoch:UNIQUE_LOWERCASE_TOKEN,
single_active_guest:true, fresh_cache_epoch:true}. Parent establishes that epoch
and stops the other fixture first. No instance lifecycle or daemon mutations here.
Guest-only writers rename a tiny payload inside the admitted ZFS source; host
reads final exact bytes after all guest writes finish. Mounts are guest-private.
Fresh bind/remount writes deliberately expose counterexamples, not enforcement.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
from urllib.parse import quote

PROJECT = "psx-20261104-ea009e9d"
RAM = Path("/run") / PROJECT
HOST = Path("/var/lib/homelab-tests") / PROJECT
GUEST = Path("/srv/portable-storage")
NAMES = ("psx-container", "psx-vm")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def contents(root):
    result = {}
    for path in sorted(root.rglob("*")):
        require(not path.is_symlink(), f"unexpected symlink: {path}")
        if path.is_dir():
            result[str(path.relative_to(root)) + "/"] = None
        else:
            require(path.is_file(), f"unexpected non-file: {path}")
            require(path.stat().st_size <= 4096, f"unexpected large file: {path}")
            result[str(path.relative_to(root))] = path.read_text()
    return result


def put(path, value):
    with path.open("x") as stream:
        stream.write(value)
        stream.flush()
        os.fsync(stream.fileno())
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


# A new native process, not a reused descriptor or an alleged kubelet restart.
WRITER = """
import json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
expected = json.loads(sys.argv[2])
if expected is None:
    assert list(root.iterdir()) == [], 'underlay was not empty'
else:
    assert (root / 'payload').read_text() == expected, 'wrong restarted backing'
with (root / sys.argv[3]).open('x') as stream:
    stream.write(sys.argv[4])
    stream.flush()
    os.fsync(stream.fileno())
fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
os.fsync(fd)
os.close(fd)
print(json.dumps({'pid': os.getpid(), 'uid': os.getuid(), 'path': str(root)}))
"""


def guest(epoch, kind):
    # No custom mount runtime: Linux syscalls in this disposable process only.
    signal.alarm(90)
    require(sys.platform == "linux" and os.getuid() == 0, "guest root on Linux required")
    value = GUEST.stat()
    require(not GUEST.is_symlink() and os.path.ismount(GUEST), "guest source is not mounted")
    require((value.st_uid, value.st_gid, stat.S_IMODE(value.st_mode)) == (1000, 1000, 0o700),
            "guest source ownership/mode mismatch")
    libc = ctypes.CDLL(None, use_errno=True)

    def native(op, *args):
        if getattr(libc, op)(*args) != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), op)

    native("unshare", 0x00020000)  # CLONE_NEWNS
    native("mount", None, b"/", None, 0x4000 | 0x40000, None)  # MS_REC | MS_PRIVATE
    if not RAM.exists():
        RAM.mkdir(mode=0o711)
    require(not RAM.is_symlink() and RAM.stat().st_uid == 0 and
            stat.S_IMODE(RAM.stat().st_mode) & 0o001, "guest RAMroot must permit UID1000 traversal")
    scratch = RAM / ("publication-" + epoch)
    scratch.mkdir(mode=0o755, exist_ok=False)
    published, fresh = scratch / "published", scratch / "fresh"
    for path in (published, fresh):
        path.mkdir(mode=0o700)
        os.chown(path, 1000, 1000)
    events = []

    def mounts():
        selected = []
        for line in Path("/proc/self/mountinfo").read_text().splitlines():
            fields = line.split()
            if fields[4] in (str(GUEST), str(published), str(fresh)):
                split = fields.index("-")
                selected.append({"id": fields[0], "parent": fields[1], "root": fields[3],
                                 "target": fields[4], "options": fields[5],
                                 "fstype": fields[split + 1], "source": fields[split + 2]})
        return selected

    initial_mounts = mounts()
    require(any(item["target"] == str(GUEST) and
                item["fstype"] == ("virtiofs" if kind == "vm" else "zfs")
                for item in initial_mounts), "unexpected native source transport")

    def mount(source, target):
        os.seteuid(0)
        try:
            native("mount", os.fsencode(source), os.fsencode(target), None, 4096, None)
        finally:
            os.seteuid(1000)
        events.append({"operation": "bind", "source": str(source), "mounts": mounts()})

    def unmount(target, lazy=False):
        os.seteuid(0)
        try:
            native("umount2", os.fsencode(target), 2 if lazy else 0)
        finally:
            os.seteuid(1000)
        events.append({"operation": "lazy-unmount" if lazy else "unmount", "mounts": mounts()})

    def restart(path, expected, marker, value):
        os.seteuid(0)
        try:
            result = subprocess.run([sys.executable, "-c", WRITER, str(path),
                                     json.dumps(expected), marker, value],
                                    user=1000, group=1000, extra_groups=[],
                                    capture_output=True, text=True, timeout=10)
        finally:
            os.seteuid(1000)
        require(result.returncode == 0, f"restarted writer failed: {result.stderr}")
        event = json.loads(result.stdout)
        require(event["uid"] == 1000 and event["pid"] != os.getpid(), "not a separate UID1000 writer")
        events.append({"operation": "new-process-write", "marker": marker, **event})

    os.setegid(1000)
    os.seteuid(1000)
    root = GUEST / ("publication-" + epoch)
    root.mkdir(mode=0o700, exist_ok=False)
    live, old = root / "live", root / "old"
    live.mkdir(mode=0o700)
    original = "original payload " + epoch + "\n"
    substitute = "substitute payload " + epoch + "\n"
    put(live / "payload", original)
    mount(live, published)
    directory = os.open(published, os.O_RDONLY | os.O_DIRECTORY)
    held = os.open(published / "payload", os.O_RDWR | os.O_APPEND)
    pinned = os.fstat(directory)
    try:
        live.rename(old)
        live.mkdir(mode=0o700)
        put(live / "payload", substitute)
        require(os.stat(published).st_ino == pinned.st_ino and
                os.stat(live).st_ino != pinned.st_ino, "bind did not pin original directory")
        require(os.pread(held, 4096, 0).decode() == original, "held file changed after replacement")
        os.write(held, b"held before detach\n")
        os.fsync(held)
        with os.fdopen(os.open("held-directory", os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                               0o600, dir_fd=directory), "w") as stream:
            stream.write("original directory reference\n")
            stream.flush()
            os.fsync(stream.fileno())
        restart(published, original + "held before detach\n", "restarted-published",
                "still published original\n")
        # Deliberately reach the substitute: this is the missing-gate counterexample.
        require((live / "payload").read_text() == substitute, "fresh path did not resolve replacement")
        put(live / "fresh-path", "fresh pathname reaches substitute\n")
        mount(live, fresh)
        restart(fresh, substitute, "fresh-bind", "fresh bind reaches substitute\n")
        unmount(fresh)
        unmount(published, lazy=True)
        require(not os.path.ismount(published) and list(published.iterdir()) == [],
                "lazy detach did not expose empty underlay")
        require(os.pread(held, 4096, 0).decode() == original + "held before detach\n",
                "held original file lost on lazy detach")
        os.write(held, b"held after detach\n")
        os.fsync(held)
        fd = os.open("after-detach", os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                     0o600, dir_fd=directory)
        try:
            os.write(fd, b"detached original directory reference\n")
            os.fsync(fd)
        finally:
            os.close(fd)
        os.fsync(directory)
        before_underlay = contents(root)
        restart(published, None, "underlay-write", "empty guest underlay accepted a write\n")
        require(contents(root) == before_underlay, "underlay writer changed retained payload")
        mount(live, published)
        restart(published, substitute, "remounted-writer", "remount reaches substitute\n")
        require(not (published / "underlay-write").exists(), "remount did not hide guest underlay")
        unmount(published)
        require(contents(published) == {"underlay-write": "empty guest underlay accepted a write\n"},
                "wrong exposed underlay contents")
        expected = {"old/": None, "old/payload": original + "held before detach\nheld after detach\n",
                    "old/held-directory": "original directory reference\n",
                    "old/after-detach": "detached original directory reference\n",
                    "old/restarted-published": "still published original\n",
                    "live/": None, "live/payload": substitute,
                    "live/fresh-path": "fresh pathname reaches substitute\n",
                    "live/fresh-bind": "fresh bind reaches substitute\n",
                    "live/remounted-writer": "remount reaches substitute\n"}
        require(contents(root) == expected, "guest original/substitute bytes differ from causal expectations")
        return {"epoch": epoch, "guest_pid": os.getpid(), "initial_mounts": initial_mounts,
                "events": events, "expected_host_contents": expected,
                "underlay_contents": contents(published),
                "counterexamples": ["fresh pathname", "fresh bind", "remounted publication", "empty underlay"],
                "scope": "native guest bind lifetime only; not kubelet cached same-Pod restart",
                "backing_device_failure": "not exercised; physical host ZFS fault forbidden; daemon/session loss is not device loss"}
    finally:
        os.close(held)
        os.close(directory)
        # Exit destroys this private namespace, including mounts left by any failure.


def host(args):
    lease = json.loads(args.lease.read_text())
    phase = lease["publication"]
    require(lease["authorization"] == "disposable-portable-storage" and
            phase["authorization"] == "publication-lifetime", "Parent publication lease required")
    require(phase["single_active_guest"] is True and phase["fresh_cache_epoch"] is True,
            "exclusive fresh cache epoch required")
    epoch, active = phase["epoch"], phase["active_guest"]
    require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,31}", epoch) is not None, "invalid epoch")
    require(lease["project"] == PROJECT and active in NAMES and
            lease["container"] == NAMES[0] and lease["vm"] == NAMES[1], "wrong fixture")
    require(Path(lease["host_root"]) == HOST and Path(lease["guest_root"]) == GUEST,
            "wrong admitted source")
    require((lease["uid"], lease["gid"], lease["host_uid"], lease["host_gid"]) ==
            (1000, 1000, 1132072, 1132072), "wrong fixture mapping")
    require(bool(lease["provenance"]), "Parent provenance required")
    require(Path(lease["socket"]).resolve() ==
            (Path(lease["env"]["INCUS_DIR"]) / "unix.socket").resolve() and
            stat.S_ISSOCK(Path(lease["socket"]).stat().st_mode), "wrong native socket")
    for key in ("incus", "findmnt", "guest_python"):
        require(Path(lease[key]).is_absolute(), f"absolute {key} required")
    require(args.output.parent == RAM and args.output.name.startswith("publication-"),
            "evidence must be a new owned RAMroot publication directory")
    require(not HOST.is_symlink() and HOST.is_dir(), "host source is not a real directory")
    value = HOST.stat()
    require((value.st_uid, value.st_gid, stat.S_IMODE(value.st_mode)) == (1132072, 1132072, 0o700),
            "wrong host source ownership/mode")
    root = HOST / ("publication-" + epoch)
    require(not root.exists() and not root.is_symlink(), "epoch payload already exists")
    args.output.mkdir(mode=0o700, exist_ok=False)
    env = os.environ.copy()
    env.update(lease["env"])
    env.pop("INCUS_SOCKET", None)
    env.update(INCUS_PROJECT=PROJECT, INCUS_REMOTE="local")
    cli = [lease["incus"], "--force-local", "--project", PROJECT]
    trace = []

    def call(command, input=None, timeout=20):
        try:
            result = subprocess.run(command, env=env, input=input, capture_output=True,
                                    text=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            trace.append({"command": command, "error": "timeout", "seconds": timeout})
            raise RuntimeError("bounded native command timed out; Parent must inspect exact owned guest") from error
        trace.append({"command": command, "returncode": result.returncode,
                      "stdout": result.stdout, "stderr": result.stderr})
        require(result.returncode == 0, f"native command failed: {result.stderr}")
        return result.stdout

    try:
        backing = json.loads(call([lease["findmnt"], "--json", "--target", str(HOST),
                                   "--output", "SOURCE,FSTYPE,TARGET"]))
        filesystems = backing["filesystems"]
        require(len(filesystems) == 1 and filesystems[0]["fstype"] == "zfs" and
                filesystems[0]["source"] == "rpool/safe/persist/" + PROJECT and
                filesystems[0]["target"] == str(HOST), "wrong real ZFS source")
        instances = {}
        for name in NAMES:
            uri = "/1.0/instances/" + quote(name, safe="") + "?project=" + PROJECT
            info = json.loads(call([lease["incus"], "--force-local", "query", uri]))
            instances[name] = info
            require(info["status"] == ("Running" if name == active else "Stopped"),
                    "exactly one leased fixture must be active")
            require(info["type"] == ("container" if name == NAMES[0] else "virtual-machine"),
                    "wrong instance type")
            disks = [item for item in info["expanded_devices"].values()
                     if item.get("type") == "disk" and item.get("path") == str(GUEST)]
            require(len(disks) == 1 and disks[0].get("source") == str(HOST), "wrong source attachment")
            if name == NAMES[1]:
                require(disks[0].get("io.bus") == "virtiofs", "explicit virtiofs required")
        source = Path(__file__).read_text()
        result = json.loads(call(cli + ["exec", active, "--", lease["guest_python"], "-",
                                       "--guest", "--epoch", epoch, "--kind",
                                       "container" if active == NAMES[0] else "vm"],
                                 input=source, timeout=120))
        actual = contents(root)
        require(actual == result["expected_host_contents"], "HOST old/substitute exact contents mismatch")
        result.update(status="completed-with-native-counterexamples", active_guest=active,
                      host_contents=actual, backing=backing, instances_before=instances,
                      parent_provenance=lease["provenance"], phase_lease=phase,
                      source_sha256=hashlib.sha256(source.encode()).hexdigest(),
                      cleanup="Parent owns only this epoch's payload and guest RAM scratch retirement; namespace exited")
        put(args.output / "result.json", json.dumps(result, indent=2, sort_keys=True) + "\n")
        print(json.dumps({"status": result["status"], "evidence": str(args.output)}))
    except BaseException as error:
        put(args.output / "failure.json", json.dumps({"status": "failed", "error": str(error),
            "epoch": epoch, "active_guest": active,
            "cleanup": "Parent must inspect exact owned epoch; no broad cleanup attempted"}, indent=2) + "\n")
        raise
    finally:
        put(args.output / "commands.json", json.dumps(trace, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lease", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--guest", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--epoch")
    parser.add_argument("--kind", choices=("container", "vm"))
    args = parser.parse_args()
    if args.guest:
        require(args.epoch is not None and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,31}", args.epoch)
                is not None and args.kind is not None, "internal guest arguments missing")
        print(json.dumps(guest(args.epoch, args.kind), sort_keys=True))
    else:
        require(args.lease is not None and args.output is not None, "--lease and --output required")
        host(args)


if __name__ == "__main__":
    main()
