## ADDED Requirements

### Requirement: Task-run workspace activation

Stable task identity and an active workspace lease MUST NOT be sufficient to create, reuse, execute in, or access files in a handoff-enabled environment. Before worker spawn, trusted dispatch MUST activate a globally unique Kanban run ID against its task, workspace, lease, and full policy digest. The broker MUST issue an opaque activation ID. Every ensure, execution, and file request MUST use task/run identity attached by trusted backend state; model-facing schemas MUST NOT accept or override it. Completion MUST consume the activation before VM closure. Activating a trusted retry with a fresh run ID MUST supersede the older activation and close its generation before creating another. A prior run ID MUST NOT be reactivated.

#### Scenario: Completed run attempts recreation

- **GIVEN** completion consumed a task-run activation and closed its VM while retaining the task workspace
- **WHEN** the old worker calls ensure, execution, or file APIs using its prior run identity
- **THEN** the broker MUST reject the request
- **AND** stable task identity or lease knowledge MUST NOT recreate the VM

#### Scenario: Trusted retry

- **GIVEN** a retained task workspace has no active run
- **WHEN** trusted dispatch registers a fresh Kanban run ID against the current lease and policy
- **THEN** the broker SHALL permit that run to create a new VM generation
- **AND** all older runs and generations MUST remain stale

### Requirement: Fenced immutable publication

Trusted lifecycle code MAY publish one revision from a workspace using a unique finalization ID and one or more selected relative roots. The broker MUST transactionally consume the exact source run activation and mark its generation closing, await QEMU exit and VFS callback drain, then create a bounded verified copy. A ready revision MUST have a random publication-specific ID and a versioned canonical SHA-256 manifest digest. It MUST be immutable from every workspace and guest path and MUST NOT share mutable hardlinks with source or consumers.

#### Scenario: Publish selected output

- **GIVEN** an authorized active task run and valid selected roots
- **WHEN** required completion lifecycle code publishes with a new finalization ID
- **THEN** the broker SHALL fence and close the run before reading bytes
- **AND** SHALL return one verified ready revision
- **AND** later writes to a retried producer workspace MUST NOT change it

#### Scenario: Old request races publication

- **GIVEN** publication has consumed the source run activation
- **WHEN** an execution or file request from that run arrives
- **THEN** it MUST be rejected
- **AND** no post-fence bytes MAY enter the revision

### Requirement: Canonical bounded manifest

The manifest MUST contain only directories and regular files under selected relative POSIX roots; exact `.` MAY select the whole workspace but MUST NOT appear as an entry. Names MUST be strict UTF-8 and NFC. Paths MUST reject absolute paths, empty segments, `.`, `..`, NUL, normalization collisions, and configured byte-length excess. Publication MUST use pinned `rsync` without following symlinks or crossing the source filesystem boundary, preserve no ownership, timestamps, ACLs, or xattrs, and create independent destination files rather than preserving hardlinks or using reflinks. Symlinks, devices, sockets, and FIFOs MUST fail publication.

A broker-owned filesystem quota MUST bound copy-time amplification. Detached staging-tree validation MUST enforce configured logical-byte, entry-count, individual-file, and path-byte limits before ready state. Sparse source files MAY be materialized as ordinary destination files and MUST count at their full logical size. Modes MUST normalize to `0755` for directories and executable files and `0644` otherwise. The digest MUST cover a documented, broker-versioned, domain-separated canonical JSON projection sorted by UTF-8 path bytes and MUST have a fixed test vector. Owner, group, timestamps, ACLs, xattrs, and other mode bits MUST be excluded.

#### Scenario: Unsafe link

- **GIVEN** selected output contains a symlink or unsupported special file
- **WHEN** publication copies it to staging or validates the detached staging tree
- **THEN** publication MUST fail without following or exposing the target
- **AND** no ready revision MAY be exposed

#### Scenario: Limit exceeded

- **GIVEN** selected output exceeds any configured limit
- **WHEN** it is scanned or copied
- **THEN** publication MUST fail before ready state
- **AND** partial bytes SHALL remain quarantined or be removed by reconciliation

#### Scenario: Equivalent publications

- **GIVEN** two safe trees have identical canonical paths, modes, and bytes
- **WHEN** each is published under the same broker manifest version
- **THEN** their manifest digests SHALL match
- **AND** their opaque revision IDs and provenance SHALL differ

### Requirement: Idempotent publication recovery

Publication MUST bind a finalization ID to source activation/task/run/workspace, selected roots, policy digest, and policy decision digest. Repeating an identical request MUST return the same revision. Reusing the ID with any changed bound field MUST fail. The broker MUST persist publication state before filesystem mutation and reconcile staging, ready-response-loss, quarantined, and failed states after restart.

#### Scenario: Ready response is lost

- **GIVEN** the broker committed and fsynced a ready revision but Kanban did not record the response
- **WHEN** recovery repeats the same finalization ID and request
- **THEN** the broker SHALL verify and return the same revision
- **AND** MUST NOT create another publication

### Requirement: Authorized private import

The control listener MAY import one ready revision for one destination child/run only from trusted dispatcher facts proving the source worker created that child with inherited output, the direct parent link still exists on the same board and tenant, and source/destination policy matches. Import MUST bind every source, destination, relation, and policy field to a preparation ID, re-verify the stored manifest/content, create one new private writable workspace, preserve revision-relative paths, and issue an independent lease. Revision IDs MUST NOT be accepted by execution routes or model-facing requests.

#### Scenario: Direct child import

- **GIVEN** a completed parent created a directly linked child with inherited output and has one ready revision
- **WHEN** trusted dispatch prepares the destination with a new preparation ID
- **THEN** the broker SHALL verify and copy the revision into one private destination workspace
- **AND** destination writes MUST NOT change source revision or producer workspace bytes

#### Scenario: Import response is lost

- **GIVEN** the broker committed a destination workspace but Kanban did not record it
- **WHEN** recovery repeats the identical preparation ID
- **THEN** the broker SHALL return the same workspace and lease
- **AND** MUST NOT create a second writable import

#### Scenario: Import identity changes

- **GIVEN** a preparation ID is bound to one source, destination, revision, and policy
- **WHEN** it is reused with any different bound value
- **THEN** the broker MUST reject it as an idempotency conflict

### Requirement: Broker and QA integration

`pkgs/by-name/gondolin-broker-effect` MUST first consolidate the repeated SQLite connection/migration/transaction setup used by workspace, environment-registry, and access-grant services into one shared database service without changing existing behavior, then own task-run activation, revision/import records, copy orchestration, detached-tree validation, verification, and recovery. Activation fencing, environment closing, workspace lease, revision staging, and import commits MUST use that shared transaction boundary. Revision publication/import routes MUST exist only on the control listener under explicit policy actions. `modules/den/aspects/workloads/hermes/secure-terminal/default.nix` MUST derive contained QA roots and limits and enable them only for the selected `hvn-hyp1` QA profile.

#### Scenario: Execution listener attempts revision management

- **GIVEN** a request reaches the broker execution listener
- **WHEN** it attempts publication, import, listing, or revision description
- **THEN** the route MUST be absent or denied
- **AND** no revision ID, digest, metadata, or content path SHALL be disclosed

#### Scenario: Feature disabled

- **GIVEN** workspace handoff is disabled
- **WHEN** NixOS and Home Manager configurations evaluate
- **THEN** no revision root, policy action, migration behavior, or handoff route SHALL activate
- **AND** existing private-workspace behavior SHALL remain unchanged
