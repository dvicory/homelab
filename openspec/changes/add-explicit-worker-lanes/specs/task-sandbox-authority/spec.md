## MODIFIED Requirements

### Requirement: Executor routing is not authority
A registered worker lane MAY contribute an operator-configured runtime, workspace provider, permission ceiling, policy worklane, and grant scope, but a model-selected `assignee` MUST NOT itself create authority beyond the board, lane, Project, and installed broker policy. A Hermes profile MUST NOT be an executor unless an explicit registered lane references it. Before worker execution, trusted dispatch MUST register the effective immutable task-run binding, and every environment-backed surface MUST resolve that binding.

#### Scenario: Unknown worker lane
- **GIVEN** a model creates a task with an unknown or unregistered assignee
- **WHEN** task creation or the dispatcher evaluates the task
- **THEN** it MUST NOT create a sandbox authority binding or privileged environment for that assignee
- **AND** it MUST reject the task with a stable unregistered-lane reason rather than falling back to a profile

#### Scenario: Registered lane default
- **GIVEN** a registered worker lane with an operator-configured workspace and authority ceiling
- **WHEN** trusted dispatch resolves and claims a compatible task for that lane
- **THEN** it SHALL register the exact board-qualified task/run, lane revision, optional Project/source generation, workspace/lease, and policy identity before worker execution
- **AND** subsequent worker environment calls MUST resolve the registered task-run binding rather than a process-global variable or profile default

#### Scenario: Model-selected lane exceeds Project access
- **GIVEN** a registered lane that is not authorized by the selected Project's Nix `laneAccess`
- **WHEN** a task selects that lane and Project
- **THEN** trusted resolution MUST reject the combination before claim or spawn
- **AND** it MUST NOT register partial sandbox authority
