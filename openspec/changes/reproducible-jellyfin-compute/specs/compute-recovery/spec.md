## Purpose

Define the isolation and recovery guarantees of replaceable application compute
so a persistent service can survive loss of its compute instance without
relying on undocumented runtime state. This delta also defines the Jellyfin
first-start, stock-runtime, and supported-API reconciliation boundary that
consumes the compute contract.

## ADDED Requirements

### Requirement: Shared compute and application releases have separate lifecycles

Compute lifecycle operations SHALL NOT require knowledge of an individual
application's namespace, software version, or database layout. Application
releases SHALL be selectable and deliverable independently of the compute
operating-system generation. A workload's host-local storage constraint SHALL
be explicit and SHALL NOT implicitly constrain unrelated workloads. Declared
maintenance outages MAY be accepted; additional compute capacity alone SHALL
NOT be represented as providing storage portability or control-plane
availability.

#### Scenario: An application is released independently
- **WHEN** an operator selects a new application release
- **THEN** the release can be delivered without rebuilding or activating the
  compute operating system, and its required recovery procedure remains
  application-scoped

#### Scenario: Shared compute is replaced
- **WHEN** an operator replaces a compute instance
- **THEN** the infrastructure operation preserves declared external inputs
  without an application-specific lifecycle implementation, and the selected
  workload releases are restored through their declared delivery procedures

### Requirement: Compute isolation cannot be silently weakened

A compute domain designated as unprivileged SHALL keep guest root distinct from
host root and SHALL declare its host-granted mounts, devices, resource limits,
and exceptional kernel permissions. Provisioning, normal reconciliation, and
recovery SHALL reject incompatible isolation configuration rather than enabling
privileged operation, exposing host management sockets, or broadening
permissions to make a workload start.

#### Scenario: A workload cannot start within the declared boundary
- **WHEN** starting the workload requires permissions outside its declared
  unprivileged compute boundary
- **THEN** startup or verification fails with the unmet requirement identified
  and the system does not silently grant the additional authority

#### Scenario: An existing instance has unsafe configuration drift
- **WHEN** a lifecycle operation encounters an existing instance with host-root
  mappings or an undeclared privileged mount or device
- **THEN** the operation refuses to treat that instance as conformant and does
  not start or replace it automatically

### Requirement: Recovery inputs are explicit and independent of compute state

Each recoverable compute domain SHALL identify its desired configuration,
durable application data, secret and identity recovery inputs, required
artifact sources, and lower-layer prerequisites. Losing its instance root,
Kubernetes database, and container cache SHALL NOT require reconstructing
essential configuration through undocumented manual actions. Recovery tooling
and its administrative access SHALL remain usable while Kubernetes and the
workload are unavailable.

#### Scenario: Compute and cluster state are lost
- **WHEN** the instance root, cluster database, and cache are absent but the
  declared external recovery inputs and lower-layer prerequisites are available
- **THEN** repository-owned recovery procedures reconstruct the compute domain
  and persistent service without restoring those disposable components

### Requirement: Reusable compute artifacts contain no private identity

Guest images, build outputs, and generated resource manifests SHALL NOT contain
private runtime credentials. A guest SHALL receive its managed identity through
declared runtime delivery with verified ownership and permissions before
identity-dependent services start. Identity needed after guest replacement
SHALL be recoverable outside the disposable guest and cluster state.

#### Scenario: An image is built without secret decryption
- **WHEN** an authorized maintainer evaluates or builds the guest artifact
  without runtime secret keys
- **THEN** the artifact can be produced without embedding private credentials

#### Scenario: Runtime identity is unavailable
- **WHEN** the required guest identity cannot be delivered or does not match
  its declared public identity
- **THEN** identity-dependent services remain unavailable rather than silently
  substituting an untrusted identity

### Requirement: Durable workload data outlives the compute instance

Application state required for service recovery SHALL reside outside the
instance root and cluster database. Its attachment, access identity, retention,
and consistency requirements SHALL be declared. Deleting or recreating a
compute instance or Kubernetes object SHALL NOT delete, reinitialize, or
recursively change ownership of the retained application data.

#### Scenario: Guest replacement preserves application state
- **WHEN** the compute instance and cluster objects are replaced
- **THEN** the replacement workload reattaches the retained data with the
  intended access identity and does not require application setup to be
  repeated

