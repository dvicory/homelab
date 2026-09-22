# Reproducible Jellyfin compute tasks

Checked tasks have repository implementation or recorded evidence. Disposable
Linux runtime acceptance remains open. Deployment, credentials, destructive
replacement, and target-runtime inspection remain operator-gated.

## 1. Release identity and bounded provisioner spike

- [x] 1.1 Record the bounded PR #17902 spike: exact commit
  `8b0a2c269d5a3d9d7084b5295fd818a8a67af6f2` applies cleanly to Jellyfin v12.1
  source commit `ee91c75e777da41a9c4f4855e70adc604fbf2`; the Provision path
  starts only `SetupServer`, not the normal listener; and provisioning is
  non-transactional after preflight. Keep post-preflight failure testing
  explicit rather than implying rollback.
- [x] 1.2 Add the Nix-owned `pkgs.jellyfin-provisioner-image` release
  declaration for Jellyfin `12.1`, exposing `passthru.release.version`,
  `sourceRev`, `runtimeImage`, `runtimeDigest`, and `provisionPatchRev` with
  the exact source and patch revisions above. Use an exact architecture-
  specific digest for the stock official runtime image.
- [x] 1.3 Build only the provisioner from the pinned Jellyfin source and exact
  PR #17902 patch. Keep the long-lived workload on the stock official
  `docker.io/jellyfin/jellyfin:12.1` image; do not rebuild its ffmpeg, GPU
  userspace, fonts, libraries, or container packaging.
- [x] 1.4 Make manifests consume the single release declaration and reject
  provisioner/runtime version or digest drift during evaluation/build. Do not
  permit an image-only updater or an independent provisioner bump.
- [ ] 1.5 Document and exercise coupled Jellyfin upgrades: source, runtime
  image/digest, patch compatibility, and fresh/repeat/stock-runtime evidence
  move in one reviewed change. A later upstream equivalent may remove the
  downstream patch without changing the lifecycle ownership contract.

## 2. Host and guest configuration

- [x] 2.1 Add the Den compute entity and NixOS-owned Incus envelope using
  existing aspect, settings, persistence, and access-resolution conventions.
  Supply native preseed with Nix attrsets; instance operations only verify its
  resources. Declare isolated non-root host ID translation, resource limits,
  private networking, retained directories, and node-essential startup
  prerequisites without changing physical storage or legacy Hermes.
  Application-only storage must not gate node boot. Verify exact evaluated
  option leaves, host-specific inclusion, safe expanded settings, and a
  conflict check before first preseed adoption.
- [x] 2.2 Add the standalone secret-free guest image and K3s configuration
  against the unchanged pinned nixpkgs: current user-namespace runtime
  settings, overlayfs snapshotter, bundled networking, and disabled unused
  ingress/dynamic storage components. Verify generated kubelet/kube-proxy/
  containerd configuration parses under the pinned tools, the guest derivation
  evaluates without decryption, and the built image contains no runtime
  private key. Record Linux-builder limitations rather than claiming an
  unbuilt image passed.
- [x] 2.3 Integrate host-managed runtime guest identity using existing
  `secretRequests`/agenix-rekey conventions, atomic staging, translated
  ownership, read-only attachment, and separate pinned host/guest SSH trust.
  Support re-staging and explicit identity rotation under the lifecycle lock.
  Verify matching identity starts the identity-dependent path and missing or
  mismatched private/public identity blocks it without substituting a generated
  key. Use disposable test keys locally; production key creation/rekeying
  requires separate authorization.

## 3. Jellyfin workload baseline and ownership

The baseline workload resources below are retained as completed work. They do
not close the new release-identity or startup-configuration tasks in sections 1
and 3.4 onward.

- [x] 3.1 Generate the Jellyfin namespace, explicitly bound retained PVs/PVCs,
  Recreate deployment, Service, probes, non-root security context, resource
  bounds, read-only media, persistent config, and disposable cache. Keep
  application-only HTTP behavior in `modules/tests/jellyfin_smoke.py` and
  platform orchestration/replacement acceptance in
  `modules/tests/prod-home-replacement.{nix,py}`. Physical GPU validation
  requires separate authorization.
