## 0. Gate

- [x] 0.1 Start implementation only after `reproducible-jellyfin-compute` is archived (its last open item is owner acceptance task 4.1); verify `openspec list` no longer shows it and `openspec/specs/jellyfin-lifecycle/spec.md` exists. No amendment to its writer rules is needed, because Jellarr stays the only settings writer (design D9).
  - Evidence: archived by PR #57 as `openspec/changes/archive/2026-10-10-reproducible-jellyfin-compute`; `openspec list` no longer shows it; `openspec/specs/jellyfin-lifecycle/spec.md` exists.
- [x] 0.2 After that archive, rebase this change and confirm design.md still matches the archived `jellyfin-lifecycle` and the merged Jellyfin resources (memory 4Gi from PR #49; transcode cache 64Gi if PR #53 has merged); verify `openspec validate jellyfin-hardware-transcoding --strict` passes.
  - Evidence: rebased onto `main@origin` `1d3512f6` (after #25 and #53). design.md now cites the current `jellyfin-lifecycle` spec, memory 4Gi, the 64Gi cache (request 8Gi, limit 65Gi) and the guest's 12 CPU / 32GiB limits (PR #52). `openspec validate jellyfin-hardware-transcoding --strict` passes.

## 1. Host ownership

- [x] 1.1 Declare `hardware.enableRedistributableFirmware = true` explicitly in the `hvn-hyp1` host configuration and keep host graphics userspace off; verify with `nix eval` of both options for `nixosConfigurations.hvn-hyp1`.
  - Evidence: `compute.provides.accelerator`, which `hvn-hyp1` includes, sets it; `nix eval` gives `enableRedistributableFirmware = true`, `hardware.graphics.enable = false`.
- [x] 1.2 Add an evaluation assertion to `compute-contracts` that a host declaring an accelerator grant has redistributable firmware enabled; verify the check fails when the option is set to false in a fixture.
  - Changed during review: the sub-aspect that declares the host as driving domain sets the option, so an assertion would only restate it. The compute aspect instead requires every host that declares an accelerator to include `compute.provides.accelerator`.
- [x] 1.3 Add a host udev rule on `hvn-hyp1`, ordered after systemd's default rules, that sets DRM render nodes to group `render` and mode `0660` (design D3); verify the rule appears in the evaluated `services.udev` rules for `nixosConfigurations.hvn-hyp1`.
  - Evidence: `SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0660"` in `services.udev.extraRules` (`99-local.rules`, after systemd 261's `50-udev-default.rules`, which sets `0666`; render nodes carry no `uaccess` tag in systemd 261). The VM tests show the resulting `render`/`0660` node.
- [x] 1.4 List the host users that need the GPU and add them to `render` in host configuration (none expected today); verify with `nix eval` of `users.groups.render.members` for `hvn-hyp1`, and add a `compute-contracts` assertion that the render-node rule is present whenever the host declares an accelerator grant.
  - Evidence: none needed: host graphics userspace is off and Incus runs as root. The Hermes runner users (UIDs 1100, 1101) lose the `0666` access, which they do not use. `render` has no members. `prod-home-replacement` requires the host's rule before reproducing it in the fixture host.

## 2. Capability group

- [x] 2.1 Add the `gpu-render` POSIX fleet group (GID 506) to `modules/den/groups/default.nix` and the deterministic-ID registry; verify that the fleet-groups assertion resolves it to the same GID on `hvn-hyp1` and `compute-1`.
  - Evidence: `nix eval` gives `users.groups.gpu-render.gid = 506` on both; the fleet-groups assertion passes at toplevel evaluation.

## 3. Compute envelope

- [x] 3.1 Add an accelerator-grant setting to `den.aspects.virtualization.compute` that declares the driving domain (host) and an attachment kind (only `render-node` accepted now, so a VM kind can be added later; design D12), and for `render-node` renders exactly one `unix-char` device (render node source, guest path `/dev/dri/renderD128`, `required=false`, `uid=0`, GID 506 `gpu-render`, mode `0660`) and sets `restricted.devices.unix-char = "allow"` while `restricted.devices.gpu` stays `block`; verify by evaluating the preseed profile and `/etc/homelab/compute.json` for `hvn-hyp1`.
  - Changed during review: the setting is `accelerator` (vendor, PCI address, source; read-only guest path), declared in `compute-accelerator.nix` beside `compute.provides.accelerator`. Including that sub-aspect declares the host as driving domain, so no driving-domain or attachment field is needed until a VM adds a second kind (D12). `compute.nix` renders the device.
- [x] 3.2 Do not add the capability to `storageCapabilities`; verify with a `compute-contracts` assertion that `raw.idmap` is unchanged by the grant.
  - Evidence: `accelerator-grant-leaves-id-map` compares `raw.idmap`, the ID map, the project GID ranges and the other devices with an evaluation without the grant.
- [x] 3.3 Extend `compute-contracts` so evaluation fails, for container compute guests, when a second `unix-char` device, any `gpu` device, or a grant without `required=false`, mode `0660`, and GID 506 is declared; verify each rejected fixture fails and the real configuration passes.
  - Evidence: the aspect refuses any declared `unix-char` or `gpu` device; the grant's device is rendered by the aspect itself, so its properties are not re-checked. `compute-contracts` (`character-devices-only-through-the-grant`) requires a second character device and a `gpu` device to be refused and the real configuration to pass.
- [x] 3.4 Extend the compute-runtime adoption tests so an undeclared `unix-char` device on the profile is reported as drift; verify with `go test ./...` in `pkgs/by-name/compute-runtime`.
  - Evidence: `adoption_test.go` adds an undeclared character device (a conflict preseed cannot remove) and `TestOwnedEnvelopeGainsRenderNodeGrant` (adding the grant to an owned envelope is applied drift; a second node afterwards is refused). `go test ./...` passes; `checks.x86_64-linux.compute-runtime` passes.
- [x] 3.5 Declare the grant on `hvn-hyp1` with the `by-path` render source; verify the evaluated device source is `/dev/dri/by-path/pci-0000:85:00.0-render`.
  - Changed during implementation (design D4): Incus 7.4 does not add a node to a running guest through a `by-path` link, because udev creates those links by rename. The grant declares PCI address `0000:85:00.0` and source `/dev/dri/renderD128`, and `compute-accelerator-source.service` reports drift if that node belongs to another device. Evidence: the VM test runs the check against the stand-in and sees `DRIFT`.

## 4. Guest

- [x] 4.1 Create an empty `/dev/dri` directory at boot in the `compute-1` guest; verify with `nix eval` of the guest's tmpfiles rules.
  - Evidence: `d /dev/dri 0755 root root -` in `compute-1`'s tmpfiles rules; `prod-home-replacement` sees the empty directory in a guest started without the GPU.

## 5. Jellyfin workload

- [x] 5.1 Mount guest `/dev/dri` (`hostPath`, `type: Directory`) into the Jellyfin container and add GID 506 (`gpu-render`) to the Pod's `supplementalGroups`, keeping non-root, no capabilities, and no privilege escalation; verify in the rendered manifests under `generated/manifests/prod-home/jellyfin`.
  - Evidence: `Deployment-jellyfin.yaml` has supplementary groups `[505, 506]` and a `dri` hostPath mounted only in the `jellyfin` container, with `HostToContainer` propagation (design D7).
- [x] 5.2 Add a declared transcoding-mode setting for Jellyfin with values `hardware` (default) and `software`; verify `nix eval` shows `hardware` for prod-home.
  - Evidence: `den.aspects.kubernetes.services.jellyfin.settings.transcoding`; `den.clusters.prod-home.settings.kubernetes.services.jellyfin.transcoding` evaluates to `hardware`.
- [x] 5.3 Render the `encoding:` variant for the declared mode (design D8) into the existing PostSync Jellarr Job configuration, and validate both variants against Jellarr's strict configuration schema in `jellyfin-contracts`; verify an unknown encoding key fails the check and a `software` fixture renders `hardwareAccelerationType: none`.
  - Evidence: `jellyfin-contracts` renders both modes through the real aspect and runs the pinned Jellarr CLI (`passthru.jellarr`): both variants pass its schema and stop at the missing API key; a variant with `enableToneMapping` fails validation. In the pinned source Jellarr patches only declared keys (design D8).
- [x] 5.4 Add a `jellyfin-contracts` assertion that the PostSync Jellarr Job is the only rendered workload that runs Jellarr or writes Jellyfin settings, with no probe initContainer or encoding sidecar; verify a fixture that adds a second Jellarr container fails.
  - Dropped during review: the rule restated the rendered manifests, which review already shows.
- [x] 5.5 Add a `jellyfin-contracts` assertion that only declared grant holders (the Jellyfin Deployment today) mount a `/dev` hostPath or list GID 506, and that no rendered Pod is privileged; verify a fixture with an undeclared Pod holding the GID fails.
  - Evidence: `accelerator_grants` over every rendered workload requires exactly the declared holders and refuses any other `/dev` hostPath or privileged container.
- [x] 5.6 Regenerate manifests with `nix run .#sync-prod-home-manifests`; verify `checks.<system>.prod-home-manifests-fresh` passes.
  - Evidence: regenerated on `hvn-hyp1`; `prod-home-manifests-fresh` passes. The `retained-directories` image tag also changes, because the compute-runtime sources changed.

## 6. Stand-in runtime test

- [x] 6.1 Extend `prod-home-replacement` so the host VM loads `vgem` and the compute grant uses the stand-in's render node as source; verify the host node is group `render`, mode `0660`, an undeclared host user cannot open it, and the guest shows `/dev/dri/renderD128` with GID 506 and mode `0660`.
  - Evidence: native run on `hvn-hyp1`, exit 0 in 1956 s (`hvn-hyp1:~/agent/gpu-impl/prod-home-replacement-pf2jyw/console.log`). `vgem` is the fixture's only render node, so it takes the production source path and the production descriptor and preseed run unchanged (design D11). Passed: host node `render`/`0660`; undeclared user denied, a user in `render` allowed; guest node `character special file 506 660`.
- [x] 6.2 In the same test, verify the Jellyfin process can open the node, an ungranted test Pod has no `/dev/dri/renderD128`, and a process without GID 506 gets permission denied.
  - Evidence: same run. Jellyfin holds 506 and opens the node; its container sees only `renderD128`; an ungranted Pod has no node; a Pod that mounts `/dev/dri` without 506, and a guest identity without 506, get permission denied.
- [x] 6.3 Start the guest with `vgem` unloaded; verify the guest, K3s, and Jellyfin become ready, Jellyfin's encoding configuration (read through its API) still has acceleration `qsv`, and the documented acceleration check reports the render node missing.
  - Evidence: same run. The guest's `/dev/dri` is empty; the guest, K3s, CoreDNS and Jellyfin are ready; the API reports `qsv`; the check prints `STATE: degraded`, "renderD128 is missing in the Jellyfin container". A rerun of the delivered Jellarr Job kept owner-set throttling and segment deletion and restored a changed declared key. With `vgem` loaded, the check finds the node (`group=506 mode=660`) and reports that the stand-in's VA-API driver does not initialize, and the source check reports `DRIFT` (`vgem`, not `0000:85:00.0`).
- [x] 6.4 Load `vgem` after the guest started; verify the node appears in the guest without a restart (this decides the `by-path` hotplug question in design D4; switch to the fallback in D4 if it fails).
  - Evidence: a throwaway Incus test showed `by-path` does not hotplug, so the grant uses the D4 fallback. In the run above the node reached the running guest with the same init process, and reached the running Jellyfin container too (`running_pod_sees_node=True`). Unloading and reloading `vgem` removed and restored it while Jellyfin stayed ready and `qsv` stayed declared. `compute-guest-upgrade` (exit 0, 581 s, `hvn-hyp1:~/agent/gpu-impl/compute-guest-upgrade-iza9b4/console.log`) shows host activation and native preseed adding the device to a running guest created without the grant.
- [x] 6.5 Replace the compute instance through the declared replacement procedure; verify the replacement guest has the grant and the Jellyfin Pod sees the node, with no manual device steps.
  - Evidence: same run, phase `replacement-regains-the-accelerator-grant`, after `compute-guest replace` and the second bootstrap. `compute-guest-upgrade` also checks the node in its replacement guest.

## 7. Operations and records

- [x] 7.1 Add to `docs/operations/jellyfin.md` the acceleration check from design D9 (declared mode, render node presence and owner in the Pod, `vainfo` as UID 751, host-side reasons), the procedure to declare software mode and switch back, the effect of GPU loss (hardware transcodes fail; direct play works), the rollback order (software mode first, device last), and the operator acceptance procedure; verify each command against the rendered names.
  - Evidence: "Hardware transcoding" in `docs/operations/jellyfin.md`, with the check as `docs/operations/jellyfin-acceleration-check.sh`. `prod-home-replacement` runs that script against the rendered names (`deployment/jellyfin`, container `jellyfin`, ConfigMap `jellarr-configuration`, project `compute`, instance `compute-1`).
- [x] 7.2 Add hardware acceptance to the Jellyfin coupled-release upgrade steps in `docs/operations/jellyfin.md`; verify the upgrade section lists it.
  - Evidence: step 6 of "Upgrade Jellyfin" and a "First real upgrade" checklist item.
- [x] 7.3 Record the render-node grant as the accepted narrow hardware delegation in ADR-0001 (or a new ADR that modifies it); verify the ADR front matter links this change.
  - Evidence: `docs/architecture/decisions/0010-narrow-accelerator-delegation.md` (`modifies: [ADR-0001]`, `related-changes: [jellyfin-hardware-transcoding]`); ADR-0001 lists `modified-by: [ADR-0010]`. ADR-0009 is taken on another branch.
- [x] 7.4 Open a follow-up for `monitoring-and-alerting` (PR #54) to alert on the acceleration check's degraded state; verify the follow-up links this change. This change does not wait for it.
  - Evidence: issue #59 links PR #51 and PR #54.
- [x] 7.5 Record in ADR-0001 (or the new ADR from 7.3) that the delegation contract is neutral between container and VM guests, and cite design D12 for the VM cutover path and the hardware finding; verify the ADR links D12.
  - Evidence: ADR-0010, "Container or VM guest".

## 8. Operator acceptance on `hvn-hyp1` (separately authorized)

- [ ] 8.1 After deployment, run the documented acceleration check and `vainfo --display drm --device /dev/dri/renderD128` in the Jellyfin Pod; verify the check reports hardware usable and the iHD driver loads and lists DG2 decode and encode profiles.
- [ ] 8.2 Play a 4K HEVC 10-bit file to a client that forces a 1080p H.264 transcode; verify Jellyfin's playback info shows hardware decoding and encoding, the host's Video engine is busy in `intel_gpu_top` (operator `sudo`), and Jellyfin CPU stays within its limit. Record the evidence in the change.
- [ ] 8.3 Play a file with graphical subtitles burned in; verify smooth playback and record CPU use.
- [ ] 8.4 Record measured CPU and memory under the acceptance load and decide whether Jellyfin's CPU limit (design D10) changes; verify the decision is written in design.md.
- [ ] 8.5 On `hvn-hyp1`, confirm the host render node is group `render`, mode `0660`, and that the guest node is still GID 506, mode `0660`; verify with read-only `ls -l` on host and guest.
