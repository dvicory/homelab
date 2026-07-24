# Phase 0 collection workflow

Two role-specific entry points share one read-only implementation:

- `phase0-hvn-hyp1.sh` — NixOS/current-host additions.
- `phase0-proxmox.sh` — Proxmox cluster, VM, container, storage, and HA additions.
- `_phase0-collector-lib.sh` — common hardware, disk, network, GPU, power, filesystem, and optional content scanning. Keep this file beside both entry points.

The collectors do not modify disks, pools, mounts, VMs, services, networking, or configuration. They do not run repairs, SMART self-tests, scrubs, parity sync, benchmarks, or packet captures.

## Recommended production-safe sequence

Run from a local filesystem with enough room for text reports. Root is strongly recommended.
Because the collector runs as root, execute it only from a trusted copy. Keep the two wrappers and shared library in a root-owned, non-world-writable directory on the Proxmox host; the collector itself uses a fixed system PATH to avoid command shadowing.

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

The current two scripts intentionally do not SSH into guests or extract VM disks.

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
- off-site provider capacity, retention, immutability, bandwidth, and recovery access;
- physical cable/switch/router/UPS topology not visible through LLDP/IPMI;
- intended 10GbE switch/router ports, VLANs, and maintenance/failure behavior;
- public DNS/provider and household access requirements;
- client devices and concurrency expectations;
- which media deserves later curated off-site backup;
- whether old application databases/configuration are worth migrating or services should start clean.

The desired future dual-10GbE design and VyOS direction are recorded in the architecture documents. Phase 0 only needs to preserve an upgrade path: appropriate NIC/PCIe/NUMA capacity, bridge/bond/VLAN choices, and a management path that survives switch or router maintenance.
