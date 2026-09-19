## Purpose

Define how Homelab identifies durable state, resolves protection through independently owned lifecycle implementations, validates coverage, records recovery evidence, and permits safe restoration without becoming a backup engine.

## ADDED Requirements

### Requirement: Logical state identity is stable across implementation changes

Each protected or planned state SHALL have a stable public identifier for the concrete logical resource. Changing its declaration module, live host, deployment platform, access path, backing resource, application version, package, lifecycle owner, protection policy, or current realization SHALL NOT change that identifier.

Different concrete instances SHALL have different state identifiers even when they use the same reusable state description or one is populated from the other. Native backup identities, retained-point identities, and restore destinations SHALL remain separate from state identity.

#### Scenario: State moves to another realization

- **WHEN** one logical state moves from a host path to a volume or deployment-owned storage resource
- **THEN** its state identifier remains unchanged while its realization and configuration provenance change

### Requirement: Reusable state semantics and instance protection policy are separate

A reusable application or service integration SHALL describe its state slots, data kind, required semantic consistency and fidelity, and any genuinely required application payload format without fixing the concrete instance's sensitivity, targets, lifecycle owner, backend-native retained representation, copy policy, or runtime destination authorization. A StateSlot SHALL NOT enumerate backup-engine container formats merely because eligible Integrations may retain its payload in those formats. Each concrete state instance SHALL resolve a named policy or an explicit decision to remain disposable. M1's scratch-only restore authorization SHALL NOT become an intrinsic StateSlot semantic.

Explicit instance policy SHALL take precedence over selector defaults and weak reusable suggestions. Equal-precedence assignments that select different policies SHALL fail rather than depend on declaration order, merge the policies, or silently choose the weaker result.

#### Scenario: QA overrides a durable suggestion

- **WHEN** a reusable state slot suggests durable handling but its QA instance explicitly selects a disposable policy
- **THEN** QA has no protection routes while the corresponding production instance can retain its independent policy

#### Scenario: Peer policy selectors disagree

- **WHEN** two matching selector defaults at the same precedence assign different policies to one state
- **THEN** policy resolution fails with the state and competing assignments identified

### Requirement: Plans expose gaps while executable protection resolves every obligation

A diagnostic plan and an executable protection configuration SHALL be derived from the same state, realization, policy, route, target, and lifecycle-owner declarations. A plan-only state SHALL remain non-operational and SHALL expose missing, ambiguous, unsupported, or not-yet-enabled obligations without representing them as fulfilled.

An enabled configuration SHALL exist only when the state has exactly one authoritative live realization and every required route resolves to a configured target, validated coverage, and exactly one compatible lifecycle-owner integration unless that route explicitly selects one. Runtime target unavailability SHALL NOT remove the configured obligation.

#### Scenario: Unfinished protection is inspected

- **WHEN** a plan-only state names required routes whose target, coverage, or owner configuration is incomplete
- **THEN** the plan identifies each unresolved route and cannot be used to operate on data

#### Scenario: The same unfinished state is enabled

- **WHEN** an operator enables that state without resolving every required obligation
- **THEN** compilation fails with state and route context rather than dropping an obligation or emitting a partially executable configuration

#### Scenario: Two routes use one lifecycle owner

- **WHEN** a policy explicitly requires two named routes that one owner integration can satisfy
- **THEN** both target obligations remain distinct and are not deduplicated merely because one owner manages them

#### Scenario: Two routes share one target through different owners

- **WHEN** a policy explicitly requires two named routes that select different lifecycle owners but name the same target
- **THEN** the routes remain distinct obligations because route identity is not derived from target or owner identity

#### Scenario: One route has several eligible owners

- **WHEN** one required route can be fulfilled by more than one eligible lifecycle-owner integration and policy selects none
- **THEN** that route remains ambiguous rather than becoming several obligations or selecting an owner by declaration order

### Requirement: Live realization and protection coverage are explicit

