# Sources and evidence

Inspected 2026-07-23. Repository paths are local evidence; external links are primary project documentation where available.

## Current repository

- `modules/den/hosts/hvn-hyp1/default.nix`
  - `172.27.50.17/24` on `eno1`.
  - single-device `rpool` declaration on `/dev/nvme0n1`.
  - mergerfs media pool over three gocryptfs cleartext mounts.
  - fourth LUKS/Btrfs media disk declared but `provisioned = false`.
  - Tailscale, agenix, Incus, impermanence, and mergerfs aspects included.
- `modules/den/hosts/hvn-hyp1/facter.json`
  - two CPU packages, 14 cores each and 56 aggregate threads represented by the inventory;
  - about 224 GiB usable memory;
  - two installed Intel NVMe devices whose model identifies 1 TB hardware; runtime block topology exposes approximately 100 GB namespaces;
  - four Intel Ethernet interfaces plus iDRAC;
  - Intel display PCI device `8086:56b1` using `i915`, plus embedded Matrox display.
- Owner-supplied inventory and policy:
  - four physical 1 TB NVMe devices are owned, with two installed;
  - R730xd has 12 storage slots but at most 11 may be occupied;
  - `bulk-2`/`bulk-3` contain hasty media copies, are now imported as single-disk pools, and may be repurposed only after reconciliation;
  - current gocryptfs/naming is temporary; kernel-space encryption is preferred;
  - all old Proxmox data, including the fileserver tree, currently lacks a verified backup plan;
  - application state and personal originals should use separate mirror pools; liberated 8 TB disks are available after evacuation.
  - old Proxmox remains an unchanged same-site static rollback copy after migration; off-site integration is outside the current roadmap.
- `homelab_services/phase0-hvn-hyp1-nvme-20260724T104514Z/`
  - verified imported-pool topology and NVMe controller/namespace capacity.
- `homelab_services/phase0-dia-20260724T103518Z/`
  - verified Docker/Compose topology and persistent bind/volume roots without environment values.
- `modules/den/aspects/services/mergerfs.nix`
  - host-owned mergerfs service with live branch reload.
- `modules/den/aspects/core/network/tailscale.nix`
  - host Tailscale identity persists and bootstrap auth key comes from agenix.
- `modules/den/aspects/services/hermes.nix`
  - existing NixOS `containers.*` nspawn pattern and agenix bind; useful evidence but deliberately not the desired K3s lifecycle.
- `modules/den/aspects/core/users/deterministic-uids.nix`
  - this repository already reserves IDs for Kanidm, Headscale, Jellyfin, Radarr, Sonarr, Samba, and NFS.

## Sini reference repository

- `~/src/den-examples/sini/modules/den/clusters/axon.nix`
  - three-node K3s topology, NFS volumes, cluster services, media app composition.
- `.../aspects/services/k3s/k3s.nix`
  - K3s flags, OIDC, etcd snapshots, Cilium replacement of built-ins, agenix cluster token/SOPS key, persisted K3s state.
- `.../aspects/services/k3s/bootstrap.nix`
  - explicit bootstrap waves for CNI/CoreDNS, SOPS operator/key, cert-manager, and Argo CD.
- `.../aspects/kubernetes/services/media/base.nix`
  - retained static NFS bulk PV, local/NFS scratch split, stable PVC contracts.
- `.../aspects/kubernetes/services/media/sonarr.nix`
- `.../aspects/kubernetes/services/media/radarr.nix`
  - PostgreSQL, `/data` and `/scratch`, probes, API secrets, gateway OIDC, network policies, metrics/logging;
  - these manifests declaratively deploy infrastructure but do not own the full in-application TRaSH/quality/profile configuration.
- `.../aspects/services/media/jellyfin.nix`
  - host placement, NFS media mount, declarative configuration, VA-API, SSO plugin, nginx.
- `.../aspects/services/storage/media-data-share.nix`
- `.../aspects/services/storage/media-scratch.nix`
  - NFS client and scratch exporter patterns with stable IDs.
- `.../aspects/services/security/kanidm.nix`
  - declarative OIDC clients and group-to-scope/role mapping for Jellyfin, Kubernetes, Argo, Radarr, Sonarr, and other services.
- `.../aspects/services/networking/headscale.nix`
- `.../aspects/core/network/tailscale/tailscale.nix`
  - self-hosted tailnet, OIDC, MagicDNS, and host administrative mesh.
- `.../aspects/services/networking/haproxy.nix`
  - SNI split between host nginx and Kubernetes ingress.
- `.../den/batteries/nixidy.nix`
  - per-cluster generated manifests, CRD type generation, Nixidy sync/check workflow.
- `.../aspects/kubernetes/services/security/sops-secrets-operator/sops-secrets-operator.nix`
  - cluster SOPS age key mounted into the operator.

## External primary documentation

### systemd-nspawn and NixOS images

