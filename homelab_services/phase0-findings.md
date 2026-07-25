# Phase 0 findings

**Status:** destructive storage work remains blocked. `bulk-2` and `bulk-3` were imported read-write and auto-mounted before a read-only procedure was defined; the new report shows both online with no known data errors. Do not make further pool or filesystem changes while cataloging.

**Sensitivity:** the source reports contain hostnames, IP/MAC addresses, disk serials and WWNs, filesystem paths, VM names, and some media filenames. Keep this document and the report directories/archives untracked.

## Decisions now fixed

1. New critical storage uses ZFS mirror vdevs only: RAID1-style two-way mirrors, expanded by adding mirror pairs. Do not use RAIDZ or dRAID.
2. Replaceable bulk media uses independent filesystems combined with mergerfs and protected by SnapRAID parity.
3. The old Proxmox RAIDZ2 pool is only a legacy migration source. Its topology is not a template for the new system.
4. `bulk-2` and `bulk-3` are imported single-disk media-copy pools, mounted at `/bulk-2` and `/bulk-3`. They remain repurposable only after their unique files are reconciled.
5. Current gocryptfs/Btrfs names and layout are temporary. Target bulk disks use per-disk LUKS2, newly defined stable labels/mounts, mergerfs, and SnapRAID.
6. Application state and personal originals use separate physical ZFS mirror pools. Use owned NVMe for application state and liberated 8 TB Proxmox disks for personal data after evacuation.
7. Enlarge or rebuild the boot namespace, but do not use the boot `rpool` for K3s, PostgreSQL, Immich metadata, or other durable application state.

## `hvn-hyp1`: observed platform

| Area | Evidence | Consequence |
|---|---|---|
| Chassis/compute | Dell PowerEdge R730; 2 × Xeon E5-2690 v4; 28 physical cores/56 threads; 220 GiB reported RAM | Ample single-node compute. NUMA and guest resource limits still need a feasibility test. |
| Network | `eno1` negotiated at 10,000 Mb/s with `172.27.50.17/24`; three other onboard interfaces were down | Initial migration can use the existing 10GbE LAN. Dual-link/switch failure behavior remains unknown. |
| GPU | Intel PCI device `8086:56b1`, `i915`, and `/dev/dri/renderD128` are present | Hardware exists, but codec/tonemap support is unproved. The render node was mode `0666`; restrict it before guest/pod exposure. |
| NVMe | Four physical 1 TB Intel `SSDPELKX010T8L` devices are owned; two are installed. Each installed controller reports 1,000,204,886,016 bytes total, a single 100,931,731,456-byte namespace, and 899,273,154,560 bytes unallocated. Controller identify reports `oacs=15` and capacity for 128 namespaces. | The hardware exposes namespace-management capability, but root recovery must be proven before changing the boot device. Use the separate owned pair for application state; treat safe root expansion as a distinct operation. |
| Chassis slots | 12 storage slots are available; owner policy caps normal occupancy at 11 | Keep one compatible bay physically empty so maintenance and replacement can attach a new disk before removing an old member when possible. |
| Boot pool | Runtime `rpool` is 76.5 GiB, 84% allocated, 70% fragmented, with about 10.4 GB dataset availability; the current NixOS closure alone reports 17.4 GiB | Image builds and normal rebuilds can exhaust the host. Root namespace expansion or staged reinstall is a prerequisite. |
| Nix retention | 28 NixOS generations (103–130) are retained and repository settings disable automatic GC | Review and deliberately prune obsolete generations/store paths for immediate headroom, but do not mistake cleanup for the required namespace/root redesign. |
| Root identity | Repository declares `zfs.rootPool.disk1 = "/dev/nvme0n1"`; runtime `rpool` is on the device currently named `nvme1n1`, serial `PHLJ952202FT1P0I` | Volatile kernel naming has already diverged. Convert the declaration to the verified stable by-id before any installer/disko operation or before placing data on the other NVMe. |
| HDDs | Seven 12 TB HDDs behind integrated `megaraid_sas`; exact PERC mode is unknown | No disk is safe to repurpose until controller mode, slots, health, and existing labels are understood. |
| Current media | Three temporary single-device Btrfs filesystems, each under gocryptfs and merged at `/mnt/storage/media` | Preserve only through reconciliation. The target layout, encryption, names, labels, and paths are redesigned rather than extended. |
| Current parity | `/etc/snapraid.conf` is absent and the SnapRAID command was unavailable | One data-disk loss currently loses the files placed on that disk. This is the highest current media-protection gap. |
| Host health | `systemd-tmpfiles-clean.service` was failed | Diagnose before adding workloads; it may indicate unrelated cleanup or filesystem pressure. |

