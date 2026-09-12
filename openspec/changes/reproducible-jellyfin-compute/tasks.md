## 2. Host and guest configuration

- [x] 2.1 Add the Den compute entity and NixOS-owned Incus envelope using existing aspect, settings, persistence, and access-resolution conventions. Supply native preseed with Nix attrsets; instance operations only verify its resources. Declare isolated non-root host ID translation, resource limits, private networking, retained directories, and node-essential startup prerequisites without changing physical storage or legacy Hermes. Application-only storage must not gate node boot. Verify exact evaluated option leaves, host-specific inclusion, safe expanded settings, and a conflict check before first preseed adoption.
- [x] 2.2 Add the standalone secret-free guest image and K3s configuration against the unchanged pinned nixpkgs: current user-namespace runtime settings, native snapshotter, bundled networking, and disabled unused ingress/dynamic storage components. Verify the generated kubelet/kube-proxy/containerd configuration parses under the pinned tools, the guest derivation evaluates without decryption, and the built image contains no runtime private key. Record Linux-builder limitations rather than claiming an unbuilt image passed.
- [x] 2.3 Integrate host-managed runtime guest identity using existing secretRequests/agenix-rekey conventions, atomic staging, translated ownership, read-only attachment, and separate pinned host/guest SSH trust. Support re-staging and explicit identity rotation under the lifecycle lock. Verify matching identity starts the identity-dependent path and missing or mismatched private/public identity blocks it without substituting a generated key. Use disposable test keys locally; production key creation/rekeying requires separate authorization.

## 3. Persistent workload and managed resources

- [x] 3.1 Generate Jellyfin namespace, explicitly bound retained PVs/PVCs, Recreate deployment, service, probes, non-root security context, resource bounds, read-only media, persistent config, and disposable cache. Build a pinned application artifact independently of the guest OS. Keep application-only HTTP behavior in `modules/tests/jellyfin_smoke.py`; platform orchestration and replacement acceptance are owned by `modules/tests/prod-home-replacement.{nix,py}`. Physical GPU validation requires separate authorization.
- [x] 3.2 Use stable Nix-delivered manifest names and one Argo reconciliation owner with retained-resource protection. Separate retained storage and namespace from disposable workload resources; introduce no custom inventory or pruning controller.
- [x] 3.3 Provide operator-private access and bridge-aware enforcement for workload and Kubernetes management ports without public listeners, physical-uplink bridge changes, or broad trusted interfaces. Cover same-bridge guests as well as routed traffic; do not assume NAT or FORWARD rules alone suffice. Generate and inspect the local rules and tunnel boundaries.

## 4. Lifecycle and recovery tooling

- [x] 4.1 Provide thin application-neutral inspection, creation, and acknowledged replacement operations over Incus, with no application update/backup/plugin engine. Preserve host serialization, structured absence handling, effective-envelope verification, declared retained-path and identity preflight, artifact acquisition before destruction, and bounded management readiness. Use standard NixOS copy/activation commands and explicit SSH trust rather than selecting a deployment frontend. Verify idempotent creation, no mutation on failed preflight or concurrent maintenance, and independent OS activation that leaves application releases unchanged.

## 5. Local integration and operator evidence

- [x] 5.1 Run focused local Nix evaluation/build checks for the host, guest, images, and lifecycle packages; run formatter/linter once after integration. Verify unrelated fleet outputs still evaluate without changing the lockfile. Report exact commands and distinguish evaluated derivations from built outputs.

## 6. Target runtime acceptance — pending

The x86_64 disposable replacement acceptance has not passed. Do
not substitute local evaluation, a different test, or a Darwin fixture for this
evidence. Production inspection, credential provisioning, deployment, and
production destructive operations remain separately authorized.

- [ ] 6.1 Obtain permission for read-only inspection of hvn-hyp1, then check actual encryption/mounts, free space, kernel/cgroups, Incus resources, subordinate-ID collisions, route collisions, media readability, and independent management access. Record the observed prerequisites; stop before any required storage-permission or isolation expansion rather than inventing a compatibility workaround.
- [ ] 6.2 Obtain permission for secret provisioning and host/guest deployment; check conflicts before first preseed adoption, create only approved slice-owned resources, deploy, privately complete new-instance Jellyfin setup, and verify real playback plus denied media writes. Check effective unprivileged maps and actual network restrictions, including same-bridge peers and management ports. Prove node boot without application media, media loss/return without node restart, and continued unrelated workload/management access. Keep incompatible-kernel, filesystem, or nesting results as failed gates; no privileged fallback.
- [ ] 6.3 On an appropriate x86_64 Linux/KVM runner, execute `checks.prod-home-replacement` from `modules/tests/prod-home-replacement.nix` through its `prod-home-replacement.py` driver and `jellyfin_smoke.py` helper. Record derivation/build preparation, fixture-host startup, compute guest creation, registry pulls, first Argo reconciliation, media loss/return, compute replacement, and second Argo reconciliation. Verify the same user, library, recorded playback state, retained data, unrelated workload availability, and Jellyfin's read-only `/media` mount. Only a successful run closes the target guest-rebuild acceptance gate.
