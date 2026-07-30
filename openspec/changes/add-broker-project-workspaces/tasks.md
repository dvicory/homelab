## 1. Source and provider policy

- [x] 1.1 Add typed Nix Project source-adapter declarations keyed by logical `repositoryId`, with immutable revision selection and no model-facing URL or credential fields.
- [x] 1.2 Add the `broker-project` lane-provider declaration, supported source kinds, read-only/workspace-write modes, and hard materialization/storage limits.
- [x] 1.3 Configure source credentials through trusted adapters and add evaluation assertions preventing store, environment, argv, or guest-path exposure.
- [x] 1.4 Render Project/source and provider revision digests into the broker and Hermes trusted catalogues.

## 2. Broker source-generation model

- [x] 2.1 Add durable Project source-generation, materialization operation, workspace-result, and lifecycle records bound to board-qualified task/run and lane revision.
- [x] 2.2 Implement idempotent detached staging, atomic workspace installation, writer lease acquisition, and conflict detection for one complete task-run binding.
- [x] 2.3 Implement crash reconciliation for abandoned staging, incomplete installation, stale leases, interrupted release, retention, and deletion.
- [x] 2.4 Fence stale runs and changed source/provider revisions without changing the meaning of active source generations.

## 3. Trusted source materialization

- [x] 3.1 Implement the first trusted Git source adapter and acquire public/private source generations without running credential-bearing commands inside the guest.
- [x] 3.2 Materialize a task-private standalone repository whose Git metadata does not reference the gateway checkout, sibling workspaces, or shared external Git directories.
- [x] 3.3 Sanitize remote/configuration state and fail before activation when credential material or host-only paths cannot be proven absent.
- [x] 3.4 Enforce source size, file/entry, path, deadline, workspace-count, and storage limits during materialization.
- [ ] 3.5 Add broker-local baseline/reflink optimization only if needed after the complete-private-repository contract passes unchanged.

## 4. Three-plane workspace

- [x] 4.1 Create `/workspace/work`, `/workspace/inputs`, and `/workspace/output` as distinct broker-managed planes for every new workspace.
- [x] 4.2 Make `/workspace/work` the trusted worker CWD and keep `/workspace/inputs` read-only and initially empty.
- [x] 4.3 Enforce lane/Project effective permission on the work plane while retaining bounded writable output for read-only review tasks.
- [x] 4.4 Route terminal, execute-code, file, search, patch, process, and completion paths through the same three-plane task-run binding.
- [x] 4.5 Run external Codex with CWD `/workspace/work`; extend its strict structured result with normalized workspace-root `output/...` artifact selections; have the trusted wrapper alone validate and pass them to Kanban completion; keep Git changed paths and prose non-authoritative.
- [x] 4.6 Remove direct-`/workspace` work-root assumptions in prompts, configuration, checks, and acceptance tooling without compatibility aliases.

## 5. Project results and lifecycle integration

- [x] 5.1 Record Project, source generation, provider revision, permission, workspace/lease, and materialization provenance in the frozen worker specification and broker audit state.
- [x] 5.2 Keep completion capture rooted exactly at `/workspace/output` and distinct from complete Project-result state.
- [x] 5.3 Record bounded Project-result descriptors for changed workspaces without merge, push, canonical mutation, or implied publication.
- [x] 5.4 Integrate block, timeout, cancellation/reclaim, retry, completion, retention, and deletion with Project workspace lease consumption and stale-run fencing.

## 6. Verification

- [ ] 6.1 Verify public and private source materialization, immutable source identity, self-contained Git metadata, and absence of credentials from environment, argv, files, remotes, logs, snapshots, metadata, and output.
- [ ] 6.2 Verify workspace-write and read-only behavior across terminal, execute-code, file, patch, process, symlink, stale-handle, and concurrent-task paths.
- [ ] 6.3 Verify worker CWD and cross-surface observation under `/workspace/work`, empty read-only `/workspace/inputs`, and output-only completion capture.
- [ ] 6.4 Verify crash/restart at each materialization and release boundary, response-loss replay, quota failures, retry fencing, retention, and cleanup.
- [ ] 6.5 Discard incompatible broker workspaces and queued tasks; retain no legacy root alias or host-worktree fallback.
- [ ] 6.6 Smoke-test one orchestrator-created Codex Project task from source acquisition through changed private work and an explicit `output/...` structured-result selection, proving native task attachment availability, unchanged canonical source, and denial of direct child completion authority.
- [ ] 6.7 Run focused broker, Hermes, Nix module, and end-to-end checks after the narrowed handoff passes and before starting `add-multi-task-inputs`.
