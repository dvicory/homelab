## MODIFIED Requirements

### Requirement: Broker-owned authority binding

The broker MUST own the binding between an opaque environment key and its trusted profile, executor, authority class, full immutable policy digest, broker-issued workspace ID, and active workspace lease ID. The ordinary execution protocol MUST NOT accept a caller-selected worklane, template, network class, capability set, workspace ID, lease ID, or host path.

#### Scenario: Default binding
- **GIVEN** an execution request for an unbound environment key
- **WHEN** the configured profile permits automatic default binding
- **THEN** the broker SHALL acquire the profile's default private workspace and bind the environment to its default authority class before creating the VM
- **AND** the response SHALL identify the authority class, policy digest, workspace ID, and lease ID without exposing raw session identity or a host path

#### Scenario: Trusted pre-bound workspace
- **GIVEN** trusted lifecycle code has acquired a workspace lease for an environment key
- **WHEN** it registers the environment authority
- **THEN** the broker SHALL bind the exact workspace and lease IDs with the authority record
- **AND** execution SHALL fail unless that lease remains active and owned by the same environment key

#### Scenario: Conflicting authority
- **GIVEN** an environment key already bound to one authority and workspace context
- **WHEN** a control request attempts to bind incompatible profile, executor, class, policy digest, workspace, or lease data
- **THEN** the broker MUST reject the request with a stable conflict reason
- **AND** MUST NOT modify the existing binding or workspace lease

### Requirement: Structural authority changes create a generation boundary

Changes to guest asset, backend, writable mount, workspace ID or lease, filesystem export, or hard resource envelope MUST create a new environment generation. Runtime network and supported operation grants MAY change effective policy without changing generation.

#### Scenario: Network grant activation
- **GIVEN** an active VM and an approved network-origin grant
- **WHEN** the broker activates the grant
- **THEN** the environment generation MUST remain unchanged

#### Scenario: Workspace lease change
- **GIVEN** an active VM bound to one workspace lease
- **WHEN** trusted control lifecycle code releases that lease or binds a different current lease
- **THEN** the broker MUST close or supersede the old generation before any further execution
- **AND** a process or file handle carrying the old generation MUST fail

#### Scenario: Writable export activation
- **GIVEN** an active VM
- **WHEN** an approved future capability changes its writable host-backed export
- **THEN** the broker MUST close or supersede the old generation before exposing the new authority

## Mechanism

- `pkgs/by-name/gondolin-broker-effect/src/domain.ts`, `registry.ts`, and `authority.ts` extend the strict authority record with broker-issued workspace and lease IDs.
- `pkgs/by-name/gondolin-broker-effect/src/environments.ts` compares workspace and lease identity during reuse and validates the active lease before VM creation or leasing.
- The sandbox-authority plugin registers workspace identity only from the trusted workspace acquisition result or trusted Kanban task context; it never reads model tool arguments for this data.
- The control listener owns explicit workspace/authority mutation. The execution listener may perform only the configured default private acquisition needed for an otherwise unbound ordinary conversation.