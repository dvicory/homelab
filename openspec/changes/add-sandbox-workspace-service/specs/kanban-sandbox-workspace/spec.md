## ADDED Requirements

### Requirement: Trusted Kanban workspace acquisition

When the QA Gondolin backend is selected, trusted Kanban claim/dispatch code MUST acquire or reuse a broker workspace for the task and persist only its opaque workspace ID. Model-facing Kanban arguments MUST NOT select a workspace ID, lease, host path, or provider.

#### Scenario: First task claim
- **GIVEN** a claimed QA Kanban task with no sandbox workspace ID
- **WHEN** a registered Gondolin worker lane prepares the task
- **THEN** trusted infrastructure SHALL acquire a private workspace from the broker
- **AND** SHALL persist the returned workspace ID on the task before worker execution

#### Scenario: Model supplies workspace selection
- **WHEN** model-generated Kanban arguments contain a workspace ID, lease ID, provider, or host path
- **THEN** Hermes MUST ignore or reject those fields
- **AND** MUST NOT forward them to the broker control plane

### Requirement: Consistent worker filesystem binding

A Gondolin Kanban worker's terminal and environment-backed file surfaces MUST use the task workspace binding and guest path `/workspace`. Hermes MUST NOT present the gateway host worktree as if it were the sandbox workspace.

#### Scenario: Worker environment
- **GIVEN** a claimed task with a persisted sandbox workspace ID
- **WHEN** Hermes launches its worker
- **THEN** the worker SHALL receive `HERMES_KANBAN_WORKSPACE_ID` and `TERMINAL_CWD=/workspace`
- **AND** SHALL NOT receive the broker host path

#### Scenario: Terminal reuse
- **GIVEN** a worker that has written a file through Gondolin
- **WHEN** a later terminal or file tool call resolves the same task
- **THEN** it SHALL resolve the same workspace ID and active lease

### Requirement: Retry and completion lifecycle

Retries of one Kanban task MUST reuse its retained workspace. Completion or terminal cancellation MUST close the live VM and release the writable lease without deleting workspace files. Concurrent child tasks MUST NOT inherit one mutable workspace lease.

#### Scenario: Task retry
- **GIVEN** a failed worker attempt with retained workspace files
- **WHEN** the dispatcher starts a later attempt for the same task
- **THEN** it SHALL reacquire or reuse that task's workspace
- **AND** the later VM SHALL observe the retained files

#### Scenario: Concurrent children
- **GIVEN** a parent task with two concurrently runnable child tasks
- **WHEN** both are dispatched under Gondolin
- **THEN** each child SHALL receive a distinct private workspace ID

#### Scenario: Task completion
- **GIVEN** a task holding an active workspace lease
- **WHEN** the task reaches its terminal completion path
- **THEN** trusted lifecycle code SHALL close its VM and release its lease
- **AND** SHALL retain the workspace for explicit later cleanup

### Requirement: Backend compatibility

The workspace integration MUST be gated to the Gondolin secure-terminal backend. Existing local, Podman, production, and non-sandbox worker workspace behavior MUST remain unchanged.

#### Scenario: Non-Gondolin worker
- **GIVEN** a task dispatched by a profile or lane not using Gondolin
- **WHEN** worker environment variables are prepared
- **THEN** Hermes SHALL retain its existing workspace behavior
- **AND** SHALL NOT call the Gondolin workspace control routes

## Mechanism

- `pkgs/by-name/hermes-agent-patched` extends the repository-owned sandbox-access plugin with trusted workspace acquire/release functions over the control Unix socket.
- The Hermes Kanban patch adds a nullable `sandbox_workspace_id` task field and idempotent migration, persists the opaque ID during trusted dispatch, and injects it into worker infrastructure context only.
- Canonical environment-key derivation remains in the existing task-environment registry; the workspace ID is not accepted by individual terminal/file tool schemas.
- `modules/den/aspects/workloads/hermes/secure-terminal/default.nix` enables the integration only for the QA Gondolin profile and provides the existing read-only broker socket mount.
- No Kanban model tool gains workspace-management parameters.