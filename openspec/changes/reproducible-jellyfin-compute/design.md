## Context

This change keeps the shared, replaceable unprivileged Incus compute guest,
secret-free guest artifacts, explicit maintenance boundaries, and the isolation
decision in [ADR-0001](../../../docs/architecture/decisions/0001-unprivileged-application-compute.md).
The [delta spec](specs/compute-recovery/spec.md) defines the proposed
contracts; current specs remain authoritative until this change is applied.

The Jellyfin workload now has three intentionally separate runtime owners:

1. a short-lived patched Jellyfin provisioner initContainer for fresh retained
   state;
2. the stock official Jellyfin image for the long-lived server; and
3. a separately pinned, API-only Jellarr one-shot for selected ongoing
   configuration.

Nix/Den and Kubernetes declare the boundaries and delivery. Preserve owns
retained-state protection and recovery policy. This document is a plan, not a
claim that the new provisioner/runtime/Jellarr implementation or target
acceptance is complete. Production inspection, secrets, deployment, and
 destruction require separate authorization.

## Release identity and upgrade coupling

Jellyfin state is shared by the provisioner and the stock runtime, so release
identity is one invariant rather than two independently configurable images.
The Nix-owned declaration consumed by `pkgs.jellyfin-provisioner-image` and
Jellyfin manifests records:

| Field | Required identity |
| --- | --- |
| `version` | `12.1` |
| `sourceRev` | `ee91c75e777da41a9c4f4855e70adc604fbf2ef8` |
| `runtimeImage` | the official `docker.io/jellyfin/jellyfin:12.1` image reference |
| `runtimeDigest` | the exact pinned architecture-specific digest for that official image |
| `provisionPatchRev` | `8b0a2c269d5a3d9d7084b5295fd818a8a67af6f2` |

The package exposes these facts through `passthru.release`; manifests consume
that declaration instead of repeating a version or digest. Evaluation/build
checks reject a provisioner base release that differs from the stock runtime
release. A Jellyfin upgrade changes source, runtime image/digest, and all
compatibility evidence together in one reviewed change. An image-only updater
must not move the runtime independently, and the provisioner must not move to
a future source revision independently.

Jellarr is pinned separately to v0.1.0 commit
`f94c24f26c0264a7c331b016968d5b6e8d1504b7`. Its pin may change independently
only as a reviewed API-compatible reconciliation change; it does not define
the Jellyfin server release identity.

## Bounded PR #17902 spike

The provisioning backport is deliberately narrow. The exact PR #17902 commit
`8b0a2c269d5a3d9d7084b5295fd818a8a67af6f2` applies cleanly to Jellyfin source
`ee91c75e777da41a9c4f4855e70adc604fbf2ef8` (v12.1), with no unrelated
post-v12.1 tree carried into the provisioner.

The spike also records the important execution boundary: in Provision mode the
patch starts only `SetupServer`; it does not start Jellyfin's normal listener.
The initContainer therefore can complete first-start setup without an
unauthenticated `/Startup/*` race or a ready backend.

The patch's provisioning work is non-transactional after preflight. Preflight
can reject missing or invalid inputs before mutation, but a failure after
preflight may leave partial retained state; there is no implied rollback. The
focused acceptance must deliberately exercise such failures, verify that the
initContainer reports failure and the stock runtime does not become ready, and
record the retained-state outcome. Do not hide this behavior behind retries or
claim transactional recovery.

## Ownership and lifecycle

### Explicit owners

| Owner | Owns | Must not own |
| --- | --- | --- |
| Nix/Den | Release declaration and pins; provisioner package inputs; non-secret desired values; workload, storage, media, resource, security, Service/Gateway, and Jellarr configuration declarations | Runtime-generated credentials; Jellyfin's internal steady-state XML/SQLite; a second release identity |
| Kubernetes/Argo | Pod ordering; retained `/config` and media mounts; initContainer completion gate; stock Service/readiness; one Jellarr PostSync/equivalent Job owner and its health/failure visibility | A second inventory/pruner; direct database bootstrap; readiness before provisioning succeeds |
| Patched Jellyfin provisioner | Fresh empty-state initialization, initial administrator creation, startup-wizard completion, and fields explicitly supported by PR #17902 during Provision mode | Long-lived serving; later Pod-start rewrites; Jellarr-owned steady-state settings |
| Official stock Jellyfin runtime | Long-lived Jellyfin process, its database/state internals, media processing, upstream ffmpeg/GPU userspace, fonts, runtime libraries, and unspecified application behavior | Patched assemblies or Nix-rebuilt multimedia packaging; first-start HTTP enrollment |
| Jellarr | Only the supported API settings explicitly selected in its declarative config, reconciled by a one-shot after runtime health | `startup.completeStartupWizard`; XML/SQLite edits; every unspecified Jellyfin field; a periodic controller |
| Preserve | Backup/recovery policy, retained-state protection, recovery evidence, and restore authorization | Startup, runtime configuration, release selection, or API-key bootstrap |

The provisioner creates one normal declarative administrator. Its password is
an agenix-managed runtime input. Jellarr may reconcile supported policy or
password fields only when explicitly selected, and the desired value must be
coherent with the provisioner. No second undocumented automation administrator
is introduced.

