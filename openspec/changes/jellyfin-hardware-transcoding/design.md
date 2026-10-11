## Context

See proposal.md, "Why". The requirements are in
`specs/hardware-acceleration/spec.md`. This document records the facts the
design rests on, the mechanisms chosen, and the owner's decisions on the
questions the first draft left open (see "Resolved decisions").

### Host facts (read-only inspection of `hvn-hyp1`, 2026-10-10)

| Fact | Value |
| --- | --- |
| Kernel and OS | Linux 6.18.49, NixOS 26.11 (`26.11.20260904.801bef6`) |
| Incus | 7.4 |
| CPU | 2× Xeon E5-2690 v4, 56 threads |
| Accelerator | PCI `0000:85:00.0`, `8086:56b1` (subsystem `8086:1210`), "DG2 [Arc Pro A40/A50]", rev 05, NUMA node 1 |
| Driver in use | `i915`. The `xe` module is loaded but not bound. Both are listed as candidate modules. |
| DRM nodes | `card1` (226:1) and `renderD128` (226:128). `card0` is the BMC VGA (`102b:0534`, `mgag200`) and has no render node. |
| Render node | `/dev/dri/renderD128`, owner `root`, group `render` (GID 303), mode `0666` |
| Card nodes | owner `root`, group `video` (GID 26), mode `0660` |
| Stable name | `/dev/dri/by-path/pci-0000:85:00.0-render -> ../renderD128` |
| Firmware | DMC `dg2_dmc_ver2_08.bin` v2.8; GuC `dg2_guc_70.bin` 70.53.0 (submission, SLPC, RC enabled); HuC `dg2_huc_gsc.bin` 7.10.16, "authenticated for all workloads"; GSC/PXP MEI components bound |
| BAR | Resizable BAR failed (`-ENOSPC`); i915 uses a 256 MiB BAR |
| PCIe | Root port `80:03.0` runs at 8 GT/s x8 (Gen3 x8, the platform limit). The card's internal bridge reports 2.5 GT/s x1, which is normal for Arc's internal switch. |
| IOMMU | `/sys/kernel/iommu_groups` is empty. `CONFIG_INTEL_IOMMU=y`, but `intel_iommu=on` is not on the command line. |
| SR-IOV / mdev | No `sriov_totalvfs` and no `mdev_supported_types` on the device |
| Stand-in drivers | `CONFIG_DRM_VGEM=m`, `CONFIG_DRM_VKMS=m` |
| Evaluated host config | `hardware.enableRedistributableFirmware = true`, `hardware.graphics.enable = false` |
| Not readable as `daniel` | debugfs GuC/HuC status and i915 module parameters (permission denied) |

### Repository facts

- The compute project blocks GPU and character devices:
  `restricted.devices.gpu = "block"` and
  `restricted.devices.unix-char = "block"`
  (`modules/den/aspects/virtualization/compute.nix`, `projectConfig`). The
  adoption gate in `pkgs/by-name/compute-runtime/internal/adoption` reports
  any undeclared project key or profile device as a conflict.
- `compute-1` is an unprivileged container with `security.idmap.isolated`,
  nesting, `limits.cpu = 4`, and `limits.memory = 12GiB`
  (`modules/den/hosts/hvn-hyp1/default.nix`). `raw.idmap` is derived from
  `storageCapabilities = [ "media" ]` by `_idmap.nix`, which punches one
  identity-mapped hole for GID 505.
- The Jellyfin container runs as UID/GID 751 with supplementary group 505,
  drops all capabilities, uses `RuntimeDefault` seccomp, and is limited to
  2 CPUs (`modules/den/aspects/kubernetes/services/jellyfin.nix`). Its memory
  limit is 4Gi since PR #49 (merged). PR #53 (open) sizes the transcode cache
  at 64Gi.
- Jellarr runs as an Argo CD `PostSync` hook Job
  (`argocd.argoproj.io/hook = PostSync`) and is the only writer of
  Jellyfin's declared steady-state settings, as `jellyfin-lifecycle` in the
  active change `reproducible-jellyfin-compute` requires.
- K3s runs with `KubeletInUserNamespace`. runc ignores failures to load its
  eBPF device filter inside a user namespace
  (`opencontainers/cgroups`, `devices/v2.go`, `canSkipEBPFError`). In this
  guest, the per-container device cgroup is therefore not an enforcement
  layer. Device access is bounded by the outer Incus device cgroup, by which
  device nodes are visible inside a Pod, and by file ownership and mode.
- The `render` entry in `deterministic-uids.nix` (514) is a fallback that
  nixpkgs overrides (303). It is not a fleet identity.
