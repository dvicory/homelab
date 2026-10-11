---
id: ADR-0010
status: accepted
date: 2026-10-11
updated: 2026-10-11
decision-makers:
  - Daniel Vicory
consulted: []
informed: []
supersedes: []
superseded-by: []
modifies:
  - ADR-0001
modified-by: []
related-adrs:
  - ADR-0001
related-specs:
  - hardware-acceleration
  - jellyfin-lifecycle
related-changes:
  - jellyfin-hardware-transcoding
target-architecture: []
---

# Delegate a host GPU's render interface to declared workloads

## Context and decision drivers

ADR-0001 keeps the compute guest unprivileged and says to return for a
decision when a workload needs hardware access. Jellyfin needs the host's
Intel Arc GPU to transcode: two CPUs of the host cannot keep up with 4K
sources. The compute project blocked every GPU and character device.

The decision has to keep the boundary narrow, survive a missing GPU, and not
assume the guest stays a container.

## Considered options

- **Pass the render node only (Incus `unix-char`, optional).** The host keeps
  the driver; the guest gets one render node with a dedicated group.
- **Incus `gpu` device (`physical`).** Also passes card and control nodes, and
  Incus refuses to start the guest when the GPU is missing.
- **VM with the GPU passed through (VFIO).** The host and every other domain
  lose the GPU. This Arc Pro A40/A50 has no SR-IOV or mediated devices, so a
  VM could not share it.
- **Device plugin or DRA driver in the cluster.** Adds a privileged node agent
  for one consumer on one node; a Pod that requests a missing GPU stays
  Pending.

## Decision outcome

Accept a narrow hardware delegation, as the `hardware-acceleration` contract
of the `jellyfin-hardware-transcoding` change states:

- The host drives the GPU and its firmware. It passes only the render node to
  the compute guest, as an optional device: the guest and its workloads start
  without it.
- Inside the guest the node carries the fleet group `gpu-render` (GID 506),
  mode `0660`. Only workloads the owner declares hold that group and mount the
  node. Jellyfin is the first. No workload is privileged or gains a
  capability.
- On the host, the render node is group `render`, mode `0660`, and only
  declared host users are in `render`.
- Jellyfin's transcoding mode is declared. With the GPU missing, hardware
  transcodes fail visibly; a documented check reports why.

This modifies ADR-0001's "return for a decision" rule for this one grant: the
render-node delegation is accepted, and further grant holders follow the same
rules without a new decision. Wider device access, privileged guests or
workloads, and display or modesetting interfaces still need one.

### Container or VM guest

The contract is neutral between a container and a VM guest. Design D12 of the
change records the VM path: the attachment changes to an Incus `gpu` device
(SR-IOV virtual function, mediated device, or whole device), the guest kernel
drives its share, and the guest gives the node the same `gpu-render` group.
This card cannot be shared with a VM; that needs, for example, an Arc Pro
B-Series card with SR-IOV.

### Consequences and confirmation

- Jellyfin can reach the host's i915 driver through the render node. This is
  accepted kernel attack surface, bounded by one declared holder, a non-root
  identity, no capabilities, `RuntimeDefault` seccomp, and no card node.
- `restricted.devices.unix-char = allow` admits any character device in the
  compute project. Evaluation pins the one render node; the adoption gate
  rejects undeclared devices.
- Incus 7.4 does not add a device to a running guest when its source is a
  `/dev/dri/by-path` link, because udev creates those links by rename. The
  source is therefore `renderD128`, and a host check reports drift if that
  name ever belongs to another PCI device.
- Confirmation: `compute-contracts`, `jellyfin-contracts`, the
  `prod-home-replacement` and `compute-guest-upgrade` VM tests with a `vgem`
  stand-in, and operator acceptance on the target host
  (`docs/operations/jellyfin.md`, "Accept hardware transcoding").

## Reconsider when

A second workload needs the GPU at the same time and needs scheduling or
accounting, the cluster gains nodes, the compute guest becomes a VM, or the
GPU is replaced.
