## Why

Jellyfin transcodes in software today. Its container is limited to 2 CPUs of
a Broadwell Xeon E5-2690 v4, which can sustain about one 1080p H.264
transcode. 4K HEVC sources, HDR tone mapping, and subtitle burn-in stutter or
fail. The host, `hvn-hyp1`, already has an Intel Arc Pro A40/A50-class GPU
(DG2) with working i915 driver, GuC, and HuC firmware. That GPU's media
engines are idle.

No current contract says who may use a host GPU, how access crosses the
unprivileged compute boundary, or what happens when the GPU is missing. The
compute project blocks every GPU and character device today. ADR-0001 says to
return for a decision when a workload needs hardware access, rather than
widening the boundary. This change is that decision.

## What Changes

- Introduce a `hardware-acceleration` contract for host accelerators shared
  with workloads:
  - The physical host owns the accelerator, its kernel driver, and its
    firmware. Guests and workloads only consume it.
  - Access is an explicit, reviewable grant at two levels: host to compute
    domain, then compute domain to a named workload. A workload cannot grant
    itself access.
  - Grants are limited to media-processing workloads. Jellyfin is the first
    and only grant in this change.
  - Access is the GPU's render interface only, held through a stable group
    capability, like the media storage capability. No privileged containers,
    no display or modesetting interface, and no broad device access.
  - Losing the accelerator does not stop the compute domain, unrelated
    workloads, or the media workload itself.
  - Replacement compute regains the grant from declared configuration.
  - Device and group plumbing is verified without real hardware. Real
    hardware use is verified by operator acceptance on the target host.
- Decide failure behavior for Jellyfin: when acceleration is unavailable,
  transcoding continues in software, and the degraded state is reported where
  an operator can see it without reproducing a failed playback. Jellyfin has
  no built-in fallback (upstream issues #4389 and #17108), so Homelab must
  select the encoding mode from a runtime probe.
- Current behavior: no accelerator reaches the compute guest
  (`restricted.devices.gpu` and `restricted.devices.unix-char` are `block`),
  and Jellyfin's encoding settings are application defaults (software).
  Target behavior: the render interface reaches Jellyfin through the grant,
  and Jellyfin uses hardware transcoding when a probe proves it works.

### Non-goals

- GPU access for non-media workloads such as LLM inference or general GPU
  compute. That needs a separate decision.
- Converting the compute guest to a VM, or using VFIO, `mdev` (GVT-g), or
  SR-IOV. None applies to the current container, and the card supports
  neither `mdev` nor SR-IOV. See design.md.
- Rebuilding or patching Jellyfin's runtime image, ffmpeg, or GPU userspace.
  These stay upstream-owned, as `jellyfin-lifecycle` already requires.
- Changing the host kernel, firmware source, or BIOS (Resizable BAR is not
  available on this platform).
- Exclusive GPU scheduling, quotas, or multi-node GPU placement.
- Monitoring or alerting infrastructure. This change requires that the
  degraded state be observable, not that a pager exists.

## Capabilities

### New Capabilities

- `hardware-acceleration`: ownership, grant, scope, failure, recovery, and
  verification contract for host hardware accelerators delegated through the
  compute boundary to media workloads, including Jellyfin's software
  fallback.

### Modified Capabilities

None. `compute-recovery` (active change `reproducible-application-compute`)
already requires an unprivileged compute domain to declare its host-granted
devices and to reject undeclared ones. `jellyfin-lifecycle` (active change
`reproducible-jellyfin-compute`) already requires steady-state settings to go
through supported APIs. This change adds a contract that depends on both
without changing their requirements. If the chosen fallback mechanism adds a
second encoding-settings writer, `jellyfin-lifecycle`'s ownership list must be
updated in coordination with that change. See design.md, Open questions.

## Impact

- `hvn-hyp1` host configuration: explicit driver and firmware ownership, and
  the device grant declared in the compute envelope.
- Compute envelope (`modules/den/aspects/virtualization/compute.nix`): project
  restrictions and descriptor change to admit exactly the declared render
  device; adoption drift checks cover it.
- Fleet groups (`modules/den/groups/default.nix`): a new stable POSIX group
  for the accelerator capability.
- Jellyfin manifests (`modules/den/aspects/kubernetes/services/jellyfin.nix`):
  device mount, supplementary group, a probe, and encoding selection through
  Jellarr.
- Checks: evaluation checks for grant scope; the `prod-home-replacement` VM
  test gains a stand-in render node; a new operator acceptance procedure in
  `docs/operations/jellyfin.md`.
- Security: a granted workload can reach the host's i915 kernel driver
  through the render node. This is a real increase in kernel attack surface
  for Jellyfin, accepted as narrow and recorded in design.md.
- Decisions the owner must confirm are listed in design.md under "Open
  questions".
