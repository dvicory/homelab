## Context

This section records only the current state and constraints that shape the approach.

Evidence from the current repository:

- The root pool is created from a single declared device and already carries
  `encryption=on`, `acltype=posixacl`, `xattr=sa`, `atime=off` and a
  `canmount=off` root. Impermanence rolls back to a blank snapshot of the root
  dataset, and that rollback runs from the initrd only when the initrd is
  systemd-based and the blank snapshot exists. `/persist` is `neededForBoot`.
  Any storage root that must survive a rollback has to be declared as
  persistent; nothing under `/` qualifies.
- Current media branches mount individually; production uses gocryptfs over plain
  filesystems and one mergerfs namespace at `/srv/media`. The namespace
  aggregates the clear views and is the host-owned media boundary. Changing the
  provider or encryption layer is outside this contract.
- Acquisition workloads attach that namespace at `/data`, while Jellyfin
  attaches only `/srv/media/library` at `/media` read-only. Private application
  state remains in separately declared retained paths.

## Goals / Non-Goals

**Goals:**

- One declared namespace contract that consumers reference, with placement,
  ownership and durability expressed as separate policy.
- A media layout in which link-dependent consumers see one filesystem while
  read-only consumers see only the library.
- Attachment that fails closed when a required branch is missing, for the
  writable namespace as well as the read-only one.
- A writable media boundary that is host-owned rather than guest-retained, so
  that it can rest on the media devices and survive guest replacement.
- Managed roots whose ownership is declared once may also declare optional
  inherited permissions policy; routine activation leaves both untouched.

**Non-Goals:**

- Choosing encryption layering, filesystem types, redundancy, or a key
  hierarchy. Those stay open in
  [`docs/architecture/storage.md`](../../../docs/architecture/storage.md) and
  this change must work with whatever is currently configured.
- Implementing or selecting the placement mover. This change fixes the
  contract the mover must satisfy; the mover itself remains open.
- Choosing a Kubernetes storage adapter or introducing distributed storage.
- Migrating, classifying, or importing existing content.

## Decisions

### Declare host-owned semantic roots separately from compute-retained state

Compute-retained paths are host directories whose location is derived from the
compute state root and whose ownership is translated into the guest ID range.
That is the right model for state a guest owns, and the wrong model for a
host-owned storage namespace that several hosts and guests may consume, that
must sit on specific devices, and whose ownership is a host-visible service
identity.

Introduce a separate declaration for host-owned semantic roots, carrying the
path, owning user and group, mode, optional default access entries, and mount
failures that must deny access.

*Alternatives considered:* widening the existing retained-path declaration to
accept an arbitrary host path. Rejected: it would erase the difference between
guest-translated state and host-owned data, and would let a guest-facing
declaration place content anywhere on the host. Naming devices directly in
application configuration is not part of this proposal; the alternatives are
recorded in the proposed ADR-0006.

### The writable media boundary is the namespace, not a per-application tree

Acquisition services and the player consume the same host-owned namespace with
different access: writers receive the common parent because they link into the
library, and the player receives the library read-only. This is the selected
boundary and removes the former split between a guest-retained writable tree
and an unrelated read-only export.

*Alternatives considered:* keeping a per-application writable tree and
exporting the library separately (the status quo) — it cannot express the link
that import depends on. Giving the player the whole namespace read-only was also
rejected: it would let it see in-progress downloads.

The writable media boundary is the host-owned namespace. Repointing acquisition
consumers does not change the current media provider or physical disks.

### One pooling instance per namespace

Two pooling instances over the same branches give each its own creation policy,
free-space reporting, and failure behavior. The read-only export becomes a view
of the shared namespace — the same filesystem, presented read-only — rather than
a second, independently configured pool.

*Alternatives considered:* keeping both pools and configuring them identically.
Rejected: identical configuration is not enforced by anything, and the two
would drift. A single pool with per-consumer access is simpler and is what the
"one filesystem for link-dependent consumers" requirement needs anyway.

### Preserve the existing fail-closed attachment discipline, and extend it

The read-only export already pins each real device, verifies that the mount is
the expected one, and refuses to serve an empty directory in a branch's place.
The writable namespace needs the same discipline: each required branch is
verified before the namespace is exposed, and a missing branch denies access
instead of accepting writes onto the root filesystem.

*Alternatives considered:* relying on mount ordering alone. Rejected: ordering
prevents some races but does not detect a device that failed to unlock or was
removed, which is exactly the case that produces silent writes to the wrong
place.

### Managed roots declare ownership; inherited permissions are policy

Roots always carry declared ownership and mode. A root declares default access
entries only when its sharing policy requires later content to inherit access
beyond owner/group/mode. Activation never recursively rewrites ownership, modes,
or access control entries of existing content.

*Alternatives considered:* enforcing desired state recursively on every
activation. Rejected: it is unbounded work over large trees, it makes a rebuild
a potentially destructive operation, and it fights any writer that legitimately
creates files with other ownership.

