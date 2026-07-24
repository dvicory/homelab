# Research: relevant Sini patterns

Reference tree: `~/src/den-examples/sini` as inspected on 2026-07-23.

## What Sini actually does

### Physical topology and Kubernetes

Sini's `axon` cluster is a three-node physical K3s cluster, not a nested single node. It defines distinct control-plane, pod, service, and load-balancer networks; a control-plane VIP; dual-stack Cilium; BGP-advertised load balancer addresses; etcd snapshots; and Longhorn. Those HA/network/storage mechanisms solve a materially different topology and should not be copied into one nspawn guest.

Cluster composition is declared at den cluster scope. The cluster includes Cilium, CoreDNS, cert-manager, SOPS Secrets Operator, Argo CD, Envoy Gateway, storage operators, monitoring, and the media applications.

### Storage boundaries

Sini separates three storage classes:

1. **NAS bulk media**: an external Synology NFS export becomes a statically declared RWX PV/PVC (`media-data-nfs`) with `Retain` and Argo prune/delete protection.
2. **Download scratch**: an NVMe cache dataset is exposed both as a node-pinned local PV for downloaders and as NFS for the other nodes.
3. **Application state**: Radarr/Sonarr config PVCs use Longhorn; their PostgreSQL databases use CloudNativePG.

The media pods use consistent paths: bulk media at `/data`, import scratch at `/scratch`, and application state at `/config`. Sini uses stable UID/GID `1027:65536` across the NAS, media pods, scratch export, and host Jellyfin.

This separation is directly reusable. The implementation technologies are not: this design replaces Longhorn with single-node local PVs backed by host ZFS and uses the host itself as the NFS server.

### Radarr and Sonarr

Both applications are rendered through Nixidy using the bjw-s app-template chart. Relevant patterns:

- pinned images;
- explicit health probes;
- PostgreSQL main/log databases;
- fixed API keys from encrypted cluster secrets;
- `/data`, `/scratch`, and `/config` storage separation;
- OIDC at Envoy Gateway, with the application set to trust external authentication;
- per-workload Cilium policies for gateway ingress, DNS, PostgreSQL, metrics, and internet egress;
- exportarr Prometheus sidecars and bounded file-log shipping;
- `Retain`/Argo prune protection for irreplaceable static PVs.

The observability sidecars and fine-grained policies are valuable later, but are not prerequisites for the first recoverable deployment. Health probes, stable paths, secret ownership, and storage separation are first-pass requirements.

### Jellyfin

Sini intentionally runs Jellyfin on the physical `uplink` NixOS host rather than Kubernetes. It mounts the NAS through NFS, uses declarative-jellyfin, runs as the shared media UID, exposes VA-API hardware acceleration, and terminates TLS at host nginx. Kanidm integration uses the Jellyfin SSO plugin and group-to-role claims.

This is evidence that accelerator locality and simple NAS access can justify placement outside the cluster. For this homelab, Jellyfin remains proposed in K3s to preserve one application lifecycle, but only after a mandatory Intel DRM/VA-API proof through host → nspawn → pod. Failure of that proof moves Jellyfin to its own independently SSH-managed nspawn guest, not silently onto the `hvn-hyp1` deployment lifecycle.

### Identity and access

Sini runs Kanidm on the `uplink` host and provisions OIDC clients declaratively. Group labels drive access and roles. Jellyfin uses native/plugin OIDC. Radarr, Sonarr, and most media UIs are protected by Envoy Gateway `SecurityPolicy` OIDC and trust the authenticated gateway identity. Kubernetes and Argo CD also use Kanidm OIDC. Applications retain deliberate bootstrap/break-glass paths where their initial setup cannot use OIDC.

This is a strong fit here:

- `media.access` for household use;
- `media.admins` for service administration;
- a future infrastructure-admin group for Kubernetes/Argo/host operations;
- native OIDC where it is reliable; gateway OIDC for administrative apps that lack adequate native support;
- local break-glass credentials stored in the recovery process, not used day-to-day.

### Public edge and Tailscale

Sini's canonical services use public DNS names and normal TLS. An `uplink` edge host runs nginx plus HAProxy. HAProxy inspects SNI, sends host-local names to nginx, and forwards other TLS traffic to the Kubernetes Envoy Gateway VIP. This supports normal browser/app access without requiring Tailscale.

Sini separately self-hosts Headscale and joins hosts to that tailnet. MagicDNS names are used for host administration and roaming host-to-host access. The cluster data plane explicitly excludes `tailscale0`. SSH has tailnet/LAN paths plus a documented break-glass route.

The reusable rule is: **Tailscale is an administrative/private transport, not the application naming or primary ingress architecture.**

### Secrets and GitOps

Sini has two connected secret systems:

- agenix/agenix-rekey generates and decrypts host/cluster bootstrap material;
- Nixidy renders `SopsSecret` resources, encrypted in Git, and SOPS Secrets Operator materializes Kubernetes Secrets.

The initial K3s node receives a cluster SOPS age key through agenix. Bootstrap units create the operator's key Secret, install networking and secret reconciliation, then install Argo CD. Argo CD reconciles generated manifests from Git. OIDC client secrets deliberately share one generated source between the Kanidm declaration and the Kubernetes consumer.

This architecture adopts the ownership boundary, but should not copy bootstrap commands without review. In particular, recovery-critical bootstrap operations should fail closed rather than broadly ignoring `kubectl apply` failures.

### Nixidy and Argo CD

Sini uses den aspects to emit typed Kubernetes manifest modules. Nixidy builds per-cluster output, generates CRD types, writes generated manifests, and exposes a sync command/pre-commit check. Argo CD owns live reconciliation and sync ordering.

This has higher initial implementation cost than hand-authored Helm, but it matches this repository's den structure, keeps Nix as the configuration language, and provides a mature application graph/UI. It is the recommended direction after a small bootstrap proof.

## What is absent from Sini

- No Immich deployment was found.
- Sini consumes a Synology NAS; it does not provide a reference for mergerfs/SnapRAID, ZFS data tiering, SMB, or a general NAS UI.
- It does not run K3s inside systemd-nspawn.
- Its Longhorn, three-node etcd, VRRP, BGP, thunderbolt fabric, and dual-stack details are inappropriate for the proposed single physical host.
- Its Jellyfin placement differs from the initial proposed placement here.

## Patterns to adopt

- Host/storage and Kubernetes application boundary.
- Static, retained NFS PVs for bulk data.
- Dedicated scratch, bulk, and app-state paths.
- Stable UID/GID and shared path contracts.
- Kanidm groups and OIDC, with break-glass accounts.
- Public DNS/TLS independent of tailnet access.
- Nixidy-generated manifests reconciled by Argo CD.
- Host agenix bootstrap leading to an independent encrypted cluster-secret lifecycle.
- Explicit bootstrap waves and restore-aware state protection.

## Patterns to reject or defer

- Longhorn, Ceph, or other replicated Kubernetes storage on one host.
- HA etcd, VRRP, BGP, multi-node overlay complexity.
- Full Sini observability stack before core backups and restore drills pass.
- Automatic acquisition applications in the first service wave.
- Copying UID `1027:65536`; this repository already reserves deterministic service IDs and should define an explicit shared media group instead.
