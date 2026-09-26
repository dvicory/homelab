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

## Context

Compute-loss recovery must replace disposable Kubernetes state rather than
restore it. The operator needs same-evening recovery when the physical host and
durable storage survive, and accepts GitHub, registry, and other online inputs
during a rebuild.

The decision is whether recovery preserves and restores control-plane state or
replaces it and reconciles from Git.

## Decision drivers

- Recovery must be a short, documented sequence reproducible from the
  repository, durable data, and secrets.
- Rebuilding may use GitHub and public container registries; running services
  should tolerate outages, but rebuild need not work offline.
- Prefer standard K3s, Argo, and Git behavior; keep custom orchestration only
  for integration points unique to this homelab.
- Durable application state must not depend exclusively on the disposable
  cluster database.

## Alternatives

- Replace the compute instance and reconcile from Git through secret staging,
  Argo seeding, and the root-Application handoff.
- Keep cold whole-stack export/restore/resume of retained paths and cluster
  state.
- Restore the K3s datastore from backup while reattaching storage.

## Decision

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

## Consequences

- Good: recovery uses the normal GitOps path instead of a parallel cold-restore
  implementation.
- Good: failure domains stay explicit; host and storage are durable, while
  compute and cluster state are disposable.
- Bad: rebuilds require Git and registry access; an outage blocks reconstruction
  while running workloads are unaffected.
- Neutral: application-consistent protection and restoration remain separate
  work owned outside this decision.

## Confirmation boundary

This ADR records the recovery decision but does not claim target-runtime
replacement acceptance. A destructive replacement scenario and its runtime
evidence require separate authorization and execution.

## Reconsideration triggers

Revisit this decision if one or more of these become true:

- Rebuild-time Internet access becomes unacceptable, forcing an offline-capable
  design.
- Multi-node or HA control-plane requirements make datastore continuity
  necessary.
- Argo/GitOps maintenance cost exceeds a simpler static-delivery mechanism
  with equivalent guarantees.

## References

- OpenSpec change: [disposable-control-plane-recovery](../../../openspec/changes/disposable-control-plane-recovery/proposal.md).
- Related ADR: [ADR-0002](0002-declarative-application-delivery.md).
