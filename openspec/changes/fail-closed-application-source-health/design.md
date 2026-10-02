## Context

See proposal.md for motivation. The existing Application health customization in `modules/den/aspects/kubernetes/services/argocd.nix` propagates `status.health` and defaults to Progressing when health is absent. Argo can report a missing Git path as `ComparisonError` while leaving health Healthy. The focused controller fixture already exposes that failure.

## Goals / Non-Goals

Use the existing parent-wave health boundary. Do not require every child to be Synced, create a dependency controller, change retry policy or make independently syncing Applications transactional. Existing workload health remains distinct from source availability.

## Decisions

- Inspect explicit `ComparisonError` conditions before propagating child health; return Degraded for that error. Preserve ordinary health otherwise. This covers the observed failure without treating every OutOfSync or Unknown sync status as broken.
- Use a fixed, useful health message rather than copying arbitrary source-error text into another status field. The original Application condition remains available for diagnosis.
- Reuse execution of the rendered Lua for error precedence, missing status, unrelated conditions, OutOfSync and cleared-error cases. Do not pin Lua source text.
- Extend the existing disposable Argo scenario to correct the missing source, correlate the new source revision, observe the condition clear and require the previously blocked later-wave workload to run. Reverting the health guard must expose the original early advancement.
- Keep the production fix and contract delta in their own revision. Integrate that revision under the verification work, then regenerate canonical manifests with the existing writer.

## Risks / Trade-offs

- Transient repository errors can block later waves while workloads remain available → document the distinction; restore progress through ordinary reconciliation after source recovery.
- Parent waves also contain unrelated applications → retain existing ordering rather than introducing a new dependency model.
- A stale error condition can delay advancement until refresh → the native recovery scenario must prove the real controller clears it and resumes.
- Independent child auto-sync is not gated by this rule → do not describe the result as a global rollout lock or a guarantee that no child can change.

## Migration Plan

Prepare and verify the isolated revision, regenerate the affected ConfigMap, and open a draft review on an unwatched branch. No merge or live Argo configuration change is authorized. After operator-approved deployment, repair source errors before expecting later parent waves to advance. Reverting the health customization restores the previous fail-open behavior; no data migration is involved.
