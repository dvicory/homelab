## Context

See `proposal.md` for motivation. The current tree already has replaceable Incus lifecycle tooling, canonical checked-in manifests, Argo reconciliation, host-owned retained storage, and staged runtime secrets. The obsolete layer is cold whole-stack capture plus offline image/test fixtures built around restoring that disposable state.

## Goals / Non-Goals

**Goals:**

- Make `compute-guest replace`, Argo seeding, secret staging, and retained-storage reattachment the only compute-loss path.
- Remove cold export/restore/resume orchestration and offline production assumptions.
- Keep application-consistent backup work as a separate future slice.

**Non-Goals:**

- Selecting or implementing a backup engine, schedule, retention policy, or off-host destination.
- Changing storage placement, media pooling, encryption layering, or multi-node topology.
- Publishing the local Kanidm provisioning image to a registry; retain narrow host staging until that follow-up.

## Decisions

- Replace broad static bootstrap with the Argo seed: retained `argocd` namespace, Argo CRDs/controllers, staged Argo Secret, then explicit application of the canonical root Argo Application.
  - Alternative retained: apply every canonical workload statically. Rejected because it bypasses Argo ownership and restores disposable cluster state.
- Delete `household-recovery`, its generated inventory/journal/metrics protocol, and offline Jellyfin fixtures.
  - Alternative retained: keep them as an offline fallback. Rejected because the operator does not require offline cluster reconstruction and the fallback preserves the wrong architecture.
- Delete the manual offline sandbox bundle/guide.
  - Alternative retained: relabel it as a learning exercise. Rejected because it duplicates test inputs and documents an unsupported recovery shape.
- Rewrite the x86_64 `prod-home-replacement` acceptance around online
  replacement: a new guest, fresh cluster identity, staged secrets, the shipped
  Argo seed/root handoff through a test-local root Application, a disposable Git
  origin holding verbatim canonical manifests, real registry image pulls, and
  retained Jellyfin state verification. Keep application-only HTTP behavior in
  `modules/tests/jellyfin_smoke.py`; the platform driver owns orchestration.
  - Alternative retained: hermetic `dockerTools.pullImage` fixtures with per-architecture hashes. Rejected by the operator: the test should exercise the registry dependency production recovery actually has, and must not carry version-specific archive fixtures.
  - The disposable Git origin stands in for GitHub transport only; manifest content under test stays canonical, and production image identity is never duplicated into the test.
- Replace household recovery alerts with replacement/reconciliation health and future backup-completion signals.
  - Alternative retained: keep stale-point alerts. Rejected because they measure obsolete export artifacts, not recovery capability.

## Risks / Trade-offs

- [Risk] Argo reconciliation requires Git and registry access during rebuild → accepted explicitly by the operator; running workloads are expected to tolerate outages, while rebuild is not.
- [Risk] The integration test needs network access and may fail when an external registry is unavailable → accepted explicitly; that failure tests a dependency the supported path really has. Deterministic contracts stay in evaluation-time checks.
- [Risk] Local Kanidm provisioning image remains host-staged → narrow exception with registry publication as follow-up; it does not block Jellyfin recovery.
- [Risk] Application-consistent capture still needs design → preserve database/filesystem seams in a later backup change; do not smuggle a backup engine into this change.

## Migration Plan

1. Land contract delta and ADR history.
2. Remove obsolete recovery/test/sandbox outputs.
3. Narrow bootstrap and monitoring to the supported path.
4. Update operations docs and active overlapping deltas.
5. Verify manifest freshness, evaluation contracts, and the replacement test.

Rollback is repository revert; no live migration is authorized here.
