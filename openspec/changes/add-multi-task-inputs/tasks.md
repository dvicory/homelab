## 1. Kanban input-edge model

- [ ] 1.1 Add durable board-qualified `inputs_from` edges, destination input generations, exact producer bindings, and handoff retention references.
- [ ] 1.2 Keep `parents` as ordering/summary-only edges and compute readiness from the union of `parents` and `inputs_from` without requiring duplicate declarations.
- [ ] 1.3 Reject or normalize a producer named in both edge sets and forbid input-edge mutation while a destination run is active.
- [ ] 1.4 Pin a destination input generation to exact producer task/run, lane, optional Project/source generation, handoff, and output manifest before its first run.
- [ ] 1.5 Reuse a pinned input generation on destination retry; require an explicit trusted reset to consume a newer producer completion.

## 2. Model-facing task and inspection contracts

- [ ] 2.1 Add board-local producer task IDs as the only model-facing `inputs_from` values and keep writable-input or infrastructure selectors out of the task contract.
- [ ] 2.2 Keep handoff, run, manifest, generation, provider, workspace/lease, mount path, permission, and writable-input fields out of ordinary task schemas.
- [ ] 2.3 Render ordering-only and filesystem input edges distinctly in task inspection, graph views, summaries, and worker context.
- [ ] 2.4 Expose the canonical `/workspace/inputs/<producer-task-id>` mapping with producer title, lane, and provenance to the destination worker.
- [ ] 2.5 Return stable non-runnable reasons for incomplete, missing, failed, ambiguous, expired, quarantined, or publication-failed producer output.

## 3. Broker input preparation

- [ ] 3.1 Add durable deterministic input-preparation operations bound to the complete ordered producer set, destination input generation, lane, board, limits, and policy digest.
- [ ] 3.2 Validate every ready handoff and aggregate count/byte/entry/path ceilings before acquiring references or activating the destination.
- [ ] 3.3 Make identical preparation replay return or resume one operation and reject every changed bound fact as an idempotency conflict.
- [ ] 3.4 Acquire and release durable handoff references transactionally, including restart reconciliation, destination replacement/deletion, active runs, and retention expiry.
- [ ] 3.5 Reject cross-board/cross-instance producers, partial input sets, live workspaces, empty substitutes, local paths, and writable input requests.

## 4. Read-only VFS input plane

- [ ] 4.1 Mount each exact producer handoff read-only at `/workspace/inputs/<producer-task-id>` without overlays, merges, renames, or automatic copies.
- [ ] 4.2 Bind all prepared inputs atomically with the destination work/output workspace and sandbox authority before execution.
- [ ] 4.3 Enforce read-only behavior across terminal, execute-code, file, patch, process, symlink, stale-handle, and indirect mutation paths.
- [ ] 4.4 Keep completion capture rooted only at `/workspace/output`; input-derived data enters destination output only through an explicit worker copy or synthesis.
- [ ] 4.5 Preserve producer task/run, lane, optional Project/source generation, handoff, and manifest provenance without granting direct Project or credential authority.


## 5. Verification

- [ ] 5.1 Verify zero-input, one-input, intentionally empty input, multi-input fan-in, and shared-handoff fan-out workflows.
- [ ] 5.2 Verify cross-lane same-board inputs preserve provenance and do not grant producer Project workspace, credential, or publication authority.
- [ ] 5.3 Verify producer retry after binding, destination retry, explicit input reset, edge mutation, stale runs, response-loss replay, and changed-fact conflicts.
- [ ] 5.4 Verify count/byte/entry/path limits, partial failure, broker outage/restart, reference retention, workspace cleanup, and final handoff deletion.
- [ ] 5.5 Smoke-test a fully pre-created research fan-out/fan-in graph and a Project implementation/review/revision graph.
- [ ] 5.6 Run focused Kanban, Hermes, broker, Nix module, and end-to-end checks for the complete immutable input lifecycle.
