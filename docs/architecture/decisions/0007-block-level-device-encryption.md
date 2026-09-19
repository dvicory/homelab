---
id: ADR-0007
status: accepted
date: 2026-09-10
updated: 2026-09-10
decision-makers:
  - Daniel Vicory
consulted: []
informed: []
supersedes: []
superseded-by: []
modifies: []
modified-by: []
related-adrs:
  - ADR-0006
related-specs:
  - storage-foundations
related-changes:
  - storage-placement-contract
target-architecture:
  - docs/architecture/storage.md
---

# Encrypt data devices with block-level containers

## Context and Problem Statement

The media devices currently mount their filesystem in the clear and run a
userspace encryption layer on top of it, which presents an encrypted directory
tree to consumers. That layer is one of two ways this fleet encrypts data
devices, and the devices are about to be reworked anyway: additional capacity is
arriving and existing content has to be relocated.

The layering is expensive to change once devices hold data, because changing it
means decrypting and rewriting everything on the device. The decision therefore
has to be made before the migration rather than discovered during it.

The decision question: **should data devices be encrypted at the block layer, or
by a userspace layer above a plain filesystem?** The related requirement that
persistent data is encrypted at rest is owned by
[`storage-foundations`](../../../openspec/specs/storage-foundations/spec.md);
this decision chooses the mechanism, not the requirement.

## Decision Drivers

- The choice is only cheap while the devices are being re-created anyway.
- Encryption should cover everything written to the device, including the
  filesystem's own metadata, not only the file contents.
- The data path through a pooled media namespace should not carry an avoidable
  userspace layer.
- One mechanism is easier to operate and reason about than two, and block-level
  containers are already how data devices are handled here.
- The unlock path and key handling have to remain operable on a headless host at
  boot and on demand.

## Considered Options

- Block-level container per device, with a plain filesystem above it.
- Userspace encryption layer above a plain filesystem (current).
- Single-device ZFS with native encryption.

## Decision Outcome

Chosen option: **Block-level container per device**, because it protects the
whole device rather than a directory tree inside it, keeps the data path free of
an extra userspace layer, and leaves the fleet with one way of encrypting data
devices instead of two.

Userspace encryption is retired rather than extended. The transition reuses the
spare device: content moves onto it, the vacated device is re-created as an
encrypted container, and the process repeats. Consumer-visible paths do not
change, which is what the storage namespace exists to provide.

This decision does not choose the filesystem above the container, the key
hierarchy, or when the devices unlock. Those remain open in the target
architecture.

### Consequences

- Good, because the encrypted boundary is the device, so filesystem metadata and
  anything the host writes to it are covered.
- Good, because consumers and the pooling layer see ordinary block devices, with
  no second mount and no userspace filesystem in the path.
- Good, because a future data device follows the same pattern regardless of what
  is put on top of it.
- Bad, because the container is opaque: per-dataset features such as quotas,
  snapshots and per-dataset compression are not available from it and would have
  to come from the filesystem above, if at all.
- Bad, because converting existing devices means moving their content off and
  back, which needs spare capacity for the duration.
- Neutral, because the media tier remains unmirrored either way; encryption is
  not protection against device loss.

### Confirmation

- A media device appears as an opened device-mapper container, and its
  filesystem is mounted from that container rather than from the raw device.
- No media filesystem is mounted without its container being opened first; a
  failed unlock denies the mount rather than exposing a plain filesystem.
- No userspace encryption process appears on the media data path.

## Pros and Cons of the Options

### Block-level container per device

- Good, because it protects the entire device, including filesystem structure
  and metadata.
- Good, because key handling and unlocking happen before any filesystem is
  mounted, so a failure to unlock fails closed.
- Neutral, because it needs the key available to the host at mount time, which
  is an operational concern rather than a consumer-visible one.
- Bad, because the host cannot offer per-dataset features inside the container.

### Userspace encryption layer above a plain filesystem

- Good, because encryption can be scoped to individual files and directories
  rather than a whole device, and can be mounted by an unprivileged user.
- Neutral, because it works even where block-level containers are not available.
- Bad, because it leaves the filesystem's own structure and metadata outside the
  encrypted boundary.
- Bad, because it adds a userspace filesystem to the data path and a second
  mount to every consumer of that device.
- Bad, because it keeps a second encryption mechanism alive in the fleet for no
  requirement that the first one fails to meet.

### Single-device ZFS with native encryption

- Good, because encryption, checksums, snapshots and compression arrive
  together, and the fleet already uses ZFS on the protected tiers.
- Neutral, because it would make every media device its own pool, which is
  compatible with the "independent devices" intent of the replaceable tier.
- Bad, because it changes the media filesystem at the same time as the
  encryption layering, coupling two migrations that do not have to happen
  together.
- Bad, because a single-device pool provides no redundancy while adding pool
  management to devices that are expected to be individually replaceable.

## More Information

### Assumptions

- A spare device is available to stage the conversion.
- Content can be relocated without changing any consumer-visible path.
- The media tier does not need the per-file granularity that the userspace layer
  provides.

### Reconsideration Triggers

- A requirement appears for per-file or per-directory encryption granularity on
  these devices.
- A storage weaving or deduplication layer needs to sit below the encryption
  container rather than above it.
- Operational evidence shows the block-level unlock path cannot be made reliable
  on this hardware.

### References

- Target architecture: [`docs/architecture/storage.md`](../storage.md)
- OpenSpec: [`storage-foundations`](../../../openspec/specs/storage-foundations/spec.md)
- Related ADR: [ADR-0006](0006-stable-semantic-storage-namespace.md)
