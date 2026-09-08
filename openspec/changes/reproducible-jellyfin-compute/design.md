## Context

The operator approved a shared unprivileged Incus compute guest, persistent
Jellyfin, independent application releases, and declared maintenance outages.
[ADR-0001](../../../docs/architecture/decisions/0001-unprivileged-application-compute.md)
records the isolation choice. The [delta spec](specs/compute-recovery/spec.md)
contains the proposed guarantees; it is not current specification authority.
Production inspection, secrets, deployment, and destruction remain separately
authorized gates.

Nix/Den owns concrete configuration. Operational steps live in the
[household operations runbook](../../../docs/operations.md), not in this
design. Historical branches and Sini's configuration informed the choices but
do not establish contracts or supply a configuration bundle to transplant.

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
  to obtain startup. Cilium/BPF delegation and hardware access require separate
  compatibility evidence; they are deferred, not declared impossible.
- Bundle platform images with the guest. Deliver Jellyfin's pinned image and
  manifests as an independent Nix artifact through native K3s AddOns. No registry,
  Git server, secret operator, or GitOps controller inside the failed domain may
  be required to recover it. Pins still require retained artifact closures.
- Keep retained storage/namespace separate from disposable workload manifests.
  Native AddOn pruning applies to updated manifests; deleting a file alone is
  not resource retirement. Do not give a second controller the same objects.

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
that storage guarantee. Do not pre-grant future applications write access.

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
plane. Multi-node maintenance needs a later capacity/drain/storage review.

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

The tasks and disposable integration scenario own executable acceptance. Prove
fresh root/cluster state with the same Jellyfin user, library, recorded playback
state, and authorized media consumption without setup. Include failed identity,
unsafe drift, concurrency, independent OS/application delivery, native resource
retirement, media loss/return, and denied network/media access.

After separate permission, inspect actual host mounts/encryption, capacity,
kernel/cgroups/confinement, ID and route collisions, existing Incus resources,
media permissions, and independent management access. Stop for any required
permission/isolation expansion; configuration evaluation cannot settle these.

Deploy only after that gate. Prove real playback before obtaining guest-deletion
approval, then perform the destruction/rebuild acceptance twice. Local evidence
does not close those target gates or prove recovery from physical-host loss.
Independent backup and restore is a later capability, not an implied result.