### Current 12 TB disk roles

The names below are report-time kernel names only; use their WWNs for decisions.

| Report device | WWN suffix | Observed role |
|---|---|---|
| `sda` | `270607128` | Btrfs `media2`, gocryptfs/mergerfs data |
| `sdb` | `200080000` | Imported single-disk ZFS pool `bulk-2`; `/bulk-2/medialibrary` references 7.03 TB |
| `sdc` | `26f7c1a74` | Btrfs `media3`, gocryptfs/mergerfs data |
| `sdd` | `253dd0dc5` | No partition or recognized filesystem in collected topology; this does not prove erasure is safe |
| `sde` | `27061f6b4` | No partition or recognized filesystem; declared as unprovisioned `media4` in the repository |
| `sdf` | `270846370` | Btrfs `media1`, gocryptfs/mergerfs data |
| `sdg` | `26f7cf7cc` | Imported single-disk ZFS pool `bulk-3`; `/bulk-3/medialibrary` references 6.81 TB |

The three Btrfs media disks total 36.00 TB decimal. Reported used space is 21.04 TB and estimated free space is 14.96 TB. Btrfs device error counters were zero, but SMART data was not collected because `smartctl` was unavailable; zero Btrfs counters are not a health verdict.

## Old Proxmox: observed platform and urgency

| Area | Evidence | Consequence |
|---|---|---|
| Platform | Supermicro X9DBL; 2 × Xeon E5-2450L; 192 GiB RAM; Proxmox VE 7.4-19 | Retain only long enough to evacuate and verify data. Do not expand its responsibilities. |
| Network | X710 `enp4s0f0` negotiated at 10,000 Mb/s with `172.27.50.22/24`; second X710 port down | A direct same-LAN 10GbE migration path likely exists, subject to switch and firewall confirmation. |
| Storage pool | Seven 8 TB HDDs in one online RAIDZ2 vdev; 98% pool allocation, 55% fragmentation; scrub paused after scanning 83.77 TB with zero reported errors | Stop avoidable writes. Complete migration planning before any pool upgrade, scrub mutation, snapshot deletion, or app churn. |
| Media dataset | `tank1/ds1/mccoy/media` reports only 49.2 GB available and 100% use | Immediate capacity pressure. It is not a safe landing area or staging workspace. |
| Media corpus | 195,567 regular files; 30.24 TB logical. Approximately 27.42 TB is recognized video, 1.21 TB is archive parts, and 0.10 TB is images | The 21.04 TB current-host usage cannot be presumed complete; exact overlap needs manifests. |
| Legacy media VM | Running VM `dia`, 16 GiB RAM, six cores, Quadro P400 passthrough, and the media dataset mounted into the guest | Export Jellyfin and every Arr-family service comprehensively before retirement; declarative reconciliation follows a compatibility-pinned restore. |
| File server | Running `turnkey-fs` container bind-mounts `tank1/ds1/spock/media/fileserver` | Treat this subtree as potentially personal/critical until classified and backed up. |
| Remote access | Running Tailscale container on internal `10.10.10.0/24` bridge | Retirement must preserve a break-glass path but should not copy this routing design into the new host blindly. |

### Old data not covered by the deep scan

Only `/tank1/ds1/mccoy/media` received the deep file scan. The following still need classification:

- `tank1/ds1/mccoy` has about 2.55 TB referenced outside its `media` child.
- `tank1/ds1/kirk` has about 2.02 TB referenced at the parent in addition to children.
- `tank1/ds1/kirk/backups` references about 2.17 TB.
- `tank1/ds1/spock/media` references about 820 GB and contains the fileserver bind path.
- VM/container storage uses about 1.40 TB. VM 200 alone reports about 1.30 TB used but only 271 GB referenced, indicating roughly 1 TB held by snapshots/descendants or related ZFS accounting. The collector's snapshot summary failed, so this must be inspected before considering any deletion.

