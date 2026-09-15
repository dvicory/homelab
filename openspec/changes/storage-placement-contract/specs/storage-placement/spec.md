## Purpose

Define the durable contract between storage consumers and the devices, pools
and tiers that hold their data, so that placement can change without changing
what applications, manifests and operators depend on.

## ADDED Requirements

### Requirement: Consumer-visible storage paths are stable and semantic

A storage path exposed to an application, manifest, or operator SHALL describe
the kind of data it holds. It SHALL NOT encode physical placement, device
identity, or relative importance. Changing where content is physically stored
SHALL NOT change a consumer-visible path or require a consumer to be
reconfigured.

#### Scenario: Content is moved to different hardware

- **WHEN** content that a consumer already references is relocated to a
  different device, pool, or placement tier
- **THEN** the consumer reads and writes the same content at the same path,
  with no configuration change and no interruption beyond the move itself

#### Scenario: A device is replaced

- **WHEN** a device is replaced by a different device and becomes the location
  for content that was previously stored elsewhere
- **THEN** every consumer-visible path still resolves to the content it
  resolved to before

### Requirement: Link-dependent paths are one filesystem to their consumer

Where a consumer creates, links, renames, or removes between two or more
consumer-visible paths, those paths SHALL be presented to that consumer within
a single filesystem.

#### Scenario: A completed item is imported into a library

- **WHEN** a consumer links a completed item from its ingest path into a
  library path
- **THEN** the operation succeeds and both paths refer to the same underlying
  data rather than to two copies

#### Scenario: A rename crosses an ingest and library boundary

- **WHEN** a consumer atomically renames an item between an ingest path and a
  library path
- **THEN** the operation succeeds without a copy, and a reader of the library
  observes either the complete item or no item

### Requirement: Ingest access and library access are distinct

A consumer that only reads library content SHALL NOT receive write access to
it, and SHALL NOT receive access to the ingest location.

#### Scenario: A read-only consumer requests library access

- **WHEN** a workload is declared as a reader of library content
- **THEN** it can read the library, cannot modify it, and cannot reach the
  ingest location through its declared access

### Requirement: New content is created only on creation-eligible placements

New content SHALL be created only on storage declared to accept new content.
Storage declared as archive placement SHALL NOT receive newly created content.

#### Scenario: A new item is written through the namespace

- **WHEN** a consumer creates a new file or directory
- **THEN** the content resides on storage declared to accept new content, and
  no part of it resides on archive placement

### Requirement: Archive placements remain usable for their existing content

Storage declared as archive placement SHALL remain fully usable for content
already present there.

#### Scenario: Archived content is modified

- **WHEN** a consumer modifies, renames, or deletes content that already
  resides on archive placement
- **THEN** the operation succeeds on that storage

### Requirement: Movement between placements preserves link relationships

Moving content between placements SHALL preserve every consumer-visible path
that refers to the same underlying data, and those paths SHALL remain usable
throughout the move. Temporary duplication of content during a move is
permitted, provided it is reconcilable.

#### Scenario: Content with multiple links is moved between placements

- **WHEN** content reachable through more than one consumer-visible path is
  moved between placements
- **THEN** every one of those paths still resolves to the content after the
  move, and the space is not permanently doubled

#### Scenario: A move fails or is interrupted

- **WHEN** a move between placements fails after it has begun
- **THEN** every consumer-visible path still resolves to complete data rather
  than to a partial copy

### Requirement: Reported capacity reflects creation-eligible storage

Capacity reported for a namespace SHALL reflect the space available where new
content can be created. It SHALL NOT include capacity that new content cannot
use.

#### Scenario: Archive capacity is added

- **WHEN** archive capacity is added to a namespace without changing where new
  content is created
- **THEN** the capacity reported to a consumer that writes to the namespace is
  unchanged

#### Scenario: Creation-eligible space is consumed

- **WHEN** content is created until creation-eligible space is nearly
  exhausted
- **THEN** the capacity reported to a consumer falls to reflect that, before
  creation begins to fail

### Requirement: Required storage fails closed

When storage required by a workload is unavailable, access through its path
SHALL be denied. The system SHALL NOT present a writable substitute location,
and SHALL NOT initialize replacement application data there.

#### Scenario: A required backing location is absent

- **WHEN** a workload's required backing storage is not available
- **THEN** the workload cannot read or write through that path, and nothing is
  written to the location that would otherwise be exposed

#### Scenario: A workload starts while its storage is unavailable

- **WHEN** a workload is started and its required storage is unavailable
- **THEN** it fails rather than initializing a new empty state in its place

### Requirement: Workload storage does not gate unrelated operation

Storage required only by one workload SHALL NOT be a prerequisite for host
management, for the compute environment that runs it, or for unrelated
workloads.

#### Scenario: Application storage is unavailable

- **WHEN** storage required only by one workload is unavailable
- **THEN** the dependent workload fails or stops, while host management, the
  compute environment, and unrelated workloads continue to operate

### Requirement: Managed roots declare ownership

A storage root created by configuration SHALL carry declared owner, group, and
mode. Inherited default access entries are optional: a root declares them
only when its sharing policy requires that content created inside it later
receives access beyond owner/group/mode without a further corrective step.

#### Scenario: A new entry appears inside a shared root

- **WHEN** a participating identity creates a file or directory inside a
  managed shared root whose sharing policy declares inherited default access
- **THEN** the entry carries the declared group and permissions without an
  additional operation being run afterwards

### Requirement: Shared identities remain stable across compute replacement

Ownership identities used for shared or service content SHALL remain valid when
the compute environment that consumes the content is replaced.

#### Scenario: The consuming compute environment is rebuilt

- **WHEN** the compute environment is rebuilt and reattaches existing content
- **THEN** the replacement environment recognizes the existing ownership and
  the workloads it runs can read and write the content they previously owned

### Requirement: Activation does not rewrite existing content

Routine configuration activation SHALL NOT recursively change ownership, modes,
or access control entries of content already present under a managed root.

#### Scenario: A host with existing content is rebuilt

- **WHEN** configuration is activated on a host that already holds content
  under a managed root
- **THEN** existing entries keep the ownership, modes, and access control
  entries they had before the activation
