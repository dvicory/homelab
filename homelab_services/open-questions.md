# Open questions and decision gates

These are intentionally unresolved. The architecture defines when and how to answer them.

## Phase 0 facts now established

- `hvn-hyp1` has seven 12 TB HDDs. Three temporary Btrfs/gocryptfs filesystems provide 36.00 TB raw and contain 20.83 TB of regular files; `bulk-2` and `bulk-3` contain additional hasty media copies but were not scanned as roots.
- All seven 12 TB disks may eventually become five mergerfs data disks plus two SnapRAID parity disks after unique-file reconciliation. The temporary filesystem, encryption, path, and naming scheme is not retained.
- Four physical 1 TB Intel NVMe devices are owned and two are installed. The installed devices currently expose approximately 100 GB namespaces; the boot `rpool` is 84% allocated.
- Application state and personal originals use separate physical mirror pools. Liberated 8 TB Proxmox disks are candidates for personal-data mirrors; owned NVMe devices are candidates for application-state mirrors.
- The R730xd has 12 storage slots. At most 11 may be occupied; one bay is permanently reserved for maintenance and replacement workflows.
- Both hosts have active 10GbE links on `172.27.50.0/24`.
- The old seven-disk RAIDZ2 pool is online but 98% allocated. No old Proxmox data has a verified backup plan, including the fileserver tree.

## Must answer before storage changes

1. Which exact enclosure slots contain every disk, what is each disk's SMART/NVMe health, and is the integrated `megaraid_sas` controller in a mode that preserves end-to-end disk error visibility?
2. What differs among old `/tank1/ds1/mccoy/media`, current `/mnt/storage/media`, `bulk-2`, and `bulk-3` by relative path, size, and targeted checksum?
3. What do the old Proxmox roots outside the scanned media subtree contain, especially `mccoy`'s 2.55 TB parent data, `kirk`'s 2.02 TB parent data, 2.17 TB of backups, and the unbacked 820 GB `spock/media` fileserver tree?
4. What namespace topology and controller operations expose the owned 1 TB NVMe capacity? Can root be enlarged without deleting its namespace, or is a staged reinstall required?
5. Which two NVMe devices form the application-state mirror, and do the remaining devices provide mirrored root, a single rebuildable root, or disposable cache?
6. Do personal originals initially need one 8 TB mirror (8 TB usable) or two mirror vdevs/pairs (16 TB usable)? Two pairs consume all four additional allowed slots and reach the 11-slot occupancy ceiling.
7. Which filesystem should live inside each bulk LUKS2 device: Btrfs for checksummed detection, or XFS/ext4 for a simpler SnapRAID stack?
8. Does critical ZFS use native encryption or LUKS2 under ZFS after comparing recovery keys, raw send, metadata exposure, and boot/unlock behavior?

## Must answer before nspawn commitment

1. Final guest name and reserved LAN/VLAN addresses.
2. Which NIC is bridged, what is its negotiated speed, and what out-of-band recovery path exists if bridge activation breaks host connectivity?
3. Can K3s run with a constrained cgroup v2/nspawn contract on the host's pinned systemd/kernel?
4. Can only the Intel DRM render device be exposed, without unintended BMC/host devices?
5. Does VA-API inside a pod support the required codec/tonemap paths on device `8086:56b1`?
6. Does K3s use embedded SQLite and clean GitOps rebuild, or embedded etcd snapshots? Decide from measured restore behavior.
7. What resource floor/ceiling should protect host storage/edge services from guest CPU, memory, I/O, and process exhaustion?
8. Does the accepted threat model allow the privileges required by nested K3s? If not, use a VM.

## Must answer before production networking

