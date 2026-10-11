## Context

See proposal.md, "Why". The requirements are in
`specs/hardware-acceleration/spec.md`. This document records the facts the
design rests on, the mechanisms chosen, and what the owner must confirm.

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
  2 CPUs and 2 GiB memory (`modules/den/aspects/kubernetes/services/jellyfin.nix`).
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
- Keep the compute guest, its management path, and Jellyfin running when the
  GPU is missing.
- Pick hardware or software transcoding from a runtime probe, and make the
  choice visible.
- Prove the plumbing in existing checks and leave hardware proof to a short
  operator acceptance.

**Non-Goals:**

- A general GPU scheduling layer (device plugin, DRA) for multiple consumers
  or nodes.
- Tuning Jellyfin's encoding quality, tone mapping, or trickplay. These remain
  application-owned unless Jellarr gains the fields.
- Changing the host's display console or BMC VGA.

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
  ownership. Fallback is a Jellyfin behavior, but it follows from the device
  contract, and future media workloads will need the same rules.

The capability is therefore new, and its single Jellyfin-specific rule
(playback falls back to software) is phrased for "a media server".

### D2. `mdev` and SR-IOV do not apply; render-node sharing does

Incus `gpu` device types:

| Type | Instance | What it does | Fit for this host |
| --- | --- | --- | --- |
| `physical` | container | Bind-mounts the GPU's DRM nodes (card, render, control) into the container. The host keeps the driver; the GPU stays shared. | Works. |
| `physical` | VM | VFIO passthrough of the whole PCI device. The host loses the GPU. | Needs IOMMU (off today) and the whole IOMMU group, including the card's internal bridges and its HDMI audio function `86:00.0`. Exclusive to one VM. |
| `mdev` | VM only | A mediated vGPU, for Intel this is GVT-g (`i915-GVTg_V5_*`). | GVT-g supports only integrated GPUs from Broadwell to Comet Lake. DG2 has no mdev types; the host confirms `mdev_supported_types` is absent. |
| `sriov` | VM only | Passes a virtual function of an SR-IOV GPU. | Intel ships graphics SR-IOV for Gen12+ integrated GPUs (out-of-tree) and for data-center and newer Pro cards. Not for Alchemist A40/A50; the host shows no `sriov_totalvfs`. |
| `mig` | container only | NVIDIA MIG instances. | Not applicable. |
| `native-context` | VM only | virtio-gpu DRM native context; no passthrough. | Not evaluated. Video decode and encode through native context on Intel is experimental. |

The owner's note ("we can use incus's mdev if VM") does not hold for this
card. In the current container, the right mechanism is sharing the render
node: the host keeps the i915 driver, the GPU stays usable by more than one
consumer, and no IOMMU change is needed. If compute ever became a VM, the
practical option would be whole-GPU VFIO passthrough, which needs
`intel_iommu=on`, a clean IOMMU group, and gives up host and multi-guest use.
The spec says "render interface" and "grant", so a VM design could still meet
it with a different mechanism.

### D3. The host keeps i915 and makes firmware ownership explicit

- Keep `i915` for DG2. On this kernel `xe` binds DG2 only with
  `force_probe`, and i915 is Intel's supported driver for Alchemist.
- State `hardware.enableRedistributableFirmware = true` in host
  configuration instead of relying on the facter default, and add an
  evaluation check that it stays on. GuC and HuC are required for low-power
  encoding on DG2.
- Do not enable host graphics userspace (`hardware.graphics`). The host only
  needs the kernel driver and firmware. The media userspace ships in
  Jellyfin's official image.
- Do not change the host's render node mode (see Open questions, item 8).

### D4. Attach only the render node with an Incus `unix-char` device

Declare one device in the compute envelope:

```nix
devices.media-accel = {
  type = "unix-char";
  source = "/dev/dri/by-path/pci-0000:85:00.0-render";
  path = "/dev/dri/renderD128";
  required = "false";   # guest starts without it; hotplug when it appears
  uid = "0";
  gid = "<media-acceleration GID>";
  mode = "0660";
};
```

