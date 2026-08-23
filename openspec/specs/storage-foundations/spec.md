# storage-foundations Specification

## Purpose
Define durable storage, encryption, persistence, and provisioning properties that current managed servers rely on while leaving filesystem, pooling, parity, and disk-layout choices free to evolve.

## Requirements

### Requirement: Persistent server data is encrypted at rest

Persistent data owned by managed server storage SHALL be encrypted at rest unless it is explicitly required as narrow pre-unlock boot or recovery material. Plaintext runtime views MAY exist while protected storage is unlocked.

Pre-unlock material SHALL be limited to what is required to reach the unlock or recovery path and SHALL NOT itself contain the secret that directly decrypts the protected data it is used to recover.

#### Scenario: A server is powered off
- **WHEN** the server's protected storage is locked or the machine is powered off
- **THEN** persistent server data is not available as plaintext from the underlying storage media

#### Scenario: Remote unlock requires unencrypted bootstrap material
- **WHEN** a boot-time credential or network identity must be available before protected storage can be unlocked
- **THEN** that material may live in the pre-unlock boundary while the data-decryption secret remains protected separately

### Requirement: Required state survives ephemeral-root reset only through deliberate persistence

On a host whose root state is reset or treated as ephemeral, state required across reboot SHALL live on persistent storage or be explicitly selected for persistence. Correct operation SHALL NOT depend on accidental mutation of the ephemeral root surviving a reset.

#### Scenario: An impermanent host reboots
- **WHEN** ephemeral root state is reset during boot
- **THEN** deliberately persistent machine identity and service state remain available while undeclared ephemeral mutations may disappear

### Requirement: Destructive provisioning is separate from routine activation

Routine desired-state activation SHALL NOT implicitly format, initialize, or reinitialize an existing persistent data device merely because that device appears in configuration.

Operations that establish a destructive on-disk format or encryption container SHALL require an explicit provisioning or installation action. Routine activation MAY then open, mount, and configure an already provisioned device.

#### Scenario: A new encrypted data disk is declared
- **WHEN** configuration describes a disk that has not yet been provisioned
- **THEN** ordinary activation does not silently destroy or initialize the disk and an explicit provisioning step is required before normal use

### Requirement: Physical storage lifecycle has a clear machine owner

The managed machine responsible for attached physical storage SHALL own that storage's device identity, encryption, provisioning, and physical assembly lifecycle unless a deliberate architecture change assigns that responsibility elsewhere.

Higher-level workloads or compute domains MAY consume storage through declared interfaces, but consuming storage SHALL NOT implicitly transfer ownership of the underlying physical-device lifecycle.

#### Scenario: A workload consumes host storage
- **WHEN** a workload or future guest is given access to a host-provided persistent path or volume
- **THEN** that access does not by itself authorize the workload to repartition, re-encrypt, provision, or redefine the underlying physical disks
