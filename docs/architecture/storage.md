# Storage architecture

This document describes where storage is going, not what is deployed today. It
is architectural direction, not a contract. Durable behavior belongs in
OpenSpec, settled choices belong in
[`decisions/`](decisions/), and concrete desired state belongs in Nix.

Where this document explains what storage has to do, it is explaining the
reasoning behind a contract rather than defining one. The normative statement
lives in OpenSpec.

Read the two levels differently:

- **Direction** describes intended structure. Changing it is an architectural
  decision.
- **Not yet decided** lists choices deliberately left open. Anything named
  there is illustrative and can change without an architecture decision.

The originating review is recorded in
[ADR-0006](decisions/0006-stable-semantic-storage-namespace.md).

## What storage has to provide

- **Stable names.** Paths referenced by Nix, applications, backup jobs and
  humans outlive the hardware underneath them.
- **Separable policy.** What data *is*, who owns it, how much it matters,
  where it lives, and who can read it are independent questions.
- **Correct link semantics.** Downloads and libraries that rely on hardlinks or
  atomic renames share one filesystem.
- **Fail-closed behavior.** Missing backing storage denies access. It never
  becomes a write into an empty directory.
- **Non-destructive activation.** Routine rebuilds create and mount. They do
  not repartition, migrate, or rewrite ownership of large data trees.

## The stable namespace: `/srv`

`/srv` is the durable interface. Physical devices, pools, dataset names, and
tier names stay underneath it.

```text
/srv/
├── media/
│   ├── library/          # long-term media, read-only to players
│   └── downloads/        # ingest staging, writable by acquisition services
├── photos/
│   ├── library/          # application-managed photo library
│   └── import/           # controlled imports of external collections
├── footage/
│   ├── users/<user>/
│   │   ├── inbox/        # new source material, safe to drop into
│   │   └── projects/     # editing sources and projects
│   └── shared/
├── files/
│   ├── users/<user>/
│   │   └── inbox/        # unclassified data, safe to drop into
│   └── shared/           # family and household shares
├── documents/
│   ├── library/          # records managed by a document workflow
│   └── inbox/            # scanner and drop target
├── surveillance/
└── backups/
    └── devices/<user>/<device>/
```

Naming rules:

- Top-level names describe the *kind of data*, never its placement or
  importance. `/srv/ssd`, `/srv/hdd`, `/srv/important` are wrong.
- Each user gets an `inbox` so unclassified data has a safe home and does not
  force a taxonomy decision at import time.
- A domain gets a path when it has durable content. Empty scaffolding for
  future domains is not created ahead of need.

Not every domain is implemented. `media` and `photos` are the near-term
concerns; `footage`, `files`, `documents`, `surveillance` and `backups/devices`
reserve the name and the ownership model without committing implementation.

## Policy dimensions

Each storage root answers five separable questions:

| Dimension | Question | Examples |
| --- | --- | --- |
| Domain | What kind of data is this? | media, photos, footage, documents |
| Ownership | Who is authoritative? | filesystem user, shared group, application, service |
| Durability | How much does loss hurt? | ephemeral, replaceable, protected, critical |
| Placement | Where does it live? | protected mirror, hot removable, bulk archive |
| Confidentiality | Who can read it? | server-encrypted, client-sealed |

Do not collapse these into the path. A path says *what something is*; the
other four dimensions are policy that can change independently.

## Ownership models

**Filesystem-human-owned.** The user or a small number of durable groups own
the data, and POSIX permissions and inherited ACLs carry the access model.
Applies to `/srv/files`, `/srv/footage`, and parts of `/srv/backups`.

**Application-owned human data.** The service account owns the bytes and the
application enforces human authorization. Applies to `/srv/photos/library` and
`/srv/documents/library`. Filesystem ACLs must not try to mirror the
application's own sharing model.

**Service-owned.** A service account and group own the data, with narrowly
scoped mounts for consumers. Applies to `/srv/media` and `/srv/surveillance`.
Players get read-only views; only acquisition services get a writable one.

**Client-sealed.** Selected user data may be encrypted before it reaches the
server, so host root cannot read it. This is a confidentiality property, not a
separate tier or a top-level namespace.

All four models carry inherited access entries, including the ones where the
application owns the bytes. Application ownership governs authorization for
human users *inside* the application; it is not a claim that the data should be
workable from the host only as root.

Access decomposes into three axes that one group cannot answer together:

- **Ownership** — whose data this is: a person, or a service identity. Decided
  by the root's owner, not by a group.
- **Sharing** — which other people may reach it. Expressed by a group per real
  sharing boundary. A group with one member adds a name, not access, so these
  appear when a second person actually needs the data.
- **Administration** — who may inspect and repair it from the host. Expressed by
  inherited access entries naming the administrative group.

The three compose: content can be owned by one person, shared with a group, and
administrable by another.

Media is the clearest administration case. It is service-owned for writes, and
it still has to be manageable from the host — inspecting it, fixing a bad
import, moving something by hand — without becoming root and without going
through the service.