- Jellarr v0.1.0 (`f94c24f`) supports these encoding fields:
  `enableHardwareEncoding`, `hardwareAccelerationType`
  (`none|amf|qsv|nvenc|v4l2m2m|vaapi|videotoolbox|rkmpp`), `vaapiDevice`,
  `qsvDevice`, `hardwareDecodingCodecs`, the HEVC/VP9/RExt color-depth
  toggles, `allowHevcEncoding`, and `allowAv1Encoding`. It has no tone-mapping
  or low-power encoder fields. Its codec-list diff never removes entries.
- Jellyfin does not fall back to software when hardware transcoding fails
  (jellyfin/jellyfin#4389; automatic detection is planned in #17108 with no
  date). If hardware acceleration is configured and does not work, transcodes
  fail.
- There is no monitoring or alerting stack in the cluster.

## Goals / Non-Goals

**Goals:**

- Give Jellyfin the Arc GPU's render node through the unprivileged compute
  boundary without widening that boundary beyond one declared device.
- Keep the compute guest, its management path, other workloads, Jellyfin, and
  playback that needs no transcode working when the GPU is missing.
- Declare the transcoding mode statically. When the GPU fails, hardware
  transcodes fail visibly and a documented check detects it. Switching to
  software is a declared operator change.
- Limit host access to the render node to declared host users and the granted
  guest.
- Prove the plumbing in existing checks and leave hardware proof to a short
  operator acceptance.
- Keep the contract neutral between container and VM compute guests, so a
  later cutover of `compute-1` to a VM changes mechanisms, not requirements
  (D12).

**Non-Goals:**

- A general GPU scheduling layer (device plugin, DRA) for multiple consumers
  or nodes.
- Tuning Jellyfin's encoding quality, tone mapping, or trickplay. These remain
  application-owned unless Jellarr gains the fields.
- Changing the host's display console or BMC VGA.
- Performing the VM cutover, or choosing replacement GPU hardware.

## Decisions

### D1. A new `hardware-acceleration` capability owns GPU access

The decisions here are about delegating a shared host device. None of the
existing or proposed capabilities owns that:

- `storage-foundations` and `storage-placement` own storage and the media
  group capability, not devices.
- `compute-recovery` (active change) says an unprivileged domain declares its
  host-granted devices and rejects undeclared ones. It does not say who may
  receive a device, how it reaches a Pod, or what happens when it is missing.
  This change relies on it and does not modify it.
- `jellyfin-lifecycle` (active change) owns Jellyfin startup and settings
  ownership. The transcoding-mode rule is a Jellyfin behavior, but it follows
  from the device contract, and later grant holders (Immich is expected) need
  the same rules.

The capability is therefore new. Its one media-specific rule (the declared
transcoding mode and visible failure) is phrased for "a granted media server".
Eligibility is not limited to media: any workload the owner explicitly
declares may hold a grant (see "Resolved decisions", item 2).

### D2. With this card and a container guest, render-node sharing is the mechanism

The spec is written so that a container or a VM compute guest can meet it
(see D12). This section picks the mechanism for today: `compute-1` is a
container, and the card is an Arc Pro A40/A50 (DG2, `8086:56b1`).

Incus `gpu` device types ([Incus GPU device reference][incus-gpu]):

| Type | Instance | What it does | Fit for this host |
| --- | --- | --- | --- |
| `physical` | container | Bind-mounts the GPU's DRM nodes (card, render, control) into the container. The host keeps the driver; the GPU stays shared. | Works, but exposes the card node and fails container start when the GPU is missing (D4). |
| `physical` | VM | VFIO passthrough of the whole PCI device. The host loses the GPU. No hotplug. | Needs IOMMU (off today) and the whole IOMMU group, including the card's internal bridges and its HDMI audio function `86:00.0`. Exclusive to one VM. |
| `mdev` | VM only | A mediated vGPU. For Intel this is GVT-g. No hotplug. | Intel lists GVT-g only for integrated graphics up to 11th Gen Core, and lists Arc Pro A-Series as "Not Supported" for any graphics virtualization ([Intel 000093216][intel-gvt]). The host confirms `mdev_supported_types` is absent. |
| `sriov` | VM only | Passes a virtual function of an SR-IOV GPU. No hotplug. | Not for this card: Intel lists Arc Pro A-Series as "Not Supported" ([Intel 000093216][intel-gvt]), upstream `xe` does not set `has_sriov` for DG2 ([xe_pci.c][xe-pci]), and the host shows no `sriov_totalvfs`. |
| `mig` | container only | NVIDIA MIG instances. | Not applicable. |
| `native-context` | VM only | virtio-gpu DRM native context; the host keeps the driver and shares the GPU. No hotplug. | Not evaluated. Incus says Intel support needs about `virglrenderer` 1.3 and QEMU 11.0 ([Incus GPU device reference][incus-gpu]). Whether VA-API and QSV media work through it on DG2 is not established. |