These are not minor leftovers. The non-media roots may contain the highest-value personal data in the old system.

## Data ownership comparison

The current reports establish capacity, not equivalence:

- Old media corpus: 30.24 TB logical, 195,567 files.
- Current mergerfs corpus: 20.83 TB regular-file payload, 168,717 files. Imported `bulk-2/medialibrary` and `bulk-3/medialibrary` reference 7.03 TB and 6.81 TB, but their file catalogs are still pending.
- Current mergerfs filesystem usage/free: 21.04 TB used and 14.96 TB estimated free.
- Old versus current corpus shape differs materially: old has about 8.88 TB more recognized video, while current has about 0.36 TB more recognized audio. The current tree is not a simple byte-for-byte subset.

[INFERENCE] The roughly 9.41 TB aggregate payload difference can fit in current free space only if path-level comparison confirms sufficient overlap. Files deleted from Proxmox may survive only on current mergerfs, `bulk-2`, or `bulk-3`; old-only and new-only files must both be preserved. Path/size manifests are therefore a hard gate.

The prior `/mnt/storage` deep scan returned zero files because `find -xdev` stayed on the host root filesystem and did not cross into the `/mnt/storage/media` FUSE mount. This is expected from the selected root; it is not evidence that the media tree is empty.

### Complete catalog inventory

All six catalog sets passed their collection checksums and were streamed into a 7.87 GB SQLite database without loading a raw catalog into model context:

| Catalog | Entries | Files | Apparent file bytes |
|---|---:|---:|---:|
| old Proxmox `/tank1/ds1` | 18,324,476 | 15,472,790 | 38.91 TB |
| current mergerfs | 249,326 | 168,717 | 20.83 TB |
| `bulk-2/medialibrary` | 10,354 | 9,442 | 7.03 TB |
| `bulk-3/medialibrary` | 198,063 | 120,825 | 6.89 TB |
| `dia` home/application tree | 314,856 | 222,816 | 70.07 GB |
| `dia` Docker volumes | 47 | 7 | 1.97 MB |

Rclone logs contain notices but no summarized error/permission-denied events. The old Proxmox tree alone contains 2,613,817 directories and 237,869 recorded symlinks, explaining the large manifest despite only 38.91 TB of apparent file payload.

Metadata-only matching found 66,244 cross-catalog fuzzy-name plus exact-size candidate groups. Strong overlap signals include current mergerfs ↔ Proxmox (98,309 candidate pairs; 18.70 TB), `bulk-3` ↔ Proxmox (67,500; 6.55 TB), `bulk-3` ↔ current mergerfs (37,104; 6.16 TB), and `bulk-2` ↔ current mergerfs (2,765; 7.05 TB). Pair bytes can exceed unique source bytes when multiple files share a signature. These are triage signals, never deletion proof; targeted hashes remain required.

Depth-three heuristic classification produced 1,827 media subtrees, 84 services-state subtrees, 15 personal-data subtrees, 17 static-Proxmox subtrees, seven disposable-review subtrees, and 353 manual-review subtrees. Mixed-content parents are deliberately downgraded to manual review rather than forcing a destination.

### Catalog and initial classification

Use `phase0-catalog.sh` for all planning manifests. It wraps rclone `lsjson` without payload hashes, records non-followed symlinks, and excludes `.zfs`. Generate one complete old `/tank1/ds1` catalog plus separate current mergerfs, imported-pool, and `dia` local-state catalogs.

Initial priority follows the legacy naming intent but remains subject to path review:

1. `kirk`: recovery/control data and backups; separate valuable exports from stale VM images and caches.
2. `spock`: personal/fileserver authority candidate; highest immediate data-loss concern because it has no independent copy.
3. `mccoy`: bulk-media authority candidate plus 2.55 TB of unclassified parent data.
4. `redshirt`: disposable candidate, never deletion-authorized without catalog review.

Classification is semantic, not checksum-driven. Each top-level subtree receives criticality, authority, destination, and action labels; rclone/rsync performs later transfers from the approved plan.

### Owner classification decisions

