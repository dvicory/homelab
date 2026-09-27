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

Devices convert one at a time. A verified seed copy lands on the new disk
while it stays outside the pool; the pool's branch set swaps to the new disk
in one separately approved activation; the old disk stays mounted and
unchanged as the rollback copy until its own conversion is separately
approved.

## Consequences

- The encryption layer's FUSE hop leaves the data path; mergerfs pooling
  remains the only FUSE layer. Filesystem metadata moves inside the encrypted
  boundary.
- Each device is independent: losing one loses only what it holds. This tier
  is deliberately not mirrored.
- Provisioning is an explicit, gated operation separate from routine
  activation; formatting is never an activation side effect.
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
