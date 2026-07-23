## ADDED Requirements

### Requirement: Durable workspace identity

The broker MUST assign every writable Gondolin environment an opaque workspace ID and active lease independent of VM generation. It MUST derive the host path internally and MUST NOT accept a caller-selected host path.

#### Scenario: First private acquisition
- **GIVEN** a trusted authority key with no workspace
- **WHEN** the control plane acquires its default private workspace
- **THEN** the broker SHALL create one workspace row, one active lease row, and a mode-0700 directory under the configured workspace root
- **AND** SHALL return opaque workspace and lease IDs without returning the host path

#### Scenario: Idempotent acquisition
- **GIVEN** an authority key already holding an active private workspace lease
- **WHEN** it repeats acquisition without naming another workspace
- **THEN** the broker SHALL return the same workspace and lease
- **AND** SHALL NOT create another row or directory

### Requirement: Exclusive writable lease

A workspace MUST have at most one active writable lease. Lease acquisition, release, and reacquisition MUST be transactional and fenced so stale holders cannot act through a newer lease.

#### Scenario: Conflicting writer
- **GIVEN** a workspace with an active writable lease
- **WHEN** another authority attempts to acquire it writable
- **THEN** the broker MUST reject the request with a stable workspace conflict reason
- **AND** MUST NOT alter the active lease

#### Scenario: Sequential reacquisition
- **GIVEN** a retained workspace whose prior lease is released
- **WHEN** its owning authority reacquires it
- **THEN** the broker SHALL create a new active lease with a greater fencing token
- **AND** a prior lease ID MUST fail validation

### Requirement: Workspace survives VM lifecycle

VM close, crash, broker restart, idle reap, and generation recreation MUST NOT implicitly release, delete, or replace the attached workspace. Environment reuse MUST include workspace and lease identity in its structural decision.

#### Scenario: VM recreation
- **GIVEN** a workspace containing a file and an active lease
- **WHEN** the environment VM is closed and recreated under the same lease
- **THEN** the new generation SHALL mount the same workspace at `/workspace`
- **AND** the file SHALL retain identical bytes

#### Scenario: Changed workspace lease
- **GIVEN** a live environment generation
- **WHEN** its trusted authority is changed to a different workspace or lease
- **THEN** the broker MUST close or supersede the old generation before mounting the new workspace

### Requirement: Explicit workspace lifecycle

The control plane MUST support describing, listing, releasing, closing, and deleting owned workspaces. Deletion MUST require no active lease, validate filesystem containment, remove the broker-owned directory, and retain an explicit tombstone or equivalent auditable terminal state.

#### Scenario: Release retains files
- **GIVEN** an active workspace containing files
- **WHEN** the trusted owner releases its lease
- **THEN** the files SHALL remain stored
- **AND** no environment may continue writes with the released lease

#### Scenario: Delete active workspace
- **GIVEN** a workspace with an active lease
- **WHEN** deletion is requested
- **THEN** the broker MUST reject deletion without removing files or metadata

#### Scenario: Delete released workspace
- **GIVEN** a released, closed workspace whose derived path is contained by the configured root
- **WHEN** its owner requests deletion
- **THEN** the broker SHALL remove its files and mark it deleted
- **AND** later acquisition by that workspace ID MUST fail

### Requirement: Clean legacy cutover

The QA migration MUST remove the legacy `environments.workspace_path` schema and anonymous workspace data rather than preserving dual behavior. Migration MUST fail closed if a recorded legacy path is not safely contained beneath the configured workspace root.

#### Scenario: Legacy broker database
- **GIVEN** the current QA schema containing `environments.workspace_path`
- **WHEN** the new broker initializes
- **THEN** it SHALL discard old environment and authority rows, remove contained anonymous workspace directories, and create only the new workspace-aware schema
- **AND** the resulting `environments` table SHALL have no `workspace_path` column

#### Scenario: Unsafe legacy path
- **GIVEN** a legacy environment row whose path resolves outside the workspace root
- **WHEN** migration initializes
- **THEN** broker startup MUST fail before deleting that path

## Mechanism

- `pkgs/by-name/gondolin-broker-effect/src/workspaces.ts` defines the workspace service, strict records, SQLite operations, path derivation, containment checks, reconciliation, and lifecycle errors.
- `pkgs/by-name/gondolin-broker-effect/src/registry.ts` creates/rebuilds `workspaces`, `workspace_leases`, `authority_bindings`, and workspace-aware `environments` under a serialized migration and stores workspace/lease IDs instead of host paths.
- `pkgs/by-name/gondolin-broker-effect/src/domain.ts` defines strict control request schemas containing opaque IDs only.
- `pkgs/by-name/gondolin-broker-effect/src/http.ts` exposes lifecycle mutations only on the control listener; execution routes cannot list, switch, release, or delete workspaces.
- `pkgs/by-name/gondolin-broker-effect/src/environments.ts` validates a current active lease and resolves the derived path before VM creation.
- `modules/den/aspects/workloads/hermes/secure-terminal/default.nix` continues to own the broker state/workspace roots and QA-only service permissions; no new host path is exposed to the gateway or guest.