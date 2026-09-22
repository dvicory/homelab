---
id: ADR-0002
status: accepted
date: 2026-09-07
updated: 2026-09-21
decision-makers: [Homelab operator through delegated implementation authority]
consulted: []
informed: [Homelab operator]
supersedes: []
superseded-by: []
modifies: []
modified-by: [ADR-0008]
related-adrs: [ADR-0001]
related-specs: [management-boundaries, storage-foundations, secret-management]
related-changes: []
target-architecture: []
---

# Render applications with Den and Nixidy; reconcile with Argo CD

## Context and Problem Statement

Application delivery must remain independent of the guest operating system and
recoverable without the failed application plane. Maintaining hand-built
application artifacts and release machinery would duplicate capabilities
provided by Den, Nixidy, and Argo.

## Decision Drivers

- Reuse Den composition and upstream charts rather than build an application
  framework.
- Keep one desired-state owner per Kubernetes object, independent version pins,
  and explicit retained-data protection.
- Keep bootstrap and runtime secret recovery independent of live Git and
  cluster identity.
- Make standard Kubernetes and application tooling useful without requiring
  every application to use a Homelab wrapper.

## Considered Options

- Extend hand-built artifacts and K3s AddOns.
- Use Nixidy direct apply as the normal environment-wide delivery mechanism.
- Use Den/Nixidy rendering with Argo application reconciliation and static
  bootstrap artifacts.
- Require a Homelab application wrapper for every Helm chart or manifest.

## Decision Outcome

Choose **Den/Nixidy with Argo** for the integrated delivery path. Reuse cluster
entities and the `k8s-manifests` class; keep integrated applications as thin
chart/resource aspects. Nixidy renders canonical manifests, while Argo owns
normal reconciliation from the repository ref declared by the cluster.

The platform does not require an application wrapper. Ordinary Helm charts and
application-owned manifests may independently own resources outside the
integrated path. No two owners may reconcile the same object. Storage and
runtime-secret capabilities do not require wrapper participation; each
application chooses compatible identities and mounts and uses native Kubernetes
ownership handling.

Static bootstrap is limited to the Argo seed and explicit root-Application
handoff. Argo then owns workload reconciliation. Existing AddOn ownership must
be retired before Argo owns the same objects. Direct apply remains a bounded
bootstrap or recovery operation, not an unrestricted normal delivery command.

Agenix/rekey remains the secret authority. Host-staged runtime files supply
Kubernetes Secrets through the native API; rendering contains references, not
plaintext. A second encryption or secret-operator stack is not required to
adopt Nixidy.

Retained volume mappings identify their original backing storage. A matching
new claim name is not permission to adopt old data, and reattaching surviving
storage is distinct from any future data-restoration operation. This ADR does
not define backup policy.

### Consequences and Confirmation

- Upstream charts/controllers replace custom rendering and reconciliation, but
  add pinned dependencies and a Git dependency for normal delivery.
- Retained namespaces and volumes need explicit lifecycle protection. Nixidy
  direct apply prunes namespaces and does not honor Argo retention annotations;
  it is not an unrestricted recovery command.
- Ordinary Helm and application-owned resources remain useful without a
  Homelab wrapper, provided ownership is explicit and non-overlapping.
- Confirmation concerns ownership, bootstrap, secret, and storage boundaries;
  local evidence does not close production gates.
- Reconsider if controller/bootstrap dependencies outweigh their value or an
  upstream deployment mechanism supplies the same guarantees with less
  machinery.

## References

- [Cluster delivery declaration](../../../modules/den/clusters/home.nix).
- [Cluster resource policy](../../../modules/den/policies/clusters.nix).
- [Nixidy direct apply](https://nixidy.dev/user_guide/direct_apply/).
- [Argo automatic synchronization](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/).