Concretely, managed roots declare a default access entry for the operator group
so that content created later inherits it. The declared entries use the
identifiers the host actually observes; for content written by a workload
inside the compute boundary that is the translated identifier of the workload's
identity, not its number inside the guest. Applying inherited access to content
that already exists is a deliberate one-time migration, not something routine
activation does.

Access decisions must resolve to stable numeric IDs, because the compute
boundary translates between host and guest IDs. Group names and their IDs come
from the fleet group registry; a host does not invent its own.

## Durability classes

| Class | Meaning | Typical handling |
| --- | --- | --- |
| Ephemeral | Safe to lose immediately | No redundancy, no snapshots, no backup |
| Replaceable | Reacquirable or regenerable | Redundancy optional, little or no snapshotting |
| Protected | Human-created or otherwise meaningful | Local redundancy where practical, snapshots, off-host copy |
| Critical | High-value data with real recovery requirements | Redundancy, longer history, application-aware capture |

Durability is a property of the data, not of where it currently sits. A
hard-to-reacquire title can be promoted into a backed-up policy without its
`/srv/media/...` path changing.

## Physical tiers

Placement determines how a root is stored. Tier names describe physical
reality and stay out of application-visible paths.

- **Protected fast tier.** A redundant pool backing host state, application
  state, and small high-value data. This is the root pool. It sets — among other
  properties — a ZFS-native encryption root, POSIX ACLs, and `xattr=sa`; the
  pool declaration is authoritative for the full set. Two 1 TB NVMe devices are
  installed and this tier is meant to be a mirror of them. Today the pool is
  declared from one device, the host schema exposes only a single root-pool
  device, and the second device is in use elsewhere, so the mirror needs a
  device migration and a schema change before it is real.
- **Protected bulk tier.** A redundant pool for photos, documents, user files,
  and footage. It will use the two 8 TB devices that are not attached yet, and
  no pool or mount is configured for it.
- **Replaceable media tier.** Individually mounted 12 TB devices carrying the
  media archive: movies, television, and the ingest path that feeds them. Each
  device is independent, so losing one loses only what it holds. Today three of
  them are aggregated into the media namespace and a fourth is attached and
  waiting to be used for the encryption transition described below. Media is
  largely reacquirable, which is why this tier is not mirrored.

There is no fast ingest tier. New media is created directly on the media tier,
and the namespace is structured so that adding a fast ingest placement later
does not change any consumer-visible path.

Replaceable tiers deliberately avoid spending capacity on redundancy for data
that can be reacquired. Protected tiers deliberately avoid silently degrading
to unmirrored placement when full: capacity pressure must be visible.

## Encryption

Data devices are encrypted with a block-level container per device. The
filesystem and everything above it see a plain block device, and the key
material and unlock path belong to the device rather than to a directory tree.

This replaces the current arrangement, where a media filesystem is mounted in
the clear and a userspace layer presents an encrypted tree on top of it. The
userspace layer is being retired rather than extended: it duplicates a concern
the block layer already covers on other devices, it puts a FUSE layer on the
data path, and it leaves the filesystem's own metadata outside the encrypted
boundary. The decision and its alternatives are recorded in
[ADR-0007](decisions/0007-block-level-device-encryption.md).

The transition uses the spare 12 TB device: content moves onto it, the vacated
device is re-created as an encrypted container, and the process repeats until
the tier is converted. No media path changes during this, which is the property
the namespace exists to provide.

## Media: one filesystem for ingest and library

Media is the case that constrains the design, so it is stated explicitly.

`/srv/media` is presented to consumers as **one filesystem** containing both
`library/` and `downloads/`. The host mounts it as well: operators and
workloads consume the same paths, and `/mnt/storage` stays implementation
detail. This is not cosmetic. Acquisition services import
a completed download into the library using hardlinks or atomic renames, and
Linux refuses both across mount boundaries even when the two mounts come from
the same underlying device. A consumer that must link or rename receives the
common parent; a consumer that only plays media receives `library/` read-only.

Underneath, branches correspond to placements. More than one is possible, and
the namespace is built for it: creation is restricted to placements declared to
accept new content, archive placements stay fully usable for what they already
hold, and a separate mover — not an application — decides when content moves
between them.

Today media has one placement, so creation restriction and movement are not yet
exercised. They become real when a second placement is added, and adding one
changes no consumer-visible path.

The mover is a storage component rather than an application behavior. The
contract requires a placement move to preserve every path that refers to the
same data and to keep the namespace usable while it happens; temporary
duplication is acceptable, silently broken links are not.

The contract requires reported capacity to reflect where new content can
actually be created rather than the sum of attached capacity. Reporting the
larger number lets acquisition services keep accepting work they cannot place.

Consequences to keep in view:

- Hardlinks are only possible when the destination directory and the source
  file are on the same underlying placement. Import spread across placements
  cannot link, which is why creation is restricted rather than free.
- Tools that do not understand link relationships will silently duplicate data
  or break links if they are pointed at the media tree.