- `kirk/backups` is not one opaque backup repository. It is mostly rsync-collected, poorly organized content from old laptops, Han's Dropbox, and failed-drive recovery images. Preserve it as an authoritative mixed-content source; catalog and restore its useful contents later rather than copying the hierarchy unchanged into a final dataset.
- `kirk/staging/dewey-other-hd` and `bulk-3/dewey-incoming` are mostly movies/TV from old systems. Reconcile titles against the canonical media library; import acceptable releases or replace them with better releases, then catalog and restore any non-media remainder. Delete only after those two proofs.
- `bulk-3/acd-incoming` is an encrypted/synchronized archive from the former Amazon Prime Photos unlimited-storage workflow. Preserve unchanged until the encryption mechanism and credentials are recovered; decrypt into staging, catalog plaintext, and restore later.
- Owner recollection narrows the old Proxmox ACD workflow to folder syncs involving `acd_cli` and possibly git-annex/gcrypt metadata. No related binaries or state live on `dia`; ACD investigation is deferred and the source folders remain untouched.
- Photo/Immich data is irreplaceable personal data, and some paths are the only copy. Old Proxmox is authoritative relative to the point-in-time `hvn-hyp1` copy. `Amazon Photos Downloads` belongs to the encrypted ACD workflow rather than a normal photo export. `dvicory` and `han` identify Immich users, not general-purpose NAS home directories.
- Preserve all stopped Proxmox VMs in place. Initial migration focuses on `dia`; other guests remain static until individually reviewed.
- Restore the stopped Immich application, PostgreSQL, Redis, users, albums, sharing metadata, and originals on compatible versions before upgrading.
- Preserve Nextcloud and Resilio data/configuration in restore-capable form while their future service choice remains open; treat WebDAV as a replaceable access surface.
- Preserve Radarr/Sonarr and acquisition-stack state, but separate state recovery from activation and from declarative policy reconciliation.
- Migrate FreshRSS; LibreSpeed is disposable. Preserve Caddy/HAProxy/nginx/Portainer/Dockge/network-multitool configuration only as reference and replace their runtime roles with the target edge/GitOps platform.

## Candidate target allocation — preferred direction

Subject to file reconciliation, controller/health evidence, and restore proofs:

- **Application state:** install/allocate two owned 1 TB NVMe devices as a dedicated ZFS mirror. Preserve databases, guest/K3s state, and application config here; keep caches/transcodes separately disposable.
- **Host root:** use another NVMe namespace with materially more than 100 GB. Choose safe namespace growth versus staged reinstall only after controller capability and root recovery are proven.
- **Personal originals/files:** after old Proxmox evacuation, repurpose healthy 8 TB disks into one or two physically separate ZFS mirror pairs. With seven bulk disks already installed, four 8 TB mirror members reach the policy ceiling of 11 occupied slots and provide 16 TB usable.
- **Bulk media:** reconcile `bulk-2`/`bulk-3`, then use all seven 12 TB disks as five LUKS2-backed independent data filesystems under mergerfs plus two SnapRAID parity disks. Gross data capacity is 60 TB decimal.
- **Hard-to-reacquire media:** maintain a path-independent local catalog and classification. Payload backup is outside this roadmap.

Dual SnapRAID parity is the default because five data disks already provide roughly twice the current corpus capacity without buying drives. Single parity remains an acceptable fallback only if a documented capacity need outweighs the additional failure tolerance and the reduced protection is explicitly accepted.

No current names or filesystem choices are inherited automatically. No RAIDZ topology is a candidate. Critical ZFS expansion is by mirror pairs; mergerfs/SnapRAID expansion is by individual disks with parity sizing reviewed each time.

## `dia`: observed application-storage roots

The old Proxmox inventory contains two different guests named `dia`: stopped LXC 101 and active QEMU VM 200. The Docker application report came from VM 200, confirmed by matching QEMU virtualization and its machine UUID. VM 200 is the only relevant source-side rollback guest; neither guest is part of the target `hvn-hyp1` architecture.

The verified Docker report identifies `/home/medialibrary` as the parent of Compose stacks and bind-mounted application configuration for Jellyfin, Radarr, Sonarr, Bazarr, Recyclarr, SABnzbd, Nextcloud, PostgreSQL, Caddy, and other retained or review-required services. Docker-managed volumes under `/var/lib/docker/volumes` include additional application data, including an Immich library volume. Catalog both local roots. Network-mounted `/mnt/medialibrary` is legacy shared data and must not be treated as an independent `dia` copy.

