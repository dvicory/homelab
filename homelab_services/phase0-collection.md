# Phase 0 collection workflow

Three role-specific entry points share one read-only implementation:

- `phase0-hvn-hyp1.sh` — NixOS/current-host additions.
- `phase0-proxmox.sh` — Proxmox cluster, VM, container, storage, and HA additions.
- `phase0-docker-guest.sh` — credential-safe Docker/Compose inventory for `dia`; records images, mounts, ports, networks, selected Compose labels, and environment variable names but never environment values.
- `_phase0-collector-lib.sh` — common hardware, disk, network, GPU, power, filesystem, and optional content scanning. Keep this file beside every entry point.
- `phase0-catalog.sh` — one-root-at-a-time compressed JSON metadata cataloging with symlink and failure controls.
- `catalog-analyze.py` — standard-library streaming importer, SQLite inventory, fuzzy filename matching, and conservative destination classification.
- `phase0-dia-apps.sh` — focused recovery preflight for immutable image identity, application state roots, and safe version/database metadata.

The collectors do not modify disks, pools, mounts, VMs, services, networking, or configuration. They do not run repairs, SMART self-tests, scrubs, parity sync, benchmarks, or packet captures.

## Recommended production-safe sequence

Run from a local filesystem with enough room for text reports. Root is strongly recommended.
Because collection runs as root, execute only trusted copies. Keep the required wrapper/helper files in a root-owned, non-world-writable directory on each source host; the inventory collector uses a fixed system PATH to avoid command shadowing.

### 1. Low-impact topology pass on `hvn-hyp1`

```bash
cd /path/to/homelab_services
sudo ./phase0-hvn-hyp1.sh \
  --label hvn-hyp1 \
  --output /var/tmp \
  --skip-smart
```

### 2. Low-impact topology pass on the old Proxmox host

```bash
cd /path/to/homelab_services
sudo ./phase0-proxmox.sh \
  --label old-proxmox \
  --output /var/tmp \
  --skip-smart
```

These passes do not recursively walk media. Review storage topology, Proxmox guest/storage configuration, mount topology, and `90-tool-availability.tsv` before selecting content roots.

### 3. Device-health pass

When it is acceptable to query drive health, omit `--skip-smart`. The collector runs sequential SMART probes with `smartctl -n standby,3`, so a supported sleeping SATA/SAS disk is reported without being spun up. Active disks, NVMe devices, and SnapRAID health are queried. This is still optional on a latency-sensitive production host.

```bash
sudo ./phase0-proxmox.sh \
  --label old-proxmox-health \
  --output /var/tmp
```

### 3a. NVMe namespace pass on `hvn-hyp1`

The installed host profile lacks `nvme-cli`. Run the collector inside a root Nix shell so it can preserve the trusted `/nix/store` `nvme` binary while retaining its fixed PATH:

```bash
sudo nix shell nixpkgs#nvme-cli -c \
  ./phase0-hvn-hyp1.sh \
  --label hvn-hyp1-nvme \
  --output /var/tmp
```

This adds controller identify data, allocated/all namespace lists, active namespace identify data, SMART logs, and error logs. It does not create, delete, attach, detach, or resize a namespace.

### 3b. Docker inventory inside `dia`

Copy `phase0-docker-guest.sh` and `_phase0-collector-lib.sh` into the VM and run:

```bash
sudo ./phase0-docker-guest.sh \
  --label dia \
  --output /var/tmp \
  --skip-smart
```

Do not provide `docker inspect`, `docker compose config`, `.env`, or Compose files manually: those can expose credentials. The dedicated collector emits only the topology needed to design per-application exports. After reviewing its archive, create app-specific native backup commands.

### 4. Content scan, one root at a time

Start without `--include-paths`. This performs one metadata traversal for counts, bytes, extensions, and age buckets:

```bash
sudo ./phase0-proxmox.sh \
  --label old-proxmox-media \
  --output /var/tmp \
  --skip-smart \
  --deep \
  --scan-root /actual/mounted/media/root
```

