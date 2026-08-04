## ADDED Requirements

### Requirement: Explicit immutable input binding
Trusted workspace activation MUST resolve every `inputs_from` edge to one exact ready same-board handoff, validate the selected lane's effective input ceilings, acquire durable retention references, and bind all prepared inputs atomically with the destination task-run workspace authority. Each input MUST appear read-only at `/workspace/inputs/<producer-task-id>` and MUST remain distinct from destination work and output.

#### Scenario: Destination with no filesystem inputs
- **WHEN** a runnable task has no `inputs_from` edges
- **THEN** `/workspace/inputs` SHALL be an empty read-only broker-managed plane

#### Scenario: Destination with multiple inputs
- **WHEN** a runnable task has multiple valid prepared input bindings
- **THEN** workspace activation SHALL expose all exact producer handoffs in separate task-ID namespaces
- **AND** execution MUST NOT begin with a partial input set

#### Scenario: Input binding conflict
- **WHEN** activation facts differ from the persisted destination input generation or prepared broker operation
- **THEN** activation MUST fail as a stable conflict
- **AND** it MUST NOT substitute newer producer output, a live workspace, an empty directory, or a local path

### Requirement: Input lifecycle is independent from destination output
Input mounts MUST remain immutable for the destination run and MUST NOT be captured as destination output automatically. Completion MUST continue to freeze only `/workspace/output`; a worker must copy or synthesize selected input data into its own output deliberately.

#### Scenario: Destination completes without copying input
- **WHEN** a destination reads an input but writes no corresponding file under `/workspace/output`
- **THEN** completion SHALL NOT include the input file in the destination handoff

#### Scenario: Destination copies transformed input
- **WHEN** a destination writes a transformed input-derived file under `/workspace/output`
- **THEN** completion MAY freeze that destination-owned file
- **AND** provenance SHALL continue to identify the immutable inputs bound to the destination run
