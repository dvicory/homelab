---
id: ADR-0006
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
  - ADR-0001
  - ADR-0005
  - ADR-0007
related-specs:
  - storage-foundations
  - management-boundaries
related-changes:
  - storage-placement-contract
  - reliable-household-services
  - reproducible-jellyfin-compute
target-architecture:
  - docs/architecture/storage.md
---

# Stable semantic storage namespace with policy-driven physical placement

## Context and Problem Statement

Storage in this fleet is consumed by applications, manifests, backup jobs,
containers, and humans. Every one of those consumers encodes a path. If a path
encodes physical placement or importance, then replacing a disk, adding a tier,
or deciding that a library deserves backups becomes a coordinated change across
all of them.

Media makes the problem concrete. Acquisition services import a completed
download into a library using hardlinks or atomic renames, and players read the
same library. Linux refuses both operations across mount boundaries, so the two
paths have to be one filesystem for those consumers. At the same time the
content should start on fast storage and later rest on large archive devices —
a placement change that must not rename anything an application knows about.

The current implementation does not yet separate the two. Writable media lives
in guest-retained state whose host location is derived inside the compute
guest's state root, while a read-only view of the same devices reaches the guest
through a separate pinned export. A path that consumers should see as one
filesystem is presented as two independent trees, and neither is where the data
should ultimately rest.

The decision question: **should storage paths name the physical placement, and
should each application own its own tree, or should there be one stable
semantic namespace with placement as separate policy?** Related OpenSpec
authority is
[`storage-foundations`](../../../openspec/specs/storage-foundations/spec.md),
which already establishes encrypted-at-rest, persistence, provisioning
separation, and machine ownership of physical storage, and
[`management-boundaries`](../../../openspec/specs/management-boundaries/spec.md),
which keeps physical device lifecycle with the machine that owns it.

## Decision Drivers

- Path churn is expensive. Paths are referenced by Nix, application
  configuration, Kubernetes objects, backup policy and human habit.
- Link and rename semantics are a hard requirement, not a preference, for the
  ingest-to-library workflow.
- Placement must be changeable — fast to archive, one device to another —
  without touching anything a consumer knows.
- Where new content is created, and how much space a writer is told it has, have
  to be policy rather than a side effect of which path a consumer happened to
  be given.
- Ownership has to survive the unprivileged compute boundary and its host to
  guest ID translation, or reconstructed guests will not see their own data.
- Missing backing storage must deny access rather than become a write into an
  empty directory on the root filesystem.
- Ordinary rebuilds must stay non-destructive; provisioning and migration are
  deliberate operator actions.
- Physical storage lifecycle already belongs to the owning machine, and this
  decision should not move it.

## Considered Options

- Stable semantic namespace with policy-driven physical placement.
- Physical or tier-named paths exposed directly to consumers.
- Per-application storage ownership with no shared namespace.
- Status quo: guest-retained writable state plus a separate read-only export.

## Decision Outcome

Chosen option: **Stable semantic namespace with policy-driven physical
placement**, because it is the only option that keeps link semantics correct
while leaving placement free to change, and because the cost of adopting it
grows with the amount of data already placed.

Accepted with one clarification about ownership: service- and
application-owned content is not root-only content. Managing authorization
inside an application decides what its *users* may do; it does not mean the data
should be workable from the host only as root. Managed roots therefore carry
inherited access for the operator and for declared groups, while guests and
workloads still receive only the access they are declared.

The direction is described in [`docs/architecture/storage.md`](../storage.md):
`/srv` is the durable interface; devices, pools, dataset names and tiers stay
beneath it; domain, ownership, durability, placement and confidentiality are
independent policy dimensions that do not appear in path names; and media that
must link or rename is presented to those consumers as one filesystem.

This decision does not choose a filesystem, a mover implementation, a Kubernetes
storage adapter, or a backup engine. Those remain open and are listed in the
target architecture. Encryption layering is a separate decision, recorded in
[ADR-0007](0007-block-level-device-encryption.md).

### Consequences

- Good, because placement, tiering and hardware replacement stop being
  application-visible changes.
