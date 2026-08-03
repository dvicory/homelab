## ADDED Requirements

### Requirement: Instance-wide explicit worker-lane registry
The Hermes instance MUST expose one trusted registry of explicitly declared worker lanes. Every task executor MUST resolve through that registry, and discovering a Hermes profile MUST NOT make the profile independently assignable.

#### Scenario: Registered Hermes lane
- **WHEN** a ready task names an assignee registered as a Hermes worker lane
- **THEN** the dispatcher SHALL resolve that lane's declared Hermes runtime and optional backing profile
- **AND** it SHALL NOT infer runtime authority from the profile name alone

#### Scenario: Registered external lane
- **WHEN** a ready task names an assignee registered as an external worker lane
- **THEN** the dispatcher SHALL resolve the declared plugin runtime through the same lane contract used for Hermes workers

#### Scenario: Profile without lane declaration
- **WHEN** a task names a discoverable Hermes profile that has no explicit lane declaration
- **THEN** task creation or dispatch MUST reject the assignee with a stable unregistered-lane reason
- **AND** the dispatcher MUST NOT fall back to spawning that profile

### Requirement: Interactive orchestrator is not an implicit worker
The live interactive profile MUST remain distinct from task worker lanes. It MUST NOT become task-assignable unless an operator declares a separate lane that explicitly references its runtime configuration.

#### Scenario: Default profile is not registered
- **GIVEN** the interactive profile is named `default` and no `default` lane exists
- **WHEN** a task names `assignee=default`
- **THEN** task creation or dispatch MUST reject the task as targeting an unregistered lane

#### Scenario: Explicit lane reuses interactive profile baseline
- **GIVEN** a declared lane references the interactive profile as its configuration baseline
- **WHEN** the dispatcher starts a task for that lane
- **THEN** the worker SHALL receive worker role context and the lane's frozen configuration
- **AND** it MUST NOT receive live-orchestrator lifecycle authority

### Requirement: Lane-owned worker behavior
A worker lane MUST be able to declare its capability-based selection description, runtime, optional profile, model policy, reasoning effort, role/SOUL, model-visible tools and skills, durable-memory mode, workspace contract, broker policy worklane, approvals, execution limits, concurrency, immutable-input contract, output contract, and prohibited effects. Immutable operator and security policy MUST remain authoritative over lane prompt or tool configuration. A lane name MUST represent a materially distinct capability rather than a simulated job title.

#### Scenario: Hermes lane resolution
- **WHEN** trusted dispatch resolves a Hermes lane
- **THEN** it SHALL produce one worker configuration containing the lane's declared agent, memory, workspace, policy, approval, input, output, and execution settings

#### Scenario: Lane prompt attempts to broaden authority
- **WHEN** a lane SOUL or task body asks for a tool, workspace, credential, network grant, policy capability, child creation, or external effect outside the resolved backend ceiling
- **THEN** the request MUST remain unavailable or fail authorization

#### Scenario: Tool is hidden but backend route is attempted
- **WHEN** a worker invokes an unexposed backend operation through a stale or indirect client
- **THEN** the backend MUST enforce the frozen lane and task-run authority independently of model-visible tool filtering

#### Scenario: Decorative lane specialization
- **WHEN** two proposed lanes differ only by role prose while model, tools, credentials, data, workspace, evaluator, and policy are equal
- **THEN** configuration SHOULD consolidate them rather than imply a distinct capability

#### Scenario: Detached runtime cannot surface operator approval
- **GIVEN** a detached worker runtime whose noninteractive execution mode cannot route approval requests to the Hermes operator
- **WHEN** trusted configuration declares that runtime as a worker lane
- **THEN** configuration MUST require `approvalPolicy = "never"` and treat the frozen broker and runtime capability profile as the hard ceiling
- **AND** filesystem and network policy MUST be projected independently without silently dropping either field

### Requirement: Worker durable memory is explicit and off by default
Task worker lanes MUST default to no durable memory. A trusted lane declaration MAY select lane-scoped or shared-profile durable memory, while task/run transcript state MUST remain scoped to the task run.

