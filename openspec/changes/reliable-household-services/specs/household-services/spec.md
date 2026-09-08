## Purpose

Define the delivery, ownership, and recovery guarantees that make household applications usable without depending on undocumented setup or unrelated application state.

## ADDED Requirements

### Requirement: Applications have explicit independent delivery and state ownership

Each managed household application SHALL declare its release, runtime dependencies, required credentials, durable state, disposable state, and writable storage boundary. Delivering one application SHALL NOT implicitly upgrade another or reset its accounts and content. A resource SHALL have one desired-state reconciliation owner.

Managed configuration fields SHALL be explicit. Reconciliation MAY overwrite out-of-band edits to those fields, but SHALL preserve undeclared application records, identities and content. Application restart SHALL NOT require successful cross-service configuration reconciliation.

#### Scenario: An independent application release
- **WHEN** an operator delivers a selected application release
- **THEN** unrelated application releases and retained data remain unchanged and required dependencies are available before the application is declared usable

#### Scenario: Another instance of an application is declared
- **WHEN** a second instance of the same application is delivered
- **THEN** it uses its declared state and credentials without overwriting the first instance; shared writable paths require explicit declaration

### Requirement: Managed policy reconstruction uses selected inputs

Externally sourced managed policy SHALL identify the selected upstream inputs and declarative local overrides. Reconstructing that policy SHALL NOT silently adopt newer upstream policy. Changing the reconciliation implementation SHALL NOT leave competing writers for the same managed fields.

#### Scenario: Upstream policy changes after a release is selected
- **WHEN** managed application configuration is reconstructed from the selected release
- **THEN** it uses the selected policy inputs and local overrides rather than the newer upstream state

#### Scenario: A managed field and an unrelated record are edited
- **WHEN** configuration reconciliation runs
- **THEN** the managed field returns to its declared value while the unrelated record is preserved

### Requirement: Household data is recovered as an application-consistent set

A recovery point SHALL identify the matching application/database versions and contain the complete non-reproducible state required to restore user-visible behavior. Database metadata and referenced assets SHALL be mutually consistent. Failed or partial exports SHALL NOT be presented as complete recovery points. Restore SHALL validate inputs before replacing state and preserve displaced state until explicitly retired.

#### Scenario: A stateful service is restored into an empty target
- **WHEN** infrastructure restores a complete recovery point with its declared software and dependencies
- **THEN** the matching persistent files and database state are available with the declared ownership, without importing an unrelated live database

#### Scenario: A compute environment is replaced
- **WHEN** the declared retained state is reattached to its replacement
- **THEN** infrastructure does not rerun destructive initialization or overwrite existing application-managed state

#### Scenario: Restore targets retained mounted storage
- **WHEN** verified state is restored into an existing retained mount
- **THEN** the mount boundary is preserved, displaced contents remain recoverable, and affected writers do not resume against a partial restore

### Requirement: Routine capture limits disruption to the data consistency boundary

Routine backup capture SHALL NOT require stopping the compute environment or unrelated applications. Any coordinated writer pause SHALL be limited to components needed to make the selected data mutually consistent. A service-to-service connection alone SHALL NOT establish a shared capture boundary. Temporary pauses made for capture SHALL be released when safe after capture or failure; inability to resume SHALL be reported as an operational failure. Destructive restoration and compute replacement are separate operations, not routine capture.

#### Scenario: One application is captured while another remains in use
- **WHEN** a recovery point is captured for an application
- **THEN** unrelated applications remain running and the capture does not require their shutdown

#### Scenario: An application uses independently stored database metadata and files
- **WHEN** its capture completes
- **THEN** the database and referenced files meet the application-consistency guarantee without expanding the pause solely because another service calls its API

#### Scenario: Capture fails after writers were paused
- **WHEN** capture cannot complete
- **THEN** no complete recovery point is published, its temporary pauses are released when safe, and any inability to resume is visible without stopping unrelated services

### Requirement: Storage availability and writer authority remain application-scoped

Applications SHALL fail closed when required storage is unavailable rather than writing into a substitute directory. Writer access SHALL be limited to declared application-owned or explicitly shared paths. Missing media or application data SHALL NOT prevent independent substrate management or unrelated services from running.

#### Scenario: Shared writer and reader paths are exercised
- **WHEN** workloads access an explicitly shared test volume
- **THEN** writers can modify only their declared paths and read-only consumers cannot modify the shared content

### Requirement: Reliability claims identify the exercised environment

Infrastructure readiness SHALL cover the delivery and persistence boundaries it owns, with representative application smoke checks where needed to establish usability. It SHALL NOT be inferred solely from manifest rendering or a listening port. Local, production, hardware, and external-provider verification SHALL be distinguished. Same-host recovery points SHALL NOT be described as independent backups.

#### Scenario: Local preparation finishes before production activation
- **WHEN** disposable-runtime acceptance succeeds without production deployment
- **THEN** the handoff records local evidence and outstanding production, hardware, credential, and external connectivity prerequisites without claiming those gates passed