#### Scenario: A persistent volume claim is removed
- **WHEN** an operator removes a workload claim or reconstructs cluster storage
  objects
- **THEN** the underlying retained data remains available for explicit
  reattachment

### Requirement: Storage attachment fails closed

A workload SHALL NOT start against a missing, substituted, or incorrectly
mounted required durable source. Required source validation SHALL distinguish
the intended storage from an empty directory at its mountpoint. Source
disappearance SHALL remove dependent workload access rather than expose an
underlying directory as a replacement. A source attached read-only to a
compute domain SHALL remain read-only at both that attachment boundary and its
workload mounts. For a source deliberately shared with writers, each
consumer's declared read or write access SHALL be enforced through workload
mounts and filesystem permissions.

#### Scenario: Host-provided storage is unavailable
- **WHEN** a required source mount is absent even though its mountpoint
  directory exists
- **THEN** the workload does not start against that directory or initialize
  replacement application data there

#### Scenario: An attached source disappears
- **WHEN** the host loses a required source mount while the workload is running
- **THEN** dependent workload access stops or fails without falling through to
  an underlying host directory

#### Scenario: A workload attempts to modify read-only data
- **WHEN** a workload tries to create, modify, or delete data in a source
  attached read-only to the compute domain
- **THEN** the write is denied at the compute storage boundary even if the
  workload's own mount declaration is misconfigured

#### Scenario: Readers and writers share a durable source
- **WHEN** a source is deliberately exposed for writes by selected workloads
  and reads by other workloads
- **THEN** only the declared writers can modify it and a reader does not gain
  write permission merely because the compute domain has a writable attachment

### Requirement: Application storage failures stay within their dependency boundary

Storage required only by an application SHALL NOT be a prerequisite for
starting or maintaining the entire compute node. When node-essential storage
remains available, loss of application storage SHALL affect its dependent
workloads without stopping unrelated workloads or the node's management and
recovery services. Restoring the source SHALL allow the affected workload to
recover without replacing the node.

#### Scenario: Application storage is absent during node boot
- **WHEN** a compute node starts with its own required storage available but an
  application's storage unavailable
- **THEN** the node and unrelated workloads can start while the dependent
  application is prevented from using substitute storage

#### Scenario: Application storage disappears and returns
- **WHEN** an application's required storage disappears and is later restored
  while node-essential storage remains available
- **THEN** the node remains available and the affected application can resume
  using the restored source without a node restart or replacement

### Requirement: Routine reconciliation is not destructive replacement

Routine desired-state reconciliation SHALL preserve retained data and SHALL NOT
implicitly delete or recreate an existing compute instance. It SHALL
distinguish absence from permission, transport, or runtime failures, and SHALL
report incompatible drift. Destructive replacement SHALL require an explicit
operation naming the target and retained inputs, validate those inputs before
destruction, and serialize against competing lifecycle operations.

#### Scenario: Provisioning is rerun
- **WHEN** an operator repeats provisioning for a conformant existing instance
- **THEN** its root and retained data remain intact and no duplicate instance is
  created

#### Scenario: The runtime API cannot be queried
- **WHEN** inspection fails because of an access or transport error
- **THEN** the lifecycle operation fails rather than treating the instance as
  absent

#### Scenario: Replacement prerequisites are incomplete
- **WHEN** destructive replacement is requested without a required retained
  input or replacement artifact
- **THEN** the operation refuses before deleting the existing instance

### Requirement: Jellyfin has one coupled release identity

The Jellyfin provisioner and long-lived runtime SHALL consume one Nix-owned
release declaration. The declaration SHALL expose package `passthru.release`
fields `version`, `sourceRev`, `runtimeImage`, `runtimeDigest`, and
`provisionPatchRev`, and SHALL identify Jellyfin v12.1 source commit
`ee91c75e777da41a9c4f4855e70adc604fbf2ef8` with exact PR #17902 commit
`8b0a2c269d5a3d9d7084b5295fd818a8a67af6f2`. The runtime image SHALL be the
stock official `docker.io/jellyfin/jellyfin:12.1` image pinned by the declared
architecture-specific digest. Provisioner and runtime version identity SHALL
not be independently overridden.

