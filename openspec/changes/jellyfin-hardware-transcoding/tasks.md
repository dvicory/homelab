## 0. Gate

- [ ] 0.1 Start implementation only after `reproducible-jellyfin-compute` is archived (its last open item is owner acceptance task 4.1); verify `openspec list` no longer shows it and `openspec/specs/jellyfin-lifecycle/spec.md` exists. No amendment to its writer rules is needed, because Jellarr stays the only settings writer (design D9).
- [ ] 0.2 After that archive, rebase this change and confirm design.md still matches the archived `jellyfin-lifecycle` and the merged Jellyfin resources (memory 4Gi from PR #49; transcode cache 64Gi if PR #53 has merged); verify `openspec validate jellyfin-hardware-transcoding --strict` passes.

## 1. Host ownership

- [ ] 1.1 Declare `hardware.enableRedistributableFirmware = true` explicitly in the `hvn-hyp1` host configuration and keep host graphics userspace off; verify with `nix eval` of both options for `nixosConfigurations.hvn-hyp1`.
- [ ] 1.2 Add an evaluation assertion to `compute-contracts` that a host declaring an accelerator grant has redistributable firmware enabled; verify the check fails when the option is set to false in a fixture.
- [ ] 1.3 Add a host udev rule on `hvn-hyp1`, ordered after systemd's default rules, that sets DRM render nodes to group `render` and mode `0660` (design D3); verify the rule appears in the evaluated `services.udev` rules for `nixosConfigurations.hvn-hyp1`.
- [ ] 1.4 List the host users that need the GPU and add them to `render` in host configuration (none expected today); verify with `nix eval` of `users.groups.render.members` for `hvn-hyp1`, and add a `compute-contracts` assertion that the render-node rule is present whenever the host declares an accelerator grant.

## 2. Capability group

- [ ] 2.1 Add the `gpu-render` POSIX fleet group (GID 506) to `modules/den/groups/default.nix` and the deterministic-ID registry; verify that the fleet-groups assertion resolves it to the same GID on `hvn-hyp1` and `compute-1`.

## 3. Compute envelope

- [ ] 3.1 Add an accelerator-grant setting to `den.aspects.virtualization.compute` that declares the driving domain (host) and an attachment kind (only `render-node` accepted now, so a VM kind can be added later; design D12), and for `render-node` renders exactly one `unix-char` device (render node source, guest path `/dev/dri/renderD128`, `required=false`, `uid=0`, GID 506 `gpu-render`, mode `0660`) and sets `restricted.devices.unix-char = "allow"` while `restricted.devices.gpu` stays `block`; verify by evaluating the preseed profile and `/etc/homelab/compute.json` for `hvn-hyp1`.
- [ ] 3.2 Do not add the capability to `storageCapabilities`; verify with a `compute-contracts` assertion that `raw.idmap` is unchanged by the grant.
- [ ] 3.3 Extend `compute-contracts` so evaluation fails, for container compute guests, when a second `unix-char` device, any `gpu` device, or a grant without `required=false`, mode `0660`, and GID 506 is declared; verify each rejected fixture fails and the real configuration passes.
- [ ] 3.4 Extend the compute-runtime adoption tests so an undeclared `unix-char` device on the profile is reported as drift; verify with `go test ./...` in `pkgs/by-name/compute-runtime`.
- [ ] 3.5 Declare the grant on `hvn-hyp1` with the `by-path` render source; verify the evaluated device source is `/dev/dri/by-path/pci-0000:85:00.0-render`.

## 4. Guest

- [ ] 4.1 Create an empty `/dev/dri` directory at boot in the `compute-1` guest; verify with `nix eval` of the guest's tmpfiles rules.

## 5. Jellyfin workload

- [ ] 5.1 Mount guest `/dev/dri` (`hostPath`, `type: Directory`) into the Jellyfin container and add GID 506 (`gpu-render`) to the Pod's `supplementalGroups`, keeping non-root, no capabilities, and no privilege escalation; verify in the rendered manifests under `generated/manifests/prod-home/jellyfin`.
- [ ] 5.2 Add a declared transcoding-mode setting for Jellyfin with values `hardware` (default) and `software`; verify `nix eval` shows `hardware` for prod-home.
- [ ] 5.3 Render the `encoding:` variant for the declared mode (design D8) into the existing PostSync Jellarr Job configuration, and validate both variants against Jellarr's strict configuration schema in `jellyfin-contracts`; verify an unknown encoding key fails the check and a `software` fixture renders `hardwareAccelerationType: none`.
- [ ] 5.4 Add a `jellyfin-contracts` assertion that the PostSync Jellarr Job is the only rendered workload that runs Jellarr or writes Jellyfin settings, with no probe initContainer or encoding sidecar; verify a fixture that adds a second Jellarr container fails.
- [ ] 5.5 Add a `jellyfin-contracts` assertion that only declared grant holders (the Jellyfin Deployment today) mount a `/dev` hostPath or list GID 506, and that no rendered Pod is privileged; verify a fixture with an undeclared Pod holding the GID fails.
- [ ] 5.6 Regenerate manifests with `nix run .#sync-prod-home-manifests`; verify `checks.<system>.prod-home-manifests-fresh` passes.

## 6. Stand-in runtime test

- [ ] 6.1 Extend `prod-home-replacement` so the host VM loads `vgem` and the compute grant uses the stand-in's render node as source; verify the host node is group `render`, mode `0660`, an undeclared host user cannot open it, and the guest shows `/dev/dri/renderD128` with GID 506 and mode `0660`.
- [ ] 6.2 In the same test, verify the Jellyfin process can open the node, an ungranted test Pod has no `/dev/dri/renderD128`, and a process without GID 506 gets permission denied.
- [ ] 6.3 Start the guest with `vgem` unloaded; verify the guest, K3s, and Jellyfin become ready, Jellyfin's encoding configuration (read through its API) still has acceleration `qsv`, and the documented acceleration check reports the render node missing.
- [ ] 6.4 Load `vgem` after the guest started; verify the node appears in the guest without a restart (this decides the `by-path` hotplug question in design D4; switch to the fallback in D4 if it fails).
- [ ] 6.5 Replace the compute instance through the declared replacement procedure; verify the replacement guest has the grant and the Jellyfin Pod sees the node, with no manual device steps.

## 7. Operations and records

- [ ] 7.1 Add to `docs/operations/jellyfin.md` the acceleration check from design D9 (declared mode, render node presence and owner in the Pod, `vainfo` as UID 751, host-side reasons), the procedure to declare software mode and switch back, the effect of GPU loss (hardware transcodes fail; direct play works), the rollback order (software mode first, device last), and the operator acceptance procedure; verify each command against the rendered names.
- [ ] 7.2 Add hardware acceptance to the Jellyfin coupled-release upgrade steps in `docs/operations/jellyfin.md`; verify the upgrade section lists it.
- [ ] 7.3 Record the render-node grant as the accepted narrow hardware delegation in ADR-0001 (or a new ADR that modifies it); verify the ADR front matter links this change.
- [ ] 7.4 Open a follow-up for `monitoring-and-alerting` (PR #54) to alert on the acceleration check's degraded state; verify the follow-up links this change. This change does not wait for it.
- [ ] 7.5 Record in ADR-0001 (or the new ADR from 7.3) that the delegation contract is neutral between container and VM guests, and cite design D12 for the VM cutover path and the hardware finding; verify the ADR links D12.

## 8. Operator acceptance on `hvn-hyp1` (separately authorized)

- [ ] 8.1 After deployment, run the documented acceleration check and `vainfo --display drm --device /dev/dri/renderD128` in the Jellyfin Pod; verify the check reports hardware usable and the iHD driver loads and lists DG2 decode and encode profiles.
- [ ] 8.2 Play a 4K HEVC 10-bit file to a client that forces a 1080p H.264 transcode; verify Jellyfin's playback info shows hardware decoding and encoding, the host's Video engine is busy in `intel_gpu_top` (operator `sudo`), and Jellyfin CPU stays within its limit. Record the evidence in the change.
- [ ] 8.3 Play a file with graphical subtitles burned in; verify smooth playback and record CPU use.
- [ ] 8.4 Record measured CPU and memory under the acceptance load and decide whether Jellyfin's CPU limit (design D10) changes; verify the decision is written in design.md.
- [ ] 8.5 On `hvn-hyp1`, confirm the host render node is group `render`, mode `0660`, and that the guest node is still GID 506, mode `0660`; verify with read-only `ls -l` on host and guest.
