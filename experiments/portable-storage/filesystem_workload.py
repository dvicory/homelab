#!/usr/bin/env python3
"""Disposable Linux guest filesystem qualification; not a durability proof.

As UID/GID 1000, with /srv/vfq already writable:
  python3 filesystem_workload.py --root /srv/vfq/fs-CFG-RUN --run CFG-RUN --op run
  python3 filesystem_workload.py --root /srv/vfq/fs-CFG-RUN --run CFG-RUN --op verify
  python3 filesystem_workload.py --root /srv/vfq/eof-CFG-RUN --run CFG-RUN --op partial-eof

run and partial-eof require a NEW direct child of /srv/vfq. verify is read-only
and requires the same externally recorded --run after the Parent's crash/reopen.
Every operation has a 25-second deadline; data is bounded below 4 MiB. Expected
final bytes are deterministic from --run, not inferred from surviving contents.
Success asserts guest-local observed semantics only, not physical durability,
host/guest external coherence, SQLite impact, or any unperformed fault case.
"""
import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import mmap
import multiprocessing
import os
from pathlib import Path
import signal
import stat
import time

from sqlite_workload import emit, fsync_dir, mount_info, require


GENERATIONS = 32
RECORD_BYTES = 16384
DATA_LIMIT = 4 * 1024 * 1024


def alarm_expired(signum, frame):
    raise TimeoutError("filesystem workload exceeded its 25-second deadline")


def arm_deadline(deadline):
    signal.signal(signal.SIGALRM, alarm_expired)
    signal.setitimer(signal.ITIMER_REAL, max(0.001, deadline - time.monotonic()))


