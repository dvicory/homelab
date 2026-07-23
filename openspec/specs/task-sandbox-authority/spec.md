# task-sandbox-authority Specification

## Purpose
Define broker-owned authority bindings and the generation boundaries that protect task sandbox execution.

## Requirements

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

### Requirement: Execution and control plane separation

Authority mutation MUST be exposed only through the broker control listener. Environment execution, file, process, status, and health clients MUST use the execution listener, and neither listener may be available inside the guest.

#### Scenario: Control operation on execution listener
- **WHEN** a client sends an authority-bind or grant-mutation route to the execution listener
- **THEN** the broker MUST reject it without changing registry state

#### Scenario: Execution operation on control listener
- **WHEN** a client sends command execution to the control listener
- **THEN** the broker MUST reject it without starting or leasing a VM

#### Scenario: Socket replacement under a running gateway
- **GIVEN** a running Hermes gateway connected through the broker's execution and control socket paths
- **WHEN** NixOS activation or an operator replaces the socket inodes and starts a new broker
- **THEN** the gateway SHALL resolve the replacement sockets without a Hermes redeploy or container restart
- **AND** the gateway MUST NOT receive a writable mount of the broker runtime directory or unrelated host runtime state

### Requirement: Task-scoped canonical environment identity

Hermes MUST provide one generic, infrastructure-only way to associate a trusted authority binding with a task or session. Every environment-backed surface MUST continue to derive its opaque environment key through the canonical identity helper. A task carrying distinct authority MUST NOT share an environment with a conversation or task carrying different authority.

#### Scenario: Concurrent tasks with different authority
- **GIVEN** two tasks in one gateway process with different authority binding IDs
- **WHEN** both invoke terminal and file operations concurrently
- **THEN** Hermes SHALL derive different opaque environment keys
- **AND** each operation SHALL reach only its task's broker binding and VM

#### Scenario: Model cannot register authority
- **WHEN** model-generated terminal or tool arguments include an authority class, worklane, binding ID, or environment key
- **THEN** Hermes MUST ignore or reject those fields unless they came through the trusted plugin registration API

### Requirement: Executor routing is not authority

A Hermes profile or worker-lane assignee MAY contribute an operator-configured default and grant scope, but a model-selected assignee MUST NOT itself create authority beyond the profile's installed mechanisms and remembered operator rules. The trusted dispatcher or sandbox-authority plugin MUST register the effective binding.

#### Scenario: Unknown worker lane
- **GIVEN** a model creates a task with an unknown or unregistered assignee
- **WHEN** the dispatcher evaluates the task
- **THEN** it MUST NOT create a sandbox authority binding or privileged environment for that assignee

#### Scenario: Registered lane default
- **GIVEN** a registered worker lane with an operator-configured default authority class
- **WHEN** the trusted dispatcher claims a task for that lane
- **THEN** the authority plugin MAY register that default before worker execution
- **AND** subsequent worker environment calls MUST resolve the registered task binding rather than a process-global variable

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
