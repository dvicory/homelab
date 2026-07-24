# Goals, non-goals, and constraints

## Priority order

1. Recoverability.
2. Learning value from a production-like Kubernetes/GitOps design.
3. Low maintenance.
4. Availability within the limits of one physical host.

Planned maintenance should normally remain under one hour. Physical-host failure remains an outage; the architecture optimizes for deterministic restoration rather than pretending a single host is highly available.

## Required services

Initial application scope:

- Jellyfin, including hardware transcoding.
- Radarr.
- Sonarr.
- Immich, including mobile upload and durable originals.
- General NAS access for mixed desktop/mobile clients.
- User-private and shared file areas.
- A document sync/share frontend, with software still to be chosen.

Expected ancillary platform services include ingress, DNS/TLS integration, identity, GitOps, secret reconciliation, PostgreSQL, backup/export jobs, monitoring, and storage health checks. Automated acquisition services such as Prowlarr, qBittorrent/SABnzbd, request management, and import automation are deferred until the core is stable.

## Users and access

- One administrator initially; preserve a clean path to multiple administrators.
- Household users need private and shared data areas.
- Friends/family may access selected Jellyfin or Immich sharing surfaces without joining a VPN.
- Private remote access remains available.
- Selected services may be public, but administrative surfaces must not be public.
- Tailscale should connect hosts and provide administrative/private reachability, not become the canonical URL or mandatory access path for ordinary users.

## Failure model

Documented recovery must cover:

- loss of `hvn-hyp1`;
- loss of one or more storage devices within the selected redundancy design;
- operator error and accidental deletion;
- failed guest OS, K3s, and application upgrades.

Site loss is explicitly not covered by this roadmap. Old Proxmox remains an unchanged same-site migration rollback/static copy after cutover; it supplies no ongoing RPO for new writes. Off-site integration is a separate future project.

## Scale and hardware

- Plan for 20–100 TB over approximately three years.
- Hardware expansion is allowed and expected.
- Phase 0 reports identify `hvn-hyp1` as a Dell PowerEdge R730xd with 2 × 14-core Xeon E5-2690 v4 CPUs (56 threads), 220 GiB reported RAM, an active 10GbE `eno1` link at `172.27.50.17/24`, and Intel display device `8086:56b1` using `i915` plus the embedded Matrox adapter.
- The chassis has 12 front storage slots, but normal design occupancy must never exceed 11. Keep one compatible bay physically free for maintenance, replacement, migration, and temporary attachment.
- Four 1 TB Intel NVMe devices are available and two are installed. The report sees approximately 100 GB namespaces on each installed device; the boot `rpool` occupies one such namespace and is 84% allocated with 70% fragmentation. Namespace inventory, safe root expansion/reinstallation, and allocation of a separate NVMe mirror must be designed before durable application state is placed.
- Seven 12 TB HDDs are attached. Three temporary single-device Btrfs/gocryptfs filesystems provide 36.00 TB raw, 21.04 TB used, and 14.96 TB estimated free through mergerfs. Two ZFS-labeled disks (`bulk-2`, `bulk-3`) contain a few terabytes of hasty media backup and may be repurposed only after their unique files are reconciled. Two more disks have no recognized filesystem. No SnapRAID parity exists today.
- The present names, Btrfs/gocryptfs layering, and branch assignment are migration scaffolding, not target contracts. Target bulk disks use kernel-space encryption and a newly designed stable-ID/label scheme.
- The old Proxmox host has an online seven-disk 8 TB RAIDZ2 pool at 98% allocation; the scanned media dataset is at 100% and contains 195,567 files totaling 30.24 TB logical. It also contains multiple unclassified non-media datasets, backups, file-server data, and VM state. Treat it as an authority candidate under immediate capacity pressure, not as a disposable legacy host.
- `hvn-hyp1` holds a hasty partial media copy. Its 21.04 TB physical usage versus the old corpus's 30.24 TB logical size does not establish exact overlap or completeness; path/size manifests and targeted checksums must classify both copies before migration.
- Nothing on old Proxmox currently has a verified independent backup. Its mostly static fileserver data is accepted temporarily at this risk. After verified migration, preserve old Proxmox unchanged as the same-site static rollback copy until a separate off-site project is authorized.
- Both hosts currently negotiate 10GbE on `172.27.50.0/24`. Target dual 10GbE remains desirable, preferably across independent switch/router failure domains; exact bonding/routing/VLAN and physical topology still require switch/router evidence.
- A future VyOS routing VM and eventual router HA must remain possible, but neither is a dependency for the first storage/K3s deployment.