For the current container, sharing the render node is the right mechanism:
the host keeps the i915 driver, the GPU stays usable by more than one
consumer, and no IOMMU change is needed. The owner's earlier note ("we can
use incus's mdev if VM") does not hold for this card; D12 records what a VM
cutover would need.

### D3. The host drives the whole device and makes firmware ownership explicit

In the container design the host is the declared driving domain for the whole
DG2 device (spec: "The owner declares which domain drives an accelerator or
each share of it"). The guest receives only the render interface.

- Keep `i915` for DG2. On this kernel `xe` binds DG2 only with
  `force_probe`, and i915 is Intel's supported driver for Alchemist.
- State `hardware.enableRedistributableFirmware = true` in host
  configuration instead of relying on the facter default, and add an
  evaluation check that it stays on. GuC and HuC are required for low-power
  encoding on DG2.
- Do not enable host graphics userspace (`hardware.graphics`). The host only
  needs the kernel driver and firmware. The media userspace ships in
  Jellyfin's official image.
- Tighten the host's render node from `0666` to `0660`, group `render`
  (nixpkgs GID 303), with a host udev rule ordered after systemd's default
  rule, for example
  `SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0660"`.
  systemd's default rules set render nodes to `0666`, which lets every host
  process use the GPU. This meets the spec requirement "Host access to a
  host-driven render interface is limited to declared users and granted
  guests".
- Host processes that need the GPU join `render` in host configuration. None
  is known today: host graphics userspace is off, and Incus runs as root.
- The guest is unaffected. Incus does not pass the host node's inode. It
  creates the container's own node and shifts its owner through the guest ID
  map (see D5), so the guest node has group `gpu-render` (506) and mode
  `0660` whatever the host node's group and mode are.

### D4. Attach only the render node with an Incus `unix-char` device

Owner decision (item 4): render node only, `unix-char`, `required=false`.
These are container mechanisms and stay in this design; the spec does not
name them. Declare one device in the compute envelope:

```nix
devices.gpu-render = {
  type = "unix-char";
  source = "/dev/dri/by-path/pci-0000:85:00.0-render";
  path = "/dev/dri/renderD128";
  required = "false";   # guest starts without it; hotplug when it appears
  uid = "0";
  gid = "506";          # gpu-render
  mode = "0660";
};
```

and set `restricted.devices.unix-char = "allow"` in the project, keeping
`restricted.devices.gpu = "block"`.

Why `unix-char` over `gpu` with `gputype=physical`:

- Incus fails to start a container whose `gpu` device matches no GPU
  ("Failed to detect requested GPU device", `gpu_physical.go`). A missing or
  unbound GPU would stop the whole compute guest and every workload in it,
  which breaks "Accelerator loss affects only accelerated work".
- `gpu` passes the card and control nodes too, with the same group and mode.
  That exposes modesetting on the card's display outputs to the guest.
  `unix-char` passes only the render node.
- `unix-char` with `required=false` and a `source` hotplugs: Incus adds the
  node when it appears on the host and removes it when it disappears.

Costs of this choice:

- Incus project restrictions are all-or-nothing per device type. `allow`
  admits any character device in the project. Scope is enforced instead by the
  NixOS-owned profile, the adoption gate that rejects undeclared devices, and
  a new evaluation check that the only `unix-char` device is the declared
  render node.
- Selection is by path, not PCI address. The `by-path` source pins the PCI
  address. Whether Incus hotplug matches udev events on a `by-path` symlink is
  not proven (it matches the event path against `source`). The VM test must
  show it. If it does not work, use `/dev/dri/renderD128` as the source and
  add a host check that the node belongs to `0000:85:00.0`.

### D5. No `raw.idmap` change for the render group

`storageCapabilities` exists because files on host storage carry host GID
505, so that GID must be identity-mapped across the boundary. A device node is
different. Incus creates the guest's device node itself and shifts its
ownership through the instance's ID map (`unixDeviceSetup`, mount entry with
static owner shift). A `gid` of G in the device config appears as GID G inside
the guest without an identity mapping. The render capability therefore does
not join `storageCapabilities` and costs no hole in the guest's GID map. The
VM test confirms the guest-visible owner.

### D6. A dedicated fleet group is the capability

Owner decision (item 3): add the POSIX fleet group `gpu-render`, GID 506, in
`modules/den/groups/default.nix`. Jellyfin's Pod lists it in
`supplementalGroups`. The Incus device uses it as the guest node's group. The
name is generic because grants are not limited to media workloads; a later
grant holder such as Immich joins the same group through its own declared
grant.

`gpu-render` (506) is a guest-level contract. In the container, Incus sets it
on the node it creates. In a VM guest, the guest's own udev would set it on
the render node its driver creates (D12). Pods and Jellyfin see the same
group either way.