- Torrent payload stays in use while it seeds, so demotion has to keep the
  seeding paths valid rather than retiring the old location immediately.

## Application state, cache, and scratch

Application state stays at conventional service locations such as
`/var/lib/<service>`, and is backed by the tier its durability class requires.
Cache is regenerable and belongs under `/var/cache` or the application's own
cache location. Transcode and other scratch output is ephemeral.

A single application may therefore use several tiers at once — for example
state on the protected mirror, originals on protected bulk storage, and
transcodes on disposable fast storage — without any of those tier names
appearing in its configuration.

## Container and Kubernetes consumption

Workloads consume semantic paths, not device or tier names. Which of bind
mounts, host-backed volumes, or a provisioner backs a path is an implementation
decision; the following hold regardless:

- Consumers that must link or rename see one filesystem for `downloads/` and
  `library/` together.
- Access identity survives host-to-guest ID translation, so on-disk ownership
  is stable across guest replacement.
- Persistent volume lifecycle stays independent of application deployment
  lifecycle. A redeploy must not delete or reinitialize application data.
- Bulk media does not require distributed storage. Node locality is preferred
  over introducing a distributed filesystem to make the storage layer look
  uniform.

## Protection

The namespace and the backup boundary are different things. Snapshot and
replication policy follows durability class and dataset boundary, not path
depth:

- media is largely replaceable and normally has no full off-host copy, though
  individually promoted titles may;
- photos and documents carry independent snapshot and replication policy;
- application state may be captured with application-aware tooling on a
  different schedule than its bulk content;
- surveillance uses time-based retention.

Snapshots on the same pool are not a backup: host root can destroy them. Data
in the `critical` class needs a protection path with a separate trust boundary.

## Failure behaviour

The contract requires required storage to fail closed, and requires storage
used by one workload not to gate unrelated operation. What that implies here:

- An absent backing location must not behave like an empty writable directory
  that accepts writes.
- A service whose durable state is unavailable must not start against an empty
  substitute directory.
- Degraded operation may be acceptable for archive placements, but it is an
  explicit choice rather than an accident of mount ordering.
- Storage health — pool state, tier pressure, mover backlog, snapshot and
  backup freshness, failed locations — is worth exposing.

## What Nix owns

Nix owns the durable contract: storage inventory and its mapping to stable
device identifiers, encryption and unlock configuration, pool and dataset
intent with their properties, mounts and their ordering and failure behavior,
service users and groups with stable IDs, managed root directories with
inherited default permissions, application-to-storage mappings, and the
policies for snapshot, scrub, and backup.

Nix does **not** own the contents of those roots. Activation creates managed
roots and applies default permissions so that new files inherit them. It does
not recursively rewrite ownership, modes, or ACLs across existing payload
trees; that is a migration or repair action that an operator runs deliberately.

Establishing an on-disk format or an encryption container is likewise an
explicit provisioning action, separate from ordinary activation.

## Not yet decided

These are open. Implementation must not quietly settle them.

1. **Filesystem on the encrypted media devices.** The declared device uses
   btrfs. The choice is only worth revisiting if a concrete requirement appears;
   single-device filesystems on this tier are not mirrored, so the filesystem
   does not need to provide redundancy.
2. **Whether the media devices gain any parity or weaving protection layer**
   later, and if so whether that sits above or below the encryption container.
   The current direction assumes none.
3. **Key hierarchy and unlock timing for the media containers**, including where
   unlock material lives relative to the existing boot-unlock path, and whether
   these devices unlock at boot or on demand.
4. **Whether a fast ingest placement is added** for the media namespace. Nothing
   currently depends on one, and the namespace is designed so that adding one
   changes no consumer-visible path.
5. **How the host schema expresses a multi-device root pool.** The mirror is
   decided, but the schema currently exposes a single root-pool device.
6. **Dataset boundaries for application-owned human data** once each
   application's durable and regenerable files are known.
7. **The mover's implementation** and its coordination protocol with
   acquisition services.
8. **Placement watermarks** and the free-space reserve that keeps ingest from
   failing.
9. **Backup engine and off-host retention model.**
10. **How guests present their own Nix store.** It is deliberately independent
    of this namespace, and whether it shares the physical devices with this
    namespace is part of that open question.
11. **Surveillance placement and retention**, once that workload exists.

## References

- [ADR-0006](decisions/0006-stable-semantic-storage-namespace.md) — the decision
  behind this direction and the options rejected.
- [ADR-0007](decisions/0007-block-level-device-encryption.md) — the decision to
  encrypt data devices with block-level containers instead of a userspace layer.
- [`storage-foundations`](../../openspec/specs/storage-foundations/spec.md) —
  current authority for encryption, persistence, and provisioning of storage.
- [`management-boundaries`](../../openspec/specs/management-boundaries/spec.md) —
  ownership boundary this document stays inside.
- [ADR-0001](decisions/0001-unprivileged-application-compute.md) — the compute
  boundary whose host-to-guest ID translation the ownership models must respect.