- [x] 3.2 Use stable Nix-delivered manifest names and one Argo reconciliation
  owner with retained-resource protection. Separate retained storage and
  namespace from disposable workload resources; introduce no custom inventory
  or pruning controller.
- [x] 3.3 Provide operator-private access and bridge-aware enforcement for
  workload and Kubernetes management ports without public listeners,
  physical-uplink bridge changes, or broad trusted interfaces. Cover
  same-bridge guests as well as routed traffic; do not assume NAT or FORWARD
  rules alone suffice. Generate and inspect the local rules and tunnel
  boundaries.
- [x] 3.4 Add the patched provisioner as the Jellyfin Pod initContainer,
  mounting the retained `/config` and completing before the stock official
  runtime. Invoke Provision mode/`SetupServer` only; expose no normal
  listener or unauthenticated `/Startup/*` race, and make readiness depend on
  successful init plus the stock runtime.
- [x] 3.5 Assemble the credential-bearing provision input at runtime from
  Nix-rendered non-secret values and the agenix-managed administrator Secret.
  Use a memory-backed shared volume, restrictive ownership/mode, and cleanup;
  verify the final file is absent from Git, generated manifests, the Nix
  store, logs, command-line arguments, and retained `/config`.
- [ ] 3.6 Verify safe repeated Provision mode against initialized retained
  state: successful no-op with unchanged administrator, users, libraries,
  retained data, and Jellarr-owned settings. If the exact patch needs it, add
  only the smallest Provision-mode idempotence adjustment; do not add XML or
  SQLite parsing.
- [x] 3.7 Keep steady-state configuration out of Jellyfin internal XML/SQLite.
  Remove obsolete startup automation and generated `network.xml` overwrites;
  document every selected ongoing field as a supported API/Jellarr owner or
  leave it application-owned.
- [x] 3.8 Add Jellarr v0.1.0 at commit
  `f94c24f26c0264a7c331b016968d5b6e8d1504b7` as one pinned declarative
  one-shot Job after the stock Service is healthy. Use one Argo PostSync or
  equivalent owner, make failure visible, rerun on desired-config changes,
  and do not add a periodic daemon/controller.
- [x] 3.9 Bootstrap the Jellarr API key only through authenticated Jellyfin
  APIs: use the normal administrator credential, find the named existing key,
  create it only when absent, re-read it, and pass it through an ephemeral
  memory-backed shared volume to the Jellarr process. Do not edit SQLite,
  publish a durable generated API-key Secret, or copy the key into agenix.
- [x] 3.10 Make the initial administrator the one normal declarative account.
  Keep its password agenix-owned and document any supported Jellarr policy or
  password reconciliation. Do not leave a second undocumented automation or
  bootstrap administrator.
- [x] 3.11 Add the explicit owner table to the design/spec and review all
  manifests against it: Nix/Den and Kubernetes/Argo, patched provisioner,
  stock runtime, Jellarr, and Preserve each have a non-overlapping boundary.
  In particular, Jellarr must not own `startup.completeStartupWizard`.
- [x] 3.12 Use a streaming-safe Gateway timeout and query-string-safe proxy
  logging; retain semantic media projection and storage-placement
  documentation; keep static Jellyfin PV/PVC ownership explicit and protected.
- [x] 3.13 Set a coherent bounded cache/ephemeral-storage budget, strengthen
  cheap structural checks for image/init ordering/UID/GID/read-only
  media/route ownership, keep current acceptance evidence separate from static
  evaluation, and clean Python scenario caches.

## 4. Lifecycle and recovery tooling

- [x] 4.1 Provide thin application-neutral inspection, creation, and
  acknowledged replacement operations over Incus. Preserve host serialization,
  structured absence handling, effective-envelope verification, declared
  retained-path and identity preflight, artifact acquisition before
  destruction, and bounded management readiness. Use standard NixOS commands
  and explicit SSH trust rather than a deployment frontend or workload
  framework.

## 5. Local integration and focused startup acceptance

