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
- site loss, using an assumed off-site target;
- failed guest OS, K3s, and application upgrades.

Most movies and TV are replaceable and are not copied off-site. Photos, personal files, identities, application state, and configuration receive stronger treatment. A later mechanism may select only specific movies/TV for off-site backup.

## Scale and hardware

- Plan for 20–100 TB over approximately three years.
- Hardware expansion is allowed and expected.
- Current repository evidence shows a dual-socket Broadwell-generation host (2 × 14 cores / 56 threads represented by facter), about 224 GiB usable memory, four Ethernet interfaces, two 1 TB Intel NVMe devices, a single-NVMe `rpool` declaration, and an Intel display device `8086:56b1` using `i915` plus the embedded Matrox adapter.
- The current media pool is mergerfs over three gocryptfs cleartext mounts; a fourth LUKS/Btrfs disk is declared but not provisioned.
- The current inventory does not establish the attached bulk-disk count, sizes, health, HBA topology, network link speeds, UPS, or off-site target characteristics. These are mandatory discovery inputs.
- `hvn-hyp1` currently holds a hasty backup of some movies/TV from the old Proxmox homelab. Treat both machines as discovery sources: presence on `hvn-hyp1` does not establish authority, completeness, desired layout, or migration worth.
- Target host uplink is dual 10GbE. Prefer independent switch/router paths when practical so a switch restart does not remove all host connectivity; exact LACP, active/backup, routing, VLAN, and physical topology await NIC/switch/router inventory.
- A future VyOS routing VM and eventual router HA must remain possible, but neither is a dependency for the first storage/K3s deployment.

## Storage intent

- High-churn or irreplaceable data: ZFS datasets, snapshots, integrity checking, and off-site backup.
- Large low-churn replaceable media: mergerfs plus SnapRAID is acceptable.
- Flexibility and incremental disk expansion matter.
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

| Data/service tier | Local protection target | Off-site RPO target | Restore target |
|---|---|---:|---:|
| Identities, secret recovery material, Git configuration | redundant encrypted copies plus offline recovery copy | after every controlled change | 4 hours |
| Personal photos and files | hourly snapshots, filesystem redundancy | 6 hours | 24 hours |
| Application databases/configuration | application-consistent backup at least every 6 hours plus local snapshots | 24 hours | 8 hours |
| Curated media subset | checksum/catalog plus selected copy | 24 hours | 72 hours |
| Replaceable movies/TV | SnapRAID parity and scrub; no off-site copy | none | best effort / reacquire |
| Caches, thumbnails reproducible from originals, transcodes, downloads | none or short local retention | none | rebuild |

A later review may tighten these targets after measuring dataset sizes, upload rates, backup bandwidth, and restore throughput.

## Non-goals for the first implementation

- Multi-node Kubernetes or physical-host HA.
- Automatic media acquisition.
- Off-site backup of all media.
- Cloud-native distributed storage.
- Public administrative access.
- Treating nspawn as a hostile-code security boundary.
- Selecting or implementing the future curated-media backup mechanism before the core data catalog and backup pipeline exist.