def record(run, generation):
    header = f"vfq:{generation:08d}:".encode()
    body = hashlib.sha256(f"{run}:{generation}".encode()).digest()
    return header + (body * (RECORD_BYTES // len(body) + 1))[:RECORD_BYTES - len(header)]


def mapped_bytes(run, stage, size):
    return hashlib.sha256(f"mmap:{run}:{stage}".encode()).digest() * (size // 32)


def durable_create(path, value):
    with path.open("xb") as stream:
        require(stream.write(value) == len(value), "short file write")
        stream.flush()
        os.fsync(stream.fileno())


def receive(channel, expected, deadline):
    require(channel.poll(max(0, deadline - time.monotonic())), f"timeout waiting for {expected}")
    value = channel.recv()
    require(value[0] == expected, f"expected {expected}, received {value}")
    return value


def child_entry(target, channel, deadline, args):
    arm_deadline(deadline)
    try:
        target(channel, deadline, *args)
    finally:
        channel.close()


def start_worker(workers, target, deadline, *args):
    context = multiprocessing.get_context("spawn")
    parent, child = context.Pipe()
    process = context.Process(target=child_entry, args=(target, child, deadline, args))
    workers.append((process, parent))
    process.start()
    child.close()
    return process, parent


def finish_worker(process, deadline):
    process.join(timeout=max(0, deadline - time.monotonic()))
    require(not process.is_alive() and process.exitcode == 0,
            f"owned child {process.pid} failed or timed out: {process.exitcode}")


def cleanup(workers):
    # Only handles returned by our own spawn calls; never numeric PID searches.
    for process, channel in workers:
        channel.close()
        if process.pid is not None and process.is_alive():
            process.terminate()
    for process, _ in workers:
        if process.pid is None:
            continue
        process.join(timeout=0.2)
        if process.is_alive():
            process.kill()
            process.join(timeout=0.2)
        require(not process.is_alive(), f"owned child {process.pid} remains alive after SIGKILL")


def mapped_peer(channel, deadline, path, run, size):
    with path.open("r+b", buffering=0) as stream:
        with mmap.mmap(stream.fileno(), size, flags=mmap.MAP_SHARED,
                       prot=mmap.PROT_READ | mmap.PROT_WRITE) as view:
            require(view[:] == mapped_bytes(run, "initial", size), "peer initial map differs")
            channel.send(("mapped",))
            receive(channel, "check-map", deadline)
            expected = mapped_bytes(run, "parent-map", size)
            require(view[:] == expected, "peer existing mapping missed parent MAP_SHARED write")
            require(os.pread(stream.fileno(), size + 1, 0) == expected, "pread missed mapped write")
            view[:] = mapped_bytes(run, "peer-map", size)
            channel.send(("peer-mapped",))
            receive(channel, "check-pwrite", deadline)
            expected = mapped_bytes(run, "parent-pwrite", size)
            require(view[:] == expected, "existing peer mapping missed pwrite")
            require(os.pread(stream.fileno(), size + 1, 0) == expected, "peer pread missed pwrite")
            expected = mapped_bytes(run, "peer-pwrite", size)
            require(os.pwrite(stream.fileno(), expected, 0) == size, "short peer pwrite")
            channel.send(("peer-pwrite",))


def fresh_reader(channel, deadline, path, expected):
    with path.open("rb", buffering=0) as stream:
        require(stream.read(len(expected) + 1) == expected, "fresh-process exact bytes differ")
    channel.send(("fresh-exact",))


def mapping_probe(root, run, page, workers, deadline):
    size = 2 * page
    path = root / "mapped.bin"
    durable_create(path, mapped_bytes(run, "initial", size))
    fsync_dir(root)
    with path.open("r+b", buffering=0) as stream:
        with mmap.mmap(stream.fileno(), size, flags=mmap.MAP_SHARED,
                       prot=mmap.PROT_READ | mmap.PROT_WRITE) as view:
            process, channel = start_worker(workers, mapped_peer, deadline, path, run, size)
            receive(channel, "mapped", deadline)
            # Handshakes deliberately precede flush/fsync: they test visibility, not persistence.
            view[:] = mapped_bytes(run, "parent-map", size)
            channel.send(("check-map",))
            receive(channel, "peer-mapped", deadline)
            expected = mapped_bytes(run, "peer-map", size)
            require(view[:] == expected, "parent mapping missed peer MAP_SHARED write")
            require(os.pread(stream.fileno(), size + 1, 0) == expected, "parent pread missed mmap")
            view.flush()  # Linux mmap.flush invokes msync(MS_SYNC).
            os.fsync(stream.fileno())
            reader, reply = start_worker(workers, fresh_reader, deadline, path, expected)
            receive(reply, "fresh-exact", deadline)
            finish_worker(reader, deadline)
            expected = mapped_bytes(run, "parent-pwrite", size)
            require(os.pwrite(stream.fileno(), expected, 0) == size, "short parent pwrite")
            channel.send(("check-pwrite",))
            receive(channel, "peer-pwrite", deadline)
            expected = mapped_bytes(run, "peer-pwrite", size)
            require(view[:] == expected, "parent existing mapping missed peer pwrite")
            require(os.pread(stream.fileno(), size + 1, 0) == expected, "parent pread missed pwrite")
            view.flush()
            os.fsync(stream.fileno())
            finish_worker(process, deadline)
            reader, reply = start_worker(workers, fresh_reader, deadline, path, expected)
            receive(reply, "fresh-exact", deadline)
            finish_worker(reader, deadline)
    return {"bidirectional_shared_mmap": True, "bidirectional_pwrite_to_existing_map": True,
            "pread_exact": True, "msync_then_file_fsync_fresh_process_exact": True,
            "bytes": size}


def lock(fd, kind, unlock=False, disjoint=False):
    operation = fcntl.LOCK_UN if unlock else fcntl.LOCK_EX | fcntl.LOCK_NB
    if kind == "posix":
        fcntl.lockf(fd, operation, 16 if disjoint else 32, 80 if disjoint else 16, os.SEEK_SET)
    else:
        fcntl.flock(fd, operation)


def excluded(fd, kind):
    try:
        lock(fd, kind)
    except OSError as error:
        require(error.errno in (errno.EAGAIN, errno.EACCES), f"unexpected lock error: {error}")
    else:
        lock(fd, kind, unlock=True)
        raise RuntimeError(f"{kind}: independently opened descriptor acquired held lock")


def lock_peer(channel, deadline, path, kind):
    with path.open("r+b", buffering=0) as stream:
        excluded(stream.fileno(), kind)
        if kind == "posix":
            lock(stream.fileno(), kind, disjoint=True)
            lock(stream.fileno(), kind, unlock=True, disjoint=True)
        channel.send(("excluded",))
        receive(channel, "released", deadline)
        lock(stream.fileno(), kind)
        channel.send(("acquired",))
        receive(channel, "close", deadline)
    channel.send(("closed",))


def lock_probe(root, workers, deadline):
    path = root / "locks.bin"
    durable_create(path, b"\0" * 128)
    fsync_dir(root)
    evidence = {}
    with path.open("r+b", buffering=0) as stream:
        for kind in ("posix", "flock"):
            lock(stream.fileno(), kind)
            process, channel = start_worker(workers, lock_peer, deadline, path, kind)
            receive(channel, "excluded", deadline)
            lock(stream.fileno(), kind, unlock=True)
            channel.send(("released",))
            receive(channel, "acquired", deadline)
            excluded(stream.fileno(), kind)
            channel.send(("close",))
            receive(channel, "closed", deadline)
            finish_worker(process, deadline)
            lock(stream.fileno(), kind)
            lock(stream.fileno(), kind, unlock=True)
            evidence[kind] = {"bidirectional_exclusion": True, "explicit_unlock_release": True,
                              "peer_close_release": True, "disjoint_range": kind == "posix"}
    return evidence


def replacement_reader(channel, deadline, path, run):
    known = {record(run, generation): generation for generation in range(GENERATIONS + 1)}
    observations = [0] * (GENERATIONS + 1)
    background_reads = 0

    def read_generation():
        with path.open("rb", buffering=0) as stream:
            value = stream.read(RECORD_BYTES + 1)
        require(value in known, "atomic replacement exposed partial, mixed or unknown generation")
        generation = known[value]
        observations[generation] += 1
        return generation

    require(read_generation() == 0, "replacement reader missed initial generation")
    channel.send(("ready",))
    while True:
        read_generation()  # ENOENT and all other I/O failures intentionally fail the child.
        background_reads += 1
        if channel.poll():
            command = channel.recv()
            if command[0] == "observe":
                require(read_generation() == command[1], "reader missed acknowledged generation")
                channel.send(("observed", command[1]))
            else:
                require(command == ("stop",), "unknown replacement reader command")
                require(all(count > 0 for count in observations), "not every generation was observed")
                channel.send(("done", {"observations_by_generation": observations,
                                        "background_reads": background_reads,
                                        "exact_known_records_only": True}))
                return
        require(time.monotonic() < deadline, "replacement reader deadline exceeded")


def replacement_probe(root, run, workers, deadline):
    path = root / "generation.bin"
    durable_create(path, record(run, 0))
    fsync_dir(root)
    readers = [start_worker(workers, replacement_reader, deadline, path, run) for _ in range(2)]
    for _, channel in readers:
        receive(channel, "ready", deadline)
    for generation in range(1, GENERATIONS + 1):
        temporary = root / "generation.next"
        durable_create(temporary, record(run, generation))
        os.replace(temporary, path)
        fsync_dir(root)
        # No subsequent replacement until BOTH independent readers read these exact bytes.
        for _, channel in readers:
            channel.send(("observe", generation))
        for _, channel in readers:
            require(receive(channel, "observed", deadline)[1] == generation, "wrong generation ACK")
    evidence = []
    for _, channel in readers:
        channel.send(("stop",))
    for process, channel in readers:
        evidence.append(receive(channel, "done", deadline)[1])
        finish_worker(process, deadline)
    expected = record(run, GENERATIONS)
    durable_create(root / "expected-final.bin", expected)
    manifest = {"run": run, "final_generation": GENERATIONS, "bytes": RECORD_BYTES,
                "sha256": hashlib.sha256(expected).hexdigest(), "mapped_page_bytes": os.sysconf("SC_PAGE_SIZE")}
    durable_create(root / "expected.json", (json.dumps(manifest, sort_keys=True) + "\n").encode())
    fsync_dir(root)
    return {"readers": evidence, "final": manifest}


def verify_final(root, run, page):
    expected = record(run, GENERATIONS)
    manifest = {"run": run, "final_generation": GENERATIONS, "bytes": RECORD_BYTES,
                "sha256": hashlib.sha256(expected).hexdigest(), "mapped_page_bytes": page}
    require(json.loads((root / "expected.json").read_text()) == manifest, "expected manifest differs")
    for name in ("generation.bin", "expected-final.bin"):
        with (root / name).open("rb") as stream:
            require(stream.read(RECORD_BYTES + 1) == expected, f"{name}: exact final generation differs")
    expected_map = mapped_bytes(run, "peer-pwrite", 2 * page)
    with (root / "mapped.bin").open("rb") as stream:
        require(stream.read(len(expected_map) + 1) == expected_map, "persisted mapped bytes differ")
    require(not (root / "generation.next").exists(), "replacement staging file remains")
    return manifest


def partial_eof(root, page):
    """Adapt the primary syscall ordering, not its raw privileged /dev/fuse server.

    https://lists.openwall.net/linux-kernel/2026/08/24/1443
    Python mmap rejects length beyond st_size; libc permits the final partial page.
    No flush/close/reopen before pread: those could invalidate the polluted cache.
    """
    libc = ctypes.CDLL(None, use_errno=True)
    libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int,
                          ctypes.c_int, ctypes.c_longlong]
    libc.mmap.restype = ctypes.c_void_p
    libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    libc.munmap.restype = ctypes.c_int
    evidence = []
    for mode in ("pwrite-later-page", "ftruncate", "posix-fallocate", "pwrite-same-page"):
        path = root / (mode + ".bin")
        eof, base = 2 * page + page // 4, 2 * page
        with path.open("x+b", buffering=0) as stream:
            fd = stream.fileno()
            require(os.pwrite(fd, b"A" * eof, 0) == eof, "short EOF setup write")
            address = libc.mmap(None, page, mmap.PROT_READ | mmap.PROT_WRITE,
                                mmap.MAP_SHARED, fd, base)
            require(address != ctypes.c_void_p(-1).value and address is not None,
                    f"partial-EOF mmap failed: errno {ctypes.get_errno()}")
            try:
                ctypes.memset(address + page // 4, 0xee, 3 * page // 4)
                require(ctypes.string_at(address + page // 4, 3 * page // 4)
                        == b"\xee" * (3 * page // 4), "EOF tail pollution was not established")
                if mode == "pwrite-later-page":
                    position, value = 5 * page + page // 3, b"data"
                    require(os.pwrite(fd, value, position) == len(value), "short extending pwrite")
                    expected = b"A" * eof + b"\0" * (position - eof) + value
                elif mode == "ftruncate":
                    os.ftruncate(fd, 8 * page)
                    expected = b"A" * eof + b"\0" * (8 * page - eof)
                elif mode == "posix-fallocate":
                    os.posix_fallocate(fd, eof, 4 * page)
                    expected = b"A" * eof + b"\0" * (4 * page)
                else:
                    position, value = base + 3 * page // 4, b"B" * (2 * page)
                    require(os.pwrite(fd, value, position) == len(value), "short same-page pwrite")
                    expected = b"A" * eof + b"\0" * (position - eof) + value
                actual = os.pread(fd, len(expected) + 1, 0)
                mismatch = next((offset for offset, (got, want) in enumerate(zip(actual, expected))
                                 if got != want), None)
                passed = actual == expected
                evidence.append({"case": mode, "exact_bytes": passed, "old_eof": eof,
                                 "expected_size": len(expected), "actual_size": len(actual),
                                 "first_mismatch_offset": mismatch,
                                 "first_mismatch_byte": actual[mismatch] if mismatch is not None else None,
                                 "observed_sha256": hashlib.sha256(actual).hexdigest(),
                                 "expected_sha256": hashlib.sha256(expected).hexdigest()})
            finally:
                require(libc.munmap(address, page) == 0, "partial-EOF munmap failed")
            os.fsync(fd)
    fsync_dir(root)
    emit({"event": "partial_eof", "classification": "mmap-dirtied-post-EOF-extension-regression",
          "source": "https://lists.openwall.net/linux-kernel/2026/08/24/1443",
          "page_bytes": page, "cases": evidence, "ordinary_sqlite_impact_claim": False})
    require(all(item["exact_bytes"] for item in evidence), "partial-EOF extension exposed incorrect bytes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--run", required=True)
    parser.add_argument("--op", required=True, choices=("run", "verify", "partial-eof"))
    parser.add_argument("--uid", type=int, default=1000)
    parser.add_argument("--gid", type=int, default=1000)
    args = parser.parse_args()
    require(os.name == "posix" and Path("/proc/self/mountinfo").is_file(), "Linux guest required")
    require(args.root.is_absolute() and args.root.parent == Path("/srv/vfq")
            and args.root.name not in ("", ".", ".."), "root must be a dedicated direct child of /srv/vfq")
    require(args.root.parent.resolve(strict=True) == args.root.parent, "data parent must not be symlinked")
    require(args.run and len(args.run) <= 128 and args.run.isascii(), "bounded ASCII run identity required")
    require((os.geteuid(), os.getegid()) == (args.uid, args.gid) and args.uid != 0,
            "run as the requested unprivileged UID/GID (default 1000:1000)")
    page = os.sysconf("SC_PAGE_SIZE")
    require(4096 <= page <= 65536 and page % 32 == 0, "page size outside bounded probe assumptions")
    os.umask(0o077)
    started = time.monotonic()
    deadline = started + 25
    arm_deadline(deadline)
    workers = []
    try:
        if args.op != "verify":
            args.root.mkdir(mode=0o700, exist_ok=False)
            fsync_dir(args.root.parent)
        owner = args.root.lstat()
        require(stat.S_ISDIR(owner.st_mode) and not args.root.is_symlink()
                and (owner.st_uid, owner.st_gid, stat.S_IMODE(owner.st_mode))
                == (args.uid, args.gid, 0o700), "dedicated root owner/mode must match UID/GID/0700")
        if args.op == "run":
            mapping = mapping_probe(args.root, args.run, page, workers, deadline)
            locks = lock_probe(args.root, workers, deadline)
            replacement = replacement_probe(args.root, args.run, workers, deadline)
            verify_final(args.root, args.run, page)
            emit({"event": "filesystem", "run": args.run, "mapping": mapping, "locks": locks,
                  "replacement": replacement, "file_fsync": True, "directory_fsync": True})
        elif args.op == "verify":
            emit({"event": "filesystem_reopen_verified", "final": verify_final(args.root, args.run, page),
                  "exact_final_generation_and_mapped_bytes": True})
        else:
            partial_eof(args.root, page)
        logical_bytes = sum(path.stat().st_size for path in args.root.iterdir())
        require(logical_bytes <= DATA_LIMIT, "filesystem workload exceeded 4 MiB logical data ceiling")
        emit({"event": "filesystem_complete", "op": args.op, "run": args.run,
              "elapsed_s": time.monotonic() - started, "deadline_s": 25,
              "logical_file_bytes": logical_bytes, "uid": os.geteuid(), "gid": os.getegid(),
              "mount": mount_info(args.root), "physical_durability_claim": False,
              "host_guest_external_coherence_claim": False})
    finally:
        cleanup(workers)
        signal.setitimer(signal.ITIMER_REAL, 0)


if __name__ == "__main__":
    main()
