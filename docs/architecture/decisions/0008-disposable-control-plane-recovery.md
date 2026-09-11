---
id: ADR-0008
status: accepted
date: 2026-09-11
updated: 2026-09-11
decision-makers: [Daniel Vicory]
consulted: []
informed: [Homelab operator]
supersedes: []
superseded-by: []
modifies: [ADR-0002]
modified-by: []
related-adrs: [ADR-0001, ADR-0005, ADR-0006]
related-specs: [management-boundaries, storage-foundations]
related-changes: [disposable-control-plane-recovery, reproducible-jellyfin-compute, reliable-household-services]
target-architecture: []
---

# Treat the Kubernetes control plane as disposable compute state

## Context and Problem Statement

Compute-loss recovery grew a cold whole-stack export/restore/resume layer that archives retained paths, journals sessions, and restores prior cluster state. The operator requires only same-evening recovery when the physical host and durable storage survive, explicitly permits Internet/GitHub/registry access during a rebuild, and does not require offline cluster reconstruction or restoration of the prior cluster database, container cache, or object identities.

The decision question: **should recovery preserve and restore control-plane state, or replace it and reconcile from Git?**

## Decision Drivers

- Recovery must be a short, documented sequence reproducible from the repository plus durable data and secrets.
- Rebuilding may use GitHub and public container registries; running services should tolerate outages, but rebuild need not work offline.
- Custom orchestration is kept only for integration points unique to this homelab; standard K3s/Argo/Git behavior is preferred.
- Durable application state must never depend exclusively on the disposable cluster database.

## Considered Options

- Replace the compute instance and reconcile from Git (Argo seed, secret staging, root Application handoff).
- Keep cold whole-stack export/restore/resume of retained paths plus cluster-state restoration.
- Restore the K3s datastore from backup while reattaching storage.

## Decision Outcome

Chosen option: **replace the compute instance and reconcile from Git**, under the operator's explicit direction. The supported compute-loss path is `compute-guest replace` → stage secrets → seed Argo → apply the canonical root Application → Argo reconciles → reattached storage serves applications. Instance roots, the Kubernetes datastore, container caches, and prior object identities are disposable.

This modifies ADR-0002's delivery scope in one bounded respect: static bootstrap is narrowed to the Argo seed (namespace, CRDs, controllers) plus the explicit root-Application handoff. ADR-0002's Argo-owns-normal-reconciliation decision, secret authority, and retention protections are unchanged and reinforced; broad static application delivery and unrestricted direct apply remain rejected as recovery mechanisms.

### Consequences

- Good, because recovery exercises the same GitOps path as normal delivery instead of a parallel cold-restore implementation.
- Good, because whole-stack export/resume machinery, offline image fixtures, and the manual sandbox leave the tree.
- Bad, because rebuilds require Git and registry access; an outage blocks reconstruction (running workloads are unaffected).
- Neutral, because application-consistent backup design stays separate future work.

### Confirmation

- No `household-recovery` export/restore/resume interface exists in the tree.
- Static bootstrap artifacts contain only the Argo seed plus the root Application handoff.
- The automated recovery test replaces the guest, observes a fresh cluster identity, and verifies retained Jellyfin state through Argo reconciliation.

## Pros and Cons of the Options

### Replace the compute instance and reconcile from Git

- Good, because desired state has one owner (Git via Argo) in both normal and recovery operation.
- Good, because failure domains stay explicit: host/storage durable, compute/cluster disposable.
- Bad, because reconstruction depends on external Git/registry availability.

### Keep cold whole-stack export/restore/resume

- Good, because same-host exports work without external access.
- Bad, because it preserves disposable state, stops all writers for capture, and maintains a bespoke orchestrator with journals, resume protocols, and freshness metrics.
- Bad, because exports on the same host are not independent backups.

### Restore the K3s datastore from backup

- Good, because object identities and controller state survive.
- Bad, because it makes the disposable database durable by the back door and couples recovery to datastore backup/restore procedures.

## More Information

### Assumptions

- The physical host, host-owned retained storage, agenix/secret inputs, and guest identity inputs survive compute loss.
- Same-host retention is not a backup; off-host backup remains separate work.

### Reconsideration Triggers

Revisit this decision if one or more of these become true:

- Rebuild-time Internet access becomes unacceptable, forcing an offline-capable design.
- Multi-node or HA control-plane requirements make datastore continuity necessary.
- Argo/GitOps maintenance cost exceeds a simpler static-delivery mechanism with equivalent guarantees.

### References

- OpenSpec: `storage-foundations` and change `disposable-control-plane-recovery`
- Related ADR: [ADR-0002](0002-declarative-application-delivery.md)
