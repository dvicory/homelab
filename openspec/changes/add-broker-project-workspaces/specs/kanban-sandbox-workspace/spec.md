## MODIFIED Requirements

### Requirement: Trusted Kanban workspace acquisition
When the Gondolin backend is selected, trusted Kanban claim/dispatch code MUST acquire or reuse a broker workspace derived from the frozen task-run binding and pass only opaque workspace and lease references to the matching worker. Every workspace MUST expose mutable work at `/workspace/work`, broker-managed read-only inputs at `/workspace/inputs`, and task-owned output at `/workspace/output`. Only `/workspace/output` is the durable cross-task human/data output subtree; work paths outside it MUST NOT be captured as ordinary artifacts. A Project workspace MUST additionally bind its trusted logical Project and immutable source generation. Model-facing Kanban arguments MUST NOT select a workspace ID, lease ID, handoff ID, Project source, host path, provider, permission, mount, or output root.

#### Scenario: First task claim
- **GIVEN** a claimed Kanban task with a complete resolved worker specification
- **WHEN** a registered Gondolin worker lane prepares the task
- **THEN** trusted infrastructure SHALL acquire or reuse a private workspace under task-run-scoped broker authority
- **AND** SHALL pass returned opaque workspace and lease IDs only to the matching worker process
- **AND** SHALL expose `/workspace/work`, `/workspace/inputs`, and `/workspace/output` according to the binding

#### Scenario: Project task claim
- **GIVEN** a claimed task whose resolved lane selects the broker Project provider
- **WHEN** trusted dispatch prepares the task
- **THEN** it SHALL materialize the bound Project source generation at `/workspace/work` before execution
- **AND** it SHALL NOT mount or expose the gateway's canonical checkout or linked worktree

#### Scenario: Model supplies workspace or output selection
- **WHEN** model-generated Kanban arguments contain a workspace ID, lease ID, handoff ID, Project source, provider, permission, mount, host path, or output-root selector
- **THEN** Hermes MUST ignore or reject those fields
- **AND** MUST NOT forward them to the broker control plane

### Requirement: Consistent worker filesystem binding
A Gondolin Kanban worker's process context and environment-backed terminal, execute-code, file, search, patch, process, and completion surfaces MUST use its frozen task-run workspace binding and canonical logical root `/workspace`. The worker CWD MUST be `/workspace/work`. Hermes MAY bridge an upstream per-session CWD through `session_context`/`runtime_cwd`, but per-session CWD is a logical runtime-directory facility, not workspace authority or host-path disclosure. For a Gondolin Kanban worker, trusted dispatch MUST strip upstream host scratch and host process CWD and expose only the three broker workspace planes. Hermes MUST NOT present a gateway host worktree as the sandbox workspace.

#### Scenario: Worker environment
- **GIVEN** a claimed task with a broker workspace binding
- **WHEN** Hermes launches its worker
- **THEN** the worker SHALL receive opaque workspace and lease references through trusted process context
- **AND** SHALL use `/workspace/work` as CWD, `/workspace/inputs` for broker-managed read-only inputs, and `/workspace/output` for durable output
- **AND** SHALL NOT receive the broker host path or upstream Kanban scratch path through its environment or process CWD

#### Scenario: Cross-surface reuse
- **GIVEN** a worker that has written a file through one permitted Gondolin surface
- **WHEN** a later terminal, execute-code, file, search, patch, or process call resolves the same task run
- **THEN** it SHALL resolve the same workspace, active lease, plane, and effective permission
- **AND** completion SHALL capture only `/workspace/output` as ordinary artifact data

#### Scenario: No legacy layout
- **WHEN** a newly cut-over worker expects mutable task work directly at `/workspace`
- **THEN** Hermes and the broker MUST NOT provide a compatibility alias or second mutable view
- **AND** guidance SHALL direct the worker to `/workspace/work`