1. Which dual-10GbE NICs, PCIe slots/NUMA nodes, transceivers or DACs, and switch/router ports are available?
2. Does the initial host use LACP, active/backup bonding, routed links, or independent VLAN interfaces? Switch-restart survival generally requires failure domains beyond one LACP switch.
3. Which connection remains usable for iDRAC/management when either switch, router, bridge configuration, or one 10GbE link fails?
4. What switch and router models/configuration interfaces exist, and can LLDP expose the physical port map?
5. Which VLAN/IP plan keeps storage, cluster management, public ingress, household clients, and future VyOS transit separable without premature complexity?
6. What present router owns default gateway, DNS, DHCP, NAT, and public port forwarding?
7. What constraints must be reserved for a later VyOS routing VM and eventual HA peer: dedicated NIC/VLANs, virtual MAC/VIP support, state synchronization, and non-circular management?

## Must answer before GitOps implementation

1. Which externally available Git remote is authoritative during total cluster loss?
2. Is Nixidy deterministic and maintainable in this repository after porting only the minimum Sini patterns?
3. Argo CD full versus core installation; is the UI worth the additional public/private route and identity surface?
4. Does Envoy Gateway OIDC work for the chosen application versions and desired internal/public split?
5. Where are generated encrypted manifests stored, and what review/check prevents plaintext secret output?
6. Which operator identities can decrypt host agenix files and cluster SOPS files during disaster recovery?
7. How are guest SSH host key rotation and cluster SOPS key rotation rehearsed without losing access?

## Must answer before real application data

1. CloudNativePG local-PV restore versus guest systemd PostgreSQL restore: which has the smaller complete disaster-recovery procedure?
2. Should Radarr/Sonarr start with SQLite or PostgreSQL? Immich requires PostgreSQL regardless.
3. Exact Immich directory classification: which of `library`, `upload`, `thumbs`, `profile`, `encoded-video`, and `backups` are required for local restore versus regenerated?
4. Is an existing photo archive imported into Immich-managed storage or retained as a read-only external library?
5. Which Jellyfin clients must support SSO, and which require normal Jellyfin credentials?
6. Which public sharing semantics are needed from Immich versus the later document-sync application?
7. What upload/transcode concurrency should K3s resource reservations support?
8. Which paths should remain on one filesystem so future download/import workflows can use hardlinks and atomic renames?

## NAS software decision

Evaluate Nextcloud, Seafile, Syncthing, and plain SMB/WebDAV using real clients. Record:

- whether users primarily mount, sync, browse, or share links;
- iOS/Android background sync reliability;
- macOS/Windows/Linux filesystem behavior;
- OIDC and per-user/group authorization;
- offline conflicts and file locking;
- quotas and snapshots/previous versions;
- large-file and many-small-file performance;
- direct filesystem readability without the application;
- database and file backup consistency;
- full restore and export/exit path;
- operational load and upgrade rollback.

Default proposal: Samba for mounted shares plus Nextcloud for browser/mobile sync/share. Do not finalize until the restore/client trial.

## Public edge decisions

1. Canonical base domain and public DNS provider.
2. Which services are public at launch: likely Jellyfin and carefully scoped Immich routes only.
3. Whether edge or cluster terminates application TLS; avoid double ownership of the same certificate.
4. Router/firewall path and whether public traffic can be restricted by geography/rate without harming clients.
5. Whether household-only service names use split DNS, edge source ACLs, or both.
6. Email/notification path for identity recovery and platform alerts.

## Curated media selection — deferred interface

The later selective backup design must answer:

- selection source: explicit catalog, filesystem marker/xattr, directory boundary, or Radarr/Sonarr metadata;
- behavior when a selected file is renamed, upgraded, or moved between mergerfs branches;
- whether selected files are copied into a protected ZFS dataset or backed up in place;
- catalog privacy and portability while it remains local;
- deletion retention and deselection semantics;
- restore back into library paths without depending on a live Radarr/Sonarr database.

Do not implement this by merely backing up application databases: a catalog without payload is not a media backup.

## Later scale triggers

Revisit a second physical node/storage host when any occurs:

- planned maintenance must remain below the measured one-node outage;
- host CPU/RAM/device contention affects storage integrity or photo ingestion;
- database/public service availability becomes important during host maintenance;
- backup restore duration exceeds acceptable RTO;
- disk/enclosure scale exceeds safe operation in one chassis;
- untrusted workloads require a true VM/physical isolation boundary.