#### Scenario: Lane omits memory mode
- **WHEN** a worker lane has no durable-memory declaration
- **THEN** its task workers MUST NOT read or write durable profile or lane memory

#### Scenario: Lane-scoped memory
- **WHEN** a lane explicitly selects lane-scoped durable memory
- **THEN** workers for that lane SHALL use the lane's trusted memory namespace
- **AND** another lane MUST NOT receive that namespace through task arguments

#### Scenario: Shared-profile memory
- **WHEN** a lane explicitly selects shared-profile durable memory
- **THEN** its workers MAY use the referenced profile's durable memory
- **AND** the configuration MUST NOT claim that the shared namespace is tenant isolation

### Requirement: Board-scoped lane and Project participation
Worker-lane definitions MUST be global within one Hermes instance. A board MUST be able to permit a subset of declared lanes and managed Projects and MAY declare one default Project. Board configuration MUST NOT redefine a lane's runtime, provider, tool surface, or security ceiling.

#### Scenario: Board permits lane and Project
- **WHEN** a task selects a lane and Project permitted by its board
- **THEN** trusted resolution SHALL continue with lane and Project authorization

#### Scenario: Board denies lane
- **WHEN** a task selects a globally registered lane absent from the board's allowed lanes
- **THEN** task creation or dispatch MUST reject the task before claim or spawn

#### Scenario: Same lane on two boards
- **WHEN** two boards permit the same global lane
- **THEN** both boards SHALL resolve the same lane definition and revision

### Requirement: Nix-authoritative provider-neutral Project catalogue
Managed logical Projects MUST have instance-wide stable identity, a trusted typed `SourceSpec`, and one per-lane access map declared by Nix. Project identity and access MUST NOT require Git-specific fields; adapter-specific provenance belongs to source generations and results. Runtime workflow state MUST NOT add a managed source identity or broaden Project lane access beyond the active Nix catalogue.

#### Scenario: Project authorizes lane
- **GIVEN** a Project's `laneAccess` grants a lane `read-only`
- **WHEN** that lane resolves a task for the Project
- **THEN** effective direct Project permission MUST be no greater than `read-only`

#### Scenario: Project omits lane
- **WHEN** a task selects a Project whose `laneAccess` has no entry for the selected lane
- **THEN** task creation or dispatch MUST reject direct Project access

#### Scenario: Runtime attempts to broaden Project access
- **WHEN** runtime state requests a source or permission not present in the active Nix Project declaration
- **THEN** trusted resolution MUST reject it without mutating the Nix-authoritative catalogue

#### Scenario: Source kind is not yet implemented
- **WHEN** a trusted Project declares a valid source kind unsupported by the selected lane provider
- **THEN** resolution MUST fail with a stable unsupported-source reason
- **AND** it MUST NOT reinterpret the source as Git, a local path, or scratch work

### Requirement: Workspace provider belongs to the lane
A lane MUST select deterministic scratch and Project workspace providers for the modes it supports. A Project MUST NOT select or allowlist providers. Trusted resolution MUST verify that the lane's provider supports the Project source kind and effective permission.

#### Scenario: Supported Project source
- **WHEN** the selected lane's Project provider supports the Project's source kind and effective permission
- **THEN** trusted resolution SHALL bind that provider in the task-run worker specification

#### Scenario: Unsupported Project source
- **WHEN** the lane's Project provider does not support the Project source kind or effective permission
- **THEN** resolution MUST fail before claim or spawn
- **AND** it MUST NOT fall back to a host path, local execution, another provider, or another lane

### Requirement: Narrow model-facing task routing
Ordinary model-facing task creation MUST retain `assignee` as the worker-lane selector and MUST accept only registered lane names. It MUST NOT expose profile, workspace kind or path, provider, permission, policy worklane, source URL, host path, workspace or lease identity, or environment identity as task-selectable infrastructure.

