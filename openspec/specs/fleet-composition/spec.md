# fleet-composition Specification

## Purpose
Define how fleet-specific facts, reusable configuration behavior, and environment context compose into managed machine configurations without making current host inventory or Den implementation details part of the contract.

## Requirements

### Requirement: Fleet facts and reusable behavior have distinct roles

Managed machine, environment, user, group, and other fleet-specific facts SHALL be represented as entity data. Reusable system behavior SHALL be represented as composable configuration behavior rather than copied into each entity that uses it.

A reusable behavior component MAY consume entity facts, but SHALL NOT become the owner of those facts merely because it consumes them.

#### Scenario: Reusable behavior is shared by different hosts
- **WHEN** two hosts use the same reusable behavior with different host-specific facts
- **THEN** each host resolves the behavior using its own facts without duplicating the reusable behavior definition

#### Scenario: A host-specific fact changes
- **WHEN** a fact belonging to one host changes
- **THEN** the fact can be changed at that host's entity boundary without redefining unrelated reusable behavior

### Requirement: Environments provide shared context without lifecycle coupling

A managed machine that participates in fleet resolution SHALL have an explicit environment context. An environment MAY provide shared contextual data and policy gates to its members.

Environment membership SHALL NOT by itself imply that member machines share a deployment, restart, replacement, or failure lifecycle.

#### Scenario: Machines share an environment
- **WHEN** two machines belong to the same environment
- **THEN** they may inherit the same environment context while remaining independently manageable machines

### Requirement: Managed machine configuration is independently evaluable

Each managed machine configuration SHALL be derivable from repository state and its resolved fleet composition without requiring unrelated managed machines or services to be running.

Cross-machine relationships MAY contribute declarative data, but runtime reachability of another machine SHALL NOT be a prerequisite for evaluating a machine's desired configuration.

#### Scenario: Another machine is unavailable
- **WHEN** one managed machine is offline or unreachable
- **THEN** evaluation of an unrelated managed machine's desired configuration remains possible from repository state