Each enabled state SHALL resolve to exactly one authoritative live realization. A realization SHALL describe typed access and capture capabilities rather than infer support from a deployment label. Runtime-facing Incus, container, Kubernetes, or microVM paths SHALL remain nested access projections when they expose the same capture boundary; they SHALL NOT become additional authoritative realizations. A restored scratch output SHALL NOT become another active realization of the source state.

Application-native realizations MAY record `physicalBacking` for inventory, but that backing SHALL be explicitly non-authoritative. It SHALL NOT satisfy a protection route or participate in capability matching for that State unless it is modeled as a separate State with its own identity and requirements.

Integration matching SHALL use the Integration's required source capabilities and actual configured semantic consistency/fidelity guarantees as its primary compatibility boundary. A realization-kind restriction MAY be imposed only when a native mechanism genuinely requires that representation or access type; deployment kind SHALL NOT be the ordinary dispatch key. Possessing `filesystem-read` alone SHALL NOT establish a single-point `crash` or atomic `filesystem` guarantee: a mutable traversal that may observe different resources at different moments SHALL report `live` consistency unless its configured lifecycle-owner workflow provides a stronger stable capture. Preserve SHALL NOT orchestrate snapshot stages to strengthen that guarantee. Resolution SHALL expose and reject any selected workflow whose guarantee does not satisfy the StateSlot and genuine Route outcome requirements.

For each route, compilation SHALL derive the base source locator or path from the authoritative realization, apply only explicit source narrowing such as subpath, include, or exclude wiring, and validate that the selected lifecycle owner's resulting configured sources cover the intended state boundary. A parent path or dataset SHALL NOT be represented as covering mounted children, child datasets, or excluded resources unless the owner configuration includes and can preserve them. Derivable source paths SHALL NOT be repeated as independent Binding or owner-native inputs whose disagreement could silently select another source.

#### Scenario: Two active sources claim one state

- **WHEN** two realizations both claim to be the authoritative live source for one enabled state
- **THEN** executable compilation fails instead of selecting one by declaration order

#### Scenario: Configured source misses a child boundary

- **WHEN** an owner's source selection omits a mounted child or child dataset that the state declaration says is required
- **THEN** the route fails coverage validation rather than reporting the whole state as protected

#### Scenario: A realization lacks a required capability

- **WHEN** a policy requires a stable capture but the realization and selected owner expose no compatible operation
- **THEN** the route remains unsupported and is not silently downgraded to a weaker live read

#### Scenario: A mutable filesystem read does not imply single-point consistency

- **WHEN** an Integration consumes `filesystem-read` from a live mutable filesystem without an owner-provided stable-view workflow
- **THEN** it reports `live` rather than `crash` or `filesystem` consistency and cannot satisfy a StateSlot requiring a stronger guarantee

#### Scenario: One ZFS realization serves capability-specific routes

- **WHEN** one ZFS realization provides `filesystem-read`, `zfs-snapshot`, and `zfs-send`, one Route selects a Restic-style Integration whose configured workflow consumes `filesystem-read`, and another selects a native ZFS Integration consuming the ZFS capabilities
- **THEN** both Routes may resolve from the same authoritative realization without the Restic-style Integration enumerating `zfs-dataset` as a supported deployment kind, while each reports only the consistency its selected lifecycle-owner workflow actually guarantees

### Requirement: Logical targets and owner-native destinations remain separate

A Target SHALL identify the intended logical destination, purpose, or failure domain independently of backend representation. Restic repositories, Borg repositories, ZFS receive datasets, object buckets, remotes, credential references, and native retained-point container formats SHALL belong to the selected Integration's namespaced native configuration and recovery evidence rather than define Target identity or require another public target registry.

Integration-owned native destination and shared owner configuration for one Integration+Target pair MAY be declared once as typed internal wiring and reused by every compatible State/Route obligation. A normal State whose Policy selects a Route and whose Realization satisfies the selected Integration SHALL NOT require a per-State Binding merely to repeat repository location, credentials, Target, Integration, or source path.

