## ADDED Requirements

### Requirement: Explicit filesystem input edges
Kanban MUST represent ordering-only `parents` separately from filesystem-bearing `inputs_from`. Every `inputs_from` edge MUST imply readiness gating, and a producer MUST NOT need to appear in both fields to supply files.

#### Scenario: Ordering-only parent
- **WHEN** a task declares a producer only in `parents`
- **THEN** the destination SHALL wait for the producer and receive existing summary/metadata context
- **AND** it MUST NOT mount the producer's files

#### Scenario: Filesystem input
- **WHEN** a task declares a producer in `inputs_from`
- **THEN** the destination SHALL wait for the producer and resolve its frozen output as an input

#### Scenario: Same producer in both fields
- **WHEN** task creation names one producer in both `parents` and `inputs_from`
- **THEN** the tool MUST reject the duplicate or normalize it to the single stronger input edge
- **AND** persisted readiness MUST have one unambiguous relationship

### Requirement: Model selects tasks, not infrastructure
Ordinary task creation MAY select board-local producer task IDs through `inputs_from` but MUST NOT accept producer runs, handoff IDs, manifests, workspace or lease IDs, source generations, providers, mount paths, permissions, or writable-input flags.

#### Scenario: Valid task input selection
- **WHEN** the model selects an existing task on the same board through `inputs_from`
- **THEN** trusted resolution SHALL derive all opaque producer and broker facts later

#### Scenario: Model supplies handoff or mount
- **WHEN** ordinary task arguments contain a handoff, producer run, manifest, workspace, lease, source generation, provider, mount path, permission, or writable-input request
- **THEN** the model-facing tool MUST reject or omit those fields

### Requirement: Exact frozen producer binding
Before a destination first runs, trusted resolution MUST bind every input edge to one exact ready producer task/run and frozen handoff. Destination retries MUST retain that binding. A completed producer is terminal under the supported lifecycle; if a future trusted re-completion capability permits newer output, existing destinations MUST retain their original pins unless an explicit trusted operation replaces them.

#### Scenario: Producer output becomes ready
- **GIVEN** an input producer is `done` with one ready frozen handoff
- **WHEN** the destination input generation is resolved
- **THEN** it SHALL bind the exact producer task/run, lane, optional Project/source generation, handoff, and output manifest

#### Scenario: Future newer completion exists
- **WHEN** a trusted re-completion capability creates a newer producer completion after a destination input generation was frozen
- **THEN** the destination SHALL retain its original producer handoff
- **AND** using the newer output MUST require an explicit trusted act; it MUST NOT happen silently

#### Scenario: Destination retry
- **WHEN** a destination retries
- **THEN** it SHALL reuse the same immutable input binding set under a fresh destination run

### Requirement: Same-board fan-in and fan-out
The system MUST permit a destination to bind zero or more completed producers on the same board, subject to lane and broker limits. Multiple destinations MAY reference the same immutable producer handoff without receiving a shared writable workspace.

#### Scenario: Fan-in
- **WHEN** a destination declares three valid same-board producers in `inputs_from`
- **THEN** all three exact frozen outputs SHALL be available as separate read-only inputs in one destination run

#### Scenario: Fan-out
- **WHEN** three destinations select one producer output
- **THEN** each destination SHALL receive an immutable view of the same frozen handoff
- **AND** no destination mutation SHALL alter the producer or another destination

#### Scenario: Cross-board producer
- **WHEN** a destination selects a producer from another board or instance
- **THEN** task creation or input resolution MUST reject the edge
- **AND** it MUST NOT perform an implicit export or import

### Requirement: Declared inputs survive until explicit retirement
Kanban MUST guarantee that a producer's frozen output remains available to every live or future `inputs_from` consumer until a human explicitly retires the producer. Archiving a producer that still has live input-consumers MUST be refused, and creating an `inputs_from` edge naming an archived producer MUST be rejected. Both checks SHALL be kanban-local and MUST NOT require broker queries.

#### Scenario: Archive refused with live consumers
- **GIVEN** a producer has a ready handoff and a destination with an `inputs_from` edge to it is not `done` or `archived`
- **WHEN** an operator attempts to archive the producer
- **THEN** the archive SHALL be refused with the blocking destination identifiers
- **AND** the producer, its handoff, and the edge SHALL remain unchanged

#### Scenario: Archive allowed once consumers are terminal
- **GIVEN** every input-consumer of a producer is `done` or `archived`
- **WHEN** the operator archives the producer
- **THEN** the archive SHALL succeed and the broker SHALL be notified so the producer's handoff becomes reclaimable

#### Scenario: Edge naming archived producer
- **WHEN** task creation names an archived task in `inputs_from`
- **THEN** creation SHALL be rejected with a stable reason identifying the archived producer

#### Scenario: Broker unreachable during archive
- **GIVEN** the broker cannot be reached when a producer or destination is archived
- **WHEN** the archive succeeds kanban-side
- **THEN** the missed release and mark-reclaimable pushes SHALL be retried from durable kanban records at the next trusted workspace-service initialization

### Requirement: Namespaced read-only input mounts
Each bound producer output MUST appear as a distinct read-only subtree at `/workspace/inputs/<producer-task-id>`. The system MUST NOT overlay, merge, rename, or copy producer files into another input, the destination work plane, or the destination output plane automatically.