- [systemd-nspawn](https://www.freedesktop.org/software/systemd/man/systemd-nspawn.html) — image boot, settings, and credential mechanisms.
- [machinectl](https://www.freedesktop.org/software/systemd/man/machinectl.html) — import/start/image lifecycle and `/var/lib/machines` conventions.
- [NixOS Manual: building images](https://nixos.org/manual/nixos/stable/#sec-building-image-instructions) — current NixOS image build interface.

### K3s and networking

- [K3s requirements](https://docs.k3s.io/installation/requirements) — operating-system, network, and cgroup prerequisites.
- [Cilium installation on K3s](https://docs.cilium.io/en/stable/installation/k3s/) — official replacement-CNI procedure and validation. This is a later option, not the initial recommendation.

No official source found a complete supported K3s-inside-nspawn privilege contract. That uncertainty is why the roadmap requires a feasibility spike and retains a VM fallback.

### GitOps

- [Flux documentation](https://fluxcd.io/flux/) and [Flux installation/bootstrap](https://fluxcd.io/flux/installation/) — controller model, idempotent bootstrap, and self-management.
- [Argo CD overview](https://argo-cd.readthedocs.io/en/stable/) and [installation modes](https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/) — reconciliation/UI model and full/core options.
- [Argo CD secret management](https://argo-cd.readthedocs.io/en/stable/operator-manual/secret-management/) — destination-side secret population can remain independent of Argo itself.

### Media application configuration

- [TRaSH Guides](https://github.com/TRaSH-Guides/Guides) — actively maintained, developer-collaborated guidance for Radarr, Sonarr, download clients, path design, quality profiles, and custom formats; retained as the policy source.
- [Recyclarr](https://github.com/recyclarr/recyclarr) — synchronizes TRaSH quality profiles, custom formats/scores, quality definitions, naming, and media-management settings for Radarr/Sonarr.
- [Configarr](https://github.com/raydak-labs/configarr) and its [Kubernetes installation](https://configarr.de/docs/installation/kubernetes/) — broader custom configuration with documented CronJob deployment; alternative when Recyclarr's supported field set is insufficient.
- [Nixflix](https://github.com/kiriwalawren/nixflix) — NixOS modules using application APIs for idempotent Jellyfin/Arr configuration. Useful reference, but its direct runtime model is NixOS services rather than Kubernetes.

### Recovery and native backups

- [Proxmox VE Backup and Restore](https://pve.proxmox.com/wiki/Backup_and_Restore) — snapshot-mode VM backups use a running QEMU guest agent to freeze/thaw filesystems; external host paths still require separate protection.
- [Radarr FAQ: backing up and restoring](https://wiki.servarr.com/radarr/faq) — built-in **System → Backup** workflow and restore expectations; Sonarr uses the corresponding Servarr pattern.
- [Nextcloud backup](https://docs.nextcloud.com/server/stable/admin_manual/maintenance/backup.html) and [restore](https://docs.nextcloud.com/server/stable/admin_manual/maintenance/restore.html) — maintenance mode plus configuration, data, application, and database preservation.
- [Immich backup and restore](https://docs.immich.app/administration/backup-and-restore) — the database is authoritative metadata and must be preserved with the asset library; the library is not reconstructed by scanning alone.

### Filesystem catalog

- [rclone `lsjson`](https://rclone.org/commands/rclone_lsjson/) — machine-readable recursive JSON listing with path, size, and modification time; hashes are omitted unless `--hash` is requested.
- [rclone local backend](https://rclone.org/local/) — local-path behavior, symlink handling, and filesystem-boundary controls.

### Immich

- [Immich external libraries](https://docs.immich.app/features/libraries) — read-only external archive mounts and library behavior.
- [Immich custom locations](https://docs.immich.app/guides/custom-locations) — storage path customization and warning about separate `upload`/`library` bind mounts on one device.
- [Immich TrueNAS community installation](https://docs.immich.app/install/truenas/) — six storage areas: `library`, `upload`, `thumbs`, `profile`, `encoded-video`, and `backups`.
- [Immich post-installation](https://docs.immich.app/install/post-install) — storage templates, migration, mobile upload, and external-library setup.

### SnapRAID and ZFS

- [SnapRAID FAQ](https://www.snapraid.it/faq) — parity sizing, deletion/change recovery implications, and recovery behavior.
- [SnapRAID manual](https://www.snapraid.it/manual) — asynchronous parity limitations and suitability for infrequently changing data.
- [OpenZFS checksums](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Data%20Storage/Checksums.html) — stored/replicated data integrity.
- [OpenZFS snapshot semantics](https://openzfs.github.io/openzfs-docs/man/v0.8/8/zfs.8.html) — read-only point-in-time snapshots.
- [OpenZFS receive](https://openzfs.github.io/openzfs-docs/man/master/8/zfs-receive.8.html) — remote full/incremental replication and resumable receive behavior.

## Evidence limitations

- Repository facter data may not represent disks that were detached or added after capture.
- PCI ID establishes the Intel device identity but not proven codec/VA-API behavior through nspawn and Kubernetes.
- Sini is a pattern reference, not proof that its versions or bootstrap commands apply unchanged here.
- External documentation establishes product capabilities, not that the proposed combination works on this host. Every significant combination has a roadmap proof/restore gate.
