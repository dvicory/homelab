---
id: ADR-0006
status: accepted
date: 2026-09-27
decision-makers: [Daniel Vicory]
consulted: []
informed: [Homelab operator]
supersedes: []
superseded-by: []
modifies: []
modified-by: []
related-adrs: [ADR-0001]
related-specs: [storage-foundations]
related-changes: [storage-placement-contract]
target-architecture: []
---

# Present storage through a stable semantic namespace

## Context

Storage paths are consumed by Nix, application configuration, compute
boundaries, backup policy, and people. When a path encodes physical
placement, changing where data lives becomes a change to every consumer, and
workloads that import by hardlinking or renaming need the ingest and library
trees inside one filesystem, which Linux requires for both operations.

## Decision

Present storage through a stable semantic namespace rooted at `/srv`.
Top-level names describe the kind of data, never its placement or importance.
Physical devices, pools, and tier names stay underneath the namespace.

Each namespace has two levels. The top-level directory (for example
`/srv/media`) is a stable, host-owned attachment point: compute boundaries
attach it once, recursively, and never need to be recreated. The pooled
filesystem mounts one level below it (`/srv/media/data`) and may disappear
and return underneath the attachment, for example when a disk is missing,
without restarting or recreating the guest that consumes it.

Consumers that must link or rename receive one filesystem containing both the
ingest and the library trees. Consumers that only read receive the library
alone. For media this means:

- writers receive `/srv/media/data` as `/data`, holding `downloads/` and
  `library/` side by side;
- the player receives `/srv/media/data/library` read-only.

Consumers get these paths from declared projections rather than rebuilding
them from the parent.

The media library is organized by media class, one directory per class under
`library/`: `movies/` and `tv/` today, and `music/`, `audiobooks/`, and
`books/` when services for them arrive. Ingest lives under `downloads/`, split
by transport (`usenet/{incomplete,complete}`, `torrents/`). Directories for a
class are created when a service needs them, not in advance. Personal photos
are not media: their loss and protection semantics differ from replaceable
movies and shows, so they get their own semantic root (such as
`/srv/photos`), not a directory under the media library.

Branch membership underneath a namespace expresses placement policy. Each
declared backing path carries two independent properties: whether the pool
requires it, and whether it may receive new content. A cold disk can be
required, because its existing library is part of the namespace, and still
receive no new content. Creation is restricted to the branches declared to
accept it, and does not depend on where a file's parent directory already
lives: a new episode of a show held only on a cold branch lands on an
eligible branch.

A physical disk contributes only a dedicated subtree to a pool (`pool/` at
its filesystem root). Anything else on the disk stays outside the namespace.

Access is ordinary Unix group sharing. Each service keeps its own UID; the
stable `media` group (GID 505) is the shared capability from host through
the compute boundary to Kubernetes workloads. Canonical directories are
group rwx and setgid, canonical files group rw, and nothing needs world
access. Canonical shared directories carry a narrow, group-only default
POSIX ACL so new content stays group-writable whatever a writer's umask; it
has no named user or group entries.

## Consequences

- Placement changes — a new device, a removed branch, a moved tier — do not
  touch consumer configuration.
- Losing a pooled filesystem makes its data unavailable without detaching
  anything from the compute guest; the data returns when the pool does.
- Import can link or rename, which requires ingest and library content to
  share one filesystem.
- Moving content between placements must preserve every path that refers to
  the same data; link-unaware tools pointed at the namespace silently
  duplicate data or break links.
- Reported free space reflects where new content can actually be created,
  not total attached capacity.
- Path-preserving creation policies are ruled out, because they would refuse
  new content wherever the parent directory exists only on a no-create
  branch.

## Alternatives considered

- A per-application writable tree plus a separately exported read-only
  library. Rejected: the two are different filesystems, so import cannot
  hardlink or rename a completed download into the library.
- Naming devices or tiers directly in application-visible paths. Rejected:
  every placement change would rewrite every consumer.
- Mounting the pooled filesystem directly at the attachment point. Rejected:
  the attachment would then disappear with the pool, and a guest would need
  to be recreated or restarted to see it return.
- Two independently configured pools over the same branches, one writable
  and one read-only. Rejected: nothing keeps their policies identical, and
  one pool with per-consumer access is what the single-filesystem
  requirement needs anyway.

## Reconsideration triggers

Revisit this decision if consumers stop needing link and rename semantics
within the namespace, or if placement-aware paths become a requirement that a
semantic namespace cannot express.
