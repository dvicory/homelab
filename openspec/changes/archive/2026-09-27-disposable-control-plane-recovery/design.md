## Context

The current tree has replaceable Incus lifecycle tooling, canonical checked-in
manifests, Argo reconciliation, host-owned retained storage, and staged runtime
secrets. This change removes obsolete cold whole-stack capture and offline
fixtures built around restoring disposable state.

## Goals / Non-Goals

**Goals:**

- Make `compute-guest replace`, Argo seeding, secret staging, and retained
  storage reattachment the compute-loss boundary.
- Remove cold export/restore/resume orchestration and offline production
  assumptions.
- Keep application-specific data protection and restoration outside this
  change; later owners may consume the retained-state boundary.

**Non-Goals:**

- Selecting or implementing a protection engine, schedule, retention policy,
  or destination.
- Changing storage placement, media pooling, encryption layering, or
  multi-node topology.
- Publishing a local provisioning image to a registry; host staging remains
  the supported local path.

## Decisions

- Replace broad static bootstrap with the Argo seed: retained `argocd`
  namespace, Argo CRDs/controllers, staged runtime Secrets, then explicit
  application of the canonical root Argo Application.
  - Alternative: apply every canonical workload statically. Not selected
    because it bypasses Argo ownership and restores disposable cluster state.
- Delete `household-recovery`, its generated inventory/journal/metrics protocol,
  offline fixtures, and the manual offline sandbox.
  - Alternative: retain the export/restore path as an offline fallback. Not
    selected because supported recovery reconstructs disposable state instead
    of restoring it.
- Keep the executable target-runtime replacement scenario and any
  application-specific reconciliation evidence in a later workload cut. This
  platform revision records the boundary and does not claim that evidence.

## Risks / Trade-offs

- [Risk] Argo reconciliation requires Git and registry access during rebuild.
  Running workloads may tolerate outages, but rebuild is not offline.
- [Risk] A later integration test may need external registry access. That is
  evidence for the supported dependency, not a reason to add offline fixtures.
- [Risk] Application-specific protection remains outside this change; its owner
  must preserve the retained-state and lifecycle seams exposed here.

## Migration Plan

1. Remove obsolete recovery, test, and sandbox outputs.
2. Narrow bootstrap to the supported Argo seed and root handoff.
3. Keep the generated manifest source and operations runbook aligned with the
   tracked deployment ref.

Rollback is a repository revert; no live migration is authorized here.