Run separate invocations for separate large roots. Add `--include-paths` only when depth-two directory sizes are needed; it adds a second complete traversal:

```bash
sudo ./phase0-hvn-hyp1.sh \
  --label hvn-hyp1-media-paths \
  --output /var/tmp \
  --skip-smart \
  --deep \
  --scan-root /mnt/storage/media \
  --include-paths
```

Do not point `--scan-root` at `/`, `/proc`, `/sys`, `/dev`, `/run`, a VM image, ZFS zvol, inaccessible guest filesystem, Btrfs snapshot root, or a broad parent containing unrelated mounts. The script refuses key pseudo/root paths, but correct content-root selection remains an operator decision.

## JSON filesystem catalogs

Use [rclone `lsjson`](https://rclone.org/commands/rclone_lsjson/) through `phase0-catalog.sh`. The wrapper produces one compressed catalog, an rclone log, source/mount metadata, and checksums per explicit root. It records files, directories, and symbolic links without following links, hashing payloads, or entering `.zfs` snapshot namespaces.

The repeated notice `Can't follow symlink without -L/--copy-links` from the earlier manual command is expected: those regular-file entries remain useful, but symlinks were omitted. Do **not** add `-L`/`--copy-links`; following links can escape the selected root, duplicate trees, and enter loops. The wrapper uses `--links`, which represents each link as a `.rclonelink` catalog entry without traversing its target.

On `hvn-hyp1`, run via a temporary Nix shell:

```bash
sudo nix shell nixpkgs#rclone -c \
  ./phase0-catalog.sh \
  --label hvn-bulk-2 \
  --root /bulk-2/medialibrary \
  --output /var/tmp/catalogs
```

On old Proxmox or `dia`, install/use a trusted rclone binary and invoke the same script directly. Use one invocation per root. Never reuse a label: the wrapper refuses to overwrite an existing catalog.

Catalog these complete roots:

- old Proxmox: `/tank1/ds1` as `proxmox-tank1-ds1`; this includes the disorganized Kirk, Spock, McCoy, Redshirt, fileserver, backup, VM, and other nested dataset trees in one authority inventory;
- `hvn-hyp1`: `/mnt/storage/media` as `hvn-media`;
- imported ZFS pools: `/bulk-2/medialibrary` as `hvn-bulk-2` and `/bulk-3/medialibrary` as `hvn-bulk-3`;
- `dia`: `/home/medialibrary` as `dia-home-medialibrary` and `/var/lib/docker/volumes` as `dia-docker-volumes`.

Do not separately catalog `dia`'s `/mnt/medialibrary`: it is the network-mounted legacy data covered by the Proxmox catalog. The Docker report also shows `/mnt/ceres-complete-downloads`; classify its backing mount from the report before deciding whether it needs its own authority catalog.

`bulk-2` and `bulk-3` are now imported read-write and auto-mounted. Both are online single-disk pools with one `medialibrary` dataset; no errors were reported, but their last successful scrubs were September 2025. Do not run `zpool upgrade`, change properties, create/delete snapshots, or write into them. Metadata cataloging is safe. Decide whether to export and re-import read-only after current catalog processes finish.

The catalogs supply `Path`, `Name`, `Size`, `ModTime`, directory entries, and `.rclonelink` markers. They are planning inputs for high-level classification and later `rsync`/rclone transfer lists, not proof of identical content. Hash only same-path size conflicts, unique critical files, and selected samples.

Do not paste raw catalogs into chat. Keep the four files per label untracked under `homelab_services/artifacts/`. Run `python3 homelab_services/catalog-analyze.py` from the repository root. It verifies collection checksums, incrementally decodes each gzip JSON array, stores entries in local SQLite, normalizes large-file names for fuzzy candidates, and emits bounded directory/category/cross-source reports. Only those summaries and selected conflict rows enter model context; the 524 MB compressed catalog is never loaded wholesale into memory or model context.

Use `python3 homelab_services/catalog-analyze.py --status` from another terminal for live bounded progress. It reads only committed SQLite counters and schema state; it does not scan catalog contents or expose paths. If report generation is interrupted after both indexes exist, `--resume-reports` regenerates reports without re-importing the catalogs.

The classifier combines extension/content-category ratios, exact and typo-tolerant path keywords, mixed-content detection, and exact-size normalized-name matching. Its destinations (`personal-mirror`, `services-mirror`, `bulk-media`, `static-proxmox`, `disposable-review`, `manual-review`) are review suggestions only. It never authorizes deletion or treats a metadata match as a verified duplicate.

`catalog-reports/review-queue.csv` sorts every manual, disposable, or non-high-confidence subtree by apparent bytes so the highest-impact ambiguity is reviewed first. The full `directory-classification.csv` retains every depth-three suggestion; `overview.json`, `top-directories.json`, and `cross-catalog-matches.csv` remain bounded summaries.

### Initial legacy priority map

The legacy character names express approximate importance but do not override observed contents:

1. **Kirk — control/backup authority candidate:** infrastructure, backup sets, VM/application state. Split genuine recovery material from stale VM images, ISOs, and caches.
2. **Spock — personal-data authority candidate:** the unbacked fileserver tree is presumed irreplaceable until reviewed.
3. **McCoy — bulk/media authority candidate:** mostly media, but its parent contains substantial unclassified data outside `media`.
4. **Redshirt — disposable candidate:** lowest expected importance, but deletion still requires catalog review.

Every top-level subtree receives four labels during review: `criticality` (`irreplaceable`, `stateful`, `hard-to-reacquire`, `replaceable`, `disposable`), `authority` (`authoritative`, `partial`, `duplicate`, `stale`, `unknown`), `destination` (`personal-mirror`, `services-mirror`, `bulk-media`, `static-proxmox`, `discard`), and `action` (`copy-first`, `export`, `reconcile`, `retain-static`, `discard-after-proof`).

## Production risk and scaling

The collector is logically read-only, but **not zero impact**:

- The ordinary pass issues management/status queries to Proxmox, Ceph, ZFS, Btrfs, IPMI, network drivers, and configured storage. It does not pause or lock guests, but a broken remote storage target or kernel device in uninterruptible I/O can outlive the userspace timeout.
- `pvesm status`, Ceph status, filesystem/device discovery, and transceiver EEPROM reads produce small control-plane or device-management load. Avoid running during an incident, backup storm, storage recovery, scrub/resilver, or latency-sensitive maintenance.
- SMART extended-data reads do not start self-tests or modify disks. They can query many controllers and active disks; `--skip-smart` removes them. Standby-aware probes avoid waking supported sleeping disks, but buggy firmware/controllers can never be assigned zero risk.
- `--skip-smart` is not a guarantee that every disk remains asleep: `blkid`, LVM/ZFS/Btrfs/SnapRAID status, and kernel filesystem discovery may still read device metadata. There is no complete disk inventory that guarantees zero device access.
- Deep scanning is the material risk. It reads metadata for every file under the selected filesystem, wakes every mergerfs branch needed to answer that traversal, consumes cache, and can contend with VM/NAS I/O. NFS scanning transfers the load to the NFS server and network.
- Capacity in TB is not the best predictor. Ten million small files can be much more expensive than 80 TB of large movies. Btrfs snapshot trees, nested bind mounts on the same device, high-latency disks, mergerfs branches, and network filesystems amplify cost.
- Roots are scanned sequentially, never in parallel. The base `--deep` report makes one full `find` pass. `--include-paths` adds one `du` pass. Both run with `nice -n 19` and idle-class `ionice` when available.
- The timeout bounds normal userspace execution, but Linux cannot immediately kill a task blocked in uninterruptible kernel I/O. Confirm mounts are healthy first.
- The report does not sort every filename, hash payloads, detect duplicates, read file contents, or create per-file output. Report/archive size therefore stays tied to inventory metadata rather than total stored bytes.

For a production Proxmox host, the conservative order is: topology with `--skip-smart` → review → optional device health → one explicit content root per off-peak run.

## If data or services live inside a VM/container

The Proxmox collector identifies guests, virtual disks, mount points, passthrough, and current configurations, but it cannot see filesystems or application configuration hidden inside a VM.

After reviewing the first Proxmox report, likely follow-up collection is:

- run a generic/Linux variant inside the guest that owns Jellyfin/*arr/downloads, or mount a read-only restored backup and scan it;
- record application versions and export settings/configuration through supported backup mechanisms;
- identify which guest paths correspond to host storage and whether hardlinks/atomic moves were possible;
- do not start or alter an old guest solely for inventory until its storage and network exposure are understood.

The inventory collectors intentionally do not SSH into guests or extract VM disks.

## Application recovery collection

The active `dia` workload is **QEMU VM 200**, not the stopped LXC 101 that has the same name. VM 200 uses `agent: 1`, a ZFS-backed `scsi0`, and a host-provided 9p/virtiofs path rooted at `/tank1/ds1/mccoy/media`. A Proxmox VM backup covers the guest disk but not that host data tree.

The Proxmox backup is only a **source-side rollback artifact**. It is not a proposal to recreate `dia`, Docker, or a VM on `hvn-hyp1`. Its value is preserving the exact old VM disk—including application directories, databases, Compose files, local Docker volumes, and legacy image layers—before native export work touches old state. Native exports and copied data, not the VM archive, are the migration inputs.

Run the application preflight on `dia`:

```bash
./phase0-dia-apps.sh \
  --output /safe/output
```

Copy the resulting archive and `.sha256` file under `homelab_services/artifacts/` without tracking them. Do not paste its contents into chat.

The application preflight records immutable container/image IDs and pullable digests, safe build/version metadata, compose-file hashes, mounts, environment **names**, state-root metadata, selected known database-file metadata, Nextcloud status, and active PostgreSQL database names. It never emits environment values or configuration contents and never changes container lifecycle. ACD/git-annex/gcrypt are outside `dia` and intentionally excluded. Every probe has a 60-second timeout, the current section is visible in `00-current-section.txt`, and `SIGINT`/`SIGTERM` terminate the collector rather than advancing to the next probe.

At the current stage, collect only this read-only metadata. Do not create Radarr/Sonarr backup ZIPs, dump databases, enter maintenance mode, or otherwise prepare native exports before the target platform is deployed and can be explored with empty or synthetic state.

After the target applications are deployed on `hvn-hyp1` and their storage, ingress, identity, version compatibility, and restore tooling have been inspected, native export work begins. At that point, first create a source-side Proxmox rollback copy through the existing workflow if an independent target has enough capacity. The initially observed `kirk-k8s-data` target had only about 48 GB available and is too small for VM 200, whose ZFS volume reported about 271 GB referenced. The VM backup excludes `/tank1/ds1/mccoy/media` and is not a media/personal-data backup.

If recovery later needs the exact old runtime, restore that archive only as an isolated VM on old Proxmox with networking disconnected. This is an extraction/verification technique, not part of the target architecture.

Once those gates are satisfied, native exports proceed in dependency order:

1. Save legacy container images by immutable image ID to independent storage; `:latest` tags are not recovery artifacts.
2. Map every active PostgreSQL database to its consuming application before dumping or stopping it.
3. Trigger and download Radarr and Sonarr built-in backups from **System → Backup**. Keep their entire `/config` trees as a second recovery form.
4. Preserve Jellyfin `/config`; use an application-native backup only if the captured version exposes one.
5. Put Nextcloud in maintenance mode and capture its configuration, application tree, data tree, and database together.
6. Preserve FreshRSS, Bazarr, NZBHydra2, SABnzbd, Recyclarr, and Resilio application directories before pruning any service. Export user-visible formats where available, but do not treat those exports as replacements for state.
7. Treat stopped Immich/PostgreSQL 14/Redis as a cold recovery set. First preserve VM 200 and all bind/volume state. Start the exact old stack only in an isolated restored clone, then create a logical PostgreSQL dump and reconcile originals against the photo authority.

Each native export must record application version/image ID, UTC timestamp, source path, byte size, checksum, and the exact restore test used. No source application is upgraded, path-remapped, or policy-reconciled during export.

## What is collected

### Common

- OS, kernel, boot, failed services, kernel warnings, enabled units, and timers. General application journals and process command lines are excluded because they may contain credentials or user data.
- DMI/chassis/firmware, CPU, NUMA, memory DIMMs, EDAC/RAS, PCI/IOMMU groups, USB, sensors, IPMI FRU/sensors/PSU power.
- Intel DRM device mapping, `vainfo`, ffmpeg hardware codecs, i915 information, and relevant kernel messages.
- Block topology, stable IDs, serials, sector/IO geometry, local filesystem capacity/inodes, fstab/crypttab, LUKS metadata, MD/LVM, ZFS, Btrfs, mergerfs, and SnapRAID status. NVMe health/error logs and SMART extended data are added unless `--skip-smart` is used.
- Interfaces, link/driver/firmware/transceiver information, speed/duplex, channels/rings/offloads, bridges/VLANs/bonds, routes/rules/neighbors, LLDP, firewall state, forwarding, RDMA, and WireGuard interface state.
- UPS visibility where NUT tools are installed.
- Running processes and virtualization indicators.
- Tool-availability matrix, so a missing answer can be distinguished from an absent tool.

### NixOS role

- NixOS generation/version and current system size.
- Incus, libvirt, Podman, Docker, machinectl, gocryptfs/mergerfs status.
- Names of materialized agenix secrets, never their contents.

### Proxmox role

- Proxmox/package versions, cluster/node/storage state, HA and Ceph status.
- VM and container lists/configurations.
- Proxmox storage/datacenter/corosync configuration.
- Package and apt source inventory.

### Optional deep scan

For each explicit root:

- aggregate regular-file count and bytes;
- counts and bytes by file extension;
- modification-age buckets;
- with `--include-paths`, directory sizes through depth two in a second traversal.

It deliberately does not hash every media file or find duplicates. At 20–100 TB that would add substantial I/O before disk health and source-of-truth status are understood.

## Output and privacy

Each run creates:

```text
phase0-<label>-<UTC timestamp>/
phase0-<label>-<UTC timestamp>.tar.gz
```

The directory includes command exit codes, warnings, and SHA-256 checksums. A failed command usually means a tool or subsystem is absent; it does not mean the collector should install packages or repair anything.

The archive is mode-private by default, but it is sensitive. It contains infrastructure hostnames, addresses, MACs, serial numbers, VM names, storage paths, and potentially media titles. Inline credential-shaped values are redacted defensively, but review before sharing. No automatic upload occurs.

To provide the results here, copy both archives to the workstation or another path accessible to this session and give their paths. Do not paste the full reports into chat.

## Answers scripts cannot establish

After both reports are analyzed, the remaining Phase 0 discussion will cover:

- which old Proxmox data is authoritative, merely duplicated, or disposable;
- expected media/photo/personal growth and desired initial purchase budget;
- acceptable disk and enclosure failure combinations;
- the accepted duration and restrictions for using old Proxmox as a same-site static rollback copy;
- physical cable/switch/router/UPS topology not visible through LLDP/IPMI;
- intended 10GbE switch/router ports, VLANs, and maintenance/failure behavior;
- public DNS/provider and household access requirements;
- client devices and concurrency expectations;
- which media is hard to reacquire and should be marked in the catalog for a future, separately scoped backup project;
- complete export scope for Jellyfin and every installed Arr-family service before migration, including databases, native backups, users/watch state, profiles, metadata, history, and integrations;

The desired future dual-10GbE design and VyOS direction are recorded in the architecture documents. Phase 0 only needs to preserve an upgrade path: appropriate NIC/PCIe/NUMA capacity, bridge/bond/VLAN choices, and a management path that survives switch or router maintenance.