A protection Binding is optional and SHALL contain only genuinely irreducible state-specific wiring: optional Integration selection when the Route intentionally leaves it unresolved, source narrowing not derivable from the Realization, and namespaced native overrides. It SHALL reference State and Route when present, and SHALL NOT repeat the Route's logical Target, the Realization's base source locator/path, a selected Integration, or shared Integration+Target configuration merely to reconstruct relationships already fixed elsewhere. Contradictory or duplicate wiring SHALL fail.

Routes SHALL express a logical Target, optional Integration selection, and only semantic outcome constraints genuinely required by policy. Integration normally owns required source capabilities, owner-native destination shape, and native retained-point representation. A Route SHALL NOT require `restic.snapshot`, `borg.archive`, `openzfs.snapshot`, or another owner format merely because it selects that Integration.

Integration projector functions and native configuration renderers SHALL remain typed internal Nix implementation registration. Public Integration data and generated manifests SHALL contain identity, declared capabilities and constraints, packaged adapter references, stable IDs, and resolved values, but SHALL NOT serialize Nix projector functions.

Multiple successful Routes to one Target or failure domain SHALL NOT be reported as independent disaster copies merely because they use different Integrations or native representations. Failure-domain independence comes from distinct Target semantics and evidence, not Route count.

#### Scenario: Two representations satisfy one logical destination

- **WHEN** separate required Routes use Restic and native ZFS Integrations for the same logical Target
- **THEN** the Routes retain distinct obligations and Integration-owned native destination/retained-point representations without changing Target identity or claiming two independent failure-domain copies

#### Scenario: A normal obligation needs no per-State Binding

- **WHEN** a Policy selects a Route, its logical Target and Integration have shared native wiring, and the State's Realization provides the Integration's required source capabilities without state-specific narrowing
- **THEN** resolution derives the source from the Realization and native destination from shared Integration+Target wiring without requiring a Binding

#### Scenario: An optional Binding narrows one State

- **WHEN** one State needs a subpath, include/exclude rule, unresolved-Route owner selection, or namespaced native override that cannot be derived from shared declarations
- **THEN** its Binding carries only that irreducible difference and does not repeat the base source, Target, or shared owner configuration

### Requirement: Established lifecycle owners retain their native responsibilities

A selected backup or replication implementation SHALL remain the owner of the lifecycle semantics it advertises, including any scheduling, snapshot creation and cleanup, incremental transfer, resumability, retention and pruning, repository initialization and maintenance, consistency checks, and database export or restore behavior.

State protection SHALL configure, select, inspect, safely dispatch, and test those owner operations. It SHALL NOT independently reproduce an owner's internal workflow or divide an atomic owner operation into a competing coordinator-managed pipeline. If no selected owner provides a required operation, that capability SHALL remain unresolved unless a deliberately bounded non-production reference adapter is selected.

#### Scenario: A repository owner performs backup and retention

- **WHEN** a route selects an implementation that natively performs backup, retention, and repository checks as one configured lifecycle
- **THEN** Homelab generates and dispatches that lifecycle without implementing a second scheduler, retention engine, or repository manager

#### Scenario: An owner has no safe restore operation

- **WHEN** the selected implementation cannot restore the required point into an authorized scratch destination
- **THEN** restore remains unsupported rather than falling back to an unconstrained generic copy or in-place replacement

### Requirement: Recovery evidence preserves native lifecycle semantics

Recovery evidence SHALL qualify a point by logical state, Route, Target, lifecycle owner, and the owner's immutable native point identity. It SHALL distinguish any semantic payload representation required by the StateSlot or application integration from the backend-native retained-point representation owned by the Integration. A POSIX filesystem payload may be retained as an OpenZFS snapshot, Restic snapshot, Borg archive, or another native container without changing StateSlot semantics; an application-native payload such as a PostgreSQL logical/custom dump may itself be retained inside a repository representation. Evidence SHALL record capture scope, achieved semantic consistency and fidelity, relevant timestamps, both applicable representation layers, completion, and available verification evidence without replacing the owner's native catalog or retention identity.

