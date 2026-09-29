Host-owned roots, pooling, placement, permissions and fail-closed behavior are
implemented and checked in disposable environments. Consumer repointing lands
with the workload cuts. Still open: declaration conflict checks (1.2), the
physical-path check (4.1), the capacity-exhaustion half of 5.3, movement (5.6),
and production acceptance.

## 1. Declare host-owned semantic roots

- [x] 1.1 Add a host-owned semantic-root declaration alongside the existing compute-retained path declaration, carrying host path, owning user, owning group, and mode. Default access entries are optional and are declared only when the root's sharing policy requires inherited access. Verify by evaluating the host with a declared root and confirming the emitted directory and any declared access rules carry those values.
- [ ] 1.2 Add evaluation-time rejection of incoherent declarations. Verify by evaluating four conflicting variants — duplicate path, a root nested inside another root, a root overlapping a compute-managed path, and an undeclared identity — and confirming each fails naming that specific conflict, while a conformant declaration still evaluates.
- [x] 1.3 Emit managed-root creation carrying declared ownership and mode, plus default access entries only when the root's sharing policy declares them, with no operation that recurses over existing content. Verify by inspecting the emitted rules for a declared shared root: one directory rule and one non-recursive access rule, and by confirming on real `systemd-tmpfiles` that pre-existing content is left untouched.
- [x] 1.4 Wire shared-root identities through the existing group registry so their numeric IDs are stable and the groups actually exist on hosts. Verified by evaluating the resolved groups for the host and confirming the registry IDs are present, with no ad-hoc group introduced by the declaration.

## 2. Reconcile pooling into one namespace

- [x] 2.1 Make a single pooling instance serve the namespace, with creation restricted to placements declared to accept new content. Verify by evaluating the host: exactly one pooling instance is declared for the namespace, its rendered options restrict creation to those placements, and no-create placements are present without accepting creation.
- [x] 2.2 Declare each managed root's backing location as required or optional, and make an absent required location deny access instead of exposing an empty writable location. `mergerfs-contracts` checks the same required-location model used by the host assertion; the generated-unit runtime check stops the pool and its layout when a required mount is lost.
- [x] 2.3 Replace the independent read-only export with a read-only view of the same namespace, so both views are the same filesystem. Verify in a disposable Linux environment that a file created through the writable view and the same file read through the read-only view share one underlying allocation.

## 3. Repoint consumers

- [ ] 3.1 Point the writable media boundary of the acquisition workloads at the namespace, keeping the common parent so that import can link, and replacing the current per-application library roots with the namespace layout. Verified by `media-contracts`, which confirms no consumer-declared volume references the compute state root.
- [ ] 3.2 Give the player read-only access to the library subtree only. Verified by `media-contracts` and the x86_64 replacement acceptance.
- [x] 3.3 Remove the compute-retained media mapping once nothing consumes it, then evaluate the host and confirm the remaining retained mappings describe guest-owned state only.
- [ ] 3.4 Regenerate `docs/operations.md` and confirm its retained-state table no longer lists a media mapping.

## 4. Evaluation checks

- [ ] 4.1 Add a check that fails when a consumer-facing declaration references a physical placement path: devices, pools and tier names may appear only in storage declarations, never in application, manifest, or service declarations. Verify the check passes on the current tree and fails on a deliberately introduced reference.
- [x] 4.2 Add a check that fails when more than one pooling instance references the same placements. `mergerfs-contracts` exercises the validator used by the production module assertion with both the current unique model and a second pool over `/mnt/hot`.
- [x] 4.3 Add a check that fails when a root declared as requiring its backing storage is declared without the data needed to enforce that refusal. `mergerfs-contracts` exercises the validator used by the production module assertion with a required placement that has no mount unit.

## 5. Disposable-environment checks

- [x] 5.1 Link: create an item in the ingest path and link it into the library path through the common parent, then confirm both paths share one underlying allocation. Then confirm the same operation fails when the two paths are presented as separate filesystems, establishing that the common parent is required rather than merely convenient.
- [x] 5.2 Placement: create a new item through the namespace and confirm it resides on storage declared to accept new content and not on no-create storage. `mergerfs-capability` confirms a download lands on the creation-eligible disk and nothing new appears on the no-create branches.
- [ ] 5.3 Capacity: add no-create capacity without changing creation eligibility and confirm the capacity reported to a writer is unchanged; then consume creation-eligible space and confirm the reported capacity falls before creation begins to fail. The first half is covered: `mergerfs-capability` reports only the creation-eligible disk's space, including for a directory held only by a no-create branch. The exhaustion half is unexercised.
- [x] 5.4 Fail-closed: with a required placement unavailable, confirm access is denied, no substitute location accepts writes, the dependent workload fails, and host management and unrelated workloads continue to operate. Verified by the recorded x86_64/KVM replacement acceptance.
- [x] 5.5 Permissions: layout directories on the pool carry the group-only default ACL. `mergerfs-capability` creates files and nested directories with umask 022, directly on the XFS disk and through the pool, and confirms group 505 with modes 0660 and 2770 and an inherited default ACL, with no corrective step run afterwards; it also shows a deliberately `0600` file stays private (the contract's known limit). It then re-activates configuration with existing content present and confirms that no ownership, mode, or ACL entry under the root changed.
- [ ] 5.6 Movement: deferred until a link-aware mover exists; hardlink-aware movement between placements is unexercised. The namespace sets `moveonenospc=false` and no configured job performs link-unaware balancing over it, but neither is evidence for the movement requirement.
- [x] 5.7 Creation independent of parent placement: in `mergerfs-capability`, `library/movies/Foo` exists only on a required no-create branch; a download completed through the pool lands on the creation-eligible XFS disk, and a Radarr-style hardlink into `Foo/new.mkv` succeeds on that disk with the same inode, the group and default ACL, nothing new on the no-create branches, and the existing file still visible and modifiable at its canonical path.
- [x] 5.8 Shared modification: `mergerfs-capability` confirms that a file created by one participating identity can be modified, hardlinked, renamed and removed by another UID holding the capability, and that a UID without it can neither read, write, nor list it.
