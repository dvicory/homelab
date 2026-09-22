## Context

This design defines a shared, replaceable unprivileged Incus compute guest,
secret-free guest artifacts, and declared maintenance boundaries. The
[isolation decision](../../../docs/architecture/decisions/0001-unprivileged-application-compute.md)
records the compute choice. The [delta spec](specs/compute-recovery/spec.md)
contains proposed guarantees; current specs remain authoritative.

Production inspection, secrets, deployment, and destruction require separate
authorization. Workload-specific manifests, routes, data, and runtime
acceptance belong to later cuts.

Nix/Den owns concrete configuration. Operational steps live in the downstream
operations runbook, not in this design.

## Ownership and lifecycle

- Host metadata stays in Den entities; aspects supply behavior through existing
  access, persistence, and secret-request conventions.
- NixOS preseed owns Incus projects, networks, profiles, and pools. Check for
  conflicts before first adoption: preseed can overwrite existing resources.
- `compute-guest` only inspects, creates, and explicitly replaces instances. It
  verifies effective configuration, retained prerequisites, identity, and image
  availability; it does not reconcile the envelope or know application
  details.
- Host activation, guest OS activation, and application release are separate.
  An unrelated host switch must not replace compute or require a guest build.
  NixOS deployment-frontend choice remains open.
- One host-side lock serializes guest mutation, identity staging, and operator
  maintenance. Acquire artifacts before destruction; distinguish absence from
  daemon/access errors; never delete the containing pool or retained paths.

## Mechanisms and trade-offs

- Use K3s with SQLite and its bundled Flannel/kube-proxy networking. Root
  inside the outer user namespace is not K3s's separate rootless launcher.
  Avoid a second containerd service or CNI without a demonstrated requirement.
- Use the standard overlayfs snapshotter on the ZFS-backed Incus root. Native
  snapshot copying repeatedly exceeded containerd unpack deadlines in the
  x86 fixture. Keep filesystem compatibility and the unchanged isolation
  boundary covered by platform checks; this is not fleet policy.
- Use a fixed non-root host ID translation so ownership survives deletion.
  Check for collisions; do not recursively change existing data ownership.
- Keep the container unprivileged with explicit grants. Do not add broad
  syscall interception, host sockets, writable host-global trees, or disabled
  confinement to obtain startup. Cilium/BPF delegation and hardware access
  require compatibility evidence and remain outside this slice.
- Keep the guest OS and platform manifests as separate artifacts. Normal
  delivery follows the tracked Git ref through Argo; a later workload cut may
  add application images and manifests without changing the guest OS.
- Keep retained storage and disposable workload manifests under explicit,
  non-overlapping owners. Do not give a second controller the same objects.

## Storage, identity, and access

Retain host-managed state and guest identity outside guest root and cluster
state. Workload-specific retained data and access projections are declared by
the later workload cut; this platform boundary does not select an application
layout or media path.

Required host paths fail closed: validate actual source mounts, not directory
existence, and deny access without exposing a substitute directory. Reattach
must work without restarting the node when the declaration permits it. Probes
alone do not provide that storage guarantee.

Stage identity through existing agenix/rekey ownership, atomically under the
lifecycle lock. Derive the public key from the private key before trusting it.
Missing or mismatched keys block SSH, not trigger generation. Host management
stays independent; host and guest SSH trust are verified separately.

Keep the operator-private management tunnel authenticated and encrypted.
Public service exposure, route inventories, identity origins, and shared
TLS are separate decisions owned by later edge/workload cuts.

## Maintenance and recovery

Declared outages are acceptable. Shared compute does not imply shared workload
placement, portable storage, or a highly available control plane. More nodes
alone provide none of those properties; multi-node maintenance requires a
capacity, drain, and storage review.

Use standard commands, not an application manager, plugin framework, or
automatic rollback controller. Compute replacement is an explicit operation
that validates retained inputs before destruction and leaves application
release selection to the delivery owner. Application data protection and
restoration are outside this change.

## Verification and deployment gates

Platform checks cover evaluated compute configuration, guest artifact
boundaries, runtime identity delivery, Argo bootstrap, and lifecycle
preconditions. They do not establish target boot, physical storage behavior,
application behavior, or destructive replacement.

With separate authorization, inspect actual host mounts, capacity,
kernel/cgroups/confinement, ID and route collisions, existing Incus resources,
and independent management access. Stop for any required permission or
isolation expansion; configuration evaluation cannot settle these.

Deployment and destructive replacement require separate authorization. The
later workload cut owns application setup, representative service operations,
and target-runtime replacement evidence. Local evidence does not prove
recovery from physical-host loss.