Before a point is accepted for inspection or restore, its achieved consistency and fidelity SHALL satisfy the resolved StateSlot and Route requirements and SHALL NOT contradict the selected Integration's configured guarantees. Integration configuration alone SHALL NOT substitute for point-level achieved evidence.

A recovery point MAY carry opaque producer provenance under namespaced keys, including application, database/server, schema, or data-format versions. State protection SHALL retain and display this provenance without requiring generic interpretation. Producer provenance SHALL NOT participate in `stateId`, route identity, or native point identity.

A retained target SHALL carry, or its selected lifecycle owner SHALL natively maintain, enough durable information for a compatible installed integration plus reproducible configuration to discover and restore complete points after loss of the live source and coordinator-local cache. A universal Preserve-owned metadata layout SHALL NOT be required when the owner already provides this property.

If one owner proves that several routes share one stable capture, their evidence SHALL retain that relationship. Independently captured routes SHALL NOT be represented as synchronized or as sharing a capture merely because one policy selected them.

#### Scenario: Producer provenance is retained opaquely

- **WHEN** an application integration records namespaced application, server, schema, or data-format provenance on a recovery point
- **THEN** inspection retains and displays those values without changing state identity or requiring Preserve to interpret their compatibility

#### Scenario: Source and local cache are lost

- **WHEN** the live source and coordinator-local cache are unavailable but a retained target, its native catalog or metadata, reproducible mapping, and a compatible integration remain
- **THEN** complete points can still be discovered, selected, restored, and checked without a hidden source-only record

#### Scenario: Two owners capture at different times

- **WHEN** two required routes are fulfilled by lifecycle owners that capture independently
- **THEN** each route reports its own native point and time and the policy does not claim a synchronized capture

#### Scenario: One owner shares a capture

- **WHEN** one lifecycle owner creates a stable native point and replicates that same point to another target
- **THEN** both route records identify the proven shared native capture while retaining separate target completion evidence

#### Scenario: A point is weaker than its resolved plan

- **WHEN** a lifecycle owner reports a point whose achieved consistency or fidelity does not satisfy the resolved StateSlot, Route, or configured Integration guarantee
- **THEN** the coordinator rejects that point before listing it as usable or passing it to restore

### Requirement: Configuration does not make restore an activation action

Declarative evaluation and routine activation SHALL only configure lifecycle owners and operation integrations. They SHALL NOT restore data, select a latest point for restoration, replace active state, or interpret successful configuration as proof that a point exists.

A lifecycle owner MAY run configured capture, replication, retention, or check schedules after activation under its own lifecycle. Manual dispatch through the state-protection operation surface SHALL invoke only a declared owner action. Restore SHALL always require an explicit operator request naming an immutable point and destination.

#### Scenario: Configuration is activated

- **WHEN** a host configuration containing state-protection and lifecycle-owner settings is activated
- **THEN** the selected owner may receive its declarative service and schedule configuration but no restore begins

#### Scenario: A plan-only state is passed to an operation

- **WHEN** an operator requests a data operation for a state that has no enabled executable configuration
- **THEN** the operation refuses before invoking an owner adapter

### Requirement: Restore is constrained to a fresh authorized scratch destination

For M1, state protection SHALL restore a selected immutable point only into a new destination within an explicitly configured scratch capability. This is coordinator authorization policy, not an intrinsic StateSlot semantic; any future production or active-state restore requires a separate contract and explicit authority. M1 SHALL reject an existing or nonempty destination, traversal outside the scratch root, overlap or aliasing with active state or retained Targets, hostile native mount or share properties, and unsupported payload/native representation or fidelity before mutation.

