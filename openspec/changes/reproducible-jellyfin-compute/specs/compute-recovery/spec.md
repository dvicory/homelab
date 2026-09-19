## Purpose

Define the isolation and recovery guarantees of replaceable application compute so a persistent service can survive loss of its compute instance without relying on undocumented runtime state.

## ADDED Requirements

### Requirement: Shared compute and application releases have separate lifecycles

Compute lifecycle operations SHALL NOT require knowledge of an individual application's namespace, software version, or database layout. Application releases SHALL be selectable and deliverable independently of the compute operating-system generation. A workload's host-local storage constraint SHALL be explicit and SHALL NOT implicitly constrain unrelated workloads. Declared maintenance outages MAY be accepted; additional compute capacity alone SHALL NOT be represented as providing storage portability or control-plane availability.

#### Scenario: An application is released independently
- **WHEN** an operator selects a new application release
- **THEN** the release can be delivered without rebuilding or activating the compute operating system, and its required recovery procedure remains application-scoped

#### Scenario: Shared compute is replaced
- **WHEN** an operator replaces a compute instance
- **THEN** the infrastructure operation preserves declared external inputs without an application-specific lifecycle implementation, and the selected workload releases are restored through their declared delivery procedures

### Requirement: Compute isolation cannot be silently weakened

A compute domain designated as unprivileged SHALL keep guest root distinct from host root and SHALL declare its host-granted mounts, devices, resource limits, and exceptional kernel permissions. Provisioning, normal reconciliation, and recovery SHALL reject incompatible isolation configuration rather than enabling privileged operation, exposing host management sockets, or broadening permissions to make a workload start.

#### Scenario: A workload cannot start within the declared boundary
- **WHEN** starting the workload requires permissions outside its declared unprivileged compute boundary
- **THEN** startup or verification fails with the unmet requirement identified and the system does not silently grant the additional authority

#### Scenario: An existing instance has unsafe configuration drift
- **WHEN** a lifecycle operation encounters an existing instance with host-root mappings or an undeclared privileged mount or device
- **THEN** the operation refuses to treat that instance as conformant and does not start or replace it automatically

### Requirement: Recovery inputs are explicit and independent of compute state

Each recoverable compute domain SHALL identify its desired configuration, durable application data, secret and identity recovery inputs, required artifact sources, and lower-layer prerequisites. Losing its instance root, Kubernetes database, and container cache SHALL NOT require reconstructing essential configuration through undocumented manual actions. Recovery tooling and its administrative access SHALL remain usable while Kubernetes and the workload are unavailable.

#### Scenario: Compute and cluster state are lost
- **WHEN** the instance root, cluster database, and cache are absent but the declared external recovery inputs and lower-layer prerequisites are available
- **THEN** repository-owned recovery procedures reconstruct the compute domain and persistent service without restoring those disposable components

### Requirement: Reusable compute artifacts contain no private identity

Guest images, build outputs, and generated resource manifests SHALL NOT contain private runtime credentials. A guest SHALL receive its managed identity through declared runtime delivery with verified ownership and permissions before identity-dependent services start. Identity needed after guest replacement SHALL be recoverable outside the disposable guest and cluster state.

#### Scenario: An image is built without secret decryption
- **WHEN** an authorized maintainer evaluates or builds the guest artifact without runtime secret keys
- **THEN** the artifact can be produced without embedding private credentials

#### Scenario: Runtime identity is unavailable
- **WHEN** the required guest identity cannot be delivered or does not match its declared public identity
- **THEN** identity-dependent services remain unavailable rather than silently substituting an untrusted identity

### Requirement: Durable workload data outlives the compute instance

Application state required for service recovery SHALL reside outside the instance root and cluster database. Its attachment, access identity, retention, and consistency requirements SHALL be declared. Deleting or recreating a compute instance or Kubernetes object SHALL NOT delete, reinitialize, or recursively change ownership of the retained application data.

#### Scenario: Guest replacement preserves application state
- **WHEN** the compute instance and cluster objects are replaced
- **THEN** the replacement workload reattaches the retained data with the intended access identity and does not require application setup to be repeated

#### Scenario: A persistent volume claim is removed
- **WHEN** an operator removes a workload claim or reconstructs cluster storage objects
- **THEN** the underlying retained data remains available for explicit reattachment

### Requirement: Storage attachment fails closed

A workload SHALL NOT start against a missing, substituted, or incorrectly mounted required durable source. Required source validation SHALL distinguish the intended storage from an empty directory at its mountpoint. Source disappearance SHALL remove dependent workload access rather than expose an underlying directory as a replacement. A source attached read-only to a compute domain SHALL remain read-only at both that attachment boundary and its workload mounts. For a source deliberately shared with writers, each consumer's declared read or write access SHALL be enforced through workload mounts and filesystem permissions.

#### Scenario: Host-provided storage is unavailable
- **WHEN** a required source mount is absent even though its mountpoint directory exists
- **THEN** the workload does not start against that directory or initialize replacement application data there

