## Purpose

Define how Homelab identifies durable state, compiles explicit protection obligations, records recovery evidence, and permits restoration without coupling those contracts to a deployment platform or retained representation.

## ADDED Requirements

### Requirement: Logical state identity is stable across implementation changes

Each protected or planned state SHALL have a stable public identifier for the concrete logical resource. Changing its live host, deployment platform, access path, backing resource, application version, package, protection policy, or current realization SHALL NOT change that identifier.

Different concrete instances SHALL have different state identifiers even when they use the same reusable state description or one is populated from the other. Capture, retained-copy, and restore identifiers SHALL remain separate from state identity.

#### Scenario: State moves to another realization

- **WHEN** one logical state moves from a host path to a volume or deployment-owned storage resource
- **THEN** its state identifier remains unchanged while its realization and configuration provenance change

#### Scenario: Production data is rehearsed in QA

- **WHEN** a QA state is populated from a production recovery point
- **THEN** QA retains its own state identifier and records the production point only as origin provenance

### Requirement: Reusable state semantics and instance protection policy are separate

A reusable application or service integration SHALL describe its state slots and consistency or restore semantics without fixing the concrete instance's sensitivity, target obligations, or copy policy. Each concrete state instance SHALL resolve a named policy or an explicit decision to remain disposable.

Explicit instance policy SHALL take precedence over selector defaults and weak reusable suggestions. Equal-precedence assignments that select different policies SHALL fail rather than depend on declaration order, merge the policies, or silently choose the weaker result.

#### Scenario: QA overrides a durable suggestion

- **WHEN** a reusable state slot suggests durable handling but its QA instance explicitly selects a disposable policy
- **THEN** QA has no protection routes while the corresponding production instance can retain its independent policy

#### Scenario: Peer policy selectors disagree

- **WHEN** two matching selector defaults at the same precedence assign different policies to one state
- **THEN** policy resolution fails with the state and competing assignments identified

### Requirement: Plans expose gaps while executable protection resolves every obligation

A diagnostic plan and an executable protection configuration SHALL be derived from the same state, realization, policy, route, target, and implementation declarations. A plan-only state SHALL remain non-operational and SHALL expose missing, ambiguous, unsupported, or not-yet-enabled obligations without representing them as fulfilled.

An enabled executable configuration SHALL exist only when the state has exactly one authoritative live realization and every required named route resolves to a configured target and exactly one compatible implementation, unless that route explicitly selects its implementation. Runtime target unavailability SHALL NOT remove the configured obligation.

#### Scenario: Unfinished protection is inspected

- **WHEN** a plan-only state names required routes whose target or implementation configuration is incomplete
- **THEN** the plan identifies each unresolved route and cannot be used to capture, restore, or verify data

#### Scenario: The same unfinished state is enabled

- **WHEN** an operator enables executable protection for that state without resolving every required obligation
- **THEN** compilation fails with the state and route context rather than dropping an obligation or emitting a partially executable manifest

#### Scenario: Two routes use one implementation

- **WHEN** a policy explicitly requires two named routes that use the same executable implementation
- **THEN** both target obligations remain required and are not deduplicated into one copy

### Requirement: A state has one authoritative live realization

Each enabled state SHALL resolve to exactly one authoritative live realization. A realization SHALL describe typed access and capture capabilities rather than infer support from a deployment label. A restored scratch output SHALL NOT become another active realization of the source state.

#### Scenario: Two active sources claim one state

- **WHEN** two realizations both claim to be the authoritative live source for one enabled state
- **THEN** executable compilation fails instead of selecting one by declaration order

#### Scenario: A realization lacks a required capability

- **WHEN** a route requires a stable filesystem capture but the selected realization exposes no compatible capture capability
- **THEN** the route remains unsupported and is not silently downgraded to a weaker live read

### Requirement: One stable capture fans out to its selected routes

A capture operation SHALL establish one capture identity and one achieved consistency boundary before fulfilling its selected routes. Every retained copy produced by that operation SHALL reference the same capture identity and capture time while retaining its own route, target, copy identity, and completion time.

The capture SHALL remain available until every consumer that needs it has completed or failed safely. Failure of one route SHALL produce a non-successful overall result while preserving complete points and receipts from successful routes. A retry SHALL NOT recapture changed live data under the prior capture identity.

#### Scenario: Local retention succeeds and replication fails

- **WHEN** one capture produces a complete local point but its second target fails
- **THEN** the operation reports partial failure, retains the valid local point, and does not advertise an incomplete second-target point

#### Scenario: A later copy completes

- **WHEN** a target finishes storing a copy after the stable capture was created
- **THEN** its point records the original capture time and a distinct later copy-completion time

### Requirement: Recovery points are target-qualified and independently discoverable

A recovery point reference SHALL identify the state, route, target, and immutable point. Each retained target SHALL keep enough protected metadata with its native representation for a compatible configured implementation to discover, validate, and restore the point without the live source or a coordinator-local catalog.

Interpretation-critical metadata SHALL include a schema and format version, state and capture identity, point and copy identity, timestamps, data kind, representation, native locator, capture scope, achieved consistency, required driver compatibility, completion, and available verification evidence. Unknown optional provenance MAY remain uninterpreted, but an unsupported required format or protocol SHALL fail safely.

#### Scenario: Source and local catalog are lost

- **WHEN** the live source and coordinator-local index are unavailable but a retained target and compatible configured driver remain
- **THEN** the target's complete points can still be discovered, selected, restored, and checked from target-held metadata

#### Scenario: Native names look alike

- **WHEN** two targets contain points with similar native snapshot names
- **THEN** point selection remains unambiguous because the reference includes state, route, target, and point identity

