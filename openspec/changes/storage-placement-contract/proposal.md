## Why

Storage paths are consumed by Nix, application configuration, Kubernetes
objects, backup policy and people, but today they encode physical placement:
writable media lives in guest-retained state on the protected mirror, while the
library a player reads arrives through a separate read-only export of the media
devices. Changing where data lives therefore becomes a change to every
consumer, and the ingest-to-library workflow has no single filesystem within
which to link or rename.

This must be settled before library data is imported at scale, because the cost
of changing the namespace grows with the amount of data already placed
underneath it.

## What Changes

- Introduce a stable semantic storage namespace whose paths describe the kind
  of data, not its placement, and keep device, pool and tier names beneath it.
- Require that paths a consumer links or renames between are presented to that
  consumer as one filesystem, and that ingest and library content share that
  property.
- Require new content to be created only on placement branches declared to
  accept it, so that placement policy — not the application — decides where a
  new file lands.
- Require movement between placements to preserve the link relationships the
  data depends on, and to leave the semantic paths usable throughout, with
  temporary duplication permitted.
- Require reported free space to reflect where new content can actually be
  created rather than total attached capacity.
- Require managed roots to carry declared owner, group, and mode. Inherited
  default access is optional policy: a root declares it only when its sharing
  policy requires later content to receive access beyond owner/group/mode.
- Require routine activation to leave existing payload trees alone.
- Require required backing storage to fail closed: an unavailable mount denies
  access rather than exposing a writable empty directory in its place.

## Capabilities

### New Capabilities

- `storage-placement`: the observable contract of the stable storage
  namespace. Covers path stability versus placement, single-filesystem
  presentation for link-dependent consumers, placement-driven creation,
  link-preserving movement, truthful capacity reporting, fail-closed
  attachment, optional inherited-permission policy on managed roots, and
  non-destructive activation.

### Modified Capabilities

None. Existing storage, management, access, and compute contracts remain
unchanged; this proposal adds a distinct `storage-placement` capability for
consumer-visible paths, placement, and attachment behavior.

## Impact

- Host storage declaration: mount definitions, pooling, managed roots and their
  permissions, and failure behavior.
- The compute guest's media attachment and the writable boundary the media
  workloads use.
- Media workload configuration, which currently distinguishes guest-retained
  writable state from a read-only library export.

### Non-goals

- Choosing encryption layering, filesystem types for individual devices, or a
  key hierarchy.
- Changing the redundancy of any existing pool or adding devices.
- Implementing or selecting the placement mover.
- Choosing a Kubernetes storage adapter, or introducing distributed storage for
  bulk media.
- Migrating, classifying or importing existing data.
- Changing `storage-foundations`, `management-boundaries`, or the compute
  isolation decision in ADR-0001.
