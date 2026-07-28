## Why

The Gondolin workspace service gives each Hermes Kanban task a private mutable workspace, but completion has no stable broker-owned output boundary. This change freezes exactly `/workspace/output` as one immutable task-run handoff, validates the explicitly selected human artifacts against that frozen tree, and lets the trusted local Hermes gateway deliver those files without reading the live workspace. Later multi-task inputs may consume the same frozen handoff through a separate change.

## What Changes

- A successful broker-backed completion automatically captures exactly `/workspace/output`. An empty directory is valid for prose-only work; every other workspace path remains scratch.
- Kanban requires every model-facing `artifacts` entry to be an explicitly selected normalized relative regular-file path under the trusted task workspace and, for broker-backed work, below `output/`. Summary/result prose cannot discover paths. Native scratch/dir/worktree flows continue to materialize selected files into native attachment storage before `done`.
- Broker-backed completion uses one capture call containing exactly `finalizationId`, trusted `environmentKey`, `taskId`, `runId`, and `selectedArtifacts`. Kanban performs syntax-only path validation first. The broker preflights the live output, consumes and fences the active run, closes and drains the VM, copies to broker-owned temporary storage, validates the detached tree and every selected artifact, fsyncs it, and atomically installs one immutable handoff with a frozen selected-artifact manifest.
- Kanban remains in its existing `running` state until capture returns a ready handoff and verified selected-artifact manifest. Preflight or selected-artifact failure leaves the run active; post-fence failure remains journaled and retryable without publishing a partial tree or inventing a new Kanban state.
- Replaying an identical finalization ID resumes or returns the original handoff after activation consumption. A genuinely fresh attempt uses a fresh run ID and finalization ID and never reopens an old activation.
- Structural validation rejects traversal, malformed or colliding names, symlinks, disallowed hardlinks, special files, unreadable entries, and excess of exactly `maxLogicalBytes`, `maxEntries`, `maxFileBytes`, and `maxPathBytes`. Copying bytes is storage, not content scanning; invalid entries are never silently deleted.
- Completion, block, timeout, and reclaim consume or supersede the active run before VM closure. A stale run or retained lease cannot recreate a generation or mutate retained output.
- Remove the existing `inherit_parent_output` and writable child-import implementation, schemas, persistence, prompts, and tests in this workstream so later multi-task inputs start from a clean immutable-handoff boundary.
- Human delivery uses one authenticated local-UDS read operation containing exactly hidden `handoffId` and normalized `relativePath`. The broker serves only regular files recorded in that handoff's selected-artifact manifest. Hermes materializes the bytes through upstream native attachment storage before platform upload, retries only outstanding recipient deliveries, and does not advance a completion-event cursor on failed materialization or upload.

## Capabilities

### New Capabilities

- `task-workspace-handoffs`: broker-owned task/run fencing, automatic immutable output capture, selected-artifact manifests, recoverable finalization, and trusted local artifact reads.

### Modified Capabilities

- `kanban-sandbox-workspace`: existing workspace completion, retry/block/reclaim lifecycle, native attachment delivery, and outage behavior use the immutable handoff boundary for broker-backed workers.

## Impact

- `pkgs/by-name/gondolin-broker-effect`: task-run activation fencing, handoff records, operation journal, structural validation, frozen storage, and gated local `capture` and `artifacts/read` routes.
- `pkgs/by-name/hermes-agent-patched`: completion/finalization, syntax validation, selected-artifact persistence, native attachment materialization, recipient retry, cursor correctness, and the repository workspace-service bridge.
- `modules/den/aspects/workloads/hermes/secure-terminal/default.nix`: handoff gate, four structural limits, local control-UDS policy actions, storage, and service wiring.

## Deferred Follow-ups

- Worker-to-worker filesystem inputs, fan-in/fan-out, retention references, and read-only input mounts belong to `add-multi-task-inputs`.
- Broker Project source materialization and the three-plane workspace layout belong to `add-broker-project-workspaces`.
- Handoff grants, deletion APIs, deduplication, long-term storage, and shared mutable workspaces.
- Content scanning, semantic validation, secret/malware inspection, and content-derived authority.
- New model-facing cancel, publication, import, export, or workspace-management tools.

## Non-goals

- Writable parent-output inheritance, direct-child private copies, an import route, whole-workspace capture, arbitrary output roots, model-selected storage identifiers, host paths, live co-editing, multi-writer leases, or public artifact URLs.

## Technical Assumptions

- `add-sandbox-workspace-service` is complete and `add-explicit-worker-lanes` supplies the frozen board/task/run/lane/policy binding before the remaining handoff implementation proceeds.
- Trusted dispatch attaches task/run/lane identity and policy facts; model-facing schemas cannot set workspace, lease, handoff, destination, route, or host-path authority.
- The broker journals before filesystem mutation. Handoff and finalization IDs are random opaque lifecycle identifiers, never content-derived authority and never model inputs.
- Capture binds the lane revision and any already-resolved optional Project/source generation as provenance without granting Project authority.
- Local delivery runs only through the protected mode-0600 broker control UDS held by the trusted gateway account.

## Refactoring

The completed broker database and task-run activation work remains the foundation. Keep handoff storage and filesystem enforcement in the broker, generic lifecycle and delivery retry in Hermes, and task state in Kanban. Do not add a provider abstraction, writable child-import compatibility path, or `sandbox-access` extension.