The report inventories topology without environment values. Native database/application exports remain required before migration; a filename catalog is not an application-consistent backup.

## Immediate hold points

Do not run any of the following yet:

- the repository's `prepare-luks-storage` recipe for `media4`;
- `zpool upgrade`, pool attach/detach/replace, export/re-import during an active catalog, partitioning, `wipefs`, or filesystem creation;
- SnapRAID sync against the only copy of data;
- Proxmox snapshot deletion or scrub changes intended only to reclaim space;
- a NixOS installer/disko action while `rootPool.disk1` uses `/dev/nvme0n1`.

Keep old Proxmox read-mostly, stop avoidable downloads/library mutations, and do not use its remaining 49 GB as working space.

## Residual evidence required

### 1. Submitted host and application reports

`phase0-hvn-hyp1-nvme-20260724T104514Z` is correctly tagged `role=hvn-hyp1` and supplies the missing NixOS, imported-pool, and NVMe evidence. `phase0-dia-20260724T103518Z` supplies credential-safe Docker topology. All 126 host-report files and all 120 `dia` report files match their listed SHA-256 digests.

### 2. Produce complete catalogs

Use `phase0-catalog.sh` as documented in `phase0-collection.md` for complete old Proxmox, mergerfs, imported-pool, and `dia` roots. The wrapper emits compressed rclone JSON plus source metadata, logs, and checksums. It never hashes payloads or follows symlinks.

The earlier manual rclone output remains a usable regular-file catalog even with symlink notices. Do not use `-L`; either regenerate through the wrapper or retain that output and mark it `symlinks-omitted`.

### 3. Complete health/controller evidence

Still required:

- all seven HDD SMART/error/self-test histories;
- exact PERC model, firmware, HBA/JBOD versus virtual-disk mode, cache/BBU state, and whether drive error data passes through;
- enclosure slot-to-WWN map;
- Intel GPU marketing model, firmware, VA-API codec/tonemap proof;
- switch/router port mapping, second 10GbE path, UPS state, and iDRAC reachability.

## Remaining decisions and evidence

1. Complete controller-mode and slot mapping for the 12 TB and 8 TB devices; NVMe capacity/namespace evidence is now complete enough for a separate root-recovery design.
2. Generate complete catalogs for old `/tank1/ds1`, current mergerfs, both imported `medialibrary` datasets, and `dia` local state; then compare path/size data and hash conflicts/samples.
3. Classify the mostly static unbacked fileserver and every other non-media subtree; migrate them while leaving old Proxmox unchanged as the same-site rollback copy.
4. Determine whether the root namespace can grow non-destructively or requires a staged reinstall; never delete/recreate a namespace containing the only working root.
5. Allocate the four NVMe devices among application-state mirror, root, and disposable cache; separately preserve one of 12 chassis storage slots as an always-empty maintenance bay.
6. Choose Btrfs versus XFS/ext4 inside bulk LUKS2 devices after a disposable SnapRAID recovery proof.
7. Choose ZFS native encryption versus LUKS2-under-ZFS for critical mirrors from recovery tests.
8. Define the Proxmox freeze point and which catalogs/application exports it retains; no off-site integration is part of this roadmap.
9. Export and restore Jellyfin plus every Arr-family service. Declarativize deployment immediately and in-application settings incrementally, using TRaSH Guides via Recyclarr by default and Configarr when broader supported configuration is required.

## Collector defects found

- `SHA256SUMS` used absolute source-host paths, so standard verification failed after copying the report. The local collector now writes relative paths. The submitted report was instead verified by matching each listed digest to the copied file basename/path.
- The corrected report was run from the pre-fix collector copy, so its ZFS snapshot summary still shows the old quoting failure. The local collector is fixed; another full report is unnecessary solely for this field.
- The first current-host report was generated with the Proxmox role. The corrected `phase0-hvn-hyp1-20260724T091347Z` report now records `role=hvn-hyp1`, NixOS `26.05.20260515.d233902`, and the current 17.4 GiB system closure.
- SMART summaries from old Proxmox report `OK`, but its SAS/HBA path exposes no error counters or self-test log for the HDDs. Pool scrub status is stronger evidence, but still not a complete drive-health baseline.
