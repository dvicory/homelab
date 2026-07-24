# Phased roadmap

This is a decision and validation roadmap, not an OpenSpec work breakdown. Each phase has a hard exit gate. Do not start the next phase merely because manifests build.

## Phase 0 — inventory and destructive-risk controls

### Work

- Inventory every disk by enclosure/slot, stable ID, capacity, age, SMART data, filesystem, encryption layer, actual contents, and backup status.
- Collect comparable inventory from both partially configured `hvn-hyp1` and the old Proxmox host; classify each discovered copy as authoritative, duplicate, stale, or disposable before migration.
- Identify HBA/controller mode and whether disks are independently visible; record enclosure and power failure domains.
- Measure current pool usage, daily growth, Immich/photo import size, personal-file size, and expected three-year growth.
- Record both NVMe roles and decide whether the second current 1 TB Intel NVMe is available for guest/app state.
- Identify Intel GPU model/capabilities from PCI ID `8086:56b1`, firmware, supported codec matrix, and current `/dev/dri` nodes.
- Record active NIC link speeds, switch/VLAN capacity, selected bridge interface, router/firewall/DNS control, UPS state, and iDRAC recovery access.
- Validate the planned dual-10GbE path: NIC models/firmware, PCIe width and NUMA locality, transceivers/DACs, switch/router ports, VLANs, bonding/failover mode, and the management path during a switch restart.
- Preserve a later VyOS routing-VM/HA path without making it part of the initial critical path.
- Characterize off-site storage: protocol, capacity, bandwidth, retention, immutability/versioning, encryption, and cost.
- Freeze destructive storage changes until the inventory is reviewed.

### Decisions

- ZFS vdev topology and disk count for personal/app data.
- mergerfs/SnapRAID data/parity disk count for replaceable media.
- retain/migrate gocryptfs versus per-disk LUKS.
- guest name, LAN IP, VLAN, and resource reservations.

### Exit gate

A reviewed inventory maps every byte that could be destroyed. A disk-layout proposal demonstrates usable capacity after redundancy, one-disk and selected multi-disk failure behavior, expansion procedure, replacement time, and site-loss backup coverage.

## Phase 1 — nspawn platform feasibility spike

Use disposable state only.

### Work

- Build the smallest secret-free NixOS rootfs tar image from a dedicated guest flake output.
- Define host-owned import/provision/start units without `containers.*`.
- Create a private/staging bridge first; prove LAN bridge migration only after console/iDRAC recovery is ready.
- Inject a disposable guest SSH host/age identity from host agenix outside the Nix store.
- Deploy a new guest closure over SSH, roll back one generation, and replace the imported image while retaining a test persistence dataset.
- Install K3s and exercise cgroup v2, containerd/overlayfs, pod networking/DNS, local-path PVC, static NFS PV, graceful shutdown, and host reboot.
- Pass only the Intel DRM device; run `vainfo` in guest and pod, then transcode representative H.264, HEVC 10-bit, and AV1 samples.
- Document every nspawn capability, bind, device, cgroup, and sysctl required.
- Attempt the same smoke workload after removing each broad privilege; keep the least privilege that works.

### Fallback decision

Switch to a VM if K3s requires fragile host-global mutations, cgroup workarounds that break across systemd updates, or unacceptable host exposure. The storage/network/GitOps architecture stays unchanged.

### Exit gate

One script/runbook can import, provision, boot, SSH-deploy, run a pod, persist a PVC, mount NFS, use the GPU, reboot, roll back, and replace the guest. No plaintext key appears in the Nix store, image, logs, or world-readable host paths.

## Phase 2 — storage foundations

### Work

- Provision personal/app ZFS topology and datasets with explicit properties, quotas/reservations, snapshot policies, and mount ownership.
- Build mergerfs/SnapRAID on disposable sample data first. Prove data-disk loss recovery, parity-disk replacement, stale parity behavior, accidental deletion handling, content-file recovery, and scrub reporting.
- Migrate existing media only after the disposable proof and verified source backup/status.
- Configure deterministic shared groups, default ACLs, NFS exports restricted to the guest, and SMB shares restricted to LAN/tailnet.
- Prove macOS, Windows, and Linux SMB clients, filename behavior, permissions, large files, reconnects, and snapshots/previous versions if exposed.
- Create static Kubernetes PVs/PVCs with `Retain` and GitOps prune/delete protection.
- Create application-consistent backup staging and encrypted off-site transport for a synthetic dataset.

### Exit gate

Restore all of the following into an empty target: one ZFS file from snapshot, one full personal dataset from off-site, one failed SnapRAID data disk, SMB ACLs, and one static NFS PV attachment. Recorded duration meets provisional targets or the target is revised explicitly.

## Phase 3 — edge, identity, and secret bootstrap

### Work

- Deploy Kanidm on the host edge plane with declarative users/groups/OIDC clients and a tested backup/restore.
- Define `homelab.admins`, `media.admins`, `media.access`, `photos.access`, and `files.access`.
- Establish host nginx and HAProxy SNI routing with a non-sensitive test service.
- Join host and guest separately to Tailscale; prove both tailnet administration and LAN break glass.
- Restrict guest SSH, Kubernetes API, and future admin hostnames to approved LAN/tailnet sources.
- Generate separate guest machine and cluster SOPS identities; store offline-encrypted recovery copies.
- Prove bootstrap from host agenix to guest identity to SOPS Secrets Operator without plaintext Git/Nix artifacts.
- Prove recovery with Kanidm and Tailscale both unavailable.

