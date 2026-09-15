---
id: ADR-0001
status: accepted
date: 2026-09-06
updated: 2026-09-08
decision-makers:
  - Daniel Vicory
consulted: []
informed: []
supersedes: []
superseded-by: []
modifies: []
modified-by: []
related-adrs: []
related-specs:
  - management-boundaries
  - storage-foundations
  - secret-management
related-changes:
  - reproducible-jellyfin-compute
  - reliable-household-services
target-architecture: []
---

# Use an unprivileged Incus container for the first compute slice

## Context and decision drivers

Homelab needs isolated application compute whose persistent service survives
loss of guest root and cluster state. The physical host retains storage
ownership and an independent management/recovery path. The operator explicitly
selected an unprivileged container with Jellyfin as the first workload.

## Considered options

- **Unprivileged Incus container:** straightforward host storage attachment, but
  shares the host kernel and requires nested-runtime compatibility checks.
- **Incus VM:** stronger kernel separation and conventional Kubernetes runtime;
  higher memory cost and different storage/device attachments. Not selected.
- **systemd-nspawn:** historical planning did not establish the required
  unprivileged Kubernetes boundary; legacy Hermes is not a precedent for it.
- **Kubernetes on the physical host:** avoids nesting but defeats compute isolation.

## Decision outcome

Use an **unprivileged Incus system container for this slice**. Do not interpret
this as VM-equivalent isolation, suitability for hostile tenants, or a mandate
for every future node. Guest root stays distinct from host root; host grants
remain explicit. If the workload needs greater authority, return for a decision
rather than enabling privileged mode, unrestricted mounts, or disabled confinement.

This choice does not settle CNI, ingress, identity platform, distributed storage,
or future topology. Existing [management](../../../openspec/specs/management-boundaries/spec.md),
[storage](../../../openspec/specs/storage-foundations/spec.md), and
[secret](../../../openspec/specs/secret-management/spec.md) contracts still apply.
The [compute-recovery delta](../../../openspec/changes/reproducible-jellyfin-compute/specs/compute-recovery/spec.md)
is proposed authority, not a current spec. No accepted decision is superseded.

### Consequences and confirmation

Host-managed lifecycle and storage bindings stay simple, but kernel, cgroup,
filesystem, and nested-runtime compatibility must be demonstrated. Inspect actual
UID/GID maps and effective grants; exercise workload startup and replacement
without expanding authority. Local evaluation is not target runtime evidence.
A future VM migration can retain higher-level recovery contracts while replacing
attachment and lifecycle implementation.

### Reconsider when

The workload needs authority outside this boundary, BPF/hardware access cannot
be narrowly delegated, stronger tenant isolation is required, or container
compatibility costs exceed a VM migration.


## Later context (2026-09-08)

On 2026-09-08, the operator approved a planning refinement in
[reliable-household-services](../../../openspec/changes/reliable-household-services/proposal.md)
that distinguishes routine application-scoped capture from destructive restore
and guest replacement. Routine capture should use supported online tools first,
coordinate only writers required for the affected application's consistency set,
and leave unrelated services and the compute guest running; temporary writer
pauses must be released when safe, and failures to resume must be reported. Destructive restore and guest
replacement remain separately authorized operations with their own interruption
expectations. This clarifies recovery handling within the accepted compute
boundary; it does not change the unprivileged-container decision, promise
zero-downtime replacement, or make same-host captures independent backups. The
active change and its
[household-services](../../../openspec/changes/reliable-household-services/specs/household-services/spec.md)
delta remain proposed authority; the current management, storage, and secret
contracts remain authoritative.