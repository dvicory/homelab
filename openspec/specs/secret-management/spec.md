# secret-management Specification

## Purpose
Define the minimum security boundary for secrets used by managed systems and workloads without making one secret-provider API or wiring mechanism canonical.

## Requirements

### Requirement: Source-controlled secret material is encrypted

Private secret values kept in source control SHALL be stored encrypted. Declarative configuration MAY contain public keys, encrypted secret artifacts, metadata, and references to secrets, but SHALL NOT embed the corresponding plaintext secret value into source-controlled Nix or reusable build artifacts.

#### Scenario: A service needs a credential
- **WHEN** configuration declares that a service requires a private credential
- **THEN** repository state contains an encrypted artifact or secret reference rather than the plaintext credential in the service configuration

### Requirement: Managed secrets are materialized at the consumer boundary with explicit access

A secret managed by Homelab configuration SHALL be represented declaratively so that it can be materialized at runtime for its intended consumer. Materialized secret files SHALL have explicit ownership and access permissions appropriate to that consumer.

Normal evaluation of desired configuration SHALL NOT require decrypting the secret contents. Interactive, offline, hardware-held, or break-glass credentials MAY remain outside declarative secret management when Homelab configuration does not manage their secret value.

#### Scenario: A host configuration is evaluated
- **WHEN** a managed host that consumes encrypted secrets is evaluated without its runtime decryption identity
- **THEN** the desired configuration can still be evaluated without exposing plaintext secret contents

#### Scenario: A managed secret is materialized
- **WHEN** a declared secret is decrypted on its intended managed system
- **THEN** the resulting runtime material has an explicit owner, group, and access mode rather than relying on broad default access
