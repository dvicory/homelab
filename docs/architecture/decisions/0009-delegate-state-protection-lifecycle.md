---
id: ADR-0009
status: accepted
date: 2026-09-14
updated: 2026-09-14
decision-makers:
  - Daniel Vicory
consulted: []
informed:
  - Homelab operator
supersedes: []
superseded-by: []
modifies: []
modified-by: []
related-adrs:
  - ADR-0006
  - ADR-0008
related-specs:
  - storage-foundations
  - management-boundaries
related-changes:
  - first-class-state-protection
target-architecture:
  - docs/architecture/storage.md
---

# Delegate protection lifecycle while Den owns state semantics

## Context and Problem Statement

Homelab needs stable identities for durable state, explicit protection obligations, coverage checks, and recovery evidence across host filesystems, databases, containers, virtual machines, and Kubernetes storage. Existing backup and replication tools already own scheduling, snapshots, transfer, retention, repositories, checks, and application exports. A new shared state model must not duplicate those lifecycles.

The decision question is: **which responsibilities belong to Den and `homelab-preserve`, and which remain with established backup and replication tools?** The proposed normative behavior is in the active `first-class-state-protection` OpenSpec change; this record preserves the architecture choice and does not make that proposal current authority by itself.

## Decision Drivers

- Logical state identity must survive host, path, deployment, package, owner, and policy changes.
- Required routes and their coverage must fail closed when enabled and remain inspectable while plan-only.
- Production lifecycle behavior should reuse mature implementations rather than create a second backup engine.
- Restore must remain an explicit scratch operation, never an activation-time desired-state action.
- New owner integrations must remain independently implementable and testable.

## Considered Options

- Let Den resolve state semantics and delegate lifecycle execution to mature owners.
- Build a new coordinator-owned backup and replication lifecycle.
- Configure backend tools independently without a shared state identity or obligation model.

## Decision Outcome

Chosen option: **let Den resolve state semantics and delegate lifecycle execution to mature owners**, because it adds the Homelab-specific identity and policy layer without recreating scheduling, snapshot, transfer, retention, repository, or application-export machinery.

Den/gen owns stable state identity, slot/state/realization separation, instance policy and target resolution, route identity, coverage validation, capability selection, and owner-configuration projection. `homelab-preserve` may inspect those results, dispatch a fixed owner-level operation, enforce scratch boundaries, and verify evidence. Selected tools such as zrepl, Restic/resticprofile, and Borg/borgmatic retain their native lifecycle responsibilities. A direct-ZFS integration is permitted only as an explicitly fixture-only conformance reference.

This decision is additive to ADR-0006 and ADR-0008. It neither changes the semantic storage namespace nor makes disposable Kubernetes control-plane state durable.

### Consequences

- Good, because state identity and required protection remain stable while deployment and backend choices change.
- Good, because production lifecycle behavior uses software that already handles backend-specific failure and retention semantics.
- Good, because unsupported operations remain visible instead of being approximated by a generic workflow.
- Bad, because each lifecycle owner needs a thin capability, evidence, and safe-operation mapping.
- Bad, because owner-native point catalogs and status models cannot always be collapsed into one health value.
- Neutral, because production owner, target, cadence, retention, and topology choices remain separate decisions.

### Confirmation

Architecture remains conformant when state identity is independent of realization and owner configuration, every enabled route resolves to exactly one compatible owner, activation never restores data, and no Preserve component owns production scheduling, pruning, incremental replication, resumability, repository management, receiver lifecycle, or database dumping.

## Pros and Cons of the Options

### Den semantics with delegated lifecycle ownership

- Good, because it concentrates custom code on Homelab-specific identity, composition, and validation.
- Good, because owner-native operations and evidence remain intact.
- Bad, because integrations expose different capability and status shapes.

### Coordinator-owned backup and replication lifecycle

- Good, because one coordinator could present a uniform internal workflow.
- Bad, because it would duplicate mature scheduling, retention, transfer, repository, and consistency implementations.
- Bad, because generic compensation and retry behavior would silently acquire backend lifecycle ownership.

### Independent backend configuration without a shared model

- Good, because it adds no coordinator or integration protocol.
- Bad, because state identity, route obligations, coverage, and recovery evidence would remain backend-specific and difficult to validate fleet-wide.

## More Information

### Assumptions

- Mature lifecycle owners remain available for production use.
- Not every owner can provide every operation or consistency guarantee.
- Owner-native catalogs or durable metadata can satisfy source-independent recovery without one universal Preserve metadata store.

### Reconsideration Triggers

Revisit this decision if mature tools cannot express a required lifecycle, owner-native evidence cannot support source-independent recovery, or the common integration seam starts requiring owner-internal workflow stages.

### References

- OpenSpec change: `first-class-state-protection`
- OpenSpec: `storage-foundations`, `management-boundaries`
- Related ADR: [ADR-0006](0006-stable-semantic-storage-namespace.md)
- Related ADR: [ADR-0008](0008-disposable-control-plane-recovery.md)
- Target architecture: [`docs/architecture/storage.md`](../storage.md)