#### Scenario: Release identity is consumed by both sides
- **WHEN** manifests and the `pkgs.jellyfin-provisioner-image` package are
  evaluated
- **THEN** the initContainer and long-lived container derive their Jellyfin
  release from the same declaration, and no second version or digest is
  silently introduced

#### Scenario: Provisioner and runtime releases drift
- **WHEN** a change selects a provisioner source release or runtime image whose
  upstream Jellyfin version differs from the other side
- **THEN** evaluation or build fails before a workload can be deployed

#### Scenario: Jellyfin is upgraded
- **WHEN** an operator upgrades Jellyfin
- **THEN** the provisioner source, official runtime image/digest, patch
  compatibility, and focused acceptance evidence are reviewed and moved
  together

### Requirement: First-start provisioning is bounded before normal HTTP

The provisioner SHALL be a Nix-built `pkgs.jellyfin-provisioner-image` used only
as a Kubernetes initContainer. It SHALL mount retained `/config`, use the
exact pinned v12.1 source plus PR #17902 patch, and complete before the stock
runtime can become ready. In Provision mode it SHALL run only its internal
`SetupServer`. The official runtime SHALL be completely stock and SHALL remain
the only long-lived Jellyfin process.

#### Scenario: Fresh retained state is provisioned
- **WHEN** a Pod starts with an empty retained `/config`
- **THEN** the provisioner completes first-start initialization, exits
  successfully, and only then can the stock official runtime start and pass
  readiness

#### Scenario: Provision mode runs
- **WHEN** the provisioner executes its patched Provision mode
- **THEN** it runs only its internal `SetupServer`, and no externally routable
  stock-runtime backend exists until provisioning completes

#### Scenario: The stock runtime is inspected
- **WHEN** the long-lived Jellyfin process is identified after init completion
- **THEN** it comes from the pinned official runtime image, not from the
  patched provisioner image or a Nix-rebuilt multimedia image

### Requirement: Provisioning credentials are assembled only at runtime

Credential-bearing provision input SHALL be assembled at runtime from
Nix-rendered non-secret values and an agenix-managed Kubernetes Secret or
mounted secret file. The final file SHALL live only in a restrictive
memory-backed volume during provisioning and SHALL be removed afterward. It
SHALL NOT enter Git, generated manifests, the Nix store, logs, command-line
arguments, or retained `/config`.

#### Scenario: A provisioner artifact is built without secret access
- **WHEN** an authorized maintainer evaluates or builds the provisioner image
  without administrator secret keys
- **THEN** the image and generated non-secret resources contain no private
  administrator credential

#### Scenario: Runtime-only provision input is used
- **WHEN** a Pod runs the provisioner
- **THEN** the credential-bearing input is assembled in memory with restrictive
  ownership, is not printed or passed as an argument, and is removed after
  provisioning

### Requirement: Repeated Provision mode is a safe no-op

Provisioning an already initialized Jellyfin `/config` SHALL succeed as a
no-op. A repeated initContainer run SHALL NOT reset the administrator
password, recreate users or libraries, reset retained state, overwrite
Jellarr-managed settings, or fail merely because setup was completed. If the
upstream patch lacks this behavior, the implementation SHALL carry only the
smallest Provision-mode compatibility adjustment and SHALL NOT parse or rewrite
Jellyfin's internal database to manufacture idempotence.

#### Scenario: An initialized Pod is recreated
- **WHEN** the initContainer runs against an already initialized `/config`
- **THEN** it exits successfully, preserves credentials and application state,
  and the stock runtime starts normally

#### Scenario: A repeated run meets Jellarr-owned state
- **WHEN** Provision mode is rerun after Jellarr has reconciled a selected
  setting
- **THEN** the provisioner leaves that setting unchanged

### Requirement: Provisioning failures after preflight remain visible

Provisioning SHALL validate required inputs before mutation where possible, but
it SHALL be treated as non-transactional after preflight. A failure after
preflight SHALL fail the initContainer, SHALL prevent stock-runtime readiness,
and SHALL expose an actionable failure outcome without claiming automatic
rollback or silently retrying into an unknown retained state.

#### Scenario: A post-preflight operation fails
- **WHEN** a focused test injects a failure after Provision mode has passed
  preflight
- **THEN** the initContainer reports failure, the stock runtime does not become
  ready, and the test records the resulting retained-state condition

