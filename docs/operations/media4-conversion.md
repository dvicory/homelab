# Media4 LUKS2/XFS realization

Status: operator-gated procedure and read-only preflight only. No physical
format, mount, copy, mergerfs change, workload validation, media1 deletion, or
media1 formatting has been performed by this change.

Ground truth for this operation: **media4 is empty**. It is the first empty
LUKS2/XFS destination for the new media generation. Existing media1 remains
unchanged, including its gocryptfs ownership, until a later separately approved
media1-format operation. Do not treat media4 as an evacuation source.

The durable storage contract remains unchanged: one LUKS2 container per bulk
media device, XFS above the unlocked mapper, and one shared filesystem containing
`library/` and `downloads/`. Consumers use `/srv/media`; direct placement paths
under `/mnt/storage` are implementation details. Do not introduce another
layout or a migration state machine.

## Tool safety model

`prepare-luks-storage preflight` is read-only. It requires an explicit
`--disk NAME`, resolves the evaluated declared disk to a canonical whole-disk
`/dev/disk/by-id/...` identity, reports serial/WWN and aliases, checks
children/mounts/holders, and probes whole-disk filesystem and partition-table
signatures. It proves that the empty destination is safe to format; it does not
inspect or evacuate media1.

`prepare-luks-storage format` is the existing destructive provisioner. It
requires the evaluated `--declared-device` path and the exact whole-disk
`--confirm-device` path from the latest successful preflight, re-resolves both
and requires them to identify the same current whole disk, then revalidates
identity and emptiness immediately before partitioning. It also requires the
existing agenix key path and `--approve-format`, and never prints key material.

Formatting, mounting, copying, and the mergerfs branch replacement are separate
operator approvals. No marker file authorizes a destructive command. Fresh
identity, emptiness, mapper, UUID, mount, and running-branch evidence must be
reviewed at each irreversible boundary.

## 1. Preflight and confirm empty media4

Obtain the media4 device from evaluated host configuration. Pass the declaration
exactly; do not substitute `/dev/sdX`, a guessed serial, or media1's path.

```sh
prepare-luks-storage preflight \
  --disk media4 \
  --declared-device <DECLARED_DEVICE_FROM_CONFIG>
```

For this empty-destination operation, continue only when the output contains:

- `READ_ONLY_INVENTORY=PASS`;
- `EMPTY=PASS`;
- `FORMAT_READINESS=PASS`; and
- exit status 0.

Record the exact `CONFIRM_DEVICE` (already a full canonical by-id path),
whole-device path, model, size, serial, WWN, WWN/serial aliases, child
inventory, mount inventory, holder inventory, and `wipefs -n`
signature/partition-table result. Any child, mount, holder,
filesystem signature, partition-table signature, ambiguous probe, or failed
probe is a stop condition. Do not reinterpret it as an empty disk and do not
use `wipefs -a` to make the gate pass.

The checked-in host declaration stays `provisioned = false` and retains its
pending state until the full realization and recovery evidence are accepted.

## 2. Separately approved LUKS2/XFS, key, and header steps

Use the existing LUKS2/agenix contract. The recovery passphrase is supplied
interactively. The already-declared `/run/agenix/luks-media4-key` is used only
for the agenix keyslot. If key ownership, recovery escrow, or the runtime key
path is unclear, stop; do not invent another key workflow.

Immediately before formatting, compare the latest preflight identity and
`EMPTY=PASS` output with the physical device. Then approve the LUKS2
format separately:

```sh
prepare-luks-storage format \
  --disk media4 \
  --declared-device <DECLARED_DEVICE_FROM_CONFIG> \
  --confirm-device <CONFIRM_DEVICE_FROM_PREFLIGHT> \
  --mapper <declared-media4-mapper> \
  --key-file /run/agenix/luks-media4-key \
  --approve-format
```

Open the new partition with the recovery passphrase, verify that the mapper has
no filesystem, and create XFS with the declared label:

```sh
cryptsetup open <CONFIRM_DEVICE_FROM_PREFLIGHT>-part1 <declared-media4-mapper>
blkid /dev/mapper/<declared-media4-mapper>   # no existing filesystem expected
mkfs.xfs -L <declared-media4-xfs-label> /dev/mapper/<declared-media4-mapper>
cryptsetup luksAddKey <CONFIRM_DEVICE_FROM_PREFLIGHT>-part1 /run/agenix/luks-media4-key
cryptsetup close <declared-media4-mapper>
```

