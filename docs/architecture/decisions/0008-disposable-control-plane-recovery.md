---
id: ADR-0008
status: accepted
date: 2026-09-11
updated: 2026-09-21
decision-makers: [Daniel Vicory]
consulted: []
informed: [Homelab operator]
supersedes: []
superseded-by: []
modifies: [ADR-0002]
modified-by: []
related-adrs: [ADR-0001, ADR-0002]
related-specs: [management-boundaries, storage-foundations]
related-changes: [disposable-control-plane-recovery]
target-architecture: []
---

# Treat the Kubernetes control plane as disposable compute state

## Context and Problem Statement

Compute-loss recovery must replace disposable Kubernetes state rather than
restore it. The operator requires same-evening recovery when the physical host
and durable storage survive, and permits GitHub, registry, and other online
inputs during a rebuild.

The decision question is: **should recovery preserve and restore control-plane
state, or replace it and reconcile from Git?**

## Decision Drivers

- Recovery must be a short, documented sequence reproducible from the
  repository, durable data, and secrets.
- Rebuilding may use GitHub and public container registries; running services
  should tolerate outages, but rebuild need not work offline.
- Custom orchestration is kept only for integration points unique to this
  homelab; standard K3s, Argo, and Git behavior is preferred.
- Durable application state must not depend exclusively on the disposable
  cluster database.

## Considered Options

- Replace the compute instance and reconcile from Git through the Argo seed,
  secret staging, and root-Application handoff.
- Keep cold whole-stack export/restore/resume of retained paths plus
  cluster-state restoration.
- Restore the K3s datastore from backup while reattaching storage.

## Decision Outcome

Choose **replace the compute instance and reconcile from Git**. The supported
compute-loss boundary is `compute-guest replace` followed by secret staging,
Argo seeding, root-Application handoff, and Argo reconciliation. Instance
roots, the Kubernetes datastore, container caches, and prior object identities
are disposable.

This modifies ADR-0002's delivery scope in one bounded respect: static
bootstrap is narrowed to the Argo seed plus the explicit root-Application
handoff. ADR-0002's Argo-owns-normal-reconciliation decision, secret
authority, and retention protections remain unchanged. Broad static application
delivery and unrestricted direct apply remain rejected as recovery mechanisms.

### Consequences

- Good, because recovery uses the same GitOps path as normal delivery instead
  of a parallel cold-restore implementation.
- Good, because failure domains stay explicit: host/storage durable,
  compute/cluster disposable.
- Bad, because rebuilds require Git and registry access; an outage blocks
  reconstruction while running workloads are unaffected.
- Neutral, because application-consistent protection and restoration are
  separate work owned outside this change.

### Confirmation boundary

This platform revision records the recovery decision but does not claim target
runtime replacement acceptance. Later compute and application cuts own the
executable destructive-replacement scenario and its runtime evidence.

## Pros and Cons of the Options

### Replace the compute instance and reconcile from Git

- Good, because desired state has one owner (Git via Argo) in both normal and
  recovery operation.
- Good, because failure domains stay explicit: host/storage durable,
  compute/cluster disposable.
- Bad, because reconstruction depends on external Git and registry
  availability.

### Keep cold whole-stack export/restore/resume

- Good, because same-host exports work without external access.
- Bad, because it preserves disposable state and maintains bespoke recovery
  machinery.

### Restore the K3s datastore from backup

- Good, because object identities and controller state survive.
- Bad, because it makes the disposable database durable by the back door and
  couples recovery to datastore backup/restore procedures.

## More Information

### Assumptions

- The physical host, host-owned retained storage, agenix/secret inputs, and
  guest identity inputs survive compute loss.
- This ADR does not define application protection policy or a restoration
  destination.

### Reconsideration Triggers

Revisit this decision if one or more of these become true:

- Rebuild-time Internet access becomes unacceptable, forcing an offline-capable
  design.
- Multi-node or HA control-plane requirements make datastore continuity
  necessary.
- Argo/GitOps maintenance cost exceeds a simpler static-delivery mechanism
  with equivalent guarantees.

### References

- OpenSpec change: [disposable-control-plane-recovery](../../../openspec/changes/disposable-control-plane-recovery/proposal.md).
- Related ADR: [ADR-0002](0002-declarative-application-delivery.md).
