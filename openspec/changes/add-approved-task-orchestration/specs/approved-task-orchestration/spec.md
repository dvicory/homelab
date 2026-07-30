## Purpose

Define how Hermes recommends solo or graph execution, obtains exact conversational approval, and creates bounded task graphs without giving task workers orchestration or external-effect authority.

## ADDED Requirements

### Requirement: Goals remain pre-task until approved

The live orchestrator MUST treat an unapproved user goal as conversation state rather than a Kanban task. It MUST NOT create runnable tasks, dependency edges, workspaces, or worker authority before the user approves an exact proposal.

#### Scenario: User submits a rough goal
- **WHEN** a user describes work without an approved execution proposal
- **THEN** the orchestrator SHALL clarify or propose execution in the originating conversation
- **AND** no Kanban task SHALL exist merely to hold the rough goal

#### Scenario: Existing task needs operator attention
- **WHEN** a running task enters operational `triage` because of repeated blockers or another escalation
- **THEN** it SHALL remain an operator-attention item
- **AND** it MUST NOT be automatically decomposed as rough intake

### Requirement: Strong solo execution is the default

The orchestrator MUST recommend one strongest-suitable worker for a coherent goal unless a graph has separable inputs, bounded outputs, low communication needs, independent verification, cheap synthesis, and material expected benefit after coordination and model cost.

#### Scenario: Coherent coding goal
- **WHEN** one `code` worker can implement and verify a Project change while preserving useful context
- **THEN** triage SHALL propose one task
- **AND** it MUST NOT create review personas or parallel subtasks merely because more workers are available

#### Scenario: Large but tightly coupled goal
- **WHEN** a goal is large but its steps share mutable state or require sequential observations
- **THEN** triage SHALL retain solo execution or ask to narrow the goal
- **AND** size alone MUST NOT justify a graph

#### Scenario: Independent evidence axes
- **WHEN** an investigation has independently searchable evidence axes and bounded cited outputs
- **THEN** triage MAY propose research fan-out followed by synthesis
- **AND** it SHALL state the expected benefit relative to one strong worker

### Requirement: Graph proposals are explicit and bounded

Every proposal MUST identify its mode, goal, acceptance criteria, tasks, registered lanes, Projects and immutable inputs where applicable, output contracts, dependency and input edges, synthesis responsibility, maximum concurrency, resource or cost ceiling, external effects, rationale, proposal identity, and canonical digest.

#### Scenario: Graph is proposed
- **WHEN** triage recommends multiple tasks
- **THEN** the originating conversation SHALL show every task boundary and edge before execution
- **AND** SHALL show why the graph is expected to outperform solo execution

#### Scenario: Proposal lacks acceptance criteria
- **WHEN** triage cannot state observable acceptance criteria or bounded outputs
- **THEN** it SHALL ask for clarification or recommend solo discovery
- **AND** it MUST NOT create speculative children

### Requirement: Approval binds the exact proposal

Runnable work MUST require an unexpired approval bound to the proposal digest, originating conversation, and user decision. Editing any task, edge, lane, Project, effect, ceiling, or acceptance criterion MUST create a new digest requiring a new approval.

#### Scenario: User approves current digest
- **WHEN** the user approves the exact active proposal in its originating conversation
- **THEN** trusted orchestration MAY materialize precisely that proposal

#### Scenario: User approves stale text
- **WHEN** an approval refers to a superseded, expired, unverifiable, or different-conversation proposal
- **THEN** materialization MUST fail without creating tasks
- **AND** the orchestrator SHALL render or request a fresh proposal

#### Scenario: User requests revision
- **WHEN** the user changes scope, tasks, lanes, edges, effects, or ceilings
- **THEN** the orchestrator SHALL issue a new proposal and digest
- **AND** prior approval MUST NOT authorize the revision

### Requirement: Approved graph creation is atomic and replay-safe

Trusted orchestration MUST validate the complete approved proposal against one active board, lane, Project, dependency, input-capability, ceiling, and catalogue revision before atomically creating tasks and edges. Identical replay MUST return the same graph; conflict or partial failure MUST create no partial runnable graph.

