## ADDED Requirements

### Requirement: Process operations revalidate broker-owned authority

Background spawn, poll, and cancellation MUST validate the broker-owned environment binding, active task-run activation when present, workspace lease, VM generation, authority class, and policy digest. The execution listener MAY accept only opaque environment and process references supplied by trusted Hermes state; it MUST NOT accept caller-selected lane, permission, network class, workspace, lease, generation, capability set, authority class, or policy.

#### Scenario: Policy changes after process spawn

- **WHEN** a process operation uses a binding whose policy digest is no longer active
- **THEN** the broker SHALL deny it as stale authority
- **AND** SHALL not route it through the replacement generation

#### Scenario: Process ID crosses task runs

- **WHEN** a retained process ID is presented under a different run activation
- **THEN** the broker SHALL deny poll and cancellation without disclosing process data

### Requirement: In-memory process limits are trusted admission policy

The broker MUST enforce configured concurrent-process, command-duration, retained-output, poll-response, and terminal-TTL limits. Model input MUST NOT increase those limits. Exhaustion MUST fail before spawning an untracked process. Expiry MAY delete an exited or cancelled in-memory record but MUST NOT terminate an unrelated process.

#### Scenario: Concurrent process ceiling is reached

- **WHEN** an authorized environment has reached its concurrent-process ceiling
- **THEN** an additional spawn SHALL fail before Gondolin execution starts
- **AND** the broker SHALL retain ownership of every admitted process