#### Scenario: Model creates ordinary lane task
- **WHEN** the model creates a task with an allowed `assignee`, optional logical Project, dependency relationships, and bounded task intent
- **THEN** trusted infrastructure SHALL resolve all runtime and workspace mechanisms

#### Scenario: Model supplies infrastructure field
- **WHEN** ordinary task arguments contain a profile, workspace path, provider, permission, policy worklane, source URL, host path, workspace ID, lease ID, or environment key
- **THEN** the tool MUST reject or omit that field from the model-facing schema

### Requirement: Immutable task-run worker specification
Trusted dispatch MUST resolve and persist one complete worker specification before a worker is spawned. The specification MUST bind the board-qualified task and run, lane revision, optional Project and source generation, runtime/profile, provider, effective permission, workspace and lease, policy identity, agent configuration revision, and memory namespace.

#### Scenario: Successful resolution
- **WHEN** board policy, lane capability, Project access, provider compatibility, and bounded task intent are compatible
- **THEN** dispatch SHALL persist one complete worker specification before spawn
- **AND** every worker surface SHALL consume that specification rather than independently recomputing defaults

#### Scenario: Incompatible resolution
- **WHEN** any required board, lane, Project, provider, permission, runtime, or policy fact is missing or incompatible
- **THEN** resolution MUST return a stable rejection before claim or spawn
- **AND** it MUST NOT persist a partial binding

#### Scenario: Retry after configuration change
- **WHEN** a task retries after its lane or Project declaration changes
- **THEN** the retry SHALL create a new run binding using one coherent active revision
- **AND** operations carrying the prior run or workspace generation MUST remain fenced from the new run

### Requirement: One-workspace invariant
The worker process, terminal, execute-code, file, search, patch, process, and completion surfaces MUST resolve the same logical task-run workspace and effective permission. A successful dispatch MUST NOT combine a host process CWD with an unrelated broker workspace.

#### Scenario: Hermes project worker
- **WHEN** a Hermes lane starts a Project task
- **THEN** the worker process context and every filesystem-bearing Hermes tool SHALL refer to the same broker Project workspace binding

#### Scenario: External host-worktree worker
- **WHEN** an external lane starts a host-worktree task
- **THEN** the external process and all tools exposed inside that runtime SHALL refer to the same resolved host worktree
- **AND** Hermes broker tools unavailable to that external runtime need not be exposed

### Requirement: Coordination authority is separate from lane identity
The live interactive orchestrator MAY receive trusted proposal and graph-materialization authority from a separate orchestration contract. Task worker lanes MUST remain leaf executors by default, even when they reuse the interactive profile baseline. Ordinary task arguments MUST NOT elevate a lane into a coordinator.

#### Scenario: Leaf worker requests another task
- **WHEN** a running task worker identifies follow-up work
- **THEN** it MAY return a structured request to the live orchestrator
- **AND** it MUST NOT create or mutate tasks directly

#### Scenario: Synthesis uses ordinary capability
- **WHEN** a destination task synthesizes explicit immutable inputs without needing different execution authority
- **THEN** it SHALL use the ordinary suitable lane rather than require a dedicated persona lane

### Requirement: Lanes are capability boundaries, not information-flow tenants
The system MUST describe lanes as cooperating roles within one Hermes instance. Project lane access MUST govern direct source authority, but task bodies, comments, summaries, and explicitly authorized handoffs MAY transfer derived information across lanes on the same board.

#### Scenario: Cross-lane summary
- **WHEN** a Project-authorized worker records a summary consumed by another lane on the same board
- **THEN** the summary MAY cross the lane boundary
- **AND** the receiving lane MUST NOT thereby gain direct Project source authority

#### Scenario: Mutually distrustful workloads
- **WHEN** task configuration requests noninterference between workloads inside one Hermes instance
- **THEN** trusted resolution MUST reject that unsupported claim
- **AND** it MUST NOT represent boards, profiles, lane memory namespaces, or tool filtering as tenant isolation
