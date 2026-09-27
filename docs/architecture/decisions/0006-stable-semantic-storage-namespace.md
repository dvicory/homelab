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

Consumers that must link or rename receive one filesystem containing both the
ingest and the library trees. Consumers that only read receive the library
alone. Branch membership underneath a namespace expresses placement policy:
each declared backing path carries whether it is required and whether it may
receive new content, and creation is restricted to the branches declared to
accept it.

## Consequences

- Placement changes — a new device, a removed branch, a moved tier — do not
  touch consumer configuration.
- Import can link or rename, which requires ingest and library content to
  share one filesystem.
- Moving content between placements must preserve every path that refers to
  the same data; link-unaware tools pointed at the namespace silently
  duplicate data or break links.
- Reported free space reflects where new content can actually be created,
  not total attached capacity.

## Alternatives considered

- A per-application writable tree plus a separately exported read-only
  library. Rejected: the two are different filesystems, so import cannot
  hardlink or rename a completed download into the library.
- Naming devices or tiers directly in application-visible paths. Rejected:
  every placement change would rewrite every consumer.
- Two independently configured pools over the same branches, one writable
  and one read-only. Rejected: nothing keeps their policies identical, and
  one pool with per-consumer access is what the single-filesystem
  requirement needs anyway.

## Reconsideration triggers

Revisit this decision if consumers stop needing link and rename semantics
within the namespace, or if placement-aware paths become a requirement that a
semantic namespace cannot express.