Test both unlock methods with a close/reopen cycle: the recovery passphrase and
then `cryptsetup open --key-file` with the agenix key. Record LUKS UUID,
filesystem UUID/label, and keyslot roles without recording keys.

After the final keyslot change, create a protected off-host header backup and
verify it in a disposable recovery fixture without restoring it to production:

```sh
cryptsetup luksHeaderBackup <CONFIRM_DEVICE_FROM_PREFLIGHT>-part1 \
  --header-backup-file /protected/off-host/media4-luks-header.img
sha256sum /protected/off-host/media4-luks-header.img
cryptsetup luksDump --header /protected/off-host/media4-luks-header.img \
  <CONFIRM_DEVICE_FROM_PREFLIGHT>-part1
```

Copy the escrow file into the disposable fixture, compare its hash, LUKS UUID,
and keyslot roles with the live header, and test both unlock methods using
`cryptsetup open --header <escrow-copy>` against the intended device. Record the
copied-back proof and protected off-host integrity result. Never place header
backups or plaintext keys in the repository or evidence bundle.

## 3. Mount media4 directly, not as a mergerfs branch

Mount approval is separate from formatting approval. The direct mountpoint must
already exist, be canonical, and be empty. Media4 is **not** in the mergerfs
branch set during this step.

```sh
cryptsetup open --key-file /run/agenix/luks-media4-key \
  <CONFIRM_DEVICE_FROM_PREFLIGHT>-part1 \
  <declared-media4-mapper>
mount -t xfs /dev/mapper/<declared-media4-mapper> /mnt/storage-clear/media4
findmnt -T /mnt/storage-clear/media4   # exact mapper and xfs required
cryptsetup status <declared-media4-mapper>
cryptsetup luksUUID <CONFIRM_DEVICE_FROM_PREFLIGHT>-part1
blkid /dev/mapper/<declared-media4-mapper> # record filesystem UUID/label
```

Verify that the direct mount source, mapper, LUKS UUID, filesystem UUID/label,
and mount options match the realization evidence. Keep media4 out of
`/srv/media/data` while it is being seeded.

## 4. Capacity-check and stage the complete media1 root

Before copying, measure the complete direct media1 source and the direct media4
destination. Include working headroom and do not use the pooled namespace:

```sh
du -sx -B1 /mnt/storage-clear/media1
df -P -B1 /mnt/storage-clear/media4
```

The destination must have enough free capacity for the complete measured source
plus working headroom. At the live preflight, the known legacy source inventory
must be exactly:

```text
/mnt/storage-clear/media1/medialibrary/movies
/mnt/storage-clear/media1/medialibrary/tv
/mnt/storage-clear/media1/medialibrary/downloads
```

If the actual source contains another root or `medialibrary` entry, stop rather
than guessing a mapping. Media4 remains direct and is not a mergerfs branch.
Create one hidden staging tree and copy the complete media1 root in one rsync;
the single invocation preserves hardlinks that cross the legacy subtrees:

```sh
mkdir -p /mnt/storage-clear/media4/.media4-seed
rsync -aHAX --numeric-ids --info=progress2 \
  /mnt/storage-clear/media1/ \
  /mnt/storage-clear/media4/.media4-seed/
```

Inspect the staging root and require only `medialibrary/{movies,tv,downloads}`.
Do not copy through `/srv/media/data`, do not delete source files, and do not
add media4 to the branch set.

## 5. Stop writers, verify, and map the staging tree

Stop every writer that can reach media1 or the shared media namespace. Keep
media4 direct and media1 intact. Verify the complete staging tree while writers
are stopped:

```sh
rsync -aHAXn --checksum --delete --numeric-ids \
  --itemize-changes --out-format='%i %n%L' \
  /mnt/storage-clear/media1/ \
  /mnt/storage-clear/media4/.media4-seed/
```

Require no itemized changes. A successful rsync exit status alone is not proof.
If any difference appears, keep writers stopped and first confirm that the
source inventory is still exactly the three known legacy directories. Confirm
the destination is the exact verified staging directory and not a symlink before
allowing any destination-only deletion:

```sh
test -d /mnt/storage-clear/media4/.media4-seed
test ! -L /mnt/storage-clear/media4/.media4-seed
rsync -aHAX --checksum --numeric-ids --delete --info=progress2 \
  /mnt/storage-clear/media1/ \
  /mnt/storage-clear/media4/.media4-seed/
```

