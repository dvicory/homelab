## Context

The current tree already has replaceable Incus lifecycle tooling, canonical checked-in manifests, Argo reconciliation, host-owned retained storage, and staged runtime secrets. This change removes the obsolete cold whole-stack capture and offline image/test fixtures built around restoring disposable state.

## Goals / Non-Goals

**Goals:**

- Make `compute-guest replace`, Argo seeding, secret staging, and retained-storage reattachment the only compute-loss path.
- Remove cold export/restore/resume orchestration and offline production assumptions.
- Keep application-consistent backup work outside this change.

**Non-Goals:**

- Selecting or implementing a backup engine, schedule, retention policy, or off-host destination.
- Changing storage placement, media pooling, encryption layering, or multi-node topology.
- Publishing the local Kanidm provisioning image to a registry; host staging remains the supported local path.

## Decisions

- Replace broad static bootstrap with the Argo seed: retained `argocd` namespace, Argo CRDs/controllers, staged Argo Secret, then explicit application of the canonical root Argo Application.
  - Alternative: apply every canonical workload statically. Not selected because it bypasses Argo ownership and restores disposable cluster state.
- Delete `household-recovery`, its generated inventory/journal/metrics protocol, and offline Jellyfin fixtures.
  - Alternative: retain the export/restore path as an offline fallback. Not selected because supported recovery reconstructs disposable state instead of restoring it.
- Delete the manual offline sandbox bundle/guide.
  - Alternative: retain the sandbox as a learning bundle. Not selected because it duplicates test inputs and documents an unsupported recovery shape.
- Rewrite the x86_64 `prod-home-replacement` acceptance around online
  replacement: a new guest, fresh cluster identity, staged secrets, the shipped
  Argo seed/root handoff through a test-local root Application, a disposable Git
  origin holding verbatim canonical manifests, real registry image pulls, and
  retained Jellyfin state verification. Keep application-only HTTP behavior in
  `modules/tests/jellyfin_smoke.py`; the platform driver owns orchestration.
  - Alternative: use hermetic `dockerTools.pullImage` fixtures with per-architecture hashes. Not selected because acceptance must exercise the registry dependency of supported recovery and avoid version-specific archive fixtures.
  - The disposable Git origin stands in for GitHub transport only; manifest content under test stays canonical, and production image identity is never duplicated into the test.
- Replace household recovery alerts with replacement/reconciliation health and backup-completion signals.
  - Alternative: retain stale-point alerts. Not selected because they describe obsolete export artifacts rather than replacement/reconciliation health.

## Risks / Trade-offs

- [Risk] Argo reconciliation requires Git and registry access during rebuild → accepted explicitly by the operator; running workloads are expected to tolerate outages, while rebuild is not.
- [Risk] The integration test needs network access and may fail when an external registry is unavailable → accepted explicitly; that failure tests a dependency the supported path really has. Deterministic contracts stay in evaluation-time checks.
- [Risk] The local Kanidm provisioning image remains host-staged; this does not block Jellyfin recovery.
- [Risk] Application-consistent capture remains outside this change; preserve database/filesystem seams for a separate backup implementation.

## Migration Plan

1. Remove obsolete recovery, test, and sandbox outputs.
2. Narrow bootstrap and monitoring to the supported replacement path.
3. Verify manifest freshness, evaluation contracts, and the x86_64 replacement acceptance.

Rollback is a repository revert; no live migration is authorized here.
