## Why

Media paths are consumed by Nix, application configuration, Kubernetes
objects, backup policy and people. If those paths name disks, pools or tiers,
every change to where data lives becomes a change to every consumer, and
import cannot link or rename between download and library paths that sit on
different filesystems.

Legacy media disks are being converted one at a time into independent
LUKS2/XFS disks. Each conversion needs a fixed destination: a stable namespace
that the disk joins without exposing its old layout, and placement rules that
decide where new content lands. The cost of changing that namespace grows with
the amount of data placed underneath it, so it must be settled before bulk
import.

## What Changes

- Keep `/srv/media` as the stable, host-owned attachment boundary that compute
  guests receive, and serve the media namespace at `/srv/media/data` as one
  mergerfs filesystem beneath it. Consumer paths describe the kind of data
  (`library/...`, `downloads/...`), never the disk that holds it.
- Present download and library paths to link-dependent writers as one
  filesystem (`/data`), and give read-only consumers only the library subtree
  (`/media`).
- Declare each placement's `required` and `create` properties independently:
  an unavailable required placement fails closed, and new content lands only
  on placements that accept creation, whichever placement holds the parent
  directory. Reported capacity reflects only creation-eligible placements.
- Split each converted disk into `pool/`, the only part that joins the
  namespace, and `migration/`, which preserves content not yet classified into
  the canonical layout, together with its receipts, outside the namespace.
- Admit legacy disks incrementally: a disk joins only after its canonical
  content has been classified into `pool/` and shared under the media group;
  disks not yet converted stay mounted outside the namespace.
- Keep shared media group-writable: service UIDs stay distinct, the stable
  media group is the capability, and canonical directories carry a narrow
  group-only default ACL.
- Require that movement between placements preserve link relationships. No
  mover is implemented in this change.

## Capabilities

### New Capabilities

- `storage-placement`: the observable contract of the stable media namespace:
  semantic paths, one-filesystem presentation to link-dependent consumers,
  independent required and create placement properties, truthful capacity,
  fail-closed attachment, classified-only visibility, shared-group access,
  link-preserving movement, and non-destructive activation.

### Modified Capabilities

None. Existing storage, management, access, and compute contracts remain as
they are; this change adds the `storage-placement` capability.

## Impact

- Host storage declaration: disk mounts, the mergerfs branch set and its
  options, managed roots and their permissions, and failure behavior.
- The compute guest's `/srv/media` attachment and the `/data` and `/media`
  projections the media workloads use.
- Legacy disk migration, which must deliver each disk into the `pool/` and
  `migration/` layout before it joins.

### Non-goals

- Encryption layering, per-device filesystem choice, and key hierarchy
  (ADR-0007).
- Redundancy, parity, or adding devices.
- Implementing or selecting a placement mover.
- A Kubernetes storage adapter or distributed storage for bulk media.
- Backup, off-host copies, and restore policy, which Preserve owns.
- Personal photos, which stay outside replaceable media.
