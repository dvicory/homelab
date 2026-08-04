## ADDED Requirements

### Requirement: Reusable frozen output source authority
A ready frozen task output MUST be reusable by zero or more explicit same-board `inputs_from` edges. Kanban MUST validate the destination edge, exact producer completion, lane input capability, board identity, limits, and active policy before trusted broker preparation. Each destination MUST receive only an immutable read-only input binding and its own independent writable work/output workspace.

#### Scenario: Explicit authorized input
- **GIVEN** a same-board destination declares a producer in `inputs_from` and the producer has one ready handoff
- **WHEN** trusted dispatch resolves the destination input generation
- **THEN** it SHALL bind the exact producer task/run and handoff through a durable preparation
- **AND** destination mutation SHALL NOT change the producer handoff or any other destination

#### Scenario: Edge or policy changes before binding
- **GIVEN** an input preparation was requested but the task edge, board, producer completion, lane capability, limit, or policy changed
- **WHEN** Kanban revalidates immediately before broker preparation
- **THEN** it MUST reject the changed request
- **AND** the destination MUST remain non-runnable without an empty substitute or live-producer access

#### Scenario: Cross-lane destination
- **GIVEN** producer and destination use different registered lanes on the same board
- **WHEN** destination lane policy permits the resolved immutable inputs
- **THEN** the destination MAY receive the producer handoff read-only
- **AND** it MUST NOT receive the producer's workspace, credentials, or direct Project authority

### Requirement: Archive-gated handoff reclaim
A ready frozen task output's bytes SHALL be deleted only when the producer task has been archived and the archive has been pushed to the broker through an idempotent mark-reclaimable operation, and no acquired input references exist for that handoff. The system MUST NOT delete ready handoff bytes on any timer, TTL, consumption-idleness window, or background sweep.

#### Scenario: Unreferenced archived producer
- **GIVEN** a producer task is archived and its handoff has no acquired references
- **WHEN** mark-reclaimable is pushed for that handoff
- **THEN** the broker SHALL mark it reclaimable and delete its bytes synchronously

#### Scenario: Referenced archived producer
- **GIVEN** a producer task is archived and its handoff still has acquired references
- **WHEN** mark-reclaimable is pushed
- **THEN** the broker SHALL mark it reclaimable and retain the bytes
- **AND** it SHALL delete the bytes synchronously when the last reference is released

#### Scenario: Mark replay
- **WHEN** mark-reclaimable is replayed for an already-reclaimable, unknown, or non-ready handoff
- **THEN** the operation SHALL succeed idempotently and report each handoff as deleted, retained, or skipped

### Requirement: Input reference release on terminal acts
The broker SHALL release a destination run's acquired input references when that run's finalization succeeds, and SHALL release every preparation of a destination task on an idempotent release operation. Reference release MUST attempt synchronous deletion of any reclaimable handoff that becomes unreferenced.

#### Scenario: Destination completes
- **WHEN** a destination task-run's handoff finalization succeeds
- **THEN** the broker SHALL release that run's input references
- **AND** producer handoffs that are reclaimable and now unreferenced SHALL be deleted

#### Scenario: Destination archived
- **WHEN** the release operation is invoked for an archived destination task
- **THEN** all of its preparations' references SHALL be released idempotently
- **AND** retry of the release SHALL report success without changing state

#### Scenario: Failed destination keeps inputs
- **WHEN** a destination run fails and the task is blocked
- **THEN** its input references SHALL remain acquired
- **AND** a later retry SHALL observe bit-identical inputs

