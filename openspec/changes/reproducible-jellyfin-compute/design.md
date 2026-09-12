## Context

The design uses a shared unprivileged Incus compute guest, persistent Jellyfin,
independent application releases, and declared maintenance outages.
[ADR-0001](../../../docs/architecture/decisions/0001-unprivileged-application-compute.md)
records the isolation choice. The [delta spec](specs/compute-recovery/spec.md)
contains proposed guarantees; current specs remain authoritative.
Production inspection, secrets, deployment, and destruction require separate
authorization.

Nix/Den owns concrete configuration. Operational steps live in the
[household operations runbook](../../../docs/operations.md), not in this design.

## Ownership and lifecycle

- Host metadata stays in Den entities; aspects supply behavior through existing
  access, persistence, and secret-request conventions.
- NixOS preseed owns Incus projects, networks, profiles, and pools. Check for
  conflicts before first adoption: preseed can overwrite existing resources.
- `compute-guest` only inspects, creates, and explicitly replaces instances. It
  verifies effective configuration, retained prerequisites, identity, and image
  availability; it does not reconcile the envelope or know application details.
- Host activation, guest OS activation, and application release are separate.
  An unrelated host switch must not replace compute or require a guest build.
  NixOS deployment-frontend choice remains open.
- One host-side lock serializes guest mutation, identity staging, and operator
  maintenance. Acquire artifacts before destruction; distinguish absence from
  daemon/access errors; never delete the containing pool or retained paths.

## Mechanisms and trade-offs

- Use K3s with SQLite and its bundled Flannel/kube-proxy networking. Root inside
  the outer user namespace is not K3s's separate rootless launcher. Avoid a
  second containerd service or CNI without a demonstrated requirement.
- Start with the native snapshotter to avoid assuming overlay/FUSE compatibility
  on the backing filesystem. This costs disk space and unpack speed; it is not
  a fleet-wide policy or a hard per-instance disk quota.
- Use a fixed non-root host ID translation so ownership survives deletion. This
  avoids assuming idmapped-mount support through mergerfs/gocryptfs. Check for
  collisions; do not recursively change existing data ownership.
- Keep the container unprivileged with explicit grants. Do not add broad syscall
  interception, host sockets, writable host-global trees, or disabled confinement
  to obtain startup. Cilium/BPF delegation and hardware access require
  compatibility evidence and remain outside this slice.
- Keep the guest OS and application manifests as separate artifacts. The
  `prod-home-replacement` acceptance uses the shipped
  `household-bootstrap-host`, a disposable Git origin, and real registry pulls
  for pinned images; Git and registry access during rebuild is an accepted
  dependency. No offline image bundle is a supported recovery path.
- Keep retained storage/namespace separate from disposable workload manifests.
  The selected reconciler owns workload resources, and retained resources are
  protected from pruning and deletion. Do not give a second controller the same
  objects.

## Storage, identity, and access

Retain complete application state and host-managed identity outside guest root
and cluster state. Keep initial Jellyfin setup in retained application data,
not Nix literals or a repeated bootstrap procedure. Media stays on its existing
host storage, read-only to Jellyfin; cache and cluster state are disposable.
Do not change physical storage or legacy Hermes for this slice.

Stable read-only export parents and native mount propagation separate media
availability from node boot. Validate actual source mounts, not directory
existence. Loss must deny access without exposing a substitute directory;
reattachment must work without restarting the node. Probes alone do not provide
that storage guarantee. Do not pre-grant write access to applications not
declared in this slice.

Stage identity through existing agenix/rekey ownership, atomically under the
lifecycle lock. Derive the public key from the private key before trusting it.
Missing/mismatched keys block SSH, not trigger generation. Host management stays
independent; host and guest SSH trust are verified separately.

Use an operator-private, loopback-bound SSH tunnel. Keep the physical uplink and
existing management network unchanged. Enforce both routed and same-bridge
traffic: NAT, NodePort, and host INPUT rules alone do not establish privacy.
Household/public access and shared routing/TLS remain separate decisions.

## Maintenance and recovery

Declared outages are acceptable. Shared compute does not imply shared workload
placement: Jellyfin may remain storage-host-bound; other applications need not.
More nodes alone provide neither portable storage nor a highly available control
plane. Multi-node maintenance requires a capacity, drain, and storage review.

Use standard commands, not an application manager, backup engine, plugin
framework, or automatic rollback controller. Before an application upgrade,
retain matching software, pause reconciliation, stop and verify all writers,
check capacity, and copy complete state preserving ownership/modes. Publish
completion only after durable copy. A partial copy is not a recovery point.

Explicit restore pairs data with software, checks completeness before mutation,
and preserves displaced data. Copy into the retained bind mount; do not rename
it. Restoring discards subsequent application changes, not read-only media.
Binary downgrade alone is not database rollback. Preserve older complete points
until explicitly retired. Same-host retention is not independent backup.

## Verification and deployment gates

The executable replacement acceptance is
`modules/tests/prod-home-replacement.nix`
(`checks.prod-home-replacement`), driven by
`modules/tests/prod-home-replacement.py`; it delegates application behavior to
`modules/tests/jellyfin_smoke.py`. Its x86_64 Linux runtime has not yet
established acceptance. The configured four-hour timeout is a safety ceiling,
not a measured runtime.

Run it on an appropriate x86_64/KVM runner and record derivation/build
preparation, fixture-host startup, compute guest creation, registry image
pulls, first Argo reconciliation, media loss/return, compute replacement, and
second Argo reconciliation. Local evaluation or build output does not close
target boot, storage, or destructive-replacement evidence.

With separate authorization, inspect actual host mounts/encryption, capacity,
kernel/cgroups/confinement, ID and route collisions, existing Incus resources,
media permissions, and independent management access. Stop for any required
permission/isolation expansion; configuration evaluation cannot settle these.

Deployment and destructive replacement require separate authorization. Prove real
playback before destruction, then perform the destruction/rebuild acceptance.
Local evidence does not close those target gates or prove recovery from
physical-host loss. Independent backup and restore is outside this change.
