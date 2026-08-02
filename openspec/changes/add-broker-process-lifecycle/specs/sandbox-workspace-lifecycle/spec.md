## ADDED Requirements

### Requirement: Workspace lifecycle drains broker processes

Every broker-owned background process MUST remain attached to its environment generation while it can mutate workspace storage. VM close, generation replacement, branch preparation, lease release, and workspace deletion MUST cancel and drain attached processes before copying, releasing, freezing, or deleting that storage. No process bound to an old generation or released lease may execute against a recreated environment.

#### Scenario: Workspace deletion has a live process

- **WHEN** deletion is requested while an attached process can mutate the workspace
- **THEN** deletion SHALL first cancel and drain the process or fail within a trusted bound
- **AND** the workspace SHALL not be removed while mutation remains possible

#### Scenario: Branch closes the source generation

- **WHEN** branch preparation closes the parent generation before copying its workspace
- **THEN** every attached parent process SHALL be cancelled and drained before the copy
- **AND** no parent process SHALL write during or after branch snapshot creation

### Requirement: Broker restart creates no process continuity

Background process identity and terminal retention are broker-lifetime resources. Broker restart MUST close owned VMs and MUST NOT reattach an old process ID to a recreated environment or workspace. A caller presenting an old process ID after restart MUST receive loss/not-found semantics without a fabricated exit result.

#### Scenario: Broker restarts during execution

- **WHEN** a running process loses its owning broker instance
- **THEN** the replacement broker SHALL not adopt or recreate it
- **AND** the associated environment generation SHALL remain stale