### Requirement: Steady-state configuration uses supported APIs only

The provisioner SHALL own fresh-state initialization only. Routine steady-state
configuration SHALL NOT copy or overwrite Jellyfin internal XML and SHALL NOT
write Jellyfin SQLite directly. Jellarr SHALL be the selected ongoing owner
only for API-exposed fields explicitly present in its declarative
configuration, and unspecified fields SHALL remain application-owned.

#### Scenario: A selected setting drifts
- **WHEN** an API-exposed Jellarr-owned setting is changed away from its
  declared value and the one-shot reconciliation runs
- **THEN** Jellarr restores the value through an authenticated supported
  Jellyfin API without direct XML or SQLite manipulation

#### Scenario: An unspecified setting changes
- **WHEN** a setting is not present in Jellarr's declarative configuration
- **THEN** reconciliation leaves it application-owned rather than resetting it

#### Scenario: Startup wizard ownership is checked
- **WHEN** Jellarr's configuration is evaluated
- **THEN** it does not configure `startup.completeStartupWizard`, because that
  field belongs to the first-start provisioner

### Requirement: Jellarr runs once after healthy stock runtime

Jellarr v0.1.0 SHALL run as one pinned declarative one-shot Job after the stock
Jellyfin Service is healthy. Its Job/initContainer SHALL use supported
Jellyfin authentication and API-key endpoints: authenticate with the normal
administrator credential, find a named Jellarr key, create it only when
missing, re-read it, and pass the token through an ephemeral memory-backed
shared volume to the Jellarr process. The generated key SHALL NOT be published
as a durable Kubernetes Secret or copied into agenix. Job failure SHALL be
visible, and a desired configuration change SHALL cause another one-shot run.

#### Scenario: Jellarr has no existing API key
- **WHEN** the healthy stock runtime has no API key named for Jellarr
- **THEN** the Job authenticates through supported APIs, creates exactly one
  key, re-reads it, and Jellarr reconciles using a token held only in shared
  ephemeral memory

#### Scenario: Jellarr runs again
- **WHEN** the one-shot reconciliation runs a second time with the existing
  named key
- **THEN** it reuses that key, creates no duplicate, and leaves the resulting
  desired configuration unchanged

#### Scenario: Jellarr starts before Jellyfin is healthy
- **WHEN** the stock Service is not healthy
- **THEN** the Jellarr Job waits or fails visibly and does not attempt a hidden
  direct database bootstrap

### Requirement: Jellyfin has one normal declarative administrator

The first-start provisioner SHALL create one normal administrator whose
credential source and desired policy are explicit. The password SHALL remain
agenix-owned at rest. Jellarr MAY reconcile supported administrator policy or
password fields only when declared, but the workload SHALL NOT rely on a
second undocumented bootstrap or automation administrator.

#### Scenario: Fresh state creates the administrator
- **WHEN** the provisioner initializes an empty `/config`
- **THEN** the declared normal administrator is created and can authenticate to
  the stock runtime after readiness

#### Scenario: Administrator ownership is reviewed
- **WHEN** a proposed design adds another administrator for automation
- **THEN** the change identifies its lifecycle and retention explicitly or is
  rejected in favor of the one normal declarative administrator

### Requirement: Application startup ownership is explicit

Nix/Den and Kubernetes/Argo SHALL own workload declarations, retained storage
and media mounts, resource/security policy, Service/Gateway objects, release
pins, and declarative Jellarr configuration. The patched provisioner SHALL own
fresh-state SetupServer initialization and initial administrator creation. The
stock official runtime SHALL own normal serving, database/state internals,
media processing, and unspecified settings. Jellarr SHALL own only selected
supported API fields. Preserve SHALL own backup/recovery policy and
retained-state protection. No owner SHALL silently write another owner's
boundary.

#### Scenario: A new configuration writer is proposed
- **WHEN** a change introduces a Jellyfin XML/SQLite writer or a second
  startup/reconciliation controller
- **THEN** it is rejected unless it removes the competing owner and uses the
  owner boundary above

#### Scenario: Retained state is recovered
- **WHEN** Preserve or compute replacement restores retained Jellyfin state
- **THEN** it restores the declared inputs without taking ownership of
  first-start provisioning, stock runtime behavior, or Jellarr's selected API
  fields
