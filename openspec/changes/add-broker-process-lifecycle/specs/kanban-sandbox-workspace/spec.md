## ADDED Requirements

### Requirement: Kanban process lifecycle uses the frozen workspace binding

Every Gondolin background spawn, status, output, and cancellation operation performed by a Kanban worker MUST use the same frozen task-run activation, workspace, lease, generation, effective permission, and policy as terminal, file, patch, and completion surfaces. Trusted Hermes state MUST supply that binding; model-facing process arguments MUST NOT select or override it.

#### Scenario: Process writes task output

- **WHEN** an authorized workspace-write task starts a background process in `/workspace/work` that writes `/workspace/output/result.txt`
- **THEN** the process SHALL use the task's existing workspace and lease
- **AND** subsequent permitted file and completion surfaces SHALL observe the same bytes

#### Scenario: Read-only task starts a writer

- **WHEN** a read-only task attempts to start a process that writes the work plane
- **THEN** the write SHALL fail under the same effective permission as foreground execution
- **AND** starting it asynchronously SHALL grant no additional filesystem authority

### Requirement: Kanban terminal transitions reconcile owned processes

Successful completion, block, timeout, reclaim, and deliberate retry MUST apply an explicit bounded disposition to every process owned by the affected task run before consuming its activation, releasing its writer lease, freezing output, or deleting mutable storage. A stale run MUST NOT read, cancel, or recreate a prior run's process.

#### Scenario: Completion races a background writer

- **WHEN** completion begins while a task-owned process can still mutate `/workspace/output`
- **THEN** completion SHALL fail, wait, or cancel and drain according to configured policy
- **AND** SHALL freeze output only after no owned process can mutate it

#### Scenario: Task retry follows a lost process

- **WHEN** trusted dispatch activates a fresh run after an earlier process became lost
- **THEN** the new run SHALL receive distinct process authority
- **AND** SHALL not adopt, poll, or cancel the old run's process ID
