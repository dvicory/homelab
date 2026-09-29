---
id: ADR-0007
status: accepted
date: 2026-09-27
decision-makers: [Daniel Vicory]
consulted: []
informed: [Homelab operator]
supersedes: []
superseded-by: []
modifies: []
modified-by: []
related-adrs: []
related-specs: [storage-foundations]
related-changes: [storage-placement-contract]
target-architecture: []
---

# Encrypt data disks with block-level containers

## Context

Bulk media devices present encrypted content through a userspace (FUSE)
encryption layer over the disks' clear filesystems, beneath the mergerfs
pool. That arrangement stacks a second FUSE layer in the data path and leaves
filesystem metadata outside the encrypted boundary.

## Decision

Each bulk-media data disk carries a LUKS2 container holding one XFS
filesystem. The filesystem and everything above it see a plain block device,
and key material and the unlock path belong to the device rather than to a
directory tree.

Each disk's filesystem root holds two directories. `pool/` is the only part
that joins a pool. `migration/` is a lossless holding area for content that
has not been classified yet, together with the receipts, evidence, and notes
that record where it came from; it never joins a pool.

Devices convert one at a time. The old disk's content is copied, unchanged
and verified, into the new disk's `migration/` while the new disk stays
outside the pool. Content whose place in the semantic layout is clearly
understood then moves into `pool/` by same-filesystem renames; everything
else stays in `migration/` until someone classifies it. A disk's `pool/`
joins the pool only after that classification and after its content carries
the shared media group and default ACL; disks not yet converted stay mounted
outside the pool. The branch set changes in one separately approved
activation, and the old disk stays mounted and unchanged as the rollback copy
until its own conversion is separately approved.

The reusable tooling covers only disk mechanics: identity, preflight,
container and filesystem creation, copy, verification, and receipts. Old
disks differ in layout, so classifying evacuated content is migration
tooling, scoped to one generation of disks (such as the branches of one old
pool) and removed with it, not a permanent mapping in the reusable tooling.

Discards stay off the encrypted mapping unless a device opts in: spinning
disks gain nothing from them, and they reveal which blocks are free.

## Consequences

- The encryption layer's FUSE hop leaves the data path; mergerfs pooling
  remains the only FUSE layer. Filesystem metadata moves inside the encrypted
  boundary.
- Each device is independent: losing one loses only what it holds. This tier
  is deliberately not mirrored.
- Provisioning is an explicit, gated operation separate from routine
  activation; formatting is never an activation side effect.
- Migration history, such as an old layout's leftovers, stays on the disk in
  `migration/` rather than in the pooled namespace or the tooling.
- The tooling targets XFS only; supporting another filesystem is a separate
  change to the tooling and its declaration.
- Whether the devices later gain a parity or weaving layer, above or below
  the container, remains an open question this decision does not answer.

## Alternatives considered

- Keep or extend the userspace encryption layer. Rejected: it keeps a second
  FUSE layer in the data path and keeps filesystem metadata outside the
  encrypted boundary.
- Re-encrypt the existing devices in place. Rejected: there is no rollback
  copy while the operation runs, and a per-disk verified copy onto new media
  is reversible at every gate.

## Reconsideration triggers

Revisit this decision if a protected or redundant placement for the media
devices is adopted, or if a filesystem-native encryption option becomes the
preferred mechanism for data disks.