### Exit gate

OIDC login and group authorization work for a test route. Public traffic cannot reach any admin surface. Host SSH, guest SSH/console, and Kubernetes break-glass access work during IdP/tailnet outage. Kanidm and secret keys restore on an empty test target.

## Phase 4 — GitOps bootstrap

### Work

- Port the minimum required den cluster schema/policies and Nixidy battery pattern from Sini rather than copying unrelated HA modules.
- Render deterministic manifests for namespace, one test application, static NFS storage, SOPS operator, Argo CD, and ingress.
- Bootstrap in explicit waves: K3s networking/DNS → secret operator/key → Argo CD → root application.
- Use an externally available Git remote; do not depend on an in-cluster Git server.
- Add a generated-manifest drift check and secret idempotency check.
- Test clean cluster deletion and re-bootstrap from Git plus recovery keys.
- Compare actual operational result with Flux before finalizing Argo. Retain Argo only if bootstrap and recovery remain straightforward.

### Exit gate

Starting with only host storage, a guest image, Git, and recovery keys, the test application becomes healthy through GitOps with no manual live edits. Re-running bootstrap is idempotent. A failed sync is visible and does not delete retained data.

## Phase 5 — database and backup contract

### Work

- Compare CloudNativePG on local PV with a single NixOS-managed PostgreSQL service in the guest. Measure backup/restore complexity rather than choosing by feature count.
- Select one PostgreSQL ownership model for Immich and optionally Radarr/Sonarr.
- Implement physical/logical backups, retention, encryption, and compatibility-pinned restore jobs.
- Decide whether K3s uses embedded SQLite with clean rebuild or embedded etcd with snapshots. Test the selected restore path.
- Add backup freshness/restore-test observability before application data arrives.

### Exit gate

A synthetic database is backed up, the cluster/guest state is destroyed, and the database is restored into a freshly bootstrapped platform within the target time. The restore procedure identifies exact application/database versions.

## Phase 6 — first service wave

Order minimizes irreplaceable-data risk.

### 6A. Radarr and Sonarr without acquisition

- Deploy config/database state, `/data`, and `/scratch` mounts.
- Enforce stable shared paths and permissions.
- Configure OIDC/gateway protection, local break-glass accounts, probes, and backups.
- Import/read a disposable sample library; do not connect download clients/indexers.

Exit: config/database restore works; neither service can write outside assigned media subtrees.

### 6B. Jellyfin

- Deploy with read-only media, local config, disposable transcode cache, and the proven Intel device path.
- Test direct play and forced transcode from LAN and remote networks using representative TV/mobile/browser clients.
- Validate native/plugin SSO without breaking client sign-in; retain a local recovery administrator.
- If nested GPU reliability fails, execute the separate Jellyfin guest fallback.

Exit: media playback survives pod restart and guest rollback; config restore works; GPU transcode is measured and stable.

### 6C. Immich

- Deploy against empty disposable data first.
- Classify all six Immich storage directories and attach managed originals plus read-only external archive.
- Validate mobile backup, public sharing, multi-user isolation, metadata, storage-template behavior, and OIDC/client compatibility.
- Restore originals plus database to a fresh Immich instance at a pinned version.
- Import real photos only after that restore succeeds.

Exit: a phone-uploaded asset, album/share metadata, and an external-library asset all survive the full restore drill. Off-site backup freshness meets target.

## Phase 7 — NAS user service

### Work

- Migrate household shares into per-user/shared ZFS datasets with quotas and ACLs.
- Establish SMB as the canonical mounted-share path; restrict remote mounting to Tailscale.
- Evaluate Nextcloud, Seafile, Syncthing, and plain WebDAV against real macOS/Windows/Linux/iOS/Android clients.
- Required evaluation: OIDC, multi-user sharing, offline sync, large files, conflict handling, filesystem exportability, server/database backup, restore, and upgrade rollback.
- Deploy the selected sync frontend on a dedicated dataset without sharing authority over Immich/media trees.

### Exit gate

A user can mount SMB locally, sync remotely, share a test document, recover an earlier version, and restore the account/files to a clean deployment. The chosen app's storage format and exit strategy are documented.

## Phase 8 — operations and public exposure

### Work

- Add minimum alerts for disks, ZFS, SnapRAID, backups, certificates, K3s, NFS, PVC capacity, database backups, and app readiness.
- Run host-loss tabletop and timed restore; then run an actual spare/sandbox restore.
- Create maintenance procedures for host NixOS, guest NixOS, K3s, Argo/controllers, databases, and applications with explicit rollback points.
- Expose only approved Jellyfin/Immich routes publicly; rate-limit and log at the edge without logging secrets.
- Keep all admin services private.
- Establish monthly file restores, quarterly application restores, and at least annual host/cluster rebuild exercises.

### Exit gate

A documented failure matrix links every critical component to detection, backup, restore owner, command/runbook, RPO, measured RTO, and last successful drill. Public exposure passes an external port/route review.

## Phase 9 — deferred ecosystem

Only after the earlier recovery gates:

- Prowlarr/indexers;
- download clients and VPN/egress isolation;
- request management;
- import automation and hardlink strategy;
- Recyclarr/config synchronization;
- curated-media selection/catalog and selective off-site backup;
- richer observability;
- Cilium/network-policy migration if still valuable;
- second physical Kubernetes node or storage host if availability requirements change.

Each addition must declare its storage tier, writer authority, secrets, ingress class, backup set, restore test, and failure impact before deployment.