Repeat the dry-run checksum/itemized verification until it is clean. Preserve
the output and compare hardlink groups and metadata as well as file contents.

Only after that verification, move the known legacy directories within the same
XFS filesystem. This is a layout mapping, not a second copy:

```sh
mkdir -p /mnt/storage-clear/media4/library
test ! -e /mnt/storage-clear/media4/library/movies \
  && test ! -e /mnt/storage-clear/media4/library/tv \
  && test ! -e /mnt/storage-clear/media4/downloads
mv -T /mnt/storage-clear/media4/.media4-seed/medialibrary/movies \
  /mnt/storage-clear/media4/library/movies
mv -T /mnt/storage-clear/media4/.media4-seed/medialibrary/tv \
  /mnt/storage-clear/media4/library/tv
mv -T /mnt/storage-clear/media4/.media4-seed/medialibrary/downloads \
  /mnt/storage-clear/media4/downloads
rmdir /mnt/storage-clear/media4/.media4-seed/medialibrary \
  /mnt/storage-clear/media4/.media4-seed
```

Verify each renamed subtree explicitly while media4 is still direct:

```sh
rsync -aHAXn --checksum --delete --numeric-ids --itemize-changes \
  --out-format='%i %n%L' \
  /mnt/storage-clear/media1/medialibrary/movies/ \
  /mnt/storage-clear/media4/library/movies/
rsync -aHAXn --checksum --delete --numeric-ids --itemize-changes \
  --out-format='%i %n%L' \
  /mnt/storage-clear/media1/medialibrary/tv/ \
  /mnt/storage-clear/media4/library/tv/
rsync -aHAXn --checksum --delete --numeric-ids --itemize-changes \
  --out-format='%i %n%L' \
  /mnt/storage-clear/media1/medialibrary/downloads/ \
  /mnt/storage-clear/media4/downloads/
```

Require no itemized output from all three comparisons. Compare whole-tree
hardlink peer groups after normalizing the legacy prefixes:

```sh
python3 - <<'PY'
from collections import defaultdict
from pathlib import Path

source = Path("/mnt/storage-clear/media1/medialibrary")
target = Path("/mnt/storage-clear/media4")
renames = {"movies": Path("library/movies"), "tv": Path("library/tv"), "downloads": Path("downloads")}

def groups(root, normalize):
    by_inode = defaultdict(set)
    for path in root.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        stat = path.stat()
        if stat.st_nlink <= 1:
            continue
        by_inode[(stat.st_dev, stat.st_ino)].add(normalize(path.relative_to(root)))
    return sorted(tuple(sorted(paths)) for paths in by_inode.values())

def source_name(relative):
    first, *rest = relative.parts
    if first not in renames:
        raise SystemExit(f"unrecognized source path: {relative}")
    return str(renames[first].joinpath(*rest))

source_groups = groups(source, source_name)
target_groups = groups(target, lambda relative: str(relative))
if source_groups != target_groups:
    raise SystemExit("hardlink peer groups differ")
PY
```

This compares peer-path groups, not merely link counts. Stop on any mismatch.

Re-verify each mapped source/target subtree with checksum/itemized rsync
comparisons, and compare hardlink groups across the complete target. Require
exactly `library/{movies,tv}` and `downloads/`, with no hidden staging tree or
unrecognized root. Keep media4 out of mergerfs until these mapping and UUID
checks pass.

## 6. Atomically replace media1 with media4 in mergerfs

Only after final verification, perform the separately approved branch change.
Change the desired `/srv/media/data` branch declaration atomically from the
media1 branch to the media4 branch. Never run with both duplicate trees active
in the pool: media4 must be added as media1 is removed in the same declared
branch-set change.

This branch replacement is one separately approved desired-state revision. The
revision changes media4's pending disk declaration to the realized contract and
replaces media1 in the branch list; it does not activate both trees:

```nix
disk.luks-storage.disks.media4 = {
  device = "<CONFIRMED_MEDIA4_PART1_DEVICE>";
  mountpoint = "/mnt/storage-clear/media4";
  fsType = "xfs";
  provisioned = true;
};

services.mergerfs.pools."/srv/media/data".branches = [
  {
    path = "/mnt/storage-clear/media4";
    unit = "mnt-storage\\x2dclear-media4.mount";
    required = true;
    create = true;
  }
  {
    path = "/mnt/storage-clear/media2";
    unit = "gocryptfs-media2.service";
  }
  {
    path = "/mnt/storage-clear/media3";
    unit = "gocryptfs-media3.service";
  }
];
```

