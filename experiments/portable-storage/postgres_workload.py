#!/usr/bin/env python3
"""Disposable PostgreSQL qualification, not a service/controller or production config.

Run as guest UID 1000, with matching initdb/postgres/pg_ctl/psql/pg_checksums in
--bindir (Alpine 3.23: apk add postgresql18; /usr/libexec/postgresql18).
--root must be a NEW direct child /srv/vfq/pg-NAME for initialize.

  --root /srv/vfq/pg-bind --op initialize
  --root /srv/vfq/pg-bind --op exercise --run baseline --commits 120
  --root /srv/vfq/pg-bind --op crash-writer --run crash --commits 120
  --root /srv/vfq/pg-bind --op verify < external-evidence.json

All operations except crash-writer end with the owned server stopped. The parent
must kill the disposable guest or its exact owned data daemon, not merely psql.
Persist each ack OUTSIDE the guest/data failure domain, fsync it, then send exactly
one newline. Never pipeline handshake newlines. The armed event means a two-row
sentinel transaction is open and uncommitted; kill before the 120-second hold ends.

Verification input (trusted, externally retained JSON):
{"baselines":[{"run":"baseline","commits":120}], "run":"crash",
 "acks":[<exact ack objects>], "pending_seq":-1, "uncertain":null}
Only after a recorded transport error may uncertain instead be
{"run":"crash","seq":NEXT_UNACKED_SEQ,"reason":"transport-error"}.
That permits zero or one exact complete pair, never an arbitrary suffix.
Baselines may be empty. Omit run/acks/pending_seq to verify only baselines.

Two exercise clients each perform <=200 transactions; a third samples atomic
pairs and checkpoints. Defaults take about 30 seconds plus startup/shutdown.
The configuration targets <64 MiB PGDATA, checked after init/checkpoints, not a
hard quota: the parent's real ZFS quota remains authoritative. RAM socket/logs
are /tmp only. No network listener, credentials, service or host configuration.
Offline pg_checksums checks physical page checksums, not all PostgreSQL logical
invariants; exact full-table scans separately check every workload row/payload.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import selectors
import subprocess
import sys
import time
import uuid


LIMIT = 64 * 1024 * 1024
MARKER = "vfq-postgres.json"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def emit(value):
    print(json.dumps(value, sort_keys=True, separators=(",", ":")), flush=True)


def run_name(value):
    require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,64}", value),
            "run must be 1..64 ASCII letters/digits/underscore/hyphen")
    return value


def payload(run, writer, seq, side):
    return hashlib.sha256(f"{run}:{writer}:{seq}:{side}".encode()).hexdigest() * 8


def ack(run, seq):
    return {"event": "ack", "run": run, "seq": seq,
            "sha256": [hashlib.sha256(payload(run, 0, seq, side).encode()).hexdigest()
                       for side in (0, 1)]}


def pair_sql(run, writer, seq):
    values = ",".join(f"('{run}',{writer},{seq},{side},'{payload(run, writer, seq, side)}')"
                      for side in (0, 1))
    return "INSERT INTO pairs VALUES " + values + ";"


def environment():
    result = {key: value for key, value in os.environ.items() if not key.startswith("PG")}
    result.update(LC_ALL="C", PGPASSFILE="/dev/null", PGAPPNAME="vfq-disposable")
    return result


def command(args, tool, *words, timeout=30):
    result = subprocess.run([str(args.bindir / tool), *map(str, words)],
                            env=environment(), text=True, capture_output=True, timeout=timeout)
    require(result.returncode == 0,
            f"{tool} failed ({result.returncode}): {result.stdout}\n{result.stderr}")
    return {"stdout": result.stdout.strip(), "stderr": result.stderr.strip()}


def footprint(root):
    total = 0
    for path in root.rglob("*"):
        require(not path.is_symlink(), f"unexpected PGDATA symlink: {path}")
        try:
            if path.is_file():
                total += path.stat().st_size
        except FileNotFoundError:
            pass  # WAL recycling can race a live sample; final sample is offline.
    require(total <= LIMIT, f"PGDATA exceeds 64 MiB target: {total}")
    return total


def owned_pid(args):
    pidfile = args.root / "postmaster.pid"
    if not pidfile.exists():
        return None
    lines = pidfile.read_text().splitlines()
    require(len(lines) >= 2 and lines[1] == str(args.root), "PID file data directory differs")
    pid = int(lines[0])
    require(pid > 1, "invalid postmaster PID")
    proc = Path("/proc") / str(pid)
    if not proc.exists():
        return None
    argv = proc.joinpath("cmdline").read_bytes().split(b"\0")
    require(proc.stat().st_uid == 1000 and Path(os.fsdecode(argv[0])).name == "postgres",
            "PID file names an unrelated process; refusing pg_ctl")
    require(any(argv[index:index + 2] == [b"-D", os.fsencode(args.root)]
                for index in range(len(argv) - 1)), "postmaster command has different PGDATA")
    return pid


def socket_dir(args):
    path = args.socket
    require(not path.is_symlink(), "socket directory is a symlink")
    path.mkdir(mode=0o700, exist_ok=True)
    require(path.stat().st_uid == 1000 and path.stat().st_mode & 0o777 == 0o700,
            "socket directory must be UID1000/mode0700")


def start(args):
    socket_dir(args)
    if owned_pid(args) is None:
        command(args, "pg_ctl", "-D", args.root, "-l", args.socket / "server.log",
                "-w", "-t", "20", "start", timeout=25)
    pid = owned_pid(args)
    require(pid is not None, "started postmaster identity unavailable")
    return pid


def stop(args):
    require(owned_pid(args) is not None, "cannot stop without known owned postmaster PID")
    command(args, "pg_ctl", "-D", args.root, "-w", "-t", "20", "-m", "fast", "stop",
            timeout=25)
    require(owned_pid(args) is None, "postmaster still present after shutdown")


def offline(args):
    require(owned_pid(args) is None, "offline checksum verification requires stopped cluster")
    result = command(args, "pg_checksums", "--check", "--pgdata", args.root, timeout=30)
    return {"tool": "pg_checksums --check", "exit_status": 0, **result,
            "pgdata_bytes": footprint(args.root)}


class Client:
    """One stock psql process/session; no libpq dependency or database protocol clone."""
    def __init__(self, args):
        self.process = subprocess.Popen(
            [str(args.bindir / "psql"), "-X", "-w", "-qAt", "-F", "\t", "-h",
             str(args.socket), "-p", "55432", "-U", pwd.getpwuid(1000).pw_name,
             "-d", "postgres", "--set", "ON_ERROR_STOP=1", "--pset", "pager=off"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=environment())
        self.buffer = b""
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.number = 0
        self.token = uuid.uuid4().hex
        try:
            settings = self.query("SELECT current_setting('data_directory'),"
                                  "current_setting('fsync'),current_setting('synchronous_commit'),"
                                  "current_setting('full_page_writes'),current_setting('data_checksums'),"
                                  "current_setting('listen_addresses'),pg_backend_pid();")
            require(len(settings) == 1 and settings[0].split("\t")[:6] ==
                    [str(args.root), "on", "on", "on", "on", ""], "unsafe/wrong server settings")
            self.pid = int(settings[0].split("\t")[6])
        except BaseException:
            self.close()
            raise

    def query(self, sql):
        self.number += 1
        marker = f"vfq_{self.token}_{self.number}"
        self.process.stdin.write((sql + "\n\\echo " + marker + "\n").encode())
        self.process.stdin.flush()
        rows = []
        deadline = time.monotonic() + 15
        while True:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                text = line.decode()
                if text == marker:
                    return rows
                rows.append(text)
            remaining = deadline - time.monotonic()
            require(remaining > 0 and self.selector.select(max(0, remaining)),
                    "psql response deadline exceeded")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                self.process.wait(timeout=2)
                raise RuntimeError("psql exited: " + self.process.stderr.read().decode())
            self.buffer += chunk

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.write(b"\\q\n")
                self.process.stdin.flush()
                self.process.wait(timeout=2)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait(timeout=2)
        self.selector.close()
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.close()


def rows(client):
    result = []
    for line in client.query("SELECT run,writer,seq,side,payload FROM pairs "
                             "ORDER BY run,writer,seq,side;"):
        run, writer, seq, side, value = line.split("\t")
        writer, seq, side = int(writer), int(seq), int(side)
        require(value == payload(run, writer, seq, side),
                f"payload mismatch: {run}/{writer}/{seq}/{side}")
        result.append((run, writer, seq, side, value))
    return result


def expected_pair(run, writer, seq):
    return [(run, writer, seq, side, payload(run, writer, seq, side)) for side in (0, 1)]


def initialize(args):
    require(not args.root.exists(), "initialize requires a new, nonexistent dedicated PGDATA")
    args.root.mkdir(mode=0o700)
    command(args, "initdb", "-D", args.root, "--data-checksums", "--wal-segsize=1",
            "--no-locale", "--encoding=UTF8", "--auth-local=trust", "--auth-host=reject",
            "--username", pwd.getpwuid(1000).pw_name)
    config = ("listen_addresses = ''\nport = 55432\n"
              f"unix_socket_directories = '{args.socket}'\nunix_socket_permissions = 0700\n"
              "fsync = on\nsynchronous_commit = on\nfull_page_writes = on\n"
              "shared_buffers = '4MB'\nwal_buffers = '512kB'\n"
              "min_wal_size = '2MB'\nmax_wal_size = '8MB'\n"
              "checkpoint_timeout = '1h'\nmax_connections = 8\n"
              "autovacuum = off\nmax_wal_senders = 0\nmax_replication_slots = 0\n"
              "max_worker_processes = 0\nmax_parallel_workers = 0\n"
              "work_mem = '1MB'\nmaintenance_work_mem = '4MB'\n"
              "temp_file_limit = '4MB'\nlogging_collector = off\n"
              "log_min_messages = warning\nlog_checkpoints = off\n")
    (args.root / "postgresql.conf").write_text(config)
    (args.root / MARKER).write_text(json.dumps({"kind": "vfq-disposable-postgres-v1",
                                               "root": str(args.root), "uid": 1000,
                                               "config_sha256": hashlib.sha256(config.encode()).hexdigest()}))
    for path in (args.root / "postgresql.conf", args.root / MARKER, args.root, args.root.parent):
        fd = os.open(path, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    pid = start(args)
    try:
        with Client(args) as client:
            client.query("CREATE TABLE pairs (run text NOT NULL, writer integer NOT NULL,"
                         " seq integer NOT NULL, side integer NOT NULL CHECK(side IN(0,1)),"
                         " payload text NOT NULL, PRIMARY KEY(run,writer,seq,side)); CHECKPOINT;")
            version = client.query("SELECT version();")[0]
    finally:
        stop(args)
    emit({"event": "initialized", "root": str(args.root), "server_pid": pid,
          "version": version, "offline": offline(args)})


def exercise(args):
    require(args.commits >= 2, "exercise needs later progress from both writers")
    started = time.monotonic()
    start(args)
    clients = []
    try:
        with Client(args) as observer:
            require(rows(observer) == [], "exercise requires an empty workload table")
            for _ in range(2):
                clients.append(Client(args))
            require(len({observer.pid, *(client.pid for client in clients)}) == 3,
                    "exercise clients do not have distinct server backends")

            def writer(index):
                for seq in range(args.commits):
                    require(time.monotonic() - started < 55, "exercise deadline exceeded")
                    clients[index].query("BEGIN;" + pair_sql(args.run, index, seq) + "COMMIT;")
                    time.sleep(args.pause)
                return args.commits

            samples = 0
            checkpoints = []
            peaks = footprint(args.root)
            checkpoint_rows = None
            with ThreadPoolExecutor(max_workers=2) as workers:
                futures = [workers.submit(writer, index) for index in (0, 1)]
                while not all(future.done() for future in futures):
                    observed = rows(observer)
                    for index in (0, 1):
                        subset = [row for row in observed if row[1] == index]
                        require(len(subset) % 2 == 0 and subset ==
                                [row for seq in range(len(subset) // 2)
                                 for row in expected_pair(args.run, index, seq)],
                                "reader observed a partial pair, gap or unrelated row")
                    samples += 1
                    if not checkpoints and all(any(row[1] == index for row in observed)
                                               for index in (0, 1)):
                        observer.query("CHECKPOINT;")
                        checkpoint_rows = [sum(row[1] == index for row in rows(observer))
                                           for index in (0, 1)]
                        require(all(0 < count < 2 * args.commits for count in checkpoint_rows),
                                "checkpoint did not leave work for both writers")
                        checkpoints.append({"during_writes": True,
                                            "rows_per_writer_after": checkpoint_rows})
                        peaks = max(peaks, footprint(args.root))
                    time.sleep(0.1)
                require([future.result() for future in futures] == [args.commits] * 2,
                        "writer transaction totals differ")
            expected = sorted(row for index in (0, 1) for seq in range(args.commits)
                              for row in expected_pair(args.run, index, seq))
            actual = rows(observer)
            require(actual == expected, "exercise final exact rows differ")
            require(samples >= 2 and checkpoint_rows is not None,
                    "no meaningful live-reader/checkpoint observation")
            require(all(sum(row[1] == index for row in actual) > checkpoint_rows[index]
                        for index in (0, 1)), "both writers must advance after the live checkpoint")
            observer.query("CHECKPOINT;")
            peaks = max(peaks, footprint(args.root))
            checkpoints.append({"after_writes": True, "observed_rows": len(actual)})
            evidence = {"event": "exercised", "run": args.run, "commits": args.commits,
                        "writers": 2, "client_backend_pids": [client.pid for client in clients],
                        "reader_backend_pid": observer.pid, "reader_samples": samples,
                        "rows": len(actual), "payload_bytes_per_row": 512,
                        "exact_pairs_and_payloads": True, "checkpoints": checkpoints,
                        "sampled_peak_pgdata_bytes": peaks,
                        "elapsed_s": time.monotonic() - started}
    finally:
        for client in clients:
            client.close()
        stop(args)
    evidence["offline"] = offline(args)
    emit(evidence)


def crash_writer(args):
    pid = start(args)
    with Client(args) as client:
        require(not client.query(f"SELECT 1 FROM pairs WHERE run='{args.run}' LIMIT 1;"),
                "crash run already exists")
        emit({"event": "started", "run": args.run, "writer_pid": os.getpid(),
              "server_pid": pid, "backend_pid": client.pid, "root": str(args.root),
              "commits": args.commits})
        deadline = time.monotonic() + 60
        with selectors.DefaultSelector() as acknowledgments:
            acknowledgments.register(sys.stdin, selectors.EVENT_READ)
            for seq in range(args.commits):
                require(time.monotonic() < deadline, "crash writer deadline exceeded")
                client.query("BEGIN;" + pair_sql(args.run, 0, seq) + "COMMIT;")
                emit(ack(args.run, seq))  # Received only after successful COMMIT.
                require(acknowledgments.select(max(0, deadline - time.monotonic())),
                        "external ACK deadline exceeded")
                require(sys.stdin.readline() == "\n", "external durable ACK handshake lost")
                time.sleep(args.pause)
        client.query("BEGIN;" + pair_sql(args.run, 0, -1))
        # Independent backend must not see the still-open sentinel transaction.
        with Client(args) as observer:
            require(not observer.query(f"SELECT 1 FROM pairs WHERE run='{args.run}' AND seq=-1;"),
                    "uncommitted sentinel is visible")
        emit({"event": "armed", "run": args.run, "pending_seq": -1,
              "server_pid": pid, "writer_pid": os.getpid(), "hold_seconds": 120})
        time.sleep(120)
        raise RuntimeError("fault not injected before armed hold expired; no crash evidence")


def verify(args):
    evidence = json.load(sys.stdin)
    expected = []
    runs = set()
    for baseline in evidence.get("baselines", []):
        run = run_name(baseline["run"])
        count = baseline["commits"]
        require(type(count) is int and 1 <= count <= 200 and run not in runs,
                "invalid/duplicate baseline")
        runs.add(run)
        expected.extend(row for writer in (0, 1) for seq in range(count)
                        for row in expected_pair(run, writer, seq))
    acknowledged = evidence.get("acks", [])
    uncertain = evidence.get("uncertain")
    crash_run = evidence.get("run")
    if crash_run is not None:
        run_name(crash_run)
        require(crash_run not in runs and evidence["pending_seq"] == -1,
                "crash run duplicates baseline or sentinel is unspecified")
        require(len(acknowledged) <= 200, "too many acknowledgements")
        for seq, item in enumerate(acknowledged):
            require(item == ack(crash_run, seq), f"invalid external ACK identity at {seq}")
            expected.extend(expected_pair(crash_run, 0, seq))
        if uncertain is not None:
            require(len(acknowledged) < 200 and uncertain ==
                    {"run": crash_run, "seq": len(acknowledged), "reason": "transport-error"},
                    "only one explicitly recorded transport-uncertain next transaction is permitted")
    else:
        require(not acknowledged and uncertain is None, "ACKs/uncertain transaction lack crash run")
    start(args)  # PostgreSQL's own WAL recovery runs here; never pg_resetwal or checksum disabling.
    try:
        with Client(args) as client:
            actual = rows(client)
            uncertain_present = False
            expected.sort()
            if uncertain is not None:
                extra = expected_pair(crash_run, 0, uncertain["seq"])
                if actual == sorted(expected + extra):
                    uncertain_present = True
                    expected = sorted(expected + extra)
            require(actual == expected, "recovered rows differ: missing ACK, partial pair, sentinel, or unrelated data")
            require(all(row[2] >= 0 for row in actual), "uncommitted sentinel survived recovery")
            client.query("CHECKPOINT;")
            digest = hashlib.sha256(json.dumps(actual, separators=(",", ":")).encode()).hexdigest()
            counts = [{"run": run, "rows": sum(row[0] == run for row in actual)}
                      for run in sorted(runs | ({crash_run} if crash_run is not None else set()))]
    finally:
        stop(args)
    emit({"event": "verified", "rows": len(actual), "pairs": len(actual) // 2,
          "counts": counts, "acknowledged_pairs": len(acknowledged),
          "uncertain_pair_present": uncertain_present, "pending_absent": crash_run is not None,
          "exact_sequences_and_payloads": True, "rows_sha256": digest, "offline": offline(args)})


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--op", required=True, choices=("initialize", "exercise", "crash-writer", "verify"))
    parser.add_argument("--bindir", type=Path, default=Path("/usr/libexec/postgresql18"))
    parser.add_argument("--run")
    parser.add_argument("--commits", type=int, default=120)
    parser.add_argument("--pause", type=float, default=0.25)
    args = parser.parse_args()
    require(os.getuid() == os.geteuid() == 1000, "run all PostgreSQL operations as guest UID1000")
    require(args.root.is_absolute() and args.root.parent == Path("/srv/vfq")
            and re.fullmatch(r"pg-[A-Za-z0-9_-]{1,48}", args.root.name)
            and args.root.resolve() == args.root, "PGDATA must be a nonsymlink direct /srv/vfq/pg-NAME child")
    require(1 <= args.commits <= 200 and 0 <= args.pause <= 0.25,
            "transaction bound 1..200; pause bound 0..0.25 seconds")
    require(args.bindir.is_absolute() and all((args.bindir / tool).is_file()
            and os.access(args.bindir / tool, os.X_OK)
            for tool in ("initdb", "postgres", "pg_ctl", "psql", "pg_checksums")),
            "--bindir must contain matching stock PostgreSQL executables")
    args.socket = Path("/tmp") / ("vfq-pg-1000-" + hashlib.sha256(str(args.root).encode()).hexdigest()[:16])
    os.umask(0o077)
    if args.op in ("exercise", "crash-writer"):
        run_name(args.run)
    if args.op != "initialize":
        require(args.root.is_dir() and args.root.stat().st_uid == 1000
                and args.root.stat().st_mode & 0o777 == 0o700, "PGDATA must be owned UID1000/mode0700")
        marker = json.loads((args.root / MARKER).read_text())
        require(marker == {"kind": "vfq-disposable-postgres-v1", "root": str(args.root), "uid": 1000,
                           "config_sha256": hashlib.sha256((args.root / "postgresql.conf").read_bytes()).hexdigest()},
                "PGDATA qualification marker/configuration mismatch")
        require(not any(line.strip() and not line.lstrip().startswith("#")
                        for line in (args.root / "postgresql.auto.conf").read_text().splitlines()),
                "unexpected ALTER SYSTEM configuration")
        footprint(args.root)
    {"initialize": initialize, "exercise": exercise, "crash-writer": crash_writer, "verify": verify}[args.op](args)


if __name__ == "__main__":
    main()
