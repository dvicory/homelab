## 1. Source and provider policy

- [ ] 1.1 Replace Git-shaped Project source declarations with a typed provider-neutral `SourceSpec` and logical source identifier while preserving Git as the only initially enabled kind.
- [ ] 1.2 Define a source-adapter interface for immutable generation resolution, task-private materialization, provider provenance, result capture, and publication preparation; keep adapter and provider selection out of model-facing inputs.
- [ ] 1.3 Confine acquisition credentials by construction and replace universal `assertSanitized` claims with bounded checks over adapter-owned environment, argv, helpers, remotes, logs, staging metadata, and guest-visible configuration.
- [x] 1.4 Render Project/source and provider revision digests into the broker and Hermes trusted catalogues.
- [ ] 1.5 Keep host-path sources disabled; reject model-selected paths and document the future immutable snapshot/import contract without adding a live bind-mount fallback.

## 2. Broker source-generation model

- [ ] 2.1 Generalize durable Project source-generation, materialization operation, immutable result, and lifecycle records so Git metadata is optional adapter provenance rather than the Project identity.
- [x] 2.2 Implement idempotent detached staging, atomic workspace installation, writer lease acquisition, and conflict detection for one complete task-run binding.
- [x] 2.3 Implement crash reconciliation for abandoned staging, incomplete installation, stale leases, interrupted release, retention, and deletion.
- [x] 2.4 Fence stale runs and changed source/provider revisions without changing the meaning of active source generations.

## 3. Trusted source materialization

- [x] 3.1 Implement the first trusted Git source adapter and acquire public/private source generations without running credential-bearing commands inside the guest.
- [x] 3.2 Materialize a task-private standalone repository whose Git metadata does not reference the gateway checkout, sibling workspaces, or shared external Git directories.
- [ ] 3.3 Remove or rewrite credential-bearing helper state, environment, arguments, remotes, configuration, logs, and host paths before activation; use exact-value scans only as regression checks, not proof over arbitrary source bytes.
- [ ] 3.4 Enforce source logical limits and a separate projected physical reservation for every materialization, including concurrent workspaces reusing one source generation; release reservations idempotently on abort and deletion.
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
- [ ] 5.3 Freeze a bounded provider-neutral immutable Project result and selected source-relative delta before completion releases its writer lease; preserve Git commits/bundle/patch/history only as optional adapter metadata.
- [ ] 5.4 Add durable completion, release, retention/reference, physical deletion, and startup reconciliation so successful mutable workspaces cannot remain indefinitely or become the only copy of a result.

## 6. Verification

- [ ] 6.1 Verify public and private Git materialization, immutable source identity, self-contained Git metadata, and absence of adapter-owned credentials from environment, argv, helpers, remotes, configuration, logs, snapshots, task metadata, and output without claiming arbitrary source-byte proof.
- [ ] 6.2 Verify workspace-write and read-only behavior across terminal, execute-code, file, patch, process, symlink, stale-handle, and concurrent-task paths.
- [ ] 6.3 Verify worker CWD and cross-surface observation under `/workspace/work`, empty read-only `/workspace/inputs`, and output-only completion capture.
- [ ] 6.4 Verify crash/restart at each materialization, immutable-result capture, release, deletion, and reservation boundary; response-loss replay; concurrent projected quota failures; retry fencing; retention; and startup reconciliation.
- [ ] 6.5 Verify provider-neutral source/result records accept Git adapter provenance without requiring it from a synthetic non-Git test adapter; verify host-path/model path requests fail closed.
- [ ] 6.6 Discard incompatible broker workspaces and queued tasks; retain no legacy root alias, host-worktree fallback, or live host-path mount.
- [ ] 6.7 Smoke-test one orchestrator-created Codex Project task from source acquisition through changed private work, immutable Project-result capture, explicit `output/...` selection, mutable-workspace deletion, native task attachment availability, unchanged canonical source, and denial of direct child completion authority.
- [ ] 6.8 Run focused broker, Hermes, Nix module, and end-to-end checks after the narrowed handoff passes and before depending on Project results in approved orchestration.