Alternatives: the guest's NixOS `render` GID (303) is a nixpkgs internal
number, not a fleet identity, and it means "any render user" rather than "has
this grant". Reusing the `media` group would give the GPU to every
media-storage holder, which is broader than the grant. The host keeps its own
`render` group (303) for declared host users (D3); `gpu-render` is the
guest-side grant capability.

### D7. Pods see the guest's `/dev/dri` directory, not a device plugin

- The guest creates an empty `/dev/dri` at boot (tmpfiles), so the path
  exists whether or not the GPU is present.
- The Jellyfin container mounts `hostPath: /dev/dri`
  (`type: Directory`) at `/dev/dri`. Because only the render node is passed
  into the guest, the Pod sees only `renderD128`, and only when the GPU is
  present when the Pod starts.
- The Pod keeps `runAsNonRoot`, drops all capabilities, keeps
  `allowPrivilegeEscalation = false`, and adds only GID 506 (`gpu-render`) to
  `supplementalGroups`.

Alternatives:

- `hostPath` of the node with `type: CharDevice` fails Pod start when the node
  is missing, which takes all of Jellyfin down, including playback that needs
  no transcode.
- The Intel GPU device plugin or a DRA driver adds a node-level DaemonSet that
  needs broad `/dev/dri` and sysfs access. With the GPU missing, the resource
  count is zero and a Pod that requests it stays Pending, which also takes all
  of Jellyfin down. Their value is scheduling and accounting across Pods and
  nodes.
  This is one consumer on one node. Reconsider when a second workload is
  granted or the cluster gains nodes.

Because the in-guest device cgroup is not enforced (see Context), the boundary
inside the guest is which Pods mount `/dev/dri` and the node's group and mode.
All manifests are rendered from Nix, so an evaluation check rejects any
`/dev` hostPath or use of GID 506 outside declared grants.

### D8. QSV on the render node, with conservative codec settings

Owner decision (item 8): accepted as proposed. The hardware variant is the
declared default and is applied by the existing Jellarr Job:

```yaml
encoding:
  enableHardwareEncoding: true
  hardwareAccelerationType: qsv
  qsvDevice: /dev/dri/renderD128
  vaapiDevice: /dev/dri/renderD128
  hardwareDecodingCodecs: [h264, hevc, mpeg2video, vc1, vp9, av1]
  enableDecodingColorDepth10Hevc: true
  enableDecodingColorDepth10Vp9: true
  enableDecodingColorDepth10HevcRext: true
  enableDecodingColorDepth12HevcRext: true
  allowHevcEncoding: false
  allowAv1Encoding: false
```

Software variant: `hardwareAccelerationType: none`,
`enableHardwareEncoding: false`. It is used only when an operator declares
software mode (D9).

- QSV over VA-API: Jellyfin recommends QSV on Arc. It uses oneVPL, supports
  AV1 encode, and uses VA-API underneath. VA-API remains an alternative
  setting if a QSV regression appears.
- VP8 is omitted because Gen12 media engines have no VP8 decoder.
- HEVC and AV1 output stay off at first for client compatibility. This is a
  setting, not a contract.
- Tone mapping and the low-power encoder toggles are not in Jellarr v0.1.0.
  Jellyfin uses low-power encoding by default on Arc. Tone mapping stays
  application-owned until Jellarr supports it (see "Deferrable unknowns").
- Because Jellarr's codec diff never removes entries, the software variant
  leaves the codec list as it was. It has no effect while the acceleration
  type is `none`.

### D9. Fail hard: a static encoding mode, set by the existing Jellarr Job

Owner decision (item 1): no automatic fallback. The transcoding mode is a
declared setting with two values, `hardware` (the default) and `software`. The
existing `PostSync` Jellarr Job renders the matching `encoding:` variant from
D8 into its configuration and applies it through Jellyfin's API. There is no
probe initContainer and no encoding sidecar. Jellarr stays the only settings
writer.

Behavior when the GPU or driver fails while `hardware` is declared:

- The compute guest, its management path, K3s, and other workloads keep
  running (D4, `required=false`).
- The Jellyfin Pod starts. `/dev/dri` exists but holds no render node, or the
  node cannot be initialized.
- Playback that needs no video transcode (direct play) works, because
  Jellyfin does not initialize the GPU for it. Direct stream (remux) does not
  transcode video and is expected to behave the same.
- A transcode that needs the GPU fails. The client shows a playback error,
  and Jellyfin's ffmpeg transcode log records the device or initialization
  error.
- Nothing changes the declared mode. When the GPU returns, Incus hotplugs the
  node into the guest. The Jellyfin Pod sees it no later than its next start
  (D7), and hardware transcodes work again with no configuration change.