and set `restricted.devices.unix-char = "allow"` in the project, keeping
`restricted.devices.gpu = "block"`.

Why `unix-char` over `gpu` with `gputype=physical`:

- Incus fails to start a container whose `gpu` device matches no GPU
  ("Failed to detect requested GPU device", `gpu_physical.go`). A missing or
  unbound GPU would stop the whole compute guest and every workload in it,
  which breaks "Accelerator loss does not gate compute or unrelated
  workloads".
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

Add a POSIX fleet group, proposed name `media-acceleration`, GID 506, in
`modules/den/groups/default.nix`. Jellyfin's Pod lists it in
`supplementalGroups`. The Incus device uses it as the node's group.

Alternatives: the guest's NixOS `render` GID (303) is a nixpkgs internal
number, not a fleet identity, and it means "any render user" rather than "has
this grant". Reusing the `media` group would give the GPU to every
media-storage holder, which is broader than the grant.

### D7. Pods see the guest's `/dev/dri` directory, not a device plugin

- The guest creates an empty `/dev/dri` at boot (tmpfiles), so the path
  exists whether or not the GPU is present.
- The Jellyfin container and its probe mount `hostPath: /dev/dri`
  (`type: Directory`) at `/dev/dri`. Because only the render node is passed
  into the guest, the Pod sees only `renderD128`, and only when the GPU is
  present when the Pod starts.
- The Pod keeps `runAsNonRoot`, drops all capabilities, keeps
  `allowPrivilegeEscalation = false`, and adds only the capability GID to
  `supplementalGroups`.

Alternatives:

- `hostPath` of the node with `type: CharDevice` fails Pod start when the node
  is missing, which takes Jellyfin down instead of falling back.
- The Intel GPU device plugin or a DRA driver adds a node-level DaemonSet that
  needs broad `/dev/dri` and sysfs access. With the GPU missing, the resource
  count is zero and a Pod that requests it stays Pending, which also breaks
  fallback. Their value is scheduling and accounting across Pods and nodes.
  This is one consumer on one node. Reconsider when a second workload is
  granted or the cluster gains nodes.

Because the in-guest device cgroup is not enforced (see Context), the boundary
inside the guest is which Pods mount `/dev/dri` and the node's group and mode.
All manifests are rendered from Nix, so an evaluation check rejects any
`/dev` hostPath or use of the capability GID outside declared grants.

### D8. QSV on the render node, with conservative codec settings

Desired hardware variant, applied through Jellarr:

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
`enableHardwareEncoding: false`.

- QSV over VA-API: Jellyfin recommends QSV on Arc. It uses oneVPL, supports
  AV1 encode, and uses VA-API underneath. VA-API remains the fallback if a
  QSV regression appears.
- VP8 is omitted because Gen12 media engines have no VP8 decoder.
- HEVC and AV1 output stay off at first for client compatibility. This is a
  setting, not a contract.
- Tone mapping and the low-power encoder toggles are not in Jellarr v0.1.0.
  Jellyfin uses low-power encoding by default on Arc. Tone mapping stays
  application-owned until Jellarr supports it (Open questions, item 5).
- Because Jellarr's codec diff never removes entries, the software variant
  leaves the codec list as it was. It has no effect while the acceleration
  type is `none`.

### D9. Fallback: probe at Pod start, apply encoding through Jellarr per start

The spec requires software fallback no later than the media server's next
start. Jellyfin has no fallback of its own, and `jellyfin-lifecycle` forbids
writing its XML or SQLite. The encoding mode must therefore be chosen at run
time and applied through the API after each start. Recommended mechanism:

1. **Probe.** An `accel-probe` initContainer in the Jellyfin Pod uses the
   pinned stock runtime image (same digest, no new image). It runs as UID 751
   with the capability group, so it tests the same permission path as the
   server. It runs a bounded `jellyfin-ffmpeg` check: open the render node,
   initialize VA-API and derive QSV, and encode a few frames of a generated
   test source with `h264_qsv` to a null sink, with a timeout of about 20
   seconds. It always exits 0. It writes `hardware` or
   `software: <reason>` to a memory-backed `emptyDir` and to its termination
   message.