#### Scenario: Colliding producer filenames
- **GIVEN** two producer outputs each contain `report.txt`
- **WHEN** both are mounted for one destination
- **THEN** each file SHALL remain under its producer task ID namespace
- **AND** neither file SHALL shadow or overwrite the other

#### Scenario: Attempted input mutation
- **WHEN** terminal, file, patch, process, symlink, or indirect operations attempt to mutate an input subtree
- **THEN** the broker MUST reject the mutation
- **AND** the frozen producer handoff SHALL remain unchanged

#### Scenario: Worker copies an input deliberately
- **WHEN** a writable destination copies an input file into its own work or output plane
- **THEN** the copy SHALL become destination-owned mutable data
- **AND** the source input SHALL remain immutable

### Requirement: Input provenance does not grant Project authority
Every input binding MUST retain producer task/run, lane, optional Project/source generation, handoff, and manifest provenance. Receiving that input MUST NOT grant direct access to the producer Project, repository workspace, credentials, or publication authority.

#### Scenario: Cross-lane Project-derived report
- **GIVEN** a Project-authorized lane produces a report and a scratch lane consumes it on the same board
- **WHEN** the scratch destination starts
- **THEN** it MAY read the frozen report input
- **AND** it MUST NOT thereby materialize the producer Project or receive its direct source permission

### Requirement: Input readiness fails closed
A task MUST remain non-runnable until every ordering and input dependency satisfies readiness. Every input producer MUST be `done` with exactly one ready handoff, including a valid intentionally empty handoff. Missing, blocked, failed, reclaimed, ambiguous, expired, quarantined, or publication-failed output MUST NOT be omitted or substituted.

#### Scenario: Producer not ready
- **WHEN** any selected input producer lacks one ready handoff
- **THEN** the destination SHALL remain non-runnable with a stable input reason
- **AND** dispatch MUST NOT mount a live workspace, create an empty substitute, redispatch silently, or fall back to prose

#### Scenario: Intentionally empty producer output
- **WHEN** a producer completed with one ready empty handoff
- **THEN** the destination MAY run with an empty read-only producer directory

### Requirement: Lane and broker input ceilings
Trusted resolution MUST enforce the selected lane's input support and the effective maximum input count, aggregate logical bytes, entries, path bytes, per-input limits, preparation deadline, and retained-storage policy before destination execution.

#### Scenario: Lane supports no inputs
- **WHEN** a task with `inputs_from` selects a lane whose input capability is disabled
- **THEN** task creation or dispatch MUST reject the combination before workspace activation

#### Scenario: Aggregate limit exceeded
- **WHEN** the frozen producer manifests exceed any effective input ceiling
- **THEN** preparation MUST fail without mounting a subset or truncating entries

### Requirement: Transactional input preparation and replay
The broker MUST durably prepare the exact ordered input-binding set, validate ready handoffs and limits, acquire retention references, and bind the prepared inputs atomically with the destination task-run workspace authority. Identical replay MUST return or resume the same preparation; any changed bound fact MUST fail as a conflict.

#### Scenario: Response loss during preparation
- **WHEN** the caller retries the same preparation after losing a response
- **THEN** the broker SHALL resume or return the same durable operation and prepared inputs
- **AND** it MUST NOT acquire a second independent binding set

#### Scenario: Changed replay fact
- **WHEN** replay changes a producer, handoff, manifest, destination generation, lane, board, limit, or policy digest
- **THEN** the broker MUST reject the request as an idempotency conflict
- **AND** it MUST preserve the original prepared binding

### Requirement: Durable input retention and archive-gated cleanup
Every destination preparation MUST hold durable references to its producer handoffs while its run may need them. Successful finalization MUST release that run's references; blocked or failed runs MUST retain them for bit-identical retry. A ready producer handoff MUST remain available for future declared consumers until the producer is explicitly archived. The broker MUST delete its bytes only after an idempotent mark-reclaimable operation records producer archive and no acquired references remain. It MUST NOT use timer-, TTL-, idleness-, or sweep-based deletion.

#### Scenario: Producer workspace cleanup
- **WHEN** the producer mutable workspace is deleted while its ready handoff remains unarchived or referenced
- **THEN** the handoff SHALL remain available to declared destination bindings

#### Scenario: Last reference released before producer archive
- **WHEN** the last destination reference is released but the producer is not archived
- **THEN** the ready handoff SHALL remain available for a future same-board input edge

#### Scenario: Last reference released after producer archive
- **WHEN** a reclaimable producer handoff loses its last acquired reference
- **THEN** the broker SHALL delete its bytes synchronously and idempotently

#### Scenario: Broker restart
- **WHEN** the broker restarts with active, retained, or reclaimable input bindings
- **THEN** it SHALL reconstruct retention and deletion eligibility from durable records
- **AND** it MUST NOT infer authority solely from directories found on disk

### Requirement: Project work and inputs remain separate
A Project destination MUST receive its own private Project work plane in addition to namespaced immutable inputs and its own output plane. The system MUST NOT merge producer repository state or patches automatically.

#### Scenario: Project synthesis task
- **WHEN** a Project task consumes two producer outputs
- **THEN** its Project source SHALL remain under `/workspace/work`
- **AND** producer outputs SHALL remain separately mounted under `/workspace/inputs`
- **AND** any patch application or merge SHALL be an explicit operation in the destination work plane
