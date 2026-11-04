#!/usr/bin/env python3
"""Bounded experiment workload, identical for bind and virtiofs. Not production code."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import signal
import sqlite3
import stat
import subprocess
import sys
import time
from urllib.parse import quote


def emit(value):
    print(json.dumps(value, sort_keys=True), flush=True)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def mount_info(root):
    matches = []
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        fields = line.split()
        mountpoint = fields[4]
        for escaped, plain in ((r"\040", " "), (r"\011", "\t"), (r"\012", "\n"), (r"\134", "\\")):
            mountpoint = mountpoint.replace(escaped, plain)
        if root.is_relative_to(Path(mountpoint)):
            separator = fields.index("-")
            matches.append((len(mountpoint), {"mountpoint": mountpoint,
                                             "filesystem": fields[separator + 1],
                                             "source": fields[separator + 2], "raw": line}))
    require(bool(matches), "retained path has no visible mount")
    return max(matches, key=lambda item: item[0])[1]


def connect(root, create=False):
    db = root / "portable.sqlite3"
    con = sqlite3.connect("file:" + quote(str(db)) + "?mode=" + ("rwc" if create else "rw"),
                          uri=True, timeout=0.2, isolation_level=None)
    require(con.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal", "WAL unavailable")
    con.execute("PRAGMA synchronous=FULL")
    require(con.execute("PRAGMA synchronous").fetchone()[0] == 2, "FULL unavailable")
    if create:
        con.execute("CREATE TABLE IF NOT EXISTS commits (run TEXT NOT NULL, seq INTEGER NOT NULL, "
                    "payload BLOB NOT NULL, PRIMARY KEY(run,seq))")
        fsync_dir(root)
    return con


def payload(run, seq):
    return hashlib.sha256(f"{run}:{seq}".encode()).digest() * 32


def identity(run, seq, value):
    return {"run": run, "seq": seq, "sha256": hashlib.sha256(value).hexdigest()}


def verify(con, run, expected, pending=None):
    rows = con.execute("SELECT seq,payload FROM commits WHERE run=? ORDER BY seq", (run,)).fetchall()
    actual = [identity(run, seq, value) for seq, value in rows]
    require(actual == expected, f"row identities differ for {run}")
    for seq, value in rows:
        require(value == payload(run, seq), f"payload mismatch {run}:{seq}")
    integrity = con.execute("PRAGMA integrity_check").fetchall()
    require(integrity == [("ok",)], f"integrity_check: {integrity}")
    if pending is not None:
        require(con.execute("SELECT 1 FROM commits WHERE run=? AND seq=?", (run, pending)).fetchone()
                is None, "uncommitted crash row survived")
    digest = hashlib.sha256(json.dumps(actual, sort_keys=True).encode()).hexdigest()
    return {"event": "verified", "run": run, "rows": len(rows), "identities_sha256": digest,
            "integrity_check": "ok", "pending_absent": pending is not None}


def contend(args):
    con = connect(args.root)
    started = time.perf_counter()
    try:
        con.execute("BEGIN IMMEDIATE")
    except sqlite3.OperationalError as error:
        require(not args.expect_unlocked and error.sqlite_errorcode == sqlite3.SQLITE_BUSY,
                f"unexpected contention error: {error}")
        elapsed = time.perf_counter() - started
        require(elapsed >= 0.15, "busy timeout did not wait")
        emit({"event": "contention", "sqlite_error": error.sqlite_errorname, "wait_s": elapsed})
    else:
        con.rollback()
        require(args.expect_unlocked, "second process acquired a held write lock")
        emit({"event": "lock_reacquired"})
    finally:
        con.close()


def probe(args):
    root = args.root
    before = root.stat()
    require((before.st_uid, before.st_gid, stat.S_IMODE(before.st_mode)) ==
            (args.uid, args.gid, 0o700), "root UID/GID/mode does not match mapped owner/0700")
    require((os.geteuid(), os.getegid()) == (args.uid, args.gid), "wrong effective UID/GID")
    source, target = root / "fsync-source", root / "fsync-renamed"
    with source.open("xb") as stream:
        stream.write(b"portable-storage-fsync-rename\n")
        stream.flush()
        os.fsync(stream.fileno())
        os.fchown(stream.fileno(), args.uid, args.gid)
        os.fsync(stream.fileno())
    fsync_dir(root)
    source.rename(target)
    fsync_dir(root)
    require(target.read_bytes() == b"portable-storage-fsync-rename\n", "rename content mismatch")
    owner = target.stat()
    require((owner.st_uid, owner.st_gid) == (args.uid, args.gid), "created file ownership mismatch")
    con = connect(root, create=True)
    con.execute("BEGIN IMMEDIATE")
    command = [sys.executable, str(Path(__file__).resolve()), "--root", str(root), "--op", "contend"]
    try:
        blocked = subprocess.run(command, check=True, capture_output=True, text=True, timeout=10)
    finally:
        con.rollback()
    unlocked = subprocess.run(command + ["--expect-unlocked"], check=True, capture_output=True,
                              text=True, timeout=10)
    emit({"event": "probe", "python": sys.version, "sqlite": sqlite3.sqlite_version,
          "kernel": platform.release(), "machine": platform.machine(),
          "mount": mount_info(root),
          "root": str(root), "root_dev": before.st_dev, "root_inode": before.st_ino,
          "uid": before.st_uid, "gid": before.st_gid, "mode": oct(stat.S_IMODE(before.st_mode)),
          "created_file_uid": owner.st_uid, "created_file_gid": owner.st_gid,
          "file_fsync": True, "directory_fsync": True, "rename_content_preserved": True,
          "rename_atomicity_tested": False,
          "journal_mode": con.execute("PRAGMA journal_mode").fetchone()[0],
          "synchronous": con.execute("PRAGMA synchronous").fetchone()[0],
          "page_size": con.execute("PRAGMA page_size").fetchone()[0],
          "wal_autocheckpoint": con.execute("PRAGMA wal_autocheckpoint").fetchone()[0],
          "compile_options": [row[0] for row in con.execute("PRAGMA compile_options")],
          "contention": json.loads(blocked.stdout), "reacquired": json.loads(unlocked.stdout)})
    con.close()
    target.unlink()
    fsync_dir(root)


def write_rows(args):
    con = connect(args.root)
    require(con.execute("SELECT 1 FROM commits WHERE run=? LIMIT 1", (args.run,)).fetchone() is None,
            "run identity already exists")
    reader = None
    if args.op == "crash-writer":
        con.execute("PRAGMA wal_autocheckpoint=0")
        require(con.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone() == (0, 0, 0),
                "cannot establish empty WAL before crash run")
        reader = connect(args.root)
        reader.execute("BEGIN")
        require(reader.execute("SELECT count(*) FROM commits WHERE run=?", (args.run,)).fetchone()
                == (0,), "reader snapshot contains crash run")
        start_token = Path("/proc/self/stat").read_text().rsplit(")", 1)[1].split()[19]
        emit({"event": "started", "pid": os.getpid(), "start_token": start_token, "run": args.run})
    values = [payload(args.run, seq) for seq in range(args.commits)]
    latencies = []
    started = time.perf_counter()
    for seq, value in enumerate(values):
        con.execute("BEGIN IMMEDIATE")
        con.execute("INSERT INTO commits VALUES (?,?,?)", (args.run, seq, value))
        commit_start = time.perf_counter_ns()
        con.commit()
        latencies.append((time.perf_counter_ns() - commit_start) / 1e6)
        if args.op == "crash-writer":
            emit({"event": "ack", **identity(args.run, seq, value)})
            require(sys.stdin.readline() == "\n", "external durable ACK handshake lost")
    elapsed = time.perf_counter() - started
    if args.op == "crash-writer":
        # The old reader snapshot prevents any of this run's committed frames being checkpointed.
        checkpoint = con.execute("PRAGMA wal_checkpoint(PASSIVE)").fetchone()
        require(checkpoint[0] == 0 and checkpoint[1] > 0 and checkpoint[2] == 0,
                f"committed WAL is not wholly uncheckpointed: {checkpoint}")
        require(reader.execute("SELECT count(*) FROM commits WHERE run=?", (args.run,)).fetchone()
                == (0,), "pinned reader snapshot advanced")
        wal = args.root / "portable.sqlite3-wal"
        require(wal.is_file() and wal.stat().st_size > 0, "no real WAL file before fault")
        con.execute("BEGIN IMMEDIATE")
        con.execute("INSERT INTO commits VALUES (?,?,?)",
                    (args.run, args.commits, payload(args.run, args.commits)))
        emit({"event": "armed", "pid": os.getpid(), "start_token": start_token, "run": args.run,
              "pending_seq": args.commits, "wal_bytes": wal.stat().st_size,
              "committed_wal_checkpoint": list(checkpoint),
              "pending_frames_on_disk": "not asserted"})
        require(sys.stdin.readline() == "never-resume\n", "fault writer must be killed, not resumed")
        raise RuntimeError("fault writer unexpectedly resumed")
    ordered = sorted(latencies)
    expected = [identity(args.run, seq, value) for seq, value in enumerate(values)]
    checked = verify(con, args.run, expected)
    checkpoint = con.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
    require(checkpoint == (0, 0, 0), f"bounded post-measurement checkpoint failed: {checkpoint}")
    con.close()
    emit({"event": "benchmark", "run": args.run, "commits": args.commits,
          "payload_bytes": len(values[0]), "elapsed_s": elapsed,
          "throughput_commits_s": args.commits / elapsed,
          "commit_ms": {"min": ordered[0], "p50": ordered[math.ceil(len(ordered) * .50) - 1],
                        "p95": ordered[math.ceil(len(ordered) * .95) - 1],
                        "p99": ordered[math.ceil(len(ordered) * .99) - 1], "max": ordered[-1]},
          "commit_samples_ms": latencies, "verification": checked,
          "post_measurement_checkpoint": list(checkpoint)})


def kill_writer(args):
    require(args.writer_pid is not None and args.writer_pid > 1 and args.writer_start,
            "writer PID/start token required")
    # Pin the process before validating it; never signal a recycled numeric PID.
    fd = os.pidfd_open(args.writer_pid)
    try:
        proc = Path("/proc") / str(args.writer_pid)
        require(proc.joinpath("stat").read_text().rsplit(")", 1)[1].split()[19]
                == args.writer_start, "writer start token changed")
        argv = proc.joinpath("cmdline").read_bytes().split(b"\0")
        require(len(argv) > 2 and Path(os.fsdecode(argv[1])).resolve() == Path(__file__).resolve()
                and [b"--op", b"crash-writer"] in [argv[i:i + 2] for i in range(len(argv) - 1)]
                and [b"--run", args.run.encode()] in [argv[i:i + 2] for i in range(len(argv) - 1)],
                "PID is not this experiment's crash writer")
        signal.pidfd_send_signal(fd, signal.SIGKILL)
        emit({"event": "writer_killed", "pid": args.writer_pid, "start_token": args.writer_start})
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--op", required=True,
                        choices=["probe", "denied", "contend", "benchmark", "crash-writer",
                                 "kill-writer", "verify"])
    parser.add_argument("--uid", type=int)
    parser.add_argument("--gid", type=int)
    parser.add_argument("--run")
    parser.add_argument("--commits", type=int, default=100)
    parser.add_argument("--expect-unlocked", action="store_true")
    parser.add_argument("--writer-pid", type=int)
    parser.add_argument("--writer-start")
    args = parser.parse_args()
    require(args.root.is_absolute(), "root must be absolute")
    require(1 <= args.commits <= 1000, "commit bound is 1..1000")
    if args.op in ("benchmark", "crash-writer", "kill-writer", "verify"):
        require(bool(args.run) and len(args.run) <= 128, "bounded run identity required")
    os.umask(0o077)
    if args.op == "denied":
        try:
            list(args.root.iterdir())
        except PermissionError:
            emit({"event": "access_denied", "uid": os.geteuid(), "gid": os.getegid()})
        else:
            raise RuntimeError("unrelated UID could access mode0700 root")
    elif args.op == "probe":
        probe(args)
    elif args.op == "contend":
        contend(args)
    elif args.op == "kill-writer":
        kill_writer(args)
    elif args.op == "verify":
        evidence = json.load(sys.stdin)
        con = connect(args.root)
        emit(verify(con, args.run, evidence["acks"], evidence["pending_seq"]))
        con.close()
    else:
        write_rows(args)


if __name__ == "__main__":
    main()