### Requirement: Protection operations are explicit and imperative

Capture, point discovery that accesses a backend, restore, and verification SHALL run only through explicit operator-invoked operations against an enabled executable configuration. Declarative evaluation and routine activation SHALL NOT capture data, restore data, choose a latest point, or mutate a protection target.

Planning SHALL require no backend access and SHALL have no data-path side effects. A convenience selection such as latest SHALL resolve once to an immutable target-qualified point before mutation and SHALL report that exact selection.

#### Scenario: Configuration is activated

- **WHEN** a host or workload configuration containing state-protection declarations is evaluated or activated
- **THEN** no capture, target mutation, or restore operation starts

#### Scenario: A plan-only state is passed to capture

- **WHEN** an operator requests capture for a state that has no enabled executable configuration
- **THEN** the operation refuses before invoking any driver

### Requirement: Restore is constrained to a fresh authorized scratch destination

State protection SHALL restore a selected immutable point only into a new destination within an explicitly configured scratch capability unless a separate future contract authorizes active-state replacement. It SHALL reject an existing or nonempty destination, traversal outside the scratch root, overlap or aliasing with active state or retained targets, hostile native mount or share properties, and unsupported representation or fidelity before mutation.

Safety and authority checks SHALL be repeated immediately before creation or write. A force option SHALL NOT bypass these checks. Cleanup SHALL remove only temporary resources whose ownership by the current operation was established independently of untrusted recovery metadata.

#### Scenario: Destination already exists

- **WHEN** restore names an existing destination under the scratch root
- **THEN** restore refuses without changing that destination or selecting a different name

#### Scenario: Destination aliases active state

- **WHEN** a requested scratch name or native locator resolves to the live source, a retained target, or a path outside the allowed scratch root
- **THEN** restore refuses before creating, mounting, receiving, or overwriting data

#### Scenario: A safe rehearsal is repeated

- **WHEN** the same immutable point is restored into two different new authorized scratch destinations
- **THEN** both rehearsals use the selected point and neither changes the live state or retained representation

### Requirement: Drivers use a fixed versioned executable contract

Backend and deployment-specific operations SHALL be performed by executables selected from trusted evaluated configuration through a versioned structured protocol. Recovery metadata SHALL NOT select or supply an executable path. An incompatible protocol major version, unsupported required operation, representation, access method, or fidelity requirement SHALL be rejected before mutation.

Requests SHALL carry structured operation and capability data rather than arbitrary shell commands or unconstrained privileged flags. Bulk backup data and restored contents SHALL NOT be embedded in the structured control envelope.

#### Scenario: Historical metadata names an old executable

- **WHEN** a retained point's provenance contains a historical program or package path
- **THEN** the coordinator uses only the currently configured compatible driver and never executes the provenance value

#### Scenario: Driver protocol is incompatible

- **WHEN** the configured driver cannot support the request's required protocol major version or operation
- **THEN** the operation fails before the driver mutates a source, target, or scratch destination

### Requirement: Operational evidence does not overstate protection

The system SHALL distinguish configured intent, planned but disabled state, backend observation, capture completion, per-target retention, partial or failed operations, restoration, backend checks, and content verification. Absence of an observed point SHALL remain distinct from an observed empty healthy catalog, and success for one route SHALL NOT imply success for another.

Configuration, a listening service, a driver success exit, or a complete local capture SHALL NOT by itself be reported as independent protection or application-consistent recovery.

#### Scenario: No backend observation has run

- **WHEN** a fully resolved executable configuration exists but no status or point operation has contacted its targets
- **THEN** status reports configured but not observed rather than protected or healthy

#### Scenario: Restored content is altered

- **WHEN** bytes or required metadata in a restored scratch result no longer match the selected point's verification evidence
- **THEN** verification fails even if restore previously returned success

### Requirement: Capture scope, consistency, and fidelity are explicit

Each capture and point SHALL state the included resource boundary, achieved consistency, and filesystem or data fidelity it supports. A parent filesystem or dataset SHALL NOT be represented as covering mounted children, child datasets, or separate resources unless that coverage was explicitly captured and verified.

Filesystem point-in-time consistency SHALL NOT be represented as application consistency for databases, compound applications, or independently changing resources. Unsupported metadata or semantic validation SHALL remain visible rather than being silently omitted under a generic success claim.

#### Scenario: A path contains a child dataset

- **WHEN** a non-recursive parent-dataset capture excludes a mounted child dataset
- **THEN** its scope identifies that boundary and does not report the whole path tree as protected

#### Scenario: Database files are in a filesystem snapshot

- **WHEN** a filesystem-level point contains live database files without an application-consistent capture procedure
- **THEN** the point reports filesystem consistency only and does not claim database or application recovery validity

### Requirement: Operation authority and sensitive data remain scoped

Protection configuration SHALL be capable of separating live-source capture access, target write, retained-point read, scratch write, and target administration. Granting one operation SHALL NOT implicitly grant retained-point deletion, arbitrary command execution, or access to unrelated state.

Declarative manifests, build artifacts, generated documentation, and default diagnostics SHALL NOT contain credential values, backed-up file contents, or restored contents. Scratch output SHALL be treated as sensitive state and SHALL use restrictive access appropriate to its configured destination.

#### Scenario: A target writer is configured

- **WHEN** an implementation receives authority to store a required copy
- **THEN** that authority does not by itself permit pruning historical points or reading unrelated targets

#### Scenario: Diagnostics report a failure

- **WHEN** capture or restore fails while handling synthetic secret-looking content or runtime credential references
- **THEN** diagnostics identify the operation and affected route without printing the credential or data contents
