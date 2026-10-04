Host-owned roots, pooling, placement, permissions and fail-closed behavior are
implemented and checked in disposable environments, and the player reads the
namespace read-only. Writer repointing (3.1) lands with the media cut. Still
open: declaration conflict checks (1.2), the physical-path check (4.1), the
capacity-exhaustion half of 5.3, movement (5.6), and production acceptance.

## 1. Declare host-owned semantic roots

- [x] 1.1 Add a host-owned semantic-root declaration alongside the existing
  compute-retained path declaration, carrying host path, owning user, owning
  group, and mode. Default access entries are optional and are declared only
  when the root's sharing policy requires inherited access. Verify that the
  emitted directory and access rules carry those values.
- [ ] 1.2 Add evaluation-time rejection of incoherent declarations. Verify
  duplicate paths, nested roots, overlap with a compute-managed path, and
  undeclared identities each fail naming the specific conflict, while a
  conformant declaration evaluates.
- [x] 1.3 Emit managed-root creation carrying declared ownership and mode,
  plus default access entries only when the sharing policy declares them, with
  no operation that recurses over existing content.
- [x] 1.4 Wire shared-root identities through the existing group registry so
  numeric IDs are stable and the groups exist on hosts; introduce no ad-hoc
  group in the declaration.

## 2. Reconcile pooling into one namespace

- [x] 2.1 Make a single pooling instance serve the namespace, with creation
  restricted to placements declared to accept new content. Verify that
  no-create placements remain visible without accepting creation. `mergerfs-capability`
  reads existing content from a no-create branch through the one pool.
- [x] 2.2 Declare each managed root's backing location as required or optional,
  and make an absent required location deny access instead of exposing an empty
  writable location. The existing mergerfs contract covers this required-
  location model.
- [x] 2.3 Replace the independent read-only export with a read-only view of
  the same namespace, so both views are the same filesystem.
  `mergerfs-capability` confirms a read-only bind of the library refuses
  writes and reports the same device as the writable namespace.

## 3. Repoint downstream consumers

The later workload cut owns consumer manifests and runtime evidence. It must
restore these tasks without claiming them in the platform cut:

- [ ] 3.1 Point link-dependent writers at the common namespace and use the
  semantic layout rather than a compute-state path.
- [x] 3.2 Give read-only consumers access only to the required semantic
  subtree. Jellyfin mounts `library` read-only at `/media` (`jellyfin-contracts`
  checks the hostPath and `readOnly`; the replacement scenario shows its pod
  cannot write `/media`).
- [x] 3.3 Remove any obsolete compute-retained mapping once no consumer uses
  it, then verify retained mappings describe guest-owned state only. Media is
  the optional `/srv/media` attachment, not a retained path
  (`compute-contracts`), and the retained paths are guest-owned application
  state.
- [x] 3.4 Regenerate the operations document after consumer mappings change and
  confirm its retained-state table reflects only guest-owned state.
  `docs/operations.md` lists only guest-owned retained state and describes
  the media attachment separately.

## 4. Evaluation checks

- [ ] 4.1 Add a check that rejects consumer-facing declarations containing
  physical placement paths; devices, pools, and tier names belong only in
  storage declarations.
- [x] 4.2 Add a check that rejects more than one pooling instance over the
  same placements.
- [x] 4.3 Add a check that rejects a required placement without the data
  needed to enforce fail-closed refusal.

## 5. Disposable-environment checks

- [x] 5.1 Link: verify that link-dependent paths presented through the common
  parent share one underlying allocation and that separate filesystems reject
  the cross-boundary operation. Covered by `mergerfs-capability`.
- [x] 5.2 Placement: verify new content lands only on creation-eligible
  placements. `mergerfs-capability` confirms a download lands on the creation-eligible
  disk and nothing new appears on the no-create branches.
- [ ] 5.3 Capacity: verify no-create capacity does not change writer-visible
  creation capacity, then verify creation-eligible exhaustion is reported
  before writes fail. The first half is covered: `mergerfs-capability`
  reports only the creation-eligible disk's space, including for a directory
  held only by a no-create branch. The exhaustion half is unexercised.
- [x] 5.4 Fail-closed: with a required placement unavailable, verify access is
  denied, no substitute location accepts writes, the dependent workload fails,
  and host management and unrelated workloads continue. The replacement
  scenario stops the media pool under a running guest: no substitute media
  directory appears, the writer cannot write, Jellyfin stays blocked, and the
  K3s node and an unrelated workload stay healthy; the pool's return recovers
  Jellyfin without a node restart.
- [x] 5.5 Permissions: verify shared-root entries carry declared permissions
  without a corrective recursive operation and that activation leaves existing
  ownership, mode, and access entries unchanged. Layout directories carry the
  group-only default ACL; `mergerfs-capability` creates files and nested
  directories with umask 022, directly on the XFS disk and through the pool,
  confirms group 505 with modes 0660 and 2770 and an inherited default ACL,
  shows a deliberately `0600` file stays private (the contract's known
  limit), then re-activates and confirms nothing under the root changed.
- [ ] 5.6 Movement: deferred until a link-aware mover exists; hardlink-aware
  movement between placements is unexercised. The namespace sets
  `moveonenospc=false` and no configured job performs link-unaware balancing
  over it, but neither is evidence for the movement requirement.
- [x] 5.7 Creation independent of parent placement: in `mergerfs-capability`,
  `library/movies/Foo` exists only on a required no-create branch; a download
  completed through the pool lands on the creation-eligible XFS disk, and a
  Radarr-style hardlink into `Foo/new.mkv` succeeds on that disk with the
  same inode, the group and default ACL, nothing new on the no-create
  branches, and the existing file still visible and modifiable at its
  canonical path.
- [x] 5.8 Shared modification: `mergerfs-capability` confirms that a file
  created by one participating identity can be modified, hardlinked, renamed
  and removed by another UID holding the capability, and that a UID without
  it can neither read, write, nor list it.
- [x] 5.9 Only classified content is visible: in `mergerfs-capability` a disk
  contributes its `pool/` subtree with a `migration/` area beside it;
  `migration/` never appears in the namespace, and a missing or symlinked
  `pool/` refuses the pool while the disk stays mounted. hvn-hyp1 pools
  media4's `pool/` alone; media2 and media3 stay outside until they are
  converted.
