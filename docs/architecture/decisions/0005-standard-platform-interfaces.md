---
id: ADR-0005
status: accepted
date: 2026-09-08
updated: 2026-09-08
decision-makers: [Homelab operator]
consulted: []
informed: [Homelab operator]
supersedes: []
superseded-by: []
modifies: [ADR-0002]
modified-by: []
related-adrs: [ADR-0001, ADR-0004]
related-specs: [management-boundaries, storage-foundations, secret-management]
related-changes: [reliable-household-services]
target-architecture: []
---

# Standard Kubernetes platform; optional application integration

## Context and Problem Statement

The operator rejected making a Homelab application wrapper the entrance to Kubernetes. Ordinary Helm charts must be useful, while integrated media applications may still benefit from Nix-owned configuration. Requiring every application to join our model would turn system integration into a framework and make undocumented wrapper behavior part of routine operations.

## Decision Drivers

- Reuse standard Kubernetes and application tooling.
- Keep resource ownership, storage access and reconstruction inputs explicit.
- Keep routine host-path and Unix identity allocation out of application declarations.

## Considered Options

- Require Den/Nixidy and Argo ownership for every application.
- Provide standard platform interfaces with optional Den/Nixidy integration.

## Decision Outcome

Choose **standard platform interfaces with optional integration**, as approved in the operator's platform review and ordinary-Helm recovery slice.

This modifies ADR-0002's delivery scope: Den/Nixidy and Argo remain the integrated delivery path, but ordinary Helm and application-owned manifests may independently own other resources. There must not be competing owners of the same object. ADR-0002's secret authority and independent bootstrap decisions remain unchanged; ADR-0004 still governs explicitly managed application fields.

Storage and runtime secret capabilities do not require an application wrapper. Application integrations choose compatible identities and mounts; ordinary charts may use native Kubernetes ownership handling. Exceptions for image compatibility or existing-data migration remain implementation concerns rather than routine operator allocation tasks.

### Consequences and Confirmation

- Installation metadata outside Nix becomes an explicit recovery input. Persistent files alone do not reconstruct a Helm installation.
- Retained volume mappings identify the original backing storage; matching a newly created claim's name is not permission to adopt old data.
- Reattaching surviving host storage and restoring lost data from backup remain different operations.
- Confirm the boundary with an ordinary Helm application whose user-created state survives guest replacement without a Homelab application definition.

## References

- Modified decision: [ADR-0002](0002-declarative-application-delivery.md).
- Proposed platform/recovery contract: [household-services](../../../openspec/changes/reliable-household-services/specs/household-services/spec.md).
- Current physical storage ownership: [storage-foundations](../../../openspec/specs/storage-foundations/spec.md).
