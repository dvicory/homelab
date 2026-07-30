## Why

Project-linked Kanban tasks currently create gateway-owned host worktrees while Hermes terminal and file tools operate in an unrelated broker workspace. The explicit worker-lane contract needs a trusted, provider-neutral Project source contract that materializes one task-private source generation inside Gondolin and gives every worker surface the same workspace without exposing the gateway checkout, acquisition credentials, or host paths.

## What Changes

- Add a broker Project provider that resolves a Nix-authoritative logical Project and provider-neutral immutable source generation into a task-private workspace with one writer lease.
- Introduce the canonical three-plane layout: mutable `/workspace/work`, read-only `/workspace/inputs`, and task-owned `/workspace/output`; discard incompatible legacy workspaces and queued tasks.
- Make `/workspace/work` the worker CWD. Implement Git as the first source adapter by materializing a self-contained repository there rather than mounting the gateway's linked worktree or canonical checkout; preserve the contract for future archive, generated, and operator-imported source kinds.
- Mediate external Codex completion through its trusted wrapper: Codex runs with CWD `/workspace/work`, returns only normalized workspace-root `output/...` selections in its structured result, and the wrapper alone invokes Kanban completion and immutable handoff capture. Provider-specific changed-path metadata is not artifact authority.
- Support lane-selected `read-only` and `workspace-write` Project permissions while keeping publication, push, merge, and credentials separate.
- Keep acquisition credentials inside trusted adapters and exclude them from guest-visible commands and bytes by construction; sanitization and scanning are defense in depth, not a universal proof that arbitrary source content cannot contain matching bytes.
- Persist Project/source generation, workspace, lease, provider revision, and lifecycle facts in the frozen task-run binding and enforce cleanup, retention, crash recovery, and stale-run fencing.
- Freeze a provider-neutral immutable Project result at successful writable completion, then release and delete the mutable workspace according to explicit retention/reference policy. Publication consumes the immutable result and never mutates the task workspace.

## Capabilities

### New Capabilities

- `broker-project-workspaces`: Trusted provider-neutral source resolution, task-private Project materialization, three-plane workspace layout, Project permissions, immutable result capture, workspace deletion, generation provenance, and explicit publication boundary.

### Modified Capabilities

- `kanban-sandbox-workspace`: Activated workspaces use the three-plane layout and bind Project/source generation when a resolved worker lane selects the broker Project provider.

## Impact

- Gondolin Effect broker workspace service, storage model, lifecycle recovery, VFS mounts, source-adapter interface, first Git adapter, immutable Project-result metadata/storage, and physical quota enforcement.
- Patched Hermes CWD, terminal, execute-code, file/search/patch/process path resolution, completion finalization, and dispatcher activation.
- Nix Project/source registry, broker policy, lane provider declarations, acquisition-credential adapters, and storage/retention settings. Host-path sources remain deferred and MUST NOT be approximated by live bind mounts.
- Existing broker workspaces and queued tasks may be discarded; no compatibility alias for work rooted directly at `/workspace` is required.
- Depends on `add-explicit-worker-lanes` and the narrowed `add-task-workspace-handoff`; multi-task read-only inputs remain in `add-multi-task-inputs`.
