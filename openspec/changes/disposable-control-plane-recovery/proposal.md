## Why

Cold whole-stack export/restore machinery preserves a disposable Kubernetes
control plane instead of replacing it. The operator requires same-evening
recovery when the host and durable storage survive, with online access to Git
and registries.

## What Changes

- Treat the compute instance, Kubernetes datastore, container cache, and prior
  object identities as disposable.
- Recover by recreating the Incus guest, seeding Argo CD from canonical
  manifests, staging host-owned secrets, and letting Argo reconcile the
  tracked Git ref.
- Reattach host-owned retained storage through declared local volumes; do not
  restore disposable cluster state as a recovery mechanism.
- **BREAKING:** remove `household-recovery` export/restore/resume, its
  inventory/journal/metrics protocol, offline image fixtures, and the manual
  offline sandbox as supported recovery mechanisms.
- Retain `compute-guest create/replace`, host-owned storage bindings, runtime
  secret staging, canonical manifests, and the Argo root-Application handoff.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `storage-foundations`: durable workload state must remain recoverable without
  restoring disposable compute or cluster state.

## Impact

- Removes obsolete whole-stack recovery orchestration, offline fixtures, and
  sandbox artifacts.
- Narrows `household-bootstrap` to Argo seeding plus explicit root-Application
  handoff.
- Keeps the replacement boundary and tracked-source reconciliation available
  to later workload cuts; this platform revision does not claim application
  runtime acceptance.
