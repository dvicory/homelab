## Why

The replaceable compute boundary must recover a real application without relying on
an old guest root, a Kubernetes database, or an undocumented first-run action.
The current Jellyfin shape leaves first-start state, the normal server, and
steady-state configuration too close together: browser setup can race the
listener, startup can have more than one writer, and a runtime image can drift
from the executable that initialized `/config`.

This change keeps the accepted unprivileged compute and recovery boundary while
making Jellyfin startup reproducible. A bounded Nix-built provisioner will
initialize retained state before the normal server can become ready; the
long-lived process remains the stock official Jellyfin image; and Jellarr will
reconcile only its selected supported API surface after that server is healthy.

## What Changes

- Preserve the replaceable, unprivileged Incus/K3s compute domain, its explicit
  durable inputs, fail-closed storage attachment, host-managed identity, and
  explicit destructive-replacement boundary.
- Define one Nix-owned Jellyfin release identity. The identity is Jellyfin
  `12.1`, source commit
  `ee91c75e777da41a9c4f4855e70adc604fbf2ef8`, the exact PR #17902 backport
  commit `8b0a2c269d5a3d9d7084b5295fd818a8a67af6f2`, the official runtime image
  reference, and its pinned architecture-specific digest. The provisioner
  package exposes these facts through `passthru.release`, including
  `version`, `sourceRev`, `runtimeImage`, `runtimeDigest`, and
  `provisionPatchRev`.
- Build only the first-start `pkgs.jellyfin-provisioner-image` from the pinned
  Jellyfin source and bounded patch. Do not rebuild or replace the official
  multimedia runtime.
- Run the provisioner as a Kubernetes initContainer against the retained
  `/config`. It must complete before the stock runtime starts. The spike records
  that the exact patch applies cleanly to v12.1 and runs only its internal
  `SetupServer` during Provision mode; no externally routable stock-runtime
  backend exists until provisioning completes.
- Assemble provisioning input only at runtime from declarative non-secret
  values and the mounted administrator secret in a memory-backed volume. The
  final provision file must not enter Git, generated manifests, the Nix store,
  logs, command-line arguments, or retained `/config`.
- Make repeat init execution a successful no-op for already initialized state:
  it must not reset the administrator, libraries, retained state, or Jellarr
  configuration. The provisioner is not transactional after preflight, so
  failure tests must exercise post-preflight failures and keep readiness
  blocked rather than implying rollback.
- Keep the normal Jellyfin Pod completely stock and pinned to the same upstream
  release. Its upstream ffmpeg, GPU userspace, fonts, runtime libraries, and
  container packaging remain upstream-owned.
- Remove browser-driven `/Startup/*` setup races and routine copying of
  Jellyfin internal XML or SQLite. The provisioner owns fresh-state setup only;
  normal steady-state configuration uses supported Jellyfin APIs through a
  separately pinned Jellarr v0.1.0 source commit
  `f94c24f26c0264a7c331b016968d5b6e8d1504b7`.
- Run Jellarr as one declarative one-shot reconciliation Job after the stock
  runtime is healthy. Its initContainer authenticates with the normal
  administrator through supported Jellyfin APIs, finds or creates the named
  Jellarr API key, and places the token in ephemeral shared memory for the
  Jellarr process. No direct SQLite bootstrap or durable generated API-key
  Secret is introduced.
- Create one normal declarative administrator in the provisioner. Keep its
  password agenix-owned and make any subsequent Jellarr policy reconciliation
  explicit; do not leave a second undocumented automation administrator.
- Use streaming-safe Gateway timeouts, query-string-safe proxy logging,
  semantic media projection and storage-placement documentation, explicit
  static Jellyfin PV/PVC ownership, bounded cache/ephemeral storage, strong
  structural checks, current acceptance evidence, and Python cache cleanup.
  Adapt startup-related checks to the initContainer/API ownership model rather
  than reviving obsolete internal-file writers.
- Upgrade the provisioner source and stock runtime together in one reviewed
  release change. A runtime-only image bump, a provisioner-only Jellyfin bump,
  or an unreviewed future-version database writer is invalid.

### Non-goals

This change does not rebuild the Jellyfin production runtime, package its
ffmpeg/GPU userspace, add a periodic Jellarr controller, make Jellarr own every
Jellyfin field, or add a custom Jellyfin database/XML parser. It does not change
the accepted unprivileged isolation decision, the legacy Hermes nspawn service,
physical media placement, backup policy, retention policy, or restoration
destination. Public exposure and target deployment remain governed by the
existing route and operator gates.

No deployment, credential provisioning, destructive replacement, or target
runtime acceptance is authorized by this plan. Existing completed compute and
workload evidence remains distinct from the new provisioner/runtime/Jellarr
acceptance work; this proposal does not claim implementation complete.

## Capabilities

### New Capabilities

- `compute-recovery`: isolation, durable-input, storage-attachment,
  application-failure-domain, lifecycle, and recovery contracts for the
  replaceable compute domain, including the Jellyfin startup boundary.

### Modified Capabilities

None. The new capability composes with the existing
`management-boundaries`, `storage-foundations`, `secret-management`, and
`access-control` contracts without changing their ownership.

## Impact

- `hvn-hyp1`: continues to supply the Den compute entity, native Incus
  preseed, private networking, narrow storage exports, runtime identity, and
  bounded instance operations. Application-only storage remains a workload
  dependency, not a node-boot prerequisite.
- Nix/Den and Kubernetes/Argo: gain one release declaration, the provisioner
  initContainer gate, the stock runtime image reference, retained config/media
  projections, and one post-health Jellarr reconciliation owner.
- `pkgs.jellyfin-provisioner-image`: provides the pinned source/patch artifact
  and its `passthru.release` facts; it is not the long-lived Jellyfin server.
- Jellyfin retained state: is initialized once through Provision mode and then
  consumed by the matching stock runtime. Runtime-only credentials and the
  generated Jellarr key remain out of reusable artifacts and retained files.
- Focused checks: cover fresh state, repeated Pod creation, release mismatch,
  stock-runtime provenance, Jellarr API-key creation/reuse, ownership, and
  post-preflight failures. Existing compute/storage replacement checks remain
  separate.
- Production inspection, secret provisioning, deployment, destructive
  replacement, and service acceptance remain separately authorized and
  operator-gated.
