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

## 2. Jellyfin workload baseline and ownership

The baseline workload resources below are retained as completed work. They do
not close the new release-identity or startup-configuration tasks in sections 1
and 2.4 onward.

- [x] 2.1 Generate the Jellyfin namespace, explicitly bound retained PVs/PVCs,
  Recreate deployment, Service, probes, non-root security context, resource
  bounds, read-only media, persistent config, and disposable cache. Keep
  application-only HTTP behavior in `modules/tests/jellyfin_smoke.py` and
  platform orchestration/replacement acceptance in
  `modules/tests/prod-home-replacement.{nix,py}`. Physical GPU validation
  requires separate authorization.
- [x] 2.2 Use stable Nix-delivered manifest names and one Argo reconciliation
  owner with retained-resource protection. Separate retained storage and
  namespace from disposable workload resources; introduce no custom inventory
  or pruning controller.
- [x] 2.3 Provide operator-private access and bridge-aware enforcement for
  workload and Kubernetes management ports without public listeners,
  physical-uplink bridge changes, or broad trusted interfaces. Cover
  same-bridge guests as well as routed traffic; do not assume NAT or FORWARD
  rules alone suffice. Generate and inspect the local rules and tunnel
  boundaries.
- [x] 2.4 Add the patched provisioner as the Jellyfin Pod initContainer,
  mounting the retained `/config` and completing before the stock official
  runtime. Invoke Provision mode/`SetupServer` only; expose no normal
  listener or unauthenticated `/Startup/*` race, and make readiness depend on
  successful init plus the stock runtime.
- [x] 2.5 Assemble the credential-bearing provision input at runtime from
  Nix-rendered non-secret values and the agenix-managed administrator Secret.
  Use a memory-backed shared volume, restrictive ownership/mode, and cleanup;
  verify the final file is absent from Git, generated manifests, the Nix
  store, logs, command-line arguments, and retained `/config`.
- [ ] 2.6 Verify safe repeated Provision mode against initialized retained
  state: successful no-op with unchanged administrator, users, libraries,
  retained data, and Jellarr-owned settings. If the exact patch needs it, add
  only the smallest Provision-mode idempotence adjustment; do not add XML or
  SQLite parsing.
- [x] 2.7 Keep steady-state configuration out of Jellyfin internal XML/SQLite.
  Remove obsolete startup automation and generated `network.xml` overwrites;
  document every selected ongoing field as a supported API/Jellarr owner or
  leave it application-owned.
- [x] 2.8 Add Jellarr v0.1.0 at commit
  `f94c24f26c0264a7c331b016968d5b6e8d1504b7` as one pinned declarative
  one-shot Job after the stock Service is healthy. Use one Argo PostSync or
  equivalent owner, make failure visible, rerun on desired-config changes,
  and do not add a periodic daemon/controller.
- [x] 2.9 Bootstrap the Jellarr API key only through authenticated Jellyfin
  APIs: use the normal administrator credential, find the named existing key,
  create it only when absent, re-read it, and pass it through an ephemeral
  memory-backed shared volume to the Jellarr process. Do not edit SQLite,
  publish a durable generated API-key Secret, or copy the key into agenix.
- [x] 2.10 Make the initial administrator the one normal declarative account.
  Keep its password agenix-owned and document any supported Jellarr policy or
  password reconciliation. Do not leave a second undocumented automation or
  bootstrap administrator.
- [x] 2.11 Add the explicit owner table to the design/spec and review all
  manifests against it: Nix/Den and Kubernetes/Argo, patched provisioner,
  stock runtime, Jellarr, and Preserve each have a non-overlapping boundary.
  In particular, Jellarr must not own `startup.completeStartupWizard`.
- [x] 2.12 Use a streaming-safe Gateway timeout and query-string-safe proxy
  logging; retain semantic media projection and storage-placement
  documentation; keep static Jellyfin PV/PVC ownership explicit and protected.
- [x] 2.13 Set a coherent bounded cache/ephemeral-storage budget, strengthen
  cheap structural checks for image/init ordering/UID/GID/read-only
  media/route ownership, keep current acceptance evidence separate from static
  evaluation, and clean Python scenario caches.

## 3. Local integration and focused startup acceptance

- [ ] 3.1 Fresh-state acceptance: with an empty retained `/config`, prove the
  provisioner uses Jellyfin v12.1 plus the exact PR #17902 patch, runs only its
  internal `SetupServer`, and leaves no externally routable stock-runtime
  backend until provisioning completes. Prove the one normal administrator is
  created, startup is complete, and the stock official v12.1 runtime starts
  healthy against the resulting state.
- [ ] 3.2 Repeat acceptance: recreate the Pod against initialized `/config`,
  prove init exits successfully as a no-op, credentials/libraries/Jellarr-
  owned settings remain unchanged, and the stock runtime starts normally.
- [ ] 3.3 Version acceptance: deliberately mismatch the provisioner source and
  stock runtime release or digest and prove the single release invariant fails
  evaluation/build before deployment.
- [ ] 3.4 Stock-runtime acceptance: prove the long-lived Jellyfin process is
  from the official pinned image and retains the expected upstream ffmpeg/GPU
  runtime integration; the patched provisioner must never become the server.
- [ ] 3.5 Jellarr bootstrap acceptance: with no named Jellarr key, authenticate
  through the supported APIs, create exactly one key, reconcile one declared
  setting, then repeat and prove the existing key is reused, no duplicate is
  created, and the desired state is unchanged.
- [ ] 3.6 Failure acceptance: inject a failure after Provision-mode preflight,
  record the non-transactional/partial retained-state outcome, prove the
  initContainer fails visibly and the stock runtime never becomes ready, and
  do not claim automatic rollback.
- [x] 3.7 Verify generated resources and focused checks cover owner separation,
  runtime-only secret assembly, init ordering, stock image provenance,
  read-only media, static retained PV/PVCs, safe cache bounds, route timeout,
  queryless logs, and Python cache cleanup.

## 4. Runtime acceptance and production gates

Production inspection, credential provisioning, deployment, and destructive
operations remain separately authorized. A Linux VM run must demonstrate the
Jellyfin startup and recovery boundary before its acceptance task is checked.

- [ ] 4.1 With read-only host inspection permission, verify the intended media
  source is readable without relying on a bare mountpoint directory. Obtain
  separate permission for Jellyfin credentials and deployment, check resource
  conflicts, then verify the initContainer-to-stock-runtime gate, private
  Jellarr reconciliation, real playback, and denied Jellyfin media writes.
  Do not infer production readiness from local fixtures.
- [ ] 4.2 On an x86_64 Linux/KVM runner, execute
  `checks.prod-home-replacement` through `prod-home-replacement.py` and
  `jellyfin_smoke.py`. Verify both Argo reconciliations, the Jellyfin
  provisioner and stock server, the same user, library, playback and retained
  state after compute replacement, Jellyfin's read-only library mount, and
  media loss/return without substitute storage. The current run timed out:
  `/srv/media/data/library` was not a directory inside the guest. Keep this
  task open until a passing rerun.
