---
id: ADR-0002
status: accepted
date: 2026-09-07
updated: 2026-09-08
decision-makers: [Homelab operator through delegated implementation authority]
consulted: []
informed: [Homelab operator]
supersedes: []
superseded-by: []
modifies: []
modified-by: [ADR-0005]
related-adrs: [ADR-0001]
related-specs: [management-boundaries, storage-foundations, secret-management]
related-changes: [reliable-household-services]
target-architecture: []
---

# Render applications with Den and Nixidy; reconcile with Argo CD

## Context and Problem Statement

The initial compute slice uses a hand-built application artifact and K3s AddOn delivery. Expanding that pattern across household services would make Homelab maintain resource rendering and release machinery already available upstream. Application delivery must remain independent of the guest OS and recoverable without the failed application plane.

## Decision Drivers

- Reuse Sini's compatible Den composition and upstream charts rather than build an application framework.
- Keep one desired-state owner, independent version pins, and explicit retained-data protection.
- Keep bootstrap and runtime secret recovery independent of live Git and cluster identity.

## Considered Options

- Extend hand-built artifacts and K3s AddOns.
- Use Nixidy direct apply as the normal environment-wide delivery mechanism.
- Use Den/Nixidy rendering with Argo application reconciliation and static recovery artifacts.

## Decision Outcome

Choose **Den/Nixidy with Argo**, under the operator's delegated authority. Reuse cluster entities and the `k8s-manifests` class; keep applications as thin chart/resource aspects. Argo owns normal reconciliation. Static rendered resources support ordered bootstrap and selected, non-pruning recovery. Existing AddOn ownership must be retired before Argo owns the same objects.

The delivery scope is modified by [ADR-0005](0005-standard-platform-interfaces.md): this remains the integrated path, not a prerequisite for using standard platform storage or secrets with ordinary Helm/application-owned resources.

Agenix/rekey remains the secret authority. Host-staged runtime files supply Kubernetes Secrets through the native API; rendering contains references, not plaintext. A second encryption/operator stack is not required to adopt Nixidy.

### Consequences and Confirmation

- Upstream charts/controllers replace custom rendering and reconciliation, but add pinned dependencies and a Git dependency for normal delivery.
- Retained namespaces and volumes need explicit lifecycle protection. Nixidy direct apply prunes namespaces and does not honor Argo retention annotations; it is not an unrestricted recovery command.
- Confirmation concerns our ownership, bootstrap, secret and storage boundaries—not upstream application feature behavior. Local evidence does not close production gates.
- Reconsider if controller/bootstrap dependencies outweigh their value or an upstream deployment mechanism supplies the same guarantees with less machinery.

## References

- Proposed contracts and implementation plan: [reliable-household-services](../../../openspec/changes/reliable-household-services/design.md).
- [Nixidy direct apply](https://nixidy.dev/user_guide/direct_apply/).
- [Argo automatic synchronization](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/).
- Sini reference: `modules/den/batteries/nixidy.nix` and `modules/den/policies/clusters.nix` in the operator's Sini checkout.