#### Scenario: Valid approved graph
- **WHEN** every proposed lane, Project, edge, and ceiling is valid under one active catalogue revision
- **THEN** the system SHALL create the complete graph as one operation
- **AND** SHALL return stable board-qualified task identities

#### Scenario: Catalogue changes before approval is applied
- **WHEN** a lane or Project revision no longer matches the approved proposal
- **THEN** graph creation MUST fail as a revision conflict
- **AND** no subset of tasks SHALL be created

#### Scenario: Materialization response is lost
- **WHEN** trusted orchestration retries the same approved digest after an ambiguous response
- **THEN** it SHALL return the originally created graph or resume the same operation
- **AND** it MUST NOT duplicate tasks

### Requirement: Leaf workers cannot expand or approve graphs

A task worker MUST NOT receive task-creation, graph-mutation, approval, publication, or operational-effect authority. It MAY complete, block, or return a structured follow-up request to the live orchestrator.

#### Scenario: Leaf discovers necessary follow-up
- **WHEN** a worker identifies additional work not present in its frozen task
- **THEN** it SHALL report the follow-up to the orchestrator
- **AND** the orchestrator MAY create it only under prior bounded approval or a newly approved proposal

#### Scenario: Leaf invokes graph creation indirectly
- **WHEN** a worker calls a stale, hidden, or indirect task-creation route
- **THEN** backend authorization MUST deny the operation independently of tool visibility

### Requirement: Triage and graph UX is gateway-neutral

Proposal rendering and digest-bound decisions MUST use the shared gateway conversation and approval contract. Platform adapters MUST NOT independently define lane selection, graph policy, digest semantics, or authorization.

#### Scenario: Proposal originates in a group
- **WHEN** a user requests work in a supported group conversation
- **THEN** the proposal and decision SHALL remain associated with that group
- **AND** approval MUST NOT be accepted from an unrelated DM

#### Scenario: Gateway lacks rich buttons
- **WHEN** a gateway supports text but not proposal widgets
- **THEN** the user SHALL be able to approve, revise, or choose solo through the shared textual contract

### Requirement: External effects are separate approved operations

Worker completion MUST NOT itself publish Git changes, restart or reload services, deploy or roll back, mutate a host, or send an incident notification. Each effect MUST be performed by a trusted typed adapter under approval binding the exact action, target, relevant revision, destination, expiry, and proposal or result identity.

#### Scenario: Operations diagnosis recommends restart
- **WHEN** `ops-observe` concludes that an approved service restart is appropriate
- **THEN** it SHALL return the diagnosis and exact proposed action
- **AND** it MUST NOT receive a general mutation shell or execute the restart itself

#### Scenario: Code worker changes a Project
- **WHEN** `code` completes with a candidate Project result
- **THEN** the canonical Project SHALL remain unchanged
- **AND** publication SHALL require a separate trusted operation bound to that immutable result and expected destination generation

#### Scenario: Notification is approved
- **WHEN** an exact incident notification is approved for the originating conversation
- **THEN** the trusted adapter MAY send that content only to the bound destination

### Requirement: Multi-task patterns are evaluated against solo

The system acceptance process MUST compare representative graph workflows with the strongest suitable single-worker baseline and record correctness, completeness, verification, source quality where applicable, wall time, model cost or usage, duplicated work, handoff loss, and integration conflicts.

#### Scenario: Graph provides no material benefit
- **WHEN** a graph pattern does not materially outperform its solo baseline after coordination cost
- **THEN** policy and guidance SHALL retain solo execution for that workload
- **AND** the graph MUST NOT be preserved merely because it exercises multi-task infrastructure

#### Scenario: Moderate or local leaf is proposed
- **WHEN** an operator considers a weaker model for a bounded leaf workload
- **THEN** it SHALL remain disabled from automatic selection until measured against the strong baseline
- **AND** its output SHALL require strong-model or deterministic verification
