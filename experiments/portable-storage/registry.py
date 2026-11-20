#!/usr/bin/env python3
"""Throwaway policy: PVC namespace/name is logical ownership; UID is incarnation.

State: explicit empty-root bootstrap creates READY. Unseen PVC intent commits a
PENDING reservation, exclusive mkdir then inode commit makes it ACTIVE. Identical
UID retries validate; pending+missing path retries; pending+existing path refuses
ambiguous import. History survives claim deletion. New UID requires independent
writer exclusion, explicit adoption and native PV/PVC binding. No automatic repair.

SQLite FULL transactions serialize metadata; mkdir is not atomic with SQLite,
hence the fail-closed pending window. Flat allocation syncs its known parent root.
This covers guest/process interruption, not host-power durability qualification.
Backup uses SQLite backup plus quiesced payload, restored with callers excluded.
Missing/corrupt history never auto-bootstraps. Coherent history+data rollback needs
an independent inventory and deliberate recovery; erased history is not inferable.
SQLite/journals live only in .registry; the checker mounts only that metadata.
Stock local-path leaves pvc-UID_namespace_name encode native PVC intent, without
a custom pathPattern, annotation, helper mount or unsafe-template opt-in.

Directory inode checks detect ordinary substitution on one filesystem, not file
loss, inode reuse, forgery or every remount's inode semantics. No marker/anchor,
controller, generation protocol, continuous guard or writer fencing is provided.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sqlite3
import ssl
import sys
import urllib.request
from urllib.parse import quote


class Denied(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Denied(message)


def directory(path):
    require(not path.is_symlink() and path.is_dir(), f"missing/replaced directory: {path}")
    return path.stat()


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def connect(metadata, readonly=False):
    directory(metadata)
    db = metadata / "ownership.sqlite"
    require(db.is_file() and not db.is_symlink(), "registry absent; restore history, never auto-bootstrap")
    con = sqlite3.connect(f"file:{quote(str(db))}?mode={'ro' if readonly else 'rw'}", uri=True, timeout=5)
    con.execute("PRAGMA synchronous=FULL")
    require(con.execute("PRAGMA integrity_check").fetchone() == ("ok",), "registry corrupt")
    require(con.execute("SELECT version FROM metadata").fetchall() == [(1,)], "registry version invalid")
    return con


def bootstrap(root):
    directory(root)
    require(not any(root.iterdir()), "bootstrap requires explicitly approved empty root")
    metadata = root / ".registry"
    metadata.mkdir(mode=0o700)
    fd = os.open(metadata / "ownership.sqlite", os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    con = sqlite3.connect(metadata / "ownership.sqlite")
    con.executescript("""
        PRAGMA synchronous=FULL;
        BEGIN;
        CREATE TABLE metadata(version INTEGER NOT NULL);
        INSERT INTO metadata VALUES(1);
        CREATE TABLE allocations(
          owner TEXT PRIMARY KEY, uid TEXT NOT NULL, path TEXT NOT NULL UNIQUE,
          inode INTEGER, state TEXT NOT NULL);
        CREATE TABLE history(
          seq INTEGER PRIMARY KEY, owner TEXT NOT NULL, old_uid TEXT,
          new_uid TEXT NOT NULL, action TEXT NOT NULL, approved TEXT);
        COMMIT;
    """)
    con.close()
    sync_directory(metadata)
    sync_directory(root)


def intent(root, path):
    require(path.is_absolute() and root.is_absolute(), "absolute paths required")
    require(path == Path(os.path.normpath(path)), "noncanonical allocation path")
    parts = path.relative_to(root).parts
    require(len(parts) == 1, "stock helper must mount the whole root with one flat payload leaf")
    components = parts[0].split("_")
    require(len(components) == 3 and components[0].startswith("pvc-"), "expected stock pvc-UID_namespace_name")
    uid, namespace, name = components[0][4:], components[1], components[2]
    require(all(re.fullmatch(r"[a-z0-9][a-z0-9.-]*", x) for x in (uid, namespace, name)), "unsafe PVC metadata")
    return f"{namespace}/{name}", uid


def validate(root, row, mounted=None):
    path = Path(row[2]) if mounted is None else mounted
    st = directory(path)
    require(row[4] == "active", "allocation incomplete; explicit repair required")
    require(st.st_dev == directory(root).st_dev and st.st_ino == row[3], "payload directory replaced")


def allocate(root, path, fail_after=None):
    owner, uid = intent(root, path)
    directory(root)
    con = connect(root / ".registry")
    try:
        # ponytail: one SQLite writer; enough for a bounded single-node experiment.
        con.execute("BEGIN IMMEDIATE")
        rows = con.execute("SELECT * FROM allocations WHERE owner=? OR path=?", (owner, str(path))).fetchall()
        if rows:
            row = rows[0]
            require(len(rows) == 1 and row[:3] == (owner, uid, str(path)), "ownership collision or new PVC UID: explicit adoption required")
            if row[4] == "active":
                validate(root, row)
                con.commit()
                return
            require(not path.exists(), "ambiguous pending directory; explicit repair required")
        else:
            require(not path.exists(), "unregistered path exists; no automatic import")
            con.execute("INSERT INTO allocations VALUES(?,?,?,NULL,'pending')", (owner, uid, str(path)))
            con.execute("INSERT INTO history(owner,new_uid,action) VALUES(?,?,'reserve')", (owner, uid))
        con.commit()
        if fail_after == "reserve":
            os._exit(71)  # Experiment-only abrupt process exit, no finally cleanup.
        con.execute("BEGIN IMMEDIATE")
        row = con.execute("SELECT * FROM allocations WHERE owner=?", (owner,)).fetchone()
        if row[4] == "active":
            validate(root, row)
            con.commit()
            return
        path.mkdir(mode=0o700)
        path.chmod(0o777)  # Preserve stock LPP leaf permissions; metadata stays 0700.
        sync_directory(path.parent)
        if fail_after == "mkdir":
            os._exit(71)  # Leave SQLite rollback and directory ambiguity to recovery.
        con.execute("UPDATE allocations SET inode=?,state='active' WHERE owner=?", (directory(path).st_ino, owner))
        con.execute("INSERT INTO history(owner,new_uid,action) VALUES(?,?,'activate')", (owner, uid))
        con.commit()
    finally:
        con.close()


def check(root, owner, uid, mounted):
    con = connect(root, readonly=True)
    try:
        row = con.execute("SELECT * FROM allocations WHERE owner=?", (owner,)).fetchone()
        require(row is not None and row[1] == uid, "unapproved PVC ownership")
        validate(root, row, mounted)
    finally:
        con.close()


def adopt(root, pvc, old_uid, approval):
    meta = pvc["metadata"]
    owner, uid = f'{meta["namespace"]}/{meta["name"]}', meta["uid"]
    require(bool(approval.strip()), "explicit operator approval required")
    con = connect(root / ".registry")
    try:
        con.execute("BEGIN IMMEDIATE")
        row = con.execute("SELECT * FROM allocations WHERE owner=?", (owner,)).fetchone()
        require(row is not None, "no established matching owner")
        require(row[1] in (old_uid, uid), "stale approval UID")
        validate(root, row)
        if row[1] != uid:
            con.execute("UPDATE allocations SET uid=? WHERE owner=?", (uid, owner))
            con.execute("INSERT INTO history(owner,old_uid,new_uid,action,approved) VALUES(?,?,?,'adopt',?)", (owner, old_uid, uid, approval))
        con.commit()
        print(json.dumps({"owner": owner, "uid": uid, "path": row[2], "inode": row[3]}))
    finally:
        con.close()


def podcheck(root):
    """All PVC-backed Pods classify from API metadata, never Pod labels."""
    namespace = os.environ["POD_NAMESPACE"]
    token = Path("/identity/token").read_text()
    context = ssl.create_default_context(cafile="/identity/ca.crt")
    server = f'https://{os.environ["KUBERNETES_SERVICE_HOST"]}:{os.environ["KUBERNETES_SERVICE_PORT_HTTPS"]}'
    for reference in os.environ["CLAIMS"].split(","):
        volume, name = reference.split(":")
        request = urllib.request.Request(
            f"{server}/api/v1/namespaces/{namespace}/persistentvolumeclaims/{name}",
            headers={"Authorization": f"Bearer {token}"},
        )
        with urllib.request.urlopen(request, context=context, timeout=10) as response:
            pvc = json.load(response)
        storage_class = pvc["spec"]["storageClassName"]
        if storage_class == "psx-delete":
            con = connect(root, readonly=True)
            try:
                require(con.execute("SELECT 1 FROM allocations WHERE owner=?", (f"{namespace}/{name}",)).fetchone() is None,
                        "retained owner cannot bypass adoption by changing to disposable class")
            finally:
                con.close()
            continue
        require(storage_class == "psx-policy-retain", f"unrecognized class: {storage_class}")
        require(pvc.get("status", {}).get("phase") == "Bound", "claim not bound")
        check(root, f'{namespace}/{pvc["metadata"]["name"]}', pvc["metadata"]["uid"], Path("/claims") / volume)
    print(f"CHECKED_BEFORE_APPLICATION_INIT uid={os.getuid()} gid={os.getgid()}", flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", type=Path, required=True)
    sub = p.add_subparsers(dest="operation", required=True)
    sub.add_parser("bootstrap")
    setup = sub.add_parser("setup")
    setup.add_argument("--path", type=Path, default=os.environ.get("VOL_DIR"))
    setup.add_argument("--fail-after", choices=("reserve", "mkdir"))
    guard = sub.add_parser("check")
    guard.add_argument("--owner", required=True)
    guard.add_argument("--uid", required=True)
    guard.add_argument("--mounted", type=Path, required=True)
    approval = sub.add_parser("adopt", help="PVC JSON stdin; caller MUST independently fence old writers")
    approval.add_argument("--old-uid", required=True)
    approval.add_argument("--approval", required=True)
    sub.add_parser("inspect")
    sub.add_parser("podcheck")
    args = p.parse_args()
    try:
        if args.operation == "bootstrap":
            bootstrap(args.root)
        elif args.operation == "setup":
            require(args.path is not None, "VOL_DIR or --path required")
            allocate(args.root, args.path, args.fail_after)
        elif args.operation == "check":
            check(args.root, args.owner, args.uid, args.mounted)
        elif args.operation == "adopt":
            adopt(args.root, json.load(sys.stdin), args.old_uid, args.approval)
        elif args.operation == "podcheck":
            podcheck(args.root)
        else:
            con = connect(args.root / ".registry", readonly=True)
            print(json.dumps({t: con.execute(f"SELECT * FROM {t}").fetchall() for t in ("allocations", "history")}))
            con.close()
    except (Denied, OSError, ValueError, sqlite3.Error, KeyError) as e:
        print(f"DENIED: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
