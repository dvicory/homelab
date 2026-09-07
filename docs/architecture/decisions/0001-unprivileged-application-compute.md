---
id: ADR-0001
status: accepted
date: 2026-09-06
updated: 2026-09-06
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
target-architecture: []
---

# Use an unprivileged Incus container for the first application-compute slice

## Context and Problem Statement

Homelab needs to move beyond a configured hypervisor to a persistent service whose compute environment can be deleted and rebuilt. The operator selected an unprivileged Incus system container rather than the proposed VM, with a new private Jellyfin instance as the first workload and no deployment authorized yet.

The existing [management](../../../openspec/specs/management-boundaries/spec.md), [storage](../../../openspec/specs/storage-foundations/spec.md), and [secret](../../../openspec/specs/secret-management/spec.md) contracts constrain the integration. The stronger compute-recovery guarantees are proposed in [the active change](../../../openspec/changes/reproducible-jellyfin-compute/specs/compute-recovery/spec.md), not current specification authority.

## Decision Drivers

- The operator explicitly requires an unprivileged container.
- The physical host retains storage lifecycle and a recovery path independent of Kubernetes.
- Guest replacement must not require retaining its root or cluster database.
- Direct host storage attachment is useful for this first media workload.
- Runtime success must not be obtained by quietly weakening isolation.

## Considered Options

- Unprivileged Incus system container.
- Incus VM with a separate kernel.
- systemd-nspawn based on historical planning.
- Kubernetes directly on the physical host.

## Decision Outcome

Chosen option: **an unprivileged Incus system container for this first slice**, following the operator's explicit selection. This is not a claim of VM-equivalent isolation or a decision that every future Kubernetes node must be a container.

Guest root must remain distinct from host root. Host-granted storage, devices, nesting permissions, syscall mediation, and resource limits must be explicit. If Kubernetes cannot run within the reviewed boundary, report the failed constraint and return for an architectural decision; do not enable privileged mode, map guest root to host root, disable confinement wholesale, or add unrestricted host mounts as a workaround.

This ADR does not settle the Kubernetes distribution, CNI, ingress implementation, identity platform, distributed storage, or future fleet topology. Those mechanisms remain proposed in the active change or deferred. No accepted ADR in the current checkout is being superseded; old nspawn documents on `initial-k8s` are historical design input, not an accepted decision imported into this checkout.

### Consequences

- Good: the selected environment supports a lightweight host-managed lifecycle and explicit storage bindings.
- Good: future workloads need not run as services of the physical NixOS host.
- Bad: the host kernel remains shared; a compromised guest still attacks a shared kernel surface. This is not the isolation choice for arbitrary hostile tenants.
- Bad: nested Kubernetes, CNI, storage ownership, cgroups, and container runtime behavior require verification against the actual host kernel and filesystem stack.
- Neutral: a future VM migration can retain higher-level recovery and storage-interface contracts, but will require new attachment and lifecycle implementation.

### Confirmation

Inspect the effective runtime configuration and actual UID/GID mappings, not only the declared profile. Exercise nested workload startup and guest replacement without increasing authority. Treat local Nix evaluation as configuration evidence, not runtime conformance.

## Pros and Cons of the Options

### Unprivileged Incus system container

Matches the requested boundary and makes host path attachment straightforward. Its shared kernel and user-namespace restrictions remain consequential limitations; nesting is not a generic compatibility guarantee.

### Incus VM

Provides a separate kernel and a more conventional environment for Kubernetes networking. It costs additional memory and requires different storage/device attachment. It was recommended as an alternative and not selected by the operator.

### systemd-nspawn

Would reuse the runtime favored by older planning, but that planning does not establish a validated unprivileged Kubernetes boundary. Existing Hermes nspawn integration does not justify copying its isolation model into this slice.

### Kubernetes on the physical host

Avoids nesting but makes the physical storage and management host the application node. It does not meet the requested isolated-compute direction.

## More Information

### Reconsideration Triggers

- Kubernetes requires authority outside the accepted unprivileged boundary.
- BPF networking or hardware access cannot be narrowly delegated and verified.
- Hostile multi-tenancy or stronger kernel isolation becomes a requirement.
- Container compatibility failures or lifecycle complexity exceed the cost of a VM migration.

### References

- [Kubernetes node components in a user namespace](https://kubernetes.io/docs/tasks/administer-cluster/kubelet-in-userns/)
- [Incus UID/GID mappings](https://linuxcontainers.org/incus/docs/main/userns-idmap/)
- [Incus BPF delegation](https://linuxcontainers.org/incus/docs/main/explanation/bpf-tokens/)