#### Scenario: An attached source disappears
- **WHEN** the host loses a required source mount while the workload is running
- **THEN** dependent workload access stops or fails without falling through to an underlying host directory

#### Scenario: A workload attempts to modify read-only data
- **WHEN** a workload tries to create, modify, or delete data in a source attached read-only to the compute domain
- **THEN** the write is denied at the compute storage boundary even if the workload's own mount declaration is misconfigured

#### Scenario: Readers and writers share a durable source
- **WHEN** a source is deliberately exposed for writes by selected workloads and reads by other workloads
- **THEN** only the declared writers can modify it and a reader does not gain write permission merely because the compute domain has a writable attachment

### Requirement: Application storage failures stay within their dependency boundary

Storage required only by an application SHALL NOT be a prerequisite for starting or maintaining the entire compute node. When node-essential storage remains available, loss of application storage SHALL affect its dependent workloads without stopping unrelated workloads or the node's management and recovery services. Restoring the source SHALL allow the affected workload to recover without replacing the node.

#### Scenario: Application storage is absent during node boot
- **WHEN** a compute node starts with its own required storage available but an application's storage unavailable
- **THEN** the node and unrelated workloads can start while the dependent application is prevented from using substitute storage

#### Scenario: Application storage disappears and returns
- **WHEN** an application's required storage disappears and is later restored while node-essential storage remains available
- **THEN** the node remains available and the affected application can resume using the restored source without a node restart or replacement

### Requirement: Application-version changes retain a compatible recovery point

Before an application-version change that can modify retained state, the managed update procedure SHALL preserve a consistent recovery point and identify the matching application software and configuration. It SHALL verify recovery artifacts are available before starting the change and SHALL NOT apply a software downgrade to migrated data on the assumption that reversing configuration reverses a data migration. Restoring an earlier data state SHALL be explicit and disclose the loss of changes made since that recovery point. Update and replacement operations targeting the same retained state SHALL be serialized.

#### Scenario: An application upgrade fails after modifying its database
- **WHEN** recovery requires the previous application version after an unsuccessful upgrade
- **THEN** the operator can restore its matching consistent data state and software rather than running the previous version against an unverified migrated database

#### Scenario: A consistent recovery point cannot be obtained
- **WHEN** the managed upgrade procedure cannot establish a consistent recovery point or retain its matching software
- **THEN** it refuses to begin the application-version change

#### Scenario: A runtime update does not select an application upgrade
- **WHEN** a compute OS or orchestrator update is selected without an application-version change
- **THEN** the managed application version remains pinned rather than following a floating image tag

### Requirement: Routine reconciliation is not destructive replacement

Routine desired-state reconciliation SHALL preserve retained data and SHALL NOT implicitly delete or recreate an existing compute instance. It SHALL distinguish absence from permission, transport, or runtime failures, and SHALL report incompatible drift. Destructive replacement SHALL require an explicit operation naming the target and retained inputs, validate those inputs before destruction, and serialize against competing lifecycle operations.

#### Scenario: Provisioning is rerun
- **WHEN** an operator repeats provisioning for a conformant existing instance
- **THEN** its root and retained data remain intact and no duplicate instance is created

#### Scenario: The runtime API cannot be queried
- **WHEN** inspection fails because of an access or transport error
- **THEN** the lifecycle operation fails rather than treating the instance as absent

#### Scenario: Replacement prerequisites are incomplete
- **WHEN** destructive replacement is requested without a required retained input or replacement artifact
- **THEN** the operation refuses before deleting the existing instance

### Requirement: Private exposure is preserved during recovery

A service designated private SHALL expose its client and management paths only through declared private access boundaries. Fresh bootstrap, routine updates, and recovery SHALL NOT create a publicly reachable setup wizard, administrative API, or workload endpoint. Private transport carrying credentials SHALL be authenticated and encrypted.

#### Scenario: A new instance awaits application setup
- **WHEN** the private service first starts before its application administrator exists
- **THEN** setup is reachable only through the declared authenticated private access path

### Requirement: Recovery acceptance exercises the persistent service

A successful recovery claim SHALL be supported by a test that creates meaningful application state, removes the compute instance and cluster database, reconstructs them from the declared inputs, and verifies application access, preserved state, and real data consumption. Verification SHALL distinguish local configuration checks from target runtime evidence. Same-host retention SHALL NOT be described as an independent backup or recovery from physical host loss.

#### Scenario: Persistent service recovery is accepted
- **WHEN** the guest and cluster database have been destroyed and reconstructed using the recovery procedure
- **THEN** the service retains its configured access and previously recorded application state, and an authorized client can perform a representative operation using the retained data without repeating initial setup

#### Scenario: Only local evaluation has run
- **WHEN** configuration evaluation or artifact validation succeeds without exercising the target runtime
- **THEN** reporting identifies those checks as local evidence and leaves target boot, storage access, and destructive recovery unverified