## First-start flow

The Jellyfin Pod mounts the retained `/config` into both the provisioner and
stock runtime, but only the initContainer can run before the runtime becomes
ready:

1. Kubernetes mounts retained `/config`, a read-only agenix-backed credential
   input, declarative non-secret values, and a memory-backed `emptyDir`.
2. The provisioner assembles the final provision input in that memory-backed
   volume with restrictive ownership and mode. The file is removed after use.
3. The provisioner performs preflight and invokes the pinned Provision mode.
   Provision mode runs only its internal `SetupServer`; it does not run the
   stock server.
4. A successful fresh run exits; only then can the stock official
   `docker.io/jellyfin/jellyfin:12.1` container start and pass readiness.
5. Service/Gateway objects may already exist, but no externally routable
   Jellyfin backend exists until provisioning completes and the stock runtime
   passes its probes.

The final credential-bearing provision file is never stored in Git, generated
manifests, the Nix store, logs, command-line arguments, or retained `/config`.
It is assembled only at runtime, uses the same effective Jellyfin UID/GID as
retained state unless execution evidence requires otherwise, and is removed
before the Pod proceeds. The normal stock container is not rebuilt by Nix and
keeps upstream ffmpeg, GPU userspace, fonts, libraries, and filesystem
conventions.

On an already initialized `/config`, Provision mode must succeed as a no-op.
It must not reset the administrator password, recreate users or libraries,
rewrite Jellarr-owned values, or fail merely because setup is complete. If the
upstream patch needs a compatibility adjustment for that behavior, carry only
the smallest Provision-mode change; do not add an internal database parser.

## Jellarr reconciliation and API-key bootstrap

Jellarr runs as one pinned declarative Job after the stock runtime is healthy.
Its sync owner is singular (for example, one Argo PostSync hook), failures are
visible, and a configuration change causes the Job to run again. No periodic
daemon or second pruning/controller owner is needed for this cut.

The Job's initContainer mounts the administrator password read-only, waits for
the stock Jellyfin Service to be healthy, and uses Jellyfin's supported
authenticated APIs to:

1. authenticate as the normal administrator;
2. list API keys and find the key named for Jellarr;
3. create that key if it is absent;
4. re-read the resulting key; and
5. write only the resulting token to an ephemeral memory-backed shared volume.

The Jellarr container reads that token and exports `JELLARR_API_KEY` only for
its process. The generated key is not copied into agenix, Git, the Nix store,
or a durable Kubernetes Secret. A later cluster reconstruction can rediscover
the retained key through the same supported API, and can recreate it if the
key is absent. Direct SQLite bootstrap is explicitly forbidden.

Jellarr owns only API-exposed settings present in its declarative config. The
initial administrator and completion of the startup wizard remain provisioner
responsibilities; Jellarr must not configure `startup.completeStartupWizard`.
Where both phases touch a supported field, the provisioner establishes the
initial value and Jellarr becomes the ongoing owner with the same desired
value. Routine reconciliation never copies generated XML or rewrites SQLite.

## Storage and exposure constraints

The startup architecture also keeps these workload constraints:

- Gateway timeouts must be streaming-safe rather than using a short request
  deadline that interrupts Jellyfin playback.
- Proxy/access logging must not retain query strings or credential-bearing
  parameters, while preserving the trusted request-ID boundary.
- Media storage must use the semantic read-only projection and consistent
  storage-placement documentation; a mountpoint directory is not a valid
  source substitute.
- Jellyfin PV/PVC and retained resources must have one static ownership model
  with deletion protection, not an implicit dynamic replacement path.
- Cache and ephemeral-storage requests/limits must be coherent and bounded,
  separate from retained config/media capacity.
- Cheap structural checks must cover image pinning, stock-runtime provenance,
  initContainer ordering, UID/GID and read-only media, route exposure, and
  owner separation.
- Current acceptance evidence remains required, and Python scenario cache
  cleanup must not leave generated caches in the source tree.

## Verification and deployment gates

Focused checks are planned for the provisioner/runtime boundary:

- fresh empty `/config`: no HTTP listener during provisioning, successful
  initial administrator creation, completed startup state, and a healthy stock
  v12.1 runtime;
- repeated Pod creation: successful no-op, unchanged credentials/libraries,
  and normal stock startup;
- release mismatch: an independent provisioner/runtime bump fails evaluation
  or build;
- stock-runtime proof: the long-lived process comes from the official pinned
  image, not the patched provisioner, and retains the expected upstream runtime
  integration;
- Jellarr bootstrap and repeat: supported API authentication creates exactly
  one key, subsequent runs reuse it, and an API-owned setting returns to its
  declared value;
- failure injection after provisioning preflight: partial/non-transactional
  behavior is observable, readiness remains blocked, and no false recovery is
  reported.

Platform checks cover evaluated compute configuration, guest artifact
boundaries, identity delivery, Argo bootstrap, generated resource structure,
and lifecycle preconditions. They do not establish target boot, physical
storage behavior, production secret provisioning, or destructive replacement.
Operator-gated deployment and replacement must separately inspect mounts,
capacity, kernel/cgroups/confinement, ID and route collisions, resource
ownership, media behavior, and independent management access. Stop for any
required isolation or storage-permission expansion.