Switching to software is an operator change: set the declared mode to
`software`, commit, and let Argo sync. The Jellarr Job then applies the
software variant. Switching back is the same change in reverse.

Detection. A documented check in `docs/operations/jellyfin.md` reports the
state without a playback attempt:

1. the declared mode, read from the rendered Jellarr configuration;
2. whether `/dev/dri/renderD128` exists in the Jellyfin container and is
   group `gpu-render`, mode `0660`;
3. whether Jellyfin's own `vainfo` (shipped with `jellyfin-ffmpeg`) opens the
   node as UID 751 and lists the iHD driver and its profiles;
4. if any step fails, host-side facts for the reason: the `by-path` source on
   `hvn-hyp1`, the bound driver, and the Incus device state.

If the mode is `software`, the check reports "software by declaration" and
stops. The check is the minimum the spec requires. Alerting on the same
signal is a follow-up for the `monitoring-and-alerting` change (PR #54). This
change does not depend on it.

Alternatives considered:

- **Probe at Pod start and apply the mode with a second, encoding-only
  Jellarr writer** (the first draft's recommendation). Rejected by the owner:
  it adds a second settings writer, two more containers, and an API key, and
  it hides a GPU failure behind slower software transcoding.
- **Probe and select inside the Jellarr Job.** The Job runs only on an Argo
  sync, so a GPU lost across a host reboot would not be noticed. It would also
  need its own device grant.
- **Write `encoding.xml` before start.** Forbidden by `jellyfin-lifecycle`.
- **Wait for upstream fallback** (jellyfin/jellyfin#17108). No date.

Because Jellarr remains the only writer, `jellyfin-lifecycle`'s writer and
ownership rules need no amendment (owner decision, item 6). This change adds
`encoding:` fields to the Jellarr configuration that rule already governs.

### D10. Resources stay as they are until acceptance measures them

Owner decision (item 5):

- Keep Jellyfin's 2-CPU limit until real-hardware acceptance measures use.
  With QSV, the GPU decodes, scales, overlays, and encodes. The CPU still
  demuxes, transcodes audio, renders text subtitles (libass), and uploads
  frames. 2 CPUs should be enough for several hardware streams.
- Memory is 4Gi since PR #49. The transcode cache becomes 64Gi with PR #53
  (open). This change does not change either.
- If an operator declares software mode, 2 CPUs give roughly one 1080p
  stream.
- The guest's `limits.cpu = 4` does not change.

### D11. Verification layers

| Layer | What it proves | Where |
| --- | --- | --- |
| Evaluation | Device declared once with `required=false`, `0660`, GID 506; project admits it; no `gpu` device; only declared grant holders mount `/dev/dri` or hold GID 506; no privileged Pods; the Jellarr Job config holds exactly the `encoding:` variant for the declared mode, and both variants pass Jellarr's strict schema; no other rendered workload runs Jellarr; host firmware enabled; host render-node rule sets group `render`, mode `0660` | `compute-contracts`, `jellyfin-contracts` |
| VM with stand-in | `vgem` provides a real, openable render node with no media engine. On the host VM it is group `render`, mode `0660`, and an undeclared host user cannot open it. The guest sees it as group `gpu-render`, mode `0660`; Jellyfin's Pod can open it; an ungranted Pod cannot see it; a non-holder cannot open it. With `vgem` unloaded, the guest and Jellyfin start, Jellyfin's encoding settings still say QSV, and the documented check reports the node missing. Loading `vgem` later hotplugs the node into the guest. Replacement keeps the grant. | `prod-home-replacement` |
| Operator acceptance | The documented check reports hardware usable; `vainfo` in the Pod shows the iHD driver and DG2 profiles; a forced 4K HEVC 10-bit to 1080p H.264 transcode shows hardware in Jellyfin's playback info; the host's Video engine is busy (`intel_gpu_top`, operator `sudo`); CPU stays within the limit; a subtitle burn-in plays smoothly | `docs/operations/jellyfin.md` |

`vkms` is not used: it provides a card node but no render node. The VM test
uses the stand-in's own node path as the device source; that path is a host
fact and does not change the contract.

### D12. VM cutover path

The owner wants to keep open a clean cutover of `compute-1` to a VM, with the
GPU shared through mediated devices or virtual functions. This change does
not do that cutover. It keeps the contract neutral so the cutover needs a new
mechanism, not a new contract. Storage, ID mapping, and the rest of a VM
cutover belong to `compute-recovery`; this section covers acceleration only.

**What changes in a VM cutover**

- *Attachment.* The `unix-char` render-node device (D4) is replaced by an
  Incus `gpu` device on the VM: `gputype=sriov` (a virtual function),
  `gputype=mdev` (a mediated device), or `gputype=physical` (whole-device
  VFIO passthrough). The project restriction changes from
  `restricted.devices.unix-char` to `restricted.devices.gpu`. None of these
  types hotplugs into a VM ([Incus GPU device reference][incus-gpu]).
- *Driving domain.* For a VF, mdev, or whole device, the guest kernel drives
  its share. The host still owns the physical device and its partitioning:
  it drives the physical function, creates the VFs or mdevs from declared
  configuration, and binds an attached VF or whole device to `vfio-pci`.
- *Guest image.* The `compute-1` NixOS image gains the guest-side kernel
  driver (`xe` for current SR-IOV-capable Intel cards; Battlemage SR-IOV
  support landed in Linux 6.17 ([Phoronix][phoronix-pro])) and
  redistributable firmware where its driver needs
  it. Whether a VF driver needs its own GuC/HuC files or relies on the host's
  physical-function firmware must be checked for the chosen card. The guest
  image also gains a udev rule that sets group `gpu-render` (506) and mode
  `0660` on the granted render node only, and gives it a stable path. The
  render node's number may differ inside a VM, because a virtual display
  adapter can also register DRM nodes.
- *Host.* IOMMU must be on. On `hvn-hyp1`, `CONFIG_INTEL_IOMMU=y` but
  `intel_iommu=on` is not on the command line and `/sys/kernel/iommu_groups`
  is empty; VT-d may also need enabling in firmware. SR-IOV also needs a
  host driver with PF support for the card.
- *Kubernetes.* The pod-level grant is the same: a declared grant holder, the
  `gpu-render` supplementary group, render node only. Only where the node
  comes from changes. One mechanism probably changes too: K3s in the
  container runs with `KubeletInUserNamespace`, so the in-guest device cgroup
  is not enforced and a `hostPath` mount of `/dev/dri` works (D7). In a VM,
  K3s would not need a user namespace, so runc's device cgroup would be
  enforced and an unprivileged Pod could not open a `hostPath`-mounted render
  node. Device delivery would then need a device plugin, CDI, or DRA. That is
  stronger isolation, and it is the point D7 already names for reconsidering
  a device plugin. Confirm this during the cutover.
- *Missing device.* A VM cannot hotplug its GPU, and Incus is expected to
  refuse to start an instance whose `gpu` device matches nothing, as in the
  container case (D4); this needs confirming for VMs. To keep "Accelerator
  loss affects only accelerated work", the VM design needs a declared way to
  start without the share, for example a host preflight that leaves the
  device off when its function is absent. Regaining access may then need a
  VM restart, which the spec allows.

**What stays the same**

- The spec's grant model: explicit host-to-domain and domain-to-workload
  grants, owner-declared grant holders, render interface only.
- The `gpu-render` group and GID 506.
- Jellyfin's declared transcoding mode and the Jellarr `encoding:` settings.
  QSV and the render-node path are set inside the guest, so they are
  unaffected as long as the guest presents the node at the same stable path.
- The acceleration check and the operator acceptance procedure (D9, D11).
- Detection, replacement, and verification requirements.

**Hardware finding: this card cannot be shared with a VM**

The Arc Pro A40/A50 in `hvn-hyp1` (DG2, `8086:56b1`) exposes no mdev types
and no SR-IOV virtual functions:

- Intel's graphics-virtualization table lists both Arc A-Series and Arc Pro
  A-Series (Alchemist) as "Not Supported". It lists GVT-g, the Intel mdev
  type, only for integrated graphics up to 11th Gen Core ([Intel
  000093216][intel-gvt]).
- In upstream Linux, `drivers/gpu/drm/xe/xe_pci.c` (commit `8b2d3bb7`, the
  file's latest change on `master`, which is at 7.3-rc6 as of this writing),
  `dg2_desc` does not set `has_sriov` and still sets
  `require_force_probe`. `8086:56b1` is in `INTEL_DG2_IDS`, which maps to
  `dg2_desc` ([xe_pci.c][xe-pci]). So moving this card to `xe` does not add
  SR-IOV.
- On the host: no `mdev_supported_types` and no `sriov_totalvfs` on
  `0000:85:00.0` (Context).

With this card, a VM could only take the whole GPU through VFIO passthrough.
The host and every other guest would lose it. Sharing one GPU between a VM
and anything else needs different hardware. Options, with the support
claims we could verify:

- *Intel Arc Pro B-Series (Battlemage).* Intel lists SR-IOV as supported
  ([Intel 000093216][intel-gvt]). Its supported configurations are 2 VFs for
  the B50 and 4 VFs for the B70 ([Intel 000103382][intel-vfs]). Upstream
  `xe` sets `has_sriov` for Battlemage without `force_probe`
  ([xe_pci.c][xe-pci]), and the support landed in Linux 6.17. Intel told
  Phoronix that consumer Arc B-Series cards will not get SR-IOV
  ([Phoronix][phoronix-pro]). Intel's B50 SR-IOV article names Ubuntu as the
  supported Linux host ([Intel 000102857][intel-b50]); NixOS is not a
  validated configuration.
- *Intel Data Center GPU Flex (Arctic Sound-M).* Intel lists SR-IOV as
  supported ([Intel 000093216][intel-gvt]). Intel's GPU documentation says
  Flex needs the out-of-tree `intel-i915-dkms` module ([Intel dGPU
  docs][intel-i915]). Upstream `xe` sets `has_sriov` for ATS-M but still
  requires `force_probe` ([xe_pci.c][xe-pci]).
- *virtio-gpu native context* (`gputype=native-context`) keeps the host
  driving this same card and shares it with a VM without IOMMU or SR-IOV.
  Media acceleration through it on DG2 is not established (D2).

**Keeping the cutover cheap now**

- The compute aspect's grant setting declares the attachment as a kind
  (render node today), so a VM kind can be added later without renaming the
  grant or the group.
- Pod-side declarations name the grant and `gpu-render`, not the
  device-origin mechanism.
- Evaluation checks that reject `gpu` devices (task 3.3) say that they apply
  to container guests, so a VM cutover change relaxes them in one place.

## Risks / Trade-offs

- [Kernel attack surface] The render node exposes i915 ioctls to Jellyfin. A
  compromised Jellyfin could try a driver bug to reach the host kernel. →
  Only owner-declared grant holders (Jellyfin alone today), non-root, no
  capabilities, `RuntimeDefault` seccomp, no card or control node, host
  kernel kept current. ADR-0001 allows narrow
  hardware delegation; record this grant there.
- [Coarse project restriction] `restricted.devices.unix-char = "allow"`
  admits any character device in the project. → NixOS owns the profile; the
  adoption gate rejects undeclared devices; an evaluation check pins the one
  allowed device.
- [No in-guest device cgroup] Any Pod that mounts `/dev/dri` and claims the
  GID could open the node. → Manifests come only from Nix through Argo, and
  an evaluation check limits `/dev` hostPaths and the GID to declared grants.
- [Hotplug through `by-path`] Unproven. → VM test; fallback described in D4.
- [Render minor renumbering] Another render-capable driver could take
  `renderD128`. → `by-path` source pins the PCI address.
- [GPU loss goes unnoticed] With no alerting, a lost GPU shows up only as
  failed transcodes or when someone runs the check. → The documented check
  detects it without a playback. Alerting is a follow-up for
  `monitoring-and-alerting` (PR #54).
- [Transcodes fail until an operator acts] With no automatic fallback, a GPU
  outage breaks transcoding until the GPU returns or an operator declares
  software mode. Direct play keeps working. → Accepted by the owner in
  exchange for one settings writer and a visible failure.
- [Hardware decoding in background tasks] If Jellyfin's application-owned
  settings use hardware decoding for trickplay or thumbnail extraction, those
  tasks also fail while the GPU is missing. → The operations document names
  this effect; the settings stay application-owned.
- [Host render-node tightening] A host process that relied on the `0666`
  default loses GPU access. → None is known; such a process joins `render` in
  host configuration. The guest node is created separately by Incus and is
  unaffected (D3).
- [Rollback leaves QSV configured] Removing the grant while Jellyfin's
  settings still say QSV breaks transcodes. → Rollback declares software mode
  first, then removes the device (see Migration Plan).
- [Upstream image changes] A Jellyfin release bump changes ffmpeg and the
  iHD driver. → Add hardware acceptance to the coupled-release upgrade
  checklist.
- [No Resizable BAR] 256 MiB BAR. → Jellyfin documents that A-series media
  tolerates it; acceptance measures throughput.
- [Driver transition] Intel is moving to `xe`. → Host-owned; rerun acceptance
  after kernel changes; the render node path is unchanged.
- [Engine hang] A GPU hang resets the engine and fails running streams. →
  i915 recovers the engine; later transcodes use it again. If it does not
  recover, the documented check reports it. No automatic restart is added.

## Migration Plan

Dependency: implementation starts only after `reproducible-jellyfin-compute`
is archived. Its last open item is owner acceptance task 4.1. This change
needs no amendment to that change (D9).

1. Host: make firmware ownership explicit, and add the udev rule that sets the
   render node to group `render`, mode `0660`. Add any host user that needs
   the GPU to `render`.
2. Fleet: add the `gpu-render` group (GID 506).
3. Guest image: create `/dev/dri` at boot. Deliver with the normal guest
   upgrade.
4. Compute envelope: add the `unix-char` device and project restriction.
   Native preseed updates the profile; Incus hotplugs a `unix-char` device
   into the running container, so no guest restart is needed.
5. Jellyfin manifests: add the `/dev/dri` mount, the `gpu-render` group, and
   the declared mode (`hardware`) with its `encoding:` variant in the Jellarr
   configuration. Argo sync recreates the Pod (`Recreate` strategy), and the
   `PostSync` Jellarr Job applies the encoding settings.
6. Operator acceptance on `hvn-hyp1`.

Rollback: first declare software mode and let the Jellarr Job apply it. Then
remove the Pod mount and group, then the Incus device and project restriction.
Never remove the device first. The host render-node rule can be reverted on
its own; it does not affect the guest.

## Resolved decisions

The first draft listed eight questions for the owner. All are decided, and
the owner added a ninth decision:

1. **Fallback (D9).** Fail hard, with no automatic fallback. The Jellarr Job
   sets QSV statically; no probe and no encoding sidecar. GPU loss fails
   hardware transcodes visibly and affects nothing else. A documented check
   detects the degraded state; alerting is a `monitoring-and-alerting`
   (PR #54) follow-up. Switching to software is a declared operator change.
2. **Eligibility (spec).** Explicit owner grants, not limited to media.
   Jellyfin is the first grant; Immich is expected later. Nothing else
   receives access.
3. **Group (D6).** `gpu-render`, GID 506.
4. **Attachment (D4).** Render node only, `unix-char`, `required=false`.
5. **Resources (D10).** Keep the CPU limit until real-hardware acceptance
   measures use. Memory is 4Gi (PR #49); transcode cache 64Gi (PR #53,
   pending).
6. **Ordering.** No amendment to `reproducible-jellyfin-compute`'s writer
   rules, because Jellarr remains the only settings writer. This change lands
   after that change is archived; its last open item is owner acceptance
   task 4.1.
7. **Host render node (D3).** Tighten from `0666` to `0660`, group `render`
   (host GID 303). Host processes that need the GPU join `render`. The guest
   is unaffected.
8. **Encoding defaults (D8).** QSV with HEVC and AV1 output off at first, as
   proposed. Tone mapping stays application-owned.
9. **VM cutover (spec, D12).** Keep a clean cutover of `compute-1` to a VM
   with GPU sharing possible; at least, do not make it harder than needed.
   The spec no longer assumes a container: the owner declares which domain
   drives the device or each share, the render interface and `gpu-render`
   hold whichever way the guest obtains the node, and sharing is allowed but
   not required. Container mechanisms stay in this design.

## Open questions

None block planning. The items below are decided during implementation or
later.

### Deferrable unknowns

- Whether Incus hotplug follows the `by-path` symlink. The VM test decides,
  and D4 names the fallback.
- When the host should move DG2 from `i915` to `xe`.
- Whether and when `compute-1` becomes a VM, and on which GPU. Sharing with
  a VM needs an SR-IOV-capable card (D12). The VM-specific points D12 marks
  for confirmation: Incus start behavior with a missing `gpu` device, the
  Kubernetes device-delivery mechanism, and VF firmware needs.
- How `monitoring-and-alerting` (PR #54) turns the documented check into an
  alert. Not a dependency of this change.
- Whether Jellyfin's CPU limit changes after real-hardware acceptance
  (task 8.4).
- Whether Jellarr should gain tone-mapping fields so Homelab can declare
  them. Until then tone mapping stays application-owned.
- How a second grant holder (Immich) receives the render node, and whether
  that is the point to adopt a device plugin or DRA driver (D7).
- Whether trickplay and thumbnail extraction should use hardware decoding.
  This is a Jellyfin setting and stays application-owned.

### Note on sources

The task brief named an active change `reliable-household-services`. No such
change exists at `main@origin` (18ecf7f9). The active changes are
`independent-service-exposure-contract`, `reproducible-application-compute`,
`reproducible-jellyfin-compute`, and `storage-placement-contract`.

[incus-gpu]: https://linuxcontainers.org/incus/docs/main/reference/devices_gpu/
[intel-gvt]: https://www.intel.com/content/www/us/en/support/articles/000093216/graphics/processor-graphics.html
[intel-vfs]: https://www.intel.com/content/www/us/en/support/articles/000103382/graphics/intel-arc-pro-dedicated-graphics-family.html
[xe-pci]: https://github.com/torvalds/linux/blob/8b2d3bb766c69976da4767fb3b7299a909367f58/drivers/gpu/drm/xe/xe_pci.c
[intel-b50]: https://www.intel.com/content/www/us/en/support/articles/000102857/graphics.html
[phoronix-pro]: https://www.phoronix.com/news/Intel-SR-IOV-Only-For-Arc-Pro
[intel-i915]: https://dgpu-docs.intel.com/overview/supported-hardware/i915-driver-gpus.html
