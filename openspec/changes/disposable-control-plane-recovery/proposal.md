## Why

Cold whole-stack export/restore machinery preserves a disposable Kubernetes control plane instead of replacing it. The operator only requires same-evening recovery when the host and durable storage survive, with online access to Git and registries.

## What Changes

- Treat `compute-1`/K3s database, container cache, and object identities as disposable.
- Recover by recreating the Incus guest, seeding Argo CD from canonical manifests, staging host-owned secrets, and letting Argo reconcile Git.
- Reattach host-owned retained storage through declared local volumes; do not capture/restore the whole retained set as cold tar archives.
- **BREAKING**: Remove `household-recovery` export/restore/resume, its inventory/journal/metrics protocol, offline Jellyfin image fixtures, and the manual offline sandbox as recovery mechanisms.
- Retain `compute-guest create/replace`, host-owned storage bindings, runtime secret staging, canonical manifests, and an online replacement test.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `storage-foundations`: durable workload state must remain recoverable without restoring disposable compute/cluster state.

## Impact

- Removes `modules/den/aspects/kubernetes/recovery.nix`, `modules/den/aspects/kubernetes/_recovery.sh`, offline `jellyfin-image` fixtures, and `modules/flake/jellyfin-sandbox.nix`/`docs/jellyfin-sandbox.md`.
- Narrows `household-bootstrap` to Argo seeding plus explicit root-application handoff.
- Replaces the offline VM recovery scenario with an online replacement test.
- Updates recovery monitoring, operations docs, active OpenSpec deltas, and ADR history.
