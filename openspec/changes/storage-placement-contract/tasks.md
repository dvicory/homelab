Host-owned semantic-root declarations and their ACL/identity checks are
complete. Pooling, consumer repointing, placement checks, and production
validation remain open; production data has not been migrated.

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

- [ ] 2.1 Make a single pooling instance serve the namespace, with creation
  restricted to placements declared to accept new content. Verify that archive
  placements remain visible without accepting creation.
- [x] 2.2 Declare each managed root's backing location as required or optional,
  and make an absent required location deny access instead of exposing an empty
  writable location. The existing mergerfs contract covers this required-
  location model.
- [ ] 2.3 Replace the independent read-only export with a read-only view of
  the same namespace, so both views are the same filesystem.

## 3. Repoint downstream consumers

The later workload cut owns consumer manifests and runtime evidence. It must
restore these tasks without claiming them in the platform cut:

- [ ] 3.1 Point link-dependent writers at the common namespace and use the
  semantic layout rather than a compute-state path.
- [ ] 3.2 Give read-only consumers access only to the required semantic
  subtree.
- [ ] 3.3 Remove any obsolete compute-retained mapping once no consumer uses
  it, then verify retained mappings describe guest-owned state only.
- [ ] 3.4 Regenerate the operations document after consumer mappings change and
  confirm its retained-state table reflects only guest-owned state.

## 4. Evaluation checks

- [ ] 4.1 Add a check that rejects consumer-facing declarations containing
  physical placement paths; devices, pools, and tier names belong only in
  storage declarations.
- [x] 4.2 Add a check that rejects more than one pooling instance over the
  same placements.
- [x] 4.3 Add a check that rejects a required placement without the data
  needed to enforce fail-closed refusal.

## 5. Disposable-environment checks

- [ ] 5.1 Link: verify that link-dependent paths presented through the common
  parent share one underlying allocation and that separate filesystems reject
  the cross-boundary operation.
- [ ] 5.2 Placement: verify new content lands only on creation-eligible
  placements; if no archive placement exists, record that half as unexercised.
- [ ] 5.3 Capacity: verify archive capacity does not change writer-visible
  creation capacity, then verify creation-eligible exhaustion is reported
  before writes fail.
- [ ] 5.4 Fail-closed: with a required placement unavailable, verify access is
  denied, no substitute location accepts writes, the dependent workload fails,
  and host management and unrelated workloads continue. No runtime replacement
  acceptance is claimed here.
- [ ] 5.5 Permissions: verify shared-root entries carry declared permissions
  without a corrective recursive operation and that activation leaves existing
  ownership, mode, and access entries unchanged.
- [x] 5.6 Movement: no link-aware mover exists, so movement remains
  unexercised. The namespace sets `moveonenospc=false`, and no configured job
  performs link-unaware balancing over it.
