## 0. Gate

- [ ] 0.1 Record the owner's answers to design.md "Decisions the owner must confirm" (items 1–8) in design.md, and update the affected decisions and tasks below; verify that no item is left without an answer.
- [ ] 0.2 Confirm the order with `reproducible-jellyfin-compute`: either it is archived first, or its `jellyfin-lifecycle` ownership requirement is amended in that change to name the per-start encoding reconciliation; verify `openspec validate --strict` passes for both changes.

## 1. Host ownership

- [ ] 1.1 Declare `hardware.enableRedistributableFirmware = true` explicitly in the `hvn-hyp1` host configuration and keep host graphics userspace off; verify with `nix eval` of both options for `nixosConfigurations.hvn-hyp1`.
- [ ] 1.2 Add an evaluation assertion to `compute-contracts` that a host declaring an accelerator grant has redistributable firmware enabled; verify the check fails when the option is set to false in a fixture.

## 2. Capability group

- [ ] 2.1 Add the `media-acceleration` POSIX fleet group (GID 506, or the confirmed name and GID) to `modules/den/groups/default.nix` and the deterministic-ID registry; verify that the fleet-groups assertion resolves it to the same GID on `hvn-hyp1` and `compute-1`.

## 3. Compute envelope

- [ ] 3.1 Add an accelerator-grant setting to `den.aspects.virtualization.compute` that renders exactly one `unix-char` device (render node source, guest path `/dev/dri/renderD128`, `required=false`, `uid=0`, the capability GID, mode `0660`) and sets `restricted.devices.unix-char = "allow"` while `restricted.devices.gpu` stays `block`; verify by evaluating the preseed profile and `/etc/homelab/compute.json` for `hvn-hyp1`.
- [ ] 3.2 Do not add the capability to `storageCapabilities`; verify with a `compute-contracts` assertion that `raw.idmap` is unchanged by the grant.
- [ ] 3.3 Extend `compute-contracts` so evaluation fails when a second `unix-char` device, any `gpu` device, or a grant without `required=false`, mode `0660`, and the capability GID is declared; verify each rejected fixture fails and the real configuration passes.
- [ ] 3.4 Extend the compute-runtime adoption tests so an undeclared `unix-char` device on the profile is reported as drift; verify with `go test ./...` in `pkgs/by-name/compute-runtime`.
- [ ] 3.5 Declare the grant on `hvn-hyp1` with the `by-path` render source; verify the evaluated device source is `/dev/dri/by-path/pci-0000:85:00.0-render`.

## 4. Guest

- [ ] 4.1 Create an empty `/dev/dri` directory at boot in the `compute-1` guest; verify with `nix eval` of the guest's tmpfiles rules.

## 5. Jellyfin workload

- [ ] 5.1 Mount guest `/dev/dri` (`hostPath`, `type: Directory`) into the Jellyfin container and add the capability GID to the Pod's `supplementalGroups`, keeping non-root, no capabilities, and no privilege escalation; verify in the rendered manifests under `generated/manifests/prod-home/jellyfin`.
- [ ] 5.2 Add the `accel-probe` initContainer using the pinned stock runtime image: bounded VA-API/QSV init and a short `h264_qsv` encode, always exit 0, verdict written to a memory `emptyDir` and the termination message; verify the rendered image reference equals the release declaration's runtime image and digest.
- [ ] 5.3 Render two Jellarr `encoding:` variants (hardware and software, per design D8) and validate both against Jellarr's strict configuration schema in `jellyfin-contracts`; verify an unknown encoding key fails the check.
- [ ] 5.4 Add the per-start encoding reconciliation as a native sidecar that waits for `/health`, applies the variant selected by the verdict through Jellarr with its own API key name, logs the applied variant, and idles; verify the rendered Pod spec and that it uses no `/config` XML or SQLite access.
- [ ] 5.5 Ensure the PostSync Jellarr Job configuration contains no `encoding:` section; verify with a `jellyfin-contracts` assertion.
- [ ] 5.6 Add a `jellyfin-contracts` assertion that only the Jellyfin Deployment mounts a `/dev` hostPath or lists the capability GID, and that no rendered Pod is privileged; verify a fixture with a second Pod holding the GID fails.
- [ ] 5.7 Regenerate manifests with `nix run .#sync-prod-home-manifests`; verify `checks.<system>.prod-home-manifests-fresh` passes.

## 6. Stand-in runtime test

- [ ] 6.1 Extend `prod-home-replacement` so the host VM loads `vgem` and the compute grant uses the stand-in's render node as source; verify the guest shows `/dev/dri/renderD128` with the capability GID and mode `0660`.
- [ ] 6.2 In the same test, verify the Jellyfin process can open the node, an ungranted test Pod has no `/dev/dri/renderD128`, and a process without the capability GID gets permission denied.
- [ ] 6.3 Start the guest with `vgem` unloaded; verify the guest, K3s, and Jellyfin become ready, the probe reports `software`, and Jellyfin's encoding configuration (read through its API) has acceleration `none`.
- [ ] 6.4 Load `vgem` after the guest started; verify the node appears in the guest without a restart (this decides the `by-path` hotplug question in design D4; switch to the fallback in D4 if it fails).
- [ ] 6.5 Replace the compute instance through the declared replacement procedure; verify the replacement guest has the grant and the Jellyfin Pod sees the node, with no manual device steps.

## 7. Operations and records

- [ ] 7.1 Add to `docs/operations/jellyfin.md` the acceleration-state check (probe termination message, sidecar log, Dashboard page), the rollback order (software variant first, device last), and the operator acceptance procedure; verify each command against the rendered names.
- [ ] 7.2 Add hardware acceptance to the Jellyfin coupled-release upgrade steps in `docs/operations/jellyfin.md`; verify the upgrade section lists it.
- [ ] 7.3 Record the render-node grant as the accepted narrow hardware delegation in ADR-0001 (or a new ADR that modifies it); verify the ADR front matter links this change.

## 8. Operator acceptance on `hvn-hyp1` (separately authorized)

- [ ] 8.1 After deployment, run `vainfo --display drm --device /dev/dri/renderD128` in the Jellyfin Pod; verify the iHD driver loads and lists DG2 decode and encode profiles.
- [ ] 8.2 Play a 4K HEVC 10-bit file to a client that forces a 1080p H.264 transcode; verify Jellyfin's playback info shows hardware decoding and encoding, the host's Video engine is busy in `intel_gpu_top` (operator `sudo`), and Jellyfin CPU stays within its limit. Record the evidence in the change.
- [ ] 8.3 Play a file with graphical subtitles burned in; verify smooth playback and record CPU use.
- [ ] 8.4 Record measured CPU and memory under the acceptance load and decide whether D10's limits change; verify the decision is written in design.md.
