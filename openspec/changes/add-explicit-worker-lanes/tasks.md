## 1. Nix declarations and validation

- [x] 1.1 Define typed instance-wide worker-lane declarations for runtime, optional profile, agent configuration, memory, workspace, policy, approval, execution limits, and concurrency.
- [x] 1.2 Define Nix-authoritative board declarations with allowed lanes, allowed Projects, and optional default Project.
- [x] 1.3 Define Nix-authoritative Project source identities and the single per-Project `laneAccess` map without provider allowlists.
- [x] 1.4 Reject duplicate lane names, unknown board/project references, invalid permission escalation, unsupported source/provider combinations, and implicit profile assignments during evaluation.
- [x] 1.5 Render deterministic lane, board, and Project catalogues with revision digests into the Hermes runtime image/configuration.

## 2. Durable runtime model

- [x] 2.1 Add durable lane, Project, and resolved task-run worker-specification representations without making profile names task executors.
- [x] 2.2 Persist board-qualified task/run identity, lane and catalogue revisions, optional Project/source generation, runtime/profile, provider, permission, workspace/lease, policy, agent configuration, and memory namespace atomically before spawn.
- [x] 2.3 Fence retries and stale process/file operations by exact run and workspace generation.
- [x] 2.4 Add stable fail-closed reasons for unknown lane, board denial, Project denial, unsupported project mode/source/provider, permission conflict, incomplete resolution, and stale catalogue revision.

## 3. Explicit lane registry and task API

- [x] 3.1 Replace implicit profile fallback with one registry that materializes Nix-declared Hermes and external lanes in the dispatcher process.
- [x] 3.2 Retain `assignee` as the only model-facing lane selector, enumerate registered lanes dynamically, and remove profile/workspace/provider/path authority fields from the ordinary schema.
- [x] 3.3 Validate board lane/Project participation and Project `laneAccess` at task creation and again immediately before claim.
- [x] 3.4 Keep the live interactive profile non-assignable unless an explicit lane references its runtime configuration.
- [x] 3.5 Ensure one authoritative dispatcher loads the complete lane registry before ticking any configured board.

## 4. Hermes worker resolution

- [x] 4.1 Implement typed worker configuration resolution from immutable operator floor, referenced profile baseline, trusted lane overlay, and bounded task hints.
- [x] 4.2 Apply lane-selected model, reasoning effort, role/SOUL, tools/toolsets, skills, approvals, limits, and completion contract without allowing prompts to weaken backend policy.
- [x] 4.3 Default durable worker memory to disabled; implement explicit lane-scoped and shared-profile modes while keeping task transcripts run-scoped.
- [x] 4.4 Spawn Hermes workers with trusted lane and task-run context, not model or process-global workspace variables.
- [x] 4.5 Adapt external plugin lanes to consume the same resolved worker-specification contract and report unsupported fields explicitly.

## 5. Workspace and sandbox authority binding

- [x] 5.1 Extend trusted sandbox-authority registration to bind board, task/run, lane revision, optional Project/source generation, workspace/lease, effective permission, and policy identity; when Codex is routed through Gondolin, replace its temporary native `codex.lanes.<name>.networkAccess` specialization with broker worklane/network-bundle enforcement.
- [x] 5.2 Route worker CWD, terminal, execute-code, file, search, patch, process, and completion surfaces through the same resolved task-run binding.
- [x] 5.3 Remove the temporary `HERMES_WORKER_SPEC` transport: load the immutable specification from the durable run record or trusted broker control plane using opaque board/task/run/lease identity, enforce model-visible tool filtering and independent broker/backend authorization from that record, and do not introduce derived policy, tool, workspace, or permission environment variables.
- [x] 5.4 Reject missing or conflicting workspace/provider/policy facts before claim or spawn without local, profile, provider, or host-path fallback.

## 6. Configuration and verification

- [x] 6.1 Declare the orchestrator, Hermes worker lanes, external Codex lanes, boards, Projects, lane access, and memory defaults through Nix.
- [x] 6.2 Remove legacy implicit `default` profile assignments and ordinary `workspace_kind`/`workspace_path` routing without aliases; discard incompatible task and workspace state.
- [x] 6.3 Verify registered Hermes and external dispatch, unregistered profile rejection, board denial, Project denial, provider incompatibility, retry fencing, and catalogue-revision conflict.
- [x] 6.4 Verify lane-selected model/SOUL/tools/memory behavior and backend denial of stale or hidden operations.
- [x] 6.5 Smoke-test one orchestrator-created Hermes task and one external task, proving each process and every exposed filesystem surface sees its single resolved workspace.
- [x] 6.6 Run the focused Hermes, broker, Nix module, and end-to-end checks before completing the dependent handoff, Project-workspace, or multi-input changes.