The integration SHALL use the lifecycle owner's native restore or extraction operation when it can enforce the destination boundary. A thin integration-specific restore helper SHALL remain limited to that missing safe operation and SHALL NOT acquire unrelated lifecycle ownership. Safety and authority checks SHALL be repeated immediately before mutation, and a force option SHALL NOT bypass them.

#### Scenario: Destination already exists

- **WHEN** restore names an existing destination under the scratch root
- **THEN** restore refuses without changing that destination or selecting a different name

#### Scenario: A native restore defaults to an active path

- **WHEN** an owner's default restore operation would write to the original source or filesystem root
- **THEN** the integration refuses that default and uses only a supported explicit scratch target

#### Scenario: A safe rehearsal is repeated

- **WHEN** the same immutable point is restored into two different new authorized scratch destinations
- **THEN** both rehearsals use the selected point and neither changes live state or retained representations

### Requirement: External adapters are versioned and bounded by owner operations

Lifecycle-owner integrations SHALL use a small versioned, language-independent executable contract selected from trusted evaluated configuration. Recovery metadata SHALL NOT select or supply an executable path. Incompatible protocol versions, unsupported required operations, representations, access methods, or fidelity requirements SHALL be rejected before mutation.

Every enabled Integration SHALL provide `describe`, `status`, and `points` as baseline inspection operations. `run`, `restore`, and `verify` remain optional and SHALL be checked before dispatch. Missing baseline inspection capabilities SHALL prevent an executable Integration rather than becoming a runtime failure that hides unrelated Route evidence.

An adapter operation SHALL correspond to a declared owner-level action such as inspect status, enumerate points, start one configured job, restore one point, or verify one result. The protocol SHALL NOT require every implementation to expose a universal internal capture, stable-view, transfer, release, retry, or cleanup workflow. Bulk backup data and restored contents SHALL NOT be embedded in its control messages.

Timeout and cancellation SHALL terminate the adapter's process group or equivalent descendant scope and drain bounded output without hanging. A timed-out adapter SHALL NOT leave backend child processes running merely because the direct adapter process exited or was killed.

#### Scenario: An atomic owner operation is dispatched

- **WHEN** an established lifecycle owner performs capture, transfer, retention, and checks within one configured action
- **THEN** the adapter invokes that action as one capability rather than reimplementing its internal stages

#### Scenario: Historical metadata names an old executable

- **WHEN** retained provenance contains a historical program or package path
- **THEN** dispatch uses only the currently configured compatible adapter and never executes the provenance value

#### Scenario: An enabled Integration omits baseline inspection

- **WHEN** an Integration selected for an executable Route does not advertise `describe`, `status`, and `points`
- **THEN** executable validation rejects it while plan-only inventory may report the missing capability

#### Scenario: A timed-out adapter has a backend child

- **WHEN** an adapter spawns a long-lived backend child and exceeds its configured timeout
- **THEN** cancellation terminates both adapter and descendant scope and bounded output readers finish without hanging

### Requirement: Operational evidence does not overstate protection

The system SHALL distinguish configured intent, planned but disabled state, backend observation, native point completion, per-target retention, partial or failed obligations, restoration, owner-native checks, and content verification. Absence of observation SHALL remain distinct from an observed empty healthy catalog, and success for one route SHALL NOT imply success for another. State-level point queries SHALL preserve each Route's successful points or structured error independently so one unavailable or invalid catalog cannot hide valid recovery points from another Route.

Configuration, a listening service, a successful adapter exit, or a local native point SHALL NOT by itself be reported as independent protection or application-consistent recovery. Owner status and checks SHALL be interpreted according to their documented scope rather than collapsed into one protected flag.

#### Scenario: No owner observation has run

- **WHEN** a fully resolved configuration exists but no status or point operation has observed its lifecycle owners
- **THEN** status reports configured but not observed rather than protected or healthy

#### Scenario: One route is stale