### Shared access resolves through the fleet identity graph

Names and numeric IDs for shared roots come from the existing group registry
rather than being chosen per host or per share. That keeps access control
entries stable and meaningful after the compute environment is rebuilt, and
avoids a separate, undocumented identity space.

*Alternatives considered:* per-share groups created ad hoc. Rejected: unbounded
group growth, no stable IDs across hosts, and no relationship to the identities
the compute boundary translates.

### The storage capability identity is the contract, not the transport

A root is authorized by a persistent storage capability identity — a
deliberately numbered POSIX group such as `media` or `family` — and not by the
identity of whichever workload or container consumes it. A workload keeps its own
UID and primary GID and receives the capability group; it does not become the
storage group, and its identity is never written into shared storage metadata.

The contract is therefore the stable GID. The attachment mechanism is an
implementation detail beneath it and may differ by consumer: an unprivileged
container, a filesystem-sharing mechanism, or NFS. The durable number is the
same in every case, which is what makes the namespace portable across hosts,
restores and direct disk inspection.

Explicitly rejected: letting the persistent on-disk GID become the current
container boundary's translated value (`idmapBase + guestGid`). That number is
meaningful only relative to one host's mapping, so it would have to be
reconstructed on every other consumer. Also rejected: changing the container's
user namespace globally to make the numbers line up.

The capability identity is verified rather than assumed: a group whose number is
part of the filesystem contract is asserted at evaluation time to resolve to
exactly its declared GID, so an upstream or platform definition cannot silently
take the number.

The disposable contract test must show the real mergerfs-backed mount: the
service UID and primary GID stay ordinarily subordinate-mapped, a single
capability GID is mapped identically on both sides, and the workload holds it
**only as a supplemental group**. A file created that way carries the
translated service UID and bare capability GID on the host, the guest sees the
capability under its fleet number, the same UID without the capability is
denied, container root is denied, and hardlink, rename, unlink and append all
behave. Restarting preserves all of it.

Only capabilities that actually have to cross a given boundary receive such a
mapping, so the exceptions stay as narrow as possible: the mapping is derived
from an explicit declared set rather than from a band, and the subordinate-ID
authorization and project permission follow that same set. The mechanism —
which map entries exist, which subordinate lines authorize them — is
implementation detail beneath this decision and is expected to differ for a VM,
an export, or another host.

## Risks / Trade-offs

- **Hardlinks cannot cross branch boundaries within the pool** → creation is
  restricted to branches declared to accept new content, the mover is
  link-aware, and a synthetic link test must pass before any real import.
- **Reported free space can mislead writers into accepting work they cannot
  place** → capacity reporting is restricted to creation-eligible capacity and
  is covered by its own check.
- **An interrupted move leaves two copies or an incomplete destination** →
  copy, verify, and only then remove; an interrupted move must leave the
  original complete data reachable and report itself as incomplete.
- **A wrong configuration produces confusing failures rather than obvious
  ones** → the fail-closed checks above turn the common misconfigurations into
  refusals instead of silent writes.
- **MergerFS older than 2.42.0 does not honour a supplemental capability
  group.** Measured: on 2.40.2 a process holding the capability only as a
  supplemental group was denied on a mergerfs mount and allowed on a plain
  filesystem, because mergerfs resolved entitlements from the host group
  database instead of the process. On **2.42.0 the same write is allowed**,
  including from a boundary-translated UID with no host account, and the result
  is identical to a plain filesystem; upstream reworked credential handling so
  that "the kernel manages entitlements". 2.42.0 also refuses to disable
  `default_permissions` for that reason → the capability model needs no
  workaround, but the deployed pool must not run an older mergerfs. A version
  floor belongs with the pooling declaration, not in prose.
- **Two-level indirection makes "where is this file" non-obvious** → the
  namespace and its branches must be inspectable as a mapping, not inferred
  from a path.
- **The protected fast tier is declared from a single device** and the host
  schema exposes no second root-pool device, so "protected" describes intent
  rather than current redundancy → the architecture document records this as an
  open decision, and nothing here depends on redundancy existing yet.
- **Archive placement movement is not exercised until a link-aware mover exists**
  → keep the requirement explicit; a single-tier deployment still satisfies the
  contract.

## Migration Plan

No content migration is in scope. Run synthetic placement, linking, capacity,
permission, and fail-closed checks before importing real content. Reverting
after content import would be a data migration outside this change.

## Open Questions

- **Which capabilities cross a given compute boundary, and how.** Decided in
  principle — an explicit declared set, initially `media` alone — with the
  mechanism kept as implementation detail. What remains open is only the
  spelling of the declaration and the lifecycle tool's representation of a
  range with declared holes, which should stay small and deterministic rather
  than becoming a general idmap policy language.
- Internal directory naming beneath each tier root is not fixed by this change.
- Watermark and free-space reserve values are operational tuning.
- Whether archive branches join the namespace does not change the contract; it
  only determines the deployed placement set.
