## 1. Declare host-owned semantic roots

- [x] 1.1 Add a host-owned semantic-root declaration alongside the existing compute-retained path declaration, carrying host path, owning user, owning group, mode, and default access entries. Verified by evaluating the host with a declared root and confirming the emitted directory and access rules carry those values.
- [x] 1.2 Add evaluation-time rejection of incoherent declarations. Verified by evaluating four conflicting variants — duplicate path, a root nested inside another root, a root overlapping a compute-managed path, and an undeclared identity — and confirming each fails naming that specific conflict, while a conformant declaration still evaluates.
- [x] 1.3 Emit managed-root creation carrying declared ownership, mode, and default access entries, with no operation that recurses over existing content. Verified by inspecting the emitted rules for a declared root: one directory rule and one non-recursive access rule, and by confirming on real `systemd-tmpfiles` that pre-existing content is left untouched.
- [x] 1.4 Wire shared-root identities through the existing group registry so their numeric IDs are stable and the groups actually exist on hosts. Verified by evaluating the resolved groups for the host and confirming the registry IDs are present, with no ad-hoc group introduced by the declaration.

## 2. Reconcile pooling into one namespace

- [ ] 2.1 Make a single pooling instance serve the namespace, with creation restricted to placements declared to accept new content. Verify by evaluating the host: exactly one pooling instance is declared for the namespace, its rendered options restrict creation to those placements, and archive placements are present without accepting creation.
- [ ] 2.2 Declare each managed root's backing location as required or optional, and make an absent required location deny access instead of exposing an empty writable location. Verify by evaluating a variant with one required placement removed and confirming the declaration refuses rather than degrading silently.
- [ ] 2.3 Replace the independent read-only export with a read-only view of the same namespace, so both views are the same filesystem. Verify in a disposable Linux environment that a file created through the writable view and the same file read through the read-only view share one underlying allocation.

## 3. Repoint consumers — gated on the operator decision

Section 3 changes where acquisition services write. Do not start it until the
operator has decided that the writable media boundary moves from compute-retained
state to the namespace. Sections 1, 2, 4 and 5 do not depend on that decision.

- [ ] 3.1 Point the writable media boundary of the acquisition workloads at the namespace, keeping the common parent so that import can link, and replacing the current per-application library roots with the namespace layout. Verify by evaluating the workloads and confirming no consumer-declared volume references the compute state root.
- [ ] 3.2 Give the player read-only access to the library subtree only. Verify by evaluating the player workload and confirming the declared mount is the library subtree and read-only.
- [ ] 3.3 Remove the compute-retained media mapping once nothing consumes it, then evaluate the host and confirm the remaining retained mappings describe guest-owned state only.
- [ ] 3.4 Regenerate `docs/operations.md` and confirm its retained-state table no longer lists a media mapping.

## 4. Evaluation checks

- [ ] 4.1 Add a check that fails when a consumer-facing declaration references a physical placement path: devices, pools and tier names may appear only in storage declarations, never in application, manifest, or service declarations. Verify the check passes on the current tree and fails on a deliberately introduced reference.
- [ ] 4.2 Add a check that fails when more than one pooling instance references the same placements. Verify the check passes on the current tree and fails on a variant that declares a second instance over the same placements.
- [ ] 4.3 Add a check that fails when a root declared as requiring its backing storage is declared without the data needed to enforce that refusal. Verify by evaluating a deliberately incomplete declaration.

## 5. Disposable-environment checks

- [ ] 5.1 Link: create an item in the ingest path and link it into the library path through the common parent, then confirm both paths share one underlying allocation. Then confirm the same operation fails when the two paths are presented as separate filesystems, establishing that the common parent is required rather than merely convenient.
- [ ] 5.2 Placement: create a new item through the namespace and confirm it resides on storage declared to accept new content and not on archive placement. Conditional on a second placement existing; if only one placement exists, record the archive half as unexercised.
- [ ] 5.3 Capacity: add archive capacity without changing creation eligibility and confirm the capacity reported to a writer is unchanged; then consume creation-eligible space and confirm the reported capacity falls before creation begins to fail.
- [ ] 5.4 Fail-closed: with a required placement unavailable, confirm access is denied, no substitute location accepts writes, the dependent workload fails, and host management and unrelated workloads continue to operate.
- [ ] 5.5 Permissions: create an entry inside a shared root as a participating identity and confirm it carries the declared group and permissions with no corrective step run afterwards. Then re-activate configuration with existing content present and confirm nothing under the root changed ownership, mode, or access entries.
- [ ] 5.6 Movement: if a link-aware mover is available, move content with more than one linked path between placements and confirm every path still resolves and space is not permanently doubled. If no mover exists, record the movement requirement as unexercised and confirm no configured job performs link-unaware balancing over the namespace.
- [ ] 5.7 Operator access: from the host, as an operator identity rather than root, read and modify content inside each managed root, including media written by a workload through the compute boundary. Confirm the operation succeeds through inherited access rather than by becoming root.
