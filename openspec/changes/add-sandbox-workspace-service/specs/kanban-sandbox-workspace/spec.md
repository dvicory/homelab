## ADDED Requirements

### Requirement: Trusted Kanban workspace acquisition

When the QA Gondolin backend is selected, trusted Kanban claim/dispatch code MUST acquire or reuse a broker workspace derived from trusted task identity and pass only its opaque workspace and lease references to the matching worker. Model-facing Kanban arguments MUST NOT select a workspace ID, lease, host path, or provider.

#### Scenario: First task claim
- **GIVEN** a claimed QA Kanban task
- **WHEN** a registered Gondolin worker lane prepares the task
- **THEN** trusted infrastructure SHALL acquire or reuse a private workspace under the task-scoped broker authority
- **AND** SHALL pass the returned opaque workspace and lease IDs only to the matching worker process

#### Scenario: Model supplies workspace selection
- **WHEN** model-generated Kanban arguments contain a workspace ID, lease ID, provider, or host path
- **THEN** Hermes MUST ignore or reject those fields
- **AND** MUST NOT forward them to the broker control plane

### Requirement: Consistent worker filesystem binding

A Gondolin Kanban worker's terminal and environment-backed file surfaces MUST use the task workspace binding and guest path `/workspace`. Hermes MUST NOT present the gateway host worktree as if it were the sandbox workspace.

#### Scenario: Worker environment
- **GIVEN** a claimed task with a broker workspace binding
- **WHEN** Hermes launches its worker
- **THEN** the worker SHALL receive `HERMES_WORKSPACE_ID`, `HERMES_WORKSPACE_LEASE_ID`, and `HERMES_WORKSPACE_GUEST_PATH=/workspace`
- **AND** SHALL NOT receive the broker host path or the upstream Kanban scratch path through its environment or process cwd

#### Scenario: Terminal reuse
- **GIVEN** a worker that has written a file through Gondolin
- **WHEN** a later terminal or file tool call resolves the same task
- **THEN** it SHALL resolve the same workspace ID and active lease

### Requirement: Retry and completion lifecycle

Retries of one Kanban task MUST reuse its retained workspace. Completion or blocking MUST close the live VM while retaining the task-private workspace and lease for retry. Concurrent child tasks MUST NOT inherit one mutable workspace lease.

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
- **GIVEN** a task holding an active workspace lease and live VM
- **WHEN** the task reaches completion or blocking
- **THEN** trusted lifecycle code SHALL close its VM
- **AND** SHALL retain its workspace and lease for same-task retry or explicit later cleanup

### Requirement: Broker outage and in-process recovery

When the QA Gondolin backend is configured, transient broker liveness MUST NOT remove terminal or file schemas from the Hermes model tool catalogue. Every workspace-backed execution surface, including terminal, file tools, process control, close-terminal, and execute-code, MUST revalidate through the trusted workspace pre-tool gate. Broker recovery MUST NOT require a Hermes process restart.

#### Scenario: Conversation starts during broker outage
- **GIVEN** the QA Gondolin broker and its sockets are stopped
- **WHEN** Hermes creates a new conversation
- **THEN** workspace-backed tool schemas SHALL remain available to the conversation
- **AND** attempts to use them SHALL fail before execution with a structured workspace-unavailable reason
- **AND** Hermes SHALL NOT invoke a local, Docker, Podman, execute-code, process, or other fallback

#### Scenario: Broker recovers in process
- **GIVEN** a conversation whose workspace-backed tool call was blocked while the broker was unavailable
- **WHEN** the broker and its sockets become available again
- **THEN** the next workspace-backed tool call SHALL reacquire or revalidate its binding
- **AND** execution SHALL resume without restarting Hermes, toggling tools, or creating another conversation

### Requirement: Backend compatibility

The workspace integration MUST be gated to the Gondolin secure-terminal backend. Existing local, Podman, production, and non-sandbox worker workspace behavior MUST remain unchanged.

#### Scenario: Non-Gondolin worker
- **GIVEN** a task dispatched by a profile or lane not using Gondolin
- **WHEN** worker environment variables are prepared
- **THEN** Hermes SHALL retain its existing workspace behavior
- **AND** SHALL NOT call the Gondolin workspace control routes

## Mechanism

- `pkgs/by-name/hermes-agent-patched` provides a repository-owned `workspace-service` plugin with trusted workspace acquisition and lifecycle hooks over broker Unix sockets.
- The Hermes Kanban patch adds a generic `prepare_worker_environment` hook. In broker mode it injects opaque workspace and lease references, strips the upstream host workspace from the worker environment, and suppresses that host directory as worker cwd.
- Canonical environment-key derivation remains in the existing task-environment registry; individual terminal and file tool schemas cannot accept workspace identity.
- `modules/den/aspects/workloads/hermes/secure-terminal/default.nix` enables the integration only for the QA Gondolin profile and provides the existing read-only broker socket directory mount.
- No Kanban model tool gains workspace-management parameters. Cross-task filesystem handoff remains a separate capability.