Deploy/activate this single revision first so Den owns the XFS mount and the
required mount unit fails closed when media4 is absent. Then perform the
controlled mergerfs restart and inspect the running branch list. The checked-in
declaration remains `provisioned = false` and pending until this later approved
revision; do not apply this block during the current preparation.

Use the established controlled mergerfs restart procedure after all intended
providers are mounted. Do not live-reload the branch list. Before accepting the
change, inspect the *running* branch list and prove:

- media4's direct mount is the replacement branch;
- media1 is absent from the running pool branch set;
- media2 and media3 are unchanged;
- no duplicate media1/media4 trees are active in `/srv/media/data`.

Do not unmount, delete, repartition, or re-encrypt media1 in this operation.
Its gocryptfs ownership and intact data are the rollback source.

## 7. Validate the namespace and workloads

After the controlled restart, recheck the destination mapper, LUKS UUID,
filesystem UUID/label, mount source/type, and branch-to-mount mapping. Validate
`/srv/media/data`, authorized writes, hardlinks/renames where applicable, and
Jellyfin's read-only library view. Validate the media workloads' direct paths
and imports against the one-filesystem `library/` + `downloads/` contract.

If any namespace, identity, branch, UUID, workload, or hardlink check fails
after the swap, roll back by atomically replacing media4 with intact media1 in
the declared/running branch set, then perform the controlled restart and verify
media1 is the sole replacement branch, media2/media3 are unchanged, and no
duplicate trees are active. Do not merely remove media4 and leave the pool
missing a branch. Do not delete data to make a check pass.

## 8. Later media1 retirement is separate

Media1 remains unchanged after this realization and is the rollback copy. A
later operation may receive explicit approval to stop and unmount its gocryptfs
ownership, verify the surviving media4 copy, and format media1 for another
LUKS2/XFS generation step. That later operation is outside this change. There is
no media1 deletion or media1 format command here.

## Negative-path scenarios

Main can exercise these against a disposable fake-command fixture; this change
runs no validation, formatter, build, device, or live-host command:

1. A volatile `/dev/sdX`, noncanonical by-id path, missing serial/WWN, or alias
   resolving to a partition is rejected.
2. Any child, mount, holder, filesystem signature, partition-table signature,
   ambiguous probe, or failed probe keeps `EMPTY`/`FORMAT_READINESS` failed;
   `sgdisk` and `luksFormat` are not reached.
3. A copied or stale identity record cannot authorize formatting; the exact
   by-id path and current serial/WWN are revalidated immediately before it.
4. An existing agenix key path that is unreadable stops before mutation; no
   plaintext fallback or alternate key workflow is accepted.
5. Existing XFS, LUKS, mapper, UUID, or mount mismatches stop realization.
6. Copying from `/srv/media/data`, running media4 as a mergerfs branch during
   seeding, insufficient destination capacity, or any itemized final delta
   stops the operation.
7. A branch replacement that leaves both media1 and media4 active, changes
   media2/media3, or changes the mapper/UUID/branch mapping is rejected.
8. A workload or hardlink/rename validation failure rolls back to intact media1;
   no source deletion is attempted.
9. Any later media1 format/unmount/deletion request is rejected as out of scope
   until separately approved.
10. If the revalidated declaration and confirmation resolve to different whole
    disks, formatting stops before child/signature probes or `sgdisk`; a
    `-part1` declaration is compared through its parent whole disk.

## Disposable fixture commands

```sh
set +e
bash pkgs/by-name/prepare-luks-storage/prepare-luks-storage.sh \
  preflight --disk media4 --declared-device /dev/sdX
[ "$?" -ne 0 ]

bash pkgs/by-name/prepare-luks-storage/prepare-luks-storage.sh \
  format --disk media4 --declared-device /dev/sdX \
  --confirm-device /dev/sdX --mapper crypt-media4 \
  --key-file /run/agenix/luks-media4-key --approve-format
[ "$?" -ne 0 ]
```

A fuller disposable fixture should fake `lsblk`, `findmnt`, `udevadm`, `wipefs`,
`sgdisk`, `cryptsetup`, `blkid`, `mkfs.xfs`, `mount`, `df`, and `rsync`, and
assert that identity, emptiness, signature, capacity, duplicate-branch, and
itemized-difference failures never reach a mutating command.
