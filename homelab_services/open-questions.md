# Open questions and decision gates

These are intentionally unresolved. The architecture defines when and how to answer them.

## Must answer before storage changes

1. What are every disk's stable ID, size, age, filesystem, encryption layer, health, slot/enclosure, and current contents across both `hvn-hyp1` and the old Proxmox host?
2. For every duplicated movie/TV/photo/personal dataset, which copy is authoritative, complete, stale, or disposable? The hasty copy on `hvn-hyp1` must not be assumed authoritative.
3. Are the bulk disks directly visible through an HBA/JBOD path, and which failures share a controller, cable, enclosure, or power supply?
4. Which second 1 TB Intel NVMe is unused, and is it suitable for guest local PVs/database state?
5. What data is currently under the three gocryptfs trees, and is there any verified backup before migrating encryption/layout?
6. What is the planned initial disk purchase and expected annual growth within the 20–100 TB range?
7. Does personal data receive its own pool/vdevs, or a rigorously isolated redundant topology within a shared ZFS pool?
8. How many simultaneous data-disk failures should the media tier tolerate? The proposal assumes dual SnapRAID parity is the conservative starting point, pending disk count.
9. What off-site target exists, and does it provide versioning/immutability against credential compromise or ransomware?

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
3. Exact Immich directory classification: which of `library`, `upload`, `thumbs`, `profile`, `encoded-video`, and `backups` are copied off-site versus regenerated?
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
- checksum/catalog privacy at the off-site target;
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