- **WHEN** one required target has a recent verified point and another target is stale or failed
- **THEN** the second obligation remains visibly unsatisfied

#### Scenario: One point catalog is unavailable

- **WHEN** a State has valid points on one resolved Route while another Route's point operation or point validation fails
- **THEN** the point query returns the successful Route's points and a structured error for the failed Route rather than failing the whole State query

### Requirement: Capture scope, consistency, and fidelity are explicit

Each observed point SHALL state the included resource boundary, achieved consistency, semantic payload representation when applicable, backend-native retained-point representation, and filesystem or data fidelity established by its lifecycle owner and verification. Generic consistency SHALL use a small semantic vocabulary: `live` for a traversal with no single-point guarantee, `crash` for one crash-consistent point, `filesystem` for a filesystem-consistent point, and `application` or `database` only when that stronger semantic distinction is justified. Export methods, backup-engine containers, native snapshot mechanisms, and online-backup APIs SHALL be represented as capabilities, payload/native representations, or namespaced fidelity rather than invented generic consistency levels. `filesystem-read` SHALL NOT by itself imply point-in-time `filesystem` consistency, and filesystem point-in-time consistency SHALL NOT be represented as application or database consistency for databases, compound applications, or independently changing resources.

Unsupported metadata, excluded content, owner-specific restore constraints, or unverified semantic behavior SHALL remain visible rather than being silently omitted under a generic success claim.

#### Scenario: Database files are in a filesystem snapshot

- **WHEN** a filesystem-level point contains live database files without an application-consistent owner operation
- **THEN** the point reports filesystem consistency only and does not claim database or application recovery validity

#### Scenario: Owner-native checks do not restore content

- **WHEN** an owner reports that repository or native metadata checks passed without a scratch restore
- **THEN** evidence records those checks but does not claim content restoration was verified

### Requirement: Recovery integrations have independent conformance evidence

An integration SHALL advertise only operations, coverage, consistency, and fidelity exercised against the shipped owner path or explicitly declared unsupported. Recovery acceptance SHALL restore a selected native point into disposable scratch and verify the result independently of the adapter's own success result.

A non-production reference adapter SHALL be clearly identified and SHALL NOT be used as evidence that scheduling, retention, incremental transfer, repository management, receiver lifecycle, or application consistency is production-ready.

#### Scenario: A lifecycle owner integration is accepted

- **WHEN** a disposable test configures the owner, creates meaningful state, obtains a native point through the owner operation, restores it through the shipped integration, and independently checks the result
- **THEN** the integration may advertise only the capabilities and environment that the test exercised

#### Scenario: A reference adapter passes

- **WHEN** a bounded direct backend adapter passes its isolated conformance test
- **THEN** reporting identifies it as reference/test-only and does not infer production lifecycle ownership

### Requirement: Operation authority and sensitive data remain scoped

Protection configuration SHALL be capable of separating live-source access, target write, retained-point read, scratch write, and target administration. Granting one operation SHALL NOT implicitly grant retained-point deletion, arbitrary command execution, or access to unrelated state.

Declarative manifests, build artifacts, generated documentation, and default diagnostics SHALL NOT contain credential values, backed-up file contents, or restored contents. Adapter errors intended for default display SHALL use operator-safe structured summaries; raw owner stderr and backend command output SHALL NOT be copied into those summaries. Scratch output SHALL be treated as sensitive state and SHALL use restrictive access appropriate to its configured destination.

#### Scenario: A target writer is configured

- **WHEN** a lifecycle owner receives authority to store a required copy
- **THEN** that authority does not by itself permit a separate inspection or restore integration to prune historical points

#### Scenario: Diagnostics report a failure

- **WHEN** dispatch or restore fails while the owner writes synthetic secret-looking stderr or handles runtime credential references
- **THEN** default diagnostics identify the operation and affected route through an operator-safe summary without copying raw owner stderr, credential values, or data contents
