## ADDED Requirements

### Requirement: Lane catalogue is capability-described

A worker lane MUST declare a capability-based selection description, runtime, optional profile, model policy, reasoning effort, role/SOUL, model-visible tools and skills, durable-memory mode, workspace contract, broker policy worklane, approvals, execution limits, concurrency, input contract, output contract, and prohibited external effects. Immutable operator and security policy MUST remain authoritative over lane prompt or tool configuration. Lane names and descriptions MUST represent materially different capabilities rather than simulated team personas.

#### Scenario: Lane selection is described
- **WHEN** the orchestrator considers a registered lane
- **THEN** its catalogue entry SHALL state suitable goals, required inputs, produced outputs, capability ceiling, and prohibited effects
- **AND** the orchestrator MUST NOT infer capability from a persona title

#### Scenario: Two lanes differ only in role prose
- **WHEN** two proposed lanes have the same model, tools, credentials, data access, workspace, evaluator, and policy
- **THEN** configuration SHOULD reject or consolidate them
- **AND** decorative role specialization MUST NOT expand the initial catalogue

### Requirement: Live orchestrator owns coordination authority

The live interactive profile MUST remain a control-plane orchestrator rather than a task worker lane. It MAY clarify goals, produce solo or graph proposals, receive digest-bound approval, and invoke trusted atomic graph materialization. It MUST NOT execute an approved task implicitly or become task-assignable unless an operator separately declares a worker lane for that runtime configuration.

#### Scenario: User goal arrives in conversation
- **WHEN** the live orchestrator receives a new goal
- **THEN** it MAY recommend solo or graph execution before any task exists
- **AND** approved execution SHALL target registered worker lanes rather than the interactive profile

#### Scenario: Leaf worker is running
- **WHEN** a dispatcher-spawned worker resolves its lane
- **THEN** it MUST NOT receive the live orchestrator's proposal, approval, task-creation, or graph-mutation authority


### Requirement: Initial lane catalogue is small and independently useful

The initial managed catalogue MUST provide `general`, `code`, `review`, and `ops-observe` semantics. Each lane MUST support useful solo execution. A generic weak-model or local-model lane MUST NOT be automatically registered solely to reduce per-token cost.

#### Scenario: General analytical goal
- **WHEN** a coherent non-operational goal needs planning, investigation, public research, or synthesis without direct Project mutation
- **THEN** the orchestrator SHALL prefer `general`

#### Scenario: Project implementation
- **WHEN** a goal requires changing and verifying one trusted Project
- **THEN** the orchestrator SHALL select `code` with a private writable Project workspace
- **AND** completion MUST produce a candidate result without publication

#### Scenario: Independent Project review
- **WHEN** a fresh worker must inspect a Project generation or candidate result without changing it
- **THEN** the orchestrator SHALL select `review` with read-only Project access and writable bounded output

#### Scenario: Homelab diagnosis
- **WHEN** a goal needs host or service diagnosis
- **THEN** the orchestrator SHALL select `ops-observe` only if the required typed read-only observations are available
- **AND** missing adapters MUST NOT be replaced with arbitrary SSH authority

### Requirement: Strongest-suitable model is the initial default

Triage, synthesis, `general`, `code`, `review`, and `ops-observe` MUST initially use the strongest suitable operator-configured model. Exact provider and model names MUST remain configuration rather than lane semantics.

#### Scenario: Model provider changes
- **WHEN** the operator replaces the strongest configured model provider
- **THEN** lane purpose and authorization SHALL remain unchanged
- **AND** policy SHALL not require renaming semantic lanes

#### Scenario: Weaker leaf model is available
- **WHEN** a cheaper model exists but has not passed a bounded workload evaluation
- **THEN** automatic triage MUST NOT route work to it