- Good, because one ownership model with stable IDs covers shared data, and
  survives guest replacement through the existing ID translation.
- Good, because link-based import becomes reliable by construction rather than
  by accident.
- Bad, because it adds a pooling layer and a mover between applications and
  devices: more components to operate, and more ways for a misconfiguration to
  produce confusing failures.
- Bad, because two-level indirection makes "where does this file actually
  live?" a question requiring tooling rather than a path.
- Neutral, because it leaves encryption, filesystem, redundancy, mover and
  backup choices open.
- Neutral, because it does not change the existing `storage-foundations`
  contract; it adds behavior those requirements did not address.

### Confirmation

Conformance is observable without inspecting module structure:

- Only semantic `/srv/...` paths cross the boundary into application
  configuration, manifests, and service declarations; placement paths appear
  only inside storage modules.
- A consumer that links or renames downloads into a library observes one
  filesystem.
- Rebuilding and activating a host does not change ownership, modes or ACLs of
  existing payload data.
- Removing a required backing mount denies access instead of creating a
  substitute directory.

## Pros and Cons of the Options

### Stable semantic namespace with policy-driven physical placement

- Good, because it decouples the two things that change at completely
  different rates: what data is, and where it happens to live.
- Good, because it lets durability policy change without moving data between
  namespaces — a title can become backed-up in place.
- Neutral, because it requires a small amount of new infrastructure (pooling
  plus a mover) that did not previously exist.
- Bad, because pooled filesystems have genuinely subtle placement, free-space
  and link semantics that must be configured and tested rather than assumed.

### Physical or tier-named paths exposed directly to consumers

- Good, because it is transparent: a path says exactly which device holds the
  data, and no indirection exists to debug.
- Neutral, because it is simple while the device inventory never changes.
- Bad, because every placement change becomes a coordinated change across
  applications, manifests and backup policy.
- Bad, because it forces a placement decision at the moment data is created,
  which is the moment with the least information about its long-term value.

### Per-application storage ownership with no shared namespace

- Good, because each application owns exactly its own tree with no shared
  access model to design.
- Neutral, because it is adequate for applications whose data is never shared
  with another component.
- Bad, because it cannot express the ingest-to-library workflow, where two
  services must link and rename inside what each would consider the other's
  tree.
- Bad, because it duplicates placement, retention and protection policy across
  every application instead of stating it once.

### Status quo: guest-retained writable state plus a separate read-only export

- Good, because it already works for a single player and requires no new
  components today.
- Neutral, because the writable tree is a single real filesystem, so link
  semantics happen to hold within it.
- Bad, because the writable tree is pinned to the compute guest's state root,
  so it cannot rest on the media devices without changing the compute model.
- Bad, because the library a player reads and the library acquisition writes
  are different trees, so nothing keeps them consistent.
- Bad, because it bakes placement into the interface: the same path means
  "guest state on the protected mirror" and cannot mean anything else.

## More Information

### Assumptions

- A single machine owns the physical media lifecycle for now. Shared
  multi-node access to the same media is not a current requirement.
- A FUSE-based pooling layer remains available and adequate for splitting
  ingest from archive placement.
- Link-aware demotion is implementable; it is not yet demonstrated here.
- Consuming applications can be pointed at a semantic path rather than a
  device path.

### Reconsideration Triggers

- A storage weaving, deduplication or distributed layer takes over the pooling
  role, making this indirection redundant or harmful.
- A workload needs the same media mounted on multiple nodes.
- Link-aware movement proves impractical, which would make the ingest/archive
  split incompatible with link-based import.
- Kernel or FUSE behavior makes create placement, free-space reporting, or
  link preservation unreliable for the shapes required.
- Protection requirements demand per-file policy that a pooled namespace
  cannot express.

### References

- Target architecture: [`docs/architecture/storage.md`](../storage.md)
- OpenSpec: [`storage-foundations`](../../../openspec/specs/storage-foundations/spec.md)
- OpenSpec change: `storage-placement-contract`
- Related ADR: [ADR-0001](0001-unprivileged-application-compute.md)
- Related ADR: [ADR-0005](0005-standard-platform-interfaces.md)
