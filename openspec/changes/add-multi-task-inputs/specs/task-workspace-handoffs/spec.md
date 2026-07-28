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

