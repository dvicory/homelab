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
  - The host owns the physical device and its partitioning. The owner
    declares which domain drives the device or each share of it: the host,
    or the one guest that holds that share. Workloads never load drivers or
    firmware. Today the host drives the whole device and the guest gets the
    render interface.
  - The contract does not assume the compute guest is a container. A later
    cutover of `compute-1` to a VM, with a shared or whole GPU, needs a new
    mechanism but no contract change (design D12).
  - Sharing one GPU among the host and several guests is allowed, not
    required. Each grant is explicit, and no grant reaches beyond its share.
  - On the host, only declared host users and granted guests can use the
    render interface.
  - Access is an explicit, reviewable grant at two levels: host to compute
    domain, then compute domain to a named workload. A workload cannot grant
    itself access.
  - Any workload the owner explicitly declares may hold a grant; nothing else
    may. Eligibility is not limited to media. Jellyfin is the first and only
    grant in this change; Immich is expected later.
  - Access is the GPU's render interface only, held through a stable group
    capability (`gpu-render`, GID 506), like the media storage capability. No
    privileged containers, no display or modesetting interface, and no broad
    device access.
  - Losing the accelerator affects only accelerated work. The compute domain,
    unrelated workloads, and the granted workload keep running, and playback
    that needs no transcode keeps working.
  - Replacement compute regains the grant from declared configuration.
  - Device and group plumbing is verified without real hardware. Real
    hardware use is verified by operator acceptance on the target host.
- Decide failure behavior for Jellyfin: fail hard, with no automatic
  fallback. The transcoding mode is declared. The existing Jellarr `PostSync`
  Job sets hardware (QSV) encoding statically, and Jellarr stays the only
  settings writer. If the GPU or driver fails, hardware transcodes fail
  visibly. A documented check detects the degraded state without a playback
  attempt. Switching to software is a declared operator change.
- Current behavior: no accelerator reaches the compute guest
  (`restricted.devices.gpu` and `restricted.devices.unix-char` are `block`),
  Jellyfin's encoding settings are application defaults (software), and the
  host render node is mode `0666`, so any host process can use the GPU.
  Target behavior: the render interface reaches Jellyfin through the grant,
  Jellyfin is declared to use QSV, and the host render node is `0660`, group
  `render`.

### Non-goals

- Granting any workload other than Jellyfin. Immich or any other workload
  needs its own declared grant in a later change.
- Automatic software fallback. Jellyfin has none (upstream issues #4389 and
  #17108), and the owner chose a visible failure over a second settings
  writer.
- Converting the compute guest to a VM now, or using VFIO, `mdev`, or
  SR-IOV. The contract keeps that cutover open. This card supports neither
  `mdev` nor SR-IOV, so a VM could only take the whole GPU; sharing with a
  VM needs different hardware. See design.md, D12.
- Rebuilding or patching Jellyfin's runtime image, ffmpeg, or GPU userspace.
  These stay upstream-owned, as `jellyfin-lifecycle` already requires.
- Changing the host kernel, firmware source, or BIOS (Resizable BAR is not
  available on this platform).
- Exclusive GPU scheduling, quotas, or multi-node GPU placement.
- Monitoring or alerting infrastructure. This change requires that the
  degraded state be detectable by a documented check. Alerting on it is a
  follow-up for the `monitoring-and-alerting` change (PR #54); this change
  does not depend on it.
- Changing Jellyfin's resource limits. The CPU limit stays until
  real-hardware acceptance measures use.

## Capabilities

### New Capabilities

- `hardware-acceleration`: ownership, driving domain, sharing, host access,
  grant, eligibility, scope, failure, detection, recovery, and verification
  contract for host hardware accelerators delegated through the compute
  boundary, whether the guest is a container or a VM, to owner-declared
  workloads, including Jellyfin's declared transcoding mode.

### Modified Capabilities

None. `compute-recovery` (active change `reproducible-application-compute`)
already requires an unprivileged compute domain to declare its host-granted
devices and to reject undeclared ones. `jellyfin-lifecycle` (active change
`reproducible-jellyfin-compute`) already requires steady-state settings to go
through supported APIs, with Jellarr as the only writer. Jellarr stays the
only writer here, so neither requirement changes.

Dependency: implementation lands after `reproducible-jellyfin-compute` is
archived. Its last open item is owner acceptance task 4.1.

## Impact

- `hvn-hyp1` host configuration: explicit driver and firmware ownership, a
  udev rule that sets the render node to `0660`, group `render`, and the
  device grant declared in the compute envelope.
- Compute envelope (`modules/den/aspects/virtualization/compute.nix`): project
  restrictions and descriptor change to admit exactly the declared render
  device; adoption drift checks cover it.
- Fleet groups (`modules/den/groups/default.nix`): a new stable POSIX group,
  `gpu-render` (GID 506).
- Jellyfin manifests (`modules/den/aspects/kubernetes/services/jellyfin.nix`):
  device mount, supplementary group, a declared transcoding mode, and the
  matching `encoding:` settings in the existing Jellarr Job.
- Checks: evaluation checks for grant scope, single settings writer, and the
  host render-node rule; the `prod-home-replacement` VM test gains a stand-in
  render node; a new acceleration check and operator acceptance procedure in
  `docs/operations/jellyfin.md`.
- Security: a granted workload can reach the host's i915 kernel driver
  through the render node. This is a real increase in kernel attack surface
  for Jellyfin, accepted as narrow and recorded in design.md. Tightening the
  host node removes GPU access from undeclared host processes.
- The owner's decisions on the first draft's open questions are recorded in
  design.md under "Resolved decisions".
