## ADDED Requirements

### Requirement: Broker-owned authority binding

The broker MUST own the binding between an opaque environment key and its trusted profile, executor, authority class, and full immutable policy digest. The ordinary execution protocol MUST NOT accept a caller-selected worklane, template, network class, or capability set.

#### Scenario: Default binding
- **GIVEN** an execution request for an unbound environment key
- **WHEN** the configured profile permits automatic default binding
- **THEN** the broker SHALL bind the environment to the profile's default authority class before creating the VM
- **AND** the response SHALL identify the resulting authority class and policy digest without exposing raw session identity

#### Scenario: Conflicting authority
- **GIVEN** an environment key already bound to one authority context
- **WHEN** a control request attempts to bind incompatible profile, executor, class, or policy-digest data
- **THEN** the broker MUST reject the request with a stable conflict reason
- **AND** MUST NOT modify the existing binding

### Requirement: Execution and control plane separation

Authority mutation MUST be exposed only through the broker control listener. Environment execution, file, process, status, and health clients MUST use the execution listener, and neither listener may be available inside the guest.

#### Scenario: Control operation on execution listener
- **WHEN** a client sends an authority-bind or grant-mutation route to the execution listener
- **THEN** the broker MUST reject it without changing registry state

#### Scenario: Execution operation on control listener
- **WHEN** a client sends command execution to the control listener
- **THEN** the broker MUST reject it without starting or leasing a VM

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

Changes to guest asset, backend, writable mount, workspace authority, filesystem export, or hard resource envelope MUST create a new environment generation. Runtime network and supported operation grants MAY change effective policy without changing generation.

#### Scenario: Network grant activation
- **GIVEN** an active VM and an approved network-origin grant
- **WHEN** the broker activates the grant
- **THEN** the environment generation MUST remain unchanged

#### Scenario: Writable export activation
- **GIVEN** an active VM
- **WHEN** an approved future capability changes its writable host-backed export
- **THEN** the broker MUST close or supersede the old generation before exposing the new authority

## Mechanism

- `pkgs/by-name/gondolin-broker-effect` adds strict authority-binding domain types, SQLite persistence, control routes, and listener routing.
- `modules/den/aspects/workloads/hermes/secure-terminal/_policy.nix` emits profile and executor defaults plus installed authority classes; this data remains immutable policy input.
- `modules/den/aspects/workloads/hermes/secure-terminal/default.nix` defines the QA control socket and plugin configuration.
- `pkgs/by-name/hermes-agent-patched` adds only a generic authority-binding key to its infrastructure task-environment registry and canonical environment-key derivation.
- The Nix-managed sandbox-authority plugin registers bindings from trusted session/task and Kanban lifecycle context. It does not modify individual environment-backed tool schemas.
