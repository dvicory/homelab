## Why

Project-linked Kanban tasks currently create gateway-owned host worktrees while Hermes terminal and file tools operate in an unrelated broker workspace. The explicit worker-lane contract needs a trusted Project provider that materializes one task-private repository inside Gondolin and gives every worker surface the same source generation without exposing the gateway checkout, Git metadata, credentials, or host paths.

## What Changes

- Add a broker Project provider that resolves a Nix-authoritative logical Project and immutable source generation into a task-private workspace with one writer lease.
- Introduce the canonical three-plane layout: mutable `/workspace/work`, read-only `/workspace/inputs`, and task-owned `/workspace/output`; discard incompatible legacy workspaces and queued tasks.
- Make `/workspace/work` the worker CWD and materialize a self-contained Git repository there rather than mounting the gateway's linked worktree or canonical checkout.
- Mediate external Codex completion through its trusted wrapper: Codex runs with CWD `/workspace/work`, returns only normalized workspace-root `output/...` selections in its structured result, and the wrapper alone invokes Kanban completion and immutable handoff capture. Changed Git paths are metadata, not artifact authority.
- Support lane-selected `read-only` and `workspace-write` Project permissions while keeping publication, push, merge, and credentials separate.
- Keep source acquisition and private-repository credentials in trusted provider/adaptor code; credentials never enter the guest workspace, VM environment, disk, command line, or task output.
- Persist Project/source generation, workspace, lease, provider revision, and lifecycle facts in the frozen task-run binding and enforce cleanup, retention, crash recovery, and stale-run fencing.
- Produce explicit Project-result metadata suitable for later reviewed promotion without mutating the canonical source automatically.

## Capabilities

### New Capabilities

- `broker-project-workspaces`: Trusted source resolution, task-private project materialization, three-plane workspace layout, Project permissions, generation provenance, and explicit result publication boundary.

### Modified Capabilities

- `kanban-sandbox-workspace`: Activated workspaces use the three-plane layout and bind Project/source generation when a resolved worker lane selects the broker Project provider.

## Impact

- Gondolin Effect broker workspace service, storage model, lifecycle recovery, VFS mounts, source adapters, and Project-result metadata.
- Patched Hermes CWD, terminal, execute-code, file/search/patch/process path resolution, completion finalization, and dispatcher activation.
- Nix project source registry, broker policy, lane provider declarations, source credential adapters, and storage/retention settings.
- Existing broker workspaces and queued tasks may be discarded; no compatibility alias for work rooted directly at `/workspace` is required.
- Depends on `add-explicit-worker-lanes` and the narrowed `add-task-workspace-handoff`; multi-task read-only inputs remain in `add-multi-task-inputs`.