## Storage intent

- High-churn or irreplaceable data: ZFS datasets on RAID1-style mirror vdevs, local snapshots, integrity checking, application-consistent exports, and the temporary static Proxmox copy where applicable. RAIDZ and dRAID are explicit non-goals.
- Large low-churn replaceable media: independent data filesystems combined with mergerfs and protected by SnapRAID parity.
- Flexibility and incremental expansion matter: grow critical storage by mirror pairs and bulk storage by individual data/parity disks.
- Separate physical pools are preferred: NVMe mirrors for critical application state and HDD mirrors for personal originals/files. Reuse liberated 8 TB Proxmox disks for HDD mirrors after evacuation; do not buy additional 12 TB disks for the initial layout.
- Prefer dual SnapRAID parity for bulk media. Single parity is acceptable only after explicit failure-risk acceptance and classification of hard-to-reacquire media; future selective backup is outside this roadmap.
- Replace userspace gocryptfs with kernel-space encryption: per-disk LUKS2 for independent bulk filesystems and ZFS native encryption or a justified LUKS2-under-ZFS design for critical mirrors.
- Local parity/redundancy is not a backup.
- Kubernetes must not own physical-disk or array lifecycle.

## Platform intent

- One K3s node; no multi-node HA in the first architecture.
- The K3s node is a NixOS systemd-nspawn machine.
- Do not use the NixOS `containers.*` abstraction for this node.
- `hvn-hyp1` owns image import and runtime wiring only. Guest configuration and routine upgrades are separate flake outputs deployed over SSH.
- Bootstrap begins from an imported image and host-provided agenix material.
- No Ceph, Rook, Longhorn, or equivalent cloud-native replicated block-storage system on one physical host.
- No publicly reachable Kubernetes API, SSH, GitOps UI, metrics UI, Radarr, Sonarr, or NAS administration surface.

## Initial conservative service targets

These are architecture defaults, not promises until restore drills prove them.

| Data/service tier | Local protection target | Temporary secondary-copy position | Restore target |
|---|---|---|---:|
| Identities, secret recovery material, Git configuration | redundant encrypted copies plus offline recovery copy | offline recovery material; not dependent on Proxmox | 4 hours |
| Personal photos and files | hourly snapshots and ZFS mirrors | static Proxmox copy only where migrated data existed there; no ongoing RPO | 24 hours |
| Application databases/configuration | application-consistent backup at least every 6 hours plus local snapshots | legacy exports retained on static Proxmox at cutover; no ongoing RPO | 8 hours |
| Curated media subset | catalog/classification only in this roadmap | no separate payload backup | best effort |
| Replaceable movies/TV | SnapRAID parity and scrub | pre-migration Proxmox corpus retained unchanged | best effort / reacquire |
| Caches, thumbnails reproducible from originals, transcodes, downloads | none or short local retention | none | rebuild |

These targets deliberately leave site loss and post-cutover second-copy freshness uncovered. That accepted gap must remain visible in health and recovery documentation.

## Non-goals for the first implementation

- Multi-node Kubernetes or physical-host HA.
- Automatic media acquisition.
- Any off-site backup integration, including selective media backup.
- Cloud-native distributed storage.
- Public administrative access.
- Treating nspawn as a hostile-code security boundary.
- Selecting or implementing the future curated-media backup mechanism before the core data catalog and backup pipeline exist.
