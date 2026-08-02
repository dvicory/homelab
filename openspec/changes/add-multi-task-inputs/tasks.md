## 1. Kanban input-edge model

- [x] 1.1 Add durable board-qualified `inputs_from` edges, destination input generations, exact producer bindings, and handoff retention references.
- [x] 1.2 Keep `parents` as ordering/summary-only edges and compute readiness from the union of `parents` and `inputs_from` without requiring duplicate declarations.
- [x] 1.3 Reject or normalize a producer named in both edge sets and forbid input-edge mutation while a destination run is active.
- [x] 1.4 Pin a destination input generation to exact producer task/run, lane, optional Project/source generation, handoff, and output manifest before its first run.
- [x] 1.5 Reuse the exact pinned input generation on every destination retry; preserve existing pins if a future trusted re-completion capability is introduced.

## 2. Model-facing task and inspection contracts

- [x] 2.1 Add board-local producer task IDs as the only model-facing `inputs_from` values and keep writable-input or infrastructure selectors out of the task contract.
- [x] 2.2 Keep handoff, run, manifest, generation, provider, workspace/lease, mount path, permission, and writable-input fields out of ordinary task schemas.
- [x] 2.3 Render ordering-only and filesystem input edges distinctly in task inspection, graph views, summaries, and worker context.
- [x] 2.4 Expose the canonical `/workspace/inputs/<producer-task-id>` mapping with producer title, lane, and provenance to the destination worker.
- [x] 2.5 Return stable non-runnable reasons for incomplete, missing, failed, ambiguous, expired, quarantined, or publication-failed producer output.

## 3. Broker input preparation

- [x] 3.1 Add durable deterministic input-preparation operations bound to the complete ordered producer set, destination input generation, lane, board, limits, and policy digest.
- [x] 3.2 Validate every ready handoff and aggregate count/byte/entry/path ceilings before acquiring references or activating the destination.
- [x] 3.3 Make identical preparation replay return or resume one operation and reject every changed bound fact as an idempotency conflict.
- [x] 3.4 Release references at destination finalization and through an idempotent destination-archive operation; mark producer handoffs reclaimable only on producer archive; delete reclaimable bytes synchronously only after the last acquired reference is released; use no timers or sweeps.
- [x] 3.5 Reject cross-board/cross-instance producers, partial input sets, live workspaces, empty substitutes, local paths, and writable input requests.

## 4. Read-only VFS input plane

- [x] 4.1 Mount each exact producer handoff read-only at `/workspace/inputs/<producer-task-id>` without overlays, merges, renames, or automatic copies.
- [x] 4.2 Bind all prepared inputs atomically with the destination work/output workspace and sandbox authority before execution.
- [x] 4.3 Enforce read-only behavior across terminal, execute-code, file, patch, process, symlink, stale-handle, and indirect mutation paths.
- [x] 4.4 Keep completion capture rooted only at `/workspace/output`; input-derived data enters destination output only through an explicit worker copy or synthesis.
- [x] 4.5 Preserve producer task/run, lane, optional Project/source generation, handoff, and manifest provenance without granting direct Project or credential authority.


## 5. Verification

- [x] 5.1 Verify zero-input, one-input, intentionally empty input, multi-input fan-in, and shared-handoff fan-out workflows.
- [x] 5.2 Verify cross-lane same-board inputs preserve provenance and do not grant producer Project workspace, credential, or publication authority (`test/task-run-inputs.test.mjs`, “cross-lane Project provenance does not transfer producer authority”).
- [x] 5.3 Verify destination retry, edge mutation, stale runs, response-loss replay, changed-fact conflicts, and preservation of existing pins under a synthetic newer-completion fixture (`tests/hermes_cli/test_multi_task_inputs.py`, “generation binds exact handoff”; `test/task-run-inputs.test.mjs`, replay and activation conflict cases).
- [ ] 5.4 Verify count/byte/entry/path limits, partial failure, broker outage/restart, reference retention through destination retry, archive-gated release/reclaim (archive refused with live consumers, mark-reclaimable idempotency, referenced-retained/unreferenced-deleted, finalize-time release), workspace cleanup, and final handoff deletion (`test/task-run-inputs*.test.mjs`, `test/workspaces.test.mjs`, `tests/hermes_cli/test_{multi_task_inputs,input_reclaim_guards}.py`).
- [x] 5.5 Smoke-test a fully pre-created research fan-out/fan-in graph and a Project implementation/review/revision graph (`tests/hermes_cli/test_multi_task_inputs.py`, “precreated research graph”; `test/multi-task-workflow-smoke.test.mjs`).
- [ ] 5.6 Run focused Kanban, Hermes, broker, Nix module, and end-to-end checks for the complete immutable input lifecycle (`hermes-worker-lane`: 875 passed; `gondolin-broker-effect`: 90 passed; secure-terminal socket and policy HTTP checks passed).