2. **Apply.** A native sidecar (an initContainer with
   `restartPolicy: Always`) in the same Pod runs the existing Jellarr image and
   bootstrap. It waits for `/health`, reads the verdict, reconciles a Jellarr
   config that contains only the matching `encoding:` variant, logs the
   result, and then idles. It reuses the `jellyfin-admin` Secret already
   mounted in the Pod for the provisioner, and it uses its own API key name
   (for example `Jellarr encoding`) so it cannot race the Job's
   find-or-create of the `Jellarr` key.
3. **Ownership.** The PostSync Jellarr Job keeps every other declared field
   and its config must not contain `encoding:`. The per-start reconciliation
   owns only the encoding fields. An evaluation check enforces the split.

Observable places, documented in `docs/operations/jellyfin.md`:

- the probe's termination message on the current Jellyfin Pod;
- the sidecar's log line naming the applied variant;
- Jellyfin's Dashboard, Playback, Transcoding page.

Alternatives considered:

- **Fail visibly, switch by hand.** A declared setting selects `hardware` or
  `software`; the probe only reports. No second writer, but transcoding stays
  broken until an operator changes the setting. Direct play still works.
  Simpler, and the fallback if the owner rejects a second writer.
- **Probe and select inside the Jellarr Job.** The Job runs only on an Argo
  sync, so a GPU lost across a host reboot would not be detected. It would
  also need its own device grant.
- **Write `encoding.xml` before start.** Forbidden by `jellyfin-lifecycle`.
- **Wait for upstream fallback.** No date.
- **Restart Jellyfin on probe failure.** Restarting does not change its
  settings.

This adds a second Jellarr writer, scoped to encoding fields. The
`jellyfin-lifecycle` ownership requirement in the active
`reproducible-jellyfin-compute` change describes Jellarr as one one-shot Job.
That text must be reconciled with this design before implementation (Open
questions, item 7).

### D10. Resources stay as they are until acceptance measures them

- With QSV, the GPU decodes, scales, overlays, and encodes. The CPU still
  demuxes, transcodes audio, renders text subtitles (libass), and uploads
  frames. The 2-CPU limit should be enough for several hardware streams;
  acceptance records actual CPU use.
- Memory stays at 2 GiB until acceptance shows QSV or tone mapping needs more
  (Open questions, item 6).
- In software fallback, 2 CPUs give roughly one 1080p stream. The spec accepts
  that as degraded service.
- The guest's `limits.cpu = 4` does not change.

### D11. Verification layers

| Layer | What it proves | Where |
| --- | --- | --- |
| Evaluation | Device declared once with `required=false`, `0660`, the capability GID; project admits it; no `gpu` device; only granted Pods mount `/dev/dri` or hold the GID; no privileged Pods; Job config has no `encoding:`; both encoding variants pass Jellarr's strict schema; host firmware enabled | `compute-contracts`, `jellyfin-contracts` |
| VM with stand-in | `vgem` provides a real, openable render node with no media engine. The guest sees it with the declared group and mode; Jellyfin's Pod can open it; an ungranted Pod cannot see it; a non-holder cannot open it; with `vgem` unloaded the guest and Jellyfin start, the probe reports `software`, and the software variant is applied; loading `vgem` later hotplugs the node into the guest; replacement keeps the grant | `prod-home-replacement` |
| Operator acceptance | `vainfo` in the Pod shows the iHD driver and DG2 profiles; a forced 4K HEVC 10-bit to 1080p H.264 transcode shows hardware in Jellyfin's playback info; the host's Video engine is busy (`intel_gpu_top`, operator `sudo`); CPU stays within the limit; a subtitle burn-in plays smoothly | `docs/operations/jellyfin.md` |

`vkms` is not used: it provides a card node but no render node. The VM test
uses the stand-in's own node path as the device source; that path is a host
fact and does not change the contract.

## Risks / Trade-offs