- [x] 5.1 Run focused local evaluation/build checks for the host, guest,
  platform images, and lifecycle packages. Verify unrelated fleet outputs still
  evaluate without changing the lockfile. Report evaluated derivations
  separately from built outputs.
- [ ] 5.2 Fresh-state acceptance: with an empty retained `/config`, prove the
  provisioner uses Jellyfin v12.1 plus the exact PR #17902 patch, runs only its
  internal `SetupServer`, and leaves no externally routable stock-runtime
  backend until provisioning completes. Prove the one normal administrator is
  created, startup is complete, and the stock official v12.1 runtime starts
  healthy against the resulting state.
- [ ] 5.3 Repeat acceptance: recreate the Pod against initialized `/config`,
  prove init exits successfully as a no-op, credentials/libraries/Jellarr-
  owned settings remain unchanged, and the stock runtime starts normally.
- [ ] 5.4 Version acceptance: deliberately mismatch the provisioner source and
  stock runtime release or digest and prove the single release invariant fails
  evaluation/build before deployment.
- [ ] 5.5 Stock-runtime acceptance: prove the long-lived Jellyfin process is
  from the official pinned image and retains the expected upstream ffmpeg/GPU
  runtime integration; the patched provisioner must never become the server.
- [ ] 5.6 Jellarr bootstrap acceptance: with no named Jellarr key, authenticate
  through the supported APIs, create exactly one key, reconcile one declared
  setting, then repeat and prove the existing key is reused, no duplicate is
  created, and the desired state is unchanged.
- [ ] 5.7 Failure acceptance: inject a failure after Provision-mode preflight,
  record the non-transactional/partial retained-state outcome, prove the
  initContainer fails visibly and the stock runtime never becomes ready, and
  do not claim automatic rollback.
- [x] 5.8 Verify generated resources and focused checks cover owner separation,
  runtime-only secret assembly, init ordering, stock image provenance,
  read-only media, static retained PV/PVCs, safe cache bounds, route timeout,
  queryless logs, and Python cache cleanup.

## 6. Runtime acceptance and production gates

The platform revision does not claim target-runtime replacement acceptance.
Production inspection, credential provisioning, deployment, and destructive
operations remain separately authorized. The existing compute/storage evidence
in 6.3 remains distinct from the open provisioner/runtime/Jellarr checks in
section 5.

- [ ] 6.1 Obtain permission for read-only inspection of hvn-hyp1, then check
  actual encryption/mounts, free space, kernel/cgroups, Incus resources,
  subordinate-ID collisions, route collisions, media readability, and
  independent management access. Record observed prerequisites; stop before
  any required storage-permission or isolation expansion rather than inventing
  a compatibility workaround.
- [ ] 6.2 Obtain permission for secret provisioning and host/guest deployment;
  check conflicts before first preseed adoption, create only approved
  slice-owned resources, deploy, and verify the initContainer-to-stock-runtime
  gate, private Jellarr reconciliation, real playback, and denied media
  writes. Check effective unprivileged maps and actual network restrictions,
  including same-bridge peers and management ports. Prove node boot without
  application media, media loss/return without node restart, and continued
  unrelated workload/management access. Keep incompatible-kernel,
  filesystem, or nesting results as failed gates; no privileged fallback.
- [x] 6.3 On an appropriate x86_64 Linux/KVM runner, execute
  `checks.prod-home-replacement` from `modules/tests/prod-home-replacement.nix`
  through its `prod-home-replacement.py` driver and `jellyfin_smoke.py`
  helper. Record derivation/build preparation, fixture-host startup, compute
  guest creation, registry pulls, first Argo reconciliation, media loss/return,
  compute replacement, and second Argo reconciliation. Verify the same user,
  library, recorded playback state, retained data, unrelated workload
  availability, and Jellyfin's read-only `/media` mount. This existing
  compute/storage result does not close the new section 5 startup boundary.
- [ ] 6.4 Before routine replacement begins, add an operator-invoked retirement
  flow for superseded compute bundle GC roots and matching Incus images.
  Require an explicit target, preserve at least one verified rollback point,
  refuse resources referenced by an instance, and check host capacity before
  deletion. Exercise retirement without affecting the active guest or retained
  service data.
