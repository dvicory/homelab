## ADDED Requirements

### Requirement: Approved orchestration owns model-created graph edges

Only the live orchestrator acting through a trusted, digest-approved graph materialization operation MAY create model-proposed `parents` and `inputs_from` relationships. The proposal MAY identify existing board-local producer task IDs, but MUST NOT contain producer runs, handoff IDs, manifests, workspace or lease IDs, source generations, providers, mount paths, permissions, or writable-input flags. Leaf task workers MUST NOT create or mutate input edges.

#### Scenario: Approved graph selects producer tasks
- **WHEN** trusted orchestration materializes an approved proposal containing same-board `inputs_from` edges
- **THEN** it SHALL persist only semantic task relationships
- **AND** trusted input resolution SHALL derive opaque producer and broker facts later

#### Scenario: Leaf attempts to add fan-out
- **WHEN** a running task worker attempts to create a child or add an `inputs_from` edge
- **THEN** the operation MUST be unavailable or denied
- **AND** the worker MAY return a follow-up request to the live orchestrator

#### Scenario: Proposal supplies broker infrastructure
- **WHEN** a proposed graph contains a handoff, producer run, manifest, workspace, lease, source generation, provider, mount path, permission, or writable-input request
- **THEN** trusted materialization MUST reject the proposal without creating a partial graph


### Requirement: Fan-out and fan-in originate from one approved graph

Orchestrator-created fan-out/fan-in MUST be validated and committed as part of one approved graph operation before any member task becomes runnable. An incomplete graph MUST NOT expose runnable roots that can finish without their approved synthesis or verification path being recorded.

#### Scenario: Research fan-out is approved
- **WHEN** a proposal contains independent research leaves and one synthesis destination
- **THEN** graph creation SHALL atomically persist every task and dependency/input edge
- **AND** the synthesis task SHALL be visible before any leaf is dispatched

#### Scenario: Graph creation partially fails
- **WHEN** any proposed lane, Project, edge, input capability, ceiling, or dependency is invalid
- **THEN** none of the proposed tasks SHALL become runnable