- [Kernel attack surface] The render node exposes i915 ioctls to Jellyfin. A
  compromised Jellyfin could try a driver bug to reach the host kernel. →
  Only one workload, non-root, no capabilities, `RuntimeDefault` seccomp, no
  card or control node, host kernel kept current. ADR-0001 allows narrow
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
- [Second settings writer] Two Jellarr runs could conflict. → Disjoint field
  sets, separate API key names, and an evaluation check.
- [Rollback leaves QSV configured] Removing the grant while Jellyfin's
  settings still say QSV breaks transcodes, because Jellyfin does not fall
  back. → Rollback applies the software variant first, then removes the
  device (see Migration Plan).
- [Upstream image changes] A Jellyfin release bump changes ffmpeg and the
  iHD driver. → Add hardware acceptance to the coupled-release upgrade
  checklist.
- [No Resizable BAR] 256 MiB BAR. → Jellyfin documents that A-series media
  tolerates it; acceptance measures throughput.
- [Driver transition] Intel is moving to `xe`. → Host-owned; rerun acceptance
  after kernel changes; the render node path is unchanged.
- [Engine hang] A GPU hang resets the engine and fails running streams. →
  The next Pod start re-probes; no automatic restart is added.

## Migration Plan

1. Host: make firmware ownership explicit (no runtime change).
2. Fleet: add the `media-acceleration` group.
3. Guest image: create `/dev/dri` at boot. Deliver with the normal guest
   upgrade.
4. Compute envelope: add the `unix-char` device and project restriction.
   Native preseed updates the profile; Incus hotplugs a `unix-char` device
   into the running container, so no guest restart is needed.
5. Jellyfin manifests: add the probe, the `/dev/dri` mount, the group, the
   per-start encoding reconciliation, and remove any `encoding:` from the Job.
   Argo sync recreates the Pod (`Recreate` strategy).
6. Operator acceptance on `hvn-hyp1`.

Rollback: first deploy manifests that pin the software variant, or set
Jellyfin's acceleration to `none` through Jellarr. Then remove the Pod mount
and group, then the Incus device and project restriction. Never remove the
device first.

## Open questions

### Decisions the owner must confirm

Each item has a recommendation in this design. Changing one changes the
named decision and its tasks.

1. **Fallback mechanism (D9).** Automatic per-start selection with a second,
   encoding-only Jellarr run (recommended), or fail-visible with a manual
   switch.
2. **Who may be granted (spec).** Media-processing workloads only
   (recommended), with Jellyfin as the only grant now. Is any second consumer
   expected soon (for example a media analysis tool), or should non-media use
   such as LLM inference be considered now?
3. **Capability group (D6).** Name `media-acceleration` and GID 506?
4. **Guest attachment (D4).** `unix-char` render-only with hotplug
   (recommended), or `gpu` `physical` with `pci=` (simpler selection, but the
   guest will not start when the GPU is missing and the card node is
   exposed).
5. **Encoding defaults (D8).** Keep HEVC and AV1 output off at first? Should
   tone mapping stay application-owned, or should Jellarr be extended so
   Homelab declares it?
6. **Resource limits (D10).** Keep 2 CPUs and 2 GiB until acceptance, or
   raise memory now?
7. **Coordination with `reproducible-jellyfin-compute`.** Implement after
   that change is archived, and amend its `jellyfin-lifecycle` ownership
   requirement to name the per-start encoding reconciliation?
8. **Host render node mode.** The host's render node is `0666` (systemd
   default), so any host process can use the GPU. This does not affect the
   guest, whose node Incus creates as `0660`. Tighten it to `0660` on the
   host?

### Deferrable unknowns

- Whether Incus hotplug follows the `by-path` symlink. The VM test decides,
  and D4 names the fallback.
- When the host should move DG2 from `i915` to `xe`.
- Exporting the probe verdict as a metric once a monitoring stack exists.
- Whether trickplay and thumbnail extraction should use hardware decoding.
  This is a Jellyfin setting and stays application-owned.

### Note on sources

The task brief named an active change `reliable-household-services`. No such
change exists at `main@origin` (18ecf7f9). The active changes are
`independent-service-exposure-contract`, `reproducible-application-compute`,
`reproducible-jellyfin-compute`, and `storage-placement-contract`.